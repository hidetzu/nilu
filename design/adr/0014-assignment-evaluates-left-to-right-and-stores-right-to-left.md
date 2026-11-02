# 0014 — An assignment evaluates left to right and stores right to left

**Status:** accepted. The owner approved the whole: the schedule, the loop variables' lifetime
and one identity per declaration.

## Context

Lua's manual leaves the order of evaluation in an assignment undefined, and says nothing about
when a target's receiver and key are evaluated against the right side. A program with
duplicate targets (`a[i], a[j] = 1, 2` with `i == j`), with a target whose key a right-side
call changes, or that replaces `_ENV` on the left sees whatever order the implementation
happened to choose. A closure made in a generic `for` body needs to know whether it captured
this turn's variable or one shared by every turn.

## Decision

- **An assignment has one schedule.** First the receiver and key of every target on the left
  are evaluated, from left to right, and kept. Then the right-side expressions are evaluated
  from left to right, with the usual adjustment of their counts. Then the targets are written
  from right to left. Duplicate targets and an assignment that replaces `_ENV` follow the same
  schedule: a global target keeps the environment selected before the right side. Indexed
  function definitions (`function t.a.b() … end`) prepare their target the same way. A
  `local function` is bound before its body is compiled, so it can call itself. A `global`
  declaration with a value (`global x = 1`, `global function f() … end`) keeps its own check
  that the global is still nil ([3.4](../../doc/en/03-variables.md#34-the-global-declaration)).
- **A failure stops at its place in that schedule.** A failure while evaluating a receiver or a
  key comes before one on the right side; checking a receiver or a key for a store, and running
  its `__newindex`, happens when that store runs. Stores already made, and other side effects,
  are not rolled back.
- **Each turn of a generic `for` has fresh variables.** A closure made in the body captures
  that turn's variables. Their cells close before the next call of the iterator, including the
  call that ends the loop or fails, and on every way out of the loop. The first variable is
  read-only; the others can be assigned.
- **One analysis names every variable.** The pass that resolves names gives each declaration an
  identity, and the compiler places storage and captures by those identities rather than
  resolving names a second time.

The manual states the schedule in [4.1](../../doc/en/04-statements.md#41-assignment) and the
lifetime of a loop's variables in [4.5](../../doc/en/04-statements.md#45-generic-for).

## Why

- A schedule a program can rely on is one the manual can state and a test can check; "the
  order the compiler happened to emit" is neither.
- Evaluating the left side's receivers and keys first is what lets a swap through an index,
  `t[i], t[j] = t[j], t[i]`, mean what it says. Writing right to left gives what `lua5.5`
  gives for duplicate targets: `a, a = 1, 2` leaves `a` as `1` in both (checked on 2026-11-02 against lua5.5 5.5.1).
- A fresh variable per turn is what a closure made in a loop expects, and what Lua gives.
- Two passes that each resolved names could disagree; one identity per declaration cannot.

## Consequences

- The register VM needs no new instruction: an indexed target uses the existing store, and the
  kept receivers, keys and values stay in registers the collector sees until the last store.
- Where Lua's implementation answers differently for a program whose result depends on the
  order, Nilu's schedule decides.

## What would reverse it

- Deciding that the order is unspecified, as in Lua's manual. Then the schedule becomes an
  implementation detail, and the manual and the tests that pin it would go.
