defmodule AlaLint.LiveViewRulesTest do
  use ExUnit.Case, async: true

  @layers [
    {:app, [~r/^App\.Page/]},
    {:state, [~r/^App\.Features\./]},
    {:domain, [~r/^App\.Domain\./]},
    {:platform, [~r/^App\.Store/, ~r/^App\.Binder/, ~r/^App\.Parts/]}
  ]

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ala_lint_lv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "page.ex"), ~S'''
    defmodule App.Page do
      alias App.Features.Cart
      alias App.Domain.Rule
      @gift_wrap_unit 299

      def bindings(cart_id), do: %{{:cart, :rows} => [{:via, &add_line(cart_id, &1), []}]}

      def handle_event("start", _, socket), do: Cart.start(socket, socket.assigns.summary)
      def handle_info(_msg, socket), do: socket

      defp add_line(cart_id, p) do
        App.Store.add(cart_id, p)
        App.Store.list(cart_id)
      end

      def render(assigns) do
        ~H"""
        <div :if={@count == 0}>{Money.new(@price * @qty)}</div>
        <div :for={row <- @rows}>{Rule.call(row)}</div>
        <.live_component module={Cart} id="c" init={Rule.new(2)} />
        <%= case @status do %>
        <% end %>
        <p :if={@flag} class={[@on && "on"]}>{@summary.total} Gift wrap ($2.99)</p>
        <.live_component module={Cart} id="cart" />
        """
      end
    end
    ''')

    File.write!(Path.join(dir, "cart.ex"), ~S'''
    defmodule App.Features.Cart do
      def ports, do: %{in: [start: :event], out: [rows: :row_change, gone: :item]}
      def start(cart, _), do: {cart, [rows: 1, extra: 2]}
      def schema(cs), do: validate_format(cs, :code, ~r/x/, message: "must look like PO-1234")
      def label(rate), do: "free over #{rate}"
      def items(c), do: %{currency: "usd", c: c}
    end
    ''')

    File.write!(Path.join(dir, "domain.ex"), ~S'''
    defmodule App.Domain.Rule do
      defstruct unit: 0
      def new(unit), do: %__MODULE__{unit: unit}
      def call(%__MODULE__{unit: unit}, count), do: count * unit
      def other(%__MODULE__{unit: unit}), do: unit
    end
    ''')

    File.write!(Path.join(dir, "parts.ex"), ~S'''
    defmodule App.Parts do
      use Phoenix.Component
      def row(assigns), do: ~H"""
      <div><button>Save for later</button><input placeholder="Promo code" /></div>
      """
    end
    ''')

    File.write!(Path.join(dir, "binder.ex"), ~S'''
    defmodule App.Binder do
      def apply_binding({:stream, _}, s), do: s
      def apply_binding({:assign, _}, s), do: s
      def apply_binding({:flash, _}, s), do: s
      def apply_binding({:input, _}, s), do: s
      def apply_binding({:via, _}, s), do: s
      def apply_binding(:redirect, s), do: s
    end
    ''')

    File.write!(Path.join(dir, "store.ex"), ~S'''
    defmodule App.Store do
      def add(_c, _p), do: :ok
      def list(_c), do: []
    end
    ''')

    r = AlaLint.analyze(dir, layers: @layers, strict: true)
    {:ok, r: r}
  end

  defp msgs(r, rule), do: for(f <- r.findings, f.rule == rule, do: f.message)
  defp any?(r, rule, pattern), do: Enum.any?(msgs(r, rule), &(&1 =~ pattern))

  test "logic in an application template is R11", %{r: r} do
    assert any?(r, :r11, "compares (`==`)")
    assert any?(r, :r11, "computes (`*`)")
    assert any?(r, :r11, "iterates")
    assert any?(r, :r11, "uses `case`")
    assert any?(r, :r11, "calls Domain.Rule.call")
  end

  test "wiring forms in a template are not logic", %{r: r} do
    refute any?(r, :r11, "@flag")
    refute any?(r, :r11, "@summary.total")
    refute any?(r, :r11, "@on &&")
    refute any?(r, :r11, "Rule.new")
  end

  test "words and codes below the composition are R3", %{r: r} do
    assert any?(r, :r3, ~s("Save for later"))
    assert any?(r, :r3, ~s("Promo code"))
    assert any?(r, :r3, ~s(validation message "must look like PO-1234"))
    assert any?(r, :r3, "sentence built by interpolation")
    assert any?(r, :r3, ~s(currency code "usd"))
  end

  test "a label restating a configured amount is R5", %{r: r} do
    assert any?(r, :r5, "$2.99")
  end

  test "declared ports: drift both ways, and an unwired output", %{r: r} do
    assert any?(r, :ports, "emits `extra`")
    assert any?(r, :ports, "declares output `gone`")
    assert any?(r, :ports_unwired, "`gone`")
    refute any?(r, :ports_unwired, "`rows`")
  end

  test "an assign handed to a lower call, a wiring closure, and store work in a helper", %{r: r} do
    assert any?(r, :r11, "reads an assign and passes it into Features.Cart.start")
    assert any?(r, :wiring_closure, "add_line")
    assert any?(r, :r11, "page helper doing store work")
  end

  test "report-only measures", %{r: r} do
    assert any?(r, :r11_share, "of application functions")
    assert any?(r, :hops, "one message hop")
    assert any?(r, :vocabulary, "6 kinds")

    refute Enum.any?(
             r.scored_findings,
             &(&1.rule in [:r11_share, :hops, :vocabulary, :ports_unwired])
           )
  end

  test "a configured rule is neither a primitive wrapper nor a shared aggregate", %{r: r} do
    refute any?(r, :r6, "Rule.call")
    refute any?(r, :r10_aggregate, "Rule")
  end
end

defmodule AlaLint.UnassignedTest do
  use ExUnit.Case, async: true

  test "a module matching no layer is a loud, unscored warning" do
    dir =
      Path.join(System.tmp_dir!(), "ala_lint_unassigned_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.ex"), "defmodule App.Page do\n  def x, do: 1\nend\n")
    File.write!(Path.join(dir, "b.ex"), "defmodule Stray.Thing do\n  def y, do: 2\nend\n")

    r = AlaLint.analyze(dir, layers: [{:app, [~r/^App\./]}, {:domain, [~r/^App\.Domain/]}])

    assert [%{module: "Stray.Thing", severity: :warn}] =
             Enum.filter(r.findings, &(&1.rule == :unassigned))

    refute Enum.any?(r.scored_findings, &(&1.rule == :unassigned))
    assert AlaLint.Report.to_text(r) =~ "!! WARNING: 1 module(s) (1 functions) match no layer"
    assert AlaLint.Report.unassigned_banner(AlaLint.analyze(dir)) == ""
  end
end

defmodule AlaLint.UiIoTest do
  use ExUnit.Case, async: true

  @layers [
    {:app, [~r/^App\.Page/]},
    {:state, [~r/^App\.Features\./]},
    {:platform, [~r/^App\.Store/, ~r/^App\.Repo/, ~r/^App\.Widgets/]}
  ]

  test "a UI component that loads or saves is flagged; one that renders what it's given isn't" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_uiio_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "all.ex"), ~S'''
    defmodule App.Repo do
      def all(q), do: q
    end

    defmodule App.Store do
      alias App.Repo
      def list(id), do: Repo.all(id)
    end

    defmodule App.Features.Cart.Panel do
      use Phoenix.LiveComponent
      def update(%{store: store, id: id}, s), do: {:ok, Map.put(s, :rows, store.list(id))}
      def handle_event("save", _, s), do: {:noreply, (s.assigns.store.save(s.assigns.rows); s)}
      def render(assigns), do: assigns.row.name
    end

    defmodule App.Features.Saved.Panel do
      use Phoenix.LiveComponent
      def update(_, s), do: {:ok, Map.put(s, :rows, App.Store.list(1))}
      def render(assigns), do: assigns
    end

    defmodule App.Widgets do
      use Phoenix.Component
      def row(assigns), do: assigns.row.product.name
    end
    ''')

    r = AlaLint.analyze(dir, layers: @layers, strict: true)
    msgs = for f <- r.findings, f.rule == :ui_io, do: {f.module, f.message}

    assert Enum.any?(msgs, fn {m, msg} ->
             m == "App.Features.Cart.Panel" and msg =~ "store.list" and msg =~ "store.save"
           end)

    assert Enum.any?(msgs, fn {m, msg} ->
             m == "App.Features.Saved.Panel" and msg =~ "Store.list"
           end)

    refute Enum.any?(msgs, fn {m, _} -> m == "App.Widgets" end)
    assert Enum.any?(r.scored_findings, &(&1.rule == :ui_io))
  end
end

defmodule AlaLint.FeaturesAndSubcomponentsTest do
  use ExUnit.Case, async: true

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ala_lint_features_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "all.ex"), ~S'''
    defmodule App.Page do
      def mount(_, _, s), do: s
    end

    defmodule App.Page.FormComponent do
      use Phoenix.LiveComponent
      def handle_event("save", p, s), do: {:noreply, Map.put(s, :p, p)}
    end

    defmodule App.Stories.UndoRemoval do
      def wire(s, :undo, {:captured, item}), do: App.Steps.start_timer(s, :undo, item, 5000)
    end

    defmodule App.Stories.Coded do
      def total(lines), do: if(lines == [], do: 0, else: length(lines) * 2)
    end

    defmodule App.Widgets.RecordForm do
      use Phoenix.LiveComponent
      def handle_event("submit", p, s), do: {:noreply, Map.put(s, :draft, p)}
    end

    defmodule App.Steps do
      def start_timer(s, _k, _i, _ms), do: s
    end
    ''')

    layers = [
      {:app, [~r/^App\.Page/]},
      {:feature, [~r/^App\.Stories\./]},
      {:domain, [~r/^App\.Widgets\./]},
      {:platform, [~r/^App\.Steps/]}
    ]

    {:ok, r: AlaLint.analyze(dir, layers: layers, super_strict: true)}
  end

  defp on(r, rule, mod), do: Enum.filter(r.findings, &(&1.rule == rule and &1.module == mod))

  test "a LiveComponent inside the application is a contained sub-component", %{r: r} do
    assert [f] = on(r, :subcomponent, "App.Page.FormComponent")
    assert f.message =~ "§2.2"
    assert on(r, :subcomponent, "App.Widgets.RecordForm") == []
    assert Enum.any?(r.scored_findings, &(&1.rule == :subcomponent))
  end

  test "a Features layer is composition: wiring passes, coded logic is R11", %{r: r} do
    assert on(r, :r11, "App.Stories.UndoRemoval") == []

    assert Enum.any?(
             on(r, :r11, "App.Stories.Coded"),
             &(&1.message =~
                 "a Features layer, which holds only instances, configuration and wiring")
           )
  end

  test "a feature may hold its configuration literals", %{r: r} do
    assert on(r, :r3, "App.Stories.UndoRemoval") == []
  end

  test "a layer named for features can opt out" do
    m =
      AlaLint.Layers.resolve([], [{:app, []}, {:feature, [], composition: false}, {:domain, []}])

    assert MapSet.to_list(m.composition_layers) == [0]
  end
end

defmodule AlaLint.RulesMetTest do
  use ExUnit.Case, async: true

  test "the report counts the checklist rules met, so one finding can't round away" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_rules_met_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "all.ex"), ~S'''
    defmodule App.Page do
      def mount(_, _, s), do: s
    end

    defmodule App.Page.FormComponent do
      use Phoenix.LiveComponent
      def update(a, s), do: {:ok, Map.merge(s, a)}
    end
    ''')

    layered =
      AlaLint.analyze(dir,
        layers: [{:app, [~r/^App\.Page/]}, {:domain, [~r/^App\.Domain/]}],
        strict: true
      )

    assert %{
             checked: 10,
             total: 11,
             by_rule: %{r11: %{state: :not_met, scored: 1}, r8: %{state: :unchecked}}
           } = layered.rules

    assert layered.rules.met == 9
    assert AlaLint.Report.to_text(layered) =~ "Checklist rules met: 9 of 10 checked"

    plain = AlaLint.analyze(dir)
    assert plain.rules.by_rule.r11.state == :unchecked
    assert plain.rules.checked == 9
  end
end

defmodule AlaLint.StoryCompositionTest do
  use ExUnit.Case, async: true

  setup_all do
    dir = Path.join(System.tmp_dir!(), "ala_lint_story_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "all.ex"), ~S'''
    defmodule App.Page do
      def mount(_, _, s) do
        rule = App.Domain.Rule.new(2)
        s |> App.Story.input(:a, :mounted, App.Stories.A.new(rule: rule)) |> App.Story.input(:b, :x, rule)
      end

      defp open(s, id), do: App.Story.feed(s, :a, &App.Domain.Rule.call/2, &App.Store.get/1, id)
      def handle_params(%{"id" => id}, _, s), do: {:noreply, open(s, id)}
    end

    defmodule App.Stories.A do
      def parts, do: %{rule: App.Domain.Rule}
      def ports, do: %{in: [mounted: :event], out: [done: :item, never: :item]}
      def new(opts), do: App.Story.new(__MODULE__, %{}, view: [shown: false, count: 0], opts: opts)
      def wire(s, me, :rule, {:x, item}), do: s |> App.Story.show(me, :shown, true) |> App.Story.send_out(me, :done, item)
    end

    defmodule App.Domain.Rule do
      defstruct n: 0
      def new(n), do: %__MODULE__{n: n}
      def call(%__MODULE__{n: n}, x), do: {n, x}
    end

    defmodule App.Story do
      def new(m, p, o), do: {m, p, o}
      def input(s, _, _, _), do: s
      def feed(s, _, _, _, _), do: s
      def show(s, _, _, _), do: s
      def send_out(s, _, _, _), do: s
    end

    defmodule App.Store do
      def get(id), do: id
    end
    ''')

    layers = [
      {:app, [~r/^App\.Page/]},
      {:feature, [~r/^App\.Stories\./]},
      {:domain, [~r/^App\.Domain\./]},
      {:platform, [~r/^App\.Story$/, ~r/^App\.Store$/]}
    ]

    {:ok, r: AlaLint.analyze(dir, layers: layers, super_strict: true)}
  end

  defp msgs(r, rule, mod),
    do: for(f <- r.findings, f.rule == rule, f.module == mod, do: f.message)

  test "naming a built instance to wire it twice isn't handling data", %{r: r} do
    refute Enum.any?(msgs(r, :r11, "App.Page"), &(&1 =~ "binds `rule`"))
  end

  test "a capture handed to a runner isn't store work in a helper", %{r: r} do
    refute Enum.any?(msgs(r, :r11, "App.Page"), &(&1 =~ "page helper doing store work"))
  end

  test "a story's outputs are its send_out ports, not its configuration lists", %{r: r} do
    ports = msgs(r, :ports, "App.Stories.A")
    refute Enum.any?(ports, &(&1 =~ "`shown`" or &1 =~ "`count`" or &1 =~ "`done`"))
    assert Enum.any?(ports, &(&1 =~ "declares output `never` but never emits it"))
  end
end

defmodule AlaLint.AdapterNotPassthroughTest do
  use ExUnit.Case, async: true

  test "a call that computes one of its arguments first is an adapter, not a rename" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_adapter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "all.ex"), ~S'''
    defmodule App.A do
      def go(s, k), do: App.B.start(s, k)
      def go_configured(s, k), do: App.B.start(s, Map.fetch!(s.timers, k))
    end

    defmodule App.B do
      def start(s, _k), do: s
    end

    defmodule App.C do
      def use_a(s), do: App.A.go(s, :x)
      def use_b(s), do: App.A.go_configured(s, :x)
    end
    ''')

    r = AlaLint.analyze(dir)
    names = for f <- r.findings, f.rule == :passthrough, do: f.message
    assert Enum.any?(names, &(&1 =~ "A.go/2"))
    refute Enum.any?(names, &(&1 =~ "go_configured"))
  end
end

defmodule AlaLint.NoComposerPortsTest do
  use ExUnit.Case, async: true

  test "a module that declares ports and has no composer doesn't crash the ports check" do
    dir =
      Path.join(System.tmp_dir!(), "ala_lint_nocomposer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.Page do
      def ports, do: %{in: [], out: [edit: :id]}
      def go(s), do: {s, [edit: 1]}
    end
    ''')

    r =
      AlaLint.analyze(dir,
        layers: [{:app, [~r/^App\.Page/]}, {:platform, [~r/^App\.X/]}],
        strict: true
      )

    refute Enum.any?(r.findings, &(&1.rule == :ports_unwired))
  end
end

defmodule AlaLint.BindingOutAndParadigmTextTest do
  use ExUnit.Case, async: true

  test "an {:out, port} binding is a sent output; a paradigm's own interpolated text isn't product words" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_out_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.Stories.S do
      def parts, do: %{}
      def ports, do: %{in: [], out: [done: :item, never: :item]}
      def bindings, do: %{{:part, :x} => [{:out, :done}]}
    end

    defmodule App.Domain.Rule do
      def label(n), do: "free over #{n} dollars"
    end

    defmodule App.Paradigms.Check do
      def problem(t), do: "a stream takes rows, not #{t}"
    end
    ''')

    layers = [
      {:feature, [~r/^App\.Stories\./]},
      {:domain, [~r/^App\.Domain\./]},
      {:platform, [~r/^App\.Paradigms\./]}
    ]

    r = AlaLint.analyze(dir, layers: layers, strict: true)
    ports = for f <- r.findings, f.rule == :ports, do: f.message
    assert Enum.any?(ports, &(&1 =~ "`never`"))
    refute Enum.any?(ports, &(&1 =~ "`done`"))
    r3 = for f <- r.findings, f.rule == :r3, do: f.module
    assert "App.Domain.Rule" in r3
    refute "App.Paradigms.Check" in r3
  end
end

defmodule AlaLint.ThreeTupleWiringTest do
  use ExUnit.Case, async: true

  test "a page clause head {:instance, :port, payload} counts as wiring that port" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_3tuple_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "cart.ex"), ~S'''
    defmodule App.State.Cart do
      def ports, do: %{in: [], out: [changed: :change, lost: :change]}
      def go(c), do: {c, [changed: 1, lost: 2]}
    end
    ''')

    File.write!(Path.join(dir, "page.ex"), ~S'''
    defmodule App.Page do
      alias App.State.Cart
      def handle_info({:cart, :changed, _change}, s), do: Cart.go(s)
    end
    ''')

    layers = [{:app, [~r/^App\.Page/]}, {:state, [~r/^App\.State\./]}, {:platform, [~r/^App\.X/]}]
    r = AlaLint.analyze(dir, layers: layers)
    [msg] = for f <- r.findings, f.rule == :ports_unwired, do: f.message
    assert msg =~ "`lost`"
    refute msg =~ "`changed`"
  end
end

defmodule AlaLint.ConstructionIsNotReadingTest do
  use ExUnit.Case, async: true

  test "a module that only builds an aggregate isn't one of its readers" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_construct_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.Domain.Cart do
      defstruct [:id]
      def new(id), do: %__MODULE__{id: id}
      def id(%__MODULE__{id: id}), do: id
      def rename(%__MODULE__{} = c, id), do: %{c | id: id}
    end
    ''')

    File.write!(Path.join(dir, "b.ex"), ~S'''
    defmodule App.State.Owner do
      alias App.Domain.Cart
      def go(%Cart{} = c), do: Cart.id(c)
    end
    ''')

    File.write!(Path.join(dir, "c.ex"), ~S'''
    defmodule App.Stories.Builder do
      def new(id), do: App.Domain.Cart.new(id)
    end
    ''')

    File.write!(Path.join(dir, "d.ex"), ~S'''
    defmodule App.State.Reader do
      alias App.Domain.Cart
      def look(c), do: Cart.id(c)
    end
    ''')

    layers = [
      {:story, [~r/^App\.Stories\./], composition: false},
      {:state, [~r/^App\.State\./], unit: ~r/^(App\.State\.[^.]+)/},
      {:domain, [~r/^App\.Domain\./], peer_ok: true},
      {:platform, [~r/^App\.X/]}
    ]

    r = AlaLint.analyze(dir, layers: layers, strict: true)
    [msg] = for f <- r.findings, f.rule == :r10_aggregate, do: f.message
    assert msg =~ "Owner" and msg =~ "Reader"
    refute msg =~ "Builder"
  end
end

defmodule AlaLint.DistinctFunctionsTest do
  use ExUnit.Case, async: true

  test "the report counts functions once per name and arity, and clauses separately" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_distinct_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.A do
      def f(:x), do: 1
      def f(:y), do: 2
      def f(_), do: 3
      def g(a, b), do: {a, b}
    end
    ''')

    r = AlaLint.analyze(dir)
    assert {r.distinct_functions, r.functions} == {2, 4}
    assert AlaLint.Report.to_text(r) =~ "functions: 2 (4 clauses)"
  end
end

defmodule AlaLint.OutClosureStoriesTest do
  use ExUnit.Case, async: true

  test "a story sends through the out function it's given; the page binding a key to its wire isn't a closure" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_outfn_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.Stories.S do
      def parts, do: %{part: App.State.P}
      def ports, do: %{in: [go: :event], out: [done: :item, piped: :item, never: :item]}
      def input(s, :go, x, out), do: s |> out.({:piped, x}) |> then(&out.(&1, {:done, x}))
    end

    defmodule App.Page do
      def parts, do: %{s: App.Stories.S}
      def go(s), do: App.Stories.S.input(s, :go, 1, out(:s))
      defp out(key), do: &wire(&1, key, &2)
      defp hidden(s), do: &helper(&1, s)
      defp helper(a, b), do: {a, b}
      defp wire(s, :s, {:done, _}), do: s
      defp wire(s, :s, {:piped, _}), do: s
    end
    ''')

    layers = [
      {:app, [~r/^App\.Page$/]},
      {:feature, [~r/^App\.Stories\./]},
      {:state, [~r/^App\.State\./]}
    ]

    r = AlaLint.analyze(dir, layers: layers, strict: true)
    ports = for f <- r.findings, f.rule == :ports, do: f.message
    assert Enum.any?(ports, &(&1 =~ "`never`"))
    refute Enum.any?(ports, &(&1 =~ "`done`" or &1 =~ "`piped`"))
    closures = for f <- r.findings, f.rule == :wiring_closure, do: f.message
    assert Enum.any?(closures, &(&1 =~ "helper"))
    refute Enum.any?(closures, &(&1 =~ "wire/"))
  end
end

defmodule AlaLint.CrossModuleNamesTest do
  use ExUnit.Case, async: true

  test "an event or timer named in one module and matched only in another is R5; one module, a shared own name, or a configured name isn't" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_names_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.Stories.Leaky do
      use Phoenix.Component
      def view(assigns), do: ~H"""
      <button phx-click="go_far">Go</button>
      <.row on_remove="drop_line" />
      """
      def mount(s), do: Steps.start_timer(s, :expiry, 1, 10)
    end

    defmodule App.Stories.Tidy do
      use Phoenix.Component
      def view(assigns), do: ~H"""
      <button phx-click="stay_home">Stay</button>
      """
      def handle_event("stay_home", _p, s, _out), do: s
      def mount(s, timer), do: Steps.start_timer(s, timer, 1, 10)
    end

    defmodule App.OtherPage do
      use Phoenix.Component
      def view(assigns), do: ~H"""
      <button phx-click="stay_home">Here too</button>
      """
      def handle_event("stay_home", _p, s), do: s
    end

    defmodule App.Page do
      def handle_event("go_far", _p, s), do: s
      def handle_event("drop_line", _p, s), do: s
      def handle_info({:timer, :expiry, _}, s), do: s
      def handle_info({:timer, :configured, _}, s), do: s
      def mount(s), do: App.Stories.Tidy.mount(s, :configured)
    end
    ''')

    r = AlaLint.analyze(dir)
    msgs = for f <- r.findings, f.rule == :r5, do: f.message
    assert Enum.any?(msgs, &(&1 =~ ~s(event "go_far") and &1 =~ "Leaky" and &1 =~ "Page"))
    assert Enum.any?(msgs, &(&1 =~ ~s(event "drop_line")))
    assert Enum.any?(msgs, &(&1 =~ "timer or task :expiry"))
    refute Enum.any?(msgs, &(&1 =~ "stay_home" or &1 =~ ":configured"))
  end
end

defmodule AlaLint.ApplicationNamesTest do
  use ExUnit.Case, async: true

  test "a page's view module and its page share event names as one application; a story and the page don't" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_appnames_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "a.ex"), ~S'''
    defmodule App.CartView do
      use Phoenix.Component
      def render(assigns), do: ~H"""
      <button phx-click="check_out">Pay</button>
      """
    end

    defmodule App.Stories.Edit do
      use Phoenix.Component
      def view(assigns), do: ~H"""
      <button phx-click="edit_line">Edit</button>
      """
    end

    defmodule App.CartPage do
      def handle_event("check_out", _p, s), do: s
      def handle_event("edit_line", _p, s), do: s
    end
    ''')

    layers = [
      {:app, [~r/^App\.Cart(View|Page)$/]},
      {:feature, [~r/^App\.Stories\./]},
      {:platform, [~r/^App\.X$/]}
    ]

    msgs = for f <- AlaLint.analyze(dir, layers: layers).findings, f.rule == :r5, do: f.message
    assert Enum.any?(msgs, &(&1 =~ ~s(event "edit_line")))
    refute Enum.any?(msgs, &(&1 =~ "check_out"))
  end
end
