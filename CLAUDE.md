@AGENTS.md

# Claude Code

`AGENTS.md` is the shared instruction set; this file and `.claude/rules/` only add what Claude
Code needs on top of it. Never restate a rule from `AGENTS.md` here: fix it there.

| Question | Where |
|---|---|
| Claims, counts and authorities | `.claude/rules/evidence.md` |
| Decide yourself or ask the owner | `.claude/rules/owner-decisions.md` |
| Checks and how to report them | `.claude/rules/verification.md` |
| git and pull requests | `.claude/rules/git.md` |
| Writing Zig (loads when code is touched) | `.claude/rules/zig.md` |
| Where a change's questions, answers and findings go | The change's GitHub issue (`AGENTS.md`) |

The Zig version is the one `README.md` names and `.mise.toml` pins; run it through `mise exec --`
when the `zig` on the path is another version.

## Architecture boundaries

These come from [`design/README.md`](design/README.md) and its ADRs; read them before code.

- The pipeline stays separable, and each stage's output can be printed without running the next
  ([0004](design/adr/0004-one-pipeline-and-one-evaluator.md)). No tree-walker, ever.
- The core touches nothing outside itself ([0003](design/adr/0003-the-core-touches-nothing-outside-itself.md));
  the standard library is written against the C API ([0010](design/adr/0010-the-library-is-written-against-the-c-api.md)).
- The collector is the one place where a mistake is silent: a missing root frees something live
  and nothing else catches it. When a change alters what the stack holds during a call, re-read
  the root set ([0005](design/adr/0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)).
- Nothing is a dependency except the Zig standard library. Node runs the read-only checks only.

An ADR comes first for: a lexer or parser generator; a second evaluator; a second collector or a
change to what is a root; threads or anything asynchronous; a second surface syntax; a second
build system or a runtime dependency; a layer split. A new language feature needs the owner, not
only an ADR.

Never keep two implementations that answer the same question; if one is unavoidable, cross-check
them mechanically.

## Words

- A human reads a sentence that says what happened and what to do, never an error code or a Zig
  error tag. The sentence itself is the owner's when the record does not give it.
- Name a thing after the concept the domain already named, not after the data structure.
- `nil` is Nilu's value, never Zig's `null`; "value" is a Nilu value ("Zig value" otherwise);
  "error" says which — a Nilu runtime error or a Zig `error{…}`.
- Say what it does first, then what it does not, why, and what to do instead. "Not implemented
  yet", not "unavailable". Never phrase our own gap as the other side's fault.

## Comments

A comment says why, why this value, and what is avoided. No history: not the version a thing
arrived in, not the old answer. When code changes, update the set: implementation → test →
comment → document.

## How to proceed

1. Measure before polishing: state what it does now, in numbers.
2. Report observation and inference separately.
3. Do not widen a change past its subject.
