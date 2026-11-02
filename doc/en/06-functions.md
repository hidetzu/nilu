[← Contents](README.md)

# 6. Functions

A function is a value. A name is something given to it afterwards.

## 6.1. Making one

```lua nilu
local double = function(x) return x * 2 end
print(double(21))
```
```output
42
```

A function that calls itself is written with `local function`. The name is created before the body,
so the body can see itself.

```lua nilu
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(5))
```
```output
120
```

**`function f() … end` can be written**.
**It means `f = function() … end`** — an assignment to a global variable, and that does not change.

```lua nilu
function f() return 1 end
print(f())
```
```output
1
```

`function t.g() … end` can be written too, and is the same as `t.g = function() … end`.

### Methods — `function t:m()` and `t:m()`

`function t:m(a)` **declares `self` as an implicit first parameter**, and the parameters written come after it.

```lua nilu
local counter = {}
counter.n = 0

function counter:add(k)
  self.n = self.n + k
  return self.n
end

print(counter:add(5))
print(counter:add(2))
print(counter.add(counter, 1))
```
```output
5
7
8
```

As the last line shows, **the function `t:m(x)` calls is `t.m` itself**. `self` is not a special name
but **an ordinary local variable**, and **not a reserved word** — `local self = 1` can be written.

⚠ **But `t:m(x)` is not the same as `t.m(t, x)`.** **The receiver is evaluated once.**

```lua nilu
local calls = 0
local box = {}
function box:get() return "値" end
local function receiver() calls = calls + 1 return box end

print(receiver():get(), calls)
```
```output
値	1
```

Written as `receiver().get(receiver())`, `receiver` is called twice. **`:` exists for this
difference.**

**A string's methods are called the same way** — `s:upper()` is `string.upper(s)`.

⚠ **In a program that declares its globals, the `f` of `function f()` needs a declaration too**
([3.4](03-variables.md#34-the-global-declaration)). It is treated the same as `f = function() end`:
the spelling changes, the rule does not.

## 6.2. Parameters

A missing argument is `nil`, and an extra argument is discarded.

```lua nilu
local function f(a, b) return a, b end
print(f(1))
print(f(1, 2, 3))
```
```output
1	nil
1	2
```

Arguments are always passed by value. When a table is passed, what is passed is
a reference to the table, so if the callee changes its contents, the caller sees that too.

```lua nilu
local function fill(t) t[1] = "入れた" end
local t = {}
fill(t)
print(t[1])
```
```output
入れた
```

## 6.3. Undeclared arguments — `...`

Writing `...` at the end of the parameter list receives the arguments beyond the declared ones.

```lua nilu
local function count(...)
  return select("#", ...)
end
print(count(), count(1), count(1, 2, 3))
```
```output
0	1	3
```

`select("#", ...)` is the count, and `select(n, ...)` is everything from the n-th onwards.

**A chunk (a whole file) is also a function that receives `...`.** The `nilu` command passes the script's
arguments there ([11.1](11-nilu-command.md#111-how-to-run-it)).

```lua nilu
local function f(first, ...)
  print(first, select(1, ...))
  print(select(2, ...))
end
f("あ", "い", "う")
```
```output
あ	い	う
う
```

`...` expands only in the last position of a list. This is the same rule as for a call
([5.6](05-expressions.md#56-multiple-values)).

```lua nilu
local function f(...)
  print(..., "後ろ")
  return table.pack(...).n
end
print(f(1, 2))
```
```output
1	後ろ
2
```

`table.pack(...)` packs them into a table and returns it with the count in `n`. Unlike `#`,
the count in `n` is right even when `nil` is among them.

**Writing a name after `...` gives that table a name.** As in Lua 5.5, `...rest` binds `rest` to
a table holding the arguments beyond the declared ones, and their count in `n`. Each call gets a
new table, and with no extra arguments it is a table whose `n` is `0`.

```lua nilu
local function f(first, ...rest)
  print(first, #rest, rest.n, rest[2])
end
f("あ", "い", nil)
f("あ")
```
```output
あ	1	2	nil
あ	0	0	nil
```

**`...` still works, and it reads that table as it is now.** Changing a field changes what `...`
gives, and `n` is how many it gives.

```lua nilu
local function f(...rest)
  rest[1] = "かえた"
  rest.n = 1
  return select("#", ...), ...
end
print(f("あ", "い"))
```
```output
1	かえた
```

When `n` is not a whole number from `0` to `1073741823` (Lua's limit), `...` fails with
`vararg table has no proper 'n'`, and more values than the stack holds with `stack overflow`.
Changing `n` does nothing until `...` is read.

**The name is read-only**, like a `<const>` ([3.1](03-variables.md#31-local-variables)): `rest = {}` is refused
with `attempt to assign to const variable 'rest'`; change its fields instead. `...name` is only
the last parameter, and takes no attribute: `function(...rest, a)` and `function(...rest <const>)`
are syntax errors. `...[1]` is not in Lua 5.5 either (`lua5.5` 5.5.1 refuses it with
`')' expected near '['`).

## 6.4. Closures

A function's body can see the local variables around it. **Not only see them — it
shares the same variables.**

```lua nilu
local function counter()
  local n = 0
  return function()
    n = n + 1
    return n
  end
end
local next1 = counter()
print(next1(), next1(), next1())
```
```output
1	2	3
```

The same variable can be shared by two functions.

```lua nilu
local function pair()
  local n = 0
  local get = function() return n end
  local inc = function() n = n + 1 end
  return get, inc
end
local get, inc = pair()
inc()
inc()
print(get())
```
```output
2
```

Calling `counter()` twice makes two `n`s. What is captured is
"the variable of the block that was running at the time".

```lua nilu
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local a = counter()
local b = counter()
print(a(), a(), b())
```
```output
1	2	1
```

## 6.5. Tail calls

A call of the form `return f(…)` **rebuilds the current frame and reuses it**.
So it can repeat any number of times.

```lua nilu
local function loop(n)
  if n == 0 then return "終わり" end
  return loop(n - 1)
end
print(loop(100000))
```
```output
終わり
```

A hundred thousand calls, and the depth has not grown. This is a loop written as a function.

**In exchange, the depth limit no longer covers this shape.**

```lua nilu-source
local function forever() return forever() end
```

This is syntactically correct, and it is the same thing as `while true do end`. It does not stop.
(Every example in this manual is run, but this one alone is not.
What does not end has no result.)
`return f()` and `return (f())` are different things, and the latter is not a tail call
(the parentheses truncate the values to one, so the call's result has to be received).

Recursion that is not a tail call has a depth limit.

```lua nilu
local function deep(n) return 1 + deep(n) end
print(select(2, pcall(deep, 1)))
```
```output
<manual>:1: stack overflow
```

The limit is a fixed number and cannot be changed.

(It is caught with `pcall` **to keep this example to one line**. Run without catching it,
the command **prints the traceback as well** — that is in [11.3](11-nilu-command.md#113-how-a-failure-is-written).)

## 6.6. Treating a function as a value

```lua nilu
local t = {}
t.add = function(a, b) return a + b end
local f = t.add
print(f(1, 2), t.add(3, 4))
```
```output
3	7
```

`t:method(x)` and `function t:method(x) … end` can be written too ("Methods" in [6.1](#61-making-one)).

A function the host wrote in C is the same thing as far as the program can see. There is no
way to tell them apart.

```lua nilu
print(type(print), type(function() end))
```
```output
function	function
```

---

Next: [7. Metatables](07-metatables.md)
