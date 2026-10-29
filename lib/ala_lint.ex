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
    * `:r11_calls` — `:all` (default) or `:wired_only`, which leaves out R11's
      hand-offs into a part that declares no `ports/0` (also `checks: %{r11: [calls: ...]}`).
    * `:preset` — `:light_ala` adopts only the checks the light-ALA reading keeps and turns
      every other one off; a `checks:` level, `:enforce` and `:disabled` override it.
  """
  def analyze(root \\ "lib", opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])
    config_modules = Keyword.get(opts, :config_modules, [])

    %{
      preset: preset,
      light: light,
      configured: configured,
      enforce: enforce,
      disabled: disabled,
      soft: soft,
      conflicts: conflicts,
      check_aggregates: check_aggregates,
      mode: mode,
      max_height: max_height,
      max_app_share: max_app_share,
      max_module_loc: max_module_loc,
      max_public_funs: max_public_funs,
      public_surface_iqr: public_surface_iqr,
      min_avg_module_loc: min_avg_module_loc,
      min_clone_size: min_clone_size,
      r11_calls: r11_calls
    } = resolve(opts)

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
      |> Map.put(:public_surface_iqr, public_surface_iqr)
      |> Map.put(:min_avg_module_loc, min_avg_module_loc)
      |> Map.put(:min_clone_size, min_clone_size)
      |> put_layers(layers_spec)
      |> put_r11_quiet(r11_calls)
      |> Map.put(:params, %{
        root: root,
        mode: mode,
        max_height: max_height,
        max_app_share: max_app_share,
        max_module_loc: max_module_loc,
        max_public_funs: max_public_funs,
        public_surface_iqr: public_surface_iqr,
        min_avg_module_loc: min_avg_module_loc,
        min_clone_size: min_clone_size,
        enforce: enforce,
        disabled: disabled,
        soft: soft,
        layers: if(layers_spec, do: :on, else: :off),
        config_modules: config_modules,
        exclude: exclude,
        weights: Rules.weights()
      })
      |> echo_choice(:r11_calls, r11_calls)
      |> then(&if(conflicts == [], do: &1, else: put_in(&1, [:params, :conflicts], conflicts)))
      |> Map.put(:light_ala, light)
      |> echo_light(preset, light, configured)

    acceptances = AlaLint.Acceptance.scan_roots(root)

    {accepted, findings} =
      model
      |> Rules.run()
      |> Enum.reject(&(&1.rule in disabled))
      |> Enum.map(fn f -> if f.rule in soft, do: %{f | severity: :warn}, else: f end)
      |> Enum.split_with(fn f -> Enum.any?(acceptances, &AlaLint.Acceptance.covers?(&1, f)) end)

    Report.build(model, findings, accepted, acceptances)
  end

  @doc """
  What a run's opts resolve to before any code is read: the level sets (`enforce`, `disabled`,
  `soft`), the tier, the preset, the light-ALA settings and the thresholds. `analyze/2` and
  `AlaLint.Explain` share it, so the guide shows what the run scores.
  """
  def resolve(opts) do
    strict = Keyword.get(opts, :strict, false)
    super_strict = Keyword.get(opts, :super_strict, false)

    # Per-check settings from a `checks: %{}` map (a `.ala_lint.exs` file or a
    # caller): `:off` disables, `:advisory` downgrades a scored rule to reported,
    # `:scored` promotes an advisory rule, and `max:` retunes a threshold.
    raw_checks = Keyword.get(opts, :checks, %{})
    checks = AlaLint.Config.normalize_checks(raw_checks)
    preset = preset!(Keyword.get(opts, :preset))
    light = ok!(AlaLint.Config.light_settings(raw_checks))
    configured = for {check, settings} <- light, settings != nil, do: check

    # precedence: tier default < preset < a `checks:` level < --enforce < --disable
    cli_enforce = Keyword.get(opts, :enforce, [])
    leveled = checks.disabled ++ checks.soft ++ checks.scored
    preset_off = if preset, do: preset.off -- (leveled ++ cli_enforce), else: []

    disabled =
      Enum.uniq(
        Keyword.get(opts, :disabled, []) ++ (checks.disabled -- cli_enforce) ++ preset_off
      )

    soft = Enum.uniq(Keyword.get(opts, :soft, []) ++ checks.soft) -- cli_enforce

    # strict promotes the *obtainable* advisory rules to scored (R7, module-size, tramp,
    # height, pass-through, reference-level R1, subscribe). R11 ("no logic at the
    # top") is aspirational purity, scored only under super-strict. The
    # shared-domain-aggregate check (R10) is scored from --strict up. The app-layer
    # share, the average module size and the public surface are reported at every
    # tier and scored by none: `checks: %{rule => :scored}` or `--enforce` promotes one.
    super_strict_only = [:r11]

    # the light-ALA checks join a tier's promotions only once configured, so a default
    # run's enforce list is unchanged
    enforce =
      cond do
        super_strict ->
          Enum.uniq(cli_enforce ++ Rules.advisory_rules() ++ configured)

        strict ->
          Enum.uniq(cli_enforce ++ (Rules.advisory_rules() -- super_strict_only) ++ configured)

        true ->
          cli_enforce
      end
      |> Kernel.++(if preset, do: configured, else: [])
      |> Kernel.++(checks.scored)
      |> Enum.uniq()
      # a check the caller set to :advisory stays reported, whatever the tier or preset promotes
      |> Kernel.--(soft)

    # the same precedence as above, as the levels each source asked for, so the report can say
    # which setting lost
    conflicts =
      AlaLint.Config.conflicts(
        if(preset,
          do: [
            {"preset #{preset.name}",
             Map.merge(Map.new(preset.off, &{&1, :off}), Map.new(configured, &{&1, :scored}))}
          ],
          else: []
        ) ++
          [
            {"file checks", AlaLint.Config.levels(raw_checks)},
            {"--enforce", Map.new(cli_enforce, &{&1, :scored})},
            {"--disable", Map.new(Keyword.get(opts, :disabled, []), &{&1, :off})}
          ]
      )

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
    # the public-surface floor: no module at or below it is reported, whatever its layer's spread
    max_public_funs = Keyword.get(opts, :max_public_funs) || Map.get(t, :max_public_funs) || 10

    public_surface_iqr =
      Keyword.get(opts, :public_surface_iqr) || Map.get(t, :public_surface_iqr) || 1.5

    min_avg_module_loc =
      Keyword.get(opts, :min_avg_module_loc) || Map.get(t, :min_avg_module_loc) || 100

    min_clone_size =
      Keyword.get(opts, :min_clone_size) || Map.get(t, :min_clone_size) ||
        AlaLint.Clones.default_min_size()

    r11_calls =
      case AlaLint.Config.choice(
             :r11_calls,
             Keyword.get(opts, :r11_calls) || Map.get(t, :r11_calls) || :all
           ) do
        {:ok, calls} -> calls
        {:error, message} -> raise ArgumentError, message
      end

    %{
      preset: preset,
      light: light,
      configured: configured,
      enforce: enforce,
      disabled: disabled,
      soft: soft,
      conflicts: conflicts,
      check_aggregates: check_aggregates,
      mode: mode,
      max_height: max_height,
      max_app_share: max_app_share,
      max_module_loc: max_module_loc,
      max_public_funs: max_public_funs,
      public_surface_iqr: public_surface_iqr,
      min_avg_module_loc: min_avg_module_loc,
      min_clone_size: min_clone_size,
      r11_calls: r11_calls
    }
  end

  @doc """
  Each check's level in a run with these opts, `%{check => :scored | :advisory | :off}`. A check
  that cannot run is `:off`: a light-ALA check with no settings, and R10-aggregate below `--strict`.
  """
  def levels(opts) do
    r = resolve(opts)

    Map.new(Rules.checks(), fn check ->
      level =
        cond do
          check in r.disabled -> :off
          check in AlaLint.LightAla.checks() and check not in r.configured -> :off
          check == :r10_aggregate and not r.check_aggregates -> :off
          check in r.enforce -> :scored
          Rules.default_severity(check) == :error and check not in r.soft -> :scored
          true -> :advisory
        end

      {check, level}
    end)
  end

  defp preset!(nil), do: nil
  defp preset!(name), do: ok!(AlaLint.Config.preset(name))

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  # echoed only when chosen or configured, so a default run's output is unchanged
  defp echo_light(model, preset, light, configured) do
    model
    |> then(&if(preset, do: put_in(&1, [:params, :preset], preset.name), else: &1))
    |> then(fn m ->
      Enum.reduce(configured, m, fn check, acc ->
        put_in(acc, [:params, :weights, check], AlaLint.LightAla.weights()[check])
      end)
    end)
    |> then(fn m ->
      case light[:builder_literals] do
        nil -> m
        s -> put_in(m, [:params, :builders], AlaLint.LightAla.builders(m, s))
      end
    end)
  end

  defp put_r11_quiet(model, :wired_only),
    do: Map.put(model, :r11_quiet, Rules.called_parts(model))

  defp put_r11_quiet(model, _all), do: model

  # a reading is echoed only when chosen, so a default run's output is unchanged
  defp echo_choice(model, param, value) do
    if value == AlaLint.Config.default_choice(param),
      do: model,
      else: put_in(model, [:params, param], value)
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
