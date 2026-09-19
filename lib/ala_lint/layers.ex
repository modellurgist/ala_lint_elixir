defmodule AlaLint.Layers do
  @moduledoc """
  Optional layer configuration — the generalization of a project-specific
  `CorePurity`-style check into a reusable rule. A layer spec is an **ordered**
  list, top (concrete/application) to bottom (abstract/platform):

      layers: [
        {:app,      [~r/Web\\..*Page$/, ~r/View$/, "Manifest"], peer_ok: true},
        {:feature,  [~r/\\.Features\\./],                        peer_ok: false},
        {:domain,   [~r/\\.Domain\\./, ~r/\\.Cart$/],            peer_ok: true},
        {:platform, [~r/Effects/, ~r/Foundation/]},           # peer_ok defaults true
      ]

  A module is assigned to the **first** layer whose patterns match (string =
  substring, or a `Regex`). This unlocks what a tag-blind linter cannot check:

    * **R1 altitude** — every dependency edge must *drop* (callee more abstract
      than caller). An **upward** edge (callee more concrete) is a hard
      violation; a **same-layer** edge in a `peer_ok: false` layer (the feature
      tier, where peer coupling is the classic ALA smell) is a violation too.
    * **R3 layer-aware** — application literals are allowed only in the top
      (composition) layer; literals in a lower layer are flagged (hoist if
      application-specific, keep if intrinsic to the abstraction).
  """

  @doc """
  Find a layer spec for a host project, checking (in order): an explicit
  `:layers` opt, an explicit `:layers_module`, then the `:ala_lint` app env
  (`:layers_module`, then `:layers`). Returns the spec list or `nil`.

  A **layers module** is any module exporting `layers/0` that returns a spec.
  A host project (with `:ala_lint` as a dev dep) declares one in `config`:

      config :ala_lint, layers_module: MyAppWeb.AlaLayers

  so `mix ala.lint` / `mix ala.encode` pick it up with no flags. `layers/0`
  keeps the regexes in code where they belong (config can't hold a `Regex`
  literal cleanly). The module must be compiled and on the code path.
  """
  def load(opts \\ []) do
    cond do
      spec = opts[:layers] -> spec
      mod = opts[:layers_module] -> from_module(mod)
      mod = Application.get_env(:ala_lint, :layers_module) -> from_module(mod)
      spec = Application.get_env(:ala_lint, :layers) -> spec
      true -> nil
    end
  end

  defp from_module(mod) when is_atom(mod) do
    Code.ensure_loaded(mod)
    if function_exported?(mod, :layers, 0), do: mod.layers(), else: nil
  end

  defp from_module(str) when is_binary(str), do: from_module(Module.concat([str]))

  @doc """
  Resolve a spec against the project's **modules** (each carrying its functions,
  file path, and any `@ala_layer` tags). Produces both a module→layer index and
  a **function→layer index**, resolved *most-specific-wins*: a function's own
  `@ala_layer` tag beats its module's convention match; a module matches the
  first layer whose module-name pattern OR path glob (`paths:` opt) matches.
  Functions matching nothing are left unassigned (index `nil`) — that is the
  coverage gap, not a violation. A tag naming an undeclared layer is collected
  in `unknown_tags` (a validity error).
  """
  def resolve(modules, spec) do
    names = Enum.map(spec, fn t -> elem(t, 0) end)
    indexed = Enum.with_index(spec)
    peer_ok = for {t, i} <- indexed, into: %{}, do: {i, layer_opt(t, :peer_ok, true)}
    units = for {t, i} <- indexed, into: %{}, do: {i, layer_opt(t, :unit, nil)}

    # Layers where application literals are allowed (R3 exemption). Any layer
    # can opt in with `config: true` — so an app tier with sub-layers can hold
    # its "diagram config" in whichever sub-layer owns it, not just index 0.
    # Default (nothing declared): the top/composition layer, as before.
    declared_config = for {t, i} <- indexed, layer_opt(t, :config, false), into: MapSet.new(), do: i
    config_layers = if MapSet.size(declared_config) == 0, do: MapSet.new([0]), else: declared_config

    # Application-layer tiers. Calls *within* the app layer don't add abstraction
    # height — the whole app layer is one altitude — because it is wiring with
    # legitimate sub-layers (shell → page → view). Mark tiers with `app: true`;
    # default is the top layer (index 0).
    declared_app = for {t, i} <- indexed, layer_opt(t, :app, false), into: MapSet.new(), do: i
    app_layers = if MapSet.size(declared_app) == 0, do: MapSet.new([0]), else: declared_app

    index = for m <- modules, into: %{}, do: {m.name, first_match(m, spec)}

    {fun_index, unknown} =
      for m <- modules, fun <- m.functions, reduce: {%{}, []} do
        {fi, unk} ->
          id = {m.name, fun.name, fun.arity}

          cond do
            fun.layer_tag != nil ->
              case Enum.find_index(names, &(&1 == fun.layer_tag)) do
                nil -> {Map.put(fi, id, nil), [{id, fun.layer_tag} | unk]}
                i -> {Map.put(fi, id, i), unk}
              end

            true ->
              {Map.put(fi, id, Map.get(index, m.name)), unk}
          end
      end

    %{
      names: names,
      peer_ok: peer_ok,
      units: units,
      config_layers: config_layers,
      app_layers: app_layers,
      index: index,
      fun_index: fun_index,
      unknown_tags: Enum.reverse(unknown),
      top: 0
    }
  end

  @doc """
  The peer-unit key for a module in a peer-forbidden layer: same-unit modules
  are internal cohesion (a feature and its own submodules), NOT peers. If the
  layer declares a `unit:` regex, the first capture group is the unit;
  otherwise the whole module name is its own unit.
  """
  def unit(mod, nil), do: mod
  def unit(mod, %Regex{} = re) do
    case Regex.run(re, mod) do
      [_, cap | _] -> cap
      _ -> mod
    end
  end

  # A module matches a layer by module-name pattern, `paths:` glob, or `uses:`
  # (the modules it `use`s — a content signal, e.g. `Ecto.Schema` → persistence).
  # `uses:` wins first because it is the most specific, intentional signal: a
  # schema is persistence even when its name sits in a domain namespace. Among
  # name/path matchers, first-in-declared-order wins (declaration order = altitude).
  defp first_match(m, spec) do
    by_uses(m, spec) || by_name_or_path(m, spec)
  end

  defp by_uses(m, spec) do
    Enum.find_value(Enum.with_index(spec), fn {t, i} ->
      ups = layer_opt(t, :uses, [])
      if ups != [] and Enum.any?(m.uses, fn u -> Enum.any?(ups, &pattern_match?(&1, u)) end), do: i
    end)
  end

  defp by_name_or_path(m, spec) do
    Enum.find_value(Enum.with_index(spec), fn {t, i} ->
      if Enum.any?(patterns(t), &pattern_match?(&1, m.name)) or
           Enum.any?(layer_opt(t, :paths, []), &path_match?(&1, m.file)),
         do: i
    end)
  end

  defp patterns({_name, pats}), do: pats
  defp patterns({_name, pats, _opts}), do: pats

  defp layer_opt({_n, _p}, _key, default), do: default
  defp layer_opt({_n, _p, opts}, key, default), do: Keyword.get(opts, key, default)

  defp pattern_match?(%Regex{} = re, mod), do: Regex.match?(re, mod)
  defp pattern_match?(p, mod) when is_binary(p), do: String.contains?(mod, p)

  defp path_match?(%Regex{} = re, file) when is_binary(file), do: Regex.match?(re, file)
  defp path_match?(p, file) when is_binary(p) and is_binary(file), do: String.contains?(file, p)
  defp path_match?(_, _), do: false
end
