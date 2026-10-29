defmodule LightAlaTest do
  # Light-ALA rules 11 and 12 (ala_variants_elixir/v59-light-ala/DESIGN.md), the :light_ala
  # preset, and the :not_adopted rule state, from the hybrid-1 run
  # (ala_lab/docs/change-cost-form1-2026-10-24.md).
  use ExUnit.Case, async: true

  @layers [
    {:app, [~r/^AppWeb\./], peer_ok: true},
    {:domain, [~r/^App\./], peer_ok: true}
  ]

  defp write_tree(files) do
    dir = Path.join(System.tmp_dir!(), "ala_light_#{System.unique_integer([:positive])}")

    for {name, src} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp analyze(files, opts \\ []) do
    dir = write_tree(files)
    AlaLint.analyze(Path.join(dir, "lib"), [layers: @layers] ++ resolve_tests(opts, dir))
  end

  # `tests:` paths in a test are relative to the tree written for it
  defp resolve_tests(opts, dir) do
    case get_in(opts, [:checks, :builder_literals]) do
      spec when is_list(spec) ->
        case Keyword.fetch(spec, :tests) do
          {:ok, paths} ->
            spec = Keyword.put(spec, :tests, Enum.map(paths, &Path.join(dir, &1)))
            put_in(opts, [:checks, :builder_literals], spec)

          :error ->
            opts
        end

      _ ->
        opts
    end
  end

  defp findings(r, rule), do: for(f <- r.findings, f.rule == rule, do: f)
  defp msgs(r, rule), do: Enum.map(findings(r, rule), & &1.message)

  @shop ~S'''
  defmodule App.Shop do
    @enforce_keys [:channel, :cart_id]
    defstruct @enforce_keys ++ [locale: "en"]
  end
  '''

  @session ~S'''
  defmodule AppWeb.CartSession do
    alias App.Shop

    def shop(channel, overrides), do: struct!(Shop, [channel: channel] ++ overrides)
  end
  '''

  @page_with_literal ~S'''
  defmodule AppWeb.CartLive do
    alias App.Shop

    def mount(_params, session, socket) do
      shop = %Shop{channel: :storefront, cart_id: session["cart_id"]}
      {:ok, Map.put(socket, :shop, shop)}
    end

    def reads(%Shop{} = shop), do: shop.cart_id

    def moved(shop) do
      case shop do
        %Shop{cart_id: nil} -> %Shop{shop | cart_id: 1}
        other -> other
      end
    end
  end
  '''

  @shop_checks [structs: ["App.Shop"], builders: ["AppWeb.CartSession"]]

  describe "builder_literals (light-ALA rule 11)" do
    test "a literal outside the builder is a finding naming rule 11 as a light-ALA reading" do
      r =
        analyze(
          [
            {"lib/shop.ex", @shop},
            {"lib/session.ex", @session},
            {"lib/page.ex", @page_with_literal}
          ],
          checks: %{builder_literals: @shop_checks}
        )

      assert [f] = findings(r, :builder_literals)
      assert f.file =~ "lib/page.ex"
      assert f.line == 5
      assert f.message =~ "%App.Shop{}"
      assert f.message =~ "AppWeb.CartSession"
      assert f.message =~ "light-ALA rule 11"
      assert f.message =~ "not a checklist rule"
    end

    test "struct!/2 and struct/2 outside the builder count; heads, patterns and updates do not" do
      page = ~S'''
      defmodule AppWeb.PortalLive do
        alias App.Shop

        def a(id), do: struct!(Shop, channel: :portal, cart_id: id)
        def b(id), do: Kernel.struct(App.Shop, cart_id: id)
        def c(%Shop{} = s), do: s
        def d(s) do
          %Shop{cart_id: id} = s
          with %Shop{} <- s, do: %{s | cart_id: id}
        end
      end
      '''

      r =
        analyze([{"lib/shop.ex", @shop}, {"lib/session.ex", @session}, {"lib/portal.ex", page}],
          checks: %{builder_literals: @shop_checks}
        )

      assert Enum.map(findings(r, :builder_literals), & &1.line) |> Enum.sort() == [4, 5]
    end

    test "the struct's own module may build it" do
      shop =
        String.replace(
          @shop,
          "end\n",
          "  def new(overrides), do: struct!(__MODULE__, [channel: :x] ++ overrides)\n  def blank, do: %__MODULE__{channel: :x, cart_id: nil}\nend\n"
        )

      r = analyze([{"lib/shop.ex", shop}], checks: %{builder_literals: @shop_checks})
      assert msgs(r, :builder_literals) == []
    end

    test "test files are read only when tests: names them, and only by this check" do
      test_src = ~S'''
      defmodule AppWeb.CartLiveTest do
        use ExUnit.Case
        alias App.Shop

        test "x" do
          shop = %Shop{channel: :storefront, cart_id: 1}
          assert %Shop{cart_id: 1} = shop
          assert match?(%Shop{}, shop)
        end
      end
      '''

      files = [
        {"lib/shop.ex", @shop},
        {"lib/session.ex", @session},
        {"test/cart_live_test.exs", test_src}
      ]

      without = analyze(files, checks: %{builder_literals: @shop_checks})
      assert msgs(without, :builder_literals) == []

      with_tests =
        analyze(files, checks: %{builder_literals: @shop_checks ++ [tests: ["test"]]})

      assert [f] = findings(with_tests, :builder_literals)
      assert f.file =~ "test/cart_live_test.exs"
      assert f.line == 6
      assert f.message =~ "test"
      assert with_tests.modules == without.modules
      assert with_tests.functions == without.functions
    end

    test "a test-support module named as a builder may build it" do
      fixture = ~S'''
      defmodule App.Fixtures do
        def shop(id), do: %App.Shop{channel: :storefront, cart_id: id}
      end
      '''

      files = [{"lib/shop.ex", @shop}, {"test/support/fixtures.ex", fixture}]
      checks = [structs: ["App.Shop"], tests: ["test"]]

      flagged = analyze(files, checks: %{builder_literals: checks ++ [builders: ["AppWeb.X"]]})
      assert [_] = msgs(flagged, :builder_literals)

      allowed =
        analyze(files, checks: %{builder_literals: checks ++ [builders: ["App.Fixtures"]]})

      assert msgs(allowed, :builder_literals) == []
    end

    test "without builders:, a lib module whose function returns the struct is inferred as its builder, and the echo says so" do
      r =
        analyze(
          [
            {"lib/shop.ex", @shop},
            {"lib/session.ex", @session},
            {"lib/page.ex", @page_with_literal}
          ],
          checks: %{builder_literals: [structs: ["App.Shop"]]}
        )

      # CartLive.moved/1 returns only an update, and mount/3 builds one it doesn't return
      assert [f] = findings(r, :builder_literals)
      assert f.file =~ "lib/page.ex"
      assert AlaLint.Report.to_text(r) =~ "App.Shop built by AppWeb.CartSession (inferred)"
    end

    test "a builder taking the struct's fields positionally is a finding" do
      positional = ~S'''
      defmodule AppWeb.CartSession do
        alias App.Shop
        def shop(channel, cart_id), do: %Shop{channel: channel, cart_id: cart_id}
      end
      '''

      r =
        analyze([{"lib/shop.ex", @shop}, {"lib/session.ex", positional}],
          checks: %{builder_literals: @shop_checks}
        )

      assert [f] = findings(r, :builder_literals)
      assert f.line == 3
      assert f.message =~ "shop/2"
      assert f.message =~ "cart_id"
      assert f.message =~ "keyword"
    end

    test "a builder with a keyword list may take what it can't do without positionally" do
      ok = ~S'''
      defmodule AppWeb.CartSession do
        alias App.Shop
        def shop(name, overrides \\ [])
        def shop(:storefront, overrides), do: build(:storefront, overrides)
        def shop(:portal, overrides), do: build(:portal, overrides)
        def other(channel, cart_id, opts), do: struct!(Shop, [channel: channel, cart_id: cart_id] ++ opts)
        defp build(channel, overrides), do: struct!(Shop, [channel: channel] ++ overrides)
      end
      '''

      r =
        analyze([{"lib/shop.ex", @shop}, {"lib/session.ex", ok}],
          checks: %{builder_literals: @shop_checks}
        )

      assert msgs(r, :builder_literals) == []
    end

    test "too many positional parameters, or an optional field taken positionally, is a finding" do
      src = ~S'''
      defmodule AppWeb.CartSession do
        alias App.Shop
        def wide(channel, cart_id, user, overrides \\ []),
          do: struct!(Shop, [channel: {channel, user}, cart_id: cart_id] ++ overrides)
        def localized(channel, locale, overrides),
          do: struct!(Shop, [channel: channel, locale: locale] ++ overrides)
      end
      '''

      files = [{"lib/shop.ex", @shop}, {"lib/session.ex", src}]
      r = analyze(files, checks: %{builder_literals: @shop_checks})
      found = msgs(r, :builder_literals)
      assert Enum.any?(found, &(&1 =~ "wide/4" and &1 =~ "3 positional"))
      assert Enum.any?(found, &(&1 =~ "localized/3" and &1 =~ "locale"))

      loose = analyze(files, checks: %{builder_literals: @shop_checks ++ [max_positional: 3]})
      refute Enum.any?(msgs(loose, :builder_literals), &(&1 =~ "wide/4"))
    end

    test "is off unless configured, and a default run is unchanged by it" do
      files = [{"lib/shop.ex", @shop}, {"lib/page.ex", @page_with_literal}]
      r = analyze(files)
      assert msgs(r, :builder_literals) == []
      refute Map.has_key?(r.params.weights, :builder_literals)
      refute AlaLint.Report.to_text(r) =~ "builder"
    end

    test "is advisory when configured, scored by --strict or a level" do
      files = [
        {"lib/shop.ex", @shop},
        {"lib/session.ex", @session},
        {"lib/page.ex", @page_with_literal}
      ]

      plain = analyze(files, checks: %{builder_literals: @shop_checks})
      assert [_] = findings(plain, :builder_literals)
      assert Enum.all?(plain.scored_findings, &(&1.rule != :builder_literals))

      strict = analyze(files, checks: %{builder_literals: @shop_checks}, strict: true)
      assert Enum.any?(strict.scored_findings, &(&1.rule == :builder_literals))

      scored = analyze(files, checks: %{builder_literals: [level: :scored] ++ @shop_checks})
      assert Enum.any?(scored.scored_findings, &(&1.rule == :builder_literals))
    end

    test "configuration errors fail" do
      files = [{"lib/shop.ex", @shop}]

      assert_raise ArgumentError, ~r/builder_literals.*structs/, fn ->
        analyze(files, checks: %{builder_literals: [level: :scored]})
      end

      assert_raise ArgumentError, ~r/builder_literals.*bogus/, fn ->
        analyze(files, checks: %{builder_literals: [structs: ["App.Shop"], bogus: 1]})
      end

      assert_raise ArgumentError, ~r/max_positional/, fn ->
        analyze(files, checks: %{builder_literals: [structs: ["App.Shop"], max_positional: -1]})
      end

      assert_raise ArgumentError, ~r/structs/, fn ->
        analyze(files, checks: %{builder_literals: [structs: [App.Shop]]})
      end
    end
  end

  @cart ~S'''
  defmodule App.Cart do
    def get_cart(shop), do: shop
    def add_item(shop, id), do: {shop, id}
    def remove_item(shop, id), do: {shop, id}
  end
  '''

  @guard ~S'''
  defmodule AppWeb.CartSession do
    def guard_open_cart(socket, _shop, _path), do: socket
  end
  '''

  defp page(mount_body, extra \\ "") do
    """
    defmodule AppWeb.OrderLive.Show do
      use AppWeb, :live_view
      alias App.Cart
      alias AppWeb.CartSession

      def mount(_params, session, socket) do
        shop = session["shop"]
        #{mount_body}
      end

      def handle_event("reorder", %{"id" => id}, socket) do
        Cart.add_item(socket.assigns.shop, id)
        {:noreply, socket}
      end

      def handle_event("drop", %{"id" => id}, socket) do
        {:noreply, drop(socket, id)}
      end

      def handle_event("look", _params, socket) do
        Cart.get_cart(socket.assigns.shop)
        {:noreply, socket}
      end

      defp drop(socket, id) do
        App.Cart.remove_item(socket.assigns.shop, id)
        socket
      end
    #{extra}
    end
    """
  end

  @writers [
    writers: ["App.Cart"],
    except: ["get_cart"],
    guards: ["AppWeb.CartSession.guard_open_cart"]
  ]

  describe "stale_session_write (light-ALA rule 12)" do
    test "a page whose events write without a guard in mount: one finding listing the events" do
      r =
        analyze(
          [
            {"lib/cart.ex", @cart},
            {"lib/session.ex", @guard},
            {"lib/show.ex", page("{:ok, socket}")}
          ],
          checks: %{stale_session_write: @writers}
        )

      assert [f] = findings(r, :stale_session_write)
      assert f.file =~ "lib/show.ex"
      assert f.line == 6
      assert f.message =~ "AppWeb.OrderLive.Show"
      assert f.message =~ ~s|"reorder" (App.Cart.add_item)|
      assert f.message =~ ~s|"drop" (App.Cart.remove_item)|
      refute f.message =~ "look"
      assert f.message =~ "light-ALA rule 12"
      assert f.message =~ "not a checklist rule"
    end

    test "a guard attached in mount, directly or through a private function, clears it" do
      direct = page("{:ok, CartSession.guard_open_cart(socket, shop, \"/cart\")}")

      through =
        page(
          "{:ok, socket |> attach(shop)}",
          "  defp attach(socket, shop), do: socket |> AppWeb.CartSession.guard_open_cart(shop, \"/cart\")\n"
        )

      for src <- [direct, through] do
        r =
          analyze([{"lib/cart.ex", @cart}, {"lib/session.ex", @guard}, {"lib/show.ex", src}],
            checks: %{stale_session_write: @writers}
          )

        assert msgs(r, :stale_session_write) == []
      end
    end

    test "except: takes names, Mod.fun and a pattern; a Mod.fun writer matches only that function" do
      files = [{"lib/cart.ex", @cart}, {"lib/show.ex", page("{:ok, socket}")}]

      run = fn settings ->
        msgs(analyze(files, checks: %{stale_session_write: settings}), :stale_session_write)
      end

      assert [m] = run.(writers: ["App.Cart"], except: [~r/^(get_|remove_)/])
      assert m =~ "reorder"
      refute m =~ "drop"

      assert [m] = run.(writers: ["App.Cart"], except: ["App.Cart.get_cart", "add_item"])
      refute m =~ "reorder"

      assert [m] = run.(writers: ["App.Cart.remove_item"])
      assert m =~ "drop"
      refute m =~ "reorder"
    end

    test "with no guard configured, every writing page is a finding" do
      r =
        analyze([{"lib/cart.ex", @cart}, {"lib/show.ex", page("{:ok, socket}")}],
          checks: %{stale_session_write: [writers: ["App.Cart"]]}
        )

      assert [m] = msgs(r, :stale_session_write)
      assert m =~ "no guard is configured"
    end

    test "a controller action and a LiveComponent are not pages" do
      controller = ~S'''
      defmodule AppWeb.CartController do
        use AppWeb, :controller
        def create(conn, %{"id" => id}), do: App.Cart.add_item(conn.assigns.shop, id)
      end
      '''

      component = ~S'''
      defmodule AppWeb.LineComponent do
        use AppWeb, :live_component
        def mount(socket), do: {:ok, socket}
        def handle_event("drop", %{"id" => id}, socket) do
          App.Cart.remove_item(socket.assigns.shop, id)
          {:noreply, socket}
        end
      end
      '''

      r =
        analyze(
          [{"lib/cart.ex", @cart}, {"lib/c.ex", controller}, {"lib/lc.ex", component}],
          checks: %{stale_session_write: @writers}
        )

      assert msgs(r, :stale_session_write) == []
    end

    test "is off unless configured" do
      r = analyze([{"lib/cart.ex", @cart}, {"lib/show.ex", page("{:ok, socket}")}])
      assert msgs(r, :stale_session_write) == []
      refute Map.has_key?(r.params.weights, :stale_session_write)
    end

    test "configuration errors fail" do
      files = [{"lib/cart.ex", @cart}]

      assert_raise ArgumentError, ~r/stale_session_write.*writers/, fn ->
        analyze(files,
          checks: %{stale_session_write: [guards: ["AppWeb.CartSession.guard_open_cart"]]}
        )
      end

      assert_raise ArgumentError, ~r/stale_session_write.*only/, fn ->
        analyze(files, checks: %{stale_session_write: [writers: ["App.Cart"], only: ["x"]]})
      end

      assert_raise ArgumentError, ~r/except/, fn ->
        analyze(files,
          checks: %{stale_session_write: [writers: ["App.Cart"], except: [:get_cart]]}
        )
      end
    end
  end

  # Every check the linter knows, so a check added later must be placed in or out of the
  # preset's whitelist by this test failing rather than silently.
  defp all_checks, do: AlaLint.Rules.checks()

  describe "preset :light_ala" do
    test "adopts exactly its whitelist; every other check is off" do
      whitelist = AlaLint.Config.preset_checks(:light_ala)
      r = analyze([{"lib/shop.ex", @shop}], preset: :light_ala)

      assert Enum.sort(r.params.disabled) == Enum.sort(all_checks() -- whitelist)
      assert Enum.all?(whitelist, &(&1 not in r.params.disabled))
    end

    test "the whitelist holds R1–R7's checks and the general ones, not ports, wiring or composition" do
      whitelist = AlaLint.Config.preset_checks(:light_ala)

      for kept <-
            ~w(r1 r1_ref subscribe layer r2 r3 r4 r5 r6 tramp ui_io r7 module_size module_avg
                     passthrough height public_surface clone clone_inside unassigned
                     builder_literals stale_session_write)a,
          do: assert(kept in whitelist, "#{kept} kept")

      for dropped <- ~w(r9 ports ports_unwired ports_computed r10 r10_aggregate r11 r11_share
                        app_share wiring_closure hops vocabulary subcomponent)a,
          do: refute(dropped in whitelist, "#{dropped} off")
    end

    test "a check the whitelist doesn't name is off, whatever check it is" do
      whitelist = AlaLint.Config.preset_checks(:light_ala)
      {:ok, preset} = AlaLint.Config.preset(:light_ala)
      assert preset.off == all_checks() -- whitelist

      assert :some_future_check in AlaLint.Config.preset_off(
               :light_ala,
               all_checks() ++ [:some_future_check]
             )
    end

    test "clone is scored under --strict, R11 is never scored, and app_share is off" do
      files = [{"lib/shop.ex", @shop}]
      r = analyze(files, preset: :light_ala, strict: true)
      assert :clone in r.params.enforce
      assert :app_share in r.params.disabled
      r = analyze(files, preset: :light_ala, super_strict: true)
      assert :r11 in r.params.disabled
    end

    test "the light-ALA checks are scored under the preset when their settings are given" do
      files = [
        {"lib/shop.ex", @shop},
        {"lib/session.ex", @session},
        {"lib/page.ex", @page_with_literal}
      ]

      r = analyze(files, preset: :light_ala, checks: %{builder_literals: @shop_checks})
      assert Enum.any?(r.scored_findings, &(&1.rule == :builder_literals))
      assert r.params.preset == :light_ala

      unconfigured = analyze(files, preset: :light_ala)
      assert findings(unconfigured, :builder_literals) == []
    end

    test "precedence: preset < checks: level < --enforce < --disable; thresholds alone keep the preset level" do
      files = [{"lib/shop.ex", @shop}]

      r = analyze(files, preset: :light_ala, checks: %{r10: :scored})
      refute :r10 in r.params.disabled

      r = analyze(files, preset: :light_ala, checks: %{app_share: [max: 0.5]})
      assert :app_share in r.params.disabled

      r = analyze(files, preset: :light_ala, enforce: [:r9])
      refute :r9 in r.params.disabled
      assert :r9 in r.params.enforce

      r = analyze(files, preset: :light_ala, checks: %{r1: :scored}, disabled: [:r1])
      assert :r1 in r.params.disabled

      r = analyze(files, checks: %{r7: :advisory}, enforce: [:r7])
      assert :r7 in r.params.enforce
    end

    test "an unknown preset fails" do
      assert_raise ArgumentError, ~r/preset.*light_ala/, fn ->
        analyze([{"lib/shop.ex", @shop}], preset: :heavy)
      end

      err =
        assert_raise Mix.Error, ~r/preset/, fn ->
          Mix.Tasks.Ala.Lint.run(["--preset", "heavy", "lib"])
        end

      assert err.mix == 2
    end

    test "a default run echoes no preset" do
      r = analyze([{"lib/shop.ex", @shop}])
      refute Map.has_key?(r.params, :preset)
      refute AlaLint.Report.to_text(r) =~ "preset"
    end
  end

  describe ":not_adopted" do
    test "a rule whose checks are all off is not adopted, and left out of the counts" do
      files = [{"lib/shop.ex", @shop}]
      base = analyze(files)
      r = analyze(files, checks: %{r9: :off, ports: :off})

      assert r.rules.by_rule.r9.state == :not_adopted
      assert r.rules.checked == base.rules.checked - 1
      assert r.rules.met == base.rules.met - 1
      assert r.rules.not_adopted == 1

      text = AlaLint.Report.rules_met_lines(r.rules)
      assert text =~ "R9 not adopted"
      assert text =~ "not adopted (their checks are off): R9"
    end

    test "one check of a rule left on keeps the rule checked" do
      r = analyze([{"lib/shop.ex", @shop}], checks: %{r9: :off})
      assert r.rules.by_rule.r9.state == :met
    end

    test "the preset leaves R9, R10 and R11 not adopted" do
      r = analyze([{"lib/shop.ex", @shop}], preset: :light_ala)

      for rule <- [:r9, :r10, :r11],
          do: assert(r.rules.by_rule[rule].state == :not_adopted, "#{rule}")

      assert r.rules.by_rule.r1.state == :met
    end

    test "a default run has no rule not adopted and its text doesn't mention it" do
      r = analyze([{"lib/shop.ex", @shop}])
      assert r.rules.not_adopted == 0
      refute AlaLint.Report.to_text(r) =~ "not adopted"
    end
  end
end
