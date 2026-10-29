defmodule AlaLint.LightAla do
  @moduledoc """
  Two readings of light ALA (`ala_variants_elixir/v59-light-ala/DESIGN.md`), not checklist
  rules. Each does nothing until its settings are given in `checks:`.

    * `:builder_literals` (rule 11): a guarded config or context struct is built only by its
      builders, which take keyword overrides, so a new field is one more option, never a new
      arity. Hybrid 1's S04 broke 119 tests through a builder that took the cart id positionally.
    * `:stale_session_write` (rule 12): a LiveView event writes session-scoped data only when the
      page's mount attaches a guard. Hybrid 1's S07 reorder wrote to a cart the session had moved
      past, and the lines were lost.
  """

  alias AlaLint.{Analyzer, Finding, StructBuilds}

  @weights %{builder_literals: 1, stale_session_write: 2}
  def weights, do: @weights
  def checks, do: Map.keys(@weights)

  # parameter names that carry keyword overrides even where the body doesn't show it
  @keyword_names ~w(overrides opts options attrs fields kw keywords)a

  def run(model) do
    settings = Map.get(model, :light_ala, %{})

    builder_literals(model, settings[:builder_literals]) ++
      stale_session_write(model, settings[:stale_session_write])
  end

  @doc "Light-ALA rule 11: guarded structs built outside their builders, and positional builders."
  def builder_literals(_model, nil), do: []

  def builder_literals(model, s) do
    builders = builders(model, s)

    outside =
      for {file, place} <- sources(model, s),
          b <- StructBuilds.in_source(StructBuilds.parse(file), model.module_names),
          b.struct in s.structs,
          {allowed, _how} = builders[b.struct],
          b.module != b.struct and b.module not in allowed do
        finding(
          :builder_literals,
          b.module,
          file,
          b.line,
          "#{b.module} builds %#{b.struct}{} with #{how(b.how)} in #{place}, not through its builder (#{fmt_mods(allowed)}): a new field then changes every such place (light-ALA rule 11, a reading for light ALA, not a checklist rule)"
        )
      end

    outside ++ positional_builders(model, s)
  end

  @doc """
  Each guarded struct's builders: `%{struct => {[module], :configured | :inferred}}`. Without
  `builders:`, a `lib` module with a function returning the struct (directly or through one
  same-module call) is taken as one.
  """
  def builders(model, %{builders: nil} = s) do
    returns = module_returns(model)

    for struct <- s.structs, into: %{} do
      mods =
        for {mod, by_fun} <- returns,
            mod != struct,
            Enum.any?(Map.values(by_fun), &(struct in &1)),
            do: mod

      {struct, {Enum.sort(mods), :inferred}}
    end
  end

  def builders(_model, s), do: Map.new(s.structs, &{&1, {s.builders, :configured}})

  @doc "Light-ALA rule 12: a LiveView whose events write session-scoped data with no guard in mount."
  def stale_session_write(_model, nil), do: []

  def stale_session_write(model, s) do
    for m <- model.modules,
        live_view?(m),
        events = writing_events(model, m, s),
        events != [],
        not guarded?(model, m, s) do
      mount = Enum.find(m.functions, &(&1.name == :mount))

      guard =
        case s.guards do
          [] -> "no guard is configured"
          guards -> "its mount attaches no guard (#{Enum.map_join(guards, ", ", &fmt_target/1)})"
        end

      finding(
        :stale_session_write,
        m.name,
        m.file,
        (mount && mount.line) || m.line,
        "#{m.name} writes session-scoped data from its events: #{Enum.join(events, ", ")}; #{guard}, so an event after the session moved on (the cart closed in another tab, or live navigation past it) writes through an id captured at mount. Attach the guard in mount, or make the write a controller action, which runs through the session plugs (light-ALA rule 12, a reading for light ALA, not a checklist rule)"
      )
    end
  end

  defp sources(model, s) do
    lib = model.modules |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.map(&{&1, "lib"})

    tests =
      for dir <- s.tests,
          file <- Path.wildcard(Path.join(dir, "**/*.{ex,exs}")),
          do: {file, "a test file"}

    lib ++ tests
  end

  # Conservative: only a builder that can't take a new field without a new arity, or takes
  # more than `max_positional` values positionally, or takes an optional field positionally.
  defp positional_builders(model, s) do
    returns = module_returns(model)
    defs = Map.new(s.structs, &{&1, struct_definition(model, &1)})

    for m <- model.modules,
        {{name, arity}, structs} <- Map.get(returns, m.name, %{}),
        struct <- Enum.filter(structs, &(&1 in s.structs)),
        clauses = Enum.filter(m.functions, &(&1.name == name and &1.arity == arity)),
        not hd(clauses).private,
        reason = positional_reason(clauses, defs[struct], s.max_positional),
        reason != nil do
      finding(
        :builder_literals,
        m.name,
        m.file,
        hd(clauses).line,
        "#{m.name}.#{name}/#{arity} builds %#{struct}{} and #{reason}: take what it can't do without as arguments and the rest as keyword overrides, so a new field is one more option, never a new arity (light-ALA rule 11, a reading for light ALA, not a checklist rule)"
      )
    end
  end

  defp positional_reason(clauses, definition, max) do
    arity = hd(clauses).arity
    keyword = for i <- 0..(arity - 1)//1, Enum.any?(clauses, &keyword_param?(&1, i)), do: i
    positional = Enum.to_list(0..(arity - 1)//1) -- keyword
    names = positional |> Enum.flat_map(&param_names(clauses, &1)) |> Enum.uniq()
    fields = (definition && definition.fields) || []
    optional = fields -- ((definition && definition.enforce) || [])

    cond do
      length(positional) > max ->
        "takes #{length(positional)} positional parameters (more than #{max})"

      keyword == [] and Enum.any?(names, &(&1 in fields)) ->
        "takes #{fmt_atoms(Enum.filter(names, &(&1 in fields)))} positionally with no keyword list"

      Enum.any?(names, &(&1 in optional)) ->
        "takes the optional field(s) #{fmt_atoms(Enum.filter(names, &(&1 in optional)))} positionally"

      true ->
        nil
    end
  end

  defp keyword_param?(fun, i) do
    case Enum.at(fun.params, i) do
      {:\\, _, [_var, default]} when is_list(default) ->
        true

      param ->
        case var_name(param) do
          nil -> false
          name -> name in @keyword_names or used_as_keywords?(fun.body, name)
        end
    end
  end

  defp used_as_keywords?(body, name) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:++, _, [a, b]} = node, acc ->
          {node, acc or var?(a, name) or var?(b, name)}

        {f, _, [_mod, arg | _]} = node, acc when f in [:struct, :struct!] ->
          {node, acc or var?(arg, name)}

        {{:., _, [{:__aliases__, _, [:Keyword]}, _]}, _, args} = node, acc ->
          {node, acc or Enum.any?(args, &var?(&1, name))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp param_names(clauses, i),
    do: for(c <- clauses, n = var_name(Enum.at(c.params, i)), n != nil, do: n)

  defp var_name({:\\, _, [var, _]}), do: var_name(var)
  defp var_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp var_name(_), do: nil

  defp var?({name, _, ctx}, name) when is_atom(ctx), do: true
  defp var?(_, _), do: false

  # %{module => %{{fun, arity} => [struct]}}, following one same-module call in return position
  defp module_returns(model) do
    for m <- model.modules, into: %{} do
      ctx = %{module: m.name, aliases: m.aliases, known: model.module_names}

      direct =
        for f <- m.functions,
            into: [],
            do: {{f.name, f.arity}, StructBuilds.returned(f.body, ctx)}

      by_name = Enum.group_by(direct, fn {{n, _}, _} -> n end, fn {_, rets} -> rets end)

      resolved =
        Enum.reduce(direct, %{}, fn {key, rets}, acc ->
          structs =
            Enum.flat_map(rets, fn
              {:struct, name} ->
                [name]

              {:local, n, _} ->
                for {:struct, name} <- List.flatten(Map.get(by_name, n, [])), do: name
            end)

          Map.update(acc, key, structs, &(&1 ++ structs))
        end)

      {m.name,
       resolved
       |> Enum.reject(fn {_, v} -> v == [] end)
       |> Map.new(fn {k, v} -> {k, Enum.uniq(v)} end)}
    end
  end

  defp struct_definition(model, struct) do
    case Enum.find(model.modules, &(&1.name == struct)) do
      nil -> nil
      m -> m.file |> StructBuilds.parse() |> StructBuilds.definition(struct)
    end
  end

  defp live_view?(m) do
    component =
      Enum.any?(
        m.uses,
        &(&1 == "Phoenix.LiveComponent" or String.ends_with?(&1, ":live_component"))
      )

    declared =
      Enum.any?(m.uses, &(&1 == "Phoenix.LiveView" or String.ends_with?(&1, ":live_view")))

    has = fn name, arity -> Enum.any?(m.functions, &(&1.name == name and &1.arity == arity)) end

    not component and (declared or (has.(:handle_event, 3) and has.(:mount, 3)))
  end

  # `"event" (Mod.fun, ...)` for each handle_event clause that reaches a writer
  defp writing_events(model, m, s) do
    for clause <- m.functions,
        clause.name == :handle_event,
        writes =
          clause
          |> List.wrap()
          |> remote_calls(model, m)
          |> Enum.filter(&matches?(&1, s.writers, s.except))
          |> Enum.uniq(),
        writes != [] do
      "#{event_name(clause)} (#{Enum.map_join(writes, ", ", &fmt_target/1)})"
    end
    |> Enum.uniq()
  end

  defp guarded?(model, m, s) do
    m.functions
    |> Enum.filter(&(&1.name == :mount))
    |> remote_calls(model, m)
    |> Enum.any?(&matches?(&1, s.guards, []))
  end

  # remote calls in `clauses`, and in the module's private functions they reach
  defp remote_calls(clauses, model, m) do
    privates = Enum.filter(m.functions, & &1.private)
    reach(clauses, privates, MapSet.new(), [], model, m)
  end

  defp reach([], _privates, _seen, acc, _model, _m), do: acc

  defp reach([fun | rest], privates, seen, acc, model, m) do
    {calls, locals} = calls_in(fun.body, model, m)

    next =
      for p <- privates,
          {p.name, p.arity} in locals,
          not MapSet.member?(seen, {p.name, p.arity, p.line}),
          do: p

    seen = Enum.reduce(next, seen, &MapSet.put(&2, {&1.name, &1.arity, &1.line}))
    reach(rest ++ next, privates, seen, acc ++ calls, model, m)
  end

  defp calls_in(body, model, m) do
    {_, acc} =
      Macro.prewalk(body, {[], []}, fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, args} = node, {calls, locals}
        when is_atom(fun) and is_list(args) ->
          {node, {[{Analyzer.resolve_written(parts, m, model), fun} | calls], locals}}

        {name, _, args} = node, {calls, locals} when is_atom(name) and is_list(args) ->
          {node, {calls, [{name, length(args)} | piped(name, args) ++ locals]}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # `x |> helper(a)` calls helper/2
  defp piped(name, args), do: [{name, length(args) + 1}]

  defp matches?({mod, fun}, targets, except) do
    Enum.any?(targets, fn
      {^mod, nil} -> true
      {^mod, ^fun} -> true
      _ -> false
    end) and not Enum.any?(except, &excepted?(&1, mod, fun))
  end

  defp excepted?(%Regex{} = re, _mod, fun), do: Regex.match?(re, Atom.to_string(fun))
  defp excepted?({mod, fun}, mod, fun), do: true
  defp excepted?(fun, _mod, fun) when is_atom(fun), do: true
  defp excepted?(_, _mod, _fun), do: false

  defp event_name(%{params: [event | _]}) when is_binary(event), do: inspect(event)
  defp event_name(_clause), do: "(any event)"

  defp finding(rule, module, file, line, message) do
    %Finding{
      rule: rule,
      module: module,
      file: file,
      line: line,
      weight: @weights[rule],
      severity: :warn,
      message: message
    }
  end

  defp how(:literal), do: "a literal"
  defp how(fun), do: "#{fun}/2"

  defp fmt_mods([]), do: "none found"
  defp fmt_mods(mods), do: Enum.join(mods, ", ")

  defp fmt_target({mod, nil}), do: mod
  defp fmt_target({mod, fun}), do: "#{mod}.#{fun}"

  defp fmt_atoms(atoms), do: Enum.join(atoms, ", ")
end
