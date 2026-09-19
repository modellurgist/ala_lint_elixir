# Agent demo: code written from the AGENTS guide alone

`vending_machine.ex` in this directory was written by a coding agent whose only design input was
[`../AGENTS.example.md`](../AGENTS.example.md). The agent was given a fresh context, told to read that
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
- `VendingMachine.Session` (feature): a struct threaded through every call and returned, never hidden.
  Each transaction step calls down only to `Change` and returns a tagged tuple as data
  (`{:dispensed, name, coins}`, `{:insufficient_funds, cents}`), never printing or raising.
- `VendingMachine` (application): holds `@products`, `@initial_stock`, `@initial_float` as the only
  literals in the file, and `run/0` sequences `Session` calls and formats their results.

## How it scored

Run from the linter's directory:

```
layer-aware   89/B    R1 up=0 peer=0    coverage 100%    height 6
--strict      79/B    + height, + one pass-through
--super-strict 79/B   R11 = 0 (no top-layer logic)
layer-blind   42/D    misleading, see below
```

A doc-only guide steered a cold agent to 89/B with perfectly clean altitude. That is the useful
result.

## Honest reading

- **The layer-blind 42/D is not a real failure.** Blind mode cannot know `VendingMachine` is the top,
  so it flags all eleven configuration literals as misplaced. Declaring layers (which the guide tells
  you to do) turns the same code into 89/B. This is the guide's own point: the layer map is the first
  real act of ALA.
- **The remaining R3:2 is a judgment call, not a miss.** It flags `@denominations [25, 10, 5]` in
  `Change`. Whether coin denominations are an application literal to hoist or intrinsic to a change
  abstraction is defensible either way, and the guide explicitly says this is a call only a reader
  makes. The agent kept them local.
- **The one pass-through flag is a linter false positive that this demo flushed out.** `insert_coin`
  is `%{session | credit: ..., float: Change.add_coin(...)}`, a struct update that changes two fields,
  not a bare rename. The pass-through detector does not yet exempt a struct- or map-construction body
  that merely contains a call. So the code is slightly cleaner than the score shows.

## Caveats

This is not a perfectly clean experiment. The agent is a capable model with its own taste, so the pure
functions and pattern matching are idiomatic Elixir it would write regardless. What the guide
demonstrably added was the layer split with configuration at the top, and the effects-as-data choice
the agent explicitly credited (it dropped an instinct to print or raise inside the transaction logic).
A weaker model, or the same task with no guide, would more likely have put prices in the domain module
and printed from inside the logic.
