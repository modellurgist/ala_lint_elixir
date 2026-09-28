# Agent demo: code written from the AGENTS guide alone

`vending_machine.ex` in this directory was written by a coding agent whose only design input was
an earlier version of [`../AGENTS.example.md`](../AGENTS.example.md). The guide has since been revised
to follow the revised ALA Checklist, so the demo reflects the older guide; the code is kept as it was
produced. The agent was given a fresh context, told to read that
one file and nothing else in the repository, and asked for a self-contained Elixir vending machine of
roughly 80 to 130 lines (coins, product selection, dispense, greedy change, refund, configuration at
the top). No linter was available to it while writing. The file compiles and runs with
`elixir vending_machine.ex`.

This is a rough test of one question: does following the guide's directives steer an agent toward ALA
shape, rather than away from it?

## What it produced

Three modules mapped straight to the guide's layers:

- `VendingMachine.Change` (domain): pure greedy coin selection over a float map, with no knowledge of
  products or prices. It would serve any coin-based system unchanged.
- `VendingMachine.Session` (feature): a struct passed through every call and returned, never hidden.
  Each transaction step calls down only to `Change` and returns a tagged tuple as data
  (`{:dispensed, name, coins}`, `{:insufficient_funds, cents}`), never printing or raising.
- `VendingMachine` (application): holds `@products`, `@initial_stock`, `@initial_float` as the only
  literals in the file, and `run/0` sequences `Session` calls and formats their results.

## How it scored

Re-scored 2026-09-28 with the current linter, using a layer map of `VendingMachine` (application),
`VendingMachine.Session` (feature), and `VendingMachine.Change` (domain):

```
layer-aware    89/B    R1 up=0 peer=0    coverage 100%    height 3
--strict       89/B    no advisories
--super-strict 89/B    R11 = 0 (no top-layer logic)
layer-blind    42/D    misleading, see below
```

A doc-only guide steered a cold agent to 89/B with perfectly clean altitude. That is the useful
result. (When first scored, `--strict` gave 79/B, from a height of 6 and one pass-through. Both were
linter artefacts, since fixed: height no longer counts calls inside one module, and a struct update is
no longer mistaken for a pass-through.)

## Honest reading

- **The layer-blind 42/D is not a real failure.** Blind mode cannot know `VendingMachine` is the top,
  so it flags all eleven configuration literals as misplaced. Declaring layers (which the guide tells
  you to do) turns the same code into 89/B. This is the guide's own point: the layer map is the first
  real act of ALA.
- **The remaining R3:2 is a judgment call, not a miss.** It flags `@denominations [25, 10, 5]` in
  `Change`. Whether coin denominations are an application literal to hoist or intrinsic to a change
  abstraction is defensible either way, and the guide explicitly says this is a call only a reader
  makes. The agent kept them local.
- **A silent contract the linter misses.** `Session.insert_coin/2` guards with
  `when coin in [5, 10, 25]`, the same denominations `Change` holds. Two modules agree on the valid
  coins without either signature showing it (R5), and the literals sit in a feature (R3). The linter
  doesn't see it because it doesn't collect literals from function heads. Under the revised guide the
  fix is for `Session` to ask `Change` (a lower layer) whether a coin is valid, or to take the
  denominations as configuration from the application.

## Caveats

This is not a perfectly clean experiment. The agent is a capable model with its own taste, so the pure
functions and pattern matching are idiomatic Elixir it would write regardless. What the guide
demonstrably added was the layer split with configuration at the top, and the effects-as-data choice
the agent explicitly credited (it dropped an instinct to print or raise inside the transaction logic).
A weaker model, or the same task with no guide, would more likely have put prices in the domain module
and printed from inside the logic.
