defmodule AlaLint.CLI do
  @moduledoc false
  # Shared argument handling for the `mix ala.*` tasks: an actual `--help`/`-h`
  # flag, and a warning (rather than silence) for unrecognised options.

  @doc "If argv asks for help, print `usage` and return true (the caller then stops)."
  def help?(argv, usage) do
    if "--help" in argv or "-h" in argv do
      Mix.shell().info(usage)
      true
    else
      false
    end
  end

  @checks_listing """
  ALA checks and how each is scored. Change any of this in a `.ala_lint.exs` map
  (`checks: %{r7: :scored, height: [max: 4], r11: :off}`) or per run with the
  flags shown.

  REQUIRED  (scored by default; a violation fails --min-score)
    r1    every edge between abstractions drops (no peer or upward calls)
    r2    no shared mutable state between peers
    r3    application literals live at the composition (numbers, guard numbers, message text)
    r4    state lives with its owner, not hidden
    r5    no silent contracts
    r6    every abstraction names a learnable concept
    r9    no owned interfaces: @callback/defprotocol implemented by a peer or a lower layer
    r10   no shared entity (feature-tier)
    layer layer-validity (coverage + tags), with a layer map

  ADVISORY  (reported by default; scored under --strict; --enforce CHECK to promote one)
    r7             unearned / dead abstraction
    module_size    module over N lines          --set module_size.max=N     (default 500)
    height         hops between abstractions     --set height.max=N          (default 5)
    passthrough    public cross-module rename
    tramp          a parameter a public function never reads, only passes on (R6 should)
    r1_ref         reference-level R1 (templates, aliases)
    subscribe      a module subscribing itself to a topic it fixes (R1/R5)
    ports          a feature's ports/0 declaration drifting from the outputs it builds
    ui_io          a UI component below the composition that loads or saves (R6, §5.2.2)
    subcomponent   a LiveComponent inside the application or a Features layer: a contained
                   sub-component (R11, §2.2)
    r10_aggregate  a domain struct several features read: Spray's shared entity (R10, §6.17.2)
    clone          the same logic in two functions, names and literals aside (R7)
                                                 --set clone.min=N           (default 26 nodes)

  ASPIRATIONAL  (reported by default; scored only under --super-strict)
    r11            no logic in a composition layer (the application, and a Features layer,
                   which holds only instances, configuration and wiring, §2.2): branches (guard/logic; `with`,
                   ok/error routing, `connected?`, literal dispatch tables and a case
                   whose arms only pick a component or navigate exempt), choosing what
                   runs by a name built at run time, arithmetic,
                   handling data between abstractions, working chains,
                   logic in application templates, assigns handed to a
                   feature's input, store work in page helpers
                                                 --set r11.calls=wired_only  (default all;
                                                 wired_only skips hand-offs into a part
                                                 with no ports/0)

  REPORTED ONLY  (never scored by a tier; --enforce CHECK to score one)
    app_share      application-layer share of functions --set app_share.max=F (default 0.20)
    public_surface a module whose public ports are an outlier in its layer: above
                   max(floor, Q3 + k×IQR); calibration modules exempt (an R6/R7 prompt)
                                                 --set public_surface.floor=N (default 10)
                                                 --set public_surface.iqr=K   (default 1.5)
    module_avg     files averaging under N lines         --set module_size.min_avg=N (default 100)
    clone_inside   the same logic in two functions of one module (R7: an abstraction's interior)
    unassigned     a module matching no layer: the layer-aware checks skip it (loud warning;
                   --require-layers fails the run)
    ports_unwired  a declared output no composer names (a prompt for a coverage test)
    ports_computed a module emitting a run-time kind, so its declared outputs go unchecked
    wiring_closure a closure over a private page helper in wiring (an R8 prompt)
    r11_share      share of application functions holding logic (not capped like R11)
    hops           a page relaying between LiveComponents (one message hop per effect)
    vocabulary     kinds a paradigm dispatches on (the wiring vocabulary a reader learns)

  LIGHT-ALA READINGS  (not checklist rules; off unless configured in `checks:`; then advisory,
                      scored under --strict or the light_ala preset)
    builder_literals     a config or context struct built outside its builders (in lib, and in
                         test files with tests:), or a builder taking fields positionally (rule 11)
                         checks: %{builder_literals: [structs: [...], builders: [...], tests: ["test"],
                                                      max_positional: 2]}
    stale_session_write  a LiveView whose events write session-scoped data while its mount
                         attaches no guard (rule 12)
                         checks: %{stale_session_write: [writers: [...], except: [...], guards: [...]]}

  PRESETS  (--preset NAME, or `preset:` in the file; a `checks:` level, --enforce and --disable win)
    --preset light_ala   adopts r1 r1_ref subscribe layer r2–r7 tramp ui_io module_size
                         module_avg passthrough height public_surface clone clone_inside
                         unassigned builder_literals stale_session_write; every other check is
                         off (a whitelist, so a check added later stays off until it is listed)

  NOT MACHINE-SCORED  (a human reads for these)
    r8    reads as the requirements
    r9    the rest of R9 (outputs announce, no shared DTOs) is judgement

  Turn any check off with --disable CHECK, or `checks: %{CHECK: :off}` in the file.
  """

  @doc "Human-readable listing of every check, its tier, and its threshold flag."
  def checks_listing, do: @checks_listing

  @doc "Warn on stderr about the unrecognised options OptionParser collected."
  def warn_unknown([]), do: :ok

  def warn_unknown(invalid) do
    names = invalid |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")
    Mix.shell().error("ala_lint: ignoring unknown option(s): #{names} — see --help")
  end
end
