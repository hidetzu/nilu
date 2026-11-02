[← Contents](README.md)

# 2. Values and types

A program can write six kinds of value. There is one more, `userdata`, which the host passes in (explained after the table below).

| Type | The string `type` answers | How it is written |
|---|---|---|
| nil | `"nil"` | `nil` |
| boolean | `"boolean"` | `true`, `false` |
| number | `"number"` | `1`, `3.5`, `0x10`, `1e9` |
| string | `"string"` | `"こんにちは"` |
| table | `"table"` | `{}` |
| function | `"function"` | `function(x) return x end` |

```lua nilu
print(type(nil), type(true), type(1), type("a"), type({}), type(print))
```
```output
nil	boolean	number	string	table	function
```

A number is an integer or a float, as in Lua ([2.3](#23-numbers)). A coroutine is a value of type `thread`, made by `coroutine.create` ([10.8](10-library.md#108-coroutines)).

**`userdata` exists**.
But **a program cannot make one** — the host makes it with `nilu_newuserdata` and passes it in,
and `type` answers `"userdata"` ([12.6](12-embedding.md#126-giving-a-program-the-hosts-data-to-carry)).
That is why it is not in the table above.

## 2.1. nil

The value that stands for the absence of a value. A variable nothing has been put into holds `nil`.

```lua nilu
local x
print(x)
print(y)
```
```output
nil
nil
```

The `y` on the second line is not declared. An undeclared name is a global variable, and
a global variable nothing has been put into is `nil` ([3. Variables and scope](03-variables.md)).

Putting `nil` into a table is the same as removing that key.
So "a key that was never set" and "a key that was set to `nil`" cannot be told apart.

## 2.2. Booleans

Only `false` and `nil` are false; **everything else is true**. `0` and `""` are true too.

```lua nilu
print(not nil, not false, not 0, not "")
```
```output
true	true	false	false
```

This is the same rule as Lua's. It is where someone coming from C or Python trips once, without fail.

## 2.3. Numbers

A number is an **integer** or a **float**, as in Lua: an integer is 64 bits in two's complement
and wraps around past them, and a float is a 64-bit IEEE 754 double. Both are of type `"number"`;
`math.type` tells them apart.

```lua nilu
print(type(1), type(1.5), math.type(1), math.type(1.0), math.type(2^53))
```
```output
number	number	integer	float	float
```

An integer and a float with the same value are equal, and they are the same key in a table:
`t[2.0]` is `t[2]`.

### How they are written

A numeral with a fraction point or an exponent is a float; any other is an integer. A decimal integer
numeral too large for 64 bits is read as a float, and a hexadecimal one wraps around, as in Lua.

```lua nilu
print(1, 3.5, .5, 1e2, 1E-2)
print(0x10, 0xff, 0x1p4)
print(9223372036854775807, 9223372036854775808, 0xffffffffffffffff)
```
```output
1	3.5	0.5	100.0	0.01
16	255	16.0
9223372036854775807	9.223372036854776e+18	-1
```

- Decimal is `3`, `3.5`, `.5`, `3.`, and an exponent is `1e9`, `1E-2`
- Hexadecimal starts with `0x`, and a binary exponent can be written, as in `0x1p4`
- There is no digit separator `_` (`1_0` is not a number)
- A number cannot be written with the spelling `inf` or `nan`. If you want infinity,
  it is `math.huge`; if you want NaN, it is `0 / 0`

### How they print

`tostring` (and `print`) writes an integer in decimal, and a float in **the shortest digits that read
back**. A float with a whole value keeps `.0`, as in Lua, so the two kinds print apart.

```lua nilu
print(1)
print(1.0)
print(0.1)
print(1 / 3)
print(2 ^ 53)
print(10 / 2)
```
```output
1
1.0
0.1
0.3333333333333333
9007199254740992.0
5.0
```

Lua writes a float in 15 significant digits, or 17 when 15 do not read back (`0.33333333333333331`);
Nilu writes the fewest that do.

Very large and very small floats take exponent form.

```lua nilu
print(1e15)
print(1e16)
print(1e-5)
```
```output
1e+15
1e+16
1e-05
```

That the written string reads back is guaranteed. What `tostring` writes,
`tonumber` reads.

```lua nilu
print(tonumber(tostring(1 / 3)) == 1 / 3)
print(tonumber("0x10"), tonumber("  12  "), tonumber("12a"))
```
```output
true
16	12	nil
```

`tonumber` allows whitespace before and after, but not leftover characters. If it cannot read it, the answer is `nil`.

## 2.4. Strings

A string is a sequence of bytes. Nothing is promised about its encoding. Its length is its byte count.

```lua nilu
print(#"abc")
print(#"あ")
```
```output
3
3
```

`"あ"` is 3 because the source is written in UTF-8 and those bytes go in as they are.
Nilu does not interpret the contents.

⚠ **A variable name or a field name, however, is ASCII only.** The contents of a string may be
any bytes, but a name may use only letters, digits and `_`, and must start with a letter or `_`.

```lua nilu-refused
local あ = 1
```

As a table key, any string will do. `t.ある` cannot be written, but
`t["ある"]` can.

```lua nilu
local t = {}
t["ある"] = 1
print(t["ある"])
```
```output
1
```

### Escapes

**Every one of Lua's is here**.

| Spelling | Meaning |
|---|---|
| `\\` | a backslash |
| `\"` | a double quote |
| `\'` | a single quote |
| `\n` | a newline |
| `\r` | a carriage return |
| `\t` | a tab |
| `\a` `\b` `\f` `\v` | bell, backspace, form feed, vertical tab |
| `\xXX` | one byte, from exactly 2 hexadecimal digits |
| `\ddd` | one byte, from 1 to 3 decimal digits (up to 255) |
| `\u{XXX}` | the UTF-8 of that code point (up to `7FFFFFFF`) |
| `\z` | nothing. **It skips the whitespace and newlines that follow** |
| `\` and a newline | a newline |

```lua nilu
print("a\tb")
print("q\"q", 'q\'q')
print("\x41\66\u{3042}")
print("1\z
       2")
```
```output
a	b
q"q	q'q
ABあ
12
```

Any other backslash is a syntax error. A raw newline cannot be written inside `"…"` or `'…'`
— to include a newline, use `\n`, `\` and a newline, or the long string that follows.

### Long strings

Enclosing text in `[[` and `]]` gives a string that **reads no escapes and includes newlines as they are**.
With `=` between the `[` and the `[` (`[==[ … ]==]`), it runs until a `]==]` with the same number of `=`.
**A newline right after the opening bracket is not part of the string.**

```lua nilu
local s = [[
一行目
二行目]]
print(s)
print([==[a]]b]==])
print(#[[\n]])
```
```output
一行目
二行目
a]]b
2
```

The last line is the 2 bytes `\` and `n`. Inside a long string a backslash is just a character.

### Concatenating, comparing

```lua nilu
print("a" .. "b" .. "c")
print("a" < "b", "abc" < "abd", "Z" < "a")
print("1" == 1)
```
```output
abc
true	true	true
false
```

Comparison is by byte order. `"Z" < "a"` is true because that is how ASCII orders them.

`..` joins strings, and **a number joins as `tostring` spells it**.

```lua nilu
print(1 .. 2, "n=" .. 1.5)
```
```output
12	n=1.5
```

**Arithmetic does not turn a string into a number**, as it does in Lua.

```lua nilu
return "10" + 1
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a string value (constant '10')
```

## 2.5. Tables

The only container. An array, a dictionary and an object are all tables.

```lua nilu
local t = {}
t[1] = "いち"
t["key"] = "値"
t.field = "これも"
print(t[1], t["key"], t.field)
```
```output
いち	値	これも
```

`t.field` is another spelling of `t["field"]`. They mean exactly the same thing.

### A table can be made with its contents written out

There are 3 spellings, and **they can be mixed in one constructor**.

```lua nilu
local list = {10, 20, 30}
local point = {x = 1, y = 2}
local computed = {["k"] = "文字列のキー", [1 + 1] = "計算したキー"}
local mixed = {10, x = 1, [3] = 30}
print(list[2], point.x, computed[2], mixed[1], mixed.x, mixed[3])
```
```output
20	1	計算したキー	10	1	30
```

**An element with no key goes in at 1, 2, 3, … in order.** `{10, 20, 30}` is `t[1]`, `t[2]`, `t[3]`.

`{x = 1}` is another spelling of `{["x"] = 1}` — for the same reason that `t.x` is `t["x"]`.

**The separator may be `,` or `;`, and one may be left at the end.**

```lua nilu
local t = {1, 2; 3, }
print(#t)
```
```output
3
```

**Only the last element of the list receives all of its multiple values**
(the same rule as [5.6](05-expressions.md#56-multiple-values)).

```lua nilu
local function three() return 1, 2, 3 end
print(#{three()}, #{0, three()}, #{(three())})
```
```output
3	4	1
```

### Any value but `nil` and NaN can be a key

```lua nilu
local t = {}
local k = {}
t[1] = "数がキー"
t["k"] = "文字列がキー"
t[1.5] = "整数でなくてもよい"
t[true] = "真偽値"
t[k] = "テーブル"
print(t[1], t["k"], t[1.5], t[true], t[k], t[{}])
```
```output
数がキー	文字列がキー	整数でなくてもよい	真偽値	テーブル	nil
```

**A table, a function and a userdata are keys by identity**: `t[k]` finds what was put under that
same table, and another table `{}` with the same contents is a different key. The same as Lua.

`nil` and NaN cannot be keys. **Here a read and a write differ.** A read does not fail;
it answers `nil`.

```lua nilu
local t = {}
print(t[nil], t[0 / 0])
```
```output
nil	nil
```

Trying to write is where it fails.

```lua nilu
local t = {}
t[nil] = "x"
```
```stderr
nilu: <manual>:2: table index is nil
```

This asymmetry is borrowed from Lua. Lua's `luaH_get`, too, answers "absent" for a key that
cannot go in (`nil` and NaN), and the write is what fails. The refusal's sentence says what was
being put in (`table index is nil` for `nil`, `table index is NaN` for NaN). The reasoning goes
like this — a read is a question, and "I do not have it" is a correct answer. A write is a demand,
and that one does not go through.

### Length

`#t` answers a "border": an `n` such that `t[n]` is not `nil` and `t[n+1]` is `nil`.

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
t[3] = "c"
print(#t)
```
```output
3
```

**In a table with holes, which border is answered is not decided.**

```lua nilu
local t = {}
t[1] = "a"
t[3] = "c"
print(#t == 1 or #t == 3)
```
```output
true
```

This is the same promise as Lua's. Asking the length of an array with holes is itself the
mistake; in that case, carry the count around with `table.pack`.

## 2.6. Functions

A function is a value. It can be put in a variable, put in a table, and passed as an argument.

```lua nilu
local double = function(x) return x * 2 end
local t = {}
t.double = double
print(t.double(21))
```
```output
42
```

The details are in [6. Functions](06-functions.md).

## 2.7. Turning a value into a string

`tostring` turns any value into a string.

```lua nilu
print(tostring(nil), tostring(true), tostring(12))
```
```output
nil	true	12
```

A table and a function are written as the type's name and characters that tell that value apart from others.

```lua nilu
print(string.sub(tostring({}), 1, 7))
print(string.sub(tostring(print), 1, 10))
```
```output
table: 
function: 
```

The part that follows is there to distinguish that object from others, and **it changes from run to run**.
The form is `type: identity`, borrowed from Lua. If you want to know whether two are equal,
use `==`. Comparing this string is a mistake.

If the metatable has a `__tostring`, that answers instead
([7. Metatables](07-metatables.md)).

---

Next: [3. Variables and scope](03-variables.md)
