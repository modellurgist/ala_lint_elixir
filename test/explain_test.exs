defmodule ExplainTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias AlaLint.Explain

  @scored "SCORED IN THIS RUN"
  @reported "REPORTED, NOT SCORED"
  @judged "APPLIES, BUT NOT MACHINE-CHECKED"

  defp section(text, heading) do
    [_, rest] = String.split(text, heading <> "\n", parts: 2)
    rest |> String.split(~r/\n(?=[A-Z][A-Z ,-]+\n)|\nNot adopted in this run/, parts: 2) |> hd()
  end

  defp lists?(section, check), do: section =~ ~r/^\s{4,}#{check}\s{2,}/m
  defp rule?(section, rule), do: section =~ ~r/^  #{rule} /m

  test "the default tier scores R1–R10's required checks and reports R7 and R11" do
    text = Explain.to_text([])
    scored = section(text, @scored)
    reported = section(text, @reported)

    for check <- ~w(r1 layer r2 r3 r4 r5 r6 r9 r10), do: assert(lists?(scored, check), check)
    for rule <- ~w(R1 R2 R3 R4 R5 R6 R9 R10), do: assert(rule?(scored, rule), rule)
    refute rule?(scored, "R11")
    refute rule?(scored, "R7")

    for check <- ~w(r7 clone height passthrough tramp r1_ref r11 subcomponent public_surface),
        do: assert(lists?(reported, check), check)

    assert rule?(reported, "R11")
    refute lists?(scored, "r11")
    assert text =~ "Not adopted in this run: none"
  end

  test "--strict scores the obtainable advisories and keeps R11 reported" do
    text = Explain.to_text(strict: true)
    scored = section(text, @scored)
    reported = section(text, @reported)

    for check <- ~w(r7 clone height passthrough tramp r1_ref subscribe module_size r10_aggregate),
        do: assert(lists?(scored, check), check)

    assert lists?(reported, "r11")
    assert lists?(reported, "public_surface")
    refute lists?(reported, "r7")

    assert lists?(section(Explain.to_text(super_strict: true), @scored), "r11")
  end

  test "r10_aggregate is listed only where it runs, from --strict up" do
    refute Explain.to_text([]) =~ "r10_aggregate"
  end

  test "light_ala leaves R9–R11 out but for one line, and lists the light-ALA conventions" do
    text = Explain.to_text(preset: :light_ala)
    [body, tail] = String.split(text, "Not adopted in this run:", parts: 2)

    assert tail =~ ~r/^ R9, R10, R11\n?$/
    refute body =~ ~r/\bR(9|10|11)\b/

    for check <- ~w(ports ports_unwired wiring_closure hops vocabulary r11_share app_share),
        do: refute(lists?(body, check), check)

    judged = section(text, @judged)
    assert judged =~ "a checklist reading for light ALA, not Spray's ALA"
    for n <- [5, 6, 8, 9, 10, 11, 12], do: assert(judged =~ ~r/^\s+rule #{n}\s/m, "rule #{n}")
  end

  test "under light_ala, configured rule-11 and rule-12 checks are scored, not left to a reader" do
    checks = %{
      builder_literals: [structs: ["App.Shop"]],
      stale_session_write: [writers: ["App.Cart"]]
    }

    text = Explain.to_text(preset: :light_ala, strict: true, checks: checks)
    assert lists?(section(text, @scored), "builder_literals")
    assert lists?(section(text, @scored), "stale_session_write")
    refute section(text, @judged) =~ ~r/^\s+rule 1[12]\s/m
    assert section(text, @judged) =~ ~r/^\s+rule 10\s/m
  end

  test "a file checks: setting and --disable change the listing" do
    text = Explain.to_text(checks: %{r7: :scored, r3: :off})
    assert lists?(section(text, @scored), "r7")
    refute text =~ ~r/^\s+r3\s{2,}/m
    assert rule?(section(text, @scored), "R3") == false

    text = Explain.to_text(disabled: [:r6, :tramp, :ui_io])
    assert text =~ "Not adopted in this run: R6"
    refute text =~ ~r/^  R6 /m

    text = Explain.to_text(checks: %{r3: :advisory})
    assert lists?(section(text, @reported), "r3")
    refute lists?(section(text, @scored), "r3")
  end

  test "--enforce scores one check, and a later --disable wins over it" do
    assert lists?(section(Explain.to_text(enforce: [:r11]), @scored), "r11")
    refute Explain.to_text(enforce: [:r11], disabled: [:r11]) =~ ~r/^\s+r11\s{2,}/m
  end

  test "the not-machine-checked section always includes R8" do
    for opts <- [
          [],
          [preset: :light_ala],
          [super_strict: true],
          [disabled: AlaLint.Rules.checks()]
        ] do
      assert section(Explain.to_text(opts), @judged) =~ ~r/^  R8 /m, inspect(opts)
    end
  end

  test "every check has a line to explain it" do
    for check <- AlaLint.Rules.checks(), do: assert(Explain.describes?(check), "#{check}")
  end

  test "the default output stays short, and light ALA's shorter" do
    default = Explain.to_text([]) |> String.split("\n") |> length()
    light = Explain.to_text(preset: :light_ala) |> String.split("\n") |> length()
    assert default in 60..90, "default: #{default} lines"
    assert light < default
  end

  test "mix ala.lint --explain prints the guide without reading any code" do
    out = capture_io(fn -> Mix.Tasks.Ala.Lint.run(["--explain", "--strict", "no/such/dir"]) end)
    assert out =~ @scored
    assert out =~ "tier: --strict"
    refute out =~ "Degree of function compliance"
  end
end
