# Verification

`MUST` = required, `SHOULD` = default, `MAY` = optional.

Grounds: a clean build says nothing about what the thing does, and a check that agrees only with
itself has proved nothing.

## The tiers

| Tier | Here | What it cannot show |
|---|---|---|
| Fast / inner | `zig build fmt-check`, `zig build docs-check`, `zig build test -Dtest-filter=…`, `node tools/docs-check.mjs --only=<case>` | How the whole behaves |
| Stage gate | `zig build stage-check --summary all` | Anything still pending |
| Final gate | `zig build check`, the command CI runs; fails while any required stage is pending | How anything we did not write behaves |
| External | The other end is something we did not write: the captured Lua answers, the carried C cases, CLI fixtures and manual examples | It is not evidence about our code when the other side is what failed |

- MUST: At least one check has the other end be something we did not write.
- MUST: A green `stage-check` is never reported as the round, or the language, verified.

## Every entry point runs in part

- MUST: Run one named case only, list without running, and announce on the first line which subset
  ran and how many.
- MUST: Compare `node tools/list-tests.mjs --count` with the count the runner announces; a
  declared test is not a test that ran.

## Am I measuring what I think I am measuring?

- MUST: Confirm the thing under test is the one just built. A stale `zig-out/` measures the
  previous build.
- MUST: Confirm the toolchain: `zig version` must say the version `.mise.toml` pins.

## Order

1. Fast / inner while fixing; stop at the first failure.
2. The final gate before the pull request; it is what CI runs. Green in the inner loop is not "it passed".
3. After any fix, run the whole order again.

## Split the failure before blaming yourself

- MUST: Say plainly which side failed. An external failure is still a `FAIL`, but not evidence
  that our code broke.
- MUST NOT: Never edit code to make a check go quiet, and never edit a carried check or document
  to make it pass. A carried check that our code cannot pass is a finding about our code or about
  the record, and it goes in the change's issue.

## When something is fixed

- MUST: Every fixed bug leaves a check behind.
- MUST: Break the code on purpose and watch the check fail, and read the failure text to confirm it
  failed for the reason intended. Commit before mutating, and undo a mutation by restoring the copy
  you took, never by asking git.
- MUST: A mutation that passes is either a check that does not assert the claim or an edit that
  missed. Read the diff to tell them apart; never rerun and hope.

## What to return

```
Verdict: PASS / FAIL / NOT-VERIFIED

Ran:            <entry point>  <result>  <count as announced>
Failed:         <failure text, verbatim>; ours or external
Not verified:   <which check did not run or is pending, and why>
Regression guard: EXISTING / ADDED-AND-PROVEN / NONE (why)
Mutation check: <with the fix removed, the failure text verbatim>, or "not applicable"
```

- MUST NOT: Never write `PASS` while a check went unrun or a stage is pending.
- MUST: `EXISTING` means it was seen to catch it. Merely adding a check is not `ADDED-AND-PROVEN`.
- MUST: Green CI means nothing contradicted what was asserted, not that the record is right.

## What to confirm first

1. Parsing and validation of what arrives from outside (source text, C arguments)
2. State transitions
3. Malformed, truncated, hostile and absent input
4. The path a user actually takes end to end
5. Performance detail

- MUST NOT: Never pile up checks that pin the implementation's steps. Test the contract.
