# Working on Nilu

Nilu is a scripting language inspired by Lua 5.5, implemented in Zig and embedded
through a closed C stack API. This repository holds the language's whole
record; nothing outside it is a source.

Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the current contributor workflow.
If the record leaves a contract unresolved, ask the owner.

## Sources and decisions

Record a change's questions to the owner, the answers, measurements and what was tried
and dropped in the GitHub issue of that change; open one if there is none, and
close it from the pull request.
The reference manual describes observable behavior; `design/README.md` describes
the current design once carried. Record only fundamental architectural decisions
or changes of direction in `design/adr/`.

The record is this repository: the manual, `design/README.md`, `design/adr/`, the
carried C cases and fixtures, the tests and the issues. Nothing outside it is
a source; never paste implementation code from elsewhere.

Language behavior is the owner's decision. When records disagree or do not settle
syntax, semantics, an API contract or output, present the evidence and ask the
owner. Finish independent work while an answer is pending. Do not turn an
implementation convenience into a language decision.

## Implementation

Keep source, tokens, AST, bytecode and execution separate and observable. The
register VM is the only evaluator. The core does no file I/O and reads no clock,
environment or process state. The command uses the public C API; the standard
library uses that same API.

Pass allocators explicitly inside the Zig core, track ownership, and clean up
partial allocations on failure. Use the testing allocator for allocation tests.
Treat source text and C indices as untrusted input. Check lengths, offsets and
arithmetic before use. Malformed scripts return failures rather than crashing
the host. C exports use C-compatible representations and handle Zig errors inside
the boundary. Keep collector roots correct across every call into host code.

## Zig naming

Follow the naming conventions in the "Names" section of the Zig language reference
for the version `README.md` names.
A file is classified by its top-level container, not by whether it contains
any type declarations:

- A file with top-level instance fields is itself a struct type: use
  `TitleCase.zig` (for example `Ast.zig`, `Lexer.zig`, `Token.zig`,
  `ParserEngine.zig`). A local `@This()` alias also uses TitleCase.
- A namespace file that groups functions, constants or nested types uses
  `snake_case.zig` (for example `compiler.zig`, `runtime.zig`,
  `execution_context.zig`). Declaring `pub const State = struct { ... }`
  inside a namespace does not make its filename `State.zig`.
- Namespace test modules use `<subject>_test.zig`; shared test helpers use
  descriptive snake_case names that neither start with `test_` nor end in
  `_test`, so a name tells a helper from a test module (for example
  `synthetic_ast.zig`, `repeated_text.zig`). Keep `build.zig` and `root.zig`
  as entry points.
- Directories use `snake_case`. Imported type aliases and other type names use
  TitleCase; namespace aliases, variables, fields and value constants use
  snake_case. Functions use camelCase; functions returning a type use TitleCase.
- Treat acronyms as words: `Ast`, `ApiClient`, `Vm`, rather than all-caps
  prefixes. The established C ABI names (`nilu_*`, `NiluState`, `NILU_*`),
  external fixtures and carried reference material retain their own contracts.

When renaming a Zig file, update case-sensitive imports, build inputs, current
documentation and any filename-based test filters together. Keep captured
reference bytes intact. Review new filenames
against this rule; do not infer a type filename from the module's subject alone.
`zig build naming-check` checks the part a parser can see and runs in the stage
gate; whether a constant holds a type or a value remains for review.

## Verification and reporting

Run focused checks while developing and the complete gate before a PR. Every
source test must be reachable from the module root. Test runners must support
listing and selecting cases and announce the subset actually run. A missing
stage is reported as pending, never as passed. A compiler success alone says
nothing about runtime behavior.

Use `zig build stage-check --summary all` for the faster gate while developing.
`zig build check` is the complete gate and must keep failing while required
runtime stages or document targets are pending. Never replace a pending stage
with an empty successful step. Source tests run with `zig build test`; select a
subset with `-Dtest-filter=<substring>`. `node tools/list-tests.mjs --count`
lists declarations without compiling; compare that number with the runner.

Use carried C cases, CLI fixtures, manual examples and the captured Lua numeral
answers as independent constraints. Do not change expectations to fit new code.
Prove bug regressions by observing the intended test failure when the fix is
removed. Report commands run, their results, and anything not verified. Never
invent counts or describe a build for a foreign target as having run there.

## Git

Work on a named feature branch and stage named paths. Use Conventional Commits
and message files (`git commit -F`, `gh pr create --body-file`). Keep unrelated
work separate. Never discard uncommitted work or force-push without explicit
instruction. Before merging, check CI and dependent PRs. Publishing the language,
changing repository visibility and tagging a release remain the owner's
actions.

Keep credentials, session URLs, machine paths and scratch reports out of commits.
