# 0010 — The library is written against the C API

**Status:** accepted. The `pcall` path below is decided in
[0009](0009-a-failure-is-a-status-and-one-value.md); the shape of `debug` is the owner's decision.

## Context

A language needs a standard library: string functions, table functions, mathematics. The
library can be written against the implementation's internals, which is quicker and can do
anything, or against the same C API a host uses, which can only do what a host can do.

## Decision

- **The standard library is written against the C API.** Its functions are host functions,
  registered the way a host registers its own, and they read and write values only through the
  functions `include/nilu.h` declares. A few stateless pieces are shared with the core so that
  their answers match exactly: spelling a number, turning a float into an integer, encoding a
  code point as UTF-8, and the stack's size limit.
- **`nilu_openlibs` opens the whole library; `nilu_openselectedlibs` opens the parts a host
  names.** It computes, and touches nothing outside the state; `print` and loading go through
  the writer and the reader the host gives
  ([0003](0003-the-core-touches-nothing-outside-itself.md)).
- **A library function behaves as Lua 5.5's does,** and refuses a wrong argument with Lua's
  words — `bad argument #n to 'name' (…)`. Where it does not follow Lua,
  [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) says why.
- **What a host could not write through the C API, the C API gained.** The library is the first
  host, and a call it needed and could not make is a call the boundary was missing.
- **`debug` reads and does not change.** It has `debug.traceback` and `debug.getinfo`, written
  against `nilu_getinfo`; nothing in it changes a function, a local or a hook from outside.
- **The `nilu` command brings `io` and `os`,** written against `include/nilu.h` as any host
  would, and the library never defines those names.
- **One shortcut is the core's, not the library's.** A script's call of the library's `pcall`
  with a script function runs among the script's frames
  ([0009](0009-a-failure-is-a-status-and-one-value.md)); `nilu_openlibs` tells the core which
  function is the library's `pcall`. The library's own `pcall` is unchanged, and a host that
  registers a `pcall` of its own gets the general way.

[Chapter 10](../../doc/en/10-library.md) lists the library and runs an example of each function;
[11.4](../../doc/en/11-nilu-command.md#114-io-and-os) lists what the command adds.

## Why

- A library written against the C API is proof that the C API is enough. A library that
  reached into the internals would say nothing about what a host can do — and showing what a
  host can do is the point of an embedded language.
- One way in means one set of rules. A library function runs through the same calling protocol,
  on the same state, as a host's function, so it cannot do anything a host's function could not.
- The library finds the boundary's gaps before a host does. `nilu_pushvalue`, `nilu_len`,
  `nilu_topointer`, `nilu_stringtonumber`, `nilu_next`, `nilu_getmetafield` and `nilu_pcallk`
  are on the boundary because the library needed them.

## Consequences

- A host can replace a library function with its own, or leave the library out and register a
  smaller one, through the same calls the library uses.
- Nothing of Lua 5.5's library is missing now; what Nilu leaves out was decided, and is in
  [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs).

## What would reverse it

- A library function that cannot be written against the C API without a call the owner does not
  want on the boundary. That would be a reason either to add the call or to leave the function
  out — not to let the library reach past the API.
- A new library function is the owner's decision, like any change to the language
  ([0001](0001-nilu-is-a-separate-language-inspired-by-lua-5-5.md)).
