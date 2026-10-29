defmodule AlaLint.StructBuilds do
  @moduledoc """
  Where source builds structs: `%Mod{...}` literals and `struct/2`, `struct!/2` calls, with the
  module written resolved through the enclosing module's aliases. A struct in a pattern (a
  function head, either side of `->`'s left, `=`'s left, `<-`'s left, `match?/2`) is a match,
  not a build, and an update (`%Mod{s | f: v}`) keeps every field, so neither counts.
  Reads any parsed file, `lib/` or `test/`, without the project model.
  """

  @pattern_first [:match?, :assert_receive, :assert_received, :refute_receive, :refute_received]

  @doc "Parse a file, or nil when it doesn't parse."
  def parse(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      _ -> nil
    end
  end

  @doc """
  Every struct built in `ast`: `[%{module: enclosing, struct: name, line: n, how: :literal |
  :struct | :struct!}]`. `known` (module names) resolves a nested module's implicit alias.
  """
  def in_source(ast, known \\ MapSet.new()) do
    for {name, body} <- modules(ast), b <- builds(body, context(name, body, known)), do: b
  end

  @doc "The structs a function body returns: `{:struct, name}` and `{:local, fun, arity}` (a local call in return position)."
  def returned(body, ctx) do
    case last(body) do
      {:%, _, [_mod, {:%{}, _, [{:|, _, _}]}]} ->
        []

      {:%, _, [mod, _map]} ->
        struct_ref(resolve(mod, ctx))

      {fun, _, [mod | _]} when fun in [:struct, :struct!] ->
        struct_ref(resolve(mod, ctx))

      {{:., _, [{:__aliases__, _, [:Kernel]}, fun]}, _, [mod | _]}
      when fun in [:struct, :struct!] ->
        struct_ref(resolve(mod, ctx))

      {:case, _, [_subject, [do: arms]]} ->
        arm_returns(arms, ctx)

      {:cond, _, [[do: arms]]} ->
        arm_returns(arms, ctx)

      {branch, _, [_cond, kw]} when branch in [:if, :unless] and is_list(kw) ->
        returned(kw[:do], ctx) ++ returned(kw[:else], ctx)

      {:with, _, args} when is_list(args) ->
        kw = List.last(args)
        if is_list(kw), do: returned(kw[:do], ctx) ++ arm_returns(kw[:else] || [], ctx), else: []

      {name, _, args} when is_atom(name) and is_list(args) ->
        [{:local, name, length(args)}]

      _ ->
        []
    end
  end

  @doc "A struct's fields and enforced keys from its module's `defstruct` and `@enforce_keys`, or nil."
  def definition(ast, module_name) do
    case List.keyfind(modules(ast), module_name, 0) do
      nil ->
        nil

      {_, body} ->
        exprs = top_level(body)
        attrs = for {:@, _, [{name, _, [value]}]} <- exprs, into: %{}, do: {name, value}

        case for({:defstruct, _, [spec]} <- exprs, do: spec) do
          [spec | _] ->
            %{
              fields: field_names(spec, attrs),
              enforce: field_names(Map.get(attrs, :enforce_keys, []), attrs)
            }

          [] ->
            nil
        end
    end
  end

  @doc "The module a written alias names inside `ctx` (`%{module:, aliases:, known:}`), or nil."
  def resolve({:__MODULE__, _, _}, ctx), do: ctx.module

  def resolve({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, ctx),
    do: Enum.join([ctx.module | Enum.map(rest, &to_string/1)], ".")

  def resolve({:__aliases__, _, [first | rest] = parts}, ctx) do
    if Enum.all?(parts, &is_atom/1) do
      written = Enum.map_join(parts, ".", &to_string/1)

      case Map.fetch(ctx.aliases, to_string(first)) do
        {:ok, base} -> Enum.join([base | Enum.map(rest, &to_string/1)], ".")
        :error -> implicit(written, ctx)
      end
    end
  end

  def resolve(mod, _ctx) when is_atom(mod) and mod not in [nil, true, false] do
    case Atom.to_string(mod) do
      "Elixir." <> name -> name
      _ -> nil
    end
  end

  def resolve(_, _ctx), do: nil

  @doc "Every module in `ast` with its body, nested ones by their full name."
  def modules(ast), do: modules(ast, nil)

  defp modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent) do
    local = Enum.map_join(parts, ".", &to_string/1)
    name = if parent, do: parent <> "." <> local, else: local
    [{name, body} | modules(body, name)]
  end

  defp modules({_, _, args}, parent) when is_list(args),
    do: Enum.flat_map(args, &modules(&1, parent))

  defp modules({a, b}, parent), do: modules(a, parent) ++ modules(b, parent)
  defp modules(list, parent) when is_list(list), do: Enum.flat_map(list, &modules(&1, parent))
  defp modules(_, _parent), do: []

  @doc "The resolution context of a module: its name, its aliases, and the known module names."
  def context(name, body, known) do
    aliases =
      body
      |> alias_nodes()
      |> Enum.flat_map(&AlaLint.Analyzer.alias_pairs/1)
      |> Map.new()

    %{module: name, aliases: aliases, known: known}
  end

  defp alias_nodes({:defmodule, _, _}), do: []
  defp alias_nodes({:alias, _, args}) when is_list(args), do: [args]
  defp alias_nodes({_, _, args}) when is_list(args), do: Enum.flat_map(args, &alias_nodes/1)
  defp alias_nodes({a, b}), do: alias_nodes(a) ++ alias_nodes(b)
  defp alias_nodes(list) when is_list(list), do: Enum.flat_map(list, &alias_nodes/1)
  defp alias_nodes(_), do: []

  defp builds({:defmodule, _, _}, _ctx), do: []
  defp builds({:quote, _, _}, _ctx), do: []

  defp builds({kind, _, [_head | rest]}, ctx) when kind in [:def, :defp, :defmacro, :defmacrop],
    do: builds(rest, ctx)

  defp builds({:=, _, [_pattern, expr]}, ctx), do: builds(expr, ctx)
  defp builds({op, _, [_pattern, expr]}, ctx) when op in [:->, :<-], do: builds(expr, ctx)
  defp builds({fun, _, [_pattern | rest]}, ctx) when fun in @pattern_first, do: builds(rest, ctx)

  defp builds({:%, _, [_mod, {:%{}, _, [{:|, _, [_base, fields]}]}]}, ctx),
    do: builds(fields, ctx)

  defp builds({:%, meta, [mod, map]}, ctx),
    do: build(resolve(mod, ctx), meta, :literal, ctx) ++ builds(map, ctx)

  defp builds({fun, meta, [mod | rest]}, ctx) when fun in [:struct, :struct!],
    do: build(resolve(mod, ctx), meta, fun, ctx) ++ builds([mod | rest], ctx)

  defp builds({{:., _, [{:__aliases__, _, [:Kernel]}, fun]}, meta, [mod | rest]}, ctx)
       when fun in [:struct, :struct!],
       do: build(resolve(mod, ctx), meta, fun, ctx) ++ builds([mod | rest], ctx)

  defp builds({form, _, args}, ctx) when is_list(args), do: builds(form, ctx) ++ builds(args, ctx)
  defp builds({a, b}, ctx), do: builds(a, ctx) ++ builds(b, ctx)
  defp builds(list, ctx) when is_list(list), do: Enum.flat_map(list, &builds(&1, ctx))
  defp builds(_, _ctx), do: []

  defp build(nil, _meta, _how, _ctx), do: []

  defp build(name, meta, how, ctx),
    do: [%{module: ctx.module, struct: name, line: meta[:line] || 0, how: how}]

  # a bare name not aliased may be a nested module's sibling (`Address` inside `Checkout`)
  defp implicit(written, ctx) do
    nested = ctx.module <> "." <> written

    if not MapSet.member?(ctx.known, written) and MapSet.member?(ctx.known, nested),
      do: nested,
      else: written
  end

  defp struct_ref(nil), do: []
  defp struct_ref(name), do: [{:struct, name}]

  defp arm_returns(arms, ctx) when is_list(arms),
    do: for({:->, _, [_pats, body]} <- arms, r <- returned(body, ctx), do: r)

  defp arm_returns(_, _ctx), do: []

  defp last({:__block__, _, [_ | _] = exprs}), do: List.last(exprs)
  defp last(expr), do: expr

  defp top_level({:__block__, _, exprs}), do: exprs
  defp top_level(expr), do: [expr]

  defp field_names({:@, _, [{name, _, _}]}, attrs),
    do: field_names(Map.get(attrs, name, []), Map.delete(attrs, name))

  defp field_names({:++, _, [a, b]}, attrs), do: field_names(a, attrs) ++ field_names(b, attrs)

  defp field_names(list, _attrs) when is_list(list) do
    for item <- list, name = field_name(item), name != nil, do: name
  end

  defp field_names(_, _attrs), do: []

  defp field_name(name) when is_atom(name), do: name
  defp field_name({name, _default}) when is_atom(name), do: name
  defp field_name(_), do: nil
end
