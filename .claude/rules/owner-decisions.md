# Owner decisions

`MUST` = required, `SHOULD` = default, `MAY` = optional.

## Grounds

Stalling costs more than deciding, but a decision the owner cannot walk back costs more than
either. And the language is the owner's design — designing it is the point of the project — so a
decision about what Nilu is is never made here, however obvious the answer looks, and however
clearly Lua 5.5 answers it.

## Decide yourself vs. ask

The default is: decide, carry it through, and write it in the change's issue.

| Decide yourself | Ask |
|---|---|
| Implementation order, how to split a change, where tests go | Anything about the language the record does not settle — syntax, semantics, the error a program gets, the library, the header, the command's behaviour |
| Internal structure: names, files, limits, data layout | Anything a human reads that the record does not already say word for word |
| What to measure and how | Two presentable options that measurement cannot settle |
| A bug with exactly one sensible fix | A layer split, or a new stage in the pipeline |
| How the checks and the tooling are built | Anything outside this repository: another repository, making anything public |

- MUST: Ask with `AskUserQuestion`. Never bury a question in prose.
- MUST NOT: Never ask what measuring or reading the record would settle. Read and measure first.
- MUST: Finish everything that does not depend on the answer before asking.
- MUST: Record what was asked and the answer in the change's issue.
- MUST: A change made without asking that turns out to be the owner's is brought to the owner
  afterwards, and recorded either way.

## A recorded decision outranks your judgement

- MUST: Follow a recorded decision exactly; never change one on your own judgement. In order of
  authority: the owner's answers, the carried documents (manual, `design/README.md`, `design/adr/`),
  the carried C cases and fixtures.
- MUST: A later record overrides an earlier one; check the dates.
- MUST: When two records conflict and you cannot tell which is authoritative, ask.
- MUST NOT: Nothing outside this repository is an authority.
