# 0007 — A value is eight bytes

**Status:** accepted. Which NaNs may change is the owner's decision, and the owner asked for the
eight-byte value before publication. How an integer is held is an implementation choice, not the owner's.

## Context

Every register, stack slot, table entry and upvalue holds a value, and copying values is most
of what the VM does. A value made of a tag word and a payload word is sixteen bytes. A float
already uses all 64 bits, but the NaN space has room that arithmetic never produces.

## Decision

A value is one 64-bit word. A float is its binary64 bits. Every other value is a pointer or a
small payload in the low 48 bits, under a tag in the top 16 bits taken from the NaN space that
arithmetic does not produce:

| top 16 bits | value |
|---|---|
| `0xFFF9` | nil (payload 0), false (1), true (2), an inline integer, a thread, a boxed integer |
| `0xFFFA` | string |
| `0xFFFB` | table |
| `0xFFFC` | userdata |
| `0xFFFD` | native function |
| `0xFFFE` | C closure |
| `0xFFFF` | script closure |

- **Any other bit pattern is a float.** A float made from outside the core's own arithmetic
  (the library, `string.unpack`, the C API, numeral reading) whose top 16 bits fall in
  `0xFFF9`–`0xFFFF` is replaced by the negative quiet NaN `0xFFF8000000000000`. Those are the
  negative NaNs with any of bits 48–50 set. Every other NaN keeps its bits, sign and payload
  included. Arithmetic needs no such check: its inputs follow this rule, and IEEE 754
  operations return either the default NaN or a quieted input NaN, which is still a float.
- **An integer in [-2^45, 2^45) is the value itself:** the tag `0xFFF9` with the low two bits
  of the payload set. nil, `false` and `true` are the payloads 0, 1 and 2, and a thread or a
  boxed integer is an aligned address, so none of them has both bits set.
- **The integer n is held as `inline_zero + 4n`,** an offset form: the bits of two such values
  order as the integers do, and their sum or difference is their bits added or subtracted, less
  or plus one `inline_zero`. Addition, subtraction and comparison of two of them need no
  decoding.
- **Any other integer is a boxed integer,** a heap object under the same tag, told from a
  thread by its header. Each integer has exactly one form, so two inline integers are equal
  exactly when their bits are.

## Why

- Registers, stack slots, the table's array part and its hash entries are half the size of a
  two-word value, and copying a value is one machine word.
- Some NaN patterns cannot be kept in an eight-byte value. The choices were to give up only the
  negative NaNs under the tags, to make every NaN one pattern as LuaJIT does, or to keep
  sixteen-byte values; the owner chose the first. With sixteen-byte values, `string.pack("<d", x)` of
  NaNs with payloads, packed again after `string.unpack`, gave the same bytes in Nilu and in
  Lua 5.5.1; with this rule only those negative NaNs change.
- Keeping most integers in the value keeps a counter or an index free of allocation; 2^45 is
  past any count or index of something in memory.
- Bit 47 was not used to mark an integer: an aarch64 Linux process can have user addresses
  past 2^47, and aarch64 Linux is a release target.

## Consequences

- The release targets are all 64-bit, and their user-space pointers must fit in 48 bits;
  packing a pointer checks this in safe builds.
- The collector reads a value's pointer through the same decoding as the VM; what is a root
  does not change ([0005](0005-the-state-owns-every-object-and-a-collector-frees-what-nothing-reaches.md)).
- An integer past 2^45 allocates, and its arithmetic takes the general path.
- An integer turn of a `for` loop and an integer `+` each test their operands' kind.

## What would reverse it

- Boxed integers measured as a cost in real programs — hashes, 64-bit identifiers in hot
  loops: that is the argument for a wider value or another split of the tag space.
- A release target whose user addresses do not fit in 48 bits.
