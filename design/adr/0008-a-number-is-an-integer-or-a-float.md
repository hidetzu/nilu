# 0008 — A number is an integer or a float, and a string never becomes one by itself

**Status:** accepted. The owner's decisions: Lua's integers and floats; no conversion between
strings and numbers except that a number joins text; `string.format` gives C's results.
The owner chose these so that a program from Lua keeps its numbers.

## Context

Lua 5.5 has two kinds of number, integers and floating-point numbers, and converts between
strings and numbers on its own: `"10" + 1` is `11`, and `1 .. 2` is `"12"`. Two kinds of
number need two sets of rules, for arithmetic, comparison, table keys, printing and overflow,
but they let a program hold a 64-bit identifier, a hash or a bit pattern exactly. Automatic
conversion makes what an operator does depend on what a string happens to contain.

## Decision

- **A number is an integer or a float, as in Lua 5.5.** Both are of type `"number"`;
  `math.type` tells them apart. An integer is 64-bit two's complement and wraps around; a float
  is a 64-bit IEEE 754 number.
- **The operators are Lua's.** `+`, `-`, `*`, `//`, `%` and unary `-` of two integers give an
  integer, and a float otherwise; `/` and `^` give a float. A bitwise operator converts a float
  with an integer value and refuses any other (`number has no integer representation`). An
  integer and a float compare by their exact values. An integer `//` or `%` by the integer 0 is
  a runtime error with Lua's words: `attempt to divide by zero` and `attempt to perform 'n%0'`.
- **Numerals are Lua's.** A fraction point or an exponent makes a float. A decimal integer
  numeral past 64 bits is read as a float; a hexadecimal one wraps around.
- **A float with an integer value is the same table key as that integer.**
- **A numeric `for` is Lua's:** an integer loop when the start and the step are integers, with
  the limit clipped as Lua's `forlimit` clips it, and no overflow past the limit.
- **A string never becomes a number by itself, and a number never becomes a string by
  itself.** An arithmetic operator applied to a string is a type error, a library argument
  that expects a number does not accept a string (`math.tointeger("8")` is `nil`), and one
  that expects a string does not accept a number (`string.rep(1, 2)` is refused). `tonumber`
  and `tostring` are where conversion happens, with the one exception below.
- **The exception: a number joins text.** `..` and `table.concat` take a number and write it
  as `tostring` spells it, as does `string.gsub`'s replacement.
- **An integer prints in decimal. A float prints in the shortest digits that read back to the
  same value, and keeps `.0` when its value is whole.** `string.format`'s conversions give C's
  results: `%f`, `%e` and `%g` round the exact binary value, `%a` writes its bits, and `%q`
  writes an integer in decimal and a float in hexadecimal, as Lua's does.
- **The library is Lua 5.5's where an integer is concerned:** `math.floor`, `math.tointeger`,
  `math.maxinteger`, `math.random(0)`, `string.pack`, `string.format`'s `%d` and `%x`,
  `os.time` and `io` positions answer as Lua's do, apart from the rule on strings above.
- **The C API is Lua's set:** `NiluInteger` (`long long`), `NILU_MAXINTEGER`,
  `NILU_MININTEGER`, `nilu_pushinteger`, `nilu_tointegerx` with the `nilu_tointeger` macro,
  and `nilu_isinteger`. `nilu_checkinteger` and `nilu_optinteger` take any 64-bit integer, or
  a float with an integer value.

How a value holds an integer is [0007](0007-a-value-is-eight-bytes.md). The manual shows
numbers in [2.3](../../doc/en/02-values.md#23-numbers) and what becomes a type error in
[8.3](../../doc/en/08-failure.md#83-what-becomes-a-type-error).

## Why

- Lua's model means a program from Lua keeps its numbers, and 64-bit work — identifiers,
  hashes, bit manipulation — is possible without losing bits past 2^53.
- Without conversion from strings, an operator means one thing: whether `a + b` works is
  decided by the types of `a` and `b`, not by what a string spells. Arithmetic on text is where
  conversion surprises.
- Joining a number into text is unambiguous: there is only one text a number can become.
- The shortest spelling that reads back means `tonumber(tostring(x)) == x` holds for every
  finite number, and a number prints the same way wherever its spelling is used. Lua prints
  `1/3` with 17 significant digits; Nilu prints the 16 that are enough to read it back.

## Consequences

- `string.gsub("a", "a", 1)` gives `1`, and `"n=" .. 1.5` gives `n=1.5`; `"10" + 1` fails
  with `attempt to perform arithmetic on a string value (constant '10')`.
- The differences that follow are listed in
  [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) as decided, and
  [14.3](../../doc/en/14-porting.md#143-how-a-number-is-spelled) is what a port from Lua has to
  change because of them.

## What would reverse it

- Automatic conversion from strings would need a decision about which operators convert and
  which do not, and a reason that outweighs "an operator means one thing".
