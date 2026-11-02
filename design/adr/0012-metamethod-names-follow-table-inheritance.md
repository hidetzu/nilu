# 0012 — Metamethod names follow table inheritance

**Status:** accepted. The rule and its boundaries are the owner's decisions.

## Context

Lua reads every metamethod raw from the value's metatable: a metatable that inherits from
another through `__index` does not inherit its `__add` or its `__call`. A class built that way
has to copy every metamethod into each subclass's metatable. Nilu's names are inherited
instead. This is a difference from Lua; the tests that compare Nilu with answers captured from
`lua5.5` keep Lua's answer and assert this difference.

## Decision

- **A metamethod is found by walking the metatable's table-valued `__index` chain.** Start at
  the receiver's metatable and read the name raw. If it is absent, follow that table's
  metatable's `__index` when it is a table, and repeat. The links themselves are read raw; a
  function-valued `__index` is never run to find a metamethod, and finding one runs no script.
- **One walk serves every metamethod read:** `__index`, `__newindex`, the operators,
  comparisons, `__eq`, `__len`, `__call`, `__close` and the diagnostic `__name`. The library reads
  `__tostring`, `__name` and `__pairs` through `nilu_getmetafield`, the C API's view of the
  same walk, so there is one answer to "which metamethod".
- **The walk is the ordinary `__index` chain's,** and its failure is a runtime failure, never a
  missing metamethod: answering nil would turn a lookup that failed into a handler that is not
  there. Up to 2000 links are followed and the table
  after the last link is still read, so a name is found exactly where `mt[name]` would find it,
  minus a function `__index`. A miss past that, whether the chain is long or cyclic, is the
  same runtime failure as an ordinary chain, `'__index' chain too long; possible loop`, at the
  instruction that needed the name. The walk allocates nothing.
- **`__gc`, `__mode` and `__metatable` are read where they are written.** They describe the
  metatable itself — whether it may be replaced, whether it carries a finaliser, what it makes
  weak — not what the value does. A refusal that walked links would be incomplete: a
  `__gc` added to a base after attachment could not be refused.
- **A failure's sentence never fails.** When the walk for a diagnostic `__name` runs out, the
  plain type word is used, and the failure being reported is kept.
- **Explicit raw operations stay raw.** `nilu_getmetatable` gives the actual metatable.

For example, with `Base.__call = f` and a receiver whose metatable `mt` has a metatable with
`__index = Base`, calling the receiver calls `f`. Replacing that `__index` with a function does
not run it to find `__call`. The manual states the rule in
[7.4](../../doc/en/07-metatables.md#74-operators) and the difference in
[13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs).

## Why

- One base metatable can hold the names for many. Python and PHP find their special methods
  along the class chain in the same way, without running `__getattr__`.
- Reusing the `__index` chain's budget and sentence means one rule a reader already knows, and
  no third limit.
- A walk that runs no script cannot fail halfway through a lookup with side effects.

## Consequences

- Calling a value whose `__call` is itself a callable table follows a chain of up to 1999 such
  values, and finding each one's `__call` may walk up to 2000 links, reading the name and the
  link at each: about eight million raw table reads at the worst (2000 × 2000 × 2). The owner accepted that cost over a
  third limit.
- A program from Lua that relied on a metamethod not being inherited behaves differently.

## What would reverse it

- Deciding that Nilu follows Lua here. Then every read becomes raw again, and [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) loses the
  row.
