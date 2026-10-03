defmodule AlaLint do
  @moduledoc """
  A static-analysis linter that scores an Elixir codebase against the **ALA
  Checklist** (R1–R11): coupling & layering, requirements-locus,
  state-as-a-wire, cross-boundary contracts, nameability, and abstraction
  minimality. It reports each violation with a location and computes an overall
  design-health score.

  R8 (readability) is deliberately not automated — it is judgement; a green run
  is necessary but not sufficient.

      AlaLint.analyze("lib") |> AlaLint.Report.to_text() |> IO.puts()

  Or from the CLI in a project that has `:ala_lint` as a dev dependency:

      mix ala.lint
  """

  alias AlaLint.{Analyzer, Rules, Report}

  @doc """
  Analyze all `*.ex` under `root` and return a report map. Options:

    * `:config_modules` — module names (strings) treated as the config/manifest
      locus, so their literals are not flagged by R3.
  """
  def analyze(root \\ "lib", opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])
    config_modules = Keyword.get(opts, :config_modules, [])
    strict = Keyword.get(opts, :strict, false)
    super_strict = Keyword.get(opts, :super_strict, false)

    # Per-check settings from a `checks: %{}` map (a `.ala_lint.exs` file or a
    # caller): `:off` disables, `:advisory` downgrades a scored rule to reported,
    # `:scored` promotes an advisory rule, and `max:` retunes a threshold.
    checks = AlaLint.Config.normalize_checks(Keyword.get(opts, :checks, %{}))
    disabled = Enum.uniq(Keyword.get(opts, :disabled, []) ++ checks.disabled)
    soft = Enum.uniq(Keyword.get(opts, :soft, []) ++ checks.soft)

    # strict promotes the *obtainable* advisory rules to scored (R7, module-size, tramp,
    # height, pass-through, reference-level R1, subscribe). R11 ("no logic at the
    # top") and public-surface are aspirational purity, scored only under
    # super-strict. The shared-domain-aggregate check (R10) is scored from --strict
    # up. The app-layer share and the average module size are reported at every
    # tier and scored by none: `checks: %{rule => :scored}` or `--enforce` promotes one.
    super_strict_only = [:r11, :public_surface]

    enforce =
      cond do
        super_strict ->
          Enum.uniq(Keyword.get(opts, :enforce, []) ++ Rules.advisory_rules())

        strict ->
          Enum.uniq(
            Keyword.get(opts, :enforce, []) ++ (Rules.advisory_rules() -- super_strict_only)
          )

        true ->
          Keyword.get(opts, :enforce, [])
      end
      |> Kernel.++(checks.scored)
      |> Enum.uniq()
      # a check the caller set to :advisory stays reported, whatever the tier promotes
      |> Kernel.--(soft)

    check_aggregates = strict or super_strict or Keyword.get(opts, :check_aggregates, false)

    mode =
      cond do
        super_strict -> :super_strict
        strict -> :strict
        true -> :normal
      end

    # thresholds precedence: explicit opt (a CLI `--set`) > `checks` map `max:` > default
    t = checks.thresholds
    max_height = Keyword.get(opts, :max_height) || Map.get(t, :max_height) || 5
    max_app_share = Keyword.get(opts, :max_app_share) || Map.get(t, :max_app_share) || 0.20
    max_module_loc = Keyword.get(opts, :max_module_loc) || Map.get(t, :max_module_loc) || 500
    max_public_funs = Keyword.get(opts, :max_public_funs) || Map.get(t, :max_public_funs) || 12

    min_avg_module_loc =
      Keyword.get(opts, :min_avg_module_loc) || Map.get(t, :min_avg_module_loc) || 100

    layers_spec = Keyword.get(opts, :layers)

    model =
      root
      |> Analyzer.build(exclude: exclude)
      |> Map.put(:config_modules, config_modules)
      |> Map.put(:enforce, enforce)
      |> Map.put(:check_aggregates, check_aggregates)
      |> Map.put(:max_height, max_height)
      |> Map.put(:max_app_share, max_app_share)
      |> Map.put(:max_module_loc, max_module_loc)
      |> Map.put(:max_public_funs, max_public_funs)
      |> Map.put(:min_avg_module_loc, min_avg_module_loc)
      |> put_layers(layers_spec)
      |> Map.put(:params, %{
        root: root,
        mode: mode,
        max_height: max_height,
        max_app_share: max_app_share,
        max_module_loc: max_module_loc,
        max_public_funs: max_public_funs,
        min_avg_module_loc: min_avg_module_loc,
        enforce: enforce,
        disabled: disabled,
        soft: soft,
        layers: if(layers_spec, do: :on, else: :off),
        config_modules: config_modules,
        exclude: exclude,
        weights: Rules.weights()
      })

    findings =
      model
      |> Rules.run()
      |> Enum.reject(&(&1.rule in disabled))
      |> Enum.map(fn f -> if f.rule in soft, do: %{f | severity: :warn}, else: f end)

    Report.build(model, findings)
  end

  defp put_layers(model, nil), do: Map.put(model, :layers, nil)

  defp put_layers(model, spec),
    do: Map.put(model, :layers, AlaLint.Layers.resolve(model.modules, spec))

  @doc """
  Auto-encode a codebase into the ALA Checklist notation (a human-completed
  draft). Returns `[{relpath, content}]`; the `mix ala.encode` task writes them
  to a parallel directory. Accepts the same `:layers`/`:exclude` opts as
  `analyze/2` (with a layer map, `[tag]`s and edge-altitude are filled in).
  """
  def encode(root \\ "lib", opts \\ []) do
    root
    |> Analyzer.build(exclude: Keyword.get(opts, :exclude, []))
    |> put_layers(Keyword.get(opts, :layers))
    |> AlaLint.Encoder.encode()
  end
end
