[← Contents](README.md)

# 7. Metatables

A table can be given a **metatable**. A metatable is an ordinary table: put a function or
the like into a field with a fixed name, and the language uses it.

```lua nilu
local t = {}
local mt = {}
print(getmetatable(t))
setmetatable(t, mt)
print(getmetatable(t) == mt)
```
```output
nil
true
```

`setmetatable` answers the table it was given, unchanged. So a table can be made and given
its metatable in one expression.

```lua nilu
local mt = {}
mt.__tostring = function() return "<私>" end
local t = setmetatable({}, mt)
print(t)
```
```output
<私>
```

Both `print` and `tostring` go through `__tostring` (`print` calls `tostring` and writes the result).

A program can give a metatable only to a table. A string or a number cannot have one.
A `userdata` the host passes in can hold a metatable the host gave it ([12.6](12-embedding.md#126-giving-a-program-the-hosts-data-to-carry)).

## 7.1. `__index` — when a key the table does not have is asked for

It is called **only when the table does not have that key**.

```lua nilu
local mt = {}
mt.__index = function(tbl, key) return "既定:" .. key end
local t = {}
setmetatable(t, mt)
t.own = "自分の値"
print(t.own, t.missing)
```
```output
自分の値	既定:missing
```

Put a table there instead of a function, and that table is asked. This is the shape of
inheritance.

```lua nilu
local base = {}
base.greet = "やあ"
local mt = {}
mt.__index = base
local t = {}
setmetatable(t, mt)
print(t.greet)
```
```output
やあ
```

If `base` does not have it either, `base`'s metatable is asked. The chain goes up to 2000 steps, and past that it is refused with `'__index' chain too long; possible loop` (the same as Lua).

## 7.2. `__newindex` — when a key the table does not have is written

```lua nilu
local store = {}
local mt = {}
mt.__newindex = function(tbl, key, value) store[key] = value end
local t = {}
setmetatable(t, mt)
t.x = 1
print(t.x, store.x)
```
```output
nil	1
```

Nothing goes into `t` itself. This is how a read-only table, or a table that records
its writes, is written.

**It is not called for a write to a key the table already has.**

```lua nilu
local mt = {}
mt.__newindex = function() print("呼ばれた") end
local t = {}
setmetatable(t, mt)
t.x = 1
t.x = 2
print(t.x)
```
```output
呼ばれた
呼ばれた
nil
```

It is called both times. The metamethod writes nothing into `t`, so `t` never comes to
hold `x`, and every write is handed to the metamethod again.
`t.x` is `nil`. `lua5.5` answers the same three lines.

To put it into `t` itself, use `rawset` ([7.3](#73-raw-access)).

## 7.3. Raw access

To read and write the table itself without going through the metatable, use `raw*`.

```lua nilu
local mt = {}
mt.__index = function() return "メタ" end
local t = {}
setmetatable(t, mt)
print(t.k, rawget(t, "k"))
rawset(t, "k", "生")
print(t.k, rawget(t, "k"))
```
```output
メタ	nil
生	生
```

`rawequal` and `rawlen` likewise do not go through `__eq` or `__len`.

## 7.4. Operators

The following names are available. Each is called **only when the ordinary operation cannot produce an answer**.

**How a name is found.** A name is read from the metatable itself first. If the metatable does not
have it, and the metatable's own metatable holds a table in `__index`, that table is asked, and so on:
the same walk as `mt.__add` would make, except that a function in `__index` is **not called**, so no
code runs while a name is looked up. This lets one base metatable hold the names for many
metatables. The walk goes up to 2000 steps, as in 7.1, and past that it is refused with
`'__index' chain too long; possible loop`. Every name in the table below is found this way, including
`__index` and `__newindex` themselves; only `__metatable` (and the `__gc` a `userdata` refuses, 12) is
read from the metatable it is written in, because it describes the metatable rather than the value.
Lua reads every name from the metatable itself (13.1).

| Name | When |
|---|---|
| `__add` `__sub` `__mul` `__div` `__idiv` `__mod` `__pow` `__unm` | arithmetic |
| `__band` `__bor` `__bxor` `__shl` `__shr` `__bnot` | bitwise operators |
| `__concat` | `..` |
| `__len` | `#` |
| `__eq` | `==` (when both are tables and they are not the same one) |
| `__lt` `__le` | `<` `<=` (`>` and `>=` swap the sides and use the same ones) |
| `__index` `__newindex` | indexing |
| `__call` | a call |
| `__tostring` `__name` | `tostring` (`__name` also in a failure's sentence) |
| `__pairs` | `pairs` |

```lua nilu
local mt = {}
mt.__add = function(a, b) return "足した" end
mt.__len = function() return 99 end
mt.__unm = function() return "反転" end
mt.__concat = function() return "つないだ" end
local t = {}
setmetatable(t, mt)
print(t + 1, #t, -t, t .. "x")
```
```output
足した	99	反転	つないだ
```

It is called whichever side the table is on.

```lua nilu
local mt = {}
mt.__add = function(a, b) return "足した" end
local t = {}
setmetatable(t, mt)
print(1 + t)
```
```output
足した
```

### Comparison

`__eq` is called **only when both are tables, and they are not the same one**.

```lua nilu
local mt = {}
mt.__eq = function(a, b) return true end
local a = {}
setmetatable(a, mt)
local b = {}
setmetatable(b, mt)
print(a == b, a == 1, a ~= b)
```
```output
true	false	false
```

`a == 1` is `false` because, when the types differ, the metamethod is never reached.
`~=` is the negation of `==`; there is no separate metamethod.

```lua nilu
local mt = {}
mt.__lt = function(a, b) return true end
local a = {}
setmetatable(a, mt)
local b = {}
setmetatable(b, mt)
print(a < b, a > b)
```
```output
true	true
```

`a > b` calls the same metamethod as `b < a`, so both are `true`.

### Calling

```lua nilu
local mt = {}
mt.__call = function(self, x) return x * 2 end
local t = {}
setmetatable(t, mt)
print(t(21))
```
```output
42
```

The first argument is the called table itself. A table can be put into `__call` too,
and the chain is followed up to 1999 steps (Lua's is 15. 13.1).

### Becoming a string

```lua nilu
local mt = {}
mt.__name = "Point"
local t = {}
setmetatable(t, mt)
print(string.sub(tostring(t), 1, 7))
```
```output
Point: 
```

If there is a `__tostring`, that is the answer; if there is none and there is a `__name`,
that name is used in place of `table`. If both are there, `__tostring` wins.

**`__name` appears in a failure's sentence too.** The `table` in the core's
`attempt to … a table value` becomes that name for a table that has a `__name` (the same as
Lua's `luaT_objtypename`, and a `__name` that is not a string is ignored).

If `__tostring` does not return a string, it fails.

```lua nilu
local mt = {}
mt.__tostring = function() return 1 end
local t = {}
setmetatable(t, mt)
print(t)
```
```stderr
nilu: '__tostring' must return a string
```

The sentence is Lua's.
That returning a number is refused too is a difference from Lua ([13.1](13-differences-from-lua.md#131-where-it-differs)).
**Through `print`, no position is attached** — because the `nilu` command's `print` calls the global
`tostring`; call `tostring(t)` inside a Lua function and a position is attached, as in Lua.

### Traversal

If there is a `__pairs`, `pairs` asks it. `pairs` sees only the table's own keys, so this
is for traversing a table whose values are made by `__index`.

```lua nilu
local mt = {}
mt.__pairs = function(self) return next, self, nil end
local t = {}
setmetatable(t, mt)
t[1] = "あ"
local n = 0
for k, v in pairs(t) do n = n + 1 end
print(n)
```
```output
1
```

## 7.5. What cannot be done

**A metamethod may be anything a call accepts.** A function, or a table or `userdata`
whose `__call` leads to one; that value is then passed first, before the operands, as in
`t()`. Any other value fails the way a call does, and the sentence names
the metamethod, since no variable was written: `attempt to call a boolean value
(metamethod 'add')`. This is the same as Lua.

**A metamethod can return only one value.** Return two, and only the first is used.
This is the same shape as Lua's, and not a gap.

There is no `__gc`. `__close` closes a `<close>` local ([3.1](03-variables.md#31-local-variables)), and `__mode` makes a table weak ([9.2](09-gc.md#92-what-is-alive)).

`__metatable` is there. `getmetatable` answers that value, and `setmetatable` refuses with
`cannot change a protected metatable` (the same as Lua).

---

Next: [8. Failure](08-failure.md)
