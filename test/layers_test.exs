defmodule LayersTest do
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "ala_lint_layers_#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(Path.join(@dir, "lib"))
    File.write!(Path.join(@dir, "lib/mods.ex"), """
    defmodule App.Page do            # top layer (composition) — config lives here
      def go(x), do: App.Features.Wish.run(x)         # drops app→feature ✓
      def rate, do: 599                                # calibration in composition ✓ (not flagged)
    end
    defmodule App.Features.Wish do   # feature layer
      def run(x), do: App.Features.Cart.help(x)        # feature→feature PEER ✗ (R1)
      def bad(x), do: App.Page.go(x)                   # feature→app UPWARD ✗ (R1)
      def dropped(x), do: App.Domain.Calc.call(x)      # feature→domain ✓
    end
    defmodule App.Features.Cart do
      def help(x), do: x
    end
    defmodule App.Domain.Calc do     # domain layer
      def call(x), do: x * 83                          # magic literal in domain ✗ (R3 layer-aware)
    end
    """)

    layers = [
      {:app, ["App.Page"], peer_ok: true},
      {:feature, [~r/App\.Features\./], peer_ok: false},
      {:domain, [~r/App\.Domain\./], peer_ok: true}
    ]

    {:ok, report: AlaLint.analyze(Path.join(@dir, "lib"), layers: layers)}
  end

  test "flags an upward edge (feature → app)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r1 and &1.message =~ "flows UP"))
  end

  test "flags a feature-peer edge (feature → feature)", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r1 and &1.message =~ "cross-peer"))
  end

  test "does NOT flag a dropping edge (app → feature, feature → domain)", %{report: r} do
    refute Enum.any?(r.findings, &(&1.rule == :r1 and &1.message =~ "Domain"))
  end

  test "R3 flags calibration in the domain layer but not in the composition", %{report: r} do
    r3 = Enum.filter(r.findings, &(&1.rule == :r3))
    assert Enum.any?(r3, &(&1.message =~ "83"))          # domain magic literal flagged
    refute Enum.any?(r3, &(&1.message =~ "599"))         # composition literal allowed
  end

  describe "load/1 resolves a project-level layer spec" do
    test "an explicit :layers opt wins" do
      spec = [{:app, ["Foo"], peer_ok: true}]
      assert AlaLint.Layers.load(layers: spec) == spec
    end

    test "a :layers_module opt calls the module's layers/0" do
      assert AlaLint.Layers.load(layers_module: LayersTest.SampleLayers) ==
               LayersTest.SampleLayers.layers()
    end

    test "the :ala_lint app env is a fallback" do
      Application.put_env(:ala_lint, :layers_module, LayersTest.SampleLayers)
      on_exit(fn -> Application.delete_env(:ala_lint, :layers_module) end)
      assert AlaLint.Layers.load([]) == LayersTest.SampleLayers.layers()
    end

    test "returns nil when nothing is configured" do
      assert AlaLint.Layers.load([]) == nil
    end
  end
end

defmodule LayersTest.SampleLayers do
  def layers, do: [{:app, [~r/Web\./], peer_ok: true}, {:feature, [~r/Feature/], peer_ok: false}]
end
