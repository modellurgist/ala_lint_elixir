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

  @doc "The level each entry of a `checks` map sets, `%{check => level}`; an entry with thresholds only sets none."
  def levels(checks) when is_map(checks) do
    for {check, spec} <- checks,
        {level, _max} = split_spec(spec),
        level != nil,
        into: %{},
        do: {check, level}
  end

  def levels(_), do: %{}

  @doc """
  The checks that two or more sources set to different levels. `sources` is
  `[{label, %{check => level}}]` in precedence order, so the last source that set a check won.
  """
  def conflicts(sources) do
    sources
    |> Enum.flat_map(fn {_label, levels} -> Map.keys(levels) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn check ->
      asked =
        for {label, levels} <- sources,
            Map.has_key?(levels, check),
            do: %{source: label, level: levels[check]}

      if asked |> Enum.uniq_by(& &1.level) |> length() > 1 do
        last = List.last(asked)
        [%{check: check, sources: asked, winner: last.source, level: last.level}]
      else
        []
      end
    end)
  end

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

  # A whitelist, so a check added to the linter later stays off under the preset until someone
  # decides it belongs to the reading, rather than turning on silently. By check name, not rule:
  # port-only checks (hops, vocabulary, wiring_closure) are filed under rules the preset keeps.
  @presets %{
    light_ala: ~w(r1 r1_ref subscribe layer r2 r3 r4 r5 r6 tramp ui_io r7 module_size module_avg
         passthrough height public_surface clone clone_inside unassigned
         builder_literals stale_session_write)a
  }

  @doc "The checks a preset adopts."
  def preset_checks(name), do: Map.fetch!(@presets, name)

  @doc "The checks of `checks` a preset turns off: every one it doesn't adopt."
  def preset_off(name, checks), do: checks -- preset_checks(name)

  @doc """
  A preset named by an atom or a string: `{:ok, %{name:, adopts:, off:}}`, or `{:error, message}`
  naming the presets there are.
  """
  def preset(name) do
    case Enum.find(Map.keys(@presets), &(to_string(&1) == to_string(name))) do
      nil ->
        {:error,
         "unknown preset #{inspect(name)} (one of: #{@presets |> Map.keys() |> Enum.join(", ")})"}

      found ->
        {:ok,
         %{
           name: found,
           adopts: preset_checks(found),
           off: preset_off(found, AlaLint.Rules.checks())
         }}
    end
  end

  @light_keys %{
    builder_literals: [:level, :structs, :builders, :tests, :max_positional],
    stale_session_write: [:level, :writers, :except, :guards]
  }

  @doc """
  The settings of the light-ALA checks in a `checks` map, `{:ok, %{check => settings | nil}}`
  (nil: not configured, so the check does nothing), or `{:error, message}`.
  """
  def light_settings(checks) when is_map(checks) do
    Enum.reduce_while(Map.keys(@light_keys), {:ok, %{}}, fn check, {:ok, acc} ->
      case light_setting(check, Map.get(checks, check)) do
        {:ok, settings} -> {:cont, {:ok, Map.put(acc, check, settings)}}
        {:error, message} -> {:halt, {:error, "#{check}: #{message}"}}
      end
    end)
  end

  def light_settings(_), do: light_settings(%{})

  defp light_setting(_check, nil), do: {:ok, nil}
  defp light_setting(_check, :off), do: {:ok, nil}
  defp light_setting(check, level) when is_atom(level), do: light_setting(check, level: level)

  defp light_setting(check, spec) when is_list(spec) do
    unknown = Keyword.keys(spec) -- @light_keys[check]

    cond do
      not Keyword.keyword?(spec) ->
        {:error, "expected a keyword list, got #{inspect(spec)}"}

      unknown != [] ->
        {:error,
         "unknown setting(s) #{Enum.map_join(unknown, ", ", &inspect/1)} (one of: #{Enum.join(@light_keys[check], ", ")})"}

      spec[:level] == :off ->
        {:ok, nil}

      true ->
        light_values(check, spec)
    end
  end

  defp light_setting(_check, spec), do: {:error, "expected a keyword list, got #{inspect(spec)}"}

  defp light_values(:builder_literals, spec) do
    with {:ok, structs} <- names(spec, :structs, required: true),
         {:ok, builders} <- names(spec, :builders, required: false),
         {:ok, tests} <- names(spec, :tests, required: false),
         {:ok, max} <- non_negative(spec, :max_positional, 2) do
      {:ok, %{structs: structs, builders: builders, tests: tests || [], max_positional: max}}
    end
  end

  defp light_values(:stale_session_write, spec) do
    with {:ok, writers} <- names(spec, :writers, required: true),
         {:ok, guards} <- names(spec, :guards, required: false),
         {:ok, except} <- exceptions(Keyword.get(spec, :except, [])) do
      {:ok,
       %{
         writers: Enum.map(writers, &target/1),
         guards: Enum.map(guards || [], &target/1),
         except: except
       }}
    end
  end

  defp names(spec, key, required: required) do
    case Keyword.fetch(spec, key) do
      :error when required ->
        {:error, "needs #{key}: [\"Module\", ...] (it does nothing without it)"}

      :error ->
        {:ok, nil}

      {:ok, [_ | _] = list} ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, "#{key}: takes strings, got #{inspect(list)}"}

      {:ok, other} ->
        {:error, "#{key}: takes a non-empty list of strings, got #{inspect(other)}"}
    end
  end

  defp non_negative(spec, key, default) do
    case Keyword.get(spec, key, default) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      other -> {:error, "#{key}: takes a non-negative integer, got #{inspect(other)}"}
    end
  end

  defp exceptions(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) or is_struct(&1, Regex))),
      do: {:ok, Enum.map(list, &exception/1)},
      else:
        {:error,
         "except: takes function names, \"Module.fun\" strings or a regex, got #{inspect(list)}"}
  end

  defp exceptions(other), do: {:error, "except: takes a list, got #{inspect(other)}"}

  defp exception(%Regex{} = re), do: re

  defp exception(name) do
    case target(name) do
      {nil, fun} -> fun
      target -> target
    end
  end

  # "Mod.fun" -> {"Mod", :fun}; "Mod" -> {"Mod", nil}; "fun" -> {nil, :fun}. A function name
  # starts lower-case, a module segment upper-case.
  defp target(name) do
    parts = String.split(name, ".")
    last = List.last(parts)

    cond do
      last =~ ~r/^[a-z_]/ and length(parts) == 1 -> {nil, String.to_atom(last)}
      last =~ ~r/^[a-z_]/ -> {Enum.join(Enum.drop(parts, -1), "."), String.to_atom(last)}
      true -> {name, nil}
    end
  end

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
