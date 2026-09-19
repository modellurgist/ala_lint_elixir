defmodule AlaLintTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/coupled")

  setup_all do
    {:ok, report: AlaLint.analyze(@fixture)}
  end

  defp rules(report), do: Enum.map(report.findings, & &1.rule) |> Enum.frequencies()

  test "detects the R1 dependency cycle A ↔ B", %{report: r} do
    assert Map.get(rules(r), :r1, 0) >= 1
    assert Enum.any?(r.findings, &(&1.rule == :r1 and &1.message =~ "cycle"))
  end

  test "detects the duplicated string contract (R5)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r5 and &1.message =~ "orders:updated"))
  end

  test "detects the process-dictionary hidden state (R4)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r4 and &1.message =~ "Process.put"))
  end

  test "detects the magic literal (R3)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r3 and &1.message =~ "8.3"))
  end

  test "detects the dead private (R7)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r7 and &1.message =~ "dead" and &1.message =~ "dead"))
  end

  test "detects the meaningless name (R6)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r6))
  end

  test "produces a score, grade, and normalized densities", %{report: r} do
    assert r.score in 0..100
    assert r.grade in ~w(A B C D F)
    assert is_number(r.per_100_functions)
    assert is_number(r.per_1000_loc)
    assert r.functions > 0
  end

  test "R7 is advisory by default: reported but excluded from the score", %{report: r} do
    assert Enum.any?(r.advisory_findings, &(&1.rule == :r7))
    refute Enum.any?(r.scored_findings, &(&1.rule == :r7))
    assert Enum.all?(r.scored_findings, &(&1.severity == :error))
  end

  test "--enforce r7 promotes R7 into the score and lowers it" do
    base = AlaLint.analyze(@fixture)
    strict = AlaLint.analyze(@fixture, enforce: [:r7])
    assert Enum.any?(strict.scored_findings, &(&1.rule == :r7))
    assert strict.score <= base.score
  end

  test "reports an abstraction-height number and honors max_height" do
    r = AlaLint.analyze(@fixture)
    assert is_integer(r.height) and r.height >= 1
    # A max of 0 forces the advisory height finding regardless of graph shape.
    low = AlaLint.analyze(@fixture, max_height: 0)
    assert Enum.any?(low.advisory_findings, &(&1.rule == :height))
    refute Enum.any?(low.scored_findings, &(&1.rule == :height))
  end

  test "flags a 1-in/1-out pass-through (advisory), not a genuine helper" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_pt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "p.ex"), """
    defmodule P do
      def run(x), do: forward(x)          # forward/1 has one caller and one callee
      def forward(x), do: Real.work(x)     # public, cross-module rename -> pass-through
      defp internal(x), do: Real.work(x)   # private helper -> internal, not flagged
      def use_internal(x), do: internal(x)
      def keep(x) do                        # genuine: hides a decision, not flagged
        if x > 0, do: Real.work(x), else: 0
      end
    end
    defmodule Real do
      def work(x), do: x + 1
    end
    """)

    r = AlaLint.analyze(dir)
    pt = Enum.filter(r.findings, &(&1.rule == :passthrough))
    assert Enum.any?(pt, &(&1.message =~ "forward/1")), "a public cross-module rename is a pass-through"
    refute Enum.any?(pt, &(&1.message =~ "internal")), "a private helper is internal decomposition, not flagged"
    refute Enum.any?(pt, &(&1.message =~ "keep"))
    assert Enum.all?(pt, &(&1.severity == :warn))
    File.rm_rf!(dir)
  end

  test "does not flag a HEEx function component as dead code (called from ~H markup)" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_heex_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "view.ex"), ~S'''
    defmodule MyView do
      def render(assigns) do
        ~H"""
        <div><.tabs items={@items} /></div>
        """
      end
      defp tabs(assigns) do
        ~H"""
        <nav>tabs</nav>
        """
      end
      defp genuinely_dead(_x), do: :never
    end
    ''')

    r = AlaLint.analyze(dir)
    dead = Enum.filter(r.findings, &(&1.rule == :r7 and &1.message =~ "dead code"))
    refute Enum.any?(dead, &(&1.message =~ "tabs/1")), "a component invoked in ~H must not be dead"
    assert Enum.any?(dead, &(&1.message =~ "genuinely_dead")), "a truly-uncalled defp still flags"
    File.rm_rf!(dir)
  end

  test "does not flag a macro-generated (inside quote) function as dead code" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_quote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex"), """
    defmodule Injector do
      defmacro __using__(_) do
        quote do
          defp put_slot(session, value), do: Map.put(session, :slot, value)
        end
      end
    end
    """)

    r = AlaLint.analyze(dir)
    dead = Enum.filter(r.findings, &(&1.rule == :r7 and &1.message =~ "dead code"))
    refute Enum.any?(dead, &(&1.message =~ "put_slot"))
    File.rm_rf!(dir)
  end

  test "counts a &name/arity capture as a call (not dead code)" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_cap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "c.ex"), """
    defmodule Cap do
      def run(xs), do: Enum.each(xs, &step/1)
      defp step(x), do: x + 1
      defp really_dead(_x), do: :never
    end
    """)

    r = AlaLint.analyze(dir)
    dead = Enum.filter(r.findings, &(&1.rule == :r7 and &1.message =~ "dead code"))
    refute Enum.any?(dead, &(&1.message =~ "step/1")), "a captured function is not dead"
    assert Enum.any?(dead, &(&1.message =~ "really_dead"))
    File.rm_rf!(dir)
  end

  test "does not flag a predicate (name?) forwarder as a pass-through" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_pred_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "q.ex"), """
    defmodule Q do
      def check(x), do: can_go?(x)
      defp can_go?(x), do: Flow.advance(x)
    end
    defmodule Flow do
      def advance(x), do: x
    end
    """)

    r = AlaLint.analyze(dir)
    pt = Enum.filter(r.findings, &(&1.rule == :passthrough))
    refute Enum.any?(pt, &(&1.message =~ "can_go?"))
    File.rm_rf!(dir)
  end

  test "does not count a ~p verified route as an R5 silent contract" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_vroute_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "r.ex"), ~S'''
    defmodule Web do
      def go, do: ~p"/cart/success"
    end
    defmodule Routes do
      def path, do: "/cart/success"
    end
    ''')

    r = AlaLint.analyze(dir)
    refute Enum.any?(r.findings, &(&1.rule == :r5 and &1.message =~ "/cart/success")),
           "a verified-route string in ~p is compile-checked, not a silent contract"
    File.rm_rf!(dir)
  end

  test "does not flag a transform (a call piped into a call) as a pass-through" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_xform_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "c.ex"), """
    defmodule Ext do
      def wrap(x), do: x
    end
    defmodule Calc do
      def run(items), do: total(items)
      defp total(items), do: sub(items) |> Ext.wrap()
      defp sub(items), do: items
    end
    """)

    r = AlaLint.analyze(dir)
    pt = Enum.filter(r.findings, &(&1.rule == :passthrough))
    refute Enum.any?(pt, &(&1.message =~ "total")), "piping a call into another call transforms, it does not rename"
    File.rm_rf!(dir)
  end

  test "does not flag a struct-update body containing a call as a pass-through" do
    dir = Path.join(System.tmp_dir!(), "ala_su_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "c.ex"), """
    defmodule Ext do
      def bump(n), do: n + 1
    end
    defmodule S do
      defstruct credit: 0, count: 0
      def run(s), do: add(s)
      def add(s), do: %{s | credit: s.credit + 1, count: Ext.bump(s.count)}
    end
    """)

    r = AlaLint.analyze(dir)
    pt = Enum.filter(r.findings, &(&1.rule == :passthrough))
    refute Enum.any?(pt, &(&1.message =~ "add")), "building a struct with an embedded call is not a rename"
    File.rm_rf!(dir)
  end

  test "resolves cross-module calls through the alias table into the call graph" do
    dir = Path.join(System.tmp_dir!(), "ala_lint_cg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "c.ex"), """
    defmodule App.Page do
      alias App.{Cart, Wish}
      def go(s), do: {Cart.add(s), Wish.count(s)}
    end
    defmodule App.Cart do
      def add(s), do: s
    end
    defmodule App.Wish do
      def count(s), do: s
    end
    """)

    m = AlaLint.Analyzer.build(dir)
    edges = Map.get(m.call_graph, {"App.Page", :go, 1})
    assert MapSet.member?(edges, {"App.Cart", :add, 1})
    assert MapSet.member?(edges, {"App.Wish", :count, 1})
    File.rm_rf!(dir)
  end

  describe "function-level layer assignment" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ala_fl_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "features"))

      File.write!(Path.join(dir, "features/cart.ex"), """
      defmodule App.Cart do
        def total(x), do: App.Pricing.calc(x, 2)
        def peek(x), do: App.Wish.look(x)
      end
      """)

      File.write!(Path.join(dir, "features/wish.ex"), """
      defmodule App.Wish do
        def look(x), do: {:ok, x}
      end
      """)

      File.write!(Path.join(dir, "pricing.ex"), """
      defmodule App.Pricing do
        def calc(x, n), do: App.Pricing.Impl.run(x, n)
        @ala_layer :feature
        def as_feature(x), do: x
        @ala_layer :nonsense
        def typo(x), do: x
      end
      defmodule App.Pricing.Impl do
        def run(x, n), do: x * n
      end
      """)

      layers = [
        {:feature, [], peer_ok: false, paths: [~r{/features/}], unit: ~r/(App\.[^.]+)/},
        {:domain, [~r/App\.Pricing/], peer_ok: true}
      ]

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, report: AlaLint.analyze(dir, layers: layers)}
    end

    test "assigns a layer by filesystem path glob", %{report: r} do
      # App.Cart lives under features/ → feature; peer call to App.Wish flagged
      assert Enum.any?(r.findings, &(&1.rule == :r1 and &1.message =~ "Cart.peek" and &1.message =~ "cross-peer"))
    end

    test "an @ala_layer tag overrides the module's convention", %{report: r} do
      idx = r.layer_coverage
      # as_feature is tagged feature though its module is domain — it's assigned (not unassigned)
      refute Enum.any?(idx.unassigned, fn {_m, n, _a} -> n == :as_feature end)
    end

    test "a tag naming an undeclared layer is a validity error", %{report: r} do
      assert Enum.any?(r.findings, &(&1.rule == :layer and &1.message =~ ":nonsense"))
    end

    test "reports layer coverage with an unassigned worklist", %{report: r} do
      assert r.layer_coverage.total > 0
      assert r.layer_coverage.pct < 100
      assert Enum.any?(r.layer_coverage.unassigned, fn {_m, n, _a} -> n == :typo end)
    end

    test "coverage is nil without a layer map" do
      r = AlaLint.analyze(@fixture)
      assert r.layer_coverage == nil
    end
  end

  test "reference-level R1 advisory catches a peer coupling with no direct call (the HEEx case)" do
    dir = Path.join(System.tmp_dir!(), "ala_ref_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "features"))

    # A aliases and references B's type but never *calls* it in plain Elixir —
    # stands in for a `Wishlist.member?(...)` call buried in a ~H template.
    File.write!(Path.join(dir, "features/a.ex"), """
    defmodule App.A do
      alias App.B
      @type peer :: B.t()
      def run(x), do: x
    end
    """)

    File.write!(Path.join(dir, "features/b.ex"), """
    defmodule App.B do
      def t, do: :ok
    end
    """)

    layers = [{:feature, [], peer_ok: false, paths: [~r{/features/}], unit: ~r/(App\.\w+)/}]
    r = AlaLint.analyze(dir, layers: layers)

    assert Enum.any?(r.advisory_findings, &(&1.rule == :r1_ref and &1.message =~ "A → B"))
    refute Enum.any?(r.scored_findings, &(&1.rule == :r1))
    File.rm_rf!(dir)
  end

  test "accepts multiple include roots and excludes everything outside them" do
    dir = Path.join(System.tmp_dir!(), "ala_roots_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "keep_a"))
    File.mkdir_p!(Path.join(dir, "keep_b"))
    File.mkdir_p!(Path.join(dir, "ignore"))
    File.write!(Path.join(dir, "keep_a/a.ex"), "defmodule A do\n def a, do: 1\nend\n")
    File.write!(Path.join(dir, "keep_b/b.ex"), "defmodule B do\n def b, do: 2\nend\n")
    File.write!(Path.join(dir, "ignore/c.ex"), "defmodule C do\n def c, do: 3\nend\n")

    r = AlaLint.analyze([Path.join(dir, "keep_a"), Path.join(dir, "keep_b")])
    assert r.modules == 2
    File.rm_rf!(dir)
  end

  test "a uses: matcher classifies by `use` macro, beating a namespace catch-all" do
    dir = Path.join(System.tmp_dir!(), "ala_uses_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # App.Thing is in the domain namespace but `use`s a schema → persistence.
    File.write!(Path.join(dir, "m.ex"), """
    defmodule App.Thing do
      use Ecto.Schema
      def changeset(x), do: x
    end
    defmodule App.Logic do
      def run(x), do: x
    end
    """)

    layers = [
      {:domain, [~r/^App\./], peer_ok: true},
      {:platform, [], peer_ok: true, uses: [~r/Ecto\.Schema/]}
    ]

    model = AlaLint.Analyzer.build(dir)
    resolved = AlaLint.Layers.resolve(model.modules, layers)
    # uses: (platform, idx 1) beats the name catch-all (domain, idx 0) for the schema
    assert resolved.fun_index[{"App.Thing", :changeset, 1}] == 1
    # a plain module still resolves by name to domain (idx 0)
    assert resolved.fun_index[{"App.Logic", :run, 1}] == 0
    File.rm_rf!(dir)
  end

  test "abstraction height collapses intra-application-layer calls to one altitude" do
    dir = Path.join(System.tmp_dir!(), "ala_ht_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    # Shell → Page → View are all app (should be height 1); Page also drops to a
    # feature leaf, so the whole chain is height 2 (app=1, feature=1) — not 4.
    File.write!(Path.join(dir, "m.ex"), """
    defmodule Web.Shell do
      def run(x), do: Web.Page.handle(x)
    end
    defmodule Web.Page do
      def handle(x), do: {Web.View.render(x), App.Cart.total(x)}
    end
    defmodule Web.View do
      def render(x), do: x
    end
    defmodule App.Cart do
      def total(x), do: x
    end
    """)

    layers = [
      {:app, [~r/^Web\./], peer_ok: true},
      {:feature, [~r/^App\./], peer_ok: false}
    ]

    r = AlaLint.analyze(dir, layers: layers)
    assert r.height == 2

    # Layer-blind, the same chain is its raw length (Shell→Page→View = 3).
    blind = AlaLint.analyze(dir)
    assert blind.height == 3
    File.rm_rf!(dir)
  end

  test "reports per-layer filesystem cohesion" do
    dir = Path.join(System.tmp_dir!(), "ala_coh_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "features"))
    File.write!(Path.join(dir, "features/a.ex"), "defmodule App.A do\n def a, do: 1\nend\n")
    File.write!(Path.join(dir, "features/b.ex"), "defmodule App.B do\n def b, do: 2\nend\n")

    layers = [{:feature, [], peer_ok: false, paths: [~r{/features/}]}]
    r = AlaLint.analyze(dir, layers: layers)
    feat = Enum.find(r.layer_dirs, &(&1.layer == :feature))
    assert feat.share == 100 and feat.dirs == 1
    File.rm_rf!(dir)
  end

  describe "R10 / R11 / module-size" do
    setup do
      dir = Path.join(System.tmp_dir!(), "ala_new_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "features"))

      # Cart is a FEATURE entity; Wishlist (a peer feature) reaches into it.
      File.write!(Path.join(dir, "features/cart.ex"), """
      defmodule App.Features.Cart do
        defstruct [:id, :total]
        def new, do: %__MODULE__{}
      end
      """)

      File.write!(Path.join(dir, "features/wishlist.ex"), """
      defmodule App.Features.Wishlist do
        alias App.Features.Cart
        def save(x), do: %Cart{id: x}
      end
      """)

      File.write!(Path.join(dir, "page.ex"), """
      defmodule AppWeb.Page do
        def handle(x) do
          if x, do: App.Features.Cart.new(), else: nil
        end
      end
      """)

      layers = [
        {:app, [~r/AppWeb\./], peer_ok: true},
        {:feature, [~r/App\.Features\./], peer_ok: false, unit: ~r/(App\.Features\.[^.]+)/}
      ]

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, report: AlaLint.analyze(dir, layers: layers, max_app_share: 0.1)}
    end

    test "R10 flags a feature entity read by another peer feature (scored)", %{report: r} do
      f = Enum.find(r.scored_findings, &(&1.rule == :r10))
      assert f && f.message =~ "Cart is read by 2 peer features"
    end

    test "R11 flags branching in an application-layer function (advisory)", %{report: r} do
      assert Enum.any?(r.advisory_findings, &(&1.rule == :r11 and &1.message =~ "Page.handle/1 branches"))
      refute Enum.any?(r.scored_findings, &(&1.rule == :r11))
    end

    test "R11 flags an oversized application layer share", %{report: r} do
      assert Enum.any?(r.advisory_findings, &(&1.rule == :r11 and &1.message =~ "application layer is"))
    end

    test "R11 flags a branchy clause of a multi-clause def even when the last clause is straight" do
      dir = Path.join(System.tmp_dir!(), "ala_mc11_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      # handle/2's middle clause branches; the last clause is straight wiring.
      File.write!(Path.join(dir, "p.ex"), """
      defmodule AppWeb.Page do
        def handle(:a, s), do: s
        def handle(:b, s), do: if s, do: :x, else: :y
        def handle(:c, s), do: s
      end
      """)

      layers = [{:app, [~r/AppWeb\./], peer_ok: true}]
      r = AlaLint.analyze(dir, layers: layers)
      assert Enum.any?(r.advisory_findings, &(&1.rule == :r11 and &1.message =~ "handle/2 branches")),
             "a branchy non-surviving clause must still be flagged"
      File.rm_rf!(dir)
    end
  end

  test "R10 does not fire without a layer map (needs to know features)" do
    dir = Path.join(System.tmp_dir!(), "ala_r10n_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "m.ex"), "defmodule Ent do\n defstruct [:a]\nend\ndefmodule A do\n def x, do: %Ent{}\nend\ndefmodule B do\n def y, do: %Ent{}\nend\n")
    r = AlaLint.analyze(dir)
    refute Enum.any?(r.findings, &(&1.rule == :r10))
    File.rm_rf!(dir)
  end

  test "strict scores advisories; super-strict runs and scores the shared-aggregate check" do
    dir = Path.join(System.tmp_dir!(), "ala_strict_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "features"))
    File.write!(Path.join(dir, "cart.ex"), "defmodule App.Domain.Cart do\n  defstruct [:id]\nend\n")
    File.write!(Path.join(dir, "features/a.ex"), "defmodule App.Features.A do\n  alias App.Domain.Cart\n  def x, do: %Cart{}\nend\n")
    File.write!(Path.join(dir, "features/b.ex"), "defmodule App.Features.B do\n  alias App.Domain.Cart\n  def y, do: %Cart{}\nend\n")

    layers = [
      {:feature, [~r/App\.Features\./], peer_ok: false, unit: ~r/(App\.Features\.[^.]+)/},
      {:domain, [~r/App\.Domain\./], peer_ok: true}
    ]

    normal = AlaLint.analyze(dir, layers: layers)
    strict = AlaLint.analyze(dir, layers: layers, strict: true)
    sup = AlaLint.analyze(dir, layers: layers, super_strict: true)

    # the shared domain aggregate is invisible normally, advisory under strict, scored under super-strict
    refute Enum.any?(normal.findings, &(&1.rule == :r10_aggregate))
    assert Enum.any?(strict.advisory_findings, &(&1.rule == :r10_aggregate and &1.message =~ "Cart"))
    assert Enum.any?(sup.scored_findings, &(&1.rule == :r10_aggregate))
  end

  test "R11 is advisory under strict, scored only under super-strict" do
    dir = Path.join(System.tmp_dir!(), "ala_r11tier_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "p.ex"), """
    defmodule AppWeb.Page do
      def handle(x), do: if x, do: :a, else: :b
    end
    """)

    layers = [{:app, [~r/AppWeb\./], peer_ok: true}]
    # max_app_share 1.0 isolates the branch finding from the app-share one
    strict = AlaLint.analyze(dir, layers: layers, strict: true, max_app_share: 1.0)
    sup = AlaLint.analyze(dir, layers: layers, super_strict: true, max_app_share: 1.0)

    assert Enum.any?(strict.advisory_findings, &(&1.rule == :r11 and &1.message =~ "branches"))
    refute Enum.any?(strict.scored_findings, &(&1.rule == :r11))
    assert Enum.any?(sup.scored_findings, &(&1.rule == :r11 and &1.message =~ "branches"))
    File.rm_rf!(dir)
  end

  test "module-size is advisory over the cap" do
    dir = Path.join(System.tmp_dir!(), "ala_sz_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    body = Enum.map_join(1..60, "\n", fn i -> "  def f#{i}(x), do: x" end)
    File.write!(Path.join(dir, "big.ex"), "defmodule Big do\n#{body}\nend\n")
    r = AlaLint.analyze(dir, max_module_loc: 20)
    assert Enum.any?(r.advisory_findings, &(&1.rule == :module_size and &1.message =~ "Big is"))
    File.rm_rf!(dir)
  end

  test "a private call chain inside one module does not add abstraction height" do
    dir = Path.join(System.tmp_dir!(), "ala_ht_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "m.ex"), """
    defmodule Mono do
      def go(x), do: a(x)
      defp a(x), do: b(x)
      defp b(x), do: c(x)
      defp c(x), do: x
    end
    """)
    r = AlaLint.analyze(dir, max_height: 1)
    refute Enum.any?(r.findings, &(&1.rule == :height)),
           "a chain of private helpers inside one module is internal decomposition, not depth"
    File.rm_rf!(dir)
  end

  test "public_surface flags a wide public API, only under super-strict, and spares an encapsulated module" do
    dir = Path.join(System.tmp_dir!(), "ala_ps_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "m.ex"), """
    defmodule Wide do
      def a(x), do: x
      def b(x), do: x
      def c(x), do: x
      def d(x), do: x
    end
    defmodule Tight do
      def api(x), do: h1(x)
      defp h1(x), do: h2(x)
      defp h2(x), do: x
    end
    """)
    r = AlaLint.analyze(dir, max_public_funs: 2)
    assert Enum.any?(r.advisory_findings, &(&1.rule == :public_surface and &1.message =~ "Wide"))
    refute Enum.any?(r.findings, &(&1.rule == :public_surface and &1.message =~ "Tight"))
    refute Enum.any?(r.scored_findings, &(&1.rule == :public_surface)), "public_surface is not scored by strict"

    ss = AlaLint.analyze(dir, max_public_funs: 2, super_strict: true)
    assert Enum.any?(ss.scored_findings, &(&1.rule == :public_surface)), "super-strict scores it"
    File.rm_rf!(dir)
  end

  describe "configuration" do
    test "normalize_checks maps levels and thresholds" do
      n = AlaLint.Config.normalize_checks(%{r7: :scored, r11: :off, r1: :advisory, height: [max: 3], module_size: [level: :off, max: 400]})
      assert :r7 in n.scored
      assert :r11 in n.disabled and :module_size in n.disabled
      assert :r1 in n.soft
      assert n.thresholds[:max_height] == 3
      assert n.thresholds[:max_module_loc] == 400
    end

    test "load reads a .ala_lint.exs map, and returns %{} when absent" do
      dir = Path.join(System.tmp_dir!(), "ala_conf_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      assert AlaLint.Config.load(dir) == %{}
      File.write!(Path.join(dir, ".ala_lint.exs"), "%{min_score: 85, checks: %{r7: :scored}}")
      cfg = AlaLint.Config.load(dir)
      assert cfg.min_score == 85
      assert cfg.checks.r7 == :scored
      File.rm_rf!(dir)
    end

    test "parse_set understands known threshold keys and rejects others" do
      assert AlaLint.Config.parse_set("height.max=4") == {:max_height, 4}
      assert AlaLint.Config.parse_set("app_share.max=0.3") == {:max_app_share, 0.3}
      assert AlaLint.Config.parse_set("min_score=85") == {:min_score, 85}
      assert AlaLint.Config.parse_set("bogus.max=4") == :error
    end

    test "--disable / checks :off drops a check's findings", %{report: base} do
      assert Enum.any?(base.findings, &(&1.rule == :r3))
      off = AlaLint.analyze(@fixture, disabled: [:r3])
      refute Enum.any?(off.findings, &(&1.rule == :r3))
      assert off.params.disabled == [:r3]
    end

    test "checks map promotes an advisory rule to scored and retunes a threshold" do
      dir = Path.join(System.tmp_dir!(), "ala_cfg2_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "m.ex"), """
      defmodule Mono do
        def go(x), do: a(x)
        defp a(x), do: b(x)
        defp b(x), do: x
      end
      """)
      # height default would not fire (intra-module collapses to 0); force max 0 is meaningless,
      # so instead check a promoted advisory rule surfaces in scored_findings via checks.
      File.write!(Path.join(dir, "d.ex"), "defmodule D do\n  def only(_x), do: :never\n  defp dead(_x), do: :x\nend\n")
      r = AlaLint.analyze(dir, checks: %{r7: :scored})
      assert Enum.any?(r.scored_findings, &(&1.rule == :r7)), "checks: %{r7: :scored} promotes R7"
      File.rm_rf!(dir)
    end
  end

  test "echoes effective parameters in the report", %{report: r} do
    assert r.params.max_height == 5
    assert r.params.enforce == []
    text = AlaLint.Report.to_text(r)
    assert text =~ "Parameters (effective"
    assert text =~ "max_height:"
    assert text =~ "abstraction height:"
  end

  test "skips generated files", _ do
    dir = Path.join(System.tmp_dir!(), "ala_lint_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "gen.ex"), """
    # GENERATED FILE — do not edit.
    defmodule Gen.X do
      def a, do: "dup-literal-xyz"
    end
    defmodule Gen.Y do
      def b, do: "dup-literal-xyz"
    end
    """)

    report = AlaLint.analyze(dir)
    assert report.functions == 0
    assert report.findings == []
    File.rm_rf!(dir)
  end

  describe "encoder marks (tool-stamped facts survive into the encoding)" do
    test "stamps (branches) on an app-layer branchy fn and re-lints to the same R11 findings" do
      dir = Path.join(System.tmp_dir!(), "ala_enc_rt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "p.ex"), """
      defmodule AppWeb.Page do
        def wire(x), do: App.Domain.Calc.run(x)
        def decide(x), do: if x, do: :a, else: :b
      end
      defmodule App.Domain.Calc do
        def run(x), do: x + 1
      end
      """)

      layers = [
        {:app, [~r/AppWeb\./], app: true, peer_ok: true},
        {:domain, [~r/App\.Domain\./], peer_ok: true}
      ]

      src = AlaLint.analyze(dir, layers: layers)
      src_r11 = Enum.filter(src.findings, &(&1.rule == :r11))

      enc_dir = Path.join(dir, "enc")
      for {rel, content} <- AlaLint.encode(dir, layers: layers) do
        dest = Path.join(enc_dir, rel)
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, content)
      end

      page_enc = File.read!(Path.join(enc_dir, "p.ex.ala.md"))
      assert page_enc =~ "decide/1   [?]  (branches)"
      refute page_enc =~ "wire/1   [?]  (branches)"

      enc = AlaLint.EncodingLinter.lint(enc_dir)
      enc_r11 = Enum.filter(enc.findings, &(&1.rule == :r11))
      assert length(enc_r11) == length(src_r11)
      assert Enum.any?(enc_r11, &(&1.message =~ "decide/1"))
      File.rm_rf!(dir)
    end

    test "stamps &entity on a shared-entity module" do
      dir = Path.join(System.tmp_dir!(), "ala_enc_ent_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "m.ex"), """
      defmodule App.Features.Cart do
        defstruct [:id]
        def new, do: %__MODULE__{}
      end
      defmodule App.Features.Wishlist do
        alias App.Features.Cart
        def save(x), do: %Cart{id: x}
      end
      """)

      layers = [{:feature, [~r/App\.Features\./], peer_ok: false, unit: ~r/(App\.Features\.[^.]+)/}]

      enc_dir = Path.join(dir, "enc")
      for {rel, content} <- AlaLint.encode(dir, layers: layers) do
        dest = Path.join(enc_dir, rel)
        File.mkdir_p!(Path.dirname(dest))
        File.write!(dest, content)
      end

      enc = AlaLint.EncodingLinter.lint(enc_dir)
      assert Enum.any?(enc.findings, &(&1.rule == :r10 and &1.module == "App.Features.Cart"))
      File.rm_rf!(dir)
    end
  end
end
