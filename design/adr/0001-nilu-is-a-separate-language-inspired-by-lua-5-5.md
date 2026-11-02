# 0001 — Nilu is a separate language inspired by Lua 5.5

**Status:** accepted.

## Context

Nilu is a small scripting language meant to be embedded in a host program. Most of what it
needs — a grammar, a value model, metatables, a standard library, a C API shaped around a
stack — Lua 5.5 has already answered, and answered carefully. Copying those answers is
cheaper and safer than inventing new ones.

But Nilu is not an implementation of Lua. It is written from scratch in Zig, it never turns a
string into a number by itself, and there are things Lua has that Nilu has not built. A reader
who assumes "Lua" will be wrong in specific places, and needs to know which places and why.

## Decision

Nilu is a separate language inspired by Lua 5.5. It borrows much from Lua and claims no
compatibility with it.

- **Where Lua 5.5 answers a question, Nilu borrows the answer — but only after reading Lua's
  source.** A behaviour borrowed without reading the source is an invented behaviour with a
  citation attached. Where the answer can be measured, it is measured against the `lua5.5`
  binary as well.
- **A change from Lua is the owner's decision.** Implementing something is never how a
  question about the language gets settled. That holds for the grammar, the values, the
  metamethods, the library, the error a program gets and the C API.
- **What Nilu does not share with Lua is one of four kinds, and the manual keeps them apart.**
  - *Decided and changed*: the owner chose a different answer, for a stated reason — no
    conversion from a string to a number is the main one
    ([0008](0008-a-number-is-an-integer-or-a-float.md)).
  - *Differs because a mechanism is absent*: Lua's answer needs something Nilu does not have,
    such as a C library in the core or a clock ([0003](0003-the-core-touches-nothing-outside-itself.md)).
    The difference is named, and so is what is missing.
  - *Not there yet*: what Lua has and Nilu has not built. It is not a difference of design: it
    says what would be needed.
  - *Where Lua says nothing*: Nilu's answer is its own, and is not a promise.

[Chapter 13 of the manual](../../doc/en/13-differences-from-lua.md) holds all four, row by row,
with what Lua does and what Nilu does.

## Why

- A host author or a script author who knows Lua should be able to rely on that knowledge
  everywhere except the places listed. Borrowing names and behaviour exactly is what makes
  that possible; a name that is Lua's but behaves differently is worse than a new name.
- Reading the source, rather than the reference manual alone, is what makes "borrowed" a
  checkable claim. The manual describes; the source decides.
- Keeping "decided" apart from "a mechanism is absent" tells the reader what to expect next.
  A decision is reversed only by an argument against its reason. An absent mechanism may
  arrive, and then the difference closes.
- The design of the language is the point of the project. A language question settled by
  whoever happens to write the code would take that away.

## Consequences

- Names in the C API are spelled the way Lua spells them where the function does what Lua's
  does (`nilu_pushinteger`, `nilu_settop`, `nilu_pcall`); the header documents each one
  ([0002](0002-a-closed-c-stack-api.md)).
- Where Lua itself leaves something unspecified — the order of `pairs`, which border `#`
  answers for a table with holes, how `tostring` spells an identity — Nilu is unspecified too,
  and [13.5](../../doc/en/13-differences-from-lua.md#135-where-lua-says-nothing) says so.
- A difference that is not in chapter 13 is a defect, either in the implementation or in the
  manual.
- The cost: every borrowed behaviour has to be traced to Lua's source, and every difference has
  to be written down with its kind and its reason.

## What would reverse it

- Deciding that Nilu should be compatible with Lua. Then every row of [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) becomes a bug, and
  the decisions recorded in the other ADRs here have to be revisited.
- Deciding that Nilu no longer follows Lua by default. Then each borrowed behaviour would need
  its own reason, and this record would be replaced by one that states the new default.
