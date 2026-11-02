[← Contents](README.md)

# 14. Porting from Lua

[Chapter 13](13-differences-from-lua.md) is the list of **what differs**, and [13.3](13-differences-from-lua.md#133-what-to-write-instead) is **what to write instead**.
This chapter is **a record of actually porting**. Two programs were written in Lua and then ported,
and **how many places changed** is counted.

**Every ported program shown here was run and confirmed**
(`zig build manual-check`).

## 14.1. The first program: word frequency

Written in Lua, it is this.

```text
local text = "the quick brown fox jumps over the lazy dog the fox"

local counts = {}
for word in text:gmatch("%a+") do
  counts[word] = (counts[word] or 0) + 1
end

local words = {}
for w in pairs(counts) do words[#words + 1] = w end

table.sort(words, function(a, b)
  if counts[a] ~= counts[b] then return counts[a] > counts[b] end
  return a < b
end)

for i = 1, math.min(3, #words) do
  print(string.format("%-6s %d", words[i], counts[words[i]]))
end
```

**One place changed.** `text:gmatch(…)` becomes `string.gmatch(text, …)`, and that is all.

```lua nilu
local text = "the quick brown fox jumps over the lazy dog the fox"

local counts = {}
for word in string.gmatch(text, "%a+") do
  counts[word] = (counts[word] or 0) + 1
end

local words = {}
for w in pairs(counts) do words[#words + 1] = w end

table.sort(words, function(a, b)
  if counts[a] ~= counts[b] then return counts[a] > counts[b] end
  return a < b
end)

for i = 1, math.min(3, #words) do
  print(string.format("%-6s %d", words[i], counts[words[i]]))
end
```
```output
the    3
fox    2
brown  1
```

**The output is byte for byte what `lua5.5` prints for the original program.**
The `%-6s %d` formatting, `#words`, the default value with `or`, and the function passed to `table.sort` all work as they are.

**The order of `pairs` is unspecified, yet the output is the same every time** ([Chapter 9](09-gc.md), [10.1](10-library.md#101-basic-functions)).
That is because the comparison function for the sort is **a total order** — a different count decides by the count,
and the same count by the name, so whatever order they are collected in, the result is one.
**If the comparison function leaves a tie, the order is unspecified there.** The same in the original Lua.

## 14.2. The second program: a class with methods

The most idiomatic shape in Lua. `:` appears in three kinds of place.

**The program below runs without changing a single character from the Lua**, and prints what Lua prints
([14.3](#143-how-a-number-is-spelled)).

```lua nilu
local Stack = {}
Stack.__index = Stack

function Stack.new()
  return setmetatable({items = {}, n = 0}, Stack)
end

function Stack:push(v)
  self.n = self.n + 1
  self.items[self.n] = v
  return self
end

function Stack:pop()
  if self.n == 0 then return nil end
  local v = self.items[self.n]
  self.items[self.n] = nil
  self.n = self.n - 1
  return v
end

function Stack:size() return self.n end

local s = Stack.new()
s:push("a"):push("b"):push("c")
print(s:size(), s:pop(), s:size())
```
```output
3	c	2
```

**Chaining (`s:push("a"):push("b")`) works too.** `push` returns `self`, and the returned value
is just the receiver of the next `:`.

**The metatable works as it is.** `s.push` is not in `s`, so `__index` looks at `Stack` and
finds it ([Chapter 7](07-metatables.md)).

**`:` is not sugar.** `t:m(x)` is **not the same** as `t.m(t, x)`:
**the receiver is evaluated once** — `get():push("a")` calls `get` once.
Rewriting it as `s.push(s, "a")` evaluates the receiver **twice**
when it is an expression.

**String methods are called with `:` as well** (`s:upper()`), as in Lua
([13.3](13-differences-from-lua.md#133-what-to-write-instead)).

## 14.3. How a number is spelled

**A number prints as Lua prints it**: an integer without `.0`, and a float with a whole value with it
(`10 / 2` is `5.0`; [2.3](02-values.md#23-numbers)). Only a float's digit count can differ, since Nilu
writes the fewest that read back ([13.1](13-differences-from-lua.md#131-where-it-differs)). To write a
fixed form, use `string.format` (`%d`, `%.1f`).

```lua nilu
local n = 3
print(n)
print(string.format("%d", n))
```
```output
3
3
```

## 14.4. The steps of a port

1. **Look up [13.3](13-differences-from-lua.md#133-what-to-write-instead)** for what has to be rewritten.
2. **Run it, and look where Lua printed a float** (`5.0` against `5`). To fix the form, `string.format`.

`{1, 2}`, `{x = 1}`, `{[k] = v}`, `function f() … end`, `t:m(x)`, `function t:m()` and `s:upper()`
**can be written as they are**.

**`__gc` cannot be rewritten.**
The reasons are in the last table of [13.3](13-differences-from-lua.md#133-what-to-write-instead).
Where one of those is hit, the port becomes a restructuring of the program.

---

Next: [15. Grammar](15-grammar.md)
