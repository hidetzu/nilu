# Evidence

`MUST` = required, `SHOULD` = default, `MAY` = optional.

Grounds: this is the subject. Every other rule can be re-argued for a domain; this one cannot. A
project that softens it stops being able to say what it knows.

## The lines that do not bend

```text
not observed           ≠  did not happen
could not be obtained  ≠  not there
the test passed        ≠  the behaviour is correct
it answered            ≠  it answered for the right reason
```

- MUST: Never call something verified when it was not checked.
- MUST: Never report "absent" for something that was merely not obtained.
- MUST: Never dress a guess up as a measurement.
- MAY: Add a line for this domain. Never remove one.

The question is never "did the test pass". It is "does that test actually assert the claim".

## Silence is not permission

- MUST: `MUST` / `SHOULD` / `MAY` are different things, and "the record does not say" is a fourth.
- MUST: Say which authority a behavioural claim comes from, and which section of it — the manual,
  the header, an ADR, Lua 5.5's source. "It seemed right" is not an authority.
- MUST: Where the authority is silent, say it is silent — not that it permits, and not that it
  forbids. A silence about the language is an owner question (`owner-decisions.md`).

## Outcomes are not one outcome

| Outcome | What it must not be confused with |
|---|---|
| Accepted and handled | — |
| Malformed — it violates the format | Not the same as unsupported. The other side is wrong |
| Well-formed but unsupported — understood and declined | Not the same as malformed. The other side is fine |
| Not implemented yet | Never phrased as the other side's fault |

- MUST: Name only the outcomes that can occur, and say the rest cannot.
- MUST: Record why something was rejected, at least well enough to count it.

## Numbers and counts

- MUST: Always give the denominator of a claim.
- MUST NOT: Never write a number that was not measured.
- MUST: A measurement records when, where and how: the versions that matter, the environment, how
  many runs.
- MUST NOT: Never write a count into a document; it is stale from the moment it is written.
- MUST: Whatever produced a count announces it when it runs; copy the announced number into the
  report, as announced.
