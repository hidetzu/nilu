[← Contents](README.md)

# 5. Expressions

## 5.1. Operators and precedence

The lower in the table, the tighter it binds.

| Precedence | Operators | Associativity |
|---|---|---|
| 1 (weakest) | `or` | left |
| 2 | `and` | left |
| 3 | `<` `>` `<=` `>=` `~=` `==` | left |
| 4 | `\|` | left |
| 5 | `~` | left |
| 6 | `&` | left |
| 7 | `<<` `>>` | left |
| 8 | `..` | **right** |
| 9 | `+` `-` | left |
| 10 | `*` `/` `//` `%` | left |
| 11 | `not` `#` `-` (negation) `~` (bitwise not) | right (unary) |
| 12 (strongest) | `^` | **right** |

Lua's precedence is borrowed as it is.

```lua nilu
print(1 + 2 * 3)
print(2 ^ 3 ^ 2)
print(-2 ^ 2)
```
```output
7
512.0
-4.0
```

`2 ^ 3 ^ 2` is `2 ^ (3 ^ 2)` and `-2 ^ 2` is `-(2 ^ 2)` because
`^` is right-associative and binds tighter than unary minus.

## 5.2. Arithmetic

```lua nilu
print(7 + 2, 7 - 2, 7 * 2, 7 / 2)
print(7 // 2, 7 % 2, 2 ^ 10)
```
```output
9	5	14	3.5
3	1	1024.0
```

**`+`, `-`, `*`, `//`, `%` and unary `-` of two integers give an integer; with a float on either
side they give a float. `/` and `^` always give a float.** An integer wraps around past 64 bits, as
Lua's does.

```lua nilu
print(7 // 2.0, 3 * 1.0, 2 ^ 2)
print(math.maxinteger + 1 == math.mininteger)
```
```output
3.0	3.0	4.0
true
```

`/` is always real division. `//` is floor division, and
**for a negative number it rounds towards negative infinity, not towards 0**.

```lua nilu
print(-7 // 2, 7 // -2)
print(-7 % 2, 7 % -2)
```
```output
-4	-4
1	-1
```

`%` is defined as `a - (a // b) * b`. So the sign of the result follows the right side.
Unlike `%` in C or Rust, and the same as Python. This is Lua's definition.

**An integer divided by the integer 0 with `//` or `%` is a runtime error**, with Lua's words. A float
divided by 0 gives infinity or NaN.

```lua nilu
local n = 0
print(pcall(function() return 7 // n end))
print(pcall(function() return 7 % n end))
print(7 // 0.0, -7 // 0.0)
```
```output
false	<manual>:2: attempt to divide by zero
false	<manual>:3: attempt to perform 'n%0'
inf	-inf
```

Adding something that is not a number is a failure. A string does not become a number.

```lua nilu
return "1" + 1
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a string value (constant '1')
```

Inside the parentheses is **which value it was**.
This does not fail in Lua (it converts `"1"` to 1), so
**this exact line never appears in Lua**. How the parentheses are written follows Lua's rule.

Lua makes `"1" + 1` into 2; Nilu does not. Write `tonumber`.

### Bitwise operators

`&` (and), `|` (or), `~` (exclusive or), `<<`, `>>` and the unary `~` (not) work on integers, as
Lua's do, in 64-bit two's complement. `>>` shifts zeros in; a negative count shifts the other way, and
64 or more gives 0.

```lua nilu
print(5 & 3, 5 | 3, 5 ~ 3, ~5)
print(1 << 4, 256 >> 4, 2 >> -1, 1 << 64)
```
```output
1	7	6	-6
16	16	4	0
```

**A float operand is converted to the integer of the same value; one with no such integer is
refused**, with Lua's sentence.

```lua nilu
local x = 1.5
print(pcall(function() return x & 1 end))
print(3.0 | 0, 1 << 60, -1 >> 1)
```
```output
false	<manual>:2: number (upvalue 'x') has no integer representation
3	1152921504606846976	9223372036854775807
```

A string is refused as in arithmetic, and Lua 5.5 refuses it too.

## 5.3. Comparison

```lua nilu
print(1 == 1, 1 ~= 2, 1 < 2, 2 <= 2, 3 > 2, 3 >= 4)
```
```output
true	true	true	true	true	false
```

An integer and a float are both numbers and **compare by their exact values**, as in Lua: no
rounding stands in between.

```lua nilu
print(1 == 1.0, math.maxinteger < 2^63, math.maxinteger + 0.0 == 2^63)
```
```output
true	true	true
```

`==` is false when the types differ. Nothing is converted.

```lua nilu
print(1 == "1", nil == false)
```
```output
false	false
```

Tables and functions are compared by **whether they are the same one**. The contents are not looked at.

```lua nilu
local a = {}
local b = {}
print(a == a, a == b)
```
```output
true	false
```

An order comparison is a failure unless both sides are numbers or both are strings.

```lua nilu
return 1 < "a"
```
```stderr
nilu: <manual>:1: attempt to compare number with string
```

This is the same as Lua, and that `==` returns false where `<` fails is an intended asymmetry.
Anyone can be asked whether two things are equal, but order belongs to a type.

## 5.4. `and`, `or`, `not`

`and` and `or` do not return a boolean. **They return one side or the other as it is.**

```lua nilu
print(1 and 2, nil and 2, false and 2)
print(1 or 2, nil or 2, false or "既定値")
```
```output
2	nil	false
1	2	既定値
```

- `a and b` is `a` if `a` is false, and `b` otherwise
- `a or b` is `a` if `a` is true, and `b` otherwise

The right side is not evaluated until it is needed. This is short-circuiting.

```lua nilu
local function boom() print("呼ばれた") return 1 end
local x = false and boom()
local y = true or boom()
print(x, y)
```
```output
false	true
```

`boom` was never called.

Only `not` returns a boolean.

```lua nilu
print(not nil, not 0, not not nil)
```
```output
true	false	false
```

The usual way to write a default value is `or`. **But it cannot be used on a variable that holds `false`.**

```lua nilu
local function greet(name)
  local who = name or "名無し"
  return "やあ、" .. who
end
print(greet("Nilu"))
print(greet(nil))
```
```output
やあ、Nilu
やあ、名無し
```

```lua nilu
local flag = false
print(flag or true)
```
```output
true
```

The second one was given `false` and came out `true`. `false` is false, so
`or` returns the right side. For a boolean default, use `if`.

## 5.5. Joining strings, taking a length

```lua nilu
print("a" .. "b" .. "c")
print(#"abc", #{})
```
```output
abc
3	0
```

`..` is right-associative. `#` is the number of bytes for a string, and the border for a table
([2.5](02-values.md#25-tables)).

`#` looks at the metatable's `__len` ([7.4](07-metatables.md#74-operators)).

```lua nilu
local mt = {}
mt.__len = function() return 42 end
local t = {}
setmetatable(t, mt)
print(#t, rawlen(t))
```
```output
42	0
```

`rawlen` does not go through the metatable.

## 5.6. Multiple values

A function call can return any number of values.

```lua nilu
local function two() return 1, 2 end
print(two())
```
```output
1	2
```

**In a list, only the last expression expands.** A call written in the middle
is truncated to one value.

```lua nilu
local function two() return 1, 2 end
print(two(), 9)
print(9, two())
```
```output
1	9
9	1	2
```

Wrapping it in parentheses makes it one.

```lua nilu
local function two() return 1, 2 end
print((two()))
```
```output
1
```

This is Lua's rule, and it surprises everyone once. `(f())` is "the first value of `f()`".

**The same holds inside a table constructor** ([2.5](02-values.md#25-tables)).

```lua nilu
local function two() return 1, 2 end
print(#{two()}, #{two(), 9}, #{9, two()})
```
```output
2	2	3
```

Where values are missing, `nil` fills in.

```lua nilu
local function none() end
local a, b = none()
print(a, b)
```
```output
nil	nil
```

## 5.7. How a call is written

```lua nilu
local t = {}
t.greet = function(name) return "やあ、" .. name end
print(t.greet("Nilu"))
```
```output
やあ、Nilu
```

**When the one argument is a string, the parentheses can be left out**.

```lua nilu
print "括弧なし"
```
```output
括弧なし
```

`print "x"` is `print("x")`. The parentheses can be left out when passing one table as well
(`f{…}` and `t:m{…}`).

```lua nilu
local function count(t) return #t end
print(count{1, 2, 3})
```
```output
3
```

**There is the method call `:`**.
`t:m(x)` is **not** `t.m(t, x)` — **the receiver is evaluated once**.

```lua nilu
local calls = 0
local t = {}
t.twice = function(self, n) return n * 2 end
local function get() calls = calls + 1 return t end
print(get():twice(21), calls)
```
```output
42	1
```

**A string's methods are called the same way** — `s:upper()` is `string.upper(s)`.

---

Next: [6. Functions](06-functions.md)
