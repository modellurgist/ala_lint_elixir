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
          public_surface: [max: 15],
          module_size: [max: 400]
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
    "public_surface.max" => :max_public_funs,
    "app_share.max" => :max_app_share,
    "min_score" => :min_score
  }

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
    Enum.reduce(checks, %{disabled: [], soft: [], scored: [], thresholds: %{}}, fn {rule, spec}, acc ->
      {level, max} = split_spec(spec)

      acc
      |> add_level(rule, level)
      |> add_threshold(rule, max)
    end)
  end

  def normalize_checks(_), do: %{disabled: [], soft: [], scored: [], thresholds: %{}}

  @doc "Parse a `--set key=value` string into `{param_atom, typed_value}` or `:error`."
  def parse_set(str) do
    with [key, val] <- String.split(str, "=", parts: 2),
         param when not is_nil(param) <- Map.get(@threshold_keys, key) do
      {param, cast(param, val)}
    else
      _ -> :error
    end
  end

  @doc "The `--set` keys the tool understands (for help / --list-checks)."
  def set_keys, do: Map.keys(@threshold_keys)

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

  defp rule_param(:height), do: :max_height
  defp rule_param(:module_size), do: :max_module_loc
  defp rule_param(:public_surface), do: :max_public_funs
  defp rule_param(:r11), do: :max_app_share
  defp rule_param(_), do: nil

  defp cast(:max_app_share, v), do: parse_float(v)
  defp cast(_, v), do: parse_int(v)

  defp parse_int(v), do: with({n, ""} <- Integer.parse(v), do: n, else: (_ -> nil))
  defp parse_float(v), do: with({f, ""} <- Float.parse(v), do: f, else: (_ -> nil))
end
