# 0013 — A coroutine is a value with its own stack, and a yield leaves the host stack

**Status:** accepted. The owner chose Lua 5.5's places a yield may pass, and a thread as a value on
the C stack rather than a second handle.

## Context

Lua's coroutines let a function suspend in the middle and continue later. The register VM
keeps a script frame's registers on the state's stack, but a native that calls back into the
VM (a `table.sort` comparator, a `string.gsub` callback, a host's function calling
`nilu_call`) is a call on the host's stack too, and so is each resume. A
suspended coroutine has to give the host's stack back and continue later, on every release
target, and the library is written against the C API
([0010](0010-the-library-is-written-against-the-c-api.md)).

## Decision

- **A coroutine is a value of type `thread`** with its own value stack, frames and open
  upvalues. The state runs one thread at a time. Resuming one swaps the state's stack, frames,
  open upvalues, failure record and execution chain for the coroutine's; finishing or yielding
  swaps them back. The main program is a thread too, so `coroutine.running()` can answer it.
- **A yield leaves the host's stack.** The library's `yield` returns a request; every level
  between it and the resume unwinds, and the coroutine's frames stay as they are, each script
  frame on the instruction it was executing. Resuming completes that instruction with the
  values given to `resume` and continues the frame with the same frame loop, then its caller,
  down to the coroutine's first function. There is no second evaluator
  ([0004](0004-one-pipeline-and-one-evaluator.md)).
- **Where a yield may pass is Lua 5.5's:** script calls, `for` iterators, `pcall` and
  `xpcall`, metamethods a script's instruction runs. A native that calls back into the VM
  through `nilu_call` or `nilu_pcall`, a message handler and a hook are boundaries: a yield
  under one is refused with Lua's `attempt to yield across a C-call boundary`. Outside a
  coroutine it is `attempt to yield from outside a coroutine`.
- **A protected call names what runs after it** (`nilu_pcallk`, Lua's `lua_pcallk`), so that
  the library's `pcall` and `xpcall`, written against the C API, let a yield pass: a resume
  continues the frames above it under the same protection and then runs the continuation with
  the status `nilu_pcall` would have answered.
- **The C API treats a thread as a value on the stack:** `nilu_newthread`, `nilu_resume`,
  `nilu_yield` (a C function suspends with `return nilu_yield(N, n)`), `nilu_pcallk`,
  `nilu_threadstatus`, `nilu_isyieldable`, `nilu_pushrunning` and `nilu_closethread`. There is
  no second `NiluState` handle.
- **What a thread keeps alive:** its stack, frames, failure record and the value it carries,
  the function it has not started yet, its message handlers waiting on a continuation, its
  values waiting to be closed and, while it waits on one it resumed, its execution chain. A
  running or normal thread also keeps the thread that resumed it, since the host may have
  consumed the only slot that held either. An open upvalue reaches the thread whose stack
  holds it, so a closure that escaped a suspended coroutine keeps the coroutine's stack
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)).
- **The call depth is counted across threads.** A resume nests on the host's stack, so the
  frames of every thread waiting on a resume count toward the same limit, and a chain of
  resumes too deep is `stack overflow` like any other.

## Why

- A thread with its own stack keeps the frame layout and the one frame loop; only where a
  frame's registers live changes.
- Unwinding and rebuilding needs nothing from the host's platform: no second host stack per
  coroutine, no assembly per target, no operating-system threads.
- A value on the stack keeps the C API's one handle and its index rules.

## Consequences

- An upvalue read checks whether its thread is the running one, and an open cell holds a
  pointer to its thread.
- A thread shares the tag `0xFFF9` with nil and the booleans ([0007](0007-a-value-is-eight-bytes.md)).
- C API: `NILU_TTHREAD`, the status `NILU_YIELD`, `NiluKFunction`, and the calls above.
- Library: `coroutine.create`, `resume`, `yield`, `status`, `wrap`, `isyieldable`, `running`
  and `close`, with Lua's sentences.

## What would reverse it

- A host that needs to suspend inside its own callbacks elsewhere than a protected call
  (`lua_callk`, `lua_yieldk`) would need more continuations in the C API.
- A measured cost of rebuilding deep frames on every resume would argue for a resume that does
  not nest on the host's stack.
