defmodule AlaLint.Explain do
  @moduledoc """
  The guide `mix ala.lint --explain` prints: for the run its settings describe, what is scored,
  what is only reported, and what still applies that no check reads. Rule wording follows
  `ala_checklist_elixir.md`; the light-ALA conventions follow
  `ala_variants_elixir/v59-light-ala/DESIGN.md`. No code is read.
  """

  alias AlaLint.Report

  # {name, statement, what a reader still judges}, from the checklist's rules and its
  # "What a linter can and cannot check"
  @rules [
    r1:
      {"Edges drop",
       "every edge between abstractions drops to a lower layer, a knowledge dependency only on something significantly more abstract (§2.1.3).",
       "whether the declared layers are the right ones, and whether a same-layer call is cohesion or disguised peer coupling."},
    r2:
      {"Wires meet only at the top",
       "peers share no mutable state and no meaning of data; what they share is wired from above (§3.8).",
       "whether a shared store is a peer back-channel or one owner's cache."},
    r3:
      {"Application literals at the composition",
       "product-specific constants (thresholds, prices, labels, formats) live in the composition or a manifest it owns (§1.6.3, §2.4).",
       "whether a literal or a word is the application's (hoist it) or intrinsic to its abstraction (keep it)."},
    r4:
      {"State with its owner",
       "state belongs with the abstraction whose concept it is, never kept or read raw by the app or a peer (§3.9, §3.11.2).",
       "whether a process's state is its abstraction's own concept or a hidden cross-call channel."},
    r5:
      {"No silent contracts",
       "no two modules know the meaning of data or a message, so no contract exists only as two matching literals (§7.8, §7.25).",
       "contracts no syntax tree shows, such as a cross-language constant or two ends agreeing through different literals."},
    r6:
      {"Nameability",
       "every abstraction names a learnable concept that separates the knowledge of different worlds (§2.1.1, §7.2.5).",
       "whether a name denotes a learnable concept; the checks see only opaque names, primitive wrappers and carried parameters."},
    r7:
      {"Earns its existence",
       "a separate abstraction is significantly more general than its caller and worth naming; prefer few meaningful abstractions to many trivial ones (§2.1.1).",
       "whether an abstraction hides a decision worth naming or is premature extraction; reuse is evidence, not the requirement."},
    r8:
      {"Reads as the requirements",
       "the composition reads like the spec, and names, configuration and shapes serve the reader (§2.4).",
       "no check reads it; a linter can prompt R8, never score it."},
    r9:
      {"Ports by paradigm",
       "ports are typed by a programming paradigm, and an abstraction owns no interface except its own configuration (§2.3.4).",
       "whether an output reads as a fact or names its destination, and whether a struct on a port is a peer's DTO."},
    r10:
      {"No shared entity", "no two features know the meaning of the same data (§3.8, §7.8).",
       "whether a shared struct is shared meaning or a legitimate domain abstraction, and whether a record that outlives its source kept the identity keys it needs."},
    r11:
      {"Composition only",
       "the composition layers instantiate, configure and connect, with \"no normal programming language code such as assignments and if statements\" (§3.5).",
       "whether a flagged form is one of the forced LiveView departures, and whether a layer's name matches what it holds."}
  ]

  # display order; {name} fills in the run's threshold
  @checks [
    r1: "an upward or cross-peer call; without a layer map, a module cycle",
    layer: "an @ala_layer tag naming an undeclared layer",
    r1_ref: "a peer or upward edge seen only as an alias (often a ~H template)",
    subscribe: "a module outside the application subscribing to a topic it fixes",
    r2: "use of :ets, :persistent_term or Agent, a possible peer back-channel",
    r3: "numbers and product words below the composition, lower templates included",
    r4: "the process dictionary (Process.put/get)",
    r5: "an identifier string in two modules, or a name one fires and another matches",
    r6: "meaningless names, and functions that only wrap a primitive",
    tramp: "a parameter a public function never reads, only carries two hops down",
    ui_io: "a UI component below the composition that loads or saves",
    r7: "a dead private function, or a trivial single-use one with a meaningless name",
    module_size: "a module over {max_module_loc} lines",
    passthrough: "a public function that only delegates to another module's function",
    height: "a chain of hops between abstractions longer than {max_height}",
    clone: "the same logic in two modules, names and literals aside ({min_clone_size}+ nodes)",
    clone_inside: "the same logic twice inside one module",
    public_surface:
      "a module whose public ports are an outlier in its layer (floor {max_public_funs}, k {public_surface_iqr})",
    r9: "a @callback or protocol implemented by a peer or by a lower layer",
    ports: "a ports/0 declaration drifting from the outputs the module builds",
    r10: "a struct read by two units of its own peer-forbidden layer",
    r10_aggregate: "a lower-layer struct read by two units of a layer above it (§6.17.2)",
    r11: "branches, arithmetic, loops, handled data in a composition layer or template",
    subcomponent: "a LiveComponent inside a composition layer (a contained sub-component)",
    builder_literals:
      "a guarded struct built outside its builders; a positional builder (rule 11)",
    stale_session_write:
      "a LiveView writing session data from events with no guard at mount (rule 12)",
    unassigned: "a module matching no layer, which the layer-aware checks skip",
    module_avg: "files averaging under {min_avg_module_loc} lines",
    app_share: "the application layer's share of all functions, above {max_app_share}",
    r11_share: "the share of application functions holding logic (R11, uncapped)",
    hops: "a page relaying between LiveComponents (R11)",
    ports_unwired: "a declared output no composer names (an R8 prompt)",
    ports_computed: "a run-time emit kind, leaving declared outputs unchecked (R9)",
    wiring_closure: "a private page helper's closure in the wiring (an R8 prompt)",
    vocabulary: "a bottom-layer function dispatching on five or more kinds (an R8 prompt)"
  ]

  @light_rules [
    {5,
     "configuration and session values pass once, as one struct each; a new input is a new field, not a new parameter.",
     nil},
    {6, "a rule grows by a field or a function, never by a reshaped return.", nil},
    {8, "a value the domain needs is an enforced key, not a default.", nil},
    {9,
     "a guard lives in the context function that writes the data and refuses with a tagged error.",
     nil},
    {10, "each page builds its parts in one composition root (parts/…) called from mount.", nil},
    {11,
     "every builder of a config or context struct takes its required values plus keyword overrides, and tests build only through builders.",
     :builder_literals},
    {12,
     "a write to session-scoped data sees current data: the page checks before each event, and every writer refuses a closed record.",
     :stale_session_write}
  ]

  @width 100

  def describes?(check), do: Keyword.has_key?(@checks, check)

  @doc "The guide for a run with these `AlaLint.analyze/2` opts."
  def to_text(opts \\ []) do
    run = AlaLint.resolve(opts)
    levels = AlaLint.levels(opts)

    not_adopted =
      for {rule, _} <- @rules,
          checks = for(c <- AlaLint.Rules.checks(), Report.checklist_rule(c) == rule, do: c),
          checks != [],
          Enum.all?(checks, &(&1 in run.disabled)),
          do: rule

    listed = fn level ->
      for {check, _} <- @checks,
          levels[check] == level,
          (Report.checklist_rule(check) || :general) not in not_adopted,
          do: {Report.checklist_rule(check) || :general, check}
    end

    {scored, stated} = checks_section(listed.(:scored), run, MapSet.new())
    {reported, stated} = checks_section(listed.(:advisory), run, stated)

    judged =
      for {rule, {name, statement, judgement}} <- @rules, rule not in not_adopted do
        if MapSet.member?(stated, rule),
          do: wrap("  #{label(rule)}#{name}: #{judgement}", 6),
          else:
            wrap("  #{label(rule)}#{name}: #{statement}", 6) <>
              "\n" <> wrap("      #{sentence(judgement)}", 6)
      end

    Enum.join(
      [
        "ala_lint --explain: what this run scores, what it only reports, and what is left to a reader",
        header(run, opts),
        "",
        "SCORED IN THIS RUN",
        scored,
        "",
        "REPORTED, NOT SCORED",
        reported,
        "",
        "APPLIES, BUT NOT MACHINE-CHECKED",
        Enum.join(judged ++ light_lines(run, levels), "\n"),
        "",
        "Not adopted in this run: " <>
          if(not_adopted == [], do: "none", else: Enum.map_join(not_adopted, ", ", &upcase/1))
      ],
      "\n"
    )
  end

  defp header(run, opts) do
    tier = %{normal: "default", strict: "--strict", super_strict: "--super-strict"}[run.mode]
    preset = if run.preset, do: run.preset.name, else: "none"

    layers =
      if opts[:layers],
        do: "on",
        else: "none (the layer-aware checks find nothing)"

    wrap("  tier: #{tier}  preset: #{preset}  layer map: #{layers}", 4)
  end

  # Each rule's statement is printed where the rule first appears, so a later section names it only.
  defp checks_section([], _run, stated), do: {"  (none)", stated}

  defp checks_section(listed, run, stated) do
    groups = Enum.group_by(listed, &elem(&1, 0), &elem(&1, 1))
    order = Keyword.keys(@rules) ++ [:general]

    {blocks, stated} =
      order
      |> Enum.filter(&Map.has_key?(groups, &1))
      |> Enum.map_reduce(stated, fn rule, stated ->
        head =
          case {rule, @rules[rule]} do
            {:general, nil} ->
              "  General checks (no checklist rule of their own)"

            {_, {name, statement, _}} ->
              if MapSet.member?(stated, rule),
                do: "  #{label(rule)}#{name} (above)",
                else: wrap("  #{label(rule)}#{name}: #{statement}", 6)
          end

        lines = for check <- groups[rule], do: check_line(check, run)
        {Enum.join([head | lines], "\n"), MapSet.put(stated, rule)}
      end)

    {Enum.join(blocks, "\n"), stated}
  end

  defp check_line(check, run) do
    text =
      Regex.replace(~r/\{(\w+)\}/, @checks[check], fn _, key ->
        to_string(Map.fetch!(run, String.to_existing_atom(key)))
      end)

    text =
      if check == :r11 and run.r11_calls != :all,
        do: "#{text} (calls: #{run.r11_calls})",
        else: text

    wrap("      #{String.pad_trailing(to_string(check), 15)}  #{text}", 23)
  end

  defp light_lines(%{preset: %{name: :light_ala}}, levels) do
    lines =
      for {n, text, check} <- @light_rules, check == nil or levels[check] == :off do
        wrap("    rule #{String.pad_trailing(to_string(n), 4)}#{text}", 13)
      end

    [
      "  Light-ALA conventions (V59's rules; a checklist reading for light ALA, not Spray's ALA):"
      | lines
    ]
  end

  defp light_lines(_run, _levels), do: []

  defp label(rule), do: String.pad_trailing(upcase(rule), 4)
  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp upcase(rule), do: rule |> to_string() |> String.upcase()

  defp wrap(text, indent) do
    [first | words] = String.split(text, " ")
    pad = String.duplicate(" ", indent)

    words
    |> Enum.reduce([first], fn word, [line | done] ->
      if String.length(line) + 1 + String.length(word) > @width,
        do: [pad <> word, line | done],
        else: [line <> " " <> word | done]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end
end
