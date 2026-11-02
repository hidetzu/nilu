# Contributing to Nilu

Use this checkout's [manual](doc/en/README.md), [design](design/README.md)
and tests as the starting point. Decisions and findings are in the GitHub issue
of each change. Everything a change needs is in this checkout.
If a contract is unclear, open an issue with the conflicting evidence so the
owner can decide the language behavior.

## Set up and run

Install the Zig version [the README names](README.md#build-from-source), pinned
in [.mise.toml](.mise.toml), and Node.js for the verification tools. A native C
compiler enables the additional native-host
checks; report explicitly when it is unavailable. Lua is only needed to
recapture reference answers, not for normal builds or checks.

```sh
zig version
node --version
zig build
zig-out/bin/nilu -e 'print(1 + 2)'
```

On Windows the command is `zig-out/bin/nilu.exe`. The CLI case harness uses
POSIX facilities; the complete gate described here is exercised on Linux.
Building a foreign target does not demonstrate execution on that platform.

### Editors

Nilu's syntax is Lua 5.5's, so `.nilu` files open as Lua: `.vscode/settings.json` does it for VS
Code, and `.nvim.lua` for Neovim once `exrc` is set and the file is trusted (`:trust`).

## Make and verify a change

Work on a named feature branch. Keep changes focused and follow the ownership,
naming and Git rules in [AGENTS.md](AGENTS.md). Start with a relevant subset:

```sh
zig build test -Dtest-filter=parser
```

Choose a filter for the area you changed. An empty selection fails. Before a
PR, run the complete gate:

```sh
zig build check --summary all
```

This checks source tests, C hosts, CLI cases, manual examples, the installed
embedding example and tooling. `stage-check` is a smaller, faster gate;
it does not replace `check`. Distribution changes also require `zig build dist`.
Record which targets were executed and which were only built. Further command
details are in [Development checks](tools/README.md).

Keep independent reference expectations intact. For a bug fix, demonstrate
that its regression fails without the fix. Document behavior changes in both
manuals. Examples and headings have recorded reference checks: do not update
those records merely to make a behavioral regression pass.

## Report a problem or submit a PR

An issue should include the commit or `nilu -v` output, OS, compiler versions,
a minimal script or C host, reproduction commands, expected and actual results.
Include the complete diagnostic when useful, without credentials or private data.

Use Conventional Commits and stage named paths. Describe the problem, resulting
behavior and commands actually run in the PR; identify anything not verified.
Use message files for commits and PR bodies. Check CI and dependent PRs before
merging; a local pass does not imply CI ran. Language/API decisions belong to
the owner when the existing specification does not settle them. Publishing,
tagging releases and changing repository visibility remain the owner's actions.
