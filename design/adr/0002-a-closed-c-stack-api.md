# 0002 — A closed C stack API

**Status:** accepted. The thread rule and the hook's re-entry rules are the owner's decisions.

## Context

A host program written in C has to create a Nilu state, hand it source, call functions in
both directions and read values back. Whatever crosses that line is a promise: once a host
is linked against it, renaming a function or changing its signature breaks that host.

Lua's C API solves the same problem with a stack. C never holds a Lua value, only an index
into a stack the interpreter owns. That shape has been used for decades by people who are not
Lua's authors, so its corners are known.

## Decision

- **One header, `include/nilu.h`, is the whole surface.** A host includes it and links the
  library; nothing else is promised.
- **The state is opaque.** `NiluState` is declared and never defined for C. It is created
  with `nilu_new`, or with `nilu_newstate` and an allocator the host supplies, and released
  with `nilu_close`.
- **C holds no Nilu value, only stack indices,** as in Lua: `1` is the bottom of what the
  current call can see, a negative index counts from the top, and `0` is never a valid index.
  The registry is reached through `nilu_ref` and a C closure's values through
  `nilu_getupvalue`; Nilu has no pseudo-indices, a mechanism it lacks
  ([13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs)).
- **Names are Lua's where the function does what Lua's does,** spelled with the `nilu_`
  prefix (`nilu_pushinteger` for `lua_pushinteger`, `nilu_settop` for `lua_settop`). Some
  take a different shape — `nilu_getupvalue` and `nilu_setupvalue` name the values of the C
  closure that is running, by number. The header documents each function's answer.
- **Most functions answer a status.** A push, a table access and a call return `NILU_OK` or a
  named failure. Nilu's API raises nothing across the boundary; a failure is told through the
  return value. A host's own function signals failure by returning `NILU_FAIL`, and
  `nilu_error` is how it passes on the value it pushed
  ([0009](0009-a-failure-is-a-status-and-one-value.md)).
- **As far as it can, a failure is not reported through a value that could have been an
  answer.** Where a read can fail, an out-parameter or a value outside the domain says so
  (`isnum` for `nilu_tointegerx`, `NILU_TNONE` for `nilu_type`). Where a function cannot keep
  to this, the header says so.
- **A condition a correct host can never meet aborts, with a message naming the function
  written to standard error** — a `NULL` state, or an index naming no slot where the function
  needs a value. A status a host can ignore is worse than a stop it cannot. The header
  documents which conditions each function answers and which abort.
- **One state is used by one thread at a time; different states may run on different threads
  at once.** The library does not serialise access to a state, and using one state from two
  threads at once is undefined. A native function or a hook that runs the state again does so
  on the same thread; it does not let another thread in. An allocator a host gives
  `nilu_newstate` must be safe for the states that use it.
- **A host stops a program with a hook** (`nilu_sethook`), called every so many instructions.
  The hook may run the same state again; the calls it makes count toward the ordinary call
  limit, which alone bounds re-entry. When the hook interrupts an inner call, the callback's own
  return decides for the outer call, and an interruption reaches the host's call whatever a C
  function in between does. A `nilu_sethook` made inside a callback applies to the whole state
  at once. `pcall` does not catch an interruption
  ([0009](0009-a-failure-is-a-status-and-one-value.md)).
- **There is no light userdata;** a host's data goes in a full userdata
  ([13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs)).
- **The type tags' numbers are Nilu's own.** `NILU_TNONE`'s idea is borrowed from Lua's
  `LUA_TNONE`; the numbers are not.

[12.2](../../doc/en/12-embedding.md#122-the-stack) and
[12.3](../../doc/en/12-embedding.md#123-almost-every-function-answers-a-status) of the manual show
the stack and the statuses in use.

## Why

- A stack keeps every value inside the state, where the collector can see it
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)).
  A pointer held by C would be invisible to it.
- Borrowing Lua's shape and names means a host author who knows Lua already knows most of
  Nilu's API. A borrowed name whose shape differs silently — a 0-based index, different
  arguments with nothing said — would be worse than not borrowing it.
- A push can be refused — the state is out of memory, or the stack is at its limit. Lua's API
  raises an error when memory runs out and leaves stack room to the host, who asks for it
  beforehand with `lua_checkstack`. Nilu's C API raises nothing across the boundary and has no
  `lua_checkstack`, so both outcomes come back as a status. A refused push that said nothing would be
  indistinguishable from one that was never made.
- Aborting on a host's bug, rather than answering, keeps a wrong program from running on with
  a value that only looks like an answer.
- A lock in every state would cost every host for the few that share one; a host that moves
  a state between threads knows when it does, and can coordinate.

## Consequences

- Every exported symbol is a promise. Renaming one, or changing its signature, breaks every
  host linked against it, and moves the version number accordingly
  ([0011](0011-the-version-number.md)).
- A host must check statuses. A status ignored is a failure that goes unnoticed.
- A host's callbacks and resources shared between states need their own synchronisation.
- That two states share nothing rests on a review of the core's source, which found no mutable
  global or thread-local state outside the tests, and on a test that runs a state on each of
  two threads. Neither shows every schedule or every host callback.
- Differences from Lua's C API follow from this record, and
  [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) lists them. What Lua's API
  has and Nilu's does not is listed in [12.8](../../doc/en/12-embedding.md#128-what-is-absent).

## What would reverse it

- A host that cannot live with a stack — one that needs to hold values directly. That would
  mean a second kind of reference into the state, and the collector would have to know it.
- An error that the C API raises instead of returning. Then returning a status from every
  push would be the odd one out, and the pushes would be revisited together.
