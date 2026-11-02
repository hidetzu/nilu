[← Contents](README.md)

# 10. The library

It is there only when the host opened it. A state that did not open it has nothing in it.
The `nilu` command opens it.

What is in the globals is the following.

```text
type  tostring  tonumber  assert  select
error  pcall  xpcall
next  pairs  ipairs
rawget  rawset  rawequal  rawlen
setmetatable  getmetatable  collectgarbage
string  table  math  utf8  coroutine  debug
load  require  dofile  loadfile  package
print  warn  _G  _VERSION
```

`error`, `pcall` and `xpcall` are explained in [8. Failure](08-failure.md).

`print` is here, and writes through the writer the host gives ([1.3](01-getting-started.md#13--print-writes-where-the-host-says)).
`io` and `os` are not here. The `nilu` command puts them in ([11.4](11-nilu-command.md#114-io-and-os)).

The list above is for reading. **That each of them is actually there is confirmed like this.**

```lua nilu
print(type(type), type(tostring), type(tonumber), type(assert), type(select))
print(type(next), type(pairs), type(ipairs))
print(type(rawget), type(rawset), type(rawequal), type(rawlen))
print(type(setmetatable), type(getmetatable))
print(type(string), type(table), type(math), type(utf8), type(coroutine), type(debug))
print(type(error), type(pcall), type(xpcall))
print(type(load), type(require), type(dofile), type(loadfile), type(package))
print(type(print), type(warn), type(collectgarbage), _G == _ENV, _VERSION)
```
```output
function	function	function	function	function
function	function	function
function	function	function	function
function	function
table	table	table	table	table	table
function	function	function
function	function	function	function	table
function	function	function	true	Nilu 0.1
```

(If a name disappeared, this example would fail. The list would not, so
the list alone is not enough.)

**The library is written against the C API alone.** It touches no internal.
That is, what is here is what the host could have written itself.

## 10.1. Basic functions

### `type(v)`

Answers the name of the value's type as a string.

```lua nilu
print(type(nil), type(true), type(1), type("a"), type({}), type(print))
```
```output
nil	boolean	number	string	table	function
```

### `tostring(v)`

Makes any value a string. It reads `__tostring` and `__name`
([7.4](07-metatables.md#becoming-a-string)).

```lua nilu
print(tostring(nil), tostring(12), tostring(true))
```
```output
nil	12	true
```

### `tonumber(v [, base])`

A number is answered as it is; a string is read and answered. What cannot be read is `nil`.

```lua nilu
print(tonumber("12"), tonumber("  0x10  "), tonumber("12a"), tonumber({}))
print(tonumber("ff", 16), tonumber("101", 2), tonumber("z", 36))
```
```output
12	16	nil	nil
255	5	35
```

When a base is passed, it is read only as an integer in that base.

### `assert(v [, …])`

Fails when `v` is false. When it is true, every argument is answered ([8.5](08-failure.md#85-assert)).

### `select(n, …)`

`select("#", …)` is the count, and `select(n, …)` is everything from the n-th on.

```lua nilu
print(select("#", "a", "b", "c"))
print(select(2, "a", "b", "c"))
print(select(-1, "a", "b", "c"))
```
```output
3
b	c
c
```

A negative number counts from the end.

### `next(t [, key])`

Answers the next pair of the table. Without `key`, it is the first pair.
When the end is reached, it answers `nil`.

```lua nilu
local t = {}
t[1] = "ひとつ"
local k, v = next(t)
print(k, v)
print(next(t, k))
print(next({}))
```
```output
1	ひとつ
nil
nil
```

### `pairs(t)` and `ipairs(t)`

Used with `for … in` ([4.5](04-statements.md#45-generic-for)).
`pairs` answers 4 values; the fourth is what a generic `for` closes, `nil` here.

```lua nilu
local t = {}
t[1] = "a"
print(select("#", pairs(t)))
```
```output
4
```

### `rawget` `rawset` `rawequal` `rawlen`

They do not go through the metatable ([7.3](07-metatables.md#73-raw-access)). `rawset` answers the table it was given.

```lua nilu
local t = {}
print(rawset(t, "k", 1) == t)
print(rawget(t, "k"), rawlen(t), rawequal(t, t))
```
```output
true
1	0	true
```

### `setmetatable(t, mt)` and `getmetatable(t)`

They are in [7. Metatables](07-metatables.md). `setmetatable` answers the table it was given.

### `warn(msg, …)`

**Joins its strings and hands them to the host's writer as a warning**: `Nilu warning: `, the
message and a newline, given as `writer(text, "warning")` (the `nilu` command writes it to standard
error). Warnings start off; `warn("@on")` turns them on and `warn("@off")` off, and another one-piece
message that starts with `@` is ignored, as in Lua. Without a writer it does nothing.

```lua nilu
warn("not shown: warnings start off")
warn("@on")
warn("disk ", "almost full")
```
```stderr
Nilu warning: disk almost full
```

## 10.2. `string`

**A string's index starts at 1, and a negative number counts from the end.**

| Function | What it does |
|---|---|
| `string.len(s)` | The number of bytes. The same as `#s` |
| `string.sub(s, i [, j])` | A substring |
| `string.upper(s)` / `lower(s)` | ASCII case conversion |
| `string.reverse(s)` | The bytes in reverse order |
| `string.rep(s, n [, sep])` | Repeated n times, with `sep` between the copies |
| `string.byte(s [, i [, j]])` | The values of the bytes |
| `string.char(…)` | Makes a string from byte values |
| `string.format(fmt, …)` | Lays out values according to a format |
| `string.find(s, p [, init [, plain]])` | Searches. The start and the end of the position (and the captures) |
| `string.match(s, p [, init])` | The captures, or the whole match if there are none |
| `string.gmatch(s, p [, init])` | Answers a function that takes them out in turn |
| `string.gsub(s, p, repl [, n])` | Replaces. The new string and the count |

```lua nilu
print(string.len("hello"), #"hello")
print(string.sub("hello", 2, 3), string.sub("hello", -3), string.sub("hello", 2))
print(string.upper("abc"), string.lower("ABC"), string.reverse("abc"))
print(string.rep("ab", 3))
```
```output
5	5
el	llo	ello
ABC	abc	cba
ababab
```

```lua nilu
print(string.byte("A"))
print(string.byte("abc", 1, 3))
print(string.char(78, 105, 108, 117))
```
```output
65
97	98	99
Nilu
```

A range that goes outside does not fail. It becomes an empty string, or nothing answered.

```lua nilu
print("[" .. string.sub("abc", 10) .. "]")
print(select("#", string.byte("abc", 10)))
```
```output
[]
0
```

`upper` and `lower` are ASCII only (they do not look at the locale).

### `string.format(fmt, …)`

It accepts `%d %i %u %o %x %X %c %f %e %E %g %G %a %A %q %s %p %%`. The width and the precision are up to 2 digits
(the same limit as Lua's).

```lua nilu
print(string.format("%d %5d|%-5d|%05d %+d", 42, 42, 42, 42, 42))
print(string.format("%x %X %#x %o %c%c", 255, 255, 255, 8, 78, 105))
print(string.format("[%10s][%-10s][%.3s]", "abc", "abc", "abcdef"))
print(string.format("%f %.2f %10.3f %e", 1.5, 3.14159, 3.14159, 1500))
print(string.format("%s %s %s %s=%d%%", nil, true, 12, "pct", 50))
```
```output
42    42|42   |00042 +42
ff FF 0xff 10 Ni
[       abc][abc       ][abc]
1.500000 3.14      3.142 1.500000e+03
nil true 12 pct=50%
```

`%s` uses the same spelling as `tostring` (it reads `__tostring` too). `%d` takes an integer, or a
float with an integer value, and `1.5` is a runtime error.

**The float conversions give C's results**: `%f`, `%e` and `%g` round the value
held in binary itself, a tie to even, and `%a` writes its bits. They agree with Lua byte for byte;
the tests compare 5400 answers captured from `lua5.5`.

```lua nilu
print(string.format("%.20f", 0.1))
print(string.format("%.2f %g %g %.3g %a", 2.675, 0.1, 1e20, 2.675, 1.5))
print(string.format("%q", "a\n\"b\""))
print(string.format("%q %q %q %q %q", 3, 3.0, 1.5, 1/0, nil))
```
```output
0.10000000000000000555
2.67 0.1 1e+20 2.67 0x1.8p+0
"a\
\"b\""
3 0x1.8p+1 0x1.8p+0 1e9999 nil
```

`0.1` is `0.1000000000000000055511…` in binary, and `2.675` is `2.67499999…`, so that is what is
rounded. **`%q`** writes a value Nilu reads back as the same value of the same kind, as Lua's does: a
string with its escapes, an integer in decimal (the smallest as `0x8000000000000000`), a float in
hexadecimal, infinity as `1e9999` and NaN as `(0/0)`.
A table or a function has no literal form and is refused. **`%p`** writes the address of a table, a
function, a string, a userdata or a thread (`0x…`, the address `tostring` shows), and `(null)` for
any other value, as Lua does; it takes `-` and a width.

### Patterns — `find`, `match`, `gmatch`, `gsub`

**Lua's patterns can be used as they are** (they are not regular expressions; they are Lua's own notation).

| Written as | Meaning |
|---|---|
| `.` | Any one byte |
| `%a` `%d` `%l` `%u` `%w` `%s` `%p` `%c` `%g` `%x` `%z` | A letter, a digit, a lowercase letter, an uppercase letter, an alphanumeric, a space, a punctuation mark, a control character, a printable character, a hex digit, `\0` |
| `%A` and the other uppercase forms | The complement |
| `[abc]` `[a-z]` `[^0-9]` | A set, a range, a complement |
| `%.` `%%` `%[` | That character itself |
| `*` `+` `-` `?` | 0 or more (longest), 1 or more, 0 or more (shortest), 0 or 1 |
| `^` `$` | The start, the end (only at the two ends of the pattern) |
| `%bxy` | A balanced span of `x` and `y` |
| `%f[set]` | A frontier |
| `(…)` `()` `%1`–`%9` | A capture, a position capture, a reference to a capture |

A negative `init` counts from the end. When nothing is found, it is `nil`.

```lua nilu
print(string.find("hello world", "world"))
print(string.find("hello", "l+"))
print(string.find("hello", "(l)(l)"))
print(string.match("key=val", "(%w+)=(%w+)"))
print(string.match("hello", "()ll()"))
print(string.match("f(a(b)c)d", "%b()"))
print(string.match("  x  ", "^%s*(.-)%s*$"))
```
```output
7	11
3	4
3	4	l	l
key	val
3	5
(a(b)c)
x
```

`find` answers the captures too when there are any, and `match` answers only the captures (or the whole match when there are none).
A position capture `()` is a number.

To search for a pattern character as the character itself, pass `true` as the 4th argument of `find`
(Lua's `plain`). A pattern containing no special characters is searched for as it is from the start.

```lua nilu
print(string.find("a.c", ".", 1, true))
print(string.find("a.c", "."))
```
```output
2	2
1	1
```

`gsub`'s replacement is one of **a string, a number, a table or a function**. In a string, `%0`–`%9`
are the captures (`%0` is the whole match) and `%%` is `%`. A table is looked up with the whole match as
the key, and a function is called with the captures as its arguments. **With either, if `nil` or `false` is
answered, the original stays**, and it is counted in the count.

```lua nilu
print(string.gsub("hello world", "o", "0"))
print(string.gsub("hello world", "(%w+)", "<%1>"))
print(string.gsub("hello", "l", "L", 1))
print(string.gsub("hello", "(l)", function(c) return string.upper(c) end))
local names = {}
names.hello = "こんにちは"
print(string.gsub("hello world", "%a+", names))
```
```output
hell0 w0rld	2
<hello> <world>	2
heLlo	1
heLLo	2
こんにちは world	2
```

`gmatch` answers **a function that answers the next match each time it is called**. Passing it to `for`
is the usual way, but you may keep it in a variable and call it yourself.

```lua nilu
for k, v in string.gmatch("a=1, b=2", "(%w+)=(%w+)") do
  print(k, v)
end
local it = string.gmatch("x y", "%a")
print(it(), it())
```
```output
a	1
b	2
x	y
```

**There are 3 differences from Lua.**

1. **The character classes are ASCII** (because the core does not use libc. In the C locale they agree with Lua).
2. **A number that goes into a replacement has Nilu's spelling**: `string.gsub("a", "a", 1)` is `1`, and a position
   capture `%1` also comes out as `2`.
3. **A malformed pattern carries the same sentence as Lua's**.
   The table below is **the words that actually come out**, not differences from Lua.

| Writing this | What it says (the same as Lua) |
|---|---|
| `"%"` (ending in `%`) | `malformed pattern (ends with '%')` |
| `"[a"` | `malformed pattern (missing ']')` |
| `"(a"` | `unfinished capture` |
| `"a)"` to `match` | `invalid pattern capture` |
| `"%1"` (with no capture) | `invalid capture index %1` |
| `"%b"` | `malformed pattern (missing arguments to '%b')` |
| `"%f"`, `"%fa"` | `missing '[' after '%f' in pattern` |
| 33 or more nested captures | `too many captures` |
| A pattern that needs deep backtracking (300 of `a?`…) | `pattern too complex` (it stops at depth 200) |
| `"%x"` in `gsub`'s replacement string | `invalid use of '%' in replacement string` |
| `true` as `gsub`'s replacement | `string/function/table expected` |
| A replacement function that answers a table | `invalid replacement value (a table)` |

```lua nilu
return string.find("abc", "%")
```
```stderr
nilu: <manual>:1: malformed pattern (ends with '%')
```

### `string.pack`, `string.unpack`, `string.packsize`

These 3 are for **packing into / reading out of a byte sequence**.
**The format is the same as Lua's**, and the options, the sizes and the refusals are borrowed as they are.

```lua nilu
local packed = string.pack("<i4i4", 7, 9)
print(string.len(packed))
print(string.unpack("<i4i4", packed))
```
```output
8
7	9	9
```

**`unpack` answers "the next position" after the values.** The last `9` above is that.

| option | Size | What |
|---|---|---|
| `b` `B` | 1 | A signed / unsigned integer |
| `h` `H` | 2 | The same |
| `l` `L` `j` `J` `T` | 8 | The same |
| `i[n]` `I[n]` | n (default 4, 1–16) | The same |
| `f` | 4 | Single precision |
| `d` `n` | 8 | Double precision |
| `s[n]` | n (default 8) + the contents | A string with its length in front |
| `z` | The contents + 1 | A string ending in 0 |
| `x` | 1 | 1 byte of padding |
| `<` `>` `=` | — | Little / big / native. **The default is little** |
| `!` `!n` | — | The maximum alignment. **The default is no alignment** |
| `X` | — | Aligns to the next option and packs nothing |
| Space | — | Ignored |

```lua nilu
print(string.packsize("i1i4"), string.packsize("!4i1i4"))
print(string.packsize("fdnx"))
```
```output
5	8
21
```

**`packsize` refuses `s` and `z`** (because the length is not fixed).

```lua nilu
local ok, why = pcall(string.packsize, "z")
print(ok, why)
```
```output
false	bad argument #1 to 'packsize' (variable-length format)
```

**A value that does not fit the integer is refused.** The words are the same as Lua's.

```lua nilu
print(select(2, pcall(string.pack, "i1", 300)))
print(select(2, pcall(string.pack, "B", 0 - 1)))
print(select(2, pcall(string.pack, "i4", 1.5)))
```
```output
bad argument #2 to 'pack' (integer overflow)
bad argument #2 to 'pack' (unsigned overflow)
bad argument #2 to 'pack' (number has no integer representation)
```

An integer format reads back an integer, all 64 bits of it.

```lua nilu
print(string.unpack("i8", string.pack("i8", 1152921504606846976)))
```
```output
1152921504606846976	9
```

## 10.3. `table`

| Function | What it does |
|---|---|
| `table.pack(…)` | Packs the arguments into a table, and puts the count in `n` |
| `table.create(nseq [, nrec])` | An empty table with room for `nseq` sequence elements and `nrec` other fields; a size below 0 or past 2^31 - 1 is `out of range` |
| `table.unpack(t [, i [, j]])` | Makes the elements of a table a list of values |
| `table.insert(t, [pos,] v)` | Inserts (at the end, or at a given position) |
| `table.remove(t [, pos])` | Takes out and answers (the default is the last) |
| `table.concat(t [, sep [, i [, j]]])` | Joins strings |
| `table.move(a1, f, e, t [, a2])` | Copies a range |
| `table.sort(t [, comp])` | Sorts |

```lua nilu
local packed = table.pack("a", nil, "c")
print(packed.n, packed[1], packed[2], packed[3])
```
```output
3	a	nil	c
```

Only `table.pack`'s `n` can count when a `nil` is mixed in.
`#` cannot tell.

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
t[3] = "c"
print(table.unpack(t))
print(table.unpack(t, 2))
print(table.unpack(t, 1, 2))
```
```output
a	b	c
b	c
a	b
```

```lua nilu
local t = {}
table.insert(t, "a")
table.insert(t, "b")
table.insert(t, 1, "先頭")
print(table.concat(t, ","))
print(table.remove(t), table.concat(t, ","))
print(table.remove(t, 1), table.concat(t, ","))
```
```output
先頭,a,b
b	先頭,a
先頭	a
```

`table.concat` joins strings and numbers (a number as `tostring` spells it). Anything else is
refused, with Lua's shape, saying **what was at which index**.

```lua nilu
local t = {}
t[1] = 1
t[2] = "a"
print(table.concat(t, ","))
t[3] = {}
return table.concat(t)
```
```output
1,a
```
```stderr
nilu: <manual>:6: invalid value (table) at index 3 in table for 'concat'
```
So a sentence with `number` in the parentheses never comes out of Lua.

```lua nilu
local a = {}
a[1] = "あ"
a[2] = "い"
local b = {}
table.move(a, 1, 2, 1, b)
print(b[1], b[2])
```
```output
あ	い
```

### `table.sort(t [, comp])`

Sorts in place. Without `comp`, the order is `<`'s. Strings are in byte order.

```lua nilu
local u = {}
u[1] = "pear" u[2] = "apple" u[3] = "fig"
table.sort(u)
print(table.concat(u, ","))
table.sort(u, function(a, b) return a > b end)
print(table.concat(u, ","))
```
```output
apple,fig,pear
pear,fig,apple
```

When numbers and strings are mixed they cannot be compared, so it is a runtime error.
When `comp` is not an order (for example, when it always answers `true`), it fails as Lua does,
with **the same sentence as Lua's**.

```lua nilu
local t = {}
for i = 1, 40 do t[i] = i end
table.sort(t, function() return true end)
```
```stderr
nilu: <manual>:3: invalid order function for sorting
```

**Unlike Lua, the pivot is chosen the same way every time.** When the array is large, Lua scatters
the pivot from the clock and an address, but Nilu's core has no clock. The result of the sort is the same;
only the time taken on the worst-shaped input differs.

## 10.4. `math`

| Name | What it does |
|---|---|
| `math.pi` | Pi |
| `math.huge` | Infinity |
| `math.abs(x)` | The absolute value |
| `math.floor(x)` / `ceil(x)` | Round down / round up: an integer when it fits one |
| `math.sqrt(x)` | The square root |
| `math.max(…)` / `min(…)` | The largest / the smallest, as `<` orders them (strings too, `__lt` too) |
| `math.fmod(x, y)` | C's `fmod`. **Not the same as `%`** |
| `math.random([m [, n]])` | A random number: a fraction in `[0, 1)`, or an integer in `[1, m]` or `[m, n]` |
| `math.randomseed([n1 [, n2]])` | Sets the seed. Answers the seed |
| `math.sin(x)` `cos` `tan` `asin` `acos` | Trigonometry, in radians |
| `math.atan(y [, x])` | The angle of the point (x, y); `x` is 1 when left out |
| `math.exp(x)` / `math.log(x [, base])` | e^x / the logarithm, natural or in the base |
| `math.deg(x)` / `math.rad(x)` | Radians to degrees / degrees to radians |
| `math.modf(x)` | The whole part toward 0, and the rest |
| `math.frexp(x)` / `math.ldexp(m, e)` | `x = m * 2^e` with `0.5 <= |m| < 1`, and back |
| `math.type(x)` | `"integer"` or `"float"` for a number, `nil` otherwise |
| `math.tointeger(x)` | The integer of `x`'s value, or `nil` when there is none (a string is not converted) |
| `math.maxinteger` / `math.mininteger` | 2^63 - 1 and -2^63, the largest and the smallest integer |
| `math.ult(m, n)` | `m < n` with both read as unsigned |

```lua nilu
print(math.pi)
print(math.huge, -math.huge)
print(math.abs(-3), math.sqrt(16))
print(math.floor(-1.5), math.ceil(-1.5))
print(math.max(1, 5, 3), math.min(1, 5, 3))
```
```output
3.141592653589793
inf	-inf
3	4.0
-2	-1
5	1
```

`math.fmod` truncates towards 0, and `%` truncates towards negative infinity.
**The difference is the same in both languages.**

```lua nilu
print(math.fmod(-7, 3), -7 % 3)
```
```output
-1	2
```

```lua nilu
print(math.sin(math.pi / 2), math.cos(0), math.atan(1, 1) * 4 == math.pi)
print(math.log(8, 2), math.log(100, 10), math.exp(0))
print(math.modf(3.75))
print(math.type(3), math.type(1.5), math.tointeger(4.0), math.tointeger(4.5))
print(math.maxinteger, math.mininteger)
```
```output
1.0	1.0	true
3.0	2.0	1.0
3	0.75
integer	float	4	nil
9223372036854775807	-9223372036854775808
```

### `math.random` and `math.randomseed`

The generator is the same **xoshiro256\*\*** as Lua 5.5's, and the seed is set the same way.
**So given the same seed, the same sequence as Lua's comes out** (for fractions and for integers in a range).

```lua nilu
math.randomseed(42)
print(math.random())
math.randomseed(42)
print(math.random(100), math.random(100), math.random(100))
math.randomseed(42)
print(math.random(6), math.random(6), math.random(6), math.random(6))
print(math.randomseed(7, 9))
```
```output
0.9308121780395682
50	76	86
6	2	4	6
7	9
```

Typing `math.randomseed(42); print(math.random(100))` in Lua also prints `50`.

**Where it differs from Lua**:

- **The sequence when no seed is given is fixed.** The core has no clock, so a freshly opened state
  prints the same sequence as after calling `math.randomseed(0)`. The `nilu` command seeds from the time
  and the clock when it starts, so as long as you run it through the command it differs every time. **When
  embedded in another host, the sequence is the same every time unless the host seeds it**
  ([12.7](12-embedding.md#127-things-to-be-careful-of)).
- When `math.randomseed()` is called with no arguments, Lua takes a new seed from the clock, but Nilu
  takes it **from the generator's next value**. If a seed was given at startup it stays unpredictable,
  and if none was, it stays the fixed sequence.

## 10.5. `utf8`

**A string is a sequence of bytes** ([2.4](02-values.md#24-strings)). `utf8` is 6 functions for
**counting that byte sequence as UTF-8 characters**.
What a string is does not change.

```lua nilu
local s = "a" .. utf8.char(0x3042) .. "b"
print(string.len(s), utf8.len(s))
print(utf8.codepoint(s, 2))
print(utf8.offset(s, 2))
```
```output
5	3
12354
2	4
```

**`utf8.offset` answers 2 values** — the byte where that character starts, and the byte where it ends.
This is Lua 5.5's shape; up to 5.4 it was one.

### `utf8.char(…)` and `utf8.charpattern`

```lua nilu
print(utf8.char(72, 105))
print(string.len(utf8.char(0)), string.len(utf8.char(0x10FFFF)))
local out = ""
for ch in string.gmatch("aあb", utf8.charpattern) do
  out = out .. tostring(string.len(ch)) .. ","
end
print(out)
```
```output
Hi
1	4
1,3,1,
```

**`utf8.char` can write up to `0x7FFFFFFF`** (6 bytes). That is outside Unicode, but Lua's
`MAXUTF` is there, so it is kept the same. **Reading is strict by default**, and refuses what is outside
Unicode and the surrogates. Passing a true value as the 4th argument makes it lax (Lua's `lax`).

```lua nilu
local wide = utf8.char(0x7FFFFFFF)
print(utf8.len(wide))
print(utf8.len(wide, 1, -1, true))
```
```output
nil	1
1
```

### The 2 values `utf8.len` answers

**On meeting a byte that is not UTF-8, it answers `nil` and the position of that byte.**

```lua nilu
local broken = "a" .. string.char(255) .. "b"
print(utf8.len(broken))
```
```output
nil	2
```

### `utf8.codes(s [, lax])`

**`for` drives it.** It answers the position and the code point, and on meeting a byte that is not UTF-8
it **refuses on that turn** (not at the moment it was called).

```lua nilu
for p, cp in utf8.codes("aあ") do
  print(p, cp)
end
```
```output
1	97
2	12354
```

### Specifying a position

`utf8.len`, `utf8.codepoint` and `utf8.offset` count a negative position from the end.
**Outside the range is refused**, but there are 3 ways of saying it — this is where Lua's sentences
are borrowed as they are.

| Written | Answer |
|---|---|
| `utf8.len("abc", 0)` | `bad argument #2 to 'len' (initial position out of bounds)` |
| `utf8.len("abc", 1, 4)` | `bad argument #3 to 'len' (final position out of bounds)` |
| `utf8.codepoint("abc", 0)` | `bad argument #2 to 'codepoint' (out of bounds)` |
| `utf8.offset("abc", 1, 20)` | `bad argument #3 to 'offset' (position out of bounds)` |

**`utf8.codepoint("abc", 9)` says `#3`.** What was written was the 2nd argument, but
`j` takes `i` as its default, so the one judged out of range was `j`. Lua reports
**the argument it checked**.

## 10.6. What happens when an argument is wrong

**It says which argument of which function was wrong**.
The shape is Lua's `bad argument #<number> to '<function name>' (<what>)`.

```lua nilu
return string.rep("x", -1) .. string.sub(5, 1)
```
```stderr
nilu: <manual>:1: bad argument #1 to 'sub' (string expected, got number)
```

`string.sub(5, 1)` is refused because **a number is not regarded as a string** ([2. Values](02-values.md)).
Lua converts `5` to `"5"` here, so this line does not fail in Lua.

The common shapes are collected here. Each has the same sentence as `lua5.5`'s.

| Writing this | What it says |
|---|---|
| `string.rep()` | `bad argument #1 to 'rep' (string expected, got no value)` |
| `string.rep(nil, 2)` | `bad argument #1 to 'rep' (string expected, got nil)` |
| `string.rep("a", 1.5)` | `bad argument #2 to 'rep' (number has no integer representation)` |
| `table.remove({}, 5)` | `bad argument #2 to 'remove' (position out of bounds)` |
| `string.char(300)` | `bad argument #1 to 'char' (value out of range)` |
| `select(0)` | `bad argument #1 to 'select' (index out of range)` |
| `tostring()` | `bad argument #1 to 'tostring' (value expected)` |

**An argument being absent and `nil` being passed are different** (`got no value` and `got nil`).
Lua's distinction is borrowed as it is.

**The function name is the name the caller wrote**.
The same as Lua.

```lua nilu
print(select(2, pcall(function() local f = string.rep f("x") end)))
print(select(2, pcall(function() local t = {} t.go = string.rep t.go("x") end)))
```
```output
<manual>:1: bad argument #2 to 'f' (number expected, got no value)
<manual>:2: bad argument #2 to 'go' (number expected, got no value)
```

**When there is no caller's code, it is the registered name** — when the host
called it with `nilu_call`, and when `pcall` called it. The name is in the program's bytecode,
so where there is none there is nowhere to read it from.

```lua nilu
print(select(2, pcall(string.rep, "x")))
```
```output
bad argument #2 to 'rep' (number expected, got no value)
```

In this case Lua searches the table of loaded modules and answers `'string.rep'`.
Nilu does not search `package.loaded` for a function's name, so it says the name
it was registered under.

**A refusal with no argument number also has a sentence**.
Too many arguments to `table.insert`, a malformed pattern (the table in [10.2](#102-string)),
a conversion `string.format` does not know, a value that is not a string to `table.concat`, a comparison
that is not an order to `table.sort`, a protected metatable to `setmetatable`, too many values for `table.unpack`,
a key that is not there to `next`, 3 arguments to `math.random`.

**Running out of memory also has a sentence**: `not enough memory` (it is prepared when the state is made,
so it can be handed over even with no memory. [8. Failure](08-failure.md)). A syntax error has a sentence too.

```lua nilu
local t = {}
table.insert(t, 1, 2, 3)
```
```stderr
nilu: <manual>:2: wrong number of arguments to 'insert'
```

## 10.7. Loading code

**`load` compiles a string into a function.** It needs nothing from the host.
`load(text [, chunkname [, mode [, env]]])` answers the function, or `nil` and the reason.
`mode` must allow text (`"t"` or `"bt"`); `env`, when given, is the function's `_ENV`.

```lua nilu
local f = load("return 1 + 2")
print(f())
print(load("x =", "=example"))
print(load("return y", "=env", "t", {y = 5})())
print(load("return 1", "=b", "b"))
```
```output
3
nil	example:1:4: unexpected symbol near <eof>
5
nil	attempt to load a text chunk (mode is 'b')
```

**`require`, `dofile` and `loadfile` ask the host for the text.** The library holds
the rules; finding and reading the text is the host's reader
(`nilu_setreader`, [12](12-embedding.md)). The `nilu` command gives one that reads files
([11.6](11-nilu-command.md#116-where-require-looks)). In a state whose host gave none, each says so.

- `require(name)` runs a module once. What the reader answers as the module's key is where
  `package.loaded` keeps its result (the first result, else `true`), and a second `require`
  answers the kept value. The first answers the key as a second result. A name already in
  `package.loaded`, such as `string`, answers without asking the reader. A function in
  `package.preload` under the name is the module's loader: it is called with the name and
  `":preload:"` before the reader is asked, and `":preload:"` is the second result. `require`
  keeps the table it started with, even if `package.preload` is replaced.
- `dofile(path)` runs the file there and answers everything it returns. A failure is raised.
- `loadfile(path [, mode [, env]])` answers the function without running it, or `nil` and the reason.

```lua nilu
print(require("string") == string, package.loaded.math == math)
package.preload.greeting = function(name, from) return name .. " from " .. from end
print(require("greeting"))
print(pcall(require, "geometry"))
print(loadfile("nothing.nilu"))
```
```output
true	true
greeting from :preload:	:preload:
false	cannot find module 'geometry': no file 'geometry.nilu'
nil	cannot find file 'nothing.nilu': no file 'nothing.nilu'
```

The sentences a program reads:

| When | It says |
|---|---|
| No module or file | `cannot find module 'util': <the reader's reason>`, `cannot find file 'x.nilu': <reason>` |
| A module that is still loading is asked for again | `cannot load module 'a' while it is loading (a.nilu -> b.nilu -> a.nilu)` |
| The host gave no reader | `cannot load module 'util': no reader was given to this state` (`file` for `dofile`/`loadfile`) |


## 10.8. Coroutines

**A coroutine is a function that can stop in the middle and be continued.** `coroutine.create(f)`
makes one (`type` answers `"thread"`); `coroutine.resume(co, …)` runs it until it returns or calls
`coroutine.yield(…)`. What `yield` is given, `resume` answers after `true`; what the next `resume`
is given, that `yield` answers.

```lua nilu
local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c = coroutine.yield(a + b)
  print("got", c)
  return "done"
end)
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, "x"))
print(coroutine.status(co), coroutine.resume(co))
```
```output
start	1	2
true	3
suspended
got	x
true	done
dead	false	cannot resume dead coroutine
```

**`coroutine.wrap(f)` gives a function that resumes it**, answering what it gave and raising its
failure. It makes a generator for `for`:

```lua nilu
local function range(n)
  return coroutine.wrap(function()
    for i = 1, n do coroutine.yield(i) end
  end)
end
for i in range(3) do print(i) end
```
```output
1
2
3
```

| Function | What it answers |
|---|---|
| `coroutine.status(co)` | `"suspended"`, `"running"`, `"normal"` (it resumed another that runs) or `"dead"` |
| `coroutine.running()` | the running thread, and `true` when it is the main program |
| `coroutine.isyieldable([co])` | whether a `yield` could stop it now |
| `coroutine.close(co)` | `true`, or `false` and the failure a coroutine died by; a suspended one is dropped |

**A `yield` passes where Lua's does**: script calls, `for` iterators, `pcall`, `xpcall` and
metamethods. Inside a library function that calls back, such as `table.sort`'s comparator, it is
refused, as in Lua. The sentences are Lua's:

```lua nilu
local co = coroutine.wrap(function()
  local ok, v = pcall(coroutine.yield, "inside pcall")
  local t = setmetatable({}, {__index = function(_, k) return coroutine.yield(k) end})
  return ok, v, t.field
end)
print(co())
print(co("resumed"))
print(co("from the metamethod"))
print(pcall(coroutine.yield))
print(coroutine.resume(coroutine.create(function()
  table.sort({3, 2, 1}, function(a, b) coroutine.yield() return a < b end)
end)))
```
```output
inside pcall
field
true	resumed	from the metamethod
false	attempt to yield from outside a coroutine
false	attempt to yield across a C-call boundary
```

A coroutine that failed is dead; `close` answers its failure once:

```lua nilu
local co = coroutine.create(function() error("broken") end)
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.close(co))
local main, ismain = coroutine.running()
print(type(main), ismain, coroutine.isyieldable())
print(coroutine.wrap(function() return coroutine.isyieldable() end)())
```
```output
false	<manual>:1: broken
false	<manual>:1: broken
true
thread	true	false
true
```


## 10.9. `debug`

**`debug` reads where the program is and what a function is**; nothing in it changes a function
from outside (the owner's answer). It has two functions, Lua's.

- `debug.traceback([thread,] [message [, level]])` answers the message and `stack traceback:`,
  a line per level from `level` (1, the caller, by default; 0 for another thread), named as the
  command's traceback names them ([11.3](11-nilu-command.md#113-how-a-failure-is-written)). A
  message that is not a string or nil comes back as it is.
- `debug.getinfo([thread,] f [, what])` answers a table about the function `f` or the one
  running at level `f`, or nil past the last level. `what` picks the fields with Lua's letters:
  `S` (`source`, `short_src`, `what`, `linedefined`, `lastlinedefined`), `l` (`currentline`),
  `n` (`name`, `namewhat`), `u` (`nups`, `nparams`, `isvararg`), `t` (`istailcall`,
  `extraargs`), `r` (`ftransfer`, `ntransfer`), `f` (`func`), `L` (`activelines`); all but `L`
  by default.

```lua nilu
local function inner() print(debug.traceback("here")) end
local function outer() inner() end
outer()
local info = debug.getinfo(outer, "S")
print(info.what, info.linedefined, info.lastlinedefined, info.short_src)
print(debug.getinfo(1, "l").currentline, debug.getinfo(50))
```
```output
here
stack traceback:
	<manual>:1: in upvalue 'inner'
	<manual>:2: in local 'outer'
	<manual>:3: in main chunk
Lua	2	2	<manual>
6	nil
```

A tail call leaves no frame, so `istailcall` is `false` and no `(...tail calls...)` line is
written.

---

Next: [11. The `nilu` command](11-nilu-command.md)
