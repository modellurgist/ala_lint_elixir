defmodule AlaLint.Rules do
  @moduledoc """
  The R1–R11 detectors over the project model (`AlaLint.Analyzer.build/1`).

  Precision is honest and labelled: some rules are exact (R1 cycles, R5
  duplicated literals, R4 process dictionary), others are heuristic proxies for
  a judgement the ALA Checklist leaves to a reader (R3 magic literals, R6
  naming/primitive-wrapping, R7 single-use privates). R8 (readability) is not
  auto-checked — it is judgement, reported only as a reminder.
  """

  alias AlaLint.Finding

  @weights %{r1: 3, r1_ref: 3, r2: 3, r5: 3, r10: 3, r10_aggregate: 3, r4: 2, r3: 1, r6: 1, r7: 1, r11: 1, module_size: 1, height: 1, passthrough: 1, public_surface: 1, layer: 3}
  def weights, do: @weights

  # Advisory rules that a strict mode promotes to scored. `--strict` promotes the
  # obtainable ones; R11, public_surface, and R10-aggregate are aspirational and
  # promoted only by `--super-strict` (see AlaLint.analyze).
  @advisory_rules [:r7, :r11, :module_size, :height, :passthrough, :public_surface, :r1_ref]
  def advisory_rules, do: @advisory_rules

  # Default severity per rule. `:warn` findings are reported but excluded from
  # the score unless the caller enforces the rule (`enforce: [:r7]`). R7 is
  # advisory because Spray never required reuse: an abstraction may exist for
  # its own sake, so "unearned/single-use" is a prompt to a human, not a fail.
  # `:height` (abstraction depth) is likewise a design smell to notice, not a
  # gate.
  @severity %{r7: :warn, height: :warn, passthrough: :warn, r1_ref: :warn, r11: :warn, module_size: :warn, public_surface: :warn, r10_aggregate: :warn}
  def default_severity(rule), do: Map.get(@severity, rule, :error)

  # Control-flow / composition forms whose presence means a body is more than a
  # single bare call (used by both the pass-through and the R7-triviality checks).
  @nontrivial_forms [:__block__, :|>, :case, :cond, :if, :unless, :with, :for, :fn, :try, :receive, :quote]

  @doc "Run every rule; returns a flat list of findings."
  def run(model) do
    r1(model) ++ r1_reference(model) ++ r2(model) ++ r3(model) ++ r4(model) ++ r5(model) ++ r6(model) ++ r7(model) ++
      r10(model) ++ r10_aggregate(model) ++ r11(model) ++ module_size(model) ++ height(model) ++ passthrough(model) ++ public_surface(model) ++ layer_validity(model)
  end

  # ── R10: no shared entity. A domain struct that carries an app-identity's
  # data must not be read by two *peer* features; share only an identity key and
  # keep data private. Heuristic: a struct-defining module referenced by ≥2
  # distinct feature units (peer-forbidden layer) is a shared-entity candidate.
  # Needs a layer map (to know which referrers are peer features). ───────────
  def r10(%{layers: %{index: idx, peer_ok: peer_ok, units: units}} = model) do
    for m <- model.modules,
        m.defines_struct,
        # only an entity in a peer-forbidden (feature) tier: a struct in a
        # peer_ok layer (a domain/platform abstraction) is *declared shareable*,
        # so features depending on it is a legal knowledge drop, not R10.
        si = idx[m.name],
        si != nil,
        not Map.get(peer_ok, si, true),
        units_sharing = entity_sharers(m, model, idx, peer_ok, units),
        MapSet.size(units_sharing) >= 2 do
      who = units_sharing |> Enum.map(&short/1) |> Enum.sort() |> Enum.join(", ")
      f(:r10, m.name, model, m, m.line,
        "entity #{short(m.name)} is read by #{MapSet.size(units_sharing)} peer features (#{who}) — share an identity key and keep data private (R10)")
    end
  end

  def r10(_model), do: []

  # ── R10 (aggregate) — a shared *domain* aggregate. Only runs when
  # `check_aggregates` is on (strict/super-strict). Where R10 flags a
  # feature-tier entity shared across peers, this flags a struct in a *shareable*
  # (peer_ok) layer that ≥2 features read: a legitimate domain abstraction, or
  # Clean's shared-Entity coupling? A human decides. Advisory; super-strict
  # scores it (via the enforce list). ───────────────────────────────────────
  def r10_aggregate(%{check_aggregates: true, layers: %{index: idx, peer_ok: peer_ok, units: units}} = model) do
    for m <- model.modules,
        m.defines_struct,
        si = idx[m.name],
        si != nil,
        Map.get(peer_ok, si, true),
        units_sharing = entity_sharers(m, model, idx, peer_ok, units),
        MapSet.size(units_sharing) >= 2 do
      who = units_sharing |> Enum.map(&short/1) |> Enum.sort() |> Enum.join(", ")
      f(:r10_aggregate, m.name, model, m, m.line,
        "domain aggregate #{short(m.name)} is read by #{MapSet.size(units_sharing)} features (#{who}) — a shared aggregate couples them; consider per-feature private data + an identity key (R10, strict)")
    end
  end

  def r10_aggregate(_model), do: []

  # Distinct feature *units* (a feature and its own submodules count once) that
  # reference the struct module, including the struct's own feature.
  defp entity_sharers(struct_mod, model, idx, peer_ok, units) do
    for m <- model.modules,
        MapSet.member?(m.refs, struct_mod.name) or m.name == struct_mod.name,
        i = idx[m.name],
        i != nil,
        not Map.get(peer_ok, i, true),
        into: MapSet.new() do
      AlaLint.Layers.unit(m.name, units[i])
    end
  end

  # ── R11: the application (top) layer is composition only (advisory). Two
  # signals: the top layer is a large share of the code, and top-layer functions
  # branch beyond sequencing wiring. Both are relaxations for source-encoded
  # app layers, so they are reported, not scored. Needs a layer map. ─────────
  def r11(%{layers: %{fun_index: fi, app_layers: app}} = model) do
    total = max(map_size(fi), 1)
    app_ids = for {id, i} <- fi, MapSet.member?(app, i), do: id
    share = length(app_ids) / total
    max_share = Map.get(model, :max_app_share, 0.20)

    size =
      if share > max_share do
        [f(:r11, "(project)", model, "the application layer is #{round(share * 100)}% of functions (> #{round(max_share * 100)}%) — the top layer should be mostly wiring + config, not logic (R11)")]
      else
        []
      end

    # Check *every* clause of a multi-clause def, not just the one that survives
    # the {module,name,arity} index — a `handle/3` whose 3rd clause branches must
    # be flagged even if the last clause is straight wiring. One finding per
    # function, anchored at its first branchy clause.
    app_id_set = MapSet.new(app_ids)

    branches =
      for m <- model.modules,
          {{name, arity}, clauses} <- Enum.group_by(m.functions, &{&1.name, &1.arity}),
          MapSet.member?(app_id_set, {m.name, name, arity}),
          branchy = Enum.find(clauses, &branchy?(&1.body)),
          branchy != nil do
        f(:r11, m.name, model, m, branchy.line,
          "#{short(m.name)}.#{name}/#{arity} branches in the application layer — the top layer should read as wiring + config; move logic below it (R11)")
      end

    size ++ branches
  end

  def r11(_model), do: []

  @branch_forms [:if, :unless, :case, :cond, :with]
  @doc "Does a function body contain control-flow branching (if/unless/case/cond/with)? Public so the encoder can mark R11 in the notation."
  def branchy?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {form, _, _} = node, _ when form in @branch_forms -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # ── Module size (advisory, R7 complement). An abstraction should be readable
  # in isolation; ~500 lines is a rough cap. `loc` is accurate for single-module
  # files (the common case) and approximate otherwise. ──────────────────────
  def module_size(model) do
    max = Map.get(model, :max_module_loc, 500)

    for m <- model.modules, m.loc > max do
      f(:module_size, m.name, model, m, m.line,
        "module #{short(m.name)} is #{m.loc} lines (> #{max}) — an abstraction should be readable in isolation; check it is really one concept (R7-adjacent)")
    end
  end

  # ── Public surface (advisory). A little ball of mud is fine when its mess is
  # *encapsulated*: a small public surface over a private bulk. A module that
  # exposes many public functions is letting peers depend on its internals, so
  # its boundary is fiction. Counts public `def`s per module against a cap. A
  # rough proxy for encapsulation (Elixir has no package-private, so wide API
  # is sometimes legitimate); tune with `--max-public-funs`, default 12. ──────
  def public_surface(model) do
    max = Map.get(model, :max_public_funs, 12)

    for m <- model.modules,
        publics = Enum.count(m.functions, &(not &1.private)),
        publics > max do
      f(:public_surface, m.name, model, m, m.line,
        "module #{short(m.name)} exposes #{publics} public functions (> #{max}) — a wide public surface leaks internals; keep the mess private behind a small boundary, and confirm this is one concept (R6/R7-adjacent)")
    end
  end

  # Recall companion to the function-level R1 (advisory). Function-level R1 sees
  # only real Elixir calls, so a cross-feature call embedded in a `~H` template
  # — invisible to the AST — slips past it, even though the feature still
  # `alias`es the peer. This checks the MODULE reference graph (which does see
  # that alias) for altitude violations that have NO direct function call
  # between the modules, and reports them as warnings to verify by eye. It is
  # advisory precisely because a bare alias/type reference is not always a
  # coupling — but in LiveView it usually is a template call.
  def r1_reference(%{layers: %{index: idx, peer_ok: peer_ok, units: units}} = model) do
    call_pairs =
      for {{cm, _, _}, callees} <- model.call_graph, {tm, _, _} <- callees, into: MapSet.new(), do: {cm, tm}

    for {a, deps} <- model.dep_graph, b <- deps,
        not MapSet.member?(call_pairs, {a, b}),
        ia = idx[a], ib = idx[b], ia != nil and ib != nil,
        violation = altitude_violation(a, b, ia, ib, peer_ok, units) do
      f(:r1_ref, a, model,
        "#{short(a)} → #{short(b)}: #{violation} — reference-level only (alias/type/template use, no direct call in the AST; in LiveView this is usually a cross-feature call inside a ~H template) — verify")
    end
  end

  def r1_reference(_model), do: []

  # Assignment validity: a function tagged `@ala_layer :x` where :x is not a
  # declared layer is a typo or a stale tag — a hard error (distinct from R1
  # behaviour and from the coverage gap of *unassigned* functions).
  def layer_validity(%{layers: %{unknown_tags: unknown}} = model) when unknown != [] do
    by_id = fun_lookup(model)

    for {{mod, name, arity} = id, tag} <- unknown do
      {m, fun} = Map.get(by_id, id, {nil, nil})
      f(:layer, mod, model, m, fun && fun.line,
        "#{short(mod)}.#{name}/#{arity} is tagged @ala_layer #{inspect(tag)}, which is not a declared layer — fix the tag or declare the layer")
    end
  end

  def layer_validity(_model), do: []

  @doc """
  The abstraction height — the longest chain in the function call graph, where a
  call **within the application layer costs 0** (the whole app layer is one
  altitude: its shell → page → view sub-layers are wiring, not added depth).
  Every other edge costs 1. Without a layer map, all edges cost 1 (raw chain).
  """
  def height_value(model), do: longest_chain(model.call_graph, edge_cost(model))

  # Returns fn(caller, callee) -> 0 | 1. An edge costs 0 (does not add altitude)
  # when it stays *inside one abstraction*: a call within the same module is
  # internal decomposition of a little ball of mud, not a new layer. Calls
  # within the application layer likewise collapse to one altitude. Everything
  # else is a real drop between abstractions and costs 1, so proliferation
  # *between* abstractions still shows up.
  defp edge_cost(%{layers: %{fun_index: fidx, app_layers: app}}) do
    fn a, b ->
      cond do
        elem(a, 0) == elem(b, 0) -> 0
        MapSet.member?(app, Map.get(fidx, a)) and MapSet.member?(app, Map.get(fidx, b)) -> 0
        true -> 1
      end
    end
  end

  defp edge_cost(_model), do: fn a, b -> if elem(a, 0) == elem(b, 0), do: 0, else: 1 end

  @doc """
  Abstraction height as findings — the length (in modules) of the longest chain
  of knowledge-dependency edges. Deep chains are one signature of helper
  proliferation: a real requirement rarely needs more than a handful of
  altitudes. Assumes an acyclic graph (any cycle is itself an R1 violation);
  a cycle is treated as not extending the chain rather than looping forever.
  """
  def height(model) do
    depth = height_value(model)
    max = Map.get(model, :max_height, 5)

    if depth > max do
      [f(:height, "(project)", model, "abstraction height is #{depth} levels deep (> #{max}) — counting hops *between* abstractions (calls inside one module are internal decomposition and do not add altitude); deep chains can hide helper proliferation (R7-adjacent)")]
    else
      []
    end
  end

  @doc """
  Pass-through detector (advisory). A **public** function with exactly one
  caller and exactly one project-internal callee **in another module**, whose
  body is just that delegating call, is a *rename*: it adds a name and a call
  hop over a different abstraction but hides no decision, so it is wiring
  dressed as an abstraction (the classic helper-proliferation shape). Scoped to
  the abstraction graph: a private helper, or a call within the same module, is
  internal decomposition of a little ball of mud and is left alone. See the
  checklist's "Helper proliferation" section.
  """
  def passthrough(model) do
    by_id = fun_lookup(model)

    for {id, {cmod, cname, carity}} <- passthrough_ids(model), {m, fun} = Map.get(by_id, id) do
      f(:passthrough, m.name, model, m, fun.line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} is a pass-through (1 caller, 1 callee → #{short(cmod)}.#{cname}/#{carity}); it renames a call without hiding a decision — consider inlining (R7-adjacent)")
    end
  end

  @doc "Pass-through function ids → their single callee, as `[{ {mod,name,arity}, {cmod,cname,carity} }]`. Public so the encoder can mark `~>` in the notation."
  def passthrough_ids(model) do
    g = model.call_graph
    indeg = in_degrees(g)
    by_id = fun_lookup(model)
    template_refs = Map.get(model, :template_refs, MapSet.new())

    for {id, callees} <- g,
        MapSet.size(callees) == 1,
        Map.get(indeg, id, 0) == 1,
        {m, fun} = Map.get(by_id, id),
        fun != nil,
        not fun.private,
        [{cmod, _cn, _ca} = callee] = MapSet.to_list(callees),
        cmod != m.name,
        not fun.macro_generated,
        not predicate?(fun.name),
        not MapSet.member?(template_refs, to_string(fun.name)),
        single_call_body?(fun.body) do
      {id, callee}
    end
  end

  # A predicate (`name?`) that forwards to a non-predicate operation is not a
  # bare rename: it reframes the callee's result as a yes/no question, which is
  # a decision. Leave those to a reader rather than calling them pass-throughs.
  defp predicate?(name), do: String.ends_with?(to_string(name), "?")

  defp in_degrees(g) do
    for {_caller, callees} <- g, callee <- callees, reduce: %{} do
      acc -> Map.update(acc, callee, 1, &(&1 + 1))
    end
  end

  # The body is a single call expression — a bare local/remote call, or a
  # pipe of a *plain term* into one — and nothing else (no block, no branch, no
  # binding). A pipe whose left is itself a call or a struct build is a
  # transform, not a rename (`subtotal_cents(x) |> Money.new()`,
  # `%Foo{...} |> recompute()`), so it is not a pass-through.
  defp single_call_body?({:|>, _, [left, {{:., _, _}, _, _}]}), do: bare_operand?(left)
  defp single_call_body?({:|>, _, [left, {name, _, args}]}) when is_atom(name) and is_list(args),
    do: bare_operand?(left)
  defp single_call_body?({{:., _, _}, _, args}) when is_list(args), do: true
  # A map/struct update or construction, or a tuple, builds a value; a call
  # embedded in one of its fields is a computation, not a delegating rename
  # (`%{s | field: Callee.f(...)}`, `%Struct{...}`, `{a, Callee.f(x)}`).
  defp single_call_body?({:%{}, _, _}), do: false
  defp single_call_body?({:%, _, _}), do: false
  defp single_call_body?({:{}, _, _}), do: false
  defp single_call_body?({name, _, args}) when is_atom(name) and is_list(args) and name not in @nontrivial_forms, do: true
  defp single_call_body?(_), do: false

  # A variable or a literal — not a call, not a struct/map/tuple construction.
  defp bare_operand?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp bare_operand?(lit) when is_binary(lit) or is_number(lit) or is_atom(lit), do: true
  defp bare_operand?(_), do: false

  # fun_id → {module_struct, fun_struct}, for locating a function-level finding.
  defp fun_lookup(model) do
    for m <- model.modules, fun <- m.functions, into: %{}, do: {{m.name, fun.name, fun.arity}, {m, fun}}
  end

  defp longest_chain(graph, cost) do
    {best, _memo} =
      Enum.reduce(Map.keys(graph), {0, %{}}, fn node, {best, memo} ->
        {d, memo} = chain_from(graph, node, MapSet.new(), memo, cost)
        {max(best, d), memo}
      end)

    best
  end

  # Longest cost-weighted descent from `node`; a node's own level is the base 1
  # at the deepest leaf, and each edge adds `cost` (0 collapses the step). With
  # all-cost-1 this equals the node count of the longest chain.
  defp chain_from(graph, node, stack, memo, cost) do
    cond do
      Map.has_key?(memo, node) ->
        {memo[node], memo}

      MapSet.member?(stack, node) ->
        {0, memo}

      true ->
        children = Map.get(graph, node, MapSet.new())

        {best, memo} =
          Enum.reduce(children, {0, memo}, fn nb, {mx, memo} ->
            {d, memo} = chain_from(graph, nb, MapSet.put(stack, node), memo, cost)
            {max(mx, cost.(node, nb) + d), memo}
          end)

        d = max(best, 1)
        {d, Map.put(memo, node, d)}
    end
  end

  # ── R1: knowledge flows down. With a layer map, check altitude directly;
  # without one, fall back to the config-free proxy (dependency cycles). ──
  def r1(%{layers: nil} = model), do: r1_cycles(model)
  def r1(model), do: r1_altitude(model)

  defp r1_cycles(model) do
    g = model.dep_graph

    for {a, deps} <- g, b <- deps, b > a, reaches?(g, b, a) do
      f(:r1, a, model, "modules #{a} ↔ #{b} form a dependency cycle (peer/communication coupling — an edge that does not drop)")
    end
  end

  # Every edge must drop to a MORE ABSTRACT layer. Now checked on the
  # FUNCTION call graph against each function's assigned layer: upward edges
  # (callee more concrete) are hard violations; same-layer edges in a
  # peer-forbidden layer are peer coupling (two functions in different feature
  # units calling each other). Unassigned endpoints are skipped — that gap is
  # the coverage metric's job, not an R1 violation.
  defp r1_altitude(model) do
    %{fun_index: fidx, peer_ok: peer_ok, units: units, names: names} = model.layers
    by_id = fun_lookup(model)

    for {caller, callees} <- model.call_graph, callee <- callees,
        ia = fidx[caller], ib = fidx[callee], ia != nil and ib != nil,
        violation = altitude_violation(elem(caller, 0), elem(callee, 0), ia, ib, peer_ok, units) do
      {cmod, cname, car} = caller
      {tmod, tname, tar} = callee
      {m, fun} = Map.get(by_id, caller, {nil, nil})

      f(:r1, cmod, model, m, fun && fun.line,
        "#{short(cmod)}.#{cname}/#{car} [#{Enum.at(names, ia)}] → #{short(tmod)}.#{tname}/#{tar} [#{Enum.at(names, ib)}]: #{violation}")
    end
  end

  # Only UP (ib < ia) and same-layer PEER are violations. A drop of ANY size is
  # legal in ALA — a knowledge dependency may target any lower layer, so a big
  # altitude skip (a "long drop", ib ≫ ia) is NOT a smell. Do not add a check
  # that penalizes long drops. (See the checklist's "long drop" note.)
  defp altitude_violation(_a, _b, ia, ib, _peer_ok, _units) when ib < ia,
    do: "knowledge flows UP (callee is more concrete) — edge must drop to a more abstract layer (R1)"

  defp altitude_violation(a, b, ia, ib, peer_ok, units) when ia == ib do
    cond do
      Map.get(peer_ok, ia, true) -> nil
      # same-unit modules (a feature and its own submodules) are cohesion, not peers
      AlaLint.Layers.unit(a, units[ia]) == AlaLint.Layers.unit(b, units[ia]) -> nil
      true -> "cross-peer edge in a peer-forbidden layer (feature ↔ feature coupling) (R1)"
    end
  end

  defp altitude_violation(_a, _b, _ia, _ib, _peer_ok, _units), do: nil

  defp reaches?(g, from, target) do
    {found, _seen} = reach(g, from, target, MapSet.new())
    found
  end

  # Thread `seen` through the neighbor fold so a node is explored once per call,
  # not once per path. Without this, diamond-shaped graphs blow up exponentially.
  defp reach(_g, from, target, seen) when from == target, do: {true, seen}

  defp reach(g, from, target, seen) do
    if MapSet.member?(seen, from) do
      {false, seen}
    else
      seen = MapSet.put(seen, from)

      g
      |> Map.get(from, MapSet.new())
      |> Enum.reduce_while({false, seen}, fn nb, {_found, s} ->
        case reach(g, nb, target, s) do
          {true, s2} -> {:halt, {true, s2}}
          {false, s2} -> {:cont, {false, s2}}
        end
      end)
    end
  end

  # ── R2: shared mutable state channels (advisory) ─────────────────────────
  def r2(model) do
    for m <- model.modules, {{kind, op}, line} <- m.state_ops, kind in [:ets, :persistent_term, :agent] do
      f(:r2, m.name, model, m, line,
        "#{kind}.#{op} — shared mutable state channel; confirm it is not a back-channel between peers (R2)")
    end
  end

  # ── R3: application literals baked into a lower abstraction (heuristic) ───
  # Flags "policy-ish" literals: floats, integers ≥ 10 (excluding round
  # placeholders), and any string/atom literal that also looks like config.
  def r3(model) do
    for m <- model.modules, r3_scannable?(model, m.name), {lit, line} <- m.literals, magic?(lit) do
      f(:r3, m.name, model, m, line, "literal #{fmt_lit(lit)} in #{short(m.name)} below the composition — hoist it if it's an application literal, keep it if intrinsic to the abstraction (R3)")
    end
  end

  # With a layer map, application literals are allowed only in the top (composition)
  # layer — flag magic literals in any lower layer. Without one, fall back to
  # the config_modules exclusion.
  defp r3_scannable?(%{layers: nil} = model, name), do: name not in config_modules(model)

  defp r3_scannable?(%{layers: %{index: idx, config_layers: config}}, name) do
    case Map.get(idx, name) do
      nil -> true
      i -> not MapSet.member?(config, i)
    end
  end

  @doc "Whether a literal is an application-literal candidate (a possible R3 hoist). Public so the encoder can seed the same `{app-literal?}` flags the source scan would raise."
  def magic?({:number, n}) when is_float(n), do: true
  def magic?({:number, n}) when is_integer(n), do: n not in [0, 1, 2, -1, 10, 100, 1000, 24, 60] and n > 2
  def magic?({:string, _}), do: false
  def magic?({:atom, _}), do: false

  # ── R4: hidden state — the process dictionary (exact) ────────────────────
  def r4(model) do
    for m <- model.modules, {{:process_dict, op}, line} <- m.state_ops do
      f(:r4, m.name, model, m, line, "Process.#{op} — hidden state via the process dictionary; thread state as a value instead (R4)")
    end
  end

  # ── R5: duplicated literal contracts across modules (exact) ──────────────
  def r5(model) do
    for {lit, mods} <- model.literal_index,
        contractish?(lit),
        MapSet.size(mods) >= 2 do
      owner = mods |> Enum.sort() |> hd()
      m = Enum.find(model.modules, &(&1.name == owner))
      f(:r5, owner, model, m, m.line,
        "literal #{fmt_lit(lit)} is repeated across #{MapSet.size(mods)} modules (#{mods |> Enum.sort() |> Enum.map(&short/1) |> Enum.join(", ")}) — single-source it (R5)")
    end
  end

  # A silent contract is a shared **identifier-like string** — an event name,
  # topic, key, or dom-id (`"move_to_cart"`, `"item-removed"`), not CSS classes
  # or prose labels. So: no whitespace (excludes `"text-sm text-blue-600"` and
  # `"Move to cart"`), length 3–40 (excludes markup fragments), and it must
  # contain a letter. This is what isolates real cross-boundary contracts from
  # the mass of markup/label strings a Phoenix app repeats across components.
  # Atoms are excluded (pervasive keyword/field noise); numbers → R3.
  defp contractish?({:string, s}) do
    String.length(s) in 3..40 and not String.match?(s, ~r/\s/) and String.match?(s, ~r/[a-zA-Z]/)
  end

  defp contractish?({:atom, _}), do: false
  defp contractish?({:number, _}), do: false

  # ── R6: nameability (heuristic) ──────────────────────────────────────────
  def r6(model) do
    name_findings =
      for m <- model.modules, fun <- m.functions, meaningless_name?(fun.name) do
        f(:r6, m.name, model, m, fun.line, "function #{short(m.name)}.#{fun.name}/#{fun.arity} has a meaningless name — name the concept or inline it (R6)")
      end

    wrap_findings =
      for m <- model.modules, fun <- m.functions, not fun.private, primitive_wrapper?(fun) do
        f(:r6, m.name, model, m, fun.line, "#{short(m.name)}.#{fun.name}/#{fun.arity} just wraps a primitive/stdlib call — not an abstraction (R6)")
      end

    name_findings ++ wrap_findings
  end

  @meaningless ~w(f g h x y z do_it thing stuff foo bar baz tmp op fn1 f1 f2 f3)a
  defp meaningless_name?(name) do
    s = Atom.to_string(name)
    name in @meaningless or Regex.match?(~r/^[a-z]$/, s) or Regex.match?(~r/^[a-z]\d+$/, s)
  end

  # A genuine primitive wrapper *renames* one operator: `f(x, y) = x + y`. Both
  # operands must be bare terminals (a variable or a literal). If either operand
  # is a compound expression — a nested op, a struct-field read, another call —
  # the function is doing real work (a formula, composing values)
  # and is a legitimate abstraction, not a rename. This spares e.g.
  # `apply(oas, r) = (r + oas.offset) * oas.scale`, whose operand is a `+` expr.
  defp primitive_wrapper?(%{body: {op, _, [a, b]}}) when op in [:+, :-, :*, :/, :>=, :<=, :>, :<, :==, :!=],
    do: terminal_operand?(a) and terminal_operand?(b)

  defp primitive_wrapper?(_), do: false

  # A bare variable (`{:x, _, ctx}` with atom context/nil) or a literal.
  defp terminal_operand?({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)), do: true
  defp terminal_operand?(lit) when is_number(lit) or is_binary(lit) or is_atom(lit), do: true
  defp terminal_operand?(_), do: false

  # ── R7: abstraction earns its existence (heuristic, conservative) ────────
  # A private called *once* is NOT flagged — a named pipeline step earns its
  # place by readability even at one call site (the R7-vs-readability tension,
  # resolved toward keeping helpers). Two low-noise signals only:
  #   (a) dead private — 0 local calls (unambiguous; privates are module-local);
  #   (b) trivial single-use one-liner whose name is also meaningless
  #       (intersects R6): the clear premature-extraction case.
  def r7(model) do
    template_refs = Map.get(model, :template_refs, MapSet.new())

    dead =
      for m <- model.modules, fun <- m.functions, fun.private, uniq_defp?(m, fun),
          Map.get(m.local_call_counts, fun.name, 0) == 0,
          not fun.macro_generated,
          not MapSet.member?(template_refs, to_string(fun.name)) do
        f(:r7, m.name, model, m, fun.line, "private #{short(m.name)}.#{fun.name}/#{fun.arity} is never called — dead code (R7)")
      end

    trivial =
      for m <- model.modules, fun <- m.functions, fun.private,
          Map.get(m.local_call_counts, fun.name, 0) == 1,
          trivial?(fun.body), meaningless_name?(fun.name) do
        f(:r7, m.name, model, m, fun.line, "private #{short(m.name)}.#{fun.name}/#{fun.arity} is a trivial single-use one-liner — inline it (R7)")
      end

    dead ++ trivial
  end

  # only single-clause defps for the dead check (multi-clause names dispatch
  # dynamically and are easy to under-count)
  defp uniq_defp?(m, fun), do: Enum.count(m.functions, &(&1.name == fun.name)) == 1

  # "Trivial" = genuinely inlinable: a single simple expression that is NOT
  # doing real structured work. A named pipeline step, a case/with/for, or a
  # multi-statement body is legitimate decomposition (it earns its place by
  # readability even at one call site) and must NOT be flagged — that is the
  # R7-vs-readability tension, resolved conservatively toward keeping helpers.
  defp trivial?(nil), do: false
  defp trivial?({form, _, _}) when form in @nontrivial_forms, do: false
  defp trivial?({_, _, args}) when is_list(args), do: true
  defp trivial?(lit) when is_binary(lit) or is_number(lit) or is_atom(lit), do: true
  defp trivial?(_), do: false

  # ── shared helpers ────────────────────────────────────────────────────
  defp config_modules(model), do: Map.get(model, :config_modules, [])

  defp f(rule, module, model, mod \\ nil, line \\ nil, message)

  defp f(rule, module, model, nil, nil, message) do
    m = Enum.find(model.modules, &(&1.name == module))
    %Finding{rule: rule, module: module, file: m && m.file, line: (m && m.line) || 0, weight: @weights[rule], severity: default_severity(rule), message: message}
  end

  defp f(rule, module, _model, %{} = mod, line, message) do
    %Finding{rule: rule, module: module, file: mod.file, line: line || mod.line, weight: @weights[rule], severity: default_severity(rule), message: message}
  end

  defp short(name), do: String.replace_prefix(name, "Elixir.", "") |> String.split(".") |> List.last()

  defp fmt_lit({:string, s}), do: inspect(s)
  defp fmt_lit({:atom, a}), do: inspect(a)
  defp fmt_lit({:number, n}), do: to_string(n)
end
