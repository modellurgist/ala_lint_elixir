# ALA development guide

Copy this file to your project root as `AGENTS.md` (Codex and most agents) or `CLAUDE.md`
(Claude Code). It tells a coding agent how to write and review code that conforms to Abstraction
Layered Architecture (ALA), using the [ALA Checklist](https://github.com/modellurgist/ala_checklist),
whether or not the `ala_lint` linter is installed. When the linter is available, run
`mix ala.lint --strict` and treat its findings as the mechanical half of this guide. When it is not,
apply the self-review at the bottom by hand. The checklist has the full rules, with the sections of
John Spray's book that support each one.

The rules below are language-agnostic. Notes marked "Elixir/Phoenix" apply when that is the stack.

## What ALA asks, in one paragraph

Organize code into layers ordered from concrete to abstract. Knowledge may only flow down: code in one
abstraction may use another abstraction only if that one is a significantly more general, more stable,
more reusable concept. The top layer is the application itself, the most concrete thing in the system,
and it gets more abstract as you go down. A call sideways (to a peer abstraction in the same layer) or
upward (to something more specific) is forbidden; calls inside one abstraction (a module and its private
helpers) are fine. When two parts need to interact, either push the shared thing down into a real
abstraction, or wire them together from the layer above. There are usually three or four layers.

## The four rules to hold in your head

Everything else refines these.

1. Knowledge flows down. Every dependency points at something more general and more stable. Never a
   peer, never something more specific.
2. A part knows one thing, and not who it talks to. Each module names a single concept and never names
   where its input comes from or where its output goes. The layer above does the connecting.
3. State lives with its owner, never underground. What a part remembers belongs to that part's concept
   (a filter's memory, a sampler's count). Callers may store an updated struct back without looking
   inside it, but never manage another concept's state, and nothing hides in a global, the process
   dictionary, or a shared mutable cell.
4. The top reads as the requirements. The application layer is wiring and configuration: it holds the
   product-specific knowledge and makes no decisions of its own.

## Before you write or change code

- Decide which layer the code belongs to:
  - **application:** the composition and entry points;
  - **feature:** one user-facing capability, wired by the application;
  - **domain:** reusable, product-free logic and UI components;
  - **programming paradigms:** generic machinery that runs a kind of connection, such as an effect
    interpreter, a runner, or a port protocol.

  Databases, HTTP clients and PubSub are technical domains reached sideways through an abstraction of
  them, not a bottom layer. If you can't name the layer, you don't yet understand the change.
- Check the direction of every call you are about to add. It must point down to something more general.
  If it points sideways or up, stop and rewire from above.
- Put any product-specific constant (a price, a threshold, a label, a route, message text) in the
  application layer, not in a domain or feature module.

Elixir/Phoenix: only page-specific code is application:
- the LiveView module;
- its HEEx template (whose nesting is the UI wiring);
- the router;
- components that know this page.

Generic function components are domain UI abstractions. A generic shell or effect interpreter goes in
the programming paradigms layer, below the page: it must not name any page. `Phoenix.LiveView` is itself
an execution model the page configures.

## The checklist, as coding directives

Each rule is a thing to do, a thing to avoid, and a question to ask yourself.

**R1. Every edge between abstractions drops to a lower layer.**
Do: call only downward, toward more general code. Route cross-feature work through the composition.
Avoid: a feature calling or importing a sibling feature; one domain abstraction calling another; a
lower module referencing an application module; a feature or domain module subscribing itself to a
topic it hardcodes (the composition subscribes, or passes the topic down). A function the composition
passes down is fine: that is how a lower module calls up.
Ask: is the callee more general and more stable than the caller? If not, this edge is wrong.

**R2. Wires meet only at the top.**
Do: let the composition hand each abstraction the values it needs. Give each feature its own private
state.
Avoid: two peers reading and writing the same mutable store, or both depending on the meaning of one
shared value that the composition didn't pass them.
Ask: could a change one part makes be silently seen by a peer? If yes, that is a hidden channel.
Elixir/Phoenix: no `:ets`, `Agent`, `:persistent_term`, or session slot shared across peers.
Immutability gives you most of this for free, so a violation is usually a deliberate shared cache.

**R3. Application literals live at the composition.**
Do: gather product-specific constants in the composition, or a config module it owns, and pass them
into the generic code below.
Avoid: a magic number, label, or message string baked into a domain or feature module.
Ask: would this literal change if the same code served a different product? If yes, it belongs at the
top. If it is intrinsic to the abstraction (an identity value, a unit conversion), it stays local.

**R4. State lives with its owner, not hidden.**
Do: keep state inside the abstraction whose concept it is. Give state that belongs to no concept its own
small abstraction, wired in.
Avoid: the caller keeping or computing another concept's raw state; state hidden in the process
dictionary, a global, or a process used as a back-channel.
Ask: whose concept is this state? Only that abstraction should read or change it.
Elixir/Phoenix: no `Process.put/get`. Returning an updated struct that the caller stores back is fine.
Use a process where the concept really is concurrent, not to organize code.

**R5. No silent contracts.**
Do: keep a shared name or format in the composition, which passes it to both ends as configuration. Or
make both ends two instances of one abstraction that owns the format (an encode/decode pair).
Avoid: a magic string, tuple shape, or key that one side produces and another parses, appearing in
neither signature; a module of names that several features use to agree with each other (a registry of
global names).
Ask: if I renamed this string, would something break with no compiler or test to catch it?
Elixir/Phoenix: a module of event, stream, and hook names is fine when only the page uses it (its HEEx,
handlers, and JS hooks). Don't have features read names from it to agree with each other.

**R6. Every abstraction names a learnable concept.**
Do: name a module or function for the one concept it is. Give each abstraction a short `@moduledoc`
naming the concept, its ports, and its configuration.
Avoid: a wrapper that only renames a primitive; a module that knows both the meaning of some data and an
operation on it.
Ask: "what do you know about?" The answer should be one thing. Can a reader use it without reading its
body?

**R7. Every abstraction earns its existence.**
Do: keep the least machinery that works. Prefer composing existing general parts over inventing new ones.
Avoid: a one-in, one-out function that adds a name and a call hop but hides no decision; a layer built
to hold a layer; modules averaging well under 100 lines, or one over 500.
Ask: if I inlined this, would anything be lost? Single use is fine when the thing names a real concept;
reuse is a positive, never a smell.

**R8. The composition reads as the requirements.**
Do: make the top layer legible enough that reading it tells you what the product does and how it is
configured.
Avoid: burying the product's behavior in scattered helpers so no single place states it.
Ask: can a new reader state the requirements after reading only the top layer?

**R9. Ports are typed by a programming paradigm; a module owns no interface except its own
configuration.**
Do: shape a module's ports by their kind (a transform, a filter, a store, a stream of results), not by
the product it serves. Put behaviours and protocols used as ports below both sides, in the programming
paradigms layer. Data on a port is a standard type, a struct from a lower layer, or a struct the
application defines and passes in.
Avoid: a `@callback` or protocol defined in a feature or domain module for its peers to implement or
call (implementing callbacks of a far more general module, like `GenServer`, is fine); a struct one
peer defines and another pattern-matches on (a data-transfer struct), even if moved to a shared
module; a "domain event" with product-specific keys another part must understand.
Ask: could this abstraction wire into a second, unrelated consumer unchanged?
Outputs: an output must never name its destination (a stream, a topic, message text), and should read
as a result ("this happened") rather than an operation ("do this next"). Any technique that meets this
is fine: facts the page maps, results on the feature's own ports that the page binds, or a target the
page passes in as configuration.
Ask: could the page send this output somewhere else without editing the feature?

**R10. No two features know the meaning of the same data.**
Do: keep each feature's data private to it. When features relate, use any technique that keeps their
data apart: share only an identity key, have the composition pass values in, or expose a projection
shaped for reading.
Avoid: two features holding, reading, or pattern-matching the same data struct.
Ask: could one feature change the shape of its data without editing another?

**R11. The application layer is composition only.**
Do: keep the top layer to instances, wiring, configuration, and predicates passed in as configuration.
Avoid: control flow that decides what runs, and assignments that compute data between calls.
Ask: which kind is this `if`?
- A guard ("only if there's a value", "stop on error") goes into the connection mechanism.
- A requirement condition becomes a configured abstraction or a predicate passed in.
- Something that depends on history becomes a state machine.
- An outcome route becomes two output ports.
- Ordering becomes explicit fan-out.

Elixir/Phoenix:
- Multi-clause `handle_event`/`handle_info` heads that forward to features are routing, which is fine.
- Guards become `with` or a runner that stops on nothing-to-pass.
- Arithmetic and compound conditions move into a feature, and the page assigns or displays the result.
- A `for` over rows in the page template becomes a generic list or table component.
- `connected?/1` and auth redirects are framework departures to keep small; auth can move to an
  `on_mount` hook.

## Techniques to reach for

When a rule is hard to hold, these are standard moves. None is required; the rules are the properties.

- **Results as data, interpreted below the page.** A feature returns descriptions of what happened, and
  a generic interpreter in the paradigms layer carries them out. It keeps features pure and the page
  thin (R4, R11). Its outputs must still not name their destination (R9).
- **Private struct per feature.** Each feature owns a struct no other feature reads (R10, R2).
- **A calibration module at the top.** One place holds the product's constants; the composition reads
  it and passes values down into generic code (R3).
- **Build, then run.** The composition builds a description of the program (configured stages and how
  they connect), and a generic runner moves the data. The page holds one opaque program value and never
  names the data in between.
- **A layer map, even informal.** Write down which modules are application, feature, domain, and
  paradigms. It is the first real act of ALA and makes R1 checkable by eye.
- **Test through ports.** A test never replaces a knowledge dependency. Give the subject a fake instance
  or function on its port. A Mox mock of a paradigm-layer behaviour is a fake port and is fine; a mock of
  a lower-layer module the subject calls by name is not.

## Self-review before you finish (do this when the linter is absent)

Read your diff and answer honestly:

1. Does every new call point downward to something more general? (R1)
2. Is any product constant or message text sitting below the top layer? (R3)
3. Is any state hidden in a process, global, or shared mutable, or managed by something that doesn't
   own it? (R2, R4)
4. Is there a magic string or shape two modules agree on silently? (R5)
5. Does any new module just wrap or rename something, earning no concept? (R6, R7)
6. Does any output name its destination, or any `@callback` or struct get defined for a peer? (R9)
7. Do two features now share a data struct? (R10)
8. Did the top layer gain a decision or a computation rather than wiring? (R11)
9. Does any test replace a module the subject depends on for its meaning? (tests)
10. Read the top layer alone: does it state what the product does? (R8)

Any "yes" to 2 through 9, or "no" to 1 or 10, is a defect to fix before finishing, not a note for later.

## What stays a human judgment

These are judgments a tool can't settle, and neither can an agent alone:
- R6 (is this a real concept);
- R8 (does it read as the requirements);
- the R3 call between an application literal and an intrinsic one;
- whether an output reads as a result (R9);
- whether a shared lower-layer struct is a real domain abstraction (R10).

When unsure, state the tradeoff to the developer rather than guessing.
