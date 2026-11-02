---
paths:
  - "src/**"
  - "cli/**"
  - "include/**"
  - "test/**"
  - "examples/**"
  - "build.zig"
---

# Zig

`MUST` = required, `SHOULD` = default, `MAY` = optional.

Formatting is `zig fmt`'s and never a review topic. Naming is `AGENTS.md`'s "Zig naming"; run
`zig build naming-check` after adding or renaming a file or declaration. What may not be
introduced at all is `CLAUDE.md`'s architecture boundaries.

Grounds for the whole file: Nilu is embedded in a host program we did not write, and it runs
source text we did not write. Both are inputs.

## Memory belongs to the host

- MUST: Take `std.mem.Allocator` as a parameter. Never reach for a global or default allocator in
  library code.
- MUST: Whatever allocates says who frees, in the declaration's doc comment.
- MUST: `errdefer` on every path that has allocated and can still fail.
- MUST: Use `std.testing.allocator` in tests; it fails a test that leaks.

## Source text is hostile input

- MUST NOT: Never `unreachable`, `@panic` or `catch unreachable` on anything derived from source
  text. In Debug and ReleaseSafe that aborts the process, and the process is the host's.
- MUST: Check a length or offset that came from the source before indexing with it, and use
  checked or saturating arithmetic on it.
- MUST: `unreachable` states an invariant we established ourselves, never an assumption about input.

## Errors

- MUST: A public declaration has an explicit error set. Never `anyerror` outward.
- MUST: An error value is not a message; what a human reads is built separately.
- MUST NOT: Never print from library code. Return it, or write to a writer the caller passed.

## The C boundary

- MUST: `callconv(.c)` on every `export fn`, and only what C can represent crosses: integers,
  floats, pointers, an opaque handle, a string as pointer plus length.
- MUST: No Zig error escapes an `export fn`; map each to what the C signature can say.
- MUST: Valid input never panics. Anything a host is allowed to pass is checked.
- MAY: A documented precondition the host broke may abort, with a message naming the function
  ([0002](../../design/adr/0002-a-closed-c-stack-api.md)). Never abort where an honest answer exists.
- MUST: An index or length from C is input from outside. The stack is 1-based with negatives from
  the top, so `0` is never valid.
- MUST NOT: Never report a failure through a value that could have been a legitimate answer.
- MUST: The handle stays opaque to C.
- MUST: An exported symbol is a promise; renaming one or changing its signature moves the version
  ([0011](../../design/adr/0011-the-version-number.md)).

## A test in a file nobody imports never runs

- MUST: Every source file is reachable from the module root (`src/root.zig`). Zig compiles what is
  referenced; a `test` block in an unreferenced file is silently not run.
- MUST: When a file is added, confirm the announced test count moved, and that it matches
  `node tools/list-tests.mjs --count`.
