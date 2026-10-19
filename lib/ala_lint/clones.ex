defmodule AlaLint.Clones do
  @moduledoc """
  Duplicated logic across functions. Exact (Type-2) clones: the same code shape in two or more
  functions, with variables renamed and literal values changed; calls, module names and field names
  are kept, since they carry the meaning. A fragment is a whole function, a run of its clauses, one
  clause, an expression, or a run of consecutive statements or pipeline stages, and each clone group
  is reported once, at its largest match. Near misses (a copy then edited) are compared clause to
  clause across modules; see `near_misses/2`.

  Size is counted in normalized AST nodes. A clause or statement that is a single call on plain
  arguments (a delegation, a `wire/3` clause, a routing `handle_event`) or plain data (`ports/0`)
  adds nothing to a fragment's size: those shapes look alike because wiring looks alike.
  """

  alias AlaLint.Finding

  @default_min_size 26
  def default_min_size, do: @default_min_size

  def run(model) do
    min = Map.get(model, :min_clone_size) || @default_min_size

    {frags, clauses} =
      model.modules
      |> Enum.map(&module_fragments(&1, min))
      |> Enum.reduce({[], []}, fn {f, c}, {fs, cs} -> {f ++ fs, c ++ cs} end)

    exact =
      frags
      |> Enum.filter(&logic?(&1.key))
      |> Enum.group_by(& &1.key)
      |> Map.values()
      |> Enum.filter(&(&1 |> Enum.uniq_by(fn fr -> fr.fun end) |> length() >= 2))

    kept = exact |> by_size() |> Enum.reduce([], &keep_unless_covered/2)

    near_misses(clauses, min)
    |> by_size()
    |> Enum.reject(fn pair -> linked?(pair, kept) end)
    |> Enum.reduce(kept, &keep_unless_covered/2)
    |> Enum.reverse()
    |> Enum.map(&finding(&1, model))
  end

  defp by_size(groups), do: Enum.sort_by(groups, &{-hd(&1).size, hd(&1).file, hd(&1).lo})

  # An exact clone already reported between the same two functions is the precise account.
  defp linked?(pair, kept) do
    funs = MapSet.new(pair, & &1.fun)
    Enum.any?(kept, fn group -> MapSet.subset?(funs, MapSet.new(group, & &1.fun)) end)
  end

  # A smaller group whose every copy sits inside a copy already reported is part of that match.
  defp keep_unless_covered(group, kept) do
    covered? =
      Enum.all?(group, fn fr ->
        Enum.any?(kept, fn k ->
          Enum.any?(k, &(&1.file == fr.file and &1.lo <= fr.lo and fr.hi <= &1.hi))
        end)
      end)

    if covered?, do: kept, else: [group | kept]
  end

  defp finding(group, model) do
    [first | _] =
      copies = group |> Enum.uniq_by(&{&1.fun, &1.lo}) |> Enum.sort_by(&{&1.file, &1.lo})

    where = Enum.map_join(copies, " and ", &"#{describe(&1)} (#{rel(&1.file, model)}:#{&1.lo})")
    {mod, _, _} = first.fun

    # inside one module it's the abstraction's own interior, which the checklist leaves to its author
    rule = if Enum.all?(copies, &(elem(&1.fun, 0) == mod)), do: :clone_inside, else: :clone

    %Finding{
      rule: rule,
      module: mod,
      file: first.file,
      line: first.lo,
      weight: AlaLint.Rules.weights()[rule],
      severity: AlaLint.Rules.default_severity(rule),
      message:
        "#{if Map.has_key?(first, :shared), do: "nearly the same logic (#{first.size} nodes in common)", else: "the same logic (#{first.size} nodes, names and literals aside)"} in #{where}: one concept written twice. Make it one abstraction both compose, each instance configured with its own values where it is placed (R7)"
    }
  end

  defp describe(%{fun: {mod, name, arity}, whole: whole}) do
    fun = "#{short(mod)}.#{name}/#{arity}"
    if whole, do: fun, else: "part of #{fun}"
  end

  defp short(mod), do: mod |> String.split(".") |> Enum.take(-2) |> Enum.join(".")

  defp rel(file, %{root: root}) when is_binary(root),
    do: Path.relative_to(file, Path.dirname(root))

  defp rel(file, _model), do: file

  # A copy that was then edited is no longer the same shape, so clauses are also compared pairwise:
  # aligned top-down, identical subtrees of at least @seed nodes (variables aside, atoms kept) count
  # as shared. The `case`/tuple skeleton every state function has counts for nothing, so what is
  # shared is the copied content (a normalisation, an error branch, the port names). Calibrated
  # 2026-10-19: the change-cost experiment's edited copy shares 0.47; the closest pairs that are not
  # copies (two summaries' field projections, two stories' mounts) 0.42 and 0.40.
  # Only across modules: one state module's port handlers share its own port names and helpers, the
  # interior of one abstraction, which the checklist leaves alone (R7, "little balls of mud").
  @seed 4
  @near_share 0.45
  defp near_misses(clauses, min) do
    indexed = clauses |> Enum.sort_by(& &1.nodes) |> Enum.with_index()

    for {a, i} <- indexed,
        {b, j} <- indexed,
        j > i,
        elem(a.fun, 0) != elem(b.fun, 0),
        a.nodes >= b.nodes * @near_share / 2,
        shared = shared_nodes(a.key, b.key),
        shared >= min,
        2 * shared / (a.nodes + b.nodes) >= @near_share do
      Enum.map([a, b], &Map.merge(&1, %{size: shared, shared: shared}))
    end
  end

  defp shared_nodes(a, a), do: if((n = nodes(a)) >= @seed, do: n, else: 0)
  defp shared_nodes(a, b) when is_list(a) and is_list(b), do: align(a, b)

  defp shared_nodes(a, b)
       when is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b) and
              elem(a, 0) == elem(b, 0) do
    pairs = Enum.zip(Tuple.to_list(a), Tuple.to_list(b))

    if Enum.all?(pairs, fn {x, y} -> term?(x) or x == y end),
      do: Enum.sum(for {x, y} <- pairs, term?(x), do: shared_nodes(x, y)),
      else: 0
  end

  defp shared_nodes(_a, _b), do: 0

  # The best order-preserving pairing of two lists' items (no cost for a gap).
  defp align(xs, ys) do
    row0 = List.duplicate(0, length(ys) + 1)

    xs
    |> Enum.reduce(row0, fn x, prev ->
      ys
      |> Enum.zip(Enum.zip(prev, tl(prev)))
      |> Enum.reduce([0], fn {y, {diag, up}}, [left | _] = acc ->
        [Enum.max([up, left, diag + shared_nodes(x, y)]) | acc]
      end)
      |> Enum.reverse()
    end)
    |> List.last()
  end

  defp nodes(t) when is_list(t), do: t |> Enum.map(&nodes/1) |> Enum.sum()

  defp nodes(t) when is_tuple(t),
    do: 1 + (t |> Tuple.to_list() |> Enum.filter(&term?/1) |> Enum.map(&nodes/1) |> Enum.sum())

  defp nodes(_label), do: 0

  defp term?(x), do: is_list(x) or is_tuple(x)

  defp module_fragments(m, min) do
    m.functions
    |> Enum.reject(&(&1.macro_generated or &1.body == nil))
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.map(fn {{name, arity}, clauses} ->
      function_fragments(Enum.sort_by(clauses, & &1.line), {m.name, name, arity}, m, min)
    end)
    |> Enum.reduce({[], []}, fn {f, c}, {fs, cs} -> {f ++ fs, c ++ cs} end)
  end

  defp function_fragments(clauses, fun, m, min) do
    ctx = %{aliases: m.aliases, min: min, fun: fun, file: m.file, collect: true}

    normalized =
      Enum.map(clauses, fn c ->
        params = norm(c.params, ctx)
        body = norm(c.body, ctx)
        size = if plain?(c.body), do: 0, else: params.size + body.weight
        lo = c.line

        %{
          n: {:clause, params.n, body.n},
          size: size,
          lo: lo,
          hi: max(lo, body.hi),
          frags: body.frags
        }
      end)

    inner = Enum.flat_map(normalized, & &1.frags)
    count = length(clauses)

    runs =
      for i <- 0..(count - 1), j <- i..(count - 1), into: [] do
        run = Enum.slice(normalized, i..j)
        size = run |> Enum.map(& &1.size) |> Enum.sum()

        if size >= min and Enum.at(run, 0).size > 0 and List.last(run).size > 0 do
          fragment({:clauses, Enum.map(run, & &1.n)}, size, hd(run).lo, List.last(run).hi, ctx,
            whole: i == 0 and j == count - 1
          )
        end
      end

    literal = Map.merge(ctx, %{keep_atoms: true, collect: false})

    near =
      for {c, raw} <- Enum.zip(normalized, clauses), c.size >= min do
        n = {:clause, norm(raw.params, literal).n, norm(raw.body, literal).n}
        key = blind(n)
        fr = fragment(n, c.size, c.lo, c.hi, ctx, whole: count == 1)
        %{fr | key: key} |> Map.put(:nodes, nodes(key))
      end

    {Enum.reject(runs, &is_nil/1) ++ inner, near}
  end

  defp fragment(n, size, lo, hi, ctx, opts \\ []) do
    %{
      key: alpha(n),
      size: size,
      lo: lo,
      hi: hi,
      fun: ctx.fun,
      file: ctx.file,
      whole: Keyword.get(opts, :whole, false)
    }
  end

  # Normalizes `ast` and collects the fragments inside it at or over the size threshold. `size`
  # counts nodes; `weight` is the size a run or block contributes, plain statements counting zero.
  defp norm({:__block__, _, [one]}, ctx), do: norm(one, ctx)

  defp norm({:__block__, _, stmts}, ctx) when is_list(stmts) and stmts != [] do
    seq(stmts, :run, ctx)
  end

  defp norm({:|>, _, _} = pipe, ctx), do: seq(stages(pipe), :pipe, ctx)

  defp norm({name, _, nil}, _ctx) when name in [:__MODULE__, :__CALLER__, :__ENV__],
    do: leaf({:k, name})

  defp norm({name, meta, ctx_atom}, _ctx) when is_atom(name) and is_atom(ctx_atom) do
    case Atom.to_string(name) do
      "_" <> _ -> leaf({:k, :_}, meta)
      _ -> leaf({:v, name}, meta)
    end
  end

  defp norm({:@, meta, [{_attr, _, _}]}, _ctx), do: leaf({:l, :attr}, meta)

  defp norm({:__aliases__, meta, parts}, ctx), do: leaf({:m, full_name(parts, ctx)}, meta)

  defp norm({{:., _, [{:__aliases__, _, parts}, fun]}, meta, args}, ctx) when is_list(args),
    do: form({:r, full_name(parts, ctx), fun}, args, meta, ctx)

  defp norm({{:., _, [target, field]}, meta, []}, ctx) when is_atom(field) do
    t = norm(target, ctx)
    node({:f, t.n, field}, [t], meta, ctx)
  end

  defp norm({{:., _, [callee]}, meta, args}, ctx) when is_list(args) do
    f = norm(callee, ctx)
    a = norm_list(args, ctx)
    node({:a, f.n, a.n}, [f, a], meta, ctx)
  end

  defp norm({:<<>>, meta, parts}, ctx) when is_list(parts) do
    if Enum.all?(parts, &is_binary/1),
      do: leaf({:l, :str}, meta),
      else: form(:<<>>, parts, meta, ctx)
  end

  defp norm({name, meta, [{:<<>>, _, _}, mods] = args}, ctx)
       when is_atom(name) and is_list(mods) do
    if sigil?(name), do: leaf({:l, name}, meta), else: form(name, args, meta, ctx)
  end

  defp norm({name, meta, args}, ctx) when is_atom(name) and is_list(args),
    do: form(name, args, meta, ctx)

  defp norm({call, meta, args}, ctx) when is_list(args) do
    c = norm(call, ctx)
    a = norm_list(args, ctx)
    node({:x, c.n, a.n}, [c, a], meta, ctx)
  end

  defp norm({a, b}, ctx) do
    x = norm(a, ctx)
    y = norm(b, ctx)
    node({:t, x.n, y.n}, [x, y], [], ctx)
  end

  defp norm(list, ctx) when is_list(list) do
    l = norm_list(list, ctx)
    %{l | n: {:list, l.n}, size: l.size + 1}
  end

  defp norm(v, _ctx) when v in [nil, true, false], do: leaf({:k, v})
  defp norm(v, %{keep_atoms: true}) when is_atom(v), do: leaf({:l, v})
  defp norm(v, _ctx) when is_atom(v), do: leaf({:l, :atom})
  defp norm(v, _ctx) when is_number(v), do: leaf({:l, :num})
  defp norm(v, _ctx) when is_binary(v), do: leaf({:l, :str})
  defp norm(_other, _ctx), do: leaf({:l, :other})

  defp form(head, args, meta, ctx) do
    a = norm_list(args, ctx)
    node({:c, head, a.n}, [a], meta, ctx)
  end

  defp norm_list(items, ctx) do
    parts = Enum.map(items, &norm(&1, ctx))
    combine(Enum.map(parts, & &1.n), parts, [])
  end

  defp node(n, parts, meta, ctx) do
    s = combine(n, parts, meta)
    s = %{s | size: s.size + 1, weight: s.size + 1}

    if ctx.collect and s.size >= ctx.min and s.hi > 0,
      do: %{s | frags: [fragment(n, s.size, s.lo, s.hi, ctx) | s.frags]},
      else: s
  end

  defp combine(n, parts, meta) do
    line = meta[:line] || 0

    %{
      n: n,
      size: parts |> Enum.map(& &1.size) |> Enum.sum(),
      weight: parts |> Enum.map(& &1.weight) |> Enum.sum(),
      lo: Enum.min(for(l <- [line | Enum.map(parts, & &1.lo)], l > 0, do: l), fn -> 0 end),
      hi: Enum.max([line | Enum.map(parts, & &1.hi)]),
      frags: Enum.flat_map(parts, & &1.frags)
    }
  end

  defp leaf(n, meta \\ []) do
    line = meta[:line] || 0
    %{n: n, size: 1, weight: 1, lo: line, hi: line, frags: []}
  end

  # A block or pipeline: the whole is one node, and every shorter run of two or more consecutive
  # statements (stages) is a fragment too, so a chunk copied into a longer body is still found.
  defp seq(items, tag, ctx) do
    parts =
      Enum.map(items, fn ast ->
        p = norm(ast, ctx)
        if tag == :run and plain?(ast), do: %{p | weight: 0}, else: p
      end)

    whole = combine({tag, Enum.map(parts, & &1.n)}, parts, [])
    whole = %{whole | size: whole.size + 1}
    count = length(parts)

    runs =
      for i <- 0..(count - 1),
          j <- (i + 1)..(count - 1)//1,
          {i, j} != {0, count - 1},
          run = Enum.slice(parts, i..j),
          weight = run |> Enum.map(& &1.weight) |> Enum.sum(),
          ctx.collect and weight >= ctx.min,
          lo = run |> Enum.map(& &1.lo) |> Enum.filter(&(&1 > 0)) |> Enum.min(fn -> 0 end),
          lo > 0 do
        fragment({tag, Enum.map(run, & &1.n)}, weight, lo, Enum.max(Enum.map(run, & &1.hi)), ctx)
      end

    frags =
      if ctx.collect and whole.weight >= ctx.min and whole.lo > 0,
        do: [fragment(whole.n, whole.weight, whole.lo, whole.hi, ctx) | runs],
        else: runs

    %{whole | frags: frags ++ whole.frags}
  end

  defp stages({:|>, _, [left, right]}), do: stages(left) ++ [right]
  defp stages(other), do: [other]

  defp full_name([first | rest], ctx) when is_atom(first) do
    short = Atom.to_string(first)

    case Map.get(ctx.aliases, short) do
      nil -> Enum.map_join([first | rest], ".", &to_string/1)
      full -> Enum.join([full | Enum.map(rest, &to_string/1)], ".")
    end
  end

  defp full_name(parts, _ctx), do: inspect(parts)

  # Data alone (a `ports/0` map, a keyword list of options) is declaration, however long.
  @data_forms [:%{}, :{}, :%, :|, :<<>>, :@, :&, :"::"]
  defp logic?({tag, _, _}) when tag in [:r, :a, :x, :pipe], do: true
  defp logic?({:c, name, args}), do: name not in @data_forms or logic?(args)
  defp logic?(t) when is_tuple(t), do: t |> Tuple.to_list() |> logic?()
  defp logic?(list) when is_list(list), do: Enum.any?(list, &logic?/1)
  defp logic?(_), do: false

  defp blind({:v, _}), do: {:v, 0}
  defp blind(list) when is_list(list), do: Enum.map(list, &blind/1)
  defp blind(t) when is_tuple(t), do: t |> Tuple.to_list() |> blind() |> List.to_tuple()
  defp blind(other), do: other

  # Variables are numbered by first appearance, so a consistent rename matches and `a + a` doesn't
  # match `a + b`.
  defp alpha(n) do
    {renamed, _} = rename(n, %{})
    renamed
  end

  defp rename({:v, name}, seen) do
    case seen do
      %{^name => i} -> {{:v, i}, seen}
      _ -> {{:v, map_size(seen)}, Map.put(seen, name, map_size(seen))}
    end
  end

  defp rename(list, seen) when is_list(list), do: Enum.map_reduce(list, seen, &rename/2)

  defp rename(tuple, seen) when is_tuple(tuple) do
    {items, seen} = tuple |> Tuple.to_list() |> rename(seen)
    {List.to_tuple(items), seen}
  end

  defp rename(other, seen), do: {other, seen}

  # A single call on plain arguments, or plain data: delegation and wiring, not logic.
  defp plain?({:__block__, _, [one]}), do: plain?(one)
  defp plain?({:|>, _, _}), do: false

  defp plain?({name, _, args})
       when is_atom(name) and is_list(args) and name not in [:%{}, :{}, :%, :&, :@] do
    call_name?(name) and Enum.all?(args, &simple?/1)
  end

  defp plain?({{:., _, _}, _, args} = ast) when is_list(args),
    do: simple?(ast) or Enum.all?(args, &simple?/1)

  defp plain?({:{}, _, items}), do: Enum.all?(items, &plain?/1)
  defp plain?({a, b}), do: plain?(a) and plain?(b)
  defp plain?(ast), do: simple?(ast)

  defp sigil?(name), do: String.starts_with?(Atom.to_string(name), "sigil_")

  defp call_name?(name), do: Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/, Atom.to_string(name))

  defp simple?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp simple?({:@, _, _}), do: true
  defp simple?({:__aliases__, _, _}), do: true
  defp simple?({:&, _, [n]}) when is_integer(n), do: true
  defp simple?({:&, _, [{:/, _, _}]}), do: true
  defp simple?({:&, _, [{_call, _, args}]}) when is_list(args), do: Enum.all?(args, &simple?/1)
  defp simple?({{:., _, [target, field]}, _, []}) when is_atom(field), do: simple?(target)
  defp simple?({:%{}, _, pairs}), do: Enum.all?(pairs, &simple?/1)
  defp simple?({:{}, _, items}), do: Enum.all?(items, &simple?/1)
  defp simple?({:%, _, [_struct, map]}), do: simple?(map)
  defp simple?({:|, _, [a, b]}), do: simple?(a) and simple?(b)
  defp simple?({:<<>>, _, parts}), do: Enum.all?(parts, &is_binary/1)
  defp simple?({a, b}), do: simple?(a) and simple?(b)
  defp simple?(list) when is_list(list), do: Enum.all?(list, &simple?/1)

  defp simple?({name, _, [{:<<>>, _, _}, mods]}) when is_atom(name) and is_list(mods),
    do: sigil?(name)

  defp simple?(v) when is_atom(v) or is_number(v) or is_binary(v), do: true
  defp simple?(_), do: false
end
