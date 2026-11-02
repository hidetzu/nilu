# 0006 — A young collection marks only what is new or written

**Status:** accepted. Decided under the owner's allowance for design changes made for speed; the
owner ranked it second among the options, after the call path.

## Context

A collector that marks everything reachable and sweeps every object each time does work in
proportion to the whole heap, even when most of what it marks has not changed. With a small
live heap, the standard library's objects were most of what each collection marked again; with
a large one, a table a program keeps was marked again at every collection. Measured on
2026-11-02 on an AMD Ryzen 7 5700X, the collector took 29% of the time of
`bench/closures.nilu`, which makes closures in a loop, and 40% of `bench/strkeys.nilu`, which
keeps a 200 000-entry table.

## Decision

- **Marks are sticky.** An object that survives a collection keeps its mark and is old.
  A new object is young: unmarked.
- **A young collection** marks from the roots
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)) as
  a full one does. Marking passes over a marked object, so it stops at every old one. It also
  marks what the old objects written since the last collection now hold, then sweeps the young
  objects alone — those made since the last collection. A young object that survives becomes
  old. A collection that comes due by itself
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)) is
  a young one unless a full one is due.
- **A full collection** clears every mark first and then marks and sweeps everything. One runs
  when the old objects have doubled since the last full collection, whenever a program or host
  asks for one (`collectgarbage()`, `nilu_gc`), and after a failure's rollback freed an object
  the young collection uses to tell old from young.
- **The write barrier.** Before a reference is stored into an object, the store tests one byte
  of the object's header; an old object that is not yet remembered is put on the remembered
  list, chained through a field no collection is using then. This is Lua's "barrier back".
  It sits at every store into a table, a cell, a metatable, a userdata's user values, a C
  closure's upvalues, a thread's saved state and a failure origin's record. In a safe build, a
  table's mutating methods assert that an old table was remembered before it is written.
- **Nothing moves.** A host holds pointers into strings (`nilu_tolstring`) and userdata
  bytes, so a copying nursery is ruled out.
- **Weak tables need nothing more.** A young object can enter an old weak table only by a
  store, which remembers the table, so a young collection traverses it and clears its dead
  entries. An entry pointing to an old object stays until a full collection, since only a full
  collection frees old objects. Whether a weak entry's referent is alive is still its mark,
  and an old object's mark is set.
- **A safe build checks every young collection.** Before sweeping, it marks everything again
  from the roots alone, with the old objects' marks set aside. A young object about to be freed
  that this marking reaches is a store that skipped the barrier, and the build stops there. The
  test suite runs in safe builds, so a missing barrier that a test exercises fails it.

## Why

- Most objects die young: the collector's work becomes the young objects and the written
  old ones, not the whole heap.
- Lua 5.4 and 5.5 offer the same kind of collector, without moving, as their generational
  mode, with the same backward barrier.
- The barrier and the check make the one silent failure the collector has
  ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md))
  loud in tests.
- Measured on 2026-11-02 on an AMD Ryzen 7 5700X with `tools/speed.mjs --runs=3` over ReleaseFast builds (Zig 0.17.0), in four code
  layouts (see `tools/README.md`), against whole collections every time: `strkeys` ran in
  0.825 of the cycles, `closures` in 0.848, and the geometric mean over every script in
  `bench/` was 0.975. The barrier on every global assignment made `globals` 1.041.

## Consequences

- Garbage that is alive at a young collection becomes old and waits for a full collection, so
  memory between full collections is higher than with whole collections every time.
- `collectgarbage`'s `"incremental"`, `"generational"` and `"param"` are refused: there is one
  method, and it decides by itself ([9.4](../../doc/en/09-gc.md#94-what-there-is-not)).
- Every store site needs the barrier; a new one that forgets it fails the safe-build check
  only where a test exercises it.

## What would reverse it

- A program shape where old objects are written so often that the remembered set approaches
  the old generation: then a young collection costs a full one plus the barrier.
- A need for bounded pauses: that is an incremental collector, a different change.
