[← Contents](README.md)

# 3. Variables and scope

There are 3 kinds of variable: **a local variable**, **a global variable**, and
**a local variable of an enclosing function** (an upvalue). The third is explained in
[6. Functions](06-functions.md).

## 3.1. Local variables

Declared with `local`.

```lua nilu
local x = 1
local y
local a, b = 10, 20
print(x, y, a, b)
```
```output
1	nil	10	20
```

With no value written, it is `nil`. If there are more names, the extra ones are `nil`; if there
are more values, the extra ones are discarded.

```lua nilu
local a, b, c = 1, 2
local d, e = 1, 2, 3
print(a, b, c, d, e)
```
```output
1	2	nil	1	2
```

The same name can be declared again. A new variable is made, and the name points at that one.

```lua nilu
local x = 1
local x = 2
print(x)
```
```output
2
```

The earlier variable does not go away. A function that captured it can still see it
([6. Functions](06-functions.md)).

### A read-only local

Putting `<const>` after the name makes the variable one that cannot be assigned to.
Written before the names, as in `local <const> a, b = 1, 2`, it applies to every name listed.

```lua nilu
local limit <const> = 10
local t <const> = {}
t.n = limit
print(t.n)
```
```output
10
```

Only the variable becomes read-only; the value does not change. As with `t` above, a table's contents can still be written.

An assignment is refused as a syntax error, before running. Writing it from inside a function is the same.

```lua nilu-refused
local limit <const> = 10
local function grow()
  limit = 20
end
```

It says `attempt to assign to const variable 'limit'`. To change the value, drop the `<const>`
or declare a new `local`.

### A local that is closed: `<close>`

**A `<close>` local's value is closed when its block is left**, however it is left: at its end, by
`break`, `goto` or `return`, or by a failure. Closing calls the value's `__close(value, err)`, the
innermost local first; `err` is the failure's value when a failure left the block, and `nil`
otherwise. The value must be `nil`, `false` or have `__close` when the local is declared. A `<close>`
local is read-only, as `<const>` is, and a declaration has at most one. This is Lua 5.5's.

```lua nilu
local function resource(name)
  return setmetatable({}, {__close = function(_, err) print("close " .. name, err) end})
end
do
  local a <close> = resource("a")
  local b <close> = resource("b")
  print("in block")
end
print(pcall(function()
  local c <close> = resource("c")
  error("boom", 0)
end))
print(pcall(function() local z <close> = 1 end))
```
```output
in block
close b	nil
close a	nil
close c	boom
false	boom
false	<manual>:13: variable 'z' got a non-closable value
```

A `__close` that fails puts its failure in place of the one leaving, for the next `__close` and for
whoever catches it. Under `xpcall` the handler runs first, and `__close` gets what it answered. A
failure left by `error()` carries `nil`, so `__close` cannot tell it from a normal exit
([13.1](13-differences-from-lua.md#131-where-it-differs)). Inside a block with one, `return f()` is
not a tail call.

**A failure closes them where it is caught**, by `pcall` or by the host: by then the functions it left
are no longer on the stack, as in Lua. A coroutine that fails keeps them until `coroutine.close`,
which passes them its failure; one made by `coroutine.wrap` is closed as it fails.

```lua nilu
local function resource(name)
  return setmetatable({}, {__close = function(_, err) print("close " .. name, err) end})
end
local co = coroutine.create(function()
  local r <close> = resource("r")
  error("late", 0)
end)
print(coroutine.resume(co))
print(coroutine.close(co))
```
```output
false	late
close r	late
false	late
```

## 3.2. Blocks

A local variable lives until the end of its block. The blocks are
each clause of an `if`, the body of a `while`, a `repeat` and a `for`, `do … end`, a function's body, and the whole program.

```lua nilu
local x = "外"
if true then
  local x = "内"
  print(x)
end
print(x)
```
```output
内
外
```

Once its block is left, a name is no longer resolved. It is read as a global variable.

```lua nilu
if true then local y = 1 end
print(y)
```
```output
nil
```

When all you want is a block, write `do … end`.

```lua nilu
do
  local z = 1
  print(z)
end
print(z)
```
```output
1
nil
```

## 3.3. Global variables

An undeclared name is a global variable. A global variable is
a field of one table.

```lua nilu
g = 10
print(g)
print(h)
```
```output
10
nil
```

A global variable never assigned to is `nil`. Misspelling one does
nothing at that point.

```lua nilu
local count = 0
cuont = count + 1
print(count, cuont)
```
```output
0	1
```

All that happened is that a global variable named `cuont` came into being; `count` is still 0.
**This passes silently.** When you do not want that, the next section is what you use.

### It is the same table the host sees

The table the global variables are in is the same table the host program
reads and writes with `nilu_getglobal` and `nilu_setglobal`.
If the host puts a function there, the program can call it by name
([12. Embedding from C](12-embedding.md)). That is how `print` arrives.

### `_ENV`

A global variable `x` is really `_ENV.x`. `_ENV` is an ordinary name, so
it can be hidden by a local variable.

```lua nilu
local p = print
local _ENV = {}
x = 1
p(x)
```
```output
1
```

Here `x` becomes a field of the new, empty table. `print` can no longer be looked up by
name (it is not in the new `_ENV`), which is why it was taken into a local variable
first.

This is the same device as Lua's, and there is no special implementation on Nilu's side. Name
resolution finds `_ENV`, and the name is assembled into an index into `_ENV.x`; that is all.

## 3.4. The `global` declaration

To make a misspelling a syntax error again, declare the global variables you use.

```lua nilu
global count, print
count = 0
count = count + 1
print(count)
```
```output
1
```

**Once `global` is used anywhere in a program, an undeclared global variable in that block
is a syntax error.**

⚠ **Note that `print` is declared too.** A name the host put there is a global variable as
well. Write only `global count` and use `print`, and the `print` is where the
syntax error is.

```lua nilu
global count
count = 1
print(count)
```
```stderr
nilu: <manual>:3:1: variable 'print' not declared
```

This looks strict, but asking for that is what the feature is for. Either write everything you
use, or allow everything with the `global *` that follows.

```lua nilu
global count, print
cuont = 1
```
```stderr
nilu: <manual>:2:1: variable 'cuont' not declared
```

A position is given, so you can see at once where the mistake is. Without a declaration, a typo only
shows up as `nil` when the program runs.

Everything can be allowed at once.

```lua nilu
global *
anything = 1
print(anything)
```
```output
1
```

A `global` is in effect until the end of its block. The same as a local variable.

```lua nilu
if true then
  global x
  x = 1
end
y = 2
print(x, y)
```

```output
1	2
```

`y` is outside the `global` declaration, so nothing is demanded of it.

### Declaring and putting a value in

A value can be put in at the declaration. A function can be defined the same way.

```lua nilu
global print
global limit = 10
global function twice(x)
  return x * 2
end
print(twice(limit))
```
```output
20
```

`global a, b = 1, 2` puts a value into every name listed. A name you only want to declare goes in a separate `global`.

**These two forms confirm that the global variable is still `nil` before putting the value in.**
If it already has a value, it fails at run time. This is so that a name the host put there is not overwritten by accident.

```lua nilu
global function print() end
```
```stderr
nilu: <manual>:1: global 'print' already defined
```

To overwrite it, declare it and then assign to it in the ordinary way (`print = …` after `global print`).

### A read-only global

With `<const>`, an assignment is a syntax error. The initialisation at the declaration is allowed.

```lua nilu
global print
global version <const> = "1.0"
print(version)
```
```output
1.0
```

```lua nilu-refused
global version <const> = "1.0"
version = "2.0"
```

`global <const> *` makes everything read-only except what was declared by name.

### Before and after a local variable

`global x` hides a local variable `x` declared before it. From then on, `x` is the global variable.

```lua nilu
local x = 1
global print, rawget, x
x = 2
print(rawget(_ENV, "x"))
```
```output
2
```

`global *` hides nothing.

**`global` stays an ordinary name.** It can be used as a variable name. Lua 5.5's manual writes
`global` as a reserved word, but under the default configuration Lua ships with (`LUA_COMPAT_GLOBAL`) it is an ordinary name too, and Nilu is the same.

```lua nilu
local global = 1
print(global)
```
```output
1
```

---

Next: [4. Statements](04-statements.md)
