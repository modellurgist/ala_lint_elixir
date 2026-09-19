defmodule AlaLint.EncodingLinter do
  @moduledoc """
  Lint a tree of **encoded** files (the `.ala.md` notation produced by
  `AlaLint.Encoder` and completed by a human) rather than source code. It
  reads what the notation *carries* — module `[tag]`s, `f` lines, dependency
  edges with their altitude annotation, `$` hidden-state marks, `q` silent
  contracts, and `{app-literal?}`/`{app-literal}`/`{intrinsic-literal}` literal judgements — and
  reports the checklist violations visible at that level.

  This is a narrower check than `AlaLint.analyze/2` on source. R6 (nameability)
  and R7 (earns-existence) are not expressible in the encoding, so they are not
  scored here. R3 is *partially* expressible: the encoder seeds `{app-literal?}` on
  each function that owns an application-literal candidate (value opaque; the
  source scan has its file:line), a human resolves it to `{app-literal}` (an
  application literal — hoist to the top if it isn't there) or `{intrinsic-literal}`
  (intrinsic to the abstraction, kept local), and this linter reports unresolved
  `{app-literal?}` as incomplete and each `{app-literal}` as an R3 item to place at
  the composition. R1 (does every edge drop?), R4 (`$`) and R5 (`q`) are pinned
  down as before.

  The encoder also stamps facts it can decide from the source into the notation,
  so a completed encoding re-lints close to the source: `&entity`/`&aggregate`
  (R10 / R10-aggregate shared-entity modules), `~>` (pass-throughs), `(branches)`
  (application-layer functions that branch — R11), and `(private)` on each private
  `f` (so public-surface counts and pass-through scoping work here too). Height is
  reproduced only *approximately*: the encoding carries module-level edges, not the
  function call-graph in-degrees the source height uses, so it is a module-graph
  chain-depth proxy, flagged as such.
  """

  alias AlaLint.Finding

  @max_public_funs 12
  @max_height 5
  @max_app_share 0.20

  @doc "Lint every `*.ala.md` under `root`. Returns a report map (see `to_text/2`)."
  def lint(root) do
    files = Path.wildcard(Path.join(root, "**/*.ala.md"))
    parsed = Enum.flat_map(files, &parse_file/1)

    findings = Enum.flat_map(parsed, &findings_for/1) ++ height_findings(parsed) ++ app_share_findings(parsed)
    incomplete = Enum.flat_map(parsed, &incomplete_for/1)

    %{
      root: root,
      files: length(files),
      modules: length(parsed),
      functions: parsed |> Enum.map(& &1.function_count) |> Enum.sum(),
      findings: findings,
      incomplete: incomplete,
      by_rule: Enum.frequencies_by(findings, & &1.rule)
    }
  end

  defp parse_file(file) do
    lines = file |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    {mods, cur} =
      Enum.reduce(lines, {[], nil}, fn {line, n}, {mods, cur} ->
        cond do
          m = Regex.run(~r/^module\s+(\S+)\s+\[([^\]]*)\]/, line) ->
            [_, name, tag] = m
            {maybe_push(mods, cur), %{name: name, tag: tag, level: level_in(line), entity: entity_in(line), file: file, line: n, function_count: 0, public_funs: 0, edges: [], states: [], contracts: [], configs: [], passthroughs: [], branches: []}}

          cur == nil ->
            {mods, cur}

          fm = Regex.run(~r/^\s+f\s+(\S+\/\d+)/, line) ->
            [_, fname] = fm
            kind = config_kind(line)
            configs = if kind, do: [{n, fname, kind} | cur.configs], else: cur.configs
            passthroughs = if line =~ "~>", do: [{n, fname} | cur.passthroughs], else: cur.passthroughs
            branches = if line =~ "(branches)", do: [{n, fname} | cur.branches], else: cur.branches
            public_funs = cur.public_funs + if line =~ "(private)", do: 0, else: 1
            {mods, %{cur | function_count: cur.function_count + 1, public_funs: public_funs, configs: configs, passthroughs: passthroughs, branches: branches}}

          # `rest` is the tier token (`[tag]` or `@name-Lidx`) plus the drop/verify
          # note. Findings key off the note, so this tolerates both forms.
          e = Regex.run(~r/^\s*(?:→|->)\s+(\S+)\s+(.*)$/, line) ->
            [_, dep, rest] = e
            {mods, %{cur | edges: [%{dep: dep, note: rest, line: n} | cur.edges]}}

          Regex.match?(~r/^\s+\$\s/, line) ->
            {mods, %{cur | states: [n | cur.states]}}

          Regex.match?(~r/^\s+q\s/, line) ->
            {mods, %{cur | contracts: [{n, line} | cur.contracts]}}

          true ->
            {mods, cur}
        end
      end)

    Enum.reverse(maybe_push(mods, cur))
  end

  defp maybe_push(mods, nil), do: mods
  defp maybe_push(mods, cur), do: [cur | mods]

  # A resolved `{intrinsic-literal}` beats `{app-literal}` beats the unresolved `{app-literal?}`.
  defp config_kind(line) do
    cond do
      line =~ "{intrinsic-literal}" -> :essential
      line =~ "{app-literal?}" -> :candidate
      line =~ "{app-literal}" -> :config
      true -> nil
    end
  end

  # The `@name-Lidx` level token on a line, if any.
  defp level_in(line) do
    case Regex.run(~r/@(\S+)/, line) do
      [_, level] -> level
      _ -> nil
    end
  end

  defp entity_in(line) do
    cond do
      line =~ "&aggregate" -> :aggregate
      line =~ "&entity" -> :entity
      true -> :none
    end
  end

  defp findings_for(m) do
    edge_findings =
      for e <- m.edges, rule = edge_rule(e.note), rule != nil do
        finding(rule, edge_message(rule, e), m, e.line)
      end

    state_findings =
      for line <- m.states, do: finding(:r4, "hidden state `$` declared — confirm it is a real hidden channel, not legit instance state (R4)", m, line)

    contract_findings =
      for {line, _txt} <- m.contracts, do: finding(:r5, "silent contract `q` declared — confirm it should be single-sourced (R5)", m, line)

    # `{app-literal}` = a reviewer asserted this literal is an application literal.
    # Application literals are allowed in the top/config tier (level 0) and flagged
    # anywhere below it (hoist to the composition) — the same rule source R3 uses.
    # When the level is unassigned we can't tell, so we report it to verify.
    config_findings =
      for {line, fname, :config} <- m.configs, layer_index(m.level) != 0 do
        where = if m.level, do: " (level #{m.level}, below the composition)", else: ""
        finding(:r3, "#{fname} [#{m.tag}] asserts {app-literal}#{where} — an application literal belongs at the composition/top; hoist it (R3)", m, line)
      end

    entity_findings =
      case m.entity do
        :aggregate -> [finding(:r10_aggregate, "module #{m.name} shares a domain entity across too many peers — pull the shared type down or narrow it (R10 aggregate)", m, m.line)]
        :entity -> [finding(:r10, "module #{m.name} shares a domain entity/struct with a peer — a common entity couples them; give each its own view or push it down (R10)", m, m.line)]
        :none -> []
      end

    passthrough_findings =
      for {line, fname} <- m.passthroughs do
        finding(:passthrough, "#{fname} is a pass-through (`~>`, 1 caller → 1 cross-module callee); it renames a call without hiding a decision — consider inlining (R7-adjacent)", m, line)
      end

    branch_findings =
      for {line, fname} <- m.branches do
        finding(:r11, "#{fname} is an application-layer function that branches (`(branches)`) — the top should compose, not decide; push the choice down (R11)", m, line)
      end

    surface_findings =
      if m.public_funs > @max_public_funs,
        do: [finding(:public_surface, "module #{m.name} exposes #{m.public_funs} public functions (> #{@max_public_funs}) — a wide surface is hard to depend on; consider splitting or privatising (advisory)", m, m.line)],
        else: []

    edge_findings ++ state_findings ++ contract_findings ++ config_findings ++
      entity_findings ++ passthrough_findings ++ branch_findings ++ surface_findings
  end

  # Module-graph chain depth as an approximate height proxy. The source height
  # walks the function call-graph with in-degree/collapse rules the encoding does
  # not carry, so this counts cross-module hops over project edges only and is
  # flagged advisory-approximate.
  defp height_findings(parsed) do
    known = MapSet.new(parsed, & &1.name)
    graph = Map.new(parsed, fn m -> {m.name, m.edges |> Enum.map(& &1.dep) |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.uniq()} end)

    for m <- parsed, d = longest_chain(m.name, graph, MapSet.new()), d > @max_height do
      finding(:height, "module #{m.name} sits atop a dependency chain #{d} deep (> #{@max_height}) — collapse intra-module private chains or flatten (advisory, approximate at module granularity)", m, m.line)
    end
  end

  # R11 aggregate: the application layer should be mostly wiring, not a large
  # share of the codebase's functions. The encoding carries each module's level
  # index (`@name-Lidx`); index 0 is the application/composition tier by the
  # default convention. When a project declares `app: true` on other tiers, this
  # under-counts — approximate, like height.
  defp app_share_findings(parsed) do
    total = parsed |> Enum.map(& &1.function_count) |> Enum.sum()
    app = parsed |> Enum.filter(&(layer_index(&1.level) == 0)) |> Enum.map(& &1.function_count) |> Enum.sum()

    if total > 0 and app / total > @max_app_share do
      pct = round(app / total * 100)
      [%Finding{rule: :r11, message: "the application layer is #{pct}% of functions (> #{round(@max_app_share * 100)}%) — the top should be mostly wiring + config, not logic (R11 aggregate, approximate: assumes level 0 is the app tier)", module: "(project)", file: nil, line: 0, weight: weight(:r11)}]
    else
      []
    end
  end

  defp layer_index(nil), do: nil
  defp layer_index(level) do
    case Regex.run(~r/-L(\d+)$/, level) do
      [_, i] -> String.to_integer(i)
      _ -> nil
    end
  end

  defp longest_chain(node, graph, seen) do
    if MapSet.member?(seen, node) do
      0
    else
      seen = MapSet.put(seen, node)

      case Map.get(graph, node, []) do
        [] -> 0
        deps -> 1 + Enum.max(Enum.map(deps, &longest_chain(&1, graph, seen)))
      end
    end
  end

  defp edge_rule(note) do
    cond do
      note =~ "UP" -> :r1
      note =~ "PEER" -> :r1
      true -> nil
    end
  end

  defp edge_message(:r1, %{note: note} = e) do
    kind = if note =~ "UP", do: "upward edge (knowledge flows up)", else: "cross-peer edge (feature↔feature)"
    "#{kind} → #{e.dep} (R1, from the encoding)"
  end

  defp incomplete_for(m) do
    tag =
      if m.tag in ["?", ""],
        do: [{m.line, "module #{m.name} has an unresolved [?] semantic tag — state what it knows (layer #{m.level || "unassigned"})"}],
        else: []

    edges =
      for e <- m.edges, e.note =~ "verify" or e.note =~ "[?]" do
        {e.line, "edge → #{e.dep} not resolved (\"#{String.trim(e.note)}\") — confirm it drops"}
      end

    configs =
      for {line, fname, :candidate} <- m.configs do
        {line, "#{fname} has {app-literal?} — resolve to {app-literal} (application literal, belongs at the top) or {intrinsic-literal} (intrinsic to the abstraction, kept local)"}
      end

    Enum.map(tag ++ edges ++ configs, fn {line, msg} -> %{module: m.name, file: m.file, line: line, message: msg} end)
  end

  defp finding(rule, message, m, line) do
    %Finding{rule: rule, message: message, module: m.name, file: m.file, line: line, weight: weight(rule)}
  end

  defp weight(rule), do: Map.get(AlaLint.Rules.weights(), rule, 1)

  @doc "Human-readable report."
  def to_text(report, opts \\ []) do
    limit = Keyword.get(opts, :limit, 60)

    header =
      "ALA encoding lint — #{report.modules} modules, #{report.functions} functions across #{report.files} files\n" <>
        "(checks what the notation carries: R1 edge altitude, R4 $, R5 q, R3 {app-literal}, R10 &entity/&aggregate, R11 (branches), pass-through ~>, public surface, approx height. R6/R7 are not encodable.)\n"

    violations =
      report.findings
      |> Enum.sort_by(& &1.line)
      |> Enum.take(limit)
      |> Enum.map_join("\n", fn f -> "  #{f.file}:#{f.line}  [#{f.rule}] #{f.message}" end)

    incomplete =
      report.incomplete
      |> Enum.take(limit)
      |> Enum.map_join("\n", fn i -> "  #{i.file}:#{i.line}  #{i.message}" end)

    counts = report.by_rule |> Enum.sort() |> Enum.map_join(", ", fn {r, c} -> "#{r}=#{c}" end)

    """
    #{header}
    Violations (#{length(report.findings)}#{if counts == "", do: "", else: " — " <> counts}):
    #{if violations == "", do: "  (none)", else: violations}

    Incomplete — a human must resolve (#{length(report.incomplete)}):
    #{if incomplete == "", do: "  (none — every tag and edge is resolved)", else: incomplete}
    """
  end
end
