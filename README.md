# AlaLint (ala_lint_elixir)

A static-analysis linter that scores an Elixir codebase against the **ALA Checklist** (R1–R11):
coupling & layering, requirements-locus, state-as-a-wire, cross-boundary contracts, nameability,
and abstraction minimality. It walks `lib/**/*.ex`, reports each violation with a location, and
computes an overall design-health score.

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

## Install (local dev dependency)

```elixir
# mix.exs
defp deps do
  [
    {:ala_lint, path: "../ala_lint_elixir", only: [:dev, :test], runtime: false}
    # or, once published:  {:ala_lint, "~> 0.1", only: [:dev, :test], runtime: false}
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
mix ala.lint --enforce r7         # promote one advisory check to scored
mix ala.lint --disable r3         # turn one check off (and say so in the output)
mix ala.lint --set height.max=4   # retune a threshold (height/module_size/public_surface/app_share/min_score)
mix ala.lint --help               # usage; unknown flags warn instead of being ignored

mix ala.encode                    # write an ALA-notation draft of lib/ to ala_encoding/
mix ala.encode --layers-module MyApp.AlaLayers   # with [tag]s filled in
mix ala.lint.encoding             # lint a completed encoding tree (R1/R3/R4/R5/R10/R11 + advisories)
```

Every task also has a real `--help`, and `mix help ala.lint` prints the full task
docs. Unrecognised options warn (`ignoring unknown option(s): …`) rather than
being silently dropped.

> **On "config" here.** A *config module* (`--config-module`) or a *config layer*
> (`config: true` in a layer spec) names a **place** where **application literals**
> — the product-specific constants R3 wants at the composition — are allowed to
> live. It is not about the value's nature (that is the application-literal /
> intrinsic-literal distinction); it marks the composition, or a manifest standing
> in for it. `--config-module` is the fallback for a codebase with **no** layer map
> and is ignored once one is given; with a layer map, R3 uses the `config: true`
> layer (defaulting to the top).

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
    public_surface: [max: 15],
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
threshold (`height.max`, `module_size.max`, `public_surface.max`, `app_share.max`,
`min_score`). A run that disabled or downgraded any check says so in its
parameter echo, so a green score never quietly hides which rules it skipped.

A **layers module** is any module exporting `layers/0` that returns a layer spec
(see `AlaLint.Layers`). Declare it once with `config :ala_lint, layers_module:
MyApp.AlaLayers` and both `ala.lint` and `ala.encode` pick it up with no flag.
`ala.encode` writes a parallel `.ala.md` tree a human completes; `ala.lint.encoding`
then checks that tree. It scores what the notation carries: R1 edge altitude, R4 `$`,
R5 `q`, R3 via `{app-literal?}`/`{app-literal}`/`{intrinsic-literal}` literal marks, and —
from marks the encoder **stamps** rather than asks a human to judge — R10 (`&entity`/
`&aggregate`), R11 (`(branches)` on an app-layer function), pass-throughs (`~>`), and
public surface (via `(private)`). R6/R7 stay unencodable; height and the R11 app-share
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
    {:app,     [~r/Web\./],                    peer_ok: true,  paths: [~r{/live/}]},
    {:feature, [],                             peer_ok: false, paths: [~r{/features/}], unit: ~r/(App\.\w+)/},
    {:domain,  [~r/App\.(Cart|Pricing)$/],     peer_ok: true},
    {:platform,[~r/Effects/, ~r/Foundation/]}
  ]
end
```

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
| **R1** peer coupling | with a layer map: **upward** and **cross-peer** edges on the function call graph (an edge that doesn't drop). Without one: module dependency **cycles** | **exact** |
| **R1-ref** template coupling | *advisory.* Peer/upward edges visible only in the module alias graph, not as a call — usually a cross-feature call inside a `~H` template (invisible to the AST). Reported to verify | advisory |
| **R2** shared mutable state | `:ets` / `:persistent_term` / `Agent` usage — a shared-state channel to confirm isn't a peer back-channel | advisory |
| **R3** baked calibration | "magic" numeric literals inside modules (hoist them to config/the composition) | heuristic |
| **R4** hidden state | the **process dictionary** (`Process.put/get`) — hidden state that should be a threaded value | **exact** |
| **R5** duplicated contracts | the same **identifier-like string** (`"item-removed"`, no whitespace, len 3–40) in ≥2 modules. Strings inside `~p`/`~H`/`~L` sigils are skipped — a `~p"/x"` verified route is compile-checked, not a silent contract | **exact** |
| **R6** nameability | meaningless function/module names, and functions that just wrap a primitive | heuristic |
| **R7** unearned abstractions | **dead** private functions, and trivial single-use one-liners with meaningless names. HEEx components (invoked as `<.name/>` in `~H`/`.heex`) and functions defined inside a `quote` block are recognised as *called* and never reported dead | heuristic, **advisory** |
| **R10** shared entity | a **feature-tier struct** read by ≥2 peer features — share an identity key, keep data private. Structs in a `peer_ok` (shareable) layer are exempt | heuristic |
| **R10-aggregate** shared aggregate | a struct in a **shareable** layer read by ≥2 features — a legitimate domain abstraction, or Clean's shared-Entity coupling? Only runs under `--strict`/`--super-strict` | strict-only, **advisory** |
| **R11** composition-only top layer | The application layer is a large share of the code (`--max-app-share`), or a top-layer function **branches** (all clauses checked). Aspirational purity: reported by default, scored only under `--super-strict` | advisory / super-strict |
| **module size** | *advisory.* A module over `--max-module-loc` (default 500) — an abstraction should be readable in isolation | metric, **advisory** |
| **height** proliferation | longest chain of hops *between abstractions*; calls within one module (internal decomposition of a little ball of mud) and within the app layer count as zero altitude, so only real drops between abstractions add depth. Warns past a ceiling (default 5) | metric, **advisory** |
| **passthrough** proliferation | a **public** function with 1 caller + 1 callee **in another module** whose body is a single delegating call — a rename over a different abstraction that hides no decision. Private helpers and same-module calls are internal decomposition and left alone; so are transforms (`sub(x) \|> Money.new()`, `%{s \| f: Callee.x()}`), predicate (`name?`) forwarders, HEEx components, and macro-generated defs | heuristic, **advisory** |
| **public surface** | a module exposing more than `--max-public-funs` (default 12) public functions — a wide surface leaks internals, so the little ball of mud is no longer encapsulated. Aspirational purity: reported by default, scored only under `--super-strict` | metric, advisory / super-strict |
| **layer cohesion** | *advisory metric.* Per layer, the share of its functions under one directory (Spray: directories separate layers). 100% = cohesive | metric, **advisory** |

### Strictness modes

- **default** — the *required* checks are scored (see below); everything else is advisory (reported).
- **`--strict`** — promotes the *obtainable* advisory checks (R7, module-size, height, pass-through,
  R1-reference) to scored, so genuine cruft can fail the build.
- **`--super-strict`** — `--strict`, and additionally scores the *aspirational-purity* checks: **R11**
  (no logic at the top / tight app-layer share), **public-surface** (keep the little ball of mud
  encapsulated behind a small API), and **R10-aggregate** (a shared domain aggregate). These are
  impractical to zero out in a real app and contested as metrics, so they are super-strict gates, not
  strict ones, while still being *reported* by default.

Pair any mode with `--min-score N` to gate CI at the strictness you want. The **required** (scored by
default) checks are **R1, R2, R3, R4, R5, R6, R10, and layer-validity**; the **advisory** ones are
**R7, module-size, abstraction-height, pass-through, R1-reference** (promoted by `--strict`), plus
**R11**, **public-surface**, and **R10-aggregate** (promoted only by `--super-strict`). R9 is partial (via R1 +
R1-reference); R8 is not checked (judgement).

**R7, R11, module-size, abstraction height, pass-through, and the reference-level R1 signal are
advisory** — reported but not folded into the score. Reuse is evidence not a requirement (Spray never
demanded a second caller), and a source-encoded app layer legitimately branches, so the tool won't
fail a build on these alone. Promote any to a hard failure with `--enforce r7` / `--enforce r11` /
`--enforce height` / etc. **R9** (ports carry paradigm-typed data; no abstraction names its own I/O)
is checked only in part, via R1 and the reference-level signal. **R8** (reads as the requirements) is
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

This counts each **function** at most once, so it can't be inflated by one function accruing many
findings. Findings that belong to no function — R1 cycles, R5 duplicated literals, and magic
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

```
── ALA Checklist (R1–R11) ─────────────────────────────────────────────
modules: 24   functions: 399   LOC: 6183
abstraction height: 9 call-levels (function graph)  ⚠ exceeds max 5
layer coverage: 303/399 functions assigned (76%)
  unassigned (worklist): App.Application, AppWeb.Telemetry, … +19 more
filesystem cohesion (advisory — Spray: dirs separate layers):
  feature    100% under `lib/app/features` (cohesive)
  domain      81% under `lib/app/domain` (scattered across 2 dirs)

Degree of function compliance: 92/100  (grade A)
  weighted violations: 30   violation load per 100 functions: 7.5
Count of compliant functions: 395 / 399  (99% → grade A)

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
