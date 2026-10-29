# ALA Lint (ala_lint_elixir)

A static-analysis linter that scores an Elixir codebase against the **ALA Checklist** (R1–R11):
coupling & layering, requirements-locus, state-as-a-wire, cross-boundary contracts, nameability,
and abstraction minimality. It walks `lib/**/*.ex`, reports each violation with a location, and
computes an overall design-health score.

New to ALA? [getdown.dev](https://getdown.dev) has an introduction to it, guides to applying it,
and worked examples, including posts on this linter and the checklist.

This is the **Elixir implementation** of the ALA Checklist and encoding. The checklist itself is
language-agnostic and lives in its own repository:
[modellurgist/ala_checklist](https://github.com/modellurgist/ala_checklist). Example designs the
linter is applied to live in
[modellurgist/ala_variants_elixir](https://github.com/modellurgist/ala_variants_elixir).

It analyzes source by parsing (`Code.string_to_quoted`); it does **not** compile your project, so
it runs on any codebase without its deps.

> An independent, unofficial implementation based on John Spray's
> [Abstraction Layered Architecture](https://www.abstractionlayeredarchitecture.com/).
> Not affiliated with or endorsed by the author.

## Install

```elixir
# mix.exs
defp deps do
  [
    {:ala_lint, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

```
mix ala.lint                      # score lib/
mix ala.lint lib/my_app           # a subtree
mix ala.lint lib/app lib/app_web  # several roots — everything outside them is excluded
mix ala.lint --limit 100          # show more findings
mix ala.lint --layers-module MyApp.AlaLayers   # layer-aware R1/R3 + coverage
mix ala.lint --min-score 75       # exit 1 if below 75 (CI gate)
mix ala.lint --strict             # score the obtainable advisory checks too
mix ala.lint --list-checks        # every check, its tier, and its threshold
mix ala.lint --explain --strict   # what this run scores, only reports, and leaves to a reader
mix ala.lint --enforce r7         # promote one advisory check to scored
mix ala.lint --disable r3         # turn one check off (and say so in the output)
mix ala.lint --set height.max=4   # retune a threshold (height/module_size/public_surface/app_share/clone/min_score)
mix ala.lint --set r11.calls=wired_only  # R11 reads hand-offs into wired parts only
mix ala.lint --preset light_ala   # the light-ALA reading: R1–R7 and the general checks, nothing else
mix ala.lint --help               # usage; unknown flags warn instead of being ignored

mix ala.encode                    # write an ALA-notation draft of lib/ to ala_encoding/
mix ala.encode --layers-module MyApp.AlaLayers   # with [tag]s filled in
mix ala.lint.encoding             # lint a completed encoding tree (R1/R3/R4/R5/R10/R11 + advisories)
```

Every task also has a real `--help`, and `mix help ala.lint` prints the full task
docs. Unrecognised options warn (`ignoring unknown option(s): …`) rather than
being silently dropped.

`--explain` prints a guide to the run that its flags and `.ala_lint.exs` describe, and reads no
code. It has three parts: the checklist rules the run scores, each with its § citation and the
checks that score it; the rules and checks it only reports; and what still applies that no check
reads. That last part always has R8, has the judgement half of each other rule the run adopts, and
under `--preset light_ala` has V59's conventions the linter can't check. A rule whose checks are
all off is left out, and the last line names it. `AlaLint.Explain.to_text/1` takes the same opts as
`AlaLint.analyze/2`.

> **On "config" here.** A *config module* (`--config-module`) or a *config layer*
> (`config: true` in a layer spec) names a **place** where **application literals**
> — the product-specific constants R3 wants at the composition — are allowed to
> live. It is not about the value's nature (that is the application-literal /
> intrinsic-literal distinction); it marks the composition, or a manifest standing
> in for it. `--config-module` is the fallback for a codebase with **no** layer map
> and is ignored once one is given; with a layer map, R3 uses the `config: true`
> layer (defaulting to the top).

## Accepting a finding by hand (`ala:accept`, `@inherent_`)

Several checks turn on a judgement the tool can't make: whether a word below the composition is
the product's (hoist it) or the abstraction's domain's own (keep it; the checklist's R3 exception),
whether a page's branch is routing or logic, whether a shared struct is a ground symbol. A comment
on the line above records the reviewer's call where the code is, names the exact check, and takes
that line (or the next N lines) out of the score for that check only:

```elixir
# ala:accept r3 -- "Out of stock" is retail's word, not this store's (R3, domain vocabulary)
def label, do: "Out of stock"

# ala:accept r3,r6 lines=2 -- two checks, the next two lines
```

```heex
<%!-- ala:accept r11 -- the one loop this page keeps, until a rows component exists --%>
<div :for={row <- @rows}>…</div>
```

For words there is a declaration instead of a comment: a module attribute named `@inherent_...`
holds the abstraction's own vocabulary, and R3 reads nothing inside it as product text.

The check names are the ones `--list-checks` prints; an unknown one fails the run. Accepted
findings leave the score and the rules-met count, and the report says how many were accepted and
under how many comments. `mix ala.lint --list-accepted` prints every `@inherent_` declaration and
every comment with the findings it covers, and marks the ones that cover nothing, which is how a
stale acceptance shows up after the code moved.

## Configuring checks (`.ala_lint.exs`)

The CLI carries the common path (paths, tiers, `--min-score`). Durable, per-check
settings live in an optional `.ala_lint.exs` map at the project root, so the
command line stays small as the check list grows:

```elixir
# .ala_lint.exs
%{
  layers_module: MyApp.AlaLayers,
  min_score: 85,
  config_modules: ["MyApp.Manifest"],
  exclude: [~r{/components/}],
  checks: %{
    r7: :off,                    # off | advisory | scored
    r3: :advisory,               # downgrade a scored (required) rule to reported
    height: [level: :scored, max: 4],
    public_surface: [max: 8],    # the public-surface floor (see the table)
    module_size: [max: 400]
  }
}
```

A check's setting is a **level** (`:off | :advisory | :scored`) and/or a
**threshold** (`max:`). One mechanism covers "turn it off", "change its level",
and "retune it", for any current or future check. `mix ala.lint --list-checks`
prints every check, its tier, and its threshold flag.

For a single run the generic flags override the file: `--enforce CHECK` promotes
one advisory check, `--disable CHECK` turns one off, `--set KEY=VALUE` retunes a
threshold (`height.max`, `module_size.max`, `public_surface.floor` (older name `public_surface.max`),
`public_surface.iqr`, `app_share.max`, `clone.min`, `min_score`). A run that disabled or downgraded any check says so in its
parameter echo, so a green score never quietly hides which rules it skipped.

A check's level comes from the last source that sets one, in this order: the preset, the `checks:`
level (from `.ala_lint.exs` or `analyze/2`), `--enforce`, `--disable`. When two of them ask for
different levels, the report opens with a block that names each source, the level it asked for and
the one used. `params.conflicts` in the report map holds the same list. Sources that agree, and a
`checks:` entry with thresholds only, are not a conflict, and a run without one prints what it
printed before.

```
settings conflict: 2 checks set differently by more than one source; the later source won
  clone      file checks: off   --enforce: scored   -> using --enforce (scored)
  r11        preset light_ala: off   file checks: advisory   -> using file checks (advisory)
```

R11 takes one setting that is a reading, not a number: `calls:` is `:all` (the default) or
`:wired_only`, as in `checks: %{r11: [level: :advisory, calls: :wired_only]}`,
`--set r11.calls=wired_only`, or `AlaLint.analyze(root, r11_calls: :wired_only)`. Any other value
fails the run (exit 2 from `mix ala.lint`, `ArgumentError` from `analyze/2`). The parameter echo
shows it only when it isn't the default. `:wired_only` is for a composition that wires only the
parts two or more compositions place and calls the rest (ALA Light, subset 3): a call-and-return
there is the design, not handled data.

### The light-ALA preset and its two checks

`preset: :light_ala` (in `.ala_lint.exs` or `AlaLint.analyze/2` opts), or `--preset light_ala`,
scores a codebase as light ALA (`ala_variants_elixir/v59-light-ala`): dependency direction,
calibration at the top and named rules, without ports, wiring or composition-only pages. It is a
**whitelist**. It adopts `r1 r1_ref subscribe layer r2 r3 r4 r5 r6 tramp ui_io r7 module_size
module_avg passthrough height public_surface clone clone_inside unassigned builder_literals
stale_session_write`, and every other check is off. A check added to the linter later therefore
stays off under the preset until someone lists it. The list is by check name, not by rule, because
port-only checks such as `hops`, `vocabulary` and `wiring_closure` sit under rules the preset
keeps. So R9, R10, R10-aggregate, R11, `r11_share`, `app_share` and the port, wiring and
composition checks are off. Under the preset, `clone` is scored by `--strict` as usual, and the two
checks below are scored when they are configured. Precedence: the tier's default < the preset < a
`checks:` level < `--enforce` < `--disable`; a `checks:` entry that sets only a threshold keeps the
preset's level. An unknown preset fails (exit 2, `ArgumentError`).

Two checks read light-ALA rules 11 and 12. They are readings, not checklist rules: they don't
count toward the rules met, and each does nothing until its settings are given. Once configured
they are advisory, and `--strict`, the preset or `level: :scored` scores them.

```elixir
checks: %{
  builder_literals: [
    structs: ["GoodDeal.Channel", "GoodDeal.Shop"],
    builders: ["GoodDealWeb.Calibration", "GoodDealWeb.CartSession"],  # optional
    tests: ["test"],          # also read these for literals; no other check sees them
    max_positional: 2         # the default
  ],
  stale_session_write: [
    writers: ["GoodDeal.ShoppingCart", "GoodDeal.Orders.complete_checkout"],
    except: [~r/^(get_|list_)/, "cart_closed?"],   # names, "Mod.fun", or a regex on the name
    guards: ["GoodDealWeb.CartSession.guard_open_cart"]
  ]
}
```

Without `builders:`, each struct's builders are inferred: the `lib` modules with a function that
returns the struct, directly or through one call in the same module. The parameter echo names
them and says whether they were inferred or configured. A struct's own module may always build it.
A misspelt or missing setting fails the run.

A **layers module** is any module exporting `layers/0` that returns a layer spec
(see `AlaLint.Layers`). Declare it once with `config :ala_lint, layers_module:
MyApp.AlaLayers` and both `ala.lint` and `ala.encode` pick it up with no flag.
`ala.encode` writes a parallel `.ala.md` tree a human completes; `ala.lint.encoding`
then checks that tree. It scores what the notation carries: R1 edge altitude, R4 `$`,
R5 `q`, R3 via `{app-literal?}`/`{app-literal}`/`{intrinsic-literal}` literal marks, and —
from marks the encoder **stamps** rather than asks a human to judge — R10 (`&entity`/
`&aggregate`), R11 (`(branches)` on an app-layer function), pass-throughs (`~>`), and
public surface (via `(private)`; there a fixed count of 12, since the notation carries neither clauses nor
layer spreads). R6/R7 stay unencodable, and so does the tramp-parameter check
(the encoding doesn't carry parameters); height and the R11 app-share
aggregate are reproduced only approximately (the encoding carries module-level edges, not
the full call graph). The encoder seeds `{app-literal?}` on each function owning a
configuration-candidate literal (value opaque; the source scan has its `file:line`); a
reviewer resolves it to `{app-literal}` (an application literal — hoist if it isn't at the
top) or `{intrinsic-literal}` (intrinsic to the abstraction, kept local). The aim is that a
correctly completed encoding re-lints to the same findings the source lint gives.

### Assigning functions to layers

Each layer declares matchers; a **function** is assigned **most-specific-wins**: its own
`@ala_layer :name` attribute > a **`uses:` content match** (the module's `use` macros — e.g. a
schema is persistence even in a domain namespace) > the first layer whose **module-name pattern** or
**filesystem `paths:` glob** matches > *unassigned*. Layers are a design decision you *declare*,
never something inferred from the call graph (inferring them would make R1 tautological). You can
also pass **multiple include roots** to restrict analysis to your real code
(`AlaLint.analyze(["lib/app", "lib/app_web"])`), excluding boilerplate elsewhere.

```elixir
def layers do
  [
    {:app,       [~r/Web\..*Live$/],           paths: [~r{/live/}]},
    {:feature,   [],                            paths: [~r{/features/}], unit: ~r/(App\.\w+)/},
    {:domain,    [~r/App\.(Cart|Pricing)$/, ~r/Web\.Components\./]},
    {:paradigms, [~r/Interpreter$/, ~r/Effects/, ~r/Foundation/]}
  ]
end
```

Peers are forbidden in every layer below the top unless it declares `peer_ok: true` (checklist R1:
domain → domain is a peer edge too); the top layer allows them, because the application is one
abstraction. Following the checklist's model of a LiveView app, only page-specific code is
application: generic components are domain (UI) abstractions, and a generic shell or effect
interpreter is an execution model in the paradigms layer. (`app: true` on several layers, to model
shell → page → view sub-layers, still works but is the older model.)

**A Features layer is a composition layer.** Spray's features hold wiring, like the application:
"Each feature creates instances of domain abstractions, configures the instances with feature
specific details, and connects them together as needed to express the feature or user story" (§2.2).
So a layer named `:feature`, `:features`, `:user_story`, `:user_stories`, `:story` or `:stories`, or
any layer with `composition: true`, gets the application's R11 checks, may hold application
literals (R3), and isn't checked as a lower layer. A layer of coded state abstractions (a cart
with its rules, an undo offer) is a domain layer in Spray's terms. Name it that way (`{:state, ...}`
above `{:domain, ...}`), or keep the name with `composition: false`.

A feature's parts must read as one unit. With `unit: ~r/^(App\.Features\.[^.]+)/`, a feature's UI
instance named `App.Features.CartPanel` counts as a peer of `App.Features.Cart` (R1 and R10 findings);
named `App.Features.Cart.Panel`, it is the same unit. Name a feature's parts under the feature, or
widen the unit regex.

The report then gives three things a migration cares about: **layer coverage** (% of functions
assigned, with the unassigned worklist), **validity** errors (a `@ala_layer` tag naming an
undeclared layer), and **R1** (do the assigned function→function edges drop?). With no layer map,
coverage is skipped and the structural checks that need no layers still run — the on-ramp for a
codebase not yet organised into layers.

Or as a library, without adding a dep to the target (point it at any path):

```elixir
AlaLint.analyze("../some_project/lib") |> AlaLint.Report.to_text() |> IO.puts()
```

## The rules (and their precision — this matters)

The checklist mixes exact structural facts with heuristic proxies for judgement calls. AlaLint is
honest about which is which:

| rule | what it flags | precision |
|---|---|---|
| **R1** peer coupling | with a layer map: **upward** and **cross-peer** edges between abstractions on the function call graph (an edge that doesn't drop; same-unit calls are internal). Without one: module dependency **cycles** | **exact** |
| **subscribe** self-subscription | *advisory.* A module outside the application calling `subscribe` with a topic it fixes (a literal or module attribute): a receiver choosing its own sender (Spray §4.4.2). Subscribing in the application, or taking the topic as an argument, is fine; so is a module in the **bottom** declared layer owning its topic (that is where a technical domain such as PubSub is abstracted) | advisory |
| **R1-ref** template coupling | *advisory.* Peer/upward edges visible only in the module alias graph, not as a call — usually a cross-feature call inside a `~H` template (invisible to the AST). Reported to verify | advisory |
| **R2** shared mutable state | `:ets` / `:persistent_term` / `Agent` usage — a shared-state channel to confirm isn't a peer back-channel | advisory |
| **R3** baked calibration | "magic" numeric literals inside modules, including numbers in guards, and multi-word message text a person reads (a flash, a label) in a lower layer: hoist them to the composition | heuristic |
| **R4** hidden state | the **process dictionary** (`Process.put/get`) — hidden state that should live in the abstraction that owns it (or a State-style abstraction wired in) | **exact** |
| **R5** duplicated contracts | the same **identifier-like string** (`"item-removed"`, no whitespace, len 5–40) in ≥2 modules. Strings inside `~p`/`~H`/`~L` sigils are skipped — a `~p"/x"` verified route is compile-checked, not a silent contract — and so is a `/path` string shared with the `Router`, the route table's own contract. Also a **name fired in one module and matched in another**: an event a template fires (`phx-click=`, `event=`, `on_*=`, `JS.push`) handled by a `handle_event`/`event` head elsewhere, or a literal timer/task name given to `start_timer`/`start_async` and matched by a `handle_info`/`handle_async` head elsewhere; not when the naming module handles it too, when the name is configuration, or when both modules are in the application layer | **exact** |
| **R6** nameability | meaningless function/module names, and functions that just wrap a primitive (`f(a, b) = a + b`). A predicate (`name?`) over the module's own state, a module's single public function, and a function whose first parameter is its own configured struct (`call(%__MODULE__{unit: u}, n), do: n * u`, a configured rule) are concepts, not wrappers, and are spared | heuristic |
| **R7** unearned abstractions | **dead** private functions, and trivial single-use one-liners with meaningless names. HEEx components (invoked as `<.name/>` in `~H`/`.heex`) and functions defined inside a `quote` block are recognised as *called* and never reported dead | heuristic, **advisory** |
| **R9** owned interfaces | a `@callback` or `defprotocol` implemented (`@behaviour`, `defimpl`) by a **peer** in the same peer-forbidden layer, or by a **lower** layer. A port interface belongs below its implementers (a paradigm protocol, or a general module like `GenServer` that higher modules configure). The rest of R9 (outputs announce, no shared DTOs) is judgement | **exact** on explicit implementations |
| **R10** shared entity | a struct read by ≥2 units **of its own** peer-forbidden layer (two features sharing a feature's struct) — share an identity key, keep data private. Higher layers reading a lower struct is a knowledge dependency, not R10. Entity candidates come from `defstruct`, so an Ecto `schema` is not one: a lifecycle declared on an identity schema (`has_many …, on_delete: :delete_all`), a context deleting rows keyed by an identity, and a read that walks such an association into another feature's rows are all invisible to R10 and R10-aggregate. The checklist allows lifecycle by identity key at the identity or in the composition (2026-10-21) and keeps the walk-in a finding; that line is left to a reader here | heuristic |
| **R10-aggregate** shared aggregate | a struct in a **lower** layer read by ≥2 units of a peer-forbidden layer above it — a legitimate domain abstraction (Spray's "ground symbol", §3.6.1), or shared-Entity coupling? A struct whose own functions take it as configuration and never update it (a rate table, a stock rule built once and handed down) is configuration, not shared data, and isn't reported. Checked and scored under `--strict` and `--super-strict` since 2026-10-03: read strictly, it is Spray's shared entity: an identity "should not be used as the carrier of information between two use cases" (§6.17.2). Two fixes: send a consumer only the data it needs (an id and the lines, not the cart), and keep each use case's data out of a struct another use case shares. A deliberately shared value type can be downgraded with `checks: %{r10_aggregate: :advisory}` | strict, scored |
| **R11** composition-only top layer | A top-layer function **branches** (reported as *guard* or *logic*; `with`, a `case` that only routes ok/error outcomes, and LiveView's `if connected?(socket)` are exempt, as the connection mechanism, routing, and the one framework departure the checklist names). A closed dispatch is routing too (a checklist reading, 2026-10-21): a literal map from states to components or handlers (`@views[step]`, `Map.fetch!(@handlers, event)`) is not a branch, and neither is a `case` whose patterns are literals and whose arms only pick: a module, a capture, a `~H` block, `render`/`live_component`/`component`, `push_navigate`/`push_patch`/`redirect` (also inside a `{:noreply, …}` tuple), or a function component given `assigns`. An arm that does other work keeps the `case` a branch, and so does a `nil ->`, `true ->` or `false ->` arm, an `if` spelled as a `case` (*guard* for `nil`). A function that **chooses what runs by a name built at run time** is the same branch, hidden: `apply/3` (or `Kernel.apply/3`, `Function.capture/3`) with a non-literal module or function, or a call on a module built by `String.to_atom`, `String.to_existing_atom`, `Module.concat` or an interpolated atom (directly or through a variable). An atom built from input and used as data (`%{method: String.to_existing_atom(m)}`) and a call of a configured function (`fun.(x)`, `apply(fun, args)`) are wiring, not this. Also a finding: the function does **arithmetic** (in its body or in a shorthand function it builds, `&(&1 * rate)`; a named capture `&Mod.fun/2` is not division); it **iterates** (a `for` comprehension, Spray's "for loop", §1.6.3); it **handles data** (binds a lower-layer call's result and passes it to another lower-layer call, or passes one straight into another's call as an argument, Spray §1.6.3; a nested `new` building an instance's configuration isn't counted, and neither are pipes, because a pipe of stages is how Elixir writes his §1.6.4 chain); or it is part of a **working chain** (an app function calling another app function that computes or decides). Under `r11.calls=wired_only` the hand-offs (handled data, an assign passed in, a template call) into a **called part** are left out: a project module below the application that declares no `ports/0`. Branches on its result, arithmetic, iteration and working chains are still reported, and `:r11_share` counts only what is. Real findings; reported by default, scored only under `--super-strict` | advisory / super-strict |
| **clone** duplicated logic | *advisory, R7.* The same logic in two functions of different modules (in one module it is **clone_inside**, reported and never scored by a tier, as in `ala_lint_ruby`: the checklist leaves an abstraction's interior to its author). Exact: the same shape with variables renamed and literal values changed (a whole function, a run of its clauses, a clause, an expression, or a run of statements or pipeline stages), at least `--set clone.min=N` normalized AST nodes (default 26). Near miss, across modules only: a clause copied and then edited, where identical subtrees of 4+ nodes (atoms kept) make up at least 45% of both clauses. Each copy is reported once, at its largest match. A clause or statement that is one call on plain arguments (`wire/3`, a routing `handle_event`, `{:noreply, Steps.run(...)}`) or plain data (`ports/0`) adds nothing to the size, since wiring looks alike by design. Checklist reading, not Spray's wording: a concept written twice instead of one abstraction both places compose and configure. It leans on "abstraction and reuse are two sides of the same coin" (Summary, §2.1.1) and an element knowing one thing that "no other elements should know about" (§7.25). Added 2026-10-19, after agents in a change-cost experiment met every other check by copying logic; the default size and the 45% share were calibrated there and on V50, V51 and V51B | heuristic, advisory / strict |
| **builder_literals** (light-ALA rule 11) | A guarded struct built (`%Mod{...}`, `struct/2`, `struct!/2`) outside its builders, in `lib` or in a `tests:` path. Patterns (function heads, `=`/`->`/`<-` left sides, `match?`) and updates (`%Mod{s \| f: v}`) are not builds. Also a public builder that returns a guarded struct and takes its fields positionally: more than `max_positional` non-keyword parameters, or no keyword-list parameter and a parameter named like a field, or a parameter named like an optional (non-enforced) field. A keyword parameter is one with a list default, one used with `++`, as `struct!/2`'s second argument or in a `Keyword` call, or one named `overrides`, `opts`, `options`, `attrs`, `fields`, `kw` or `keywords`. Hybrid 1's S04 broke 119 tests through a builder whose cart id was positional | heuristic; off unless configured |
| **stale_session_write** (light-ALA rule 12) | A LiveView (a `:live_view` use, or `mount/3` and `handle_event/3` without a component use) whose `handle_event` clauses call a configured writer, directly or through the module's private functions, while no `mount` clause (or private function it calls) calls a configured guard. One finding per page, at `mount`, listing each event and the writers it reaches. Controllers and LiveComponents are not read; calls into other modules are not followed (name such a module's function as a writer), nor are `handle_info`/`handle_async`, an `on_mount` hook or a guard's `only:` list. Hybrid 1's S07 reorder wrote to a cart its page captured at mount after the session had moved on | heuristic; off unless configured |
| **module size** | *advisory.* A module over `--max-module-loc` (default 500) | metric, **advisory** |
| **module_avg** | files averaging under 100 lines (Spray: "more abstractions than we need"; `--set module_size.min_avg=N`). Reported at every tier, scored by none: Spray's bound is per abstraction, and an Elixir single-function domain module is deliberately small | metric, reported only |
| **app_share** | the application layer's share of all functions (`--set app_share.max=F`, default 0.20). Reported at every tier, scored by none: a ratio that penalises an app for having many pages | metric, reported only |
| **height** proliferation | longest chain of hops *between abstractions*; calls within one module (internal decomposition of a little ball of mud) and within the app layer count as zero altitude, so only real drops between abstractions add depth. Warns past a ceiling (default 5) | metric, **advisory** |
| **passthrough** proliferation | a **public** function with 1 caller + 1 callee **in another module** whose body is a single delegating call — a rename over a different abstraction that hides no decision. Private helpers and same-module calls are internal decomposition and left alone; so are transforms (`sub(x) \|> Money.new()`, `%{s \| f: Callee.x()}`, and LiveView's `assign(s, f: Callee.x())`, the same update), predicate (`name?`) forwarders, HEEx components, and macro-generated defs | heuristic, **advisory** |
| **tramp** parameter | *advisory, R6's "should".* A **public** function never reads a parameter and only hands it to a function in another project module (a lower one, given a layer map) that doesn't read it either and hands it further down: two hops of carrying, Spray's "extra parameters that don't have anything to do with them, just so they can pass state data through to even lower functions" (§3.11.1). One hop is ordinary use of a lower abstraction and is left alone; so are private helpers, framework callbacks (`handle_event`, `mount`, `init`, …), pass-throughs, the application layer (R11 reports its data handling), and carrying into a protocol or behaviour (a runner delivering to a port) | heuristic, **advisory** |
| **LiveView templates** (R11, R3, R5) | HEEx is read as text (`~H` sigils, and a `.heex` file belongs to the same-named `.ex` beside it). In an **application** template, an expression that compares (`==`, `in`, …), computes (`+ - * /`), uses `case`/`if`/`cond`/`for`/`with`, iterates (`:for`), or calls a project module below the application is R11 (`:if={@flag}`, `@a && "class"`, field reads, `~p` paths and `&Mod.fun/1` captures are wiring, not logic; a `<%= case @step do %>` whose arm patterns are literals and whose arms hold only component tags, `<.view …/>` or `<.live_component …/>`, is routing, and the tags' attribute expressions are still checked). In a **lower** layer's markup, text nodes and label-like attributes (`label`, `placeholder`, `title`, …) are R3 words the page should supply, one finding per module. A `$2.99`-style amount in any string whose cents are also a configured integer is R5 (the label restates the configuration) | heuristic; R3/R5 scored, R11 advisory / super-strict |
| **Words and codes in code** (R3) | Below the application: a validation `message: "..."`, a sentence built by interpolation (two or more words around a `#{}`; not in the bottom layer, whose text is a paradigm's own diagnostics or labels), and a `currency:`/`unit:`/`locale:`/`time_zone:` string. `raise` and `Logger` are exempt | heuristic, scored |
| **Declared ports** (`:ports`, `:ports_unwired`, `:ports_computed`) | For a module with `ports/0` returning `%{in: [...], out: [...]}`: an emitted key (a keyword list returned in `{state, [...]}` or joined with `++`) that isn't declared, or a declared output never built anywhere in the module (in a keyword list, or sent as a composition sends), is `:ports` (drift; promoted by `--strict`). A composition that declares `parts/0` (a Spray feature) sends its outputs with a `send_out*` call, an `{:out, port}` binding or `out.(s, {:port, payload})`, so those are its emitted ports, and its keyword lists are configuration. An emit under a kind computed at run time, `out.(s, {kind, fact})` (a function variable named `out*`), counts as emitting each literal kind `kind` is enumerated from in the same clause: a `for` generator or an `Enum` function's `fn` over a literal atom list, the keys of a literal keyword list or map, a module attribute holding one, `Map.keys`/`Keyword.keys` of one, or what a function of the same module returns (one call followed). Such kinds only ever account for declared outputs, never make one undeclared. When the kind can't be resolved, "never emits" is not reported for that module and `:ports_computed` notes the emit's file:line and the outputs left unchecked. A declared output that no composer (a module referencing the feature or its submodules) names as `{:feature, :port}`, `{:feature, :port, payload}` (a clause head or message), `{:port, _}` or in an atom list is `:ports_unwired`: possibly unwired, a prompt for a coverage test | `:ports` advisory/strict; `:ports_unwired`, `:ports_computed` report only |
| **Page hand-offs** (R11, R8) | An application function passing an assign (`socket.assigns.x`) as a *non-first* argument to a feature or domain function (config-first calls and bottom-layer runners are exempt) is R11: the page is composing another abstraction's input. A private application function calling two or more bottom-layer functions is R11 store work in a page helper. A capture of a private page helper that closes over a variable (`&add_line(cart_id, &1)`) is `:wiring_closure`, an R8 concern reported only | R11 advisory / super-strict; closure report only |
| **UI doing I/O** (`:ui_io`, R6) | A LiveComponent or component module below the composition that calls a module reaching the Repo or PubSub, a configured I/O instance, or a function on a module held in a variable or assigns. Spray wires data sources and sinks to the UI element that shows the data (§5.2.2), so a UI module doing I/O bundles a data source into a UI abstraction | heuristic, advisory / strict |
| **Contained sub-components** (`:subcomponent`, R11) | A LiveComponent in a composition layer (the application, or a Features layer). A page-specific component with its own state and handlers is a sub-component, and Spray has "no analog of a sub-module or sub-component… Abstraction layers replace hierarchical containment" (§2.2). Build it from a domain UI abstraction the page configures and wires (a generic record form), or move a reusable one down a layer | exact, advisory / strict |
| **Report-only measures** | `:r11_share`: the percentage of application functions with an R11 finding (the R11 scale caps each kind of finding; this doesn't). `:hops`: an application module that places LiveComponents and receives messages, so a cross-component effect relayed through it takes one message hop. `:vocabulary`: a bottom-layer function dispatching on five or more tagged kinds (a binder's binding kinds), the wiring vocabulary a reader learns | never scored |
| **Unassigned modules** | With a layer map, a module that matches no layer is reported as `:unassigned`, and the text report opens with a `!! WARNING` banner listing them (also printed to stderr), because R1 altitude, R3, R10, R11 and the LiveView checks skip unassigned code: the score covers less than the codebase. Never scored by a tier (`--enforce unassigned` scores it); `--require-layers` (or `require_layers: true` in `.ala_lint.exs`) fails the run | exact, loud warning |
| **public surface** | a module whose public **ports** are an outlier among its own layer's modules (all modules when there is no layer map): more than max(floor, Q3 + k × IQR) of that layer's counts, quartiles by linear interpolation (numpy's default, Excel's QUARTILE.INC). Floor `--set public_surface.floor=N` (default 10, so a tiny app's small modules never trip it), k `--set public_surface.iqr=K` (default 1.5, Tukey's fence). A public function is one port, except that clauses matching distinct map or struct shapes in the same argument are one port per shape (`set_product(l, %{stock: _})` and `set_product(l, %{amount: _})` are two); shapes are compared among clauses with the same literal arguments, so under an event name (`handle_event("ship", %{"method" => m}, s)`) the shape is that event's payload and a multi-clause `handle_event` still counts once. A **calibration module** is left out of the count and the distribution: every public clause returns a literal (a number, string, atom, list, tuple, map or struct of literals, a module attribute) or picks one from a literal table by a key argument (`promo_codes(:portal)` heads, `Map.fetch!(@table, key)`, `@table[key]`, a `case key` with literal arms). Spray gives no count ("abstractness decreases with more ports", §7.2.3); the check prompts the R6/R7 judgement (one concept? mess kept private?). Reported at every tier and **scored by none** since 2026-10-21, after runs treated the old fixed limit of 12 as a gate and contorted code to stay under it; `--enforce public_surface` scores it | metric, reported only |
| **layer cohesion** | *advisory metric.* Per layer, the share of its functions under one directory (Spray: directories separate layers). 100% = cohesive | metric, **advisory** |

**Rules met.** The score is a density (weighted findings per 100 functions), so a few findings in a large codebase round away even when they matter. The report also counts the checklist rules met: a rule is met when none of its checks has a scored finding at the current tier, and a second count includes advisory findings. A rule whose checks are all off is `:not_adopted`, not met: it is left out of both counts, and the report lists it (`not adopted (their checks are off): R9, R10, R11`). R8 is judgement and is never checked; R11 needs a layer map. Each check counts toward one rule (`ui_io` and `tramp` toward R6, `subcomponent` toward R11, `ports` toward R9, the size, depth and clone checks toward R7). The report map carries it as `rules`: `%{met: 9, checked: 10, total: 11, met_strictly: 7, not_adopted: 0, by_rule: %{r11: %{state: :not_met, scored: 1, advisory: 0}, ...}}`.

### Strictness modes

- **default** — the *required* checks are scored (see below); everything else is advisory (reported).
- **`--strict`** — promotes the *obtainable* advisory checks (R7, module-size, height, pass-through,
  tramp, R1-reference, subscribe, declared-port drift, duplicated logic) to scored, so genuine cruft can fail the build.
- **`--super-strict`** — `--strict`, and additionally scores the *aspirational-purity* check **R11**
  (no logic at the top). It is impractical to zero out in a real app, so it is a super-strict gate,
  not a strict one, while still being *reported* by default.
- **Reported at every tier, scored by none**: **app_share**, **module_avg** and **public-surface**.
  Each is a ratio or a prompt for judgement rather than a defect; `--enforce CHECK` scores one.

Phoenix's generated framework files (`core_components.ex`, `layouts.ex`, `telemetry.ex`,
`gettext.ex`, `endpoint.ex`, `error_html.ex`, `error_json.ex`, `application.ex`, `mailer.ex`,
`repo.ex`) are skipped by default; pass `include_framework: true` to `AlaLint.analyze/2` to score
them.

Pair any mode with `--min-score N` to gate CI at the strictness you want. The **required** (scored by
default) checks are **R1, R2, R3, R4, R5, R6, R9, R10, and layer-validity**; the **advisory** ones are
**R7, module-size, abstraction-height, pass-through, tramp, R1-reference, subscribe, clone** (promoted by
`--strict`), plus **R11** (promoted only by `--super-strict`); **R10-aggregate** is scored from
`--strict` up; **app_share**, **module_avg** and **public-surface** are reported and never promoted by a tier. **R9** is checked for owned interfaces (scored); its other parts are judgement. R8
is not checked (judgement).

**R7, R11, module-size, abstraction height, pass-through, tramp, and the reference-level R1 signal are
advisory** — reported but not folded into the score. Reuse is evidence not a requirement (Spray never
demanded a second caller), and a source-encoded app layer legitimately branches, so the tool won't
fail a build on these alone. Promote any to a hard failure with `--enforce r7` / `--enforce r11` /
`--enforce height` / etc. **R9** (ports typed by a paradigm; no abstraction owns an interface except
its own configuration) is checked for owned interfaces; whether outputs announce rather than
command, and whether a struct on a port is a peer's DTO, are left to a reader. **R8** (reads as the requirements) is
not checked — it is judgement. Every run echoes its **effective parameters** (max_height,
max_app_share, max_module_loc, enforce set, layers on/off, weights, config/exclude) so results are
reproducible and you know exactly what was and wasn't checked.

R1 altitude, height, and pass-through all run on a **function→function call graph** (each
`Module.fun/arity` a node, remote calls resolved through the module's alias table). Only R1's
no-layer-map fallback (cycle detection) stays at module granularity — a function-level cycle is
usually legitimate recursion, whereas a module cycle is the real coupling smell.

**R8 (readability)** — names, config clarity, "the composition reads as the spec" — is *not*
checked. It is judgement; a high score is necessary but not sufficient. See the ALA Checklist.

Two design choices worth knowing:

- **Generated files are skipped** (any file whose head contains `GENERATED`). Derived code
  legitimately duplicates its source — e.g. committed codegen kept in sync by a `--check` — and
  must not be scored as hand-authored design. Without this, a manifest→generated pair looks like
  massive R5 duplication when it's actually the safest arrangement.
- **`~H` markup is opaque to the AST**, so contracts *inside* HEEx templates (`phx-click="…"`) are
  not seen — AlaLint checks Elixir-level structure. (Markup-level contract checking is what a
  `ContractPurity`-style Credo check does; the two are complementary.)

## The score

Each rule carries a severity weight (coupling core R1/R2/R5 = 3; state R4 = 2; design smells
R3/R6/R7 = 1). The headline density is **weighted violations per 100 functions** — functions, not
lines, because the checklist is about how *abstractions* relate:

```
W        = Σ weight(rule) × count(rule)
density  = W / functions × 100          # weighted violations per 100 functions (headline)
per_kloc = W / loc × 1000               # weighted violations per 1000 LOC (secondary)
score    = clamp(100 − density, 0, 100) # 0–100, higher is better
```

Grades: A ≥ 90, B ≥ 75, C ≥ 60, D ≥ 40, else F.

**Is a function counted more than once?** In the *severity* score, yes — its numerator counts
*findings*, so a function with several problems weighs several times, and a data-heavy module can
exceed 100 findings/function (e.g. a colour-table library scored 3369/100fn). That is why there is
a second, bounded metric:

### Count of compliant functions (the bounded metric)

```
offending  = distinct functions with ≥1 finding
compliant  = functions − offending         # functions with ZERO violations (a raw count)
compliant% = clamp(100 − offending/functions×100, 0, 100)   # 0–100, higher = cleaner
```

This counts each **function clause** at most once, so it can't be inflated by one function accruing
many findings. Both metrics use clauses (a five-clause `handle_event/3` is five), the unit findings
attach to; the header also gives the distinct count, one per module, name and arity, which is the
better number for comparing how finely two codebases are factored: `functions: 277 (392 clauses)`. Findings that belong to no function — R1 cycles, R5 duplicated literals, and magic
literals in module attributes — are **module-level** and reported separately (not folded in).

The two metrics answer different questions and are both reported (both: higher = cleaner):

- **Degree of function compliance** (was "severity") — `100 − weighted violation load`. Counts
  *findings*, severity-weighted, so a few dense or data-heavy modules can drag it. Its input, the
  *violation load per 100 functions*, can exceed 100 (multi-counts) — that's the "high = bad" number.
- **Count of compliant functions** (was "breadth") — how much of the code is clean; bounded,
  stable, comparable across sizes.

In a study of popular Hex packages the compliant-function % was far tighter (mean ≈92, σ ≈6) than
the degree-of-compliance score (mean ≈64, σ ≈30), precisely because it doesn't multi-count.

## Example output

An illustrative, abridged report for a small app:

```
── ALA Checklist (R1–R11) ─────────────────────────────────────────────
modules: 24   functions: 312 (399 clauses)   LOC: 6183
abstraction height: 9 call-levels (function graph)  ⚠ exceeds max 5
layer coverage: 303/399 functions assigned (76%)
  unassigned (worklist): App.Application, AppWeb.Telemetry, … +19 more
filesystem cohesion (advisory — Spray: dirs separate layers):
  feature    100% under `lib/app/features` (cohesive)
  domain      81% under `lib/app/domain` (scattered across 2 dirs)

Checklist rules met: 9 of 10 checked (11 in the checklist; R8 is judgement)
  with no finding at all, advisory included: 8 of 10
  R1 NOT met (1)  R2 met  R3 met  R4 met  R5 met  R6 met  R7 met (1 advisory)  R8 unchecked  R9 met  R10 met  R11 met

Degree of function compliance: 92/100  (grade A)
  weighted violations: 30   violation load per 100 functions: 7.5
Count of compliant function clauses: 395 / 399  (99% → grade A)

Findings (scored, most severe first):
  [r1] lib/app/features/cart.ex:18  Cart.peek/1 [feature] → Wish.look/1 [feature]: cross-peer edge …

Advisory (reported, NOT scored — R7 reuse/minimality, abstraction height):
  [passthrough] lib/app/x.ex:9  X.forward/1 is a pass-through (1 caller, 1 callee → …)
  promote any of these with --enforce <rule>.

Parameters (effective — defaults unless overridden):
  max_height: 5   enforce: (none)   layers: on   …
```

## What else it does

- **Layer assignment & coverage** — `@ala_layer` tags, `uses:` content matches, module-name and
  `paths:` globs, most-specific-wins; reports coverage (the migration worklist) and validity errors.
- **`mix ala.encode`** — writes a parallel `.ala.md` tree encoding every function in the ALA Code
  Checklist notation (`f` / `[tag]` / edges / `$` / `q`), a draft a human completes.
- **`mix ala.lint.encoding`** — lints a completed encoding tree for what the notation carries.
- **As a library** — `AlaLint.analyze(path_or_paths, opts)` returns a report map;
  `AlaLint.Report.to_text/1` renders it. Point it at any directory without adding a dep.

## Using it with a coding agent

`examples/AGENTS.example.md` is a ready-to-use instructions file that teaches a coding agent (Claude
Code, Codex, and the like) to write and review code against the ALA Checklist by hand, whether or not
this linter is installed. Copy it to your project root as `AGENTS.md` or `CLAUDE.md`. It states the
down-only rule, the four-rule core, each checklist item as a do/avoid/ask directive, the standard
techniques to reach for, and a self-review the agent runs when the linter is absent. When the linter is
present, the agent can also run `mix ala.lint --strict` for the mechanical half.

## Status

Reference implementation for the ALA Checklist. R1/R4/R5 are exact; R2/R3/R6/R7 are labelled
heuristics tuned to be low-noise (single-clause dead-private detection, whitespace-free contract
strings, generated-file skipping). R7, abstraction height, pass-through, the reference-level R1
signal, and filesystem cohesion are **advisory** (reported, not scored) unless enforced.
Contributions and rule-precision improvements welcome.

## License

Licensed under the [MIT License](./LICENSE). Fork and use freely, including
commercially; keep the copyright notice.
