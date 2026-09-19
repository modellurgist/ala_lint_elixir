# ALA development guide

Copy this file to your project root as `AGENTS.md` (Codex and most agents) or `CLAUDE.md`
(Claude Code). It tells a coding agent how to write and review code that conforms to Abstraction
Layered Architecture (ALA), using the ALA Checklist, whether or not the `ala_lint` linter is
installed. When the linter is available, run `mix ala.lint --strict` and treat its findings as the
mechanical half of this guide. When it is not, apply the self-review at the bottom by hand.

The rules below are language-agnostic. Notes marked "Elixir/Phoenix" apply when that is the stack.

## What ALA asks, in one paragraph

Organize code into layers ordered from concrete to abstract. Knowledge may only flow down: a function
may call another function only if the callee is a more general, more stable, more reusable concept than
the caller. The top layer is the application itself, the most concrete thing in the system, and it gets
more abstract as you go down. A call sideways (to a peer at the same altitude) or upward (to something
more specific) is forbidden. When two parts need to interact, either push the shared thing down into a
real abstraction, or wire them together from the layer above. There are usually two or three layers,
rarely four.

## The four rules to hold in your head

Everything else refines these.

1. Knowledge flows down. Every dependency points at something more general and more stable. Never a
   peer, never something more specific.
2. A part knows one thing, and not who it talks to. Each module names a single concept and never names
   where its input comes from or where its output goes. The layer above does the connecting.
3. State travels on a wire, not underground. Whatever a part remembers comes in as an argument and goes
   out as a return value, in the open. Nothing hides in a global, a process, or a shared mutable cell.
4. The top reads as the requirements. The application layer is wiring and configuration, nothing else.
   It holds the product-specific knowledge and no real logic.

## Before you write or change code

- Decide which layer the code belongs to: application (the composition and entry points), feature (one
  user-facing capability), domain (reusable, product-free logic), or platform (persistence, gateways,
  I/O). If you cannot name the layer, you do not yet understand the change.
- Check the direction of every call you are about to add. It must point down to something more general.
  If it points sideways or up, stop and rewire from above.
- Put any product-specific constant (a price, a threshold, a label, a route) in the application layer,
  not in a domain or feature module.

## The checklist, as coding directives

Each rule is a thing to do, a thing to avoid, and a question to ask yourself.

**R1. Every edge drops.**
Do: call only downward, toward more general code. Route cross-feature work through the composition.
Avoid: a feature calling or importing a sibling feature; a lower module referencing an application
module.
Ask: is the callee more general and more stable than the caller? If not, this edge is wrong.

**R2. No shared mutable state between peers.**
Do: give each feature its own private state. Pass values, do not share references.
Avoid: two features reading and writing the same mutable store, global, or shared struct field.
Ask: could a change one part makes be silently seen by a peer? If yes, that is a hidden channel.
Elixir/Phoenix: no `:ets`, `Agent`, or `:persistent_term` shared across peers; immutability gives you
most of this for free, so a violation here is almost always a deliberate shared cache.

**R3. Application literals live at the composition.**
Do: gather product-specific constants in one module or attribute at the top, and pass them into the
generic code below as arguments.
Avoid: a magic number or string baked into a domain or feature module.
Ask: would this literal change if the same code served a different product? If yes, it belongs at the
top. If it is a mathematical or physical constant intrinsic to the abstraction (an identity value, a
unit conversion), it correctly stays local.

**R4. State is threaded, not hidden.**
Do: take state as an argument, return the new state.
Avoid: stashing state in a process, a global, a singleton, or a module-level mutable.
Ask: can I see this state move through the function signatures? If it is invisible, expose it.
Elixir/Phoenix: no `Process.put/get`, no GenServer holding feature state that a pure function could
thread. LiveView `assigns` is the one legitimate top-level state holder.

**R5. No silent contracts.**
Do: make agreements explicit. Use a typed value or a single shared constant that both ends depend on.
Avoid: a magic string, tuple shape, or key that one side produces and another parses, appearing in
neither signature.
Ask: if I renamed this string, would something break with no compiler or test to catch it? If yes,
single-source it.
Elixir/Phoenix: define event, topic, and stream names in one module, not as literals in templates and
handlers. Prefer a typed struct over a bare tagged tuple when the shape crosses a module boundary.

**R6. Every abstraction names a learnable concept.**
Do: name a module or function for the one concept it is, so a reader learns it once and reuses it.
Avoid: a wrapper that only renames a primitive, or a name that describes its caller rather than itself.
Ask: can I say what this is in one sentence without mentioning who uses it? If not, it is not an
abstraction yet.

**R7. Every abstraction earns its existence.**
Do: keep the least machinery that works. Prefer composing existing general parts over inventing new ones.
Avoid: a one-in, one-out function that adds a name and a call hop but hides no decision; a layer built
to hold a layer.
Ask: if I inlined this, would anything be lost? If nothing, inline it. Single use is fine when the thing
names a real concept; reuse is a positive, never a smell.

**R8. The composition reads as the requirements.**
Do: make the top layer legible enough that reading it tells you what the product does and how it is
configured.
Avoid: burying the product's behavior in scattered helpers so no single place states it.
Ask: can a new reader state the requirements after reading only the top layer? That is the target.

**R9. Ports carry paradigm-typed data, not domain identities.**
Do: shape a module's interface by its kind (a transform, a filter, a store, an instruction to the
shell), not by the product it serves.
Avoid: a port that names your domain, or a "domain event" with product-specific keys another part must
understand.
Ask: could this abstraction wire into a second, unrelated consumer unchanged? If a port mentions your
domain, it cannot.
Elixir/Phoenix: return outcomes or effects as paradigm-level instructions (insert into a stream, show a
flash, start a timer), not cart-specific or user-specific events.

**R10. No shared entity.**
Do: give each feature its own private data. When features relate, share only an identity key.
Avoid: two features holding or reading the same data struct.
Ask: do two peers depend on the shape of one common record? If yes, split it, and let each keep private
data behind a shared id.

**R11. The application layer is composition only.**
Do: keep the top layer to wiring and configuration. Push decisions and computation down into features
and domain.
Avoid: real logic in the composition beyond sequencing and threading.
Ask: is this branch sequencing work (fine) or computing a result (move it down)?
Elixir/Phoenix: a LiveView `handle_event` or `mount` will branch by nature; that is acceptable. What
should move down is a branch that computes a domain result rather than dispatching one.

## Techniques to reach for

When a rule is hard to hold, these are the standard moves:

- **Effects as data.** A feature returns a list of descriptions of what should happen, and a thin edge
  interprets them. Keeps features pure (R4), keeps the top as wiring (R11), and keeps ports paradigm-
  typed (R9). Use typed values for these when they cross a boundary (R5, R9).
- **Private struct per feature.** Each feature owns a struct no other feature reads. Satisfies R10 and
  R2 by construction.
- **A calibration module at the top.** One place holds the product's constants; the composition reads
  it and passes values down into generic code. Satisfies R3 and keeps the domain reusable.
- **A single-source module for a contract.** A shared name or key lives in one module both ends depend
  on downward, rather than as a literal in two places. Satisfies R5.
- **A layer map, even informal.** Write down which modules are application, feature, domain, platform.
  It is the first real act of ALA and makes R1 checkable by eye.

## Self-review before you finish (do this when the linter is absent)

Read your diff and answer honestly:

1. Does every new call point downward to something more general? (R1)
2. Is any product constant sitting below the top layer? (R3)
3. Is any state hidden in a process, global, or shared mutable? (R2, R4)
4. Is there a magic string or shape two modules agree on silently? (R5)
5. Does any new module just wrap or rename something, earning no concept? (R6, R7)
6. Do two features now share a data struct rather than an id? (R10)
7. Did the top layer gain real logic rather than wiring? (R11)
8. Read the top layer alone: does it state what the product does? (R8)

Any "yes" to 2 through 7, or "no" to 1 or 8, is a defect to fix before finishing, not a note for later.

## What stays a human judgment

R6 (is this a real concept), R8 (does it read as the requirements), and the R3 call between an
application literal and an intrinsic one are judgments a tool cannot settle and neither can an agent
alone. When unsure, state the tradeoff to the developer rather than guessing.
