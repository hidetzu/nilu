# The design of Nilu

This document gathers in one place **how Nilu is now** and **why it is that way**.
It is written for someone reading this repository for the first time, and for someone about to change it.

- How to use it, and what a program sees, are in the [reference manual](../doc/en/README.md).
  This document does not repeat what the manual says.
- The detailed behaviour (what each call returns, the numbers of the limits, the sentences of a failure) belongs to the manual and to
  [`include/nilu.h`](../include/nilu.h). This document links to them.
- Each decision that is hard to reverse has one ADR. Each section of this document names the ADRs it rests on.

## 1. What Nilu is

Nilu is **a small scripting language meant to be embedded in a host program**. It is written in Zig,
and a C host uses it through one header (`include/nilu.h`) and one library.

**Nilu is a separate language inspired by Lua 5.5.** It borrows much of its grammar, values, metatables, library and the shape of its C API
from Lua, but it is not an implementation of Lua, and it does not promise to behave as Lua does.
The places it differs are listed in the manual's [13. Differences from Lua](../doc/en/13-differences-from-lua.md).

It aims at three things.

1. **Nothing for the embedder to worry about.** The core does not touch the outside world, and running out of memory, like every other failure, comes back to the C host as a status.
   It stops the host's process only when the host breaks a function's precondition.
2. **Small, and explainable as a whole.** One evaluator, one collector, and a lexer and a parser written by hand.
   Every stage's output can be looked at or tested without running the next stage.
3. **What it says is checked.** The manual's examples are run.
   Reading and writing numbers is held against the answers of `lua5.5` itself.

The ADRs it rests on: [0001](adr/0001-nilu-is-a-separate-language-inspired-by-lua-5-5.md),
[0003](adr/0003-the-core-touches-nothing-outside-itself.md),
[0004](adr/0004-one-pipeline-and-one-evaluator.md)

## 2. The whole shape

```text
source text
  -> lexer      (Lexer.zig, Token.zig)         tokens
  -> parser     (parser.zig, Ast.zig)          syntax tree
  -> compiler   (scope.zig, compiler.zig, bytecode.zig)   bytecode
  -> VM         (vm.zig)                       execution
```

| Part | Files in `src/` | What it does |
|---|---|---|
| Lexer | `Lexer.zig`, `Token.zig`, `numeral.zig`, `string_literal.zig` | Splits the source into tokens; `numeral.zig` reads and spells numbers |
| Parser | `parser.zig`, `ParserEngine.zig`, `Ast.zig`, `validation.zig` | Builds a syntax tree with a hand-written stack of work and bounds how deep syntax nests |
| Compiler | `scope.zig`, `jumps.zig`, `compiler.zig`, `bytecode.zig` | Resolves names and jumps, and turns the syntax tree into bytecode for the register VM |
| Loading | `loader.zig` | Source text to a function value, with the syntax error's place |
| VM | `vm.zig`, `native.zig`, `arithmetic.zig`, `coroutine.zig` | Runs the bytecode, the only evaluator. Calling a host's function is `native.zig`'s |
| Failure | `execution_context.zig`, `failure_transport.zig`, `execution_location.zig`, `runtime_diagnostic.zig` | Keeps each call's failure record, runs message handlers, and words a runtime failure |
| The state, values and collector | `runtime.zig`, `HashPart.zig` | The state, every kind of value and object, the stack, and the collector; a table's hash part is `HashPart.zig` |
| C API | `c_api.zig`, `host_allocator.zig`, and `include/nilu.h` | The only surface visible from C |
| Standard library | `stdlib.zig` and `stdlib_*.zig`, `pattern.zig`, `string_format.zig`, `string_pack.zig` | The basic functions with `print`, and `string`, `table`, `math`, `utf8`, `coroutine`, `debug` and `package` |
| The `nilu` command | `cli/nilu.c` | A C host that runs files, shows a prompt, reads modules, and has `io` and `os` |

**Every stage's output can be checked without running the next stage**: the tokens and the tree are values a test reads, and bytecode prints. A stage that can only be seen
through the next one can neither be tried nor explained on its own.

**There is one evaluator, the register VM.** Nothing evaluates by walking the syntax tree.
With two evaluators one question would get two answers, and when they disagreed nothing would decide which is right.
Each kind of instruction runs in a function of its own, which ends by jumping to the next
instruction's function (a tail call). In a single loop over every kind, editing one kind's code
can change how the compiler assigns machine registers in all of them, so loops that never run
that kind change speed. Only Zig's LLVM backend makes these tail calls, so every build step that
compiles the core selects it ([0004](adr/0004-one-pipeline-and-one-evaluator.md)).
An instruction's operation and the function that runs it fit in one cache line. Its source
position and the names a failure there would mention are kept apart, in its `Info`, as Lua keeps
line information apart.

**The core (`src/`) does not touch the outside world.** It touches no file, no standard output, no clock, no environment variable and no process;
what it needs, the host passes in. What touches the outside is `cli/nilu.c`, which is one host
written with nothing but `include/nilu.h`. The standard library is written on the same C API too ([4.6](#46-the-standard-library-and-the-nilu-command)).

The parser keeps an explicit stack of work, so how deep a program may nest is the grammar's
limit, not the host's stack's. An assignment evaluates its targets' receivers and keys, then the
right side, then stores from right to left, and each turn of a generic `for` has fresh variables
([0014](adr/0014-assignment-evaluates-left-to-right-and-stores-right-to-left.md)).

A script calling a script function pushes a frame in the same VM loop, without a nested host
call. A script's `pcall` of a script function does the same and marks that frame as protected.
Each entry from the host or a native function sets the caller's pending failure aside while the
callee runs. Calls are counted, with a little more room while a message handler runs. A failure
passed on through a host's function keeps its kind, tracked beside the C stack rather than in the
value ([0009](adr/0009-a-failure-is-a-status-and-one-value.md)).

The C API's table and global access and its operator functions (`nilu_arith`, `nilu_compare`)
run the same code as the instructions, so a metamethod reached from C behaves as one reached
from a script.

The ADRs it rests on: [0003](adr/0003-the-core-touches-nothing-outside-itself.md),
[0004](adr/0004-one-pipeline-and-one-evaluator.md),
[0009](adr/0009-a-failure-is-a-status-and-one-value.md),
[0010](adr/0010-the-library-is-written-against-the-c-api.md),
[0014](adr/0014-assignment-evaluates-left-to-right-and-stores-right-to-left.md)

## 3. How a difference is decided

When Nilu answers a question Lua answers, the answer is one of these.

| Case | What is done |
|---|---|
| Lua 5.5 answers it, and that answer suits Nilu | **Lua's answer is borrowed.** Only an answer confirmed by reading Lua's source is borrowed |
| Nilu lacks a mechanism Lua's answer needs | It becomes **something that differs because a mechanism is absent**. What is absent is written down |
| Nilu answers differently from Lua | It is **decided and changed**. The reason is written down, and it changes only when the language's owner — the maintainer who decides the language's design — decides |
| Lua has it, and Nilu has not built it yet | It is **not there yet**. What it needs is written down |
| Lua promises nothing | Nilu's answer is written down, but it is not a promise |

Whether the language itself (the grammar, the values, the metamethods, the library, the functions the C API exposes) grows or changes
is not settled by implementing something to see. The owner decides, and the reason is left in an ADR.

Chapter 13 of the manual lists the differences in this split:
[what was decided and changed](../doc/en/13-differences-from-lua.md#what-was-decided-and-changed),
[what differs because a mechanism is absent](../doc/en/13-differences-from-lua.md#what-differs-because-a-mechanism-is-absent),
[what is not there yet](../doc/en/13-differences-from-lua.md#132-what-is-not-there-yet),
[where Lua says nothing](../doc/en/13-differences-from-lua.md#135-where-lua-says-nothing).

The ADRs it rests on: [0001](adr/0001-nilu-is-a-separate-language-inspired-by-lua-5-5.md)

## 4. The answer as it stands, subject by subject

### 4.1. Grammar

**The answer now.** The grammar is built on Lua 5.5's. A program is a sequence of statements, and the only expression that can be a statement is a call.
There are `local` (including with `<const>`), the `global` declaration, `if`, `while`, `repeat`, the numeric `for`, the generic `for`, `break`,
`goto`, `return`, functions, closures, varargs and method calls.
The whole of it is in [15. Grammar](../doc/en/15-grammar.md).

**Why.** Lua's grammar has long been used as an embedded language, and reading Lua's source settles an answer.
What was borrowed can be written as in Lua, so someone who knows Lua does not get lost.

**Where it differs from Lua.**

- Decided and changed: a `<const>` stays as a named, read-only local, and its name appears in a failure's sentence.
  A syntax error gives the column as well as the line, and a refusal of a `goto` points at the `goto`.
  The depth of the syntax has a limit, and hitting it says the limit. Each of these is so that a refusal or a failure's sentence says what happened and where.

The ADRs it rests on: [0001](adr/0001-nilu-is-a-separate-language-inspired-by-lua-5-5.md),
[0004](adr/0004-one-pipeline-and-one-evaluator.md)

### 4.2. Values

**The answer now.** There are eight kinds of value: `nil`, booleans, numbers, strings, tables, functions, `userdata` and threads (coroutines)
([2. Values and types](../doc/en/02-values.md)).

**A number is an integer or a float, as in Lua.** An integer is 64 bits and wraps around; the
operators, numerals, table keys and the numeric `for` follow Lua's rules for the two.
**Arithmetic does not turn a string into a number.** `"10" + 1` is a type error; write `tonumber`.
**Concatenation takes a number**, spelled as `tostring` spells it: `"n=" .. 1` joins.
An integer is spelled in decimal, and a float with the shortest digits that read back as the same value, with `.0` when the value is whole. `tostring` and `string.format`'s `%s` use this spelling.

**Why.**

- Integers keep 64-bit values, identifiers and bit patterns exact, and a program from Lua keeps
  its numbers. An integer in [-2^45, 2^45) is held in the value itself, so a
  counter or an index allocates nothing.
  A float's spelling does not round, so `tonumber(tostring(x)) == x` holds for every finite number (`inf` and `nan` do not read back as numbers).
- If conversion is a property of the values, one has to remember which operator converts when.
  If it sits only where it is written, reading the code tells you.
- The spelling (`tostring`, `print`) never rounds. `string.format`'s float conversions are separate and give C's
  results, `%g` included: they round the binary value exactly, as `printf` does.

**A table** has an array part for the keys 1, 2, 3, … it holds as a sequence and a hash part for every other key. Any value except `nil` and NaN can be a key; tables, functions and userdata are keys by identity
([Any value but nil and NaN can be a key](../doc/en/02-values.md#any-value-but-nil-and-nan-can-be-a-key)).

**A function** is a value, and it captures and shares the locals around it (a closure). A host's C function becomes a value too,
and values can be attached to it.

**A `userdata`** is a block of bytes the state owns. It owns its own bytes only, and has no finaliser (`__gc`).
An outside resource (a file, a handle) is closed by the host itself. Having no finaliser spares the collector
a stage that calls a host's function in the middle of a collection.

**Where it differs from Lua.** Having no automatic conversion, the shortest spelling of a float, NaN having one spelling,
`userdata` having no finaliser and there being no light `userdata` are **decided and changed**.
That strings compare by the order of their bytes is **something that differs because a mechanism is absent**: the core does not use
the C standard library (it has no locale).

**A metamethod is inherited** through the table-valued `__index` of the metatable's metatable,
up to 2000 links, and finding one runs no script. `__gc`, `__mode` and `__metatable` are read
from the metatable itself. The library reads `__tostring`, `__name` and `__pairs` through
`nilu_getmetafield`, the C API's view of the same walk, so there is one answer to "which
metamethod" ([0012](adr/0012-metamethod-names-follow-table-inheritance.md)).

The ADRs it rests on: [0005](adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md),
[0007](adr/0007-a-value-is-eight-bytes.md),
[0008](adr/0008-a-number-is-an-integer-or-a-float.md),
[0012](adr/0012-metamethod-names-follow-table-inheritance.md),
[0013](adr/0013-a-coroutine-is-a-value-with-its-own-stack.md)

### 4.3. Memory and collection

**The answer now.** Strings, tables, closures, C closures, the cells that hold captured variables, `userdata` and
coroutines are all owned by the state. A coroutine is a thread with its own stack; resuming one switches the
state to it, and a yield leaves the host's stack, so a resume rebuilds the frames it continues
([0013](adr/0013-a-coroutine-is-a-value-with-its-own-stack.md)). A generational mark-and-sweep collector that moves nothing frees what nothing can reach any more
([0006](adr/0006-a-young-collection-marks-only-what-is-new-or-written.md)).
What is a root and when a collection happens are in [9. Garbage collection](../doc/en/09-gc.md).
A collection happens between two instructions of a running program, or when a program or the
host asks for one.

**Why.**

- With one owner, the state, the host does not have to remember to free each thing, and `nilu_close` gives everything back.
- There is one method, mark and sweep, done by generation: most collections mark only what was made or
  written since the last one, and an old object takes a write barrier when a reference is stored into it.
  Nothing moves, since a host holds pointers into strings and userdata. The collector is the one place where a mistake frees something
  still live without saying anything. So changing what is a root is decided by an ADR.

A host can give the state its memory (`nilu_newstate`, Lua's `lua_Alloc` shape).

A weak table lets go of what only it holds ([0005](adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)); a table's `__gc` is not read.
A register keeps its value until the code writes it, and each collection clears what is past
a stack's length ([0005](adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)).
What there is not is listed in [9.4. What there is not](../doc/en/09-gc.md#94-what-there-is-not) and [12.8. What is absent](../doc/en/12-embedding.md#128-what-is-absent).

The ADRs it rests on: [0005](adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md),
[0006](adr/0006-a-young-collection-marks-only-what-is-new-or-written.md),
[0013](adr/0013-a-coroutine-is-a-value-with-its-own-stack.md)

### 4.4. Failure

**The answer now.** A failure comes back to the host as **a status (`NiluStatus`) and, in most cases, one value**. The value is usually a sentence,
sometimes with a position. When nothing is left is in [0009](adr/0009-a-failure-is-a-status-and-one-value.md) and the header.
`error` can carry any value, and with nothing passed it carries `nil`.
A failure stops at `pcall` or `xpcall`, and from C at `nilu_pcall`; if nothing stops it, it goes back to the host.
A script's `pcall` of a script function is a marked frame in the script's own run of frames, not
a call into the host, and a failure stops at that mark
([0009](adr/0009-a-failure-is-a-status-and-one-value.md)).
`xpcall`'s handler runs before the unwinding, as in Lua. What a program sees is the same either way;
what can walk to where it failed is a handler the host writes (`nilu_where`)
([8.4.1](../doc/en/08-failure.md#841-xpcall)).
How it behaves as a program sees it is in [8. Failure](../doc/en/08-failure.md), and as a host sees it in
[12.3](../doc/en/12-embedding.md#123-almost-every-function-answers-a-status) and [12.5.1](../doc/en/12-embedding.md#1251-seeing-where-it-failed).

**Why.**

- A failure in an embedded language must not stop the host's process. So a failure does not jump through C;
  it comes back as a return value.
- A sentence is for a person to read, so it says what happened and where, and shows no internal name.
  Where the shape of a sentence can be borrowed, it is borrowed from Lua.
- A program that does not stop can be stopped by the host (`nilu_sethook`, [8.7](../doc/en/08-failure.md#87-a-program-that-does-not-stop)).
  `pcall` cannot catch this interruption. If it could, the host could not stop a program it wants to stop.

**Where it differs from Lua.** `error()` carrying `nil`, a handler running only once when the handler itself fails,
`pcall` not catching the interruption, the handler running when memory runs out inside a library function, and others, are
**decided and changed**. The list is in [13.1](../doc/en/13-differences-from-lua.md#131-where-it-differs).

The ADRs it rests on: [0009](adr/0009-a-failure-is-a-status-and-one-value.md)

### 4.5. The C API

**The answer now.** What C sees is `include/nilu.h` and nothing else. The state is a type that does not show its inside (`NiluState`),
and values are exchanged through the stack. An index counts from 1, and a negative one counts from the top.
The functions that push, the functions that read and write tables, and the functions that call return a `NiluStatus`.
How to use it is in [12. Embedding from C](../doc/en/12-embedding.md).

**Why.**

- The shape that goes through a stack is the shape of Lua's C API, and it is proven as a shape for embedding.
  Where a function does what Lua's does, the name is borrowed from Lua too (`nilu_pushnumber` for `lua_pushnumber`, and so on).
  Some differ in shape (`nilu_getupvalue` names a value of the running C closure). Each function's promise is in the header.
- Lua's API raises a failure such as running out of memory as an error, and the host checks the stack's room beforehand with `lua_checkstack`. Nilu's API raises nothing. A failure is told through the return value, and most functions return a status.
  So a C host can still clean up after itself following a failure. This is the largest difference from Lua's API.
- As far as it can, a failure or "there is none" is not returned as a value that a right answer could also be. If `0` meant both "the value is 0" and "it failed",
  the caller could not tell them apart. Where a function does not keep to this, the header says so.
- C cannot see the shapes inside the state, so changing the inside does not change the host's code.
  The names and argument shapes of the published functions are a promise, and changing them is decided by an ADR.
- Some functions stop when the host breaks a precondition (for example, when it passes an index that does not exist).
  Which functions stop and which return an answer is in each function's comment in the header.

**Where it differs from Lua.** Returning a status, the numbers of the type tags, the names `nilu_new`/`nilu_close`, `userdata`'s finaliser,
and there being no light `userdata` are **decided and changed**. That `nilu_getupvalue`/`nilu_setupvalue` name the running
C closure differs because a mechanism is absent: there are no pseudo-indices.
What Lua's C API has and Nilu's does not is in
[12.8. What is absent](../doc/en/12-embedding.md#128-what-is-absent).

The ADRs it rests on: [0002](adr/0002-a-closed-c-stack-api.md),
[0005](adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md),
[0009](adr/0009-a-failure-is-a-status-and-one-value.md),
[0011](adr/0011-the-version-number.md)

### 4.6. The standard library and the `nilu` command

**The answer now.** `nilu_openlibs` opens the basic functions with `print`, `string`, `table`, `math`, `utf8`,
`coroutine` and `debug`, and `load`, `require`, `dofile`, `loadfile` and `package` ([10. The library](../doc/en/10-library.md)). Every library function is a host's function that reads and writes values
with nothing but the functions in `include/nilu.h`. Spelling a number, turning a float into an integer, encoding UTF-8 and the stack's size limit
are shared with the core, as pieces that hold no state.

`print` is in the library and hands its line to a writer the host gives with `nilu_setwriter`
([0003](adr/0003-the-core-touches-nothing-outside-itself.md)). `io` and `os` are not in the
embedded library. The `nilu` command has its own
([11. The `nilu` command](../doc/en/11-nilu-command.md), [11.4](../doc/en/11-nilu-command.md#114-io-and-os)).
Loading code follows the same line ([0003](adr/0003-the-core-touches-nothing-outside-itself.md)):
`require`'s rules are the library's, and finding and reading the text is a reader the host gives with
`nilu_setreader`; the command's reads files ([11.6](../doc/en/11-nilu-command.md#116-where-require-looks)).

**Why.**

- Writing the library with the C API alone shows that the library can be written with what a host can do.
  What the library needs, a host needs too, so anything missing gets added to the C API.
- Standard output, files, the clock and processes belong to the host. If the core held them, they would be usable
  even where the embedder does not want them used. The command is one host that holds them.

**Where it differs from Lua.** `io` and `os` not being in the embedded library, and `print` writing through the host's writer, are **decided and changed**.
`upper`/`lower` and the pattern character classes being ASCII only, `math.random`'s initial state being fixed,
and `table.sort`'s pivot being fixed **differ because a mechanism is absent**: the core has no C standard library and no clock.
Nothing of Lua 5.5's library is missing now ([13.2](../doc/en/13-differences-from-lua.md#library)).

The ADRs it rests on: [0003](adr/0003-the-core-touches-nothing-outside-itself.md),
[0010](adr/0010-the-library-is-written-against-the-c-api.md)

### 4.7. The version number

**The answer now.** A version is `MAJOR.MINOR.PATCH`, and the first release is `0.1.0`. While it is `0.x`,
MINOR moves when something that worked stops working or gives a different answer, and PATCH moves otherwise.
A version between releases carries `-dev.N`, as in `0.1.0-dev.N`.
The header's `NILU_VERSION` holds this string, and `NILU_VERSION_NUM` has the same value as the next release's number.
`zig build dist` writes `SHA256SUMS` together with what it hands out.

**From `1.0.0` on, Semantic Versioning's reading is followed.** `1.0.0` is kept for when Nilu is finished.
This is the same thinking as Zig's.

**Why.** `0.x` is a number read as "it will still change". On top of that, MINOR is made to say what a user most wants to know:
"will it break if I upgrade".

The ADRs it rests on: [0011](adr/0011-the-version-number.md)

## 5. Where things are written

| What you want to know | Where |
|---|---|
| How to write it, what a program sees | [The reference manual](../doc/en/README.md) |
| The list of differences from Lua | [13. Differences from Lua](../doc/en/13-differences-from-lua.md) |
| The promise of each C function | [`include/nilu.h`](../include/nilu.h) |
| Decisions that are hard to reverse, and their reasons | [`adr/`](adr/) |

