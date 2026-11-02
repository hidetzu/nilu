# 0011 — The version number

**Status:** accepted.

## Context

A host links against `include/nilu.h`, a script runs on the `nilu` command, and both want to
know one thing from a version number: will what I have still work. Semantic Versioning answers
that from `1.0.0` on, but says of `0.y.z` only that anything may change.

## Decision

- **The number is a Semantic Version.** The first release is `0.1.0`.
- **Below `1.0.0` it is read the way Cargo reads `0.x`:** the minor moves when something that
  worked on the last release stops working or answers differently — a program, a host, or a
  command line. The patch moves otherwise: an addition, or a fix that makes the answer what the
  manual or the header already promised. The test is whether a promised answer changed; a fix
  that withdraws a promise moves the minor.
- **From `1.0.0` the reading is Semantic Versioning's own.** `1.0.0` is kept for when Nilu is
  finished, as Zig keeps it.
- **Between releases the number is the next release's, with `-dev.N` after it** — `0.1.0-dev.97`
  precedes `0.1.0`, as Semantic Versioning orders a pre-release. The shape is borrowed from Zig's
  development builds.
- **The version is stated in the header.** `NILU_VERSION` is the whole string, suffix included,
  and `nilu -v` prints it. `NILU_VERSION_MAJOR`, `_MINOR` and `_PATCH` are the release's three
  numbers, and `NILU_VERSION_NUM` combines them as `MAJOR * 10000 + MINOR * 100 + PATCH`, the
  way Lua's `LUA_VERSION_RELEASE_NUM` combines its three — so a development build compares equal
  to the release it precedes.
- **A release carries the `nilu` binaries for each release target `build.zig` lists, and a `SHA256SUMS` file**, both
  written by `zig build dist`.

[11.1](../../doc/en/11-nilu-command.md#111-how-to-run-it) shows `nilu -v`.

## Why

- At `0.x` there is room for one answer in the number, and the useful answer is "this may break
  what you have". Cargo's reading puts it in the minor. Spending the minor on "something was
  added" would tell a reader what the manual already says.
- `1.0.0` is a promise that the design is settled. Nilu keeps it until that is true, rather than
  reaching it by counting.
- A development build that names the release it is heading for, with a count after it, can be
  told apart from a release by reading one string, and sorts before it.
- A checksum written by the build, and not by hand, is a claim something measured.

## Consequences

- A host that must tell a development build from a release reads `NILU_VERSION`, not
  `NILU_VERSION_NUM`; Lua's shape for the number has no room for a pre-release.
- Whether a change breaks something is a judgement, made by the change that moves the number and
  stated with it.
- Renaming or re-signing a function in the header is a break, and moves the minor
  ([0002](0002-a-closed-c-stack-api.md)).
- A signature on a release is not provided; the checksum verifies a download, not its publisher.

## What would reverse it

- A reader who needs the number to say more than "will it still work" — for instance, which
  additions arrived. That is a reason for a change log beside the number, not a different reading
  of it.
- Deciding that Nilu is finished. Then the next release is `1.0.0`, and Semantic Versioning's own
  reading begins.
