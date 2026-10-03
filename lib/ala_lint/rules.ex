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

  @weights %{
    r1: 3,
    r1_ref: 3,
    r9: 3,
    subscribe: 1,
    r2: 3,
    r5: 3,
    r10: 3,
    r10_aggregate: 3,
    r4: 2,
    r3: 1,
    r6: 1,
    r7: 1,
    r11: 1,
    module_size: 1,
    module_avg: 1,
    app_share: 1,
    height: 1,
    passthrough: 1,
    tramp: 1,
    public_surface: 1,
    layer: 3,
    ports: 2,
    ports_unwired: 1,
    wiring_closure: 1,
    r11_share: 1,
    hops: 1,
    vocabulary: 1,
    unassigned: 1,
    ui_io: 1,
    subcomponent: 1
  }
  def weights, do: @weights

  # Advisory rules that a strict mode promotes to scored. `--strict` promotes the
  # obtainable ones; R11 and public_surface are aspirational and promoted only by
  # `--super-strict` (see AlaLint.analyze). Not listed, so never promoted by a
  # tier (only by `--enforce`): app_share and module_avg (ratios that penalise an
  # app for having many pages or small single-function abstractions). Since
  # 2026-10-03 r10_aggregate is scored by `--strict`: Spray's shared entity
  # (§6.17.2) read strictly, a domain struct several features read.
  @advisory_rules [
    :r7,
    :r11,
    :module_size,
    :height,
    :passthrough,
    :tramp,
    :public_surface,
    :r1_ref,
    :subscribe,
    :ports,
    :ui_io,
    :subcomponent,
    :r10_aggregate
  ]
  def advisory_rules, do: @advisory_rules

  # Default severity per rule. `:warn` findings are reported but excluded from
  # the score unless the caller enforces the rule (`enforce: [:r7]`). R7 is
  # advisory because Spray never required reuse: an abstraction may exist for
  # its own sake, so "unearned/single-use" is a prompt to a human, not a fail.
  # `:height` (abstraction depth) is likewise a design smell to notice, not a
  # gate.
  @severity %{
    r7: :warn,
    height: :warn,
    passthrough: :warn,
    tramp: :warn,
    r1_ref: :warn,
    subscribe: :warn,
    r11: :warn,
    module_size: :warn,
    module_avg: :warn,
    app_share: :warn,
    public_surface: :warn,
    r10_aggregate: :warn,
    ports: :warn,
    ports_unwired: :warn,
    wiring_closure: :warn,
    r11_share: :info,
    hops: :info,
    vocabulary: :info,
    unassigned: :warn,
    ui_io: :warn,
    subcomponent: :warn
  }
  def default_severity(rule), do: Map.get(@severity, rule, :error)

  # Control-flow / composition forms whose presence means a body is more than a
  # single bare call (used by both the pass-through and the R7-triviality checks).
  @nontrivial_forms [
    :__block__,
    :|>,
    :case,
    :cond,
    :if,
    :unless,
    :with,
    :for,
    :fn,
    :try,
    :receive,
    :quote
  ]

  @doc "Run every rule; returns a flat list of findings."
  def run(model) do
    findings = base_run(model) ++ AlaLint.LiveViewRules.run(model) ++ unassigned(model)
    findings ++ AlaLint.LiveViewRules.logic_share(model, findings)
  end

  defp base_run(model) do
    r1(model) ++
      r1_reference(model) ++
      subscribe(model) ++
      r2(model) ++
      r3(model) ++
      r3_text(model) ++
      r4(model) ++
      r5(model) ++
      r6(model) ++
      tramp(model) ++
      r7(model) ++
      r9(model) ++
      r10(model) ++
      r10_aggregate(model) ++
      r11(model) ++
      module_size(model) ++
      height(model) ++ passthrough(model) ++ public_surface(model) ++ layer_validity(model)
  end

  # ── R9: an abstraction owns no interface except its own configuration. A
  # behaviour or protocol is a port only when it sits in a layer *below* its
  # implementers (a paradigm port, or a far more general module like GenServer
  # that higher modules configure). Implemented by a peer in its own layer, it
  # is a required/provided interface between peers; implemented by a lower
  # layer, the lower module is written to a higher one's design. Needs a layer
  # map; exact on explicit `@behaviour` / `defimpl`. ──────────────────────────
  def r9(%{layers: %{index: idx, peer_ok: peer_ok, units: units, names: names}} = model) do
    ifaces = for m <- model.modules, m.interface != nil, into: %{}, do: {m.name, m}

    for m <- model.modules,
        {iface, implementer, line} <- m.implements,
        definer = ifaces[iface],
        definer != nil,
        d = idx[definer.name],
        i = idx[implementer],
        d != nil and i != nil,
        violation = owned_interface(definer.name, implementer, d, i, peer_ok, units) do
      f(
        :r9,
        m.name,
        model,
        m,
        line,
        "#{short(implementer)} [#{Enum.at(names, i)}] implements #{short(definer.name)} [#{Enum.at(names, d)}], a #{definer.interface} #{violation} — put port interfaces in a lower (paradigm) layer, owned by neither side (R9)"
      )
    end
  end

  def r9(_model), do: []

  defp owned_interface(_definer, _impl, d, i, _peer_ok, _units) when i > d,
    do: "owned by a more concrete layer"

  defp owned_interface(definer, impl, d, i, peer_ok, units) when i == d do
    cond do
      Map.get(peer_ok, d, true) -> nil
      AlaLint.Layers.unit(definer, units[d]) == AlaLint.Layers.unit(impl, units[d]) -> nil
      true -> "owned by a peer in the same layer"
    end
  end

  defp owned_interface(_definer, _impl, _d, _i, _peer_ok, _units), do: nil

  # ── Self-subscription (R1, advisory). "Receivers never register themselves to
  # a sender, or to a public event" (Spray §4.4.2). A `subscribe` call with a
  # topic fixed in the module (a literal or a module attribute) outside the
  # application layer is a module choosing its own sender. The application
  # subscribing, or passing the topic down as an argument, is the wiring. ─────
  def subscribe(model) do
    for m <- model.modules,
        {line, kind} <- m.subscriptions,
        kind in [:literal, :attribute],
        not app_module?(model, m.name),
        not bottom_module?(model, m.name) do
      f(
        :subscribe,
        m.name,
        model,
        m,
        line,
        "#{short(m.name)} subscribes to a topic it fixes itself (#{kind}) — a receiver choosing its own sender; subscribe in the application (e.g. mount/3), or take the topic as configuration (R1/R5)"
      )
    end
  end

  defp app_module?(%{layers: %{index: idx, app_layers: app}}, name),
    do: MapSet.member?(app, Map.get(idx, name))

  # Without a layer map there is no application layer to exempt; stay quiet
  # rather than flag every page's own subscription.
  defp app_module?(_model, _name), do: true

  # The lowest declared layer is where a technical domain (PubSub, a repo) is abstracted;
  # such a module owning its topic name is encapsulation, not self-registration.
  defp bottom_module?(%{layers: %{index: idx, names: names}}, name),
    do: Map.get(idx, name) == length(names) - 1

  defp bottom_module?(_model, _name), do: false

  # ── R10: no shared entity. A domain struct that carries an app-identity's
  # data must not be read by two *peer* features; share only an identity key and
  # keep data private. Heuristic: a struct-defining module referenced by ≥2
  # distinct feature units (peer-forbidden layer) is a shared-entity candidate.
  # Needs a layer map (to know which referrers are peer features). ───────────
  def r10(%{layers: %{index: idx, peer_ok: peer_ok, units: units}} = model) do
    for m <- model.modules,
        m.defines_struct,
        # Peer sharing only: two units *of the struct's own* peer-forbidden layer
        # read it. Units in higher layers reading a lower struct is a knowledge
        # dependency (at most the aggregate case below), not R10.
        si = idx[m.name],
        si != nil,
        not Map.get(peer_ok, si, true),
        units_sharing = entity_sharers(m, model, idx, peer_ok, units, &(&1 == si)),
        MapSet.size(units_sharing) >= 2 do
      who = units_sharing |> Enum.map(&short/1) |> Enum.sort() |> Enum.join(", ")

      f(
        :r10,
        m.name,
        model,
        m,
        m.line,
        "entity #{short(m.name)} is read by #{MapSet.size(units_sharing)} peer features (#{who}) — share an identity key and keep data private (R10)"
      )
    end
  end

  def r10(_model), do: []

  # ── Unassigned: a module the layer map doesn't place. Every layer-aware check
  # (R1 altitude, R3, R10, R11, the LiveView checks) skips it, so the score
  # silently covers less of the codebase. Reported loudly at every tier; scored
  # only when enforced (`--enforce unassigned`), and `--require-layers` fails CI. ──
  def unassigned(%{layers: %{index: idx}} = model) do
    # a module with no functions (a namespace root holding only docs) has nothing to check
    for m <- model.modules, idx[m.name] == nil, m.functions != [] do
      f(
        :unassigned,
        m.name,
        model,
        m,
        m.line,
        "#{m.name} matches no layer (#{length(m.functions)} functions) — R1 altitude, R3, R10, R11 and the LiveView checks skip it; add it to a layer in the layer map, rename it to fit a layer's pattern, or tag functions with @ala_layer"
      )
    end
  end

  def unassigned(_model), do: []

  # ── R10 (aggregate) — a shared *domain* aggregate. Only runs when
  # `check_aggregates` is on (strict/super-strict). Where R10 flags a
  # feature-tier entity shared across peers, this flags a struct in a *shareable*
  # (peer_ok) layer that ≥2 features read: a legitimate domain abstraction, or
  # Clean's shared-Entity coupling? A human decides. Advisory; super-strict
  # scores it (via the enforce list). ───────────────────────────────────────
  def r10_aggregate(
        %{check_aggregates: true, layers: %{index: idx, peer_ok: peer_ok, units: units, names: names}} =
          model
      ) do
    # a bottom-layer struct is a paradigm's or the foundation's own shape (a runner's state, a
    # schema), the convention its users know, not a domain aggregate peers share
    bottom = length(names) - 1

    for m <- model.modules,
        m.defines_struct,
        not configured_instance?(m),
        si = idx[m.name],
        si != nil,
        si < bottom,
        units_sharing = entity_sharers(m, model, idx, peer_ok, units, &(&1 < si)),
        MapSet.size(units_sharing) >= 2 do
      who = units_sharing |> Enum.map(&short/1) |> Enum.sort() |> Enum.join(", ")

      f(
        :r10_aggregate,
        m.name,
        model,
        m,
        m.line,
        "domain aggregate #{short(m.name)} is read by #{MapSet.size(units_sharing)} features (#{who}) — a shared entity couples them (§6.17.2): send each reader only the data it needs (an id, the lines), and keep one use case's data out of a struct another shares (R10)"
      )
    end
  end

  def r10_aggregate(_model), do: []

  # A struct its own functions take as configuration (`call(%__MODULE__{} = c, x)`)
  # and never update is configuration built once and handed down (a rate table,
  # a stock rule), not entity data features share.
  defp configured_instance?(m) do
    Enum.any?(m.functions, &(not &1.private and configured_rule?(&1))) and
      not Enum.any?(m.functions, fn fun ->
      {_, updates?} =
        Macro.prewalk(fun.body, false, fn
          {:%{}, _, [{:|, _, _}]} = n, _ -> {n, true}
          {:%, _, [_, {:%{}, _, [{:|, _, _}]}]} = n, _ -> {n, true}
          {:struct, _, [_, _]} = n, _ -> {n, true}
          n, acc -> {n, acc}
        end)

      updates?
    end)
  end

  # Distinct *units* (a feature and its own submodules count once) of
  # peer-forbidden layers selected by `layer?` that reference the struct module,
  # including the struct's own unit.
  defp entity_sharers(struct_mod, model, idx, peer_ok, units, layer?) do
    for m <- model.modules,
        MapSet.member?(m.refs, struct_mod.name) or m.name == struct_mod.name,
        # building an instance is configuration (a feature "creates instances of domain
        # abstractions", Spray §2.2), not knowing its data
        m.name == struct_mod.name or not only_constructs?(m, struct_mod.name),
        i = idx[m.name],
        i != nil,
        layer?.(i),
        not Map.get(peer_ok, i, true),
        into: MapSet.new() do
      AlaLint.Layers.unit(m.name, units[i])
    end
  end

  # every reference `m` makes to `target` is a call to its `new`: no struct pattern, no other call
  defp only_constructs?(m, target) do
    uses =
      Enum.flat_map(m.functions, fn fun ->
        {_, found} =
          # the head counts too: a struct matched in it is a read
          Macro.prewalk({fun.params, fun.body}, [], fn
            {{:., _, [{:__aliases__, _, parts}, name]}, _, _} = node, acc ->
              {node, if(resolves_to?(m, parts, target), do: [name | acc], else: acc)}

            {:%, _, [{:__aliases__, _, parts}, _]} = node, acc ->
              {node, if(resolves_to?(m, parts, target), do: [:struct | acc], else: acc)}

            node, acc ->
              {node, acc}
          end)

        found
      end)

    uses != [] and Enum.all?(uses, &(&1 == :new))
  end

  defp resolves_to?(m, parts, target) do
    [first | rest] = Enum.map(parts, &to_string/1)
    full = Enum.join([Map.get(m.aliases, first, first) | rest], ".")
    full == target or String.ends_with?(target, "." <> full) and full != ""
  end

  # ── R11: the application (top) layer is composition only (advisory). Two
  # signals: the top layer is a large share of the code, and top-layer functions
  # branch beyond sequencing wiring. Both are relaxations for source-encoded
  # app layers, so they are reported, not scored. Needs a layer map. ─────────
  def r11(%{layers: %{fun_index: fi, app_layers: app} = layers} = model) do
    total = max(map_size(fi), 1)
    app_ids = for {id, i} <- fi, MapSet.member?(app, i), do: id
    composing = Map.get(layers, :composition_layers, app)
    composing_ids = for {id, i} <- fi, MapSet.member?(composing, i), do: id
    share = length(app_ids) / total
    max_share = Map.get(model, :max_app_share, 0.20)

    size =
      if share > max_share do
        [
          f(
            :app_share,
            "(project)",
            model,
            "the application layer is #{round(share * 100)}% of functions (> #{round(max_share * 100)}%) — the top layer should be mostly wiring + config, not logic (R11-adjacent; a ratio, never scored by a tier)"
          )
        ]
      else
        []
      end

    # Check *every* clause of a multi-clause def, not just the one that survives
    # the {module,name,arity} index — a `handle/3` whose 3rd clause branches must
    # be flagged even if the last clause is straight wiring. One finding per
    # function, anchored at its first branchy clause.
    app_id_set = MapSet.new(composing_ids)

    branches =
      for m <- model.modules,
          {{name, arity}, clauses} <- Enum.group_by(m.functions, &{&1.name, &1.arity}),
          MapSet.member?(app_id_set, {m.name, name, arity}),
          branchy = Enum.find(clauses, &branchy?(&1.body)),
          branchy != nil do
        kinds =
          clauses
          |> Enum.flat_map(&branch_kinds(&1.body))
          |> Enum.reject(&(&1 == "route"))
          |> Enum.uniq()
          |> Enum.join(", ")

        f(
          :r11,
          m.name,
          model,
          m,
          branchy.line,
          "#{short(m.name)}.#{name}/#{arity} branches in #{composing_layer(model, m.name)} (#{kinds}) — a real finding, not cleared by being advisory: move guards into the connection mechanism (with, a runner), rules into configured abstractions or a state machine; keep only routing (R11)"
        )
      end

    computes =
      for m <- model.modules,
          {{name, arity}, clauses} <- Enum.group_by(m.functions, &{&1.name, &1.arity}),
          MapSet.member?(app_id_set, {m.name, name, arity}),
          computing = Enum.find(clauses, &computes?(&1.body)),
          computing != nil do
        f(
          :r11,
          m.name,
          model,
          m,
          computing.line,
          "#{short(m.name)}.#{name}/#{arity} does arithmetic in #{composing_layer(model, m.name)} — data handling belongs in a domain abstraction; the composition assigns its output (R11)"
        )
      end

    iterates =
      for m <- model.modules,
          {{name, arity}, clauses} <- Enum.group_by(m.functions, &{&1.name, &1.arity}),
          MapSet.member?(app_id_set, {m.name, name, arity}),
          looping = Enum.find(clauses, &iterates?(&1.body)),
          looping != nil do
        f(
          :r11,
          m.name,
          model,
          m,
          looping.line,
          "#{short(m.name)}.#{name}/#{arity} iterates in #{composing_layer(model, m.name)} (a `for` comprehension) — Spray's \"for loop\" (§1.6.3): move the loop into a domain abstraction or a generic component (R11)"
        )
      end

    size ++
      branches ++
      computes ++
      iterates ++
      handles_data(model, app_id_set) ++
      passes_through(model, app_id_set) ++ working_chains(model, app_id_set)
  end

  def r11(_model), do: []

  # where a composition finding sits; a feature that holds logic is told what Spray's features hold
  defp composing_layer(%{layers: %{index: idx, app_layers: app}}, name) do
    if MapSet.member?(app, idx[name]),
      do: "the application layer",
      else:
        "a Features layer, which holds only instances, configuration and wiring (§2.2; a coded abstraction belongs in a domain layer)"
  end


  defp iterates?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:for, _, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  # The same §1.6.3 handling, without a variable: one lower abstraction's result goes straight into
  # another lower abstraction's call as an argument (`A.f(x, B.g(y))`). Pipes are not counted: a pipe
  # of stages is how Elixir writes Spray's §1.6.4 chain (`readings |> Offset.map() |> Filter.smooth()`),
  # which is composition, and statically a pipe of stages looks the same as a pipe of values.
  defp passes_through(model, app_id_set) do
    %{index: idx} = model.layers

    for m <- model.modules,
        {{name, arity}, clauses} <- Enum.group_by(m.functions, &{&1.name, &1.arity}),
        MapSet.member?(app_id_set, {m.name, name, arity}),
        lower = fn mod ->
          case idx[mod] do
            nil -> false
            i -> i > idx[m.name]
          end
        end,
        {from, to} <- [Enum.find_value(clauses, &nested_lower(&1.body, m, model, lower))],
        from != nil do
      f(
        :r11,
        m.name,
        model,
        m,
        hd(clauses).line,
        "#{short(m.name)}.#{name}/#{arity} passes #{short(from)}'s result straight into #{short(to)} — the application is handling data between abstractions; let a runner or a wire carry it (R11, §1.6.3)"
      )
    end
  end

  defp nested_lower(nil, _m, _model, _lower), do: nil

  defp nested_lower(body, m, model, lower) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        node, nil ->
          {node, nested_pair(node, m, model, lower)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp nested_pair({:|>, _, _}, _m, _model, _lower), do: nil

  defp nested_pair({{:., _, [{:__aliases__, _, _}, _]}, _, args} = node, m, model, lower)
       when is_list(args) do
    with to when to != nil <- remote_target(node, m, model),
         true <- lower.(to) do
      Enum.find_value(args, fn arg ->
        from = if constructor?(arg), do: nil, else: remote_target(arg, m, model)
        if from != nil and lower.(from) and from != to, do: {from, to}
      end)
    else
      _ -> nil
    end
  end

  defp nested_pair(_node, _m, _model, _lower), do: nil

  # Building an instance inside another's configuration (`Adapter.new(Cart, Cart.new(...))`) is
  # instantiation, Spray's `WireIn(new Filter(...))`, not a hand-off of run-time data.
  defp constructor?({{:., _, [_, :new]}, _, _}), do: true
  defp constructor?(_), do: false

  # Spray §1.6.3: the application "handles the data" when it catches one abstraction's result only
  # to pass it to another. Detected as: a variable bound from a call into a lower-layer module, then
  # passed as an argument to another call into a lower-layer module, inside one app-layer function.
  # A result bound and merely stored (assign, a struct update) is holding, not handling.
  defp handles_data(model, app_id_set) do
    %{index: idx} = model.layers

    for m <- model.modules,
        fun <- m.functions,
        MapSet.member?(app_id_set, {m.name, fun.name, fun.arity}),
        lower = fn mod -> (i = idx[mod]) != nil and i > idx[m.name] end,
        {var, from} <- bound_from_lower(fun.body, m, model, lower),
        # building an instance and then using it with its own module is configuration, not handling
        to = passed_to_lower(fun.body, var, m, model, &(lower.(&1) and &1 != from)),
        to != nil do
      f(
        :r11,
        m.name,
        model,
        m,
        fun.line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} binds `#{var}` from #{short(from)} and passes it to #{short(to)} — the application is handling data between abstractions; let a runner or a wire carry it (R11, §1.6.3)"
      )
    end
  end

  # [{var_name, module}] for every `var = Lower.call(...)` or `{a, b} = Lower.call(...)` in body.
  defp bound_from_lower(body, m, model, lower) do
    {_, found} =
      Macro.prewalk(body, [], fn
        # naming a built instance so it can be wired twice is configuration (Spray §1.6.6, §3.6.2)
        {:=, _, [_pat, {{:., _, [_, :new]}, _, _}]} = node, acc ->
          {node, acc}

        {:=, _, [pat, rhs]} = node, acc ->
          case remote_target(rhs, m, model) do
            nil ->
              {node, acc}

            mod ->
              if lower.(mod),
                do: {node, acc ++ for(v <- pattern_vars(pat), do: {v, mod})},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The first lower-layer call that takes `var` as a direct argument (or inside a list/tuple arg).
  defp passed_to_lower(body, var, m, model, lower) do
    {_, found} =
      Macro.prewalk(body, nil, fn
        node, nil ->
          case remote_target(node, m, model) do
            nil ->
              {node, nil}

            mod ->
              {_, _, args} = node

              if lower.(mod) and Enum.any?(args, &mentions_var?(&1, var)),
                do: {node, mod},
                else: {node, nil}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp remote_target({{:., _, [{:__aliases__, _, parts}, _fun]}, _, args}, m, model)
       when is_list(args),
       do: AlaLint.Analyzer.resolve_written(parts, m, model)

  defp remote_target(_, _m, _model), do: nil

  defp pattern_vars(pat) do
    {_, vars} =
      Macro.prewalk(pat, [], fn
        {name, _, ctx} = node, acc
        when is_atom(name) and is_atom(ctx) and name not in [:_, :%{}, :{}] ->
          if String.starts_with?(to_string(name), "_"),
            do: {node, acc},
            else: {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # A bare variable, or a variable inside a tuple/list argument (not inside a nested call).
  defp mentions_var?({name, _, ctx}, var) when is_atom(ctx), do: name == var
  defp mentions_var?({:{}, _, els}, var), do: Enum.any?(els, &mentions_var?(&1, var))
  defp mentions_var?({a, b}, var), do: mentions_var?(a, var) or mentions_var?(b, var)
  defp mentions_var?(list, var) when is_list(list), do: Enum.any?(list, &mentions_var?(&1, var))
  defp mentions_var?(_, _), do: false

  # Checklist R1, "working chains in the application": an app-layer function that does work (it
  # branches beyond routing, or computes) and is called by another app-layer function. Each link is
  # either an abstraction that belongs lower, or wiring that belongs in the composition.
  defp working_chains(model, app_id_set) do
    by_id = fun_lookup(model)

    for {caller, callees} <- model.call_graph,
        MapSet.member?(app_id_set, caller),
        callee <- callees,
        callee != caller,
        MapSet.member?(app_id_set, callee),
        {m, fun} = Map.get(by_id, callee, {nil, nil}),
        fun != nil,
        branchy?(fun.body) or computes?(fun.body) do
      {cmod, cname, car} = caller

      f(
        :r11,
        cmod,
        model,
        m,
        fun.line,
        "#{short(cmod)}.#{cname}/#{car} → #{short(m.name)}.#{fun.name}/#{fun.arity}: a chain of product-specific functions doing work in the application; make the callee an abstraction in a lower layer, or plain wiring (R1 working chain, R11)"
      )
    end
  end

  # `with` is not counted: it is the Elixir form of Spray's Bind, the connection
  # mechanism guards should move into (checklist R11). Multi-clause function
  # heads are routing and never reach here, and a `case` that only routes
  # ok/error outcomes is wiring too.
  @doc "Does a function body branch (if/unless/cond, or a case that does more than route outcomes)? Public so the encoder can mark R11 in the notation."
  def branchy?(body), do: Enum.any?(branch_kinds(body), &(&1 != "route"))

  # A rough classification of a body's branches, for the R11 message:
  # "guard" tests for nil/ok/error only; "route" is a case whose arms only pass
  # values on; anything else is "logic". Heuristic, reported for a reader.
  defp branch_kinds(body) do
    {_, kinds} =
      Macro.prewalk(body, [], fn
        {form, _, [cond_expr | _]} = node, acc when form in [:if, :unless] ->
          {node, [branch_kind(cond_expr) | acc]}

        {:case, _, [_subject, [do: arms]]} = node, acc when is_list(arms) ->
          {node, [case_kind(arms) | acc]}

        {:cond, _, _} = node, acc ->
          {node, ["logic" | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(kinds)
  end

  # `if connected?(socket)` is the framework departure the checklist names (the
  # LiveView table); it counts as routing, like `with`, not as logic at the top.
  defp branch_kind({:connected?, _, [_]}), do: "route"
  defp branch_kind(cond_expr), do: if(guard_test?(cond_expr), do: "guard", else: "logic")

  defp guard_test?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp guard_test?({:is_nil, _, [_]}), do: true
  defp guard_test?({op, _, [_, nil]}) when op in [:==, :!=, :===, :!==], do: true
  defp guard_test?({:!, _, [inner]}), do: guard_test?(inner)
  defp guard_test?({:not, _, [inner]}), do: guard_test?(inner)
  defp guard_test?(_), do: false

  defp case_kind(arms) do
    patterns = for {:->, _, [[pat], _]} <- arms, do: pat
    bodies = for {:->, _, [_, body]} <- arms, do: body

    cond do
      Enum.any?(bodies, &computes?/1) -> "logic"
      Enum.all?(patterns, &outcome_pattern?/1) -> "route"
      true -> "logic"
    end
  end

  defp outcome_pattern?({tag, _}) when tag in [:ok, :error], do: true
  defp outcome_pattern?({:{}, _, [tag | _]}) when tag in [:ok, :error], do: true
  defp outcome_pattern?(atom) when is_atom(atom), do: true
  defp outcome_pattern?({:_, _, _}), do: true
  defp outcome_pattern?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp outcome_pattern?(_), do: false

  @arith [:+, :-, :*, :/, :div, :rem]
  # Arithmetic on values (not a literal-only constant like `60 * 60`) in a body. A
  # `&Mod.fun/arity` capture is not a division, so captures are not walked.
  defp computes?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:&, meta, _}, acc ->
          {{:&, meta, []}, acc}

        {op, _, [a, b]} = node, acc when op in @arith ->
          {node, acc or not (is_number(a) and is_number(b))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # ── Module size (advisory, R7 complement). An abstraction should be readable
  # in isolation; ~500 lines is a rough cap. `loc` is accurate for single-module
  # files (the common case) and approximate otherwise. ──────────────────────
  def module_size(model) do
    max = Map.get(model, :max_module_loc, 500)

    too_big =
      for m <- model.modules, m.loc > max do
        f(
          :module_size,
          m.name,
          model,
          m,
          m.line,
          "module #{short(m.name)} is #{m.loc} lines (> #{max}) — an abstraction should be readable in isolation; check it is really one concept (R7-adjacent)"
        )
      end

    too_big ++ average_size(model)
  end

  # Spray's lower bound: "if abstractions average less than 100 lines of code,
  # we will likely have more abstractions than we need". LOC is attributed per
  # file (to its first module), so this averages over modules that own lines.
  # Only meaningful with several of them; an Elixir module is not always an
  # abstraction, so this stays a prompt.
  defp average_size(model) do
    min_avg = Map.get(model, :min_avg_module_loc, 100)
    sized = for m <- model.modules, m.loc > 0, do: m.loc

    # Only meaningful once there is enough code for an average to say anything.
    if length(sized) >= 5 and Enum.sum(sized) >= 1000 and
         Enum.sum(sized) / length(sized) < min_avg do
      avg = round(Enum.sum(sized) / length(sized))

      [
        f(
          :module_avg,
          "(project)",
          model,
          "abstractions average #{avg} lines (< #{min_avg}) across #{length(sized)} files — Spray's lower bound suggests more abstractions than needed; check for helper proliferation (R7)"
        )
      ]
    else
      []
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
        publics =
          m.functions
          |> Enum.reject(& &1.private)
          |> Enum.uniq_by(&{&1.name, &1.arity})
          |> length(),
        publics > max do
      f(
        :public_surface,
        m.name,
        model,
        m,
        m.line,
        "module #{short(m.name)} exposes #{publics} public functions (> #{max}) — a wide public surface leaks internals; keep the mess private behind a small boundary, and confirm this is one concept (R6/R7-adjacent)"
      )
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
      for {{cm, _, _}, callees} <- model.call_graph,
          {tm, _, _} <- callees,
          into: MapSet.new(),
          do: {cm, tm}

    for {a, deps} <- model.dep_graph,
        b <- deps,
        not MapSet.member?(call_pairs, {a, b}),
        ia = idx[a],
        ib = idx[b],
        ia != nil and ib != nil,
        violation = altitude_violation(a, b, ia, ib, peer_ok, units) do
      f(
        :r1_ref,
        a,
        model,
        "#{short(a)} → #{short(b)}: #{violation} — reference-level only (alias/type/template use, no direct call in the AST; in LiveView this is usually a cross-feature call inside a ~H template) — verify"
      )
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

      f(
        :layer,
        mod,
        model,
        m,
        fun && fun.line,
        "#{short(mod)}.#{name}/#{arity} is tagged @ala_layer #{inspect(tag)}, which is not a declared layer — fix the tag or declare the layer"
      )
    end
  end

  def layer_validity(_model), do: []

  @doc """
  The abstraction height — the longest chain in the function call graph, where a
  call **within the application layer costs 0** (the whole app layer is one
  altitude, because the application is one abstraction).
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
      [
        f(
          :height,
          "(project)",
          model,
          "abstraction height is #{depth} levels deep (> #{max}) — counting hops *between* abstractions (calls inside one module are internal decomposition and do not add altitude); deep chains can hide helper proliferation (R7-adjacent)"
        )
      ]
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
      f(
        :passthrough,
        m.name,
        model,
        m,
        fun.line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} is a pass-through (1 caller, 1 callee → #{short(cmod)}.#{cname}/#{carity}); it renames a call without hiding a decision — consider inlining (R7-adjacent)"
      )
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

  # an argument the function computes first (a lookup, a conversion) makes it an adapter, the
  # same reading as a pipe whose left is a call
  defp single_call_body?({{:., _, _}, _, args}) when is_list(args),
    do: not Enum.any?(args, &computed_arg?/1)
  # A map/struct update or construction, or a tuple, builds a value; a call
  # embedded in one of its fields is a computation, not a delegating rename
  # (`%{s | field: Callee.f(...)}`, `%Struct{...}`, `{a, Callee.f(x)}`).
  defp single_call_body?({:%{}, _, _}), do: false
  defp single_call_body?({:%, _, _}), do: false
  defp single_call_body?({:{}, _, _}), do: false

  defp single_call_body?({name, _, args})
       when is_atom(name) and is_list(args) and name not in @nontrivial_forms,
       do: true

  defp single_call_body?(_), do: false

  defp computed_arg?({{:., _, [_, _]}, meta, _}), do: not Keyword.get(meta, :no_parens, false)
  defp computed_arg?(_), do: false

  # A variable or a literal — not a call, not a struct/map/tuple construction.
  defp bare_operand?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp bare_operand?(lit) when is_binary(lit) or is_number(lit) or is_atom(lit), do: true
  defp bare_operand?(_), do: false

  # fun_id → {module_struct, fun_struct}, for locating a function-level finding.
  defp fun_lookup(model) do
    for m <- model.modules,
        fun <- m.functions,
        into: %{},
        do: {{m.name, fun.name, fun.arity}, {m, fun}}
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
      f(
        :r1,
        a,
        model,
        "modules #{a} ↔ #{b} form a dependency cycle (peer/communication coupling — an edge that does not drop)"
      )
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

    for {caller, callees} <- model.call_graph,
        callee <- callees,
        ia = fidx[caller],
        ib = fidx[callee],
        ia != nil and ib != nil,
        violation = altitude_violation(elem(caller, 0), elem(callee, 0), ia, ib, peer_ok, units) do
      {cmod, cname, car} = caller
      {tmod, tname, tar} = callee
      {m, fun} = Map.get(by_id, caller, {nil, nil})

      f(
        :r1,
        cmod,
        model,
        m,
        fun && fun.line,
        "#{short(cmod)}.#{cname}/#{car} [#{Enum.at(names, ia)}] → #{short(tmod)}.#{tname}/#{tar} [#{Enum.at(names, ib)}]: #{violation}"
      )
    end
  end

  # Only UP (ib < ia) and same-layer PEER are violations. A drop of ANY size is
  # legal in ALA — a knowledge dependency may target any lower layer, so a big
  # altitude skip (a "long drop", ib ≫ ia) is NOT a smell. Do not add a check
  # that penalizes long drops. (See the checklist's "long drop" note.)
  defp altitude_violation(_a, _b, ia, ib, _peer_ok, _units) when ib < ia,
    do:
      "knowledge flows UP (callee is more concrete) — edge must drop to a more abstract layer (R1)"

  defp altitude_violation(a, b, ia, ib, peer_ok, units) when ia == ib do
    cond do
      Map.get(peer_ok, ia, true) ->
        nil

      # same-unit modules (a feature and its own submodules) are cohesion, not peers
      AlaLint.Layers.unit(a, units[ia]) == AlaLint.Layers.unit(b, units[ia]) ->
        nil

      true ->
        "cross-peer edge between two abstractions in the same layer — the layer above should wire them (R1)"
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
    for m <- model.modules,
        {{kind, op}, line} <- m.state_ops,
        kind in [:ets, :persistent_term, :agent] do
      f(
        :r2,
        m.name,
        model,
        m,
        line,
        "#{kind}.#{op} — shared mutable state channel; confirm it is not a back-channel between peers (R2)"
      )
    end
  end

  # ── R3: message text below the composition. A string with several words and a
  # capital start, in a feature or domain module, is almost always something a
  # person will read: a flash, a label, an error message. That is an application
  # literal (R3), and an output carrying it names its own presentation (R9). ────
  def r3_text(%{layers: %{index: idx}} = model) do
    for m <- model.modules,
        # only in a declared lower layer: unassigned modules are the coverage worklist, not findings
        idx[m.name] != nil,
        r3_scannable?(model, m.name),
        {{:string, text}, line} <- m.literals,
        prose?(text) do
      f(
        :r3,
        m.name,
        model,
        m,
        line,
        "message text #{inspect(text)} in #{short(m.name)} below the composition — text a person reads is an application literal; the page should supply it (R3, R9)"
      )
    end
  end

  def r3_text(_model), do: []

  defp prose?(text) do
    String.match?(text, ~r/^[A-Z][a-z].*\s.+/) and length(String.split(text)) >= 3 and
      not String.contains?(text, ["<", "=", "/"])
  end

  # ── R3: application literals baked into a lower abstraction (heuristic) ───
  # Flags "policy-ish" literals: floats, integers ≥ 10 (excluding round
  # placeholders), and any string/atom literal that also looks like config.
  def r3(model) do
    for m <- model.modules,
        r3_scannable?(model, m.name),
        {lit, line} <- m.literals,
        magic?(lit) do
      f(
        :r3,
        m.name,
        model,
        m,
        line,
        "literal #{fmt_lit(lit)} in #{short(m.name)} below the composition — hoist it if it's an application literal, keep it if intrinsic to the abstraction (R3)"
      )
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

  def magic?({:number, n}) when is_integer(n),
    do: n not in [0, 1, 2, -1, 10, 100, 1000, 24, 60] and n > 2

  def magic?({:string, _}), do: false
  def magic?({:atom, _}), do: false

  # ── R4: hidden state — the process dictionary (exact) ────────────────────
  def r4(model) do
    for m <- model.modules, {{:process_dict, op}, line} <- m.state_ops do
      f(
        :r4,
        m.name,
        model,
        m,
        line,
        "Process.#{op} — hidden state via the process dictionary; keep state in the abstraction that owns it (or a State-style abstraction wired in), not hidden (R4)"
      )
    end
  end

  # ── R5: duplicated literal contracts across modules (exact) ──────────────
  def r5(model) do
    for {lit, mods} <- model.literal_index,
        contractish?(lit),
        MapSet.size(mods) >= 2,
        not router_path?(lit, mods) do
      owner = mods |> Enum.sort() |> hd()
      m = Enum.find(model.modules, &(&1.name == owner))

      f(
        :r5,
        owner,
        model,
        m,
        m.line,
        "literal #{fmt_lit(lit)} is repeated across #{MapSet.size(mods)} modules (#{mods |> Enum.sort() |> Enum.map(&short/1) |> Enum.join(", ")}) — single-source it (R5)"
      )
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
    String.length(s) in 5..40 and not String.match?(s, ~r/\s/) and String.match?(s, ~r/[a-zA-Z]/)
  end

  defp contractish?({:atom, _}), do: false
  defp contractish?({:number, _}), do: false

  # A path shared between a page and the Router is the route table's contract, checked by the
  # router at compile time when written as `~p`; not a silent one.
  defp router_path?({:string, "/" <> _}, mods),
    do: Enum.any?(mods, &String.ends_with?(&1, ".Router"))

  defp router_path?(_lit, _mods), do: false

  # ── R6: nameability (heuristic) ──────────────────────────────────────────
  def r6(model) do
    name_findings =
      for m <- model.modules, fun <- m.functions, meaningless_name?(fun.name) do
        f(
          :r6,
          m.name,
          model,
          m,
          fun.line,
          "function #{short(m.name)}.#{fun.name}/#{fun.arity} has a meaningless name — name the concept or inline it (R6)"
        )
      end

    wrap_findings =
      for m <- model.modules,
          publics =
            m.functions |> Enum.reject(& &1.private) |> Enum.uniq_by(&{&1.name, &1.arity}),
          length(publics) > 1,
          fun <- publics,
          not predicate_name?(fun),
          not configured_rule?(fun),
          primitive_wrapper?(fun) do
        f(
          :r6,
          m.name,
          model,
          m,
          fun.line,
          "#{short(m.name)}.#{fun.name}/#{fun.arity} just wraps a primitive/stdlib call — not an abstraction (R6)"
        )
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
  defp primitive_wrapper?(%{body: {op, _, [a, b]}})
       when op in [:+, :-, :*, :/, :>=, :<=, :>, :<, :==, :!=],
       do: terminal_operand?(a) and terminal_operand?(b)

  defp primitive_wrapper?(_), do: false

  # `call(%__MODULE__{unit: u}, n), do: n * u` applies the rule an instance was
  # configured with: the configuration is the abstraction, not the operator.
  defp configured_rule?(%{params: [first | _]}), do: struct_pattern?(first)
  defp configured_rule?(_), do: false

  defp struct_pattern?({:%, _, _}), do: true
  defp struct_pattern?({:=, _, [a, b]}), do: struct_pattern?(a) or struct_pattern?(b)
  defp struct_pattern?(_), do: false

  # `pending?/1` over a private field is encapsulation, not a rename of `!=`.
  defp predicate_name?(%{name: name}), do: String.ends_with?(Atom.to_string(name), "?")

  # A bare variable (`{:x, _, ctx}` with atom context/nil) or a literal.
  defp terminal_operand?({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: true

  defp terminal_operand?(lit) when is_number(lit) or is_binary(lit) or is_atom(lit), do: true
  defp terminal_operand?(_), do: false

  # ── Tramp parameters (R6 "should"): Spray §3.11.1 — middle-layer functions
  # "end up with extra parameters that don't have anything to do with them,
  # just so they can pass state data through to even lower functions". Flagged
  # when a public function never reads a parameter and only hands it to another
  # project module's function (a lower one, given a layer map) that doesn't read
  # it either and hands it further down: two hops of carrying. One hop is
  # ordinary use of a lower abstraction on the function's own input, and carrying
  # into a protocol or behaviour is a runner delivering to a port, so both are
  # left alone. Private helpers are the abstraction's inside, framework callbacks
  # have fixed heads, pass-throughs are reported separately, and the application
  # layer's data handling is R11's. ──
  @callback_names ~w(mount handle_event handle_info handle_params handle_call handle_cast
                     handle_continue handle_async init terminate update render call
                     code_change on_mount)a

  def tramp(model) do
    pt = model |> passthrough_ids() |> MapSet.new(fn {id, _} -> id end)
    publics = public_clauses(model)

    for m <- model.modules,
        not app_module_with_layers?(model, m.name),
        {{name, arity}, clauses} <- Map.get(publics, m.name, %{}),
        not MapSet.member?(pt, {m.name, name, arity}),
        pos <- 0..(arity - 1)//1,
        {:fwd, var, targets} <- [forwarded_at(clauses, pos, m, model)],
        {via, below} <- [carried_further(targets, publics, model)],
        via != nil do
      f(
        :tramp,
        m.name,
        model,
        m,
        hd(clauses).line,
        "#{short(m.name)}.#{name}/#{arity} never reads `#{var}`; it only carries it through #{short(via)} to #{short(below)}, which is where it is used — a tramp parameter. Let the composition give #{short(below)} that input or configuration directly (R6 should, §3.11.1)"
      )
    end
  end

  # module => %{{name, arity} => [clause]} for the public, hand-written,
  # non-callback functions that the tramp check considers.
  defp public_clauses(model) do
    for m <- model.modules, into: %{} do
      {m.name,
       m.functions
       |> Enum.reject(&(&1.private or &1.macro_generated or &1.name in @callback_names))
       |> Enum.group_by(&{&1.name, &1.arity})}
    end
  end

  # The first forwarding target whose own parameter at that position is also only
  # forwarded: {that module, the module it forwards to}, or {nil, nil}.
  defp carried_further(targets, publics, model) do
    Enum.find_value(targets, {nil, nil}, fn {mod, fun, arity, pos} ->
      with clauses when is_list(clauses) <- get_in(publics, [mod, {fun, arity}]),
           gm when gm != nil <- Enum.find(model.modules, &(&1.name == mod)),
           {:fwd, _var, [{below, _, _, _} | _]} <- forwarded_at(clauses, pos, gm, model),
           false <- port?(model, below) do
        {mod, below}
      else
        _ -> nil
      end
    end)
  end

  # Delivering a value into a protocol or behaviour is putting it on a port, which
  # is what a runner or connection mechanism is for, so that carrying is wiring.
  defp port?(model, name) do
    case Enum.find(model.modules, &(&1.name == name)) do
      %{interface: kind} when kind in [:protocol, :behaviour] -> true
      _ -> false
    end
  end

  # {:fwd, var, targets} when every clause either ignores position `pos` (`_x`)
  # or binds it to a plain variable that is only forwarded, and one forwards;
  # :used otherwise.
  defp forwarded_at(clauses, pos, m, model) do
    verdicts =
      for fun <- clauses do
        case Enum.at(fun.params, pos) do
          {v, _, ctx} when is_atom(v) and is_atom(ctx) ->
            if String.starts_with?(to_string(v), "_"),
              do: :ignored,
              else: forwarded_only(fun.body, v, m, model)

          _ ->
            :used
        end
      end

    cond do
      Enum.any?(verdicts, &(&1 == :used)) -> :used
      fwd = Enum.find(verdicts, &match?({:fwd, _, _}, &1)) -> fwd
      true -> :used
    end
  end

  defp forwarded_only(nil, _var, _m, _model), do: :used

  defp forwarded_only(body, var, m, model) do
    {_, {total, targets}} =
      Macro.prewalk(body, {0, []}, fn
        {^var, _, ctx} = node, {t, ts} when is_atom(ctx) ->
          {node, {t + 1, ts}}

        {:|>, _, [{^var, _, ctx}, {_, _, rargs} = rhs]} = node, {t, ts}
        when is_atom(ctx) and is_list(rargs) ->
          case lower_project_call(rhs, m, model) do
            nil -> {node, {t, ts}}
            mod -> {node, {t, [{mod, call_name(rhs), length(rargs) + 1, 0} | ts]}}
          end

        {_, _, args} = node, {t, ts} = acc when is_list(args) ->
          case lower_project_call(node, m, model) do
            nil ->
              {node, acc}

            mod ->
              hits =
                for {arg, i} <- Enum.with_index(args),
                    match?({^var, _, ctx} when is_atom(ctx), arg),
                    do: {mod, call_name(node), length(args), i}

              {node, {t, hits ++ ts}}
          end

        node, acc ->
          {node, acc}
      end)

    if targets != [] and length(targets) == total,
      do: {:fwd, var, Enum.reverse(targets)},
      else: :used
  end

  defp call_name({{:., _, [_, fun]}, _, _}), do: fun

  # The project module a remote call targets, when it is another module and
  # (given a layer map) sits in a lower layer; nil otherwise.
  defp lower_project_call(node, m, model) do
    with mod when is_binary(mod) <- remote_target(node, m, model),
         true <- mod != m.name,
         true <- Map.has_key?(Map.get(model, :project_index, %{}), mod),
         true <- lower_or_unlayered?(model, m.name, mod) do
      mod
    else
      _ -> nil
    end
  end

  defp lower_or_unlayered?(%{layers: %{index: idx}}, from, to) do
    case {idx[from], idx[to]} do
      {a, b} when is_integer(a) and is_integer(b) -> b > a
      _ -> true
    end
  end

  defp lower_or_unlayered?(_model, _from, _to), do: true

  defp app_module_with_layers?(%{layers: %{index: idx, app_layers: app}}, name),
    do: (i = idx[name]) != nil and i in app

  defp app_module_with_layers?(_model, _name), do: false

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
      for m <- model.modules,
          fun <- m.functions,
          fun.private,
          uniq_defp?(m, fun),
          Map.get(m.local_call_counts, fun.name, 0) == 0,
          not fun.macro_generated,
          not MapSet.member?(template_refs, to_string(fun.name)) do
        f(
          :r7,
          m.name,
          model,
          m,
          fun.line,
          "private #{short(m.name)}.#{fun.name}/#{fun.arity} is never called — dead code (R7)"
        )
      end

    trivial =
      for m <- model.modules,
          fun <- m.functions,
          fun.private,
          Map.get(m.local_call_counts, fun.name, 0) == 1,
          trivial?(fun.body),
          meaningless_name?(fun.name) do
        f(
          :r7,
          m.name,
          model,
          m,
          fun.line,
          "private #{short(m.name)}.#{fun.name}/#{fun.arity} is a trivial single-use one-liner — inline it (R7)"
        )
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

    %Finding{
      rule: rule,
      module: module,
      file: m && m.file,
      line: (m && m.line) || 0,
      weight: @weights[rule],
      severity: default_severity(rule),
      message: message
    }
  end

  defp f(rule, module, _model, %{} = mod, line, message) do
    %Finding{
      rule: rule,
      module: module,
      file: mod.file,
      line: line || mod.line,
      weight: @weights[rule],
      severity: default_severity(rule),
      message: message
    }
  end

  defp short(name),
    do: String.replace_prefix(name, "Elixir.", "") |> String.split(".") |> List.last()

  defp fmt_lit({:string, s}), do: inspect(s)
  defp fmt_lit({:atom, a}), do: inspect(a)
  defp fmt_lit({:number, n}), do: to_string(n)
end
