# Nilu Reference Manual

Nilu is a small scripting language meant to be embedded in a host program. It is written in Zig,
and a C host uses it through the one header [`include/nilu.h`](../../include/nilu.h).

Nilu is a separate language inspired by Lua 5.5. It borrows much from Lua, but it is not an
implementation of Lua. What was decided and changed is gathered in [Chapter 13](13-differences-from-lua.md).

This manual describes **Nilu 0.1.0-dev.1**.
The authoritative version is `NILU_VERSION` in [`include/nilu.h`](../../include/nilu.h).

| | |
|---|---|
| Who it is for | Someone who has `nilu` in hand. You need not have read this repository |
| What this manual answers | **What it does now** |
| What it does not answer | **Why it was decided that way** (see [the design](../../design/README.md)) |

## Contents

1. [Getting started](01-getting-started.md) — building it, running `nilu`, the first line
2. [Values and types](02-values.md) — `nil`, booleans, numbers, strings, tables, functions
3. [Variables and scope](03-variables.md) — `local`, globals, the `global` declaration, blocks
4. [Statements](04-statements.md) — assignment, `if`, `while`, `repeat`, `for`, `break`, `goto`, `return`
5. [Expressions](05-expressions.md) — operators, precedence, multiple values
6. [Functions](06-functions.md) — definition, calls, varargs, closures, tail calls
7. [Metatables](07-metatables.md) — `__index`, `__newindex`, operator metamethods
8. [Failure](08-failure.md) — what is a failure and what is not
9. [Garbage collection](09-gc.md) — what is freed, and when
10. [The library](10-library.md) — the basic functions and `string`, `table`, `math`, `utf8`, `coroutine`, `debug`
11. [The `nilu` command](11-nilu-command.md) — files, `-e`, standard input, the prompt, `io` and `os`
12. [Embedding from C](12-embedding.md) — the stack, calls, the host's functions
13. [Differences from Lua](13-differences-from-lua.md) — what was borrowed, what was changed, what is absent
14. [Porting from Lua](14-porting.md) — actually porting something, and how many places changed
15. [Grammar](15-grammar.md) — the whole syntax

## What this manual promises

**Every example written here is actually run.**

An example is written as a pair of two blocks; `zig build manual-check` extracts them from this
manual, runs them through the `nilu` it built, and confirms that the output is exactly as
written. `manual-check` is part of `zig build check`, the complete gate that CI runs on every
pull request and on every push to `main`. If an example does not match, that gate fails.

````markdown
```lua nilu
print(1 + 2)
```
```output
3
```
````

The fence's first word, `lua`, is only for highlighting: Nilu's syntax is Lua 5.5's. The word
`nilu` marks the block as an example to run.

**What is not written is not promised.** Conversely, what is absent is written as
"absent" — and "not implemented yet" is distinguished from "cannot", because the reader's
next move depends on which it is.
