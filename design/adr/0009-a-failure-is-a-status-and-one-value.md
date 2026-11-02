# 0009 — A failure is a status and one value

**Status:** accepted. The owner approved keeping a failure record per execution context, and
decided that a relayed failure keeps its kind and a new one is a runtime failure, the call
margin a handler gets, and that a script's call of a script function is not an entry of its own. The reserved origin and the `pcall` path were decided under the
owner's allowance for design changes made for speed.

## Context

A failure has two audiences. The host needs to branch on it: did this work, and if not, what
kind of thing went wrong. A person needs to read it: what happened, where, and what to do. A
script that catches a failure needs to get at what was raised.

Lua answers a failure with a status and an error object on the stack. The object is usually a
string — the chunk's name, a line and a sentence — but `error` can raise any value.

## Decision

### What a host and a program see

- **A status says what kind of failure it was, and carries no words.** `NILU_ERR_RUNTIME`,
  `NILU_ERR_TYPE`, `NILU_ERR_SYNTAX`, `NILU_ERR_MEMORY` and the rest are numbers a host branches
  on. `nilu.h` lists them.
- **The words are a value.** After a failed call or load, the value the failure carries is
  usually left on the stack — for a failure the VM or the library raised, a sentence, often
  with the chunk's name and the line; for `error`, whatever value it was given
  ([8](../../doc/en/08-failure.md), [12.3](../../doc/en/12-embedding.md#123-almost-every-function-answers-a-status)).
  A few failures leave nothing: a load that runs out of memory, a call or push refused at the
  stack's limit, and a syntax error whose message could not be put on the stack.
- **The sentences are Lua's where Lua has one,** including `bad argument #n to 'name'` for a
  library refusal and the variable a failure was about, as in `(local 't')`. A syntax error
  adds a column to Lua's line.
- **A failure passes up until something stops it.** `nilu_call` returns the status and leaves
  the failure travelling; a host's function that gets one returns `NILU_FAIL` in turn, with
  `nilu_error` to pass the value on. `nilu_pcall` is where a failure stops — the library's
  `pcall` and `xpcall` are built on it.
- **A relayed failure keeps its kind; a new one is a runtime failure.** A host's function that
  passes on, with `nilu_error`, the value an inner failure left keeps that failure's status
  and position, even through copies on the C stack. A value it builds itself, even with the
  same words, is a new runtime failure, and so is a bare `NILU_FAIL`. Where a value came from
  is kept beside the stack, never in the value: copying, duplicating and rotating a slot keep
  it; popping, overwriting or reusing the slot drops it; and storing the value in a table and
  reading it back, or catching it with `pcall` and raising it again, makes a new failure. An
  ordinary result of a call that succeeded is not a relay. `nilu_error` with an empty stack is
  a host's bug. No comparison of values or words decides a status.
- **A message handler runs once, where the failure was raised, before anything unwinds.** It
  does not run when the state has run out of memory in the VM, when the host's hook stopped the
  program, or when the handler itself fails; a handler that fails, or runs out of room, gives
  `error in error handling` at the original position. A handler's change keeps the original
  failure's kind and position. A handler sees only the failures no inner `pcall` caught: an
  `xpcall` handler does not run for a failure a `pcall` inside it stopped.
- **Calls are counted, and a handler gets a little more room.**
  - At most 200 calls of script, native and C functions stand at once; a deeper one is
    `stack overflow`. A script's tail call takes no frame.
  - While a handler runs, everything it calls in the same state shares a limit of 220, so a
    failure at the 200th call can still be explained before unwinding.
  - A nested `pcall`, a new handler or a caught failure does not renew that room, and an inner
    protected call still sees the outer handler's limit. Leaving the handler restores 200, and
    another state gets no part of it.
  - The stack's capacity for values is a separate limit, and neither limit promises that a
    program ends.
- **A host's bug is not a status.** A condition a correct host cannot meet aborts with a message
  naming the function ([0002](0002-a-closed-c-stack-api.md)).

### How the core keeps it

- **A failure is a record, not a shared value.** The record holds the kind, the value, the
  instruction it came from and where it came from. Every entry into execution from the host or
  from a native function has a context that keeps the caller's record aside while the callee
  runs: a callee that succeeds leaves the caller's record as it found it, and one that fails
  leaves its record for the caller to pass on. A call from the host that succeeds clears what
  earlier calls left. When a native function catches a failure and then returns successfully,
  that failure is discarded. Having no record differs from an interruption, which has a record
  whose value is nil. The collector traces every record along the
  chain of contexts.
- **A failing call unwinds in one way.** Each call records the stack base and frame count it
  started from — its window; a failure closes the captured slots and to-be-closed variables above
  it and cuts the stack and frames back to it.
- **Publishing a failure allocates nothing.** The origin a failure needs is reserved before a
  call runs, and handed to the collector only when a failure places it; one never published is
  kept for the next call. A memory failure carries a sentence prepared when the state was made.
- **A script's `pcall` of a script function runs among the script's frames.** When a script
  calls the library's `pcall` with a counted list of arguments, a script function first and no
  failure held, the call's frame is marked as a protected call and the function runs above it
  as a script call does. A failure that reaches the mark is caught there as the library's
  `pcall` catches it, and no handler runs; an interruption, a yield and the core's internal
  refusals pass the mark, as they pass the library's `pcall`. Call depth, `nilu_where` levels
  and a traceback are the same either way.
- **Every other way of calling `pcall` runs the library's C function:** from C, as a tail call,
  with open arguments, with a C function or a callable value as the callee, or while a failure
  is held.

[Chapter 8](../../doc/en/08-failure.md) shows failure from a script's side, and
[12.3](../../doc/en/12-embedding.md#123-almost-every-function-answers-a-status) from a host's.

## Why

- Keeping the status free of words means a host can branch without parsing a sentence, and the
  sentence can be as specific as it needs to be without changing what a host compares against.
- Making the words a value means a script catches exactly what was raised, and a host and a
  script see the same thing.
- Lua's sentences are already known to anyone who has read a Lua error. Borrowing them means a
  reader recognises the failure, and the differences are few enough to list.
- Running the handler before the unwinding is where Lua runs it. What the position buys is that
  a handler the host writes can walk the frames that failed with `nilu_where`
  ([12.5.1](../../doc/en/12-embedding.md#1251-seeing-where-it-failed)).
- A record per context means a nested call that succeeds cannot erase what its caller was
  carrying, and a failure saved where the collector cannot see it cannot be freed under it.
- An origin allocated as an object on every call would make each `pcall` allocate. Measured
  on 2026-11-02 on an AMD Ryzen 7 5700X with `tools/speed.mjs --runs=3` over ReleaseFast builds
  (Zig 0.17.0) in four code layouts
  (see `tools/README.md`), on `bench/pcall.nilu`: keeping the origin until it is published ran
  in 0.840 of the cycles of allocating one per call (0.769 to 0.875 across the layouts), and then running a script's
  `pcall` among the script's frames in 0.480 (0.475 to 0.494), about 0.95 of lua5.5 5.5.1's.

## Consequences

- Compared with Lua 5.5, [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs)
  lists as decided: `error()` with no value carries `nil` where Lua answers
  `<no error object>`; a syntax error carries a column; a handler that fails runs once; a
  host's interruption is not caught by `pcall`. It also lists one difference that comes from an
  absent mechanism: a call that is too deep always says `stack overflow`, because Nilu counts
  one depth where Lua keeps separate limits for its own stack and C's.
- A host must pop the value a failed call leaves, or the stack grows.
- A handler's final runtime status alone cannot say whether the original failure was a type
  error or a stack overflow.
- How the `nilu` command writes a failure that reaches it — a string as it is, another value by
  its kind, with a traceback when more than one function's frame stood — is in
  [11.3](../../doc/en/11-nilu-command.md#113-how-a-failure-is-written).

## What would reverse it

- A host that needs the words as part of the status — for instance, a status it can log without
  touching the stack. That would mean a second place the words live, and the two would have to be
  kept the same.
- A failure kind that a host must handle differently from every existing status. That is a new
  status, and a change to the C surface ([0011](0011-the-version-number.md)).
