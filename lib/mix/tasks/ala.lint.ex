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
    --super-strict       --strict, plus the aspirational checks (R11, public-surface, R10-aggregate)
    --layers-module MOD  a module exporting layers/0 → layer-aware R1/R3/R10/R11 + coverage
    --limit N            show up to N findings (default 40)
    --list-checks        print every check with its tier and threshold, then exit
    --help, -h           show this help

  Per-check overrides (generic, so no flag-per-check):
    --enforce CHECK      promote one advisory check to scored (repeatable)
    --disable CHECK      turn one check off entirely (repeatable)
    --set KEY=VALUE      set a threshold (repeatable): height.max, module_size.max,
                         public_surface.max, app_share.max, min_score
    --config-module MOD  treat MOD as a config/manifest locus for R3 (repeatable)

  Durable settings belong in a `.ala_lint.exs` map at the project root
  (layers_module, min_score, config_modules, exclude, and a `checks:` map that
  sets each check to off / advisory / scored and retunes its threshold). CLI
  flags override the file for a single run.
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
          limit: :integer, min_score: :integer, config_module: :keep, layers_module: :string,
          enforce: :keep, disable: :keep, set: :keep, strict: :boolean, super_strict: :boolean,
          list_checks: :boolean
        ],
        aliases: [l: :limit]
      )

    AlaLint.CLI.warn_unknown(invalid)
    file = AlaLint.Config.load()

    roots = if paths == [], do: "lib", else: paths
    config_modules = Keyword.get_values(opts, :config_module) ++ Map.get(file, :config_modules, [])
    enforce = opts |> Keyword.get_values(:enforce) |> Enum.map(&String.to_atom/1)
    disabled = opts |> Keyword.get_values(:disable) |> Enum.map(&String.to_atom/1)
    layers_module = opts[:layers_module] || Map.get(file, :layers_module)
    layers = AlaLint.Layers.load(layers_module: layers_module)

    {sets, bad_sets} = parse_sets(Keyword.get_values(opts, :set))
    Enum.each(bad_sets, &Mix.shell().info("ignoring unknown --set (try one of: #{Enum.join(AlaLint.Config.set_keys(), ", ")}): #{&1}"))
    min_score = sets[:min_score] || opts[:min_score] || Map.get(file, :min_score)
    threshold_opts = sets |> Map.take([:max_height, :max_app_share, :max_module_loc, :max_public_funs]) |> Enum.into([])

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
      ] ++ threshold_opts

    report = AlaLint.analyze(roots, analyze_opts)
    Mix.shell().info(AlaLint.Report.to_text(report, limit: opts[:limit] || 40))

    case min_score do
      nil -> :ok
      min when report.score < min -> Mix.raise("ALA score #{report.score} is below --min-score #{min}")
      min -> Mix.shell().info("ok — score #{report.score} meets --min-score #{min}")
    end
  end

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
