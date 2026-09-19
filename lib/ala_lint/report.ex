defmodule AlaLint.Report do
  @moduledoc """
  Turns findings + model size into a score and a human-readable report.

  ## The metric

  Each rule carries a severity weight (coupling core R1/R2/R5 = 3; state R4 = 2;
  design smells R3/R6/R7 = 1). The headline density is **weighted violations per
  100 functions** — functions, not lines, because the checklist is about how
  *abstractions* relate:

      W        = Σ weight(rule) × count(rule)
      density  = W / functions × 100          # weighted violations per 100 functions
      per_kloc = W / loc × 1000               # weighted violations per 1000 LOC (secondary)
      score    = clamp(100 − density, 0, 100) # 0–100, higher is better

  Grades: A ≥ 90, B ≥ 75, C ≥ 60, D ≥ 40, else F. The score is a *design health*
  index, not a proof — R8 (readability) is unscored by design, so a high score is
  necessary but not sufficient (see the ALA Checklist).
  """

  alias AlaLint.Rules

  def build(model, findings) do
    enforce = Map.get(model, :enforce, [])
    {scored, advisory} = Enum.split_with(findings, &scored?(&1, enforce))

    by_rule = Enum.frequencies_by(findings, & &1.rule)
    weighted = Enum.reduce(scored, 0, fn fnd, acc -> acc + fnd.weight end)
    funcs = max(model.function_total, 1)
    loc = max(model.loc_total, 1)
    density = weighted / funcs * 100
    score = round(max(0, min(100, 100 - density)))

    # Breadth metric: distinct *functions* with ≥1 violation (bounded, so it
    # can't be inflated by one function accruing many findings — the fix for
    # the density metric's multi-counting). Findings that belong to no
    # function (R1 cycles, R5 duplicated literals — module-level) are counted
    # separately, not folded into the function rate.
    {offenders, module_level} = attribute(model, scored)
    fdr = MapSet.size(offenders) / funcs * 100
    breadth_score = round(max(0, min(100, 100 - fdr)))

    %{
      findings: findings,
      scored_findings: scored,
      advisory_findings: advisory,
      by_rule: by_rule,
      height: Rules.height_value(model),
      layer_coverage: layer_coverage(model),
      layer_dirs: layer_dir_cohesion(model),
      params: Map.get(model, :params, %{}),
      functions: model.function_total,
      loc: model.loc_total,
      modules: length(model.modules),
      weighted: weighted,
      per_100_functions: Float.round(density, 2),
      per_1000_loc: Float.round(weighted / loc * 1000, 2),
      score: score,
      grade: grade(score),
      # breadth metric = "count of compliant functions" view
      offending_functions: MapSet.size(offenders),
      compliant_functions: funcs - MapSet.size(offenders),
      module_level_findings: module_level,
      functions_with_violation_per_100: Float.round(fdr, 2),
      breadth_score: breadth_score,
      breadth_grade: grade(breadth_score)
    }
  end

  # Map each finding to the function whose def-line is the greatest ≤ the
  # finding's line, within the finding's module. Findings that land above the
  # first def (module-level: R1/R5) attribute to no function.
  defp attribute(model, findings) do
    by_mod = Map.new(model.modules, &{&1.name, &1.functions})

    Enum.reduce(findings, {MapSet.new(), 0}, fn f, {set, modlvl} ->
      case owner_fun(Map.get(by_mod, f.module, []), f.line) do
        nil -> {set, modlvl + 1}
        fun -> {MapSet.put(set, {f.module, fun.name, fun.arity, fun.line}), modlvl}
      end
    end)
  end

  defp owner_fun(functions, line) do
    functions
    |> Enum.filter(&(&1.line <= line))
    |> Enum.max_by(& &1.line, fn -> nil end)
  end

  # A finding counts toward the score if it is an error, or if its rule is
  # explicitly enforced (promoting an advisory rule like R7 to a hard failure).
  defp scored?(%{severity: :error}, _enforce), do: true
  defp scored?(%{rule: rule}, enforce), do: rule in enforce

  # Migration metric: how much of the codebase is assigned to a layer. Only
  # meaningful with a layer map; nil otherwise. `unassigned` is the worklist.
  defp layer_coverage(%{layers: %{fun_index: fi}}) do
    total = map_size(fi)

    {assigned, unassigned} =
      Enum.reduce(fi, {0, []}, fn
        {id, nil}, {a, u} -> {a, [id | u]}
        {_id, _idx}, {a, u} -> {a + 1, u}
      end)

    %{total: total, assigned: assigned, unassigned: Enum.reverse(unassigned), pct: if(total > 0, do: round(assigned / total * 100), else: 100)}
  end

  defp layer_coverage(_), do: nil

  # Advisory: Spray recommends filesystem directories separate layers, so a
  # cohesive layer's functions should sit under one root dir. Per assigned
  # layer we report the dominant directory and the share of the layer's
  # functions under it (100% = perfectly cohesive; lower = scattered).
  defp layer_dir_cohesion(%{layers: %{fun_index: fi, names: names}, root: root} = model) do
    file_of = for m <- model.modules, f <- m.functions, into: %{}, do: {{m.name, f.name, f.arity}, f.file}

    fi
    |> Enum.reduce(%{}, fn
      {_id, nil}, acc -> acc
      {id, idx}, acc -> Map.update(acc, idx, [dir_of(file_of[id], root)], &[dir_of(file_of[id], root) | &1])
    end)
    |> Enum.sort()
    |> Enum.map(fn {idx, dirs} ->
      freq = Enum.frequencies(dirs)
      {dom, n} = Enum.max_by(freq, fn {_d, c} -> c end)
      %{layer: Enum.at(names, idx), dominant: dom, share: round(n / length(dirs) * 100), dirs: map_size(freq)}
    end)
  end

  defp layer_dir_cohesion(_), do: nil

  defp dir_of(nil, _root), do: "?"
  defp dir_of(file, root), do: file |> Path.dirname() |> Path.relative_to(root)

  defp grade(s) when s >= 90, do: "A"
  defp grade(s) when s >= 75, do: "B"
  defp grade(s) when s >= 60, do: "C"
  defp grade(s) when s >= 40, do: "D"
  defp grade(_), do: "F"

  @rule_names %{
    r1: "R1 peer coupling / cycles",
    r2: "R2 shared mutable state",
    r3: "R3 misplaced application literal",
    r4: "R4 hidden state",
    r5: "R5 duplicated contracts",
    r6: "R6 nameability",
    r7: "R7 unearned abstractions",
    r10: "R10 shared entity"
  }

  def to_text(report, opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)

    max_h = Map.get(report.params, :max_height, 5)
    height_note = if report.height > max_h, do: "  ⚠ exceeds max #{max_h}", else: "  (max #{max_h})"

    header = """
    ── ALA Checklist (R1–R11) ─────────────────────────────────────────────
    modules: #{report.modules}   functions: #{report.functions}   LOC: #{report.loc}
    abstraction height: #{report.height} call-levels (function graph)#{height_note}
    #{coverage_line(report.layer_coverage)}
    #{cohesion_lines(report.layer_dirs)}

    Degree of function compliance: #{report.score}/100  (grade #{report.grade})
      — 100 minus the weighted-violation load; counts findings (severity-weighted),
        so it can be dragged down by a few dense or data-heavy modules.
      weighted violations: #{report.weighted}
      violation load per 100 functions: #{report.per_100_functions}  (can exceed 100 — multi-counts)
      per 1000 LOC:        #{report.per_1000_loc}

    Count of compliant functions: #{report.compliant_functions} / #{report.functions}  (#{report.breadth_score}% → grade #{report.breadth_grade})
      — functions with zero violations; each function counted once (bounded, not draggable).
      functions with ≥1 violation: #{report.offending_functions} (#{report.functions_with_violation_per_100} per 100)
      module-level findings (R1/R5/attrs, no owning function): #{report.module_level_findings}

    By rule (weight):
    #{rule_lines(report)}
    """

    scored = format_findings(report.scored_findings, limit)
    scored_more = more_line(report.scored_findings, limit)

    advisory = format_findings(report.advisory_findings, limit)

    header <>
      "\nFindings (scored, most severe first):\n" <>
      (if scored == "", do: "  none 🎉", else: scored) <>
      scored_more <>
      "\n\nAdvisory (reported, NOT scored — R7 reuse/minimality, abstraction height):\n" <>
      (if advisory == "", do: "  none", else: advisory) <>
      "\n  promote any of these to a hard failure with --enforce <rule> (e.g. --enforce r7).\n" <>
      params_section(report.params) <>
      "\nR8 (readability: names, config clarity, composition-reads-as-spec) is judgement, not\n" <>
      "checked here — a high score is necessary but not sufficient. See the ALA Checklist.\n"
  end

  defp format_findings(findings, limit) do
    findings
    |> Enum.sort_by(&{-&1.weight, &1.rule, &1.file, &1.line})
    |> Enum.take(limit)
    |> Enum.map_join("\n", fn f -> "  [#{f.rule}] #{rel(f.file)}:#{f.line}  #{f.message}" end)
  end

  defp more_line(findings, limit) do
    case length(findings) - limit do
      n when n > 0 -> "\n  … and #{n} more (raise --limit to see them)"
      _ -> ""
    end
  end

  # Echo every effective parameter (default or override) so a run is reproducible
  # and the reader knows exactly what was and wasn't checked.
  defp params_section(params) when params == %{}, do: ""

  defp params_section(params) do
    w = params[:weights] || %{}
    weights = w |> Enum.sort() |> Enum.map_join(" ", fn {r, v} -> "#{r}=#{v}" end)
    enforce = case params[:enforce] do
      [] -> "(none — advisory checks reported only)"
      list -> Enum.join(list, ",")
    end

    # Be honest about what a score excluded: a run that disabled or downgraded
    # checks (via .ala_lint.exs or --disable) is not scoring the full checklist.
    integrity =
      [
        line_if("disabled (NOT scored):", params[:disabled]),
        line_if("downgraded to advisory:", params[:soft])
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join()

    """

    Parameters (effective — defaults unless overridden):
      root:           #{params[:root]}
      max_height:     #{params[:max_height]}   max_module_loc: #{params[:max_module_loc]}   max_public_funs: #{params[:max_public_funs]}   app_share: #{params[:max_app_share]}
      enforce:        #{enforce}#{integrity}
      layers:         #{params[:layers]}
      config_modules: #{fmt_list(params[:config_modules])}
      exclude:        #{fmt_list(params[:exclude])}
      weights:        #{weights}
      fixed heuristics (not configurable): R5 identifier-string length 3–40, R7 flags only dead + trivial-meaningless single-use privates
    """
  end

  defp line_if(_label, nil), do: ""
  defp line_if(_label, []), do: ""
  defp line_if(label, list), do: "\n      #{label} #{Enum.join(list, ",")}"

  defp fmt_list(nil), do: "(none)"
  defp fmt_list([]), do: "(none)"
  defp fmt_list(list), do: Enum.join(list, ", ")

  defp cohesion_lines(nil), do: ""
  defp cohesion_lines([]), do: ""

  defp cohesion_lines(rows) do
    body =
      Enum.map_join(rows, "\n", fn %{layer: l, dominant: d, share: s, dirs: n} ->
        note = if s == 100, do: "cohesive", else: "scattered across #{n} dirs"
        "  #{String.pad_trailing(to_string(l), 10)} #{s}% under `#{d}` (#{note})"
      end)

    "filesystem cohesion (advisory — Spray: dirs separate layers):\n" <> body
  end

  defp coverage_line(nil), do: "layer coverage: (no layer map — run with one to assign functions to layers)"

  defp coverage_line(%{assigned: a, total: t, pct: pct, unassigned: un}) do
    tail =
      case un do
        [] -> ""
        _ ->
          shown = un |> Enum.take(8) |> Enum.map_join(", ", fn {m, n, ar} -> "#{m}.#{n}/#{ar}" end)
          extra = if length(un) > 8, do: " … +#{length(un) - 8} more", else: ""
          "\n  unassigned (worklist): #{shown}#{extra}"
      end

    "layer coverage: #{a}/#{t} functions assigned (#{pct}%)#{tail}"
  end

  defp rule_lines(report) do
    for {rule, name} <- @rule_names do
      c = Map.get(report.by_rule, rule, 0)
      w = Rules.weights()[rule]
      "  #{String.pad_trailing(name, 26)} #{String.pad_leading(to_string(c), 4)}  (×#{w})"
    end
    |> Enum.join("\n")
  end

  defp rel(nil), do: "?"
  defp rel(path), do: Path.relative_to_cwd(path)
end
