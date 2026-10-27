defmodule AlaLint.Config do
  @moduledoc """
  Project configuration for `ala_lint`, loaded from an optional `.ala_lint.exs`
  at the project root. Keeps fine-grained, per-check settings out of the CLI:
  the command line carries the common path (paths, tiers, `--min-score`) while
  a version-controlled file carries the long tail.

  The file evaluates to a map, for example:

      %{
        layers_module: MyApp.AlaLayers,
        min_score: 85,
        config_modules: ["MyApp.Manifest"],
        exclude: [~r{/components/}],
        checks: %{
          r7: :off,                       # off | advisory | scored
          height: [level: :scored, max: 4],
          public_surface: [max: 8],          # the floor under the outlier test
          module_size: [max: 400],
          r11: [level: :advisory, calls: :wired_only]   # calls: all | wired_only
        }
      }

  A check's setting is a *level* (`:off | :advisory | :scored`) and/or a
  threshold (`max:`). One uniform mechanism covers "turn it off", "change its
  level", and "retune it", for any current or future check, with no per-check
  CLI flag.
  """

  # dotted threshold key -> the model param it sets
  @threshold_keys %{
    "height.max" => :max_height,
    "module_size.max" => :max_module_loc,
    "module_size.min_avg" => :min_avg_module_loc,
    "public_surface.floor" => :max_public_funs,
    # the floor's older name, from when it was a fixed cap
    "public_surface.max" => :max_public_funs,
    "public_surface.iqr" => :public_surface_iqr,
    "app_share.max" => :max_app_share,
    "clone.min" => :min_clone_size,
    "min_score" => :min_score
  }

  # settings that pick a reading rather than a number; the first choice is the default
  @choices %{r11_calls: [:all, :wired_only]}

  @doc "Load `.ala_lint.exs` from `dir` (default cwd) into a map; `%{}` if absent or invalid."
  def load(dir \\ ".") do
    path = Path.join(dir, ".ala_lint.exs")

    with true <- File.exists?(path),
         {value, _binding} <- Code.eval_file(path),
         true <- is_map(value) do
      value
    else
      _ -> %{}
    end
  end

  @doc """
  Normalize a `checks` map into the sets `AlaLint.analyze/2` consumes:
  `%{disabled: [rule], soft: [rule], scored: [rule], thresholds: %{param => value}}`.
  `disabled` = level `:off`; `soft` = a check downgraded to advisory; `scored` =
  a check promoted to scored; `thresholds` = per-check `max:` mapped to a param.
  """
  def normalize_checks(checks) when is_map(checks) do
    Enum.reduce(checks, %{disabled: [], soft: [], scored: [], thresholds: %{}}, fn {rule, spec},
                                                                                   acc ->
      {level, max} = split_spec(spec)

      acc
      |> add_level(rule, level)
      |> add_threshold(rule, max)
      |> add_calls(rule, spec)
    end)
  end

  def normalize_checks(_), do: %{disabled: [], soft: [], scored: [], thresholds: %{}}

  @doc "Parse a `--set key=value` string into `{param_atom, typed_value}` or `:error`."
  def parse_set("r11.calls=" <> val), do: {:r11_calls, val}

  def parse_set(str) do
    with [key, val] <- String.split(str, "=", parts: 2),
         param when not is_nil(param) <- Map.get(@threshold_keys, key) do
      {param, cast(param, val)}
    else
      _ -> :error
    end
  end

  @doc "The `--set` keys the tool understands (for help / --list-checks)."
  def set_keys, do: Map.keys(@threshold_keys) ++ ["r11.calls"]

  @doc """
  Check a reading (`:r11_calls`) given as an atom or a `--set` string: `{:ok, atom}`, or
  `{:error, message}` naming the choices.
  """
  def choice(param, value) do
    choices = Map.fetch!(@choices, param)

    case Enum.find(choices, &(to_string(&1) == to_string(value))) do
      nil ->
        {:error,
         "unknown #{set_name(param)} value #{inspect(value)} (one of: #{Enum.join(choices, ", ")})"}

      found ->
        {:ok, found}
    end
  end

  @doc "The default of a reading, which the parameter echo leaves out."
  def default_choice(param), do: @choices |> Map.fetch!(param) |> hd()

  def set_name(:r11_calls), do: "r11.calls"

  # ── helpers ──────────────────────────────────────────────────────────
  defp split_spec(level) when level in [:off, :advisory, :scored], do: {level, nil}

  defp split_spec(spec) when is_list(spec),
    do: {Keyword.get(spec, :level), Keyword.get(spec, :max)}

  defp split_spec(_), do: {nil, nil}

  defp add_level(acc, rule, :off), do: %{acc | disabled: [rule | acc.disabled]}
  defp add_level(acc, rule, :advisory), do: %{acc | soft: [rule | acc.soft]}
  defp add_level(acc, rule, :scored), do: %{acc | scored: [rule | acc.scored]}
  defp add_level(acc, _rule, _), do: acc

  defp add_threshold(acc, _rule, nil), do: acc

  defp add_threshold(acc, rule, max) do
    case rule_param(rule) do
      nil -> acc
      param -> %{acc | thresholds: Map.put(acc.thresholds, param, max)}
    end
  end

  defp add_calls(acc, :r11, spec) when is_list(spec) do
    case Keyword.fetch(spec, :calls) do
      {:ok, calls} -> %{acc | thresholds: Map.put(acc.thresholds, :r11_calls, calls)}
      :error -> acc
    end
  end

  defp add_calls(acc, _rule, _spec), do: acc

  defp rule_param(:height), do: :max_height
  defp rule_param(:module_size), do: :max_module_loc
  defp rule_param(:public_surface), do: :max_public_funs
  defp rule_param(:r11), do: :max_app_share
  defp rule_param(:app_share), do: :max_app_share
  defp rule_param(:module_avg), do: :min_avg_module_loc
  defp rule_param(:clone), do: :min_clone_size
  defp rule_param(_), do: nil

  defp cast(param, v) when param in [:max_app_share, :public_surface_iqr], do: parse_float(v)
  defp cast(_, v), do: parse_int(v)

  defp parse_int(v), do: with({n, ""} <- Integer.parse(v), do: n, else: (_ -> nil))
  defp parse_float(v), do: with({f, ""} <- Float.parse(v), do: f, else: (_ -> nil))
end
