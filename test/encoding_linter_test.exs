defmodule EncodingLinterTest do
  use ExUnit.Case, async: true

  @dir Path.join(System.tmp_dir!(), "ala_enc_lint_#{System.unique_integer([:positive])}")

  setup_all do
    File.mkdir_p!(@dir)

    File.write!(Path.join(@dir, "good.ex.ala.md"), """
    module App.Page   [app]
      f Page.new/1   [app]
      f Page.go/2   [app]
      depends on:
        → Cart [feature]   drops ✓
    """)

    File.write!(Path.join(@dir, "bad.ex.ala.md"), """
    module App.Features.Wish   [feature]
      f Wish.run/1   [feature]
      depends on:
        → App.Page [app]   ⚠ UP — knowledge flows up (R1)
        → App.Features.Cart [feature]   ⚠ PEER — feature↔feature coupling (R1)
      $ get, put   -- VERIFY: hidden channel, or legit instance state? (R4)
      q "cart:updated"   -- VERIFY: silent contract to single-source? (R5)
    """)

    File.write!(Path.join(@dir, "incomplete.ex.ala.md"), """
    module App.Thing   [?]
      f Thing.do/1   [?]
      depends on:
        → Helper [?]   (verify: does this drop?)
    """)

    {:ok, report: AlaLint.EncodingLinter.lint(@dir)}
  end

  test "counts modules and functions from the notation", %{report: r} do
    assert r.modules == 3
    assert r.functions == 4
  end

  test "flags an upward edge and a peer edge as R1", %{report: r} do
    r1 = Enum.filter(r.findings, &(&1.rule == :r1))
    assert Enum.any?(r1, &(&1.message =~ "upward"))
    assert Enum.any?(r1, &(&1.message =~ "cross-peer"))
  end

  test "flags $ as R4 and q as R5", %{report: r} do
    assert Enum.any?(r.findings, &(&1.rule == :r4))
    assert Enum.any?(r.findings, &(&1.rule == :r5))
  end

  test "does not flag a dropping edge", %{report: r} do
    refute Enum.any?(r.findings, &(&1.message =~ "Cart [feature]   drops"))
  end

  test "reports unresolved tags and edges as incomplete, not violations", %{report: r} do
    assert Enum.any?(r.incomplete, &(&1.message =~ "unresolved [?] semantic tag"))
    assert Enum.any?(r.incomplete, &(&1.message =~ "not resolved"))
    refute Enum.any?(r.findings, &(&1.message =~ "verify"))
  end

  test "parses @level edges and still detects an upward drop" do
    dir = Path.join(System.tmp_dir!(), "ala_lvl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Feature   [?]  @feature-L1
      f App.Feature.run/1   [?]
      depends on:
        → App.Domain @domain-L2   drops ✓
        → App.Web @app-L0   ⚠ UP — knowledge flows up (R1)
    """)

    r = AlaLint.EncodingLinter.lint(dir)

    assert Enum.any?(
             r.findings,
             &(&1.rule == :r1 and &1.message =~ "upward" and &1.message =~ "App.Web")
           )

    refute Enum.any?(r.findings, &(&1.message =~ "App.Domain"))
    File.rm_rf!(dir)
  end

  test "literal marks: {app-literal?} incomplete, {app-literal} R3, {intrinsic-literal} resolved" do
    dir = Path.join(System.tmp_dir!(), "ala_cfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Feat   [feature]
      f App.Feat.a/1   [feature]   {app-literal?}
      f App.Feat.b/1   [feature]   {app-literal}
      f App.Feat.c/1   [feature]   {intrinsic-literal}
    """)

    r = AlaLint.EncodingLinter.lint(dir)
    assert Enum.any?(r.incomplete, &(&1.message =~ "a/1 has {app-literal?}"))
    assert Enum.any?(r.findings, &(&1.rule == :r3 and &1.message =~ "b/1"))
    refute Enum.any?(r.findings, &(&1.message =~ "c/1"))
    refute Enum.any?(r.incomplete, &(&1.message =~ "c/1"))
    File.rm_rf!(dir)
  end

  test "{app-literal} at level 0 (the config tier) is not an R3 violation" do
    dir = Path.join(System.tmp_dir!(), "ala_cfg0_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Top   [wiring]  @app-L0
      f App.Top.new/1   [wiring]   {app-literal}
    module App.Low   [domain]  @domain-L2
      f App.Low.x/1   [domain]   {app-literal}
    """)

    r = AlaLint.EncodingLinter.lint(dir)
    refute Enum.any?(r.findings, &(&1.rule == :r3 and &1.message =~ "new/1"))
    assert Enum.any?(r.findings, &(&1.rule == :r3 and &1.message =~ "x/1"))
    File.rm_rf!(dir)
  end

  test "&entity is R10, &aggregate is R10 aggregate" do
    dir = Path.join(System.tmp_dir!(), "ala_ent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Shared   [domain]  @domain-L1   &entity
      f App.Shared.a/1   [domain]
    module App.Wide   [domain]  @domain-L1   &aggregate
      f App.Wide.b/1   [domain]
    """)

    r = AlaLint.EncodingLinter.lint(dir)
    assert Enum.any?(r.findings, &(&1.rule == :r10 and &1.module == "App.Shared"))
    assert Enum.any?(r.findings, &(&1.rule == :r10_aggregate and &1.module == "App.Wide"))
    File.rm_rf!(dir)
  end

  test "~> is a pass-through and (branches) is R11" do
    dir = Path.join(System.tmp_dir!(), "ala_pt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Top   [wiring]  @app-L0
      f App.Top.run/1   [wiring]  (branches)
      f App.Top.fwd/1   [wiring]  ~>
    """)

    r = AlaLint.EncodingLinter.lint(dir)

    assert Enum.any?(
             r.findings,
             &(&1.rule == :r11 and &1.message =~ "run/1" and &1.message =~ "branches")
           )

    assert Enum.any?(r.findings, &(&1.rule == :passthrough and &1.message =~ "fwd/1"))
    File.rm_rf!(dir)
  end

  test "counts public surface, exempting (private) functions" do
    dir = Path.join(System.tmp_dir!(), "ala_surf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    pubs = for i <- 1..13, do: "  f App.Big.f#{i}/0   [domain]"

    File.write!(
      Path.join(dir, "big.ex.ala.md"),
      "module App.Big   [domain]  @domain-L1\n" <> Enum.join(pubs, "\n") <> "\n"
    )

    File.write!(Path.join(dir, "small.ex.ala.md"), """
    module App.Small   [domain]  @domain-L1
      f App.Small.pub/0   [domain]
      f App.Small.h1/0 (private)   [domain]
      f App.Small.h2/0 (private)   [domain]
    """)

    r = AlaLint.EncodingLinter.lint(dir)
    assert Enum.any?(r.findings, &(&1.rule == :public_surface and &1.module == "App.Big"))
    refute Enum.any?(r.findings, &(&1.rule == :public_surface and &1.module == "App.Small"))
    File.rm_rf!(dir)
  end

  test "flags the R11 app-share aggregate from level-0 function share" do
    dir = Path.join(System.tmp_dir!(), "ala_share_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "m.ex.ala.md"), """
    module App.Top   [wiring]  @app-L0
      f App.Top.a/1   [wiring]
      f App.Top.b/1   [wiring]
    module App.Low   [domain]  @domain-L1
      f App.Low.c/1   [domain]
    """)

    r = AlaLint.EncodingLinter.lint(dir)

    assert Enum.any?(
             r.findings,
             &(&1.rule == :r11 and &1.module == "(project)" and
                 &1.message =~ "application layer is 67%")
           )

    File.rm_rf!(dir)
  end
end
