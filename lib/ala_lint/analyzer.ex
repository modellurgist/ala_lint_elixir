defmodule AlaLint.Analyzer do
  @moduledoc """
  Builds a project model from `*.ex` sources under a root: per-module facts
  (functions, references to other project modules, literals, state ops) plus
  global indexes (the module dependency graph, a literal→modules index, and
  per-function local call counts). The rule modules read this model; they do
  no parsing themselves.
  """

  defmodule Mod do
    @moduledoc false
    defstruct name: nil,
              file: nil,
              line: 0,
              loc: 0,
              functions: [],
              refs: MapSet.new(),
              literals: [],
              state_ops: [],
              # short alias → full module name (for function-graph call resolution)
              aliases: %{},
              # module names given to `use` (content signal for layer matching)
              uses: [],
              # does this module define a struct? (an entity candidate for R10)
              defines_struct: false,
              # name → count of internal calls to that name (for R7)
              local_call_counts: %{}
  end

  defmodule Fun do
    @moduledoc false
    # macro_generated: defined inside a `quote` block, so its call sites are in
    # the code the macro injects, not in this source — do not treat as dead.
    defstruct [:name, :arity, :line, :private, :body, :module, :file, :layer_tag, macro_generated: false]
  end

  @doc """
  Parse every `.ex` under `root` into a project model. Skips **generated
  files** (those whose first lines contain `GENERATED`) — derived code
  legitimately duplicates its source (e.g. committed codegen kept in sync by a
  `--check`) and must not be scored as hand-authored design. Pass
  `exclude: [~r/.../]` to skip more paths.
  """
  def build(root, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])
    roots = List.wrap(root)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.uniq()
      |> Enum.reject(fn f -> generated?(f) or Enum.any?(exclude, &Regex.match?(&1, f)) end)

    mods =
      files
      |> Enum.flat_map(&modules_in_file/1)
      |> Enum.map(&resolve_local_calls/1)

    names = MapSet.new(mods, & &1.name)

    %{
      root: common_root(roots),
      modules: mods,
      module_names: names,
      loc_total: Enum.sum(Enum.map(mods, & &1.loc)),
      function_total: Enum.sum(Enum.map(mods, &length(&1.functions))),
      literal_index: literal_index(mods),
      dep_graph: dep_graph(mods, names),
      call_graph: call_graph(mods),
      template_refs: template_refs(roots, files)
    }
  end

  # Component names invoked in HEEx markup — `<.name>` (local) and
  # `<Alias.name>` (remote), from `~H`/`~L` sigils in `.ex` and any `.heex`
  # files. Such calls live inside a sigil *string*, so the AST never sees them
  # and the call graph misses them. R7's dead-code check consults this set so a
  # live function component isn't reported as never-called. Name-based (a set of
  # bare function names): erring toward *not* flagging, which is the safe
  # direction for an advisory check.
  @heex_local ~r/<\/?\.([a-z_]\w*)/
  @heex_remote ~r/<\/?[A-Z][\w.]*\.([a-z_]\w*)/
  defp template_refs(roots, ex_files) do
    heex_files = Enum.flat_map(List.wrap(roots), &Path.wildcard(Path.join(&1, "**/*.heex")))

    (ex_files ++ heex_files)
    |> Enum.reduce(MapSet.new(), fn file, acc ->
      case File.read(file) do
        {:ok, src} ->
          refs =
            (Regex.scan(@heex_local, src, capture: :all_but_first) ++
               Regex.scan(@heex_remote, src, capture: :all_but_first))
            |> List.flatten()

          Enum.reduce(refs, acc, &MapSet.put(&2, &1))

        _ ->
          acc
      end
    end)
  end

  # The longest shared path prefix of the include roots — used only for display
  # and relative paths; matching/analysis works off absolute file paths.
  defp common_root([one]), do: one

  defp common_root(roots) do
    segs = Enum.map(roots, &Path.split/1)

    common =
      segs
      |> Enum.zip()
      |> Enum.take_while(fn tuple -> tuple |> Tuple.to_list() |> Enum.uniq() |> length() == 1 end)
      |> Enum.map(&elem(&1, 0))

    case common do
      [] -> hd(roots)
      parts -> Path.join(parts)
    end
  end

  defp generated?(file) do
    case File.open(file, [:read], fn io -> IO.read(io, 400) end) do
      {:ok, head} when is_binary(head) -> String.contains?(head, "GENERATED")
      _ -> false
    end
  end

  # ── per-file parsing ──────────────────────────────────────────────────
  defp modules_in_file(file) do
    src = File.read!(file)
    loc = src |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))

    case Code.string_to_quoted(src, columns: true) do
      {:ok, ast} ->
        try do
          {_, acc} = walk(ast, %{current: nil, mods: %{}, file: file}, & &1)
          # attribute file-wide LOC to the first module (a rough but stable split)
          case Map.values(acc.mods) do
            [] -> []
            [first | rest] -> [%{first | loc: loc} | rest]
          end
        rescue
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  # A hand-written recursive walk so we always know the enclosing module.
  defp walk({:defmodule, meta, [{:__aliases__, _, parts} | [[do: body]]]}, st, _k) do
    # Elixir prepends the enclosing module to any nested `defmodule`, so
    # `defmodule Address` inside `…CheckoutFlow` is `…CheckoutFlow.Address`.
    # Qualify it here so the name carries its full altitude/feature prefix.
    local = Enum.map_join(parts, ".", &to_string/1)
    name = if st.current, do: st.current <> "." <> local, else: local

    mod = %Mod{name: name, file: st.file, line: meta[:line] || 0}
    prev = st.current
    st = %{st | current: name, mods: Map.put_new(st.mods, name, mod)}
    {_, st} = walk(body, st, & &1)
    # restore the enclosing module (nested defmodule): the parent's own defs
    # that follow the nested one must still be attributed to the parent.
    {nil, %{st | current: prev}}
  end

  # `defstruct ...` — mark the module as defining a struct (an R10 entity
  # candidate), and still descend into the field list so default literals are
  # recorded (an R3 config-candidate like `last_output: 0.0` must still count).
  defp walk({:defstruct, _, args} = node, st, _k) when st.current != nil do
    st = update_mod(st, st.current, fn m -> %{m | defines_struct: true} end)
    {_, st} = walk(args, st, & &1)
    {node, st}
  end

  # `use SomeMacro` — record the used module as a content signal (a layer map
  # can match on it, e.g. `uses: [~r/Ecto\\.Schema/]` → persistence).
  defp walk({:use, _, [{:__aliases__, _, parts} | _]} = node, st, _k) when st.current != nil do
    case alias_name(parts) do
      nil -> {node, st}
      name -> {node, update_mod(st, st.current, fn m -> %{m | uses: [name | m.uses]} end)}
    end
  end

  # `@ala_layer :name` before a def — the per-function layer override. Consumed
  # by the next def (like `@doc`), so it tags one function unless repeated.
  defp walk({:@, _, [{:ala_layer, _, [tag]}]} = node, st, _k) when st.current != nil and is_atom(tag) do
    {node, Map.put(st, :pending_layer, tag)}
  end

  defp walk({def_kw, meta, [head | tail]} = node, st, _k)
       when def_kw in [:def, :defp] and st.current != nil do
    {name, arity} = fun_name_arity(head)
    body = fun_body(tail)

    fun = %Fun{
      name: name,
      arity: arity,
      line: meta[:line] || 0,
      private: def_kw == :defp,
      body: body,
      module: st.current,
      file: st.file,
      layer_tag: Map.get(st, :pending_layer),
      macro_generated: Map.get(st, :in_quote, false)
    }

    st = update_mod(st, st.current, fn m -> %{m | functions: [fun | m.functions]} end)
    st = Map.put(st, :pending_layer, nil)
    # descend into the body for refs/literals/state ops/calls, tracking the
    # enclosing function's line so literal findings get a useful location.
    prev = Map.get(st, :fun_line, 0)
    {_, st} = walk(body, Map.put(st, :fun_line, meta[:line] || 0), & &1)
    {node, Map.put(st, :fun_line, prev)}
  end

  # `alias` statements — build the module's short→full name table so remote
  # calls (`Cart.foo`) can be resolved to full function ids. Still descend so
  # the existing ref recording (full module names) keeps working.
  defp walk({:alias, _, args} = node, st, _k) when st.current != nil and is_list(args) do
    st =
      Enum.reduce(alias_pairs(args), st, fn {short, full}, acc ->
        update_mod(acc, acc.current, fn m -> %{m | aliases: Map.put(m.aliases, short, full)} end)
      end)

    {_, st} = walk(args, st, & &1)
    {node, st}
  end

  # Multi-alias `A.{B, C}` — record the full names A.B, A.C (must precede the
  # remote-call clause, whose `fun` would otherwise capture the `:{}`).
  defp walk({{:., _, [{:__aliases__, _, base}, :{}]}, _, args} = node, st, _k)
       when st.current != nil and is_list(base) do
    st =
      Enum.reduce(args, st, fn
        {:__aliases__, _, parts}, acc when is_list(parts) ->
          case alias_name(base ++ parts) do
            nil -> acc
            ref -> update_mod(acc, acc.current, fn m -> %{m | refs: MapSet.put(m.refs, ref)} end)
          end

        _, acc ->
          acc
      end)

    {node, st}
  end

  defp walk({:__aliases__, _, parts} = node, st, _k) when st.current != nil do
    case alias_name(parts) do
      nil -> {node, st}
      ref -> {node, update_mod(st, st.current, fn m -> %{m | refs: MapSet.put(m.refs, ref)} end)}
    end
  end

  # remote calls: capture state ops and local-call bookkeeping is done post-hoc
  defp walk({{:., dmeta, [{:__aliases__, _, parts}, fun]}, _meta, args} = node, st, _k)
       when st.current != nil do
    st =
      case alias_name(parts) do
        nil -> st
        ref -> update_mod(st, st.current, fn m -> %{m | refs: MapSet.put(m.refs, ref)} end)
      end

    st = record_state_op(st, parts, fun, dmeta[:line] || 0)
    {_, st} = walk(args, st, & &1)
    {node, st}
  end

  # Sigil bodies are DSL text, not contract literals: a `~p"/cart"` verified
  # route is compile-checked against the router (the opposite of a silent
  # contract), and a `~H`/`~L` template's markup is not code. Don't descend, so
  # their strings aren't collected as R5 literals. (HEEx component references
  # are picked up separately by a raw-source scan, not this walk.)
  defp walk({sigil, _meta, _args} = node, st, _k)
       when sigil in [:sigil_p, :sigil_P, :sigil_H, :sigil_L] do
    {node, st}
  end

  # literals
  defp walk(lit, st, _k)
       when st.current != nil and (is_binary(lit) or is_atom(lit) or is_integer(lit) or is_float(lit)) do
    {lit, add_literal(st, lit)}
  end

  # `quote do ... end` — functions defined inside a macro body are injected into
  # *other* modules, so their call sites aren't in this source. Mark defs found
  # here as macro_generated (R7 must not call them dead), then restore the flag.
  defp walk({:quote, _meta, args} = node, st, _k) when is_list(args) do
    prev = Map.get(st, :in_quote, false)
    {_, st} = walk(args, Map.put(st, :in_quote, true), & &1)
    {node, Map.put(st, :in_quote, prev)}
  end

  # generic descent
  defp walk({_form, _meta, args} = node, st, _k) when is_list(args) do
    {_, st} = walk(args, st, & &1)
    {node, st}
  end

  # A 2-tuple whose first element is an atom is (almost always) a keyword/map
  # pair or a tagged tuple; the atom is a *key/tag identifier*, not a contract
  # value, so don't collect it as a literal (this removes the struct-field /
  # keyword-key noise that would otherwise swamp R5).
  defp walk({a, b}, st, _k) when is_atom(a) do
    {_, st} = walk(b, st, & &1)
    {{a, b}, st}
  end

  defp walk({a, b}, st, _k) do
    {_, st} = walk(a, st, & &1)
    {_, st} = walk(b, st, & &1)
    {{a, b}, st}
  end

  defp walk(list, st, _k) when is_list(list) do
    st = Enum.reduce(list, st, fn el, acc -> elem(walk(el, acc, & &1), 1) end)
    {list, st}
  end

  defp walk(other, st, _k), do: {other, st}

  # ── helpers ───────────────────────────────────────────────────────────
  defp update_mod(st, name, f), do: %{st | mods: Map.update!(st.mods, name, f)}

  # A module alias like `Foo.Bar`; nil for dynamic aliases whose parts aren't
  # all plain atoms (e.g. `unquote(x).Bar`, `__MODULE__.Sub`) — real code has these.
  defp alias_name(parts) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &to_string/1), else: nil
  end

  defp alias_name(_), do: nil

  defp fun_name_arity({:when, _, [inner | _]}), do: fun_name_arity(inner)
  defp fun_name_arity({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fun_name_arity({name, _, nil}) when is_atom(name), do: {name, 0}
  defp fun_name_arity(_), do: {:__unknown__, 0}

  defp fun_body([[do: body] | _]), do: body
  defp fun_body([_args, [do: body] | _]), do: body
  defp fun_body([[{:do, body} | _]]), do: body
  defp fun_body(_), do: nil

  @common_atoms ~w(ok error noreply reply stop nil true false do end)a
  defp add_literal(st, lit) when is_atom(lit) do
    if lit in @common_atoms or is_nil(lit) or lit in [true, false] do
      st
    else
      push_literal(st, {:atom, lit})
    end
  end

  defp add_literal(st, lit) when is_binary(lit) do
    if String.length(lit) < 2, do: st, else: push_literal(st, {:string, lit})
  end

  defp add_literal(st, lit) when is_integer(lit) or is_float(lit),
    do: push_literal(st, {:number, lit})

  defp push_literal(st, lit) do
    update_mod(st, st.current, fn m -> %{m | literals: [{lit, current_line(st)} | m.literals] } end)
  end

  defp current_line(st), do: Map.get(st, :fun_line, 0)

  @state_mods [~w(ets)a, ~w(persistent_term)a, [:Agent], [:Process]]
  defp record_state_op(st, parts, fun, line) do
    tag =
      cond do
        parts == [:"Elixir"] -> nil
        match_state?(parts, :ets) -> {:ets, fun}
        match_state?(parts, :persistent_term) -> {:persistent_term, fun}
        List.last(parts) == :Agent -> {:agent, fun}
        List.last(parts) == :Process and fun in [:put, :get] -> {:process_dict, fun}
        true -> nil
      end

    if tag do
      update_mod(st, st.current, fn m -> %{m | state_ops: [{tag, line} | m.state_ops]} end)
    else
      st
    end
  end

  defp match_state?(parts, atom), do: List.last(parts) == atom or parts == [atom]
  _ = @state_mods

  # after collecting, count internal calls to each locally-defined function name (R7)
  defp resolve_local_calls(%Mod{} = m) do
    names = MapSet.new(m.functions, & &1.name)

    counts =
      Enum.reduce(m.functions, %{}, fn f, acc ->
        count_calls(f.body, names, acc)
      end)

    %{m | local_call_counts: counts, functions: Enum.reverse(m.functions), literals: Enum.reverse(m.literals)}
  end

  defp count_calls(ast, names, acc) do
    {_, acc} =
      Macro.prewalk(ast, acc, fn
        # a `&name/arity` capture is a call site (e.g. `Enum.each(xs, &step/1)`);
        # the plain-call clause below misses it because the captured name has
        # `nil` args, not a list. Count it so R7 doesn't call `step` dead.
        {:&, _, [{:/, _, [{name, _, nil}, arity]}]} = node, a
        when is_atom(name) and is_integer(arity) ->
          if MapSet.member?(names, name), do: {node, Map.update(a, name, 1, &(&1 + 1))}, else: {node, a}

        {name, _, args} = node, a when is_atom(name) and is_list(args) ->
          if MapSet.member?(names, name), do: {node, Map.update(a, name, 1, &(&1 + 1))}, else: {node, a}

        node, a ->
          {node, a}
      end)

    acc
  end

  defp literal_index(mods) do
    for m <- mods, {lit, _line} <- m.literals, reduce: %{} do
      acc -> Map.update(acc, lit, MapSet.new([m.name]), &MapSet.put(&1, m.name))
    end
  end

  # directed graph among PROJECT modules only (external refs ignored)
  defp dep_graph(mods, names) do
    for m <- mods, into: %{} do
      {m.name, m.refs |> Enum.filter(&MapSet.member?(names, &1)) |> Enum.reject(&(&1 == m.name)) |> MapSet.new()}
    end
  end

  # ── function-level call graph (the finer-grained, module-agnostic model) ──
  # Node = {module, name, arity}. Edge = caller calls callee, resolved to a
  # real project function (local calls by name; remote calls through the
  # module's alias table). External calls are dropped, like dep_graph.
  defp call_graph(mods) do
    pindex = project_index(mods)
    base = for m <- mods, fun <- m.functions, into: %{}, do: {{m.name, fun.name, fun.arity}, MapSet.new()}

    for m <- mods, fun <- m.functions, reduce: base do
      g ->
        callees = callees_of(fun.body, m, pindex) |> MapSet.delete({m.name, fun.name, fun.arity})
        Map.update(g, {m.name, fun.name, fun.arity}, callees, &MapSet.union(&1, callees))
    end
  end

  defp project_index(mods) do
    for m <- mods, into: %{} do
      names = Enum.reduce(m.functions, %{}, fn f, acc -> Map.update(acc, f.name, [f.arity], &[f.arity | &1]) end)
      {m.name, names}
    end
  end

  defp callees_of(body, m, pindex) do
    local = Map.get(pindex, m.name, %{})

    {_, set} =
      Macro.prewalk(body, MapSet.new(), fn
        # `&Mod.fun/arity` capture → a remote call edge
        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, parts}, fun]}, _, []}, arity]}]} = node, acc
        when is_atom(fun) and is_integer(arity) ->
          {node, add_callee(acc, pindex, resolve_mod(alias_name(parts), m, pindex), fun, arity)}

        # `&fun/arity` capture → a local call edge
        {:&, _, [{:/, _, [{name, _, nil}, arity]}]} = node, acc
        when is_atom(name) and is_integer(arity) ->
          if Map.has_key?(local, name),
            do: {node, add_callee(acc, pindex, m.name, name, arity)},
            else: {node, acc}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, cargs} = node, acc when is_atom(fun) and is_list(cargs) ->
          {node, add_callee(acc, pindex, resolve_mod(alias_name(parts), m, pindex), fun, length(cargs))}

        {name, _, cargs} = node, acc when is_atom(name) and is_list(cargs) ->
          if Map.has_key?(local, name),
            do: {node, add_callee(acc, pindex, m.name, name, length(cargs))},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    set
  end

  # Resolve a written module reference to a full project module name, mirroring
  # Elixir scoping: an explicit `alias` wins, then the implicit nested alias
  # (`Address` inside `…CheckoutFlow` → `…CheckoutFlow.Address`, trying the
  # caller and each ancestor prefix), then the bare name as written.
  defp resolve_mod(nil, _m, _pindex), do: nil

  defp resolve_mod(written, m, pindex) when is_binary(written) do
    cond do
      Map.has_key?(m.aliases, written) -> m.aliases[written]
      nested = nested_match(m.name, written, pindex) -> nested
      true -> written
    end
  end

  defp nested_match(caller_module, written, pindex) do
    caller_module
    |> ancestor_prefixes()
    |> Enum.find_value(fn prefix ->
      candidate = prefix <> "." <> written
      if Map.has_key?(pindex, candidate), do: candidate
    end)
  end

  # "A.B.C" → ["A.B.C", "A.B", "A"] — the caller and its enclosing scopes.
  defp ancestor_prefixes(module) do
    module
    |> String.split(".")
    |> Enum.reduce([], fn seg, acc ->
      case acc do
        [] -> [seg]
        [top | _] -> [top <> "." <> seg | acc]
      end
    end)
  end

  defp add_callee(acc, _pindex, nil, _fun, _arity), do: acc

  defp add_callee(acc, pindex, mod, fun, arity) do
    case get_in(pindex, [mod, fun]) do
      nil -> acc
      arities -> MapSet.put(acc, {mod, fun, if(arity in arities, do: arity, else: Enum.min(arities))})
    end
  end

  # short→full pairs from an `alias` statement's arguments.
  defp alias_pairs([{:__aliases__, _, parts}]) when is_list(parts),
    do: [{to_string(List.last(parts)), mod_name(parts)}]

  defp alias_pairs([{:__aliases__, _, parts}, opts]) when is_list(parts) and is_list(opts) do
    case opts[:as] do
      {:__aliases__, _, as_parts} -> [{to_string(List.last(as_parts)), mod_name(parts)}]
      _ -> [{to_string(List.last(parts)), mod_name(parts)}]
    end
  end

  defp alias_pairs([{{:., _, [{:__aliases__, _, base}, :{}]}, _, subs}]) when is_list(base) and is_list(subs) do
    for {:__aliases__, _, parts} <- subs, is_list(parts), do: {to_string(List.last(parts)), mod_name(base ++ parts)}
  end

  defp alias_pairs(_), do: []

  defp mod_name(parts), do: Enum.map_join(parts, ".", &to_string/1)
end
