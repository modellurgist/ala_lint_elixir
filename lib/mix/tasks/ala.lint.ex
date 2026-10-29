defmodule Mix.Tasks.Ala.Lint do
  @shortdoc "Score this codebase against the ALA Checklist (R1–R11)"

  @moduledoc """
  Recursively analyze `lib/` (or a given path) against the ALA Checklist and
  print violations plus an overall design-health score.

      mix ala.lint
      mix ala.lint lib/app lib/app_web    # several roots; everything outside them is excluded
      mix ala.lint --strict               # score the obtainable advisory checks too
      mix ala.lint --min-score 85         # exit non-zero below 85 (CI gate)
      mix ala.lint --list-checks          # every check, its tier, and its threshold
      mix ala.lint --explain --strict     # what this run scores, reports, and leaves to a reader

  Fine-grained, per-check configuration lives in a `.ala_lint.exs` file at the
  project root, not on the command line (see `AlaLint.Config`). One-off tweaks
  use the generic `--enforce`, `--disable`, and `--set` flags rather than a flag
  per check, so the CLI stays small as the check list grows.
  """
  use Mix.Task

  @usage """
  mix ala.lint [PATHS...] [options]

  Analyze Elixir under the given directories (default: lib) against the ALA
  Checklist and print violations plus a design-health score.

  Common:
    --min-score N        exit non-zero if the score is below N (the CI gate)
    --strict             score the obtainable advisory checks (R7, module-size, height, pass-through, R1-ref)
    --super-strict       --strict, plus the aspirational check (R11)
    --preset light_ala   adopt only the light-ALA reading's checks (R1–R7 and the general ones);
                         every other check is off and its rule reported as not adopted
    --layers-module MOD  a module exporting layers/0 → layer-aware R1/R3/R10/R11 + coverage
    --require-layers     exit non-zero if any module matches no layer (the layer-aware checks skip it)
    --limit N            show up to N findings (default 40)
    --list-checks        print every check with its tier and threshold, then exit
    --explain            print what this run's settings score, only report, and leave to a
                         reader (rule by rule, with § citations), then exit without reading code
    --list-accepted      print every @inherent_ declaration and every `ala:accept` comment, what
                         it covers, and the stale ones, then exit
    --help, -h           show this help

  Accepting a finding by hand, where the tool can't tell (a domain's own word, routing):
    # ala:accept r3                        the next line, for check r3
    # ala:accept r3,r5 lines=3 -- why      the next three lines, for two checks, with the reason
    <%!-- ala:accept r11 -- why --%>       the same in HEEx
  Accepted findings leave the score and are counted in the report. Words a lower module owns as
  its domain's vocabulary are declared, not accepted: a module attribute named @inherent_...
  holds them, and R3 reads nothing inside it as product text.

  Per-check overrides (generic, so no flag-per-check):
    --enforce CHECK      promote one advisory check to scored (repeatable)
    --disable CHECK      turn one check off entirely (repeatable)
    --set KEY=VALUE      set a threshold (repeatable): height.max, module_size.max,
                         public_surface.floor, public_surface.iqr, app_share.max,
                         clone.min, min_score; or pick a reading: r11.calls=wired_only
                         leaves out R11's hand-offs into a part with no ports/0
    --config-module MOD  treat MOD as a config/manifest locus for R3 (repeatable)

  Durable settings belong in a `.ala_lint.exs` map at the project root
  (layers_module, min_score, config_modules, exclude, preset, and a `checks:` map
  that sets each check to off / advisory / scored and retunes its threshold, and
  configures builder_literals and stale_session_write). CLI flags override the
  file for a single run.
  """

  @impl true
  def run(argv) do
    cond do
      AlaLint.CLI.help?(argv, @usage) -> :ok
      "--list-checks" in argv -> Mix.shell().info(AlaLint.CLI.checks_listing())
      true -> run_lint(argv)
    end
  end

  defp run_lint(argv) do
    {opts, paths, invalid} =
      OptionParser.parse(argv,
        strict: [
          limit: :integer,
          min_score: :integer,
          config_module: :keep,
          layers_module: :string,
          require_layers: :boolean,
          enforce: :keep,
          disable: :keep,
          set: :keep,
          strict: :boolean,
          super_strict: :boolean,
          preset: :string,
          list_checks: :boolean,
          list_accepted: :boolean,
          explain: :boolean
        ],
        aliases: [l: :limit]
      )

    AlaLint.CLI.warn_unknown(invalid)
    file = AlaLint.Config.load()

    roots = if paths == [], do: "lib", else: paths

    config_modules =
      Keyword.get_values(opts, :config_module) ++ Map.get(file, :config_modules, [])

    enforce = opts |> Keyword.get_values(:enforce) |> Enum.map(&String.to_atom/1)
    disabled = opts |> Keyword.get_values(:disable) |> Enum.map(&String.to_atom/1)
    layers_module = opts[:layers_module] || Map.get(file, :layers_module)
    layers = AlaLint.Layers.load(layers_module: layers_module)

    {sets, bad_sets} = parse_sets(Keyword.get_values(opts, :set))

    Enum.each(
      bad_sets,
      &Mix.shell().info(
        "ignoring unknown --set (try one of: #{Enum.join(AlaLint.Config.set_keys(), ", ")}): #{&1}"
      )
    )

    min_score = sets[:min_score] || opts[:min_score] || Map.get(file, :min_score)
    r11_calls = r11_calls!(sets, file)
    preset = preset!(opts[:preset] || Map.get(file, :preset))
    ok!(AlaLint.Config.light_settings(Map.get(file, :checks, %{})))

    threshold_opts =
      sets
      |> Map.take([
        :max_height,
        :max_app_share,
        :max_module_loc,
        :max_public_funs,
        :public_surface_iqr,
        :min_avg_module_loc,
        :min_clone_size
      ])
      |> Enum.into([])

    analyze_opts =
      [
        config_modules: config_modules,
        layers: layers,
        enforce: enforce,
        disabled: disabled,
        checks: Map.get(file, :checks, %{}),
        exclude: Map.get(file, :exclude, []),
        strict: opts[:strict] || false,
        super_strict: opts[:super_strict] || false
      ] ++
        threshold_opts ++
        if(r11_calls, do: [r11_calls: r11_calls], else: []) ++
        if(preset, do: [preset: preset], else: [])

    if opts[:explain],
      do: Mix.shell().info(AlaLint.Explain.to_text(analyze_opts)),
      else: lint(roots, analyze_opts, opts, file, min_score)
  end

  defp lint(roots, analyze_opts, opts, file, min_score) do
    report = AlaLint.analyze(roots, analyze_opts)

    if opts[:list_accepted] do
      Mix.shell().info(String.trim_trailing(AlaLint.Report.accepted_listing(report)))
    else
      finish(report, opts, file, min_score)
    end
  end

  defp finish(report, opts, file, min_score) do
    Mix.shell().info(AlaLint.Report.to_text(report, limit: opts[:limit] || 40))

    case AlaLint.Report.unassigned_banner(report) do
      "" -> :ok
      banner -> Mix.shell().error(String.trim_trailing(banner))
    end

    if (opts[:require_layers] || Map.get(file, :require_layers, false)) and
         Enum.any?(report.findings, &(&1.rule == :unassigned)),
       do: Mix.raise("modules match no layer (see the warning above); --require-layers is set")

    case min_score do
      nil ->
        :ok

      min when report.score < min ->
        Mix.raise("ALA score #{report.score} is below --min-score #{min}")

      min ->
        Mix.shell().info("ok — score #{report.score} meets --min-score #{min}")
    end
  end

  # A reading is a word, not a number, so a typo would silently change what R11 reports: fail instead.
  defp r11_calls!(sets, file) do
    file_calls =
      AlaLint.Config.normalize_checks(Map.get(file, :checks, %{})).thresholds[:r11_calls]

    case sets[:r11_calls] || file_calls do
      nil ->
        nil

      value ->
        case AlaLint.Config.choice(:r11_calls, value) do
          {:ok, calls} -> calls
          {:error, message} -> Mix.raise(message, exit_status: 2)
        end
    end
  end

  # A preset or a light-ALA setting is a word or a list, not a number, so a typo fails the run.
  defp preset!(nil), do: nil
  defp preset!(name), do: ok!(AlaLint.Config.preset(name)).name

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message, exit_status: 2)

  # Parse `--set KEY=VALUE` strings into a map of {param => value}, collecting
  # any that don't name a known threshold.
  defp parse_sets(strings) do
    Enum.reduce(strings, {%{}, []}, fn s, {ok, bad} ->
      case AlaLint.Config.parse_set(s) do
        {param, value} when not is_nil(value) -> {Map.put(ok, param, value), bad}
        _ -> {ok, [s | bad]}
      end
    end)
  end
end
