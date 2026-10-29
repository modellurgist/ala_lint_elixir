defmodule SettingsConflictTest do
  use ExUnit.Case, async: true

  @shop ~S'''
  defmodule App.Shop do
    def rate, do: 599
  end
  '''

  defp analyze(opts) do
    dir = Path.join(System.tmp_dir!(), "ala_conflict_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/shop.ex"), @shop)
    on_exit(fn -> File.rm_rf!(dir) end)
    AlaLint.analyze(Path.join(dir, "lib"), opts)
  end

  defp text(r), do: AlaLint.Report.to_text(r)

  test "a file level and --enforce disagree: the block names both and the winner, before the scores" do
    t = text(analyze(checks: %{clone: :off}, enforce: [:clone]))

    assert t =~
             "settings conflict: 1 check set differently by more than one source; the later source won\n" <>
               "  clone      file checks: off   --enforce: scored   -> using --enforce (scored)\n"

    {at, _} = :binary.match(t, "settings conflict")
    {score_at, _} = :binary.match(t, "Degree of function compliance")
    assert at < score_at
  end

  test "the preset and a file level disagree" do
    t = text(analyze(preset: :light_ala, checks: %{r11: :advisory}))

    assert t =~
             "  r11        preset light_ala: off   file checks: advisory   -> using file checks (advisory)\n"
  end

  test "three sources, and two conflicts counted in the heading" do
    t =
      text(
        analyze(
          preset: :light_ala,
          checks: %{r11: :advisory, r7: :scored},
          enforce: [:r11],
          disabled: [:r7]
        )
      )

    assert t =~
             "settings conflict: 2 checks set differently by more than one source; the later source won\n"

    assert t =~
             "  r11        preset light_ala: off   file checks: advisory   --enforce: scored   -> using --enforce (scored)\n"

    assert t =~ "  r7         file checks: scored   --disable: off   -> using --disable (off)\n"
  end

  test "sources that agree are not a conflict" do
    r = analyze(preset: :light_ala, checks: %{r7: :scored, r11: :off}, enforce: [:r7])
    refute text(r) =~ "settings conflict"
    refute Map.has_key?(r.params, :conflicts)
  end

  test "a setting with thresholds only is not a conflict" do
    r =
      analyze(
        preset: :light_ala,
        checks: %{app_share: [max: 0.5], clone: [max: 20]},
        enforce: [:clone]
      )

    refute text(r) =~ "settings conflict"
    refute Map.has_key?(r.params, :conflicts)
  end

  test "the report map carries the conflicts in params" do
    r = analyze(checks: %{clone: :off}, enforce: [:clone])

    assert r.params.conflicts == [
             %{
               check: :clone,
               sources: [
                 %{source: "file checks", level: :off},
                 %{source: "--enforce", level: :scored}
               ],
               winner: "--enforce",
               level: :scored
             }
           ]
  end

  test "the disabled and downgraded lists print sorted, so their order never depends on map iteration" do
    t = text(analyze(preset: :light_ala, checks: %{r7: :advisory, r6: :advisory}))
    [_, disabled] = Regex.run(~r/disabled \(NOT scored\): (\S+)/, t)
    [_, soft] = Regex.run(~r/downgraded to advisory: (\S+)/, t)

    for list <- [disabled, soft] do
      names = String.split(list, ",")
      assert names == Enum.sort(names)
    end
  end
end
