defmodule AlaLint.LiveViewRules do
  @moduledoc """
  Checks for what LiveView designs most often got wrong on the way to a full
  ALA Checklist score, found walking the "max" variants by hand:

    * logic in application templates (R11): comparisons, arithmetic, `case`,
      `if`, `:for`, and calls that compute;
    * words and codes below the composition (R3): text in lower layers' markup,
      validation `message:` strings, sentences built by interpolation, and
      currency or unit codes;
    * a label restating a configured amount (R5);
    * declared ports that drift from what a feature emits, or that nothing
      wires (`:ports`, `:ports_unwired`);
    * page code handing an assign to a lower call, closing over a page helper in
      wiring, or doing store work in a private helper (R11, `:wiring_closure`);
    * report-only measures: the share of application functions holding logic,
      message hops through the page, and a paradigm's wiring vocabulary.

  All need a layer map. Findings use `AlaLint.Finding` with the weights and
  severities in `AlaLint.Rules`.
  """

  alias AlaLint.{Finding, Rules, Template}

  @comparisons [:==, :!=, :===, :!==, :<, :>, :<=, :>=, :in]
  @arithmetic [:+, :-, :*, :/]
  @control [:case, :cond, :if, :unless, :for, :with]
  @code_keys [:currency, :unit, :locale, :time_zone, :timezone]

  def run(%{layers: %{index: _}} = model) do
    template = template_logic(model)

    template ++
      lower_words(model) ++
      restated_amounts(model) ++
      ports(model) ++
      assigns_handoffs(model) ++
      wiring_closures(model) ++
      helper_store_work(model) ++
      ui_io(model) ++
      subcomponents(model) ++
      hops(model) ++
      vocabulary(model)
  end

  def run(_model), do: []

  @doc "Report-only: the share of application functions with an R11 finding."
  def logic_share(%{layers: %{fun_index: fi, app_layers: app}} = model, findings) do
    app_funs = for {{mod, _, _} = id, i} <- fi, MapSet.member?(app, i), do: {mod, id}

    if app_funs == [] do
      []
    else
      flagged =
        for f <- findings,
            f.rule == :r11,
            owner = owner_of(model, f),
            owner != nil,
            into: MapSet.new(),
            do: owner

      pct = round(MapSet.size(flagged) / length(app_funs) * 100)

      [
        finding(
          :r11_share,
          "(project)",
          nil,
          0,
          "#{pct}% of application functions (#{MapSet.size(flagged)} of #{length(app_funs)}) hold logic by R11's checks; a page that is composition only has 0% (report only: a proportion, so a page that is all logic reads differently from one with a stray branch)"
        )
      ]
    end
  end

  def logic_share(_model, _findings), do: []

  defp owner_of(model, %{module: mod, line: line}) do
    with m when m != nil <- Enum.find(model.modules, &(&1.name == mod)),
         fun when fun != nil <-
           m.functions |> Enum.filter(&(&1.line <= line)) |> Enum.max_by(& &1.line, fn -> nil end) do
      {mod, fun.name, fun.arity}
    end
  end

  # ── R11: logic in application templates ──────────────────────────────────
  def template_logic(model) do
    for m <- model.modules,
        composes?(model, m.name),
        {base, text} <- m.templates,
        {line, attr, src} <- Template.expressions(text),
        reason = logic_reason(model, m, attr, src),
        reason != nil do
      finding(
        :r11,
        m.name,
        m.file,
        base + line - 1,
        "#{short(m.name)}'s template #{reason} in `#{String.slice(src, 0, 60)}` — the application only places and wires; move it into a feature or a generic component (R11)"
      )
    end
  end

  defp logic_reason(_model, _m, ":for", _src), do: "iterates"

  defp logic_reason(model, m, _attr, src) do
    case head_keyword(src) do
      nil -> ast_reason(model, m, parse(src))
      kw -> "uses `#{kw}`"
    end
  end

  # `<%= case x do %>`, `<%= if a == b do %>` don't parse on their own
  defp head_keyword(src) do
    case Regex.run(~r/^(case|cond|if|unless|for|with)\b/, src) do
      [_, kw] -> kw
      _ -> nil
    end
  end

  defp parse(src) do
    case Code.string_to_quoted(src, emit_warnings: false) do
      {:ok, ast} -> ast
      _ -> nil
    end
  end

  defp ast_reason(_model, _m, nil), do: nil

  defp ast_reason(model, m, ast) do
    {_, reasons} =
      Macro.prewalk(ast, [], fn
        {sigil, _, _}, acc when sigil in [:sigil_p, :sigil_P] ->
          {nil, acc}

        {:&, _, [{:/, _, [_, arity]}]}, acc when is_integer(arity) ->
          {nil, acc}

        {op, _, [_, _]} = node, acc when op in @comparisons ->
          {node, ["compares (`#{op}`)" | acc]}

        {op, _, [_, _]} = node, acc when op in @arithmetic ->
          {node, ["computes (`#{op}`)" | acc]}

        {kw, _, _} = node, acc when kw in @control ->
          {node, ["uses `#{kw}`" | acc]}

        # building an instance is composition, as in code (`R11` exempts a nested `new`)
        {{:., _, [{:__aliases__, _, _}, :new]}, _, _} = node, acc ->
          {node, acc}

        {{:., _, [{:__aliases__, _, parts}, fun]}, _, _} = node, acc ->
          case project_target(model, m, parts) do
            nil -> {node, acc}
            target -> {node, ["calls #{short(target)}.#{fun}" | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    reasons |> Enum.reverse() |> List.first()
  end

  # A project module below the application, named by an alias in the expression.
  defp project_target(model, m, parts) do
    [first | rest] = Enum.map(parts, &to_string/1)
    full = Enum.join([Map.get(m.aliases, first, first) | rest], ".")

    target =
      Enum.find(model.module_names, fn name ->
        name == full or String.ends_with?(name, "." <> full)
      end)

    if target && not app?(model, target), do: target
  end

  # ── R3: words and codes below the composition ────────────────────────────
  def lower_words(model) do
    lower = for m <- model.modules, lower?(model, m.name), do: m

    markup =
      for m <- lower,
          words =
            for(
              {base, text} <- m.templates,
              {l, w} <- Template.words(text),
              do: {base + l - 1, w}
            ),
          words != [] do
        {line, _} = hd(words)

        shown =
          words
          |> Enum.map(&inspect(elem(&1, 1)))
          |> Enum.uniq()
          |> Enum.take(4)
          |> Enum.join(", ")

        more = if length(words) > 4, do: " (+#{length(words) - 4})", else: ""

        finding(
          :r3,
          m.name,
          m.file,
          line,
          "words in #{short(m.name)}'s markup below the composition: #{shown}#{more} — the page should supply them (R3)"
        )
      end

    # a paradigm's or the foundation's own text (a diagnostic, a diagram label) is about the
    # paradigm, not the product, so interpolated sentences are only looked for above the bottom
    code =
      for m <- lower,
          fun <- m.functions,
          {line, what} <- code_words(fun.body, fun.line, not bottom?(model, m.name)) do
        finding(
          :r3,
          m.name,
          m.file,
          line,
          "#{what} in #{short(m.name)} below the composition — the page should supply it (R3)"
        )
      end

    markup ++ code
  end

  defp code_words(nil, _line, _sentences?), do: []

  defp code_words(body, fun_line, sentences?) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:raise, _, _}, acc ->
          {nil, acc}

        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _}, acc ->
          {nil, acc}

        {:message, msg} = node, acc when is_binary(msg) ->
          {node, [{fun_line, "validation message #{inspect(msg)}"} | acc]}

        {key, code} = node, acc when key in @code_keys and is_binary(code) ->
          {node, [{fun_line, "#{key} code #{inspect(code)}"} | acc]}

        {:<<>>, meta, parts} = node, acc ->
          text = parts |> Enum.filter(&is_binary/1) |> Enum.join()

          if sentences? and length(Regex.scan(~r/[A-Za-z]{2,}/, text)) >= 2 and
               Enum.any?(parts, &(not is_binary(&1))),
             do:
               {node,
                [
                  {meta[:line] || fun_line,
                   "a sentence built by interpolation (#{inspect(String.trim(text))})"}
                  | acc
                ]},
             else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # ── R5: a label restating a configured amount ────────────────────────────
  def restated_amounts(model) do
    configured =
      for m <- model.modules,
          {{:number, n}, _} <- m.literals,
          is_integer(n),
          n >= 10,
          into: MapSet.new(),
          do: n

    strings =
      for m <- model.modules,
          src <- module_strings(m),
          [whole, dollars, cents] <- Regex.scan(~r/\$(\d+)\.(\d{2})/, src),
          MapSet.member?(configured, String.to_integer(dollars) * 100 + String.to_integer(cents)),
          uniq: true,
          do: {m, whole}

    for {m, amount} <- strings do
      finding(
        :r5,
        m.name,
        m.file,
        m.line,
        "#{short(m.name)} writes the amount #{amount} that is also configured as a number — change one and the label lies; build the label from the configured value (R5)"
      )
    end
  end

  defp module_strings(m) do
    lits = for {{:string, s}, _} <- m.literals, do: s
    lits ++ Enum.map(m.templates, &elem(&1, 1))
  end

  # ── Declared ports: drift and coverage ───────────────────────────────────
  def ports(model) do
    asts = Map.new(model.modules, &{&1.file, file_ast(&1.file)})

    for m <- model.modules, {ins, outs} <- [declared_ports(m)], outs != nil, reduce: [] do
      acc ->
        # a composition with parts (a Spray feature) sends its outputs with a `send_out` call;
        # its keyword lists are configuration, not outputs
        {emitted, built} =
          if composition_with_parts?(m),
            do: {sent_ports(m), sent_ports(m)},
            else: {emitted_ports(m), any_keyword_keys(m)}

        undeclared = MapSet.difference(emitted, MapSet.new(outs)) |> Enum.sort()
        silent = MapSet.new(outs) |> MapSet.difference(built) |> Enum.sort()
        wired = wired_atoms(model, m, asts)

        unwired =
          if wired == :no_composer,
            do: [],
            else: outs |> Enum.reject(&MapSet.member?(wired, &1)) |> Enum.sort()

        _ = ins

        acc ++
          for(
            p <- undeclared,
            do:
              finding(
                :ports,
                m.name,
                m.file,
                m.line,
                "#{short(m.name)} emits `#{p}` but `ports/0` doesn't declare it — the declaration has drifted from the code (R9, R8)"
              )
          ) ++
          for(
            p <- silent,
            do:
              finding(
                :ports,
                m.name,
                m.file,
                m.line,
                "#{short(m.name)} declares output `#{p}` but never emits it (R7, R9)"
              )
          ) ++
          if(wired == :no_composer or unwired == [],
            do: [],
            else: [
              finding(
                :ports_unwired,
                m.name,
                m.file,
                m.line,
                "no composer of #{short(m.name)} mentions output(s) #{Enum.map_join(unwired, ", ", &"`#{&1}`")} — possibly unwired; a coverage test should prove each is wired or deliberately ignored (R8, heuristic)"
              )
            ]
          )
    end
  end

  defp declared_ports(m) do
    case Enum.find(m.functions, &(&1.name == :ports and &1.arity == 0)) do
      %{body: {:%{}, _, kv}} -> {atoms(kv[:in]), atoms(kv[:out])}
      _ -> {nil, nil}
    end
  end

  defp atoms(list) when is_list(list), do: for({k, _} <- list, is_atom(k), do: k)
  defp atoms(_), do: nil

  # keyword lists a step returns: the second element of a `{state, [...]}` tuple,
  # or an operand of `++`
  defp emitted_ports(m) do
    for fun <- m.functions, fun.name != :ports, reduce: MapSet.new() do
      acc ->
        {_, found} =
          Macro.prewalk(fun.body, acc, fn
            {_, list} = node, a when is_list(list) -> {node, add_keys(a, list)}
            {:++, _, [l, r]} = node, a -> {node, a |> add_keys(l) |> add_keys(r)}
            node, a -> {node, a}
          end)

        found
    end
  end

  defp composition_with_parts?(m),
    do: Enum.any?(m.functions, &(&1.name == :parts and &1.arity == 0))

  defp send_out?(name), do: String.starts_with?(to_string(name), "send_out")

  # unpiped `send_out(socket, key, :port, ...)` has the port third; piped, second
  defp put_port(acc, [_, _, port | _]) when is_atom(port) and port not in [nil, true, false],
    do: MapSet.put(acc, port)

  defp put_port(acc, [_, port | _]) when is_atom(port) and port not in [nil, true, false],
    do: MapSet.put(acc, port)

  defp put_port(acc, _), do: acc

  # the port atom of every `send_out*(socket, key, :port, ...)` call, piped or not, and of every
  # `{:out, port}` binding
  defp sent_ports(m) do
    for fun <- m.functions, reduce: MapSet.new() do
      acc ->
        {_, found} =
          Macro.prewalk(fun.body, acc, fn
            {{:., _, [_, name]}, _, args} = node, a when is_atom(name) and is_list(args) ->
              {node, if(send_out?(name), do: put_port(a, args), else: a)}

            # a binding that sends the payload out of the composition: `{:out, port}`
            {:out, port} = node, a when is_atom(port) ->
              {node, MapSet.put(a, port)}

            node, a ->
              {node, a}
          end)

        found
    end
  end

  # every key of any keyword-list literal in the module (an output may be built by a helper)
  defp any_keyword_keys(m) do
    for fun <- m.functions, fun.name != :ports, reduce: MapSet.new() do
      acc ->
        {_, found} =
          Macro.prewalk(fun.body, acc, fn
            list, a when is_list(list) -> {list, add_keys(a, list)}
            node, a -> {node, a}
          end)

        found
    end
  end

  defp add_keys(acc, list) when is_list(list) do
    if list != [] and Enum.all?(list, &match?({k, _} when is_atom(k), &1)),
      do: Enum.reduce(list, acc, fn {k, _}, a -> MapSet.put(a, k) end),
      else: acc
  end

  defp add_keys(acc, _), do: acc

  # atoms a composer uses as port names: `{:feature, :port}` keys, `{:port, x}`
  # patterns, and atom lists (e.g. `@wired_here`)
  defp wired_atoms(model, feature, asts) do
    composers =
      for c <- model.modules,
          c.name != feature.name,
          Enum.any?(
            c.refs,
            &(&1 == feature.name or String.starts_with?(&1, feature.name <> "."))
          ),
          do: c

    if composers == [] do
      :no_composer
    else
      for c <- composers, ast = asts[c.file], ast != nil, reduce: MapSet.new() do
        acc ->
          {_, found} =
            Macro.prewalk(ast, acc, fn
              {a, b} = node, s when is_atom(a) and is_atom(b) ->
                {node, MapSet.put(s, b)}

              # a clause head or message `{:instance, :port, payload}`
              {:{}, _, [a, b | _]} = node, s when is_atom(a) and is_atom(b) ->
                {node, MapSet.put(s, b)}

              {a, _} = node, s when is_atom(a) ->
                {node, MapSet.put(s, a)}

              list, s when is_list(list) ->
                {list,
                 Enum.reduce(list, s, fn x, s2 ->
                   if is_atom(x), do: MapSet.put(s2, x), else: s2
                 end)}

              node, s ->
                {node, s}
            end)

          found
      end
    end
  end

  defp file_ast(file) do
    with {:ok, src} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(src, emit_warnings: false),
         do: ast,
         else: (_ -> nil)
  end

  # ── R11: page code handing data along ────────────────────────────────────
  def assigns_handoffs(model) do
    for m <- model.modules,
        composes?(model, m.name),
        fun <- m.functions,
        {line, target, fun_name} <- assign_args(model, m, fun) do
      finding(
        :r11,
        m.name,
        m.file,
        line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} reads an assign and passes it into #{short(target)}.#{fun_name} — the page is composing another abstraction's input; let a feature output carry it (R11)"
      )
    end
  end

  defp assign_args(model, m, fun) do
    {_, acc} =
      Macro.prewalk(fun.body, [], fn
        {{:., meta, [{:__aliases__, _, parts}, name]}, _, [_first | rest]} = node, acc ->
          with target when target != nil <- project_target(model, m, parts),
               true <- middle?(model, target),
               true <- Enum.any?(rest, &reads_assign?/1) do
            {node, [{meta[:line] || fun.line, target, name} | acc]}
          else
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp reads_assign?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [_, :assigns]}, _, _} = n, _ -> {n, true}
        {{:., _, [{:assigns, _, _}, _]}, _, _} = n, _ -> {n, true}
        n, f -> {n, f}
      end)

    found
  end

  @doc "Wiring values that close over a page helper (an R8 concern; report only)."
  def wiring_closures(model) do
    for m <- model.modules,
        app?(model, m.name),
        privates = MapSet.new(for f <- m.functions, f.private, do: f.name),
        fun <- m.functions,
        {line, helper} <- helper_captures(fun.body, privates, fun.line) do
      finding(
        :wiring_closure,
        m.name,
        m.file,
        line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} wires a closure over the page helper #{helper}/… — the wiring can't say what it does; name an instance or a feature input instead (R8, report only)"
      )
    end
  end

  defp helper_captures(nil, _p, _l), do: []

  defp helper_captures(body, privates, line) do
    {_, acc} =
      Macro.prewalk(body, [], fn
        {:&, meta, [{name, _, args}]} = node, acc when is_atom(name) and is_list(args) ->
          if MapSet.member?(privates, name) and Enum.any?(args, &(not capture_arg?(&1))),
            do: {node, [{meta[:line] || line, name} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp capture_arg?({:&, _, [n]}) when is_integer(n), do: true
  defp capture_arg?(_), do: false

  @doc "A private application function calling two or more bottom-layer functions: store work on the page."
  def helper_store_work(%{layers: %{index: idx, names: names}} = model) do
    bottom = length(names) - 1

    for m <- model.modules,
        composes?(model, m.name),
        fun <- m.functions,
        fun.private,
        calls = bottom_calls(model, m, fun.body, idx, bottom),
        MapSet.size(calls) >= 2 do
      shown = calls |> Enum.sort() |> Enum.take(3) |> Enum.join(", ")

      finding(
        :r11,
        m.name,
        m.file,
        fun.line,
        "#{short(m.name)}.#{fun.name}/#{fun.arity} is a page helper doing store work (#{shown}) — make it a domain abstraction configured with its stores (R11)"
      )
    end
  end

  defp bottom_calls(_model, _m, nil, _idx, _bottom), do: MapSet.new()

  defp bottom_calls(model, m, body, idx, bottom) do
    {_, acc} =
      Macro.prewalk(body, MapSet.new(), fn
        # a capture passed as a source is a reference the wiring hands on, not a call made here
        {:&, _, [{:/, _, [_, _]}]}, acc ->
          {:capture, acc}

        {{:., _, [{:__aliases__, _, parts}, name]}, _, _} = node, acc ->
          case project_target_any(model, m, parts) do
            nil ->
              {node, acc}

            t ->
              if idx[t] == bottom,
                do: {node, MapSet.put(acc, "#{short(t)}.#{name}")},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp project_target_any(model, m, parts) do
    [first | rest] = Enum.map(parts, &to_string/1)
    full = Enum.join([Map.get(m.aliases, first, first) | rest], ".")

    Enum.find(model.module_names, fn name ->
      name == full or String.ends_with?(name, "." <> full)
    end)
  end

  # ── R6: a UI abstraction doing I/O ───────────────────────────────────────
  @doc """
  A UI module below the application (a LiveComponent, or a component module) that fetches or saves:
  it calls a module that reaches the Repo or PubSub, a configured I/O abstraction, or a function on
  a module held in a variable or in assigns (an injected store or gateway). Spray wires data sources
  and sinks to a UI element that displays data (§5.2.2); a UI module doing I/O bundles a data source
  or sink into a UI abstraction (R6).
  """
  def ui_io(model) do
    io = io_modules(model)

    # a paradigm-layer host calling the module it was handed is an execution model, not I/O
    for m <- model.modules,
        middle?(model, m.name),
        ui_module?(m),
        calls = io_calls(model, m, io),
        calls != [] do
      shown = calls |> Enum.uniq() |> Enum.take(3) |> Enum.join(", ")

      finding(
        :ui_io,
        m.name,
        m.file,
        m.line,
        "#{short(m.name)} is a UI component that does I/O (#{shown}) — a UI abstraction renders data wired into it and emits events; wire the data source or sink at the page (R6, §5.2.2)"
      )
    end
  end

  # ── R11: a stateful component contained in the application ───────────────
  @doc """
  A LiveComponent in a composition layer (the application, or a Features layer): a page-specific
  component with its own state, lifecycle and event handlers, used only inside the page. Spray has
  "no analog of a sub-module or sub-component, no such thing as a sub-abstraction. Abstraction layers
  replace hierarchical containment" (§2.2). The page composes its UI from domain UI abstractions and
  wires them (§7.14); a reusable component moves to a lower layer, and the rest is the page's wiring.
  """
  def subcomponents(model) do
    for m <- model.modules,
        composes?(model, m.name),
        Enum.any?(m.uses, &String.match?(&1, ~r/(LiveComponent|:live_component)$/)) do
      finding(
        :subcomponent,
        m.name,
        m.file,
        m.line,
        "#{short(m.name)} is a LiveComponent inside the composition: a contained sub-component with its own state and handlers (§2.2, \"layers replace hierarchical containment\") — build it from a domain UI abstraction (a generic form, a list) that the page configures and wires (R11, §7.14)"
      )
    end
  end

  defp ui_module?(m),
    do:
      Enum.any?(
        m.uses,
        &String.match?(&1, ~r/(LiveComponent|Phoenix\.Component|:live_component|:html)$/)
      )

  # modules that reach storage or messaging: those referencing a Repo or PubSub, configured I/O
  # abstractions (a struct whose functions call a module they were handed), and anything that
  # calls either, transitively
  defp io_modules(model) do
    by_name = Map.new(model.modules, &{&1.name, &1})

    direct =
      for m <- model.modules,
          Enum.any?(m.refs, &String.match?(&1, ~r/(\.Repo|PubSub)$/)) or
            (m.defines_struct and Enum.any?(m.functions, &calls_on_variable?(&1.body))),
          into: MapSet.new(),
          do: m.name

    grow(direct, model.dep_graph, by_name)
  end

  defp grow(set, graph, by_name) do
    more =
      for {name, deps} <- graph,
          not MapSet.member?(set, name),
          not ui_module?(Map.get(by_name, name, %{uses: []})),
          Enum.any?(deps, &MapSet.member?(set, &1)),
          into: MapSet.new(),
          do: name

    if MapSet.size(more) == 0, do: set, else: grow(MapSet.union(set, more), graph, by_name)
  end

  defp calls_on_variable?(nil), do: false

  defp calls_on_variable?(body) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{var, _, ctx}, fun]}, meta, args} = n, acc
        when is_atom(var) and is_atom(ctx) and is_atom(fun) and is_list(args) ->
          {n, acc or not field_read?(meta)}

        n, acc ->
          {n, acc}
      end)

    found
  end

  defp io_calls(model, m, io) do
    for fun <- m.functions, reduce: [] do
      acc ->
        {_, found} =
          Macro.prewalk(fun.body, acc, fn
            {{:., _, [{:__aliases__, _, parts}, name]}, _, _} = n, a ->
              case project_target_any(model, m, parts) do
                nil -> {n, a}
                t -> if MapSet.member?(io, t), do: {n, a ++ ["#{short(t)}.#{name}"]}, else: {n, a}
              end

            {{:., _, [{var, _, ctx}, name]}, meta, args} = n, a
            when is_atom(var) and is_atom(ctx) and is_atom(name) and is_list(args) ->
              if field_read?(meta), do: {n, a}, else: {n, a ++ ["#{var}.#{name}"]}

            {{:., _, [{{:., _, [_, field]}, _, []}, name]}, meta, args} = n, a
            when is_atom(field) and is_atom(name) and is_list(args) and field not in [:assigns] ->
              if field_read?(meta), do: {n, a}, else: {n, a ++ ["#{field}.#{name}"]}

            n, a ->
              {n, a}
          end)

        found
    end
  end

  # `x.y` without parentheses reads a field; `x.y()` calls a function
  defp field_read?(meta), do: Keyword.get(meta, :no_parens, false)

  # ── Report only: hops and vocabulary ─────────────────────────────────────
  def hops(model) do
    for m <- model.modules,
        app?(model, m.name),
        Enum.any?(m.functions, &(&1.name == :handle_info)),
        Enum.any?(m.templates, fn {_, t} -> String.contains?(t, "<.live_component") end) do
      finding(
        :hops,
        m.name,
        m.file,
        m.line,
        "#{short(m.name)} places LiveComponents and receives messages: a cross-component effect relayed here takes one message hop (component → page → component) (report only)"
      )
    end
  end

  def vocabulary(%{layers: %{index: idx, names: names}} = model) do
    bottom = length(names) - 1

    for m <- model.modules,
        idx[m.name] == bottom,
        {{name, arity}, kinds} <- [largest_dispatch(m)],
        length(kinds) >= 5 do
      finding(
        :vocabulary,
        m.name,
        m.file,
        m.line,
        "#{short(m.name)}.#{name}/#{arity} dispatches on #{length(kinds)} kinds (#{kinds |> Enum.take(6) |> Enum.join(", ")}…) — the wiring vocabulary a reader learns (report only)"
      )
    end
  end

  defp largest_dispatch(m) do
    m.functions
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Enum.map(fn {key, clauses} -> {key, clauses |> Enum.flat_map(&tags/1) |> Enum.uniq()} end)
    |> Enum.max_by(fn {_, kinds} -> length(kinds) end, fn -> {{nil, 0}, []} end)
  end

  defp tags(%{params: [first | _]}) do
    case first do
      {:{}, _, [tag | _]} when is_atom(tag) -> [tag]
      {tag, _} when is_atom(tag) -> [tag]
      tag when is_atom(tag) and tag not in [nil, true, false] -> [tag]
      _ -> []
    end
  end

  defp tags(_), do: []

  # ── helpers ──────────────────────────────────────────────────────────────
  defp app?(%{layers: %{index: idx, app_layers: app}}, name),
    do: (i = idx[name]) != nil and MapSet.member?(app, i)

  defp bottom?(%{layers: %{index: idx, names: names}}, name), do: idx[name] == length(names) - 1

  # a feature or domain module: in a known layer, neither the application nor the bottom
  defp middle?(model, name),
    do:
      model.layers.index[name] != nil and not composes?(model, name) and not bottom?(model, name)

  defp lower?(model, name), do: model.layers.index[name] != nil and not composes?(model, name)

  # the application, or a Features layer of Spray's kind: both hold only instances, configuration and wiring
  defp composes?(%{layers: %{index: idx, app_layers: app} = layers}, name),
    do: (i = idx[name]) != nil and MapSet.member?(Map.get(layers, :composition_layers, app), i)

  defp finding(rule, module, file, line, message) do
    %Finding{
      rule: rule,
      module: module,
      file: file,
      line: line || 0,
      weight: Map.get(Rules.weights(), rule, 1),
      severity: Rules.default_severity(rule),
      message: message
    }
  end

  defp short(name), do: name |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
end
