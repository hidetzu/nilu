# 0004 — One pipeline, and one evaluator

**Status:** accepted. The depth limit and how it counts are the owner's decision, and so is a
script's call of a script function running without a host call.

## Context

A language implementation turns text into behaviour in stages. How many stages there are,
and whether each can be looked at on its own, decides how a mistake is found: a stage that can
only be observed through the next one cannot be tested or explained by itself.

There are two common ways to run a program: walk the syntax tree directly, or compile it to
bytecode for a virtual machine. Lua compiles to bytecode for a register-based VM.

## Decision

- **The pipeline is source text → tokens → syntax tree → bytecode → the VM**, and every stage
  exists:
  - a lexer that produces tokens;
  - a parser that produces a syntax tree as a value it returns;
  - a compiler that turns the tree into a prototype — bytecode with its constants and the
    prototypes nested in it;
  - a register VM that runs prototypes.
- **Each stage's output can be checked without running the next one:** the tokens and the tree
  are values a test reads, and a prototype's bytecode prints. The lexer is
  not fused into the parser, and the compiler does not walk the tree while the parser builds it.
- **The lexer and the parser are written by hand.** No generator is used.
- **The parser does not recurse on the host's stack.** It keeps an explicit stack of work, so
  how deep a program nests is a property of the language, defined in the
  [grammar](../../doc/en/15-grammar.md), and not of the host's stack. The depth is checked while
  parsing, in both directions — an open construct nested inside others, and a chain that grows
  to the left such as `a.b.c…` or `1 + 2 + …` — so a source past the limit is refused at the
  token that crosses it, with a syntax error positioned there, before an unbounded tree is
  built. What counts as a level is in the grammar too.
- **The register VM is the only evaluator.** There is no tree-walking evaluator, and none will
  be built. Its registers are slots of the same stack the C API indexes
  ([0002](0002-a-closed-c-stack-api.md)), as Lua's are. A script function called by a script
  runs in its caller's run of frames, not in a new call on the host's stack; so does a
  script's `pcall` of a script function, whose frame is marked as a protected call
  ([0009](0009-a-failure-is-a-status-and-one-value.md)).
- **Each kind of instruction runs in a function of its own,** which ends by jumping to the next
  instruction's function with a guaranteed tail call. In a single loop over every kind, editing
  one kind's code can change how the compiler assigns machine registers in all of them, so loops
  that never run that kind change speed. Only Zig's LLVM backend makes these tail calls, so every
  build step that compiles the core selects it.
- **Bytecode is not a format a program or host can see.** There is no `string.dump` and no
  loading of a binary chunk (the owner's decision), so the instruction set can change between
  any two builds.
- **The state owns every prototype it compiles**, and releases them when it closes.

## Why

- A bytecode compiler can be wrong in quiet ways — a register used twice, a jump to the wrong
  place. What replaces a second evaluator as a safeguard is being able to read each stage's
  output: the tokens, the tree and the instructions can each be printed and checked on their
  own, so a failure in the parser cannot look like a failure in the compiler.
- Two evaluators would be two implementations of one question. When they disagreed there would
  be no third authority to say which was right.
- A hand-written lexer and parser can say exactly what was expected and where, and can follow
  Lua's own parser function by function — which is how Nilu borrows Lua's grammar and its
  syntax error sentences ([0001](0001-nilu-is-a-separate-language-inspired-by-lua-5-5.md)).
- A parser that recursed on the host's stack would make the deepest program it accepts depend
  on the host's thread, and a deep enough source would crash the host instead of failing.
- Registers in the stack the C API already uses mean one stack, one set of bounds checks, and
  values a native function sees in the same place the VM keeps them.

## Consequences

- A syntax error carries a line and a column; Lua's carries a line only ([13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs)).
- A long chain of left-associative operators or suffixes counts toward the same depth limit as
  any other nesting.
- The passes after the parser still have to cope with large trees; their stress tests build
  such trees directly rather than through source the parser would refuse.
- A function loaded once lives until the state closes. A host that loads source in a loop grows
  until it calls `nilu_close`.
- The collector treats every prototype as reachable
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)),
  which is what that last point costs and what keeps compiled code from being freed while a
  closure still runs it.
- Adding a stage, or a second way of running a program, needs its own decision.
- A build of the core with a Zig backend other than LLVM is not possible while dispatch relies on
  guaranteed tail calls.

## What would reverse it

- A measurement showing that the VM cannot be made correct without a reference to compare it
  against. The answer then is a stronger check on the bytecode, not a second evaluator — and
  that would itself be a decision to record.
- A host that must load and discard many chunks in one state. That would argue for prototypes
  the collector can free, which changes what [0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)
  calls a root.
