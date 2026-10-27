defmodule SequenceAdjustmentsTest do
  # The adjustments agreed on 2026-10-21 from the accumulated-change sequence
  # (ala_lab/docs/Q-checklist-adjustments-from-sequence.md).
  use ExUnit.Case, async: true

  @layers [
    {:app, [~r/^AppWeb\./], peer_ok: true},
    {:feature, [~r/^App\.Features\./], peer_ok: false, unit: ~r/^(App\.Features\.[^.]+)/},
    {:domain, [~r/^App\.Domain\./], peer_ok: true},
    {:platform, [~r/^App\.Platform\./], peer_ok: true}
  ]

  defp analyze(files, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "ala_seq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for {name, src} <- files, do: File.write!(Path.join(dir, name), src)
    on_exit(fn -> File.rm_rf!(dir) end)
    AlaLint.analyze(dir, [layers: @layers, max_app_share: 1.0] ++ opts)
  end

  defp msgs(r, rule), do: for(f <- r.findings, f.rule == rule, do: f.message)
  defp any?(r, rule, pattern), do: Enum.any?(msgs(r, rule), &(&1 =~ pattern))

  defp publics(name, n, prefix \\ "f"),
    do:
      "defmodule #{name} do\n" <>
        Enum.map_join(1..n, "", &"  def #{prefix}#{&1}(x), do: Enum.reverse(x)\n") <> "end\n"

  defp small_domain(count, publics_each) do
    for i <- 1..count,
        do: {"d#{i}.ex", publics("App.Domain.Small#{i}", publics_each)}
  end

  describe "public surface" do
    test "is reported at every tier and scored at none" do
      files = [{"wide.ex", publics("App.Domain.Wide", 30)} | small_domain(6, 3)]

      for opts <- [[], [strict: true], [super_strict: true]] do
        r = analyze(files, opts)
        assert any?(r, :public_surface, "Wide"), "reported with #{inspect(opts)}"
        refute Enum.any?(r.scored_findings, &(&1.rule == :public_surface)), inspect(opts)
        assert r.rules.by_rule.r7.state == :met
      end
    end

    test "flags an outlier among its own layer, with the threshold in the message" do
      r = analyze([{"wide.ex", publics("App.Domain.Wide", 30)} | small_domain(6, 3)])
      [msg] = msgs(r, :public_surface)
      assert msg =~ "Wide exposes 30 public ports"
      assert msg =~ "Q3"
      assert msg =~ "IQR"
    end

    test "a module as wide as its layer's others is not an outlier, whatever the count" do
      files =
        for {n, i} <- Enum.with_index([14, 15, 15, 16, 14]),
            do: {"m#{i}.ex", publics("App.Domain.M#{i}", n)}

      r = analyze(files)
      assert msgs(r, :public_surface) == []
    end

    test "compares a module with its own layer, not the whole app" do
      features =
        for {n, i} <- Enum.with_index([20, 20, 21]),
            do: {"f#{i}.ex", publics("App.Features.F#{i}", n)}

      r = analyze(features ++ small_domain(10, 2))
      assert msgs(r, :public_surface) == []
    end

    test "a floor keeps a tiny app's small modules quiet, and is configurable" do
      files = [{"six.ex", publics("App.Domain.Six", 6)} | small_domain(4, 1)]
      assert msgs(analyze(files), :public_surface) == []
      assert any?(analyze(files, max_public_funs: 2), :public_surface, "Six")
      assert any?(analyze(files, checks: %{public_surface: [max: 2]}), :public_surface, "Six")
    end

    test "the floor and the IQR multiplier can be set from the command line" do
      assert AlaLint.Config.parse_set("public_surface.floor=8") == {:max_public_funs, 8}
      assert AlaLint.Config.parse_set("public_surface.iqr=3") == {:public_surface_iqr, 3.0}
    end

    test "a calibration module is exempt" do
      catalog = ~S'''
      defmodule App.Domain.Catalog do
        @texts %{remove: "Remove", total: "Total"}
        @promo %{portal: ["TRADE5"], cart: ["SAVE10"]}
        def rates, do: %{standard: %{cost: 599}, express: %{cost: 1299}}
        def gift_wrap_cents, do: 299
        def currency, do: "usd"
        def tiers, do: [{200_000, 10, "10%"}, {50_000, 5, "5%"}]
        def texts, do: @texts
        def promo_codes(:portal), do: ["TRADE5"]
        def promo_codes(:cart), do: ["SAVE10"]
        def promo(page), do: Map.fetch!(@promo, page)
        def text(key), do: @texts[key]
        def label(key) do
          case key do
            :a -> "A"
            :b -> "B"
          end
        end
        def c11, do: 11
        def c12, do: 12
        def c13, do: 13
        def c14, do: 14
        def c15, do: 15
        def c16, do: 16
        def c17, do: 17
        def c18, do: 18
        def c19, do: 19
        def c20, do: :twenty
        def c21, do: nil
        def c22, do: -1
        def c23, do: 1.5
        def c24, do: ~w(a b)
        def c25, do: {:ok, "x"}
      end
      '''

      r = analyze([{"catalog.ex", catalog} | small_domain(6, 3)])
      refute any?(r, :public_surface, "Catalog")
    end

    test "one computed public function makes it an abstraction again" do
      not_calibration =
        ~S'''
        defmodule App.Domain.Catalog do
          def total(a, b), do: a + b
        end
        '''
        |> String.replace(
          "end\n",
          Enum.map_join(1..29, "", &"  def c#{&1}, do: #{&1}\n") <> "end\n"
        )

      r = analyze([{"catalog.ex", not_calibration} | small_domain(6, 3)])
      assert any?(r, :public_surface, "Catalog")
    end

    # A literal argument (an event name) already selects the clause, so the payload's shape under
    # it is that port's data, not another port; shapes count where they are the selector.
    test "counts ports, not names: clauses matching distinct shapes in one argument" do
      src = ~S'''
      defmodule App.Domain.Lines do
        defstruct items: []
        def set_product(lines, %{stock: s}), do: {lines, s}
        def set_product(lines, %{amount: a}), do: {lines, a}
        def set_stock(lines, %{stock: s}) when s > 0, do: {lines, s}
        def set_stock(lines, %{stock: _}), do: lines
        def handle_event("save", %{"id" => id}, s), do: {id, s}
        def handle_event("delete", %{"name" => n}, s), do: {n, s}
        def on("set", %{"stock" => s}), do: s
        def on("set", %{"amount" => a}), do: a
        def on("other", %{"x" => x}), do: x
        def take(%App.Domain.A{} = a), do: a
        def take(%App.Domain.B{} = b), do: b
        def take(other), do: other
        def bare(%App.Domain.A{}), do: :a
        def bare(%App.Domain.B{}), do: :b
        def plain(x), do: x
        defp hidden(%{a: a}), do: a
        defp hidden(%{b: b}), do: b
      end
      '''

      dir = Path.join(System.tmp_dir!(), "ala_ports_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "lines.ex"), src)
      on_exit(fn -> File.rm_rf!(dir) end)
      [m] = AlaLint.Analyzer.build(dir).modules

      assert AlaLint.Rules.public_ports(m) == %{
               {:set_product, 2} => 2,
               {:set_stock, 2} => 1,
               {:handle_event, 3} => 1,
               {:on, 2} => 2,
               {:take, 1} => 2,
               {:bare, 1} => 2,
               {:plain, 1} => 1
             }
    end
  end

  describe "R11 routing" do
    test "a literal map from states to components picks what to render (passes)" do
      page = ~S'''
      defmodule AppWeb.CheckoutLive do
        @views %{cart: App.Domain.CartView, pay: App.Domain.PayView}
        @handlers %{add: &App.Domain.Lines.add/2, drop: &App.Domain.Lines.drop/2}
        def render(assigns), do: Map.fetch!(@views, assigns.step).render(assigns)
        def view(step), do: @views[step]
        def handle_event(event, params, socket) do
          handler = Map.fetch!(@handlers, String.to_existing_atom(event))
          {:noreply, App.Platform.Run.run(socket, handler, params)}
        end
      end
      '''

      r = analyze([{"page.ex", page}])
      assert msgs(r, :r11) == []
    end

    test "a case on a step value whose arms only pick a component or navigate is routing" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        def view("lines"), do: App.Domain.LinesView
        def pick(step) do
          case step do
            "lines" -> App.Domain.LinesView
            "review" -> &App.Domain.ReviewView.render/1
            _ -> App.Domain.DoneView
          end
        end
        def go(step, socket) do
          case step do
            "cart" -> {:noreply, push_navigate(socket, to: "/cart")}
            "back" -> {:noreply, push_patch(socket, to: "/portal")}
            _ -> {:noreply, redirect(socket, to: "/")}
          end
        end
        def show(step, assigns) do
          case step do
            1 -> lines_view(assigns)
            2 -> App.Domain.ReviewView.render(assigns)
          end
        end
      end
      '''

      r = analyze([{"page.ex", page}])
      assert msgs(r, :r11) == []
    end

    test "a case on a step value whose arms do work is still a branch" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        def go(step, socket) do
          case step do
            "cart" -> App.Platform.Repo.delete_all(socket.assigns.cart)
            _ -> push_navigate(socket, to: "/")
          end
        end
      end
      '''

      assert any?(analyze([{"page.ex", page}]), :r11, "go/2 branches")
    end

    test "arithmetic in a shorthand function is arithmetic; a named capture is not division" do
      page = ~S'''
      defmodule AppWeb.CartLive do
        def mount(_params, _session, socket) do
          {:ok, assign(socket, wrap: &(&1 * App.Domain.Prices.wrap_cents()))}
        end
        def wire(socket), do: assign(socket, total: &App.Domain.Totals.sum/2, count: &length/1)
      end
      '''

      r = analyze([{"page.ex", page}])
      assert any?(r, :r11, "mount/3 does arithmetic")
      refute any?(r, :r11, "wire/1")
    end

    test "a case on nil or a boolean is the `if` it spells, not routing" do
      page = ~S'''
      defmodule AppWeb.CartLive do
        def promo(code) do
          case Map.get(App.Domain.Codes.all(), code) do
            nil -> {:error, :invalid_code}
            pct -> {:ok, pct}
          end
        end
        def big(total) do
          case total > 100 do
            true -> :free
            false -> :paid
          end
        end
        def saved(result) do
          case App.Domain.Store.save(result) do
            {:ok, row} -> {:noreply, row}
            {:error, why} -> {:noreply, why}
          end
        end
      end
      '''

      r = analyze([{"page.ex", page}])
      assert any?(r, :r11, "promo/1 branches in the application layer (guard)")
      assert any?(r, :r11, "big/1 branches in the application layer (logic)")
      refute any?(r, :r11, "saved/1")
    end

    test "a template case whose arms only place components is routing; one with markup logic is not" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        use Phoenix.Component
        def render(assigns) do
          ~H"""
          <%= case @step do %>
            <% :lines -> %>
              <.lines_view rows={@rows} on_add={&add/1} />
            <% :review -> %>
              <.live_component module={App.Domain.ReviewView} id="review" />
            <% _ -> %>
              <.done_view />
          <% end %>
          """
        end
      end
      '''

      assert msgs(analyze([{"page.ex", page}]), :r11) == []

      mixed =
        String.replace(page, "<.done_view />", "<p>Thanks, {@name}</p>")

      assert any?(analyze([{"page.ex", mixed}]), :r11, "uses `case`")
    end
  end

  describe "R11 run-time names" do
    test "apply/3 with a variable function in a page is a branch" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        def handle_event(event, params, socket), do: apply(App.Domain.Steps, step_fun(event), [params, socket])
        def step(mod, params), do: apply(mod, :run, [params])
        def fixed(params), do: apply(App.Domain.Steps, :run, [params])
        defp step_fun(event), do: event
      end
      '''

      r = analyze([{"page.ex", page}])
      assert any?(r, :r11, "handle_event/3 chooses what runs by a name built at run time")
      assert any?(r, :r11, "step/2 chooses what runs by a name built at run time")
      refute any?(r, :r11, "fixed/1")
    end

    test "String.to_atom, String.to_existing_atom and Module.concat feeding a call are branches" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        def a(step, assigns) do
          mod = Module.concat(App.Domain, step)
          mod.render(assigns)
        end
        def b(step, assigns), do: Module.concat([App.Domain, step]).render(assigns)
        def c(event, x), do: apply(App.Domain.Steps, String.to_existing_atom("on_" <> event), [x])
        def d(name, x) do
          fun = String.to_atom(name)
          App.Domain.Steps |> apply(fun, [x])
        end
        def e(step, x), do: apply(App.Domain.Steps, :"step_#{step}", [x])
      end
      '''

      r = analyze([{"page.ex", page}])
      for f <- ~w(a/2 b/2 c/2 d/2 e/2), do: assert(any?(r, :r11, "#{f} chooses what runs"), f)
    end

    test "an atom built from input used as data, and a configured function, are wiring" do
      page = ~S'''
      defmodule AppWeb.CartLive do
        def handle_event("ship", %{"method" => m}, socket),
          do: {:noreply, App.Platform.Run.run(socket, %{method: String.to_existing_atom(m)})}
        def handle_info({:tab, tab}, socket),
          do: {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
        def wire(fun, x), do: fun.(x)
      end
      '''

      assert msgs(analyze([{"page.ex", page}]), :r11) == []
    end

    test "applies to a Features layer, and not below the composition" do
      story = ~S'''
      defmodule App.Features.Story do
        def go(fun, x), do: apply(App.Domain.Steps, fun, [x])
      end
      '''

      runner = ~S'''
      defmodule App.Domain.Runner do
        def go(mod, fun, x), do: apply(mod, fun, [x])
      end
      '''

      r = analyze([{"story.ex", story}, {"runner.ex", runner}])
      assert any?(r, :r11, "Story.go/2 chooses what runs")
      refute any?(r, :r11, "Runner")
    end
  end

  describe "R10 identity lifecycle" do
    # R10 and r10_aggregate take their entity candidates from `defstruct`. An Ecto `schema`
    # block defines its struct through a macro the analyzer doesn't expand, so a schema is not
    # an entity to either check: a lifecycle declared on it (`has_many ..., on_delete:`) or a
    # context deleting rows keyed by an identity is invisible, and so is a read that walks the
    # association into another feature's rows. This documents the blind spot.
    test "Ecto lifecycle declarations and association reads are invisible to R10" do
      product = ~S'''
      defmodule App.Features.Products.Product do
        use Ecto.Schema
        schema "products" do
          field :name, :string
          has_many :cart_lines, App.Features.Cart.Line, on_delete: :delete_all
        end
      end
      '''

      products = ~S'''
      defmodule App.Features.Products do
        import Ecto.Query
        alias App.Features.Cart.Line
        def delete(id) do
          App.Platform.Repo.delete_all(from l in Line, where: l.product_id == ^id)
        end
        def carted(product), do: App.Platform.Repo.preload(product, :cart_lines).cart_lines
      end
      '''

      line = ~S'''
      defmodule App.Features.Cart.Line do
        use Ecto.Schema
        schema "cart_lines" do
          field :product_id, :integer
          field :quantity, :integer
        end
      end
      '''

      cart = ~S'''
      defmodule App.Features.Cart do
        def lines(cart_id), do: App.Platform.Repo.all(App.Features.Cart.Line, cart_id: cart_id)
      end
      '''

      files = [
        {"product.ex", product},
        {"products.ex", products},
        {"line.ex", line},
        {"cart.ex", cart}
      ]

      for opts <- [[], [strict: true]] do
        r = analyze(files, opts)
        assert msgs(r, :r10) == []
        assert msgs(r, :r10_aggregate) == []
      end
    end
  end

  describe "R11 calls: wired_only (ALA subset 3)" do
    @wired ~S'''
    defmodule App.Domain.Wired do
      def ports, do: %{in: [take: nil], out: [taken: nil]}
      def take(_x, v), do: v
      def count(x), do: length(x)
    end
    '''

    @called ~S'''
    defmodule App.Domain.Called do
      def take(_x, v), do: v
      def count(x), do: length(x)
      def ok?(x), do: x == :ok
    end
    '''

    @source ~S'''
    defmodule App.Domain.Source do
      def get(x), do: x
    end
    '''

    @page ~S'''
    defmodule AppWeb.Page do
      use Phoenix.Component
      alias App.Domain.{Called, Source, Wired}

      def bound_wired(x) do
        v = Source.get(x)
        Wired.take(x, v)
      end

      def bound_called(x) do
        v = Source.get(x)
        Called.take(x, v)
      end

      def straight_wired(x), do: Wired.take(x, Source.get(x))
      def straight_called(x), do: Called.take(x, Source.get(x))

      def handle_event("w", _p, socket), do: {:noreply, Wired.take(socket, socket.assigns.cart)}
      def handle_event("c", _p, socket), do: {:noreply, Called.take(socket, socket.assigns.cart)}

      def decide(x) do
        if Called.ok?(x), do: Wired.count(x), else: 0
      end

      def render(assigns) do
        ~H"""
        <p>{Wired.count(@rows)}</p>
        <p>{Called.count(@rows)}</p>
        """
      end
    end
    '''

    defp subset3(opts \\ []),
      do:
        analyze(
          [
            {"page.ex", @page},
            {"wired.ex", @wired},
            {"called.ex", @called},
            {"source.ex", @source}
          ],
          opts
        )

    defp handoffs(r, into),
      do: [
        any?(r, :r11, "binds `v` from Source and passes it to #{into} "),
        any?(r, :r11, "Source's result straight into #{into} "),
        any?(r, :r11, "reads an assign and passes it into Domain.#{into}.take"),
        any?(r, :r11, "template calls Domain.#{into}.count")
      ]

    test "by default R11 reports hand-offs into wired and called parts alike" do
      r = subset3()
      assert handoffs(r, "Wired") == [true, true, true, true]
      assert handoffs(r, "Called") == [true, true, true, true]
    end

    test "wired_only leaves out hand-offs into a part without ports" do
      r = subset3(r11_calls: :wired_only)
      assert handoffs(r, "Wired") == [true, true, true, true]
      assert handoffs(r, "Called") == [false, false, false, false]
    end

    test "wired_only still reports a branch on a called part's result" do
      assert any?(subset3(r11_calls: :wired_only), :r11, "decide/1 branches")
    end

    test "r11_share counts only what is still reported" do
      share = fn r -> r |> msgs(:r11_share) |> hd() |> String.split("%") |> hd() end

      assert String.to_integer(share.(subset3(r11_calls: :wired_only))) <
               String.to_integer(share.(subset3()))
    end

    test "the checks map sets it, and an explicit opt overrides the map" do
      r = subset3(checks: %{r11: [level: :advisory, calls: :wired_only]})
      assert handoffs(r, "Called") == [false, false, false, false]
      r = subset3(checks: %{r11: [calls: :wired_only]}, r11_calls: :all)
      assert handoffs(r, "Called") == [true, true, true, true]
    end

    test "an unknown value fails" do
      assert_raise ArgumentError, ~r/r11.calls/, fn -> subset3(r11_calls: :some) end
      assert_raise ArgumentError, ~r/r11.calls/, fn -> subset3(checks: %{r11: [calls: :x]}) end
    end

    test "--set r11.calls parses, and the echo shows it only when not the default" do
      assert AlaLint.Config.parse_set("r11.calls=wired_only") == {:r11_calls, "wired_only"}
      refute AlaLint.Report.to_text(subset3()) =~ "r11.calls"

      assert AlaLint.Report.to_text(subset3(r11_calls: :wired_only)) =~
               "r11.calls:      wired_only"
    end

    test "mix ala.lint --set r11.calls with an unknown value exits 2" do
      err =
        assert_raise Mix.Error, ~r/r11.calls/, fn ->
          Mix.Tasks.Ala.Lint.run(["--set", "r11.calls=bogus", "lib"])
        end

      assert err.mix == 2
    end
  end
end
