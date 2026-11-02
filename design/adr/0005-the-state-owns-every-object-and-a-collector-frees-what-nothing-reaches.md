# 0005 — The state owns every object, and a collector frees what nothing reaches

**Status:** accepted. The owner chose weak tables without finalisers, and chose not to clear
registers on every call, for speed.

## Context

Strings, tables, functions, threads and userdata outlive the expression that made them, refer
to each other, and form cycles. Something has to decide when each can be freed. In an embedded
language that decision also has to be invisible to the host: a host cannot be asked to track
which of the script's values are still in use.

## Decision

- **The state owns every object.** Strings, tables, closures, C closures, the cells that hold
  shared upvalues, threads, boxed integers, userdata and the records of published failures
  ([0009](0009-a-failure-is-a-status-and-one-value.md)) are all allocated by the state and
  freed by it; `nilu_close` frees whatever is left. A host never frees a Nilu object.
- **A mark-and-sweep collector that moves nothing frees what nothing can reach.** It marks from
  a fixed set of roots and frees every object it did not mark. How it limits a collection to
  the new objects is [0006](0006-a-young-collection-marks-only-what-is-new-or-written.md).
- **The roots are:**
  - the values on the running thread's stack up to its length, and the failure origins of
    those slots; another thread's stack is reached through its thread object
    ([0013](0013-a-coroutine-is-a-value-with-its-own-stack.md));
  - the function of every frame, and the closure being run — which a tail call can leave in
    no stack slot;
  - the global environment, the registry, the reader and the writer
    ([0003](0003-the-core-touches-nothing-outside-itself.md)) and the strings' metatable;
  - the failure being carried and the execution chain of the running calls
    ([0009](0009-a-failure-is-a-status-and-one-value.md)), the message handlers waiting on a
    continuation, and the values waiting to be closed;
  - the main thread and the running thread
    ([0013](0013-a-coroutine-is-a-value-with-its-own-stack.md));
  - the strings that name the metamethods, the prepared sentences of a memory failure and of a
    failing handler, and every prototype with its constants and the keys its field caches
    hold.
- **A register keeps its value until it is written.** A call does not clear its callee's
  registers, a return does not clear its caller's, and the compiler emits no clear when it
  gives a temporary back. The compiler never reads a register before writing it. Every slot
  of a stack between its length and its capacity holds nil or a value the collector has not
  freed: growing a stack fills the new room with nil, and every collection clears what is past
  each stack's length before it marks.
- **A weak table lets go of what only it holds.** A table whose metatable holds `__mode` (read
  raw, as a string, at each collection) is weak: with `k` in it its keys, with `v` its values.
  A weak value that nothing else reaches becomes nil, and its key stays, as after an
  assignment of nil, so a traversal in progress goes on. A weak key keeps its
  value only while the key is reached from elsewhere (an ephemeron), and when the key goes the
  entry goes. Strings, numbers and booleans are never removed. The weak tables met while
  marking are chained through the tables themselves, so the collection allocates nothing.
- **A collection happens only between two VM instructions, once the number of objects has
  doubled since the last collection** (and is past 64), or when a program or host asks for one
  (`collectgarbage`, `nilu_gc`). `collectgarbage("stop")` and `"restart"`, and `nilu_gc` with
  `NILU_GCSTOP` and `NILU_GCRESTART`, stop and restart the automatic ones. A C API call that runs Nilu code — a call, or a table
  access that reaches a metamethod — can therefore collect; one that runs none cannot. A value
  a host has on the stack is always a root, so it is never freed under the host.
- **A userdata owns its own bytes and its user values, and nothing else.** It has a metatable
  of its own and no finaliser. A resource outside the block — a file descriptor, a handle — is
  released by the host, explicitly. A table's `__gc` is not read.

The manual's [chapter 9](../../doc/en/09-gc.md) shows what owns memory and when a collection
happens.

## Why

- One owner for everything means one place that decides lifetime, and no reference a host
  could leave dangling.
- Mark and sweep handles cycles, which a table pointing at itself makes trivial to create.
- Collecting only between instructions is the one point where every live value is known to be
  in a root — on the stack, in a register, in an upvalue — so nothing half-built can be freed.
- The root set is the decision that matters. Getting it wrong frees something that is still in
  use, and nothing else in the implementation can catch that. That is why it is stated here
  and why changing it needs its own decision.
- Clearing registers on every call and return was work Lua does not do. Leaving them was
  measured on 2026-11-01, with `tools/speed.mjs` over ReleaseFast builds (Zig 0.17.0) in four code
  layouts (see `tools/README.md`), against clearing them, on an AMD Ryzen 7 5700X:
  the call-heavy scripts in `bench/` ran in 0.94 to 0.96 of the cycles and the loop scripts in
  0.89 to 0.97, and none slower. The manual never promised when a value a register no longer
  uses goes.
- Caches and back-references keyed by objects are what weak tables are for; without them a
  program frees by hand or leaks. Ephemerons are Lua's answer, and the one that does not leak a
  cycle through a value that refers to its own key.
- A finaliser would run code in the middle of a collection, and would need a list of objects
  to finalise, an order and a rule for resurrection.

## Consequences

- A host that only pushes values and never runs Nilu code never sees a collection.
- A pointer the C API hands out has a stated lifetime: a string's bytes while the value is on
  the stack, a userdata's block while the userdata is reachable. The header states each.
- A value can outlive its last use by as long as its register is not reused; a weak table may
  keep such an entry until then.
- A `-Dpoison-registers` build fills the registers the VM regrows, and the compiler's
  given-back temporaries, with a number no script makes, so a read before a write changes an
  answer: the check for the compiler's promise.
- Compared with Lua 5.5, leaving out finalisers is a decision
  ([13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs)), and `nilu_setmetatable`
  refuses a userdata's metatable that carries `__gc`. Strings are not interned — equal strings
  are compared by their bytes.

## What would reverse it

- A root this record omits, or one it lists that the collector does not mark. That is a bug in
  one of them, and the collector is the one that frees memory — so the code is read first and
  this record corrected to it.
- A host that needs to release an outside resource when a value becomes unreachable. That is
  the argument for a finaliser, and it would bring a new stage into the collector.
