[← Contents](README.md)

# 4. Statements

A program is a sequence of statements. No separator is needed. No newline is needed either.
`;` can be written as a statement that does nothing.

The statements are these.

| Statement | How it is written |
|---|---|
| Declaration | `local x = 1`, `local x <const> = 1`, `global x`, `global x = 1` |
| Assignment | `x = 1`, `t[k] = v`, `a, b = b, a` |
| Condition | `if … then … elseif … then … else … end` |
| Loop | `while … do … end`, `repeat … until …`, `for … do … end` |
| Block | `do … end` |
| Leave, jump | `break`, `goto name`, `::name::` |
| Define a function | `function f() … end`, `function t:m() … end`, `local function f() … end`, `global function f() … end` |
| Return | `return`, `return x`, `return a, b` |
| Call | `f(x)`, `t:m(x)`, `(f)(x)` |

## 4.1. Assignment

```lua nilu
local x
x = 1
print(x)
```
```output
1
```

Any number of targets can be written on the left. The right side is evaluated in full before
the assignment happens, so a swap can be written.

Before evaluating the right side, receivers and keys of left-side targets are
evaluated from left to right and preserved. The right-side expressions are then
evaluated from left to right, and targets are written from right to left. This
also applies to duplicate targets and assignments that replace `_ENV`: a global
target keeps the environment selected before the right side. Indexed function
definitions use the same target preparation.

A failure stops at its place in this sequence. Receiver/key evaluation failures
precede right-side failures; checking a receiver or key for a store happens when
that store runs. Earlier stores and other side effects are not rolled back.

```lua nilu
local a, b = 1, 2
a, b = b, a
print(a, b)
```
```output
2	1
```

An index can be written on the left as well.

```lua nilu
local t = {}
t[1], t.name = "いち", "名前"
print(t[1], t.name)
```
```output
いち	名前
```

If the counts differ, what is missing becomes `nil` and what is extra is discarded.

```lua nilu
local a, b = 1
print(a, b)
```
```output
1	nil
```

## 4.2. `if`

```lua nilu
local n = 2
if n == 1 then
  print("いち")
else
  print("いち以外")
end
```
```output
いち以外
```

`else` can be left out. Every condition other than `false` and `nil` is true
([2.2](02-values.md#22-booleans)).

**There is `elseif`**.

```lua nilu
local n = 2
if n == 1 then
  print("いち")
elseif n == 2 then
  print("に")
else
  print("たくさん")
end
```
```output
に
```

**It means the same as an `if` placed inside the `else`.** But it does not nest — there is one
`end`, and however many arms there are, they do not count towards the depth limit.

```lua nilu
local n = 2
if n == 1 then
  print("いち")
else
  if n == 2 then
    print("に")
  else
    print("その他")
  end
end
```
```output
に
```

## 4.3. `while`

```lua nilu
local i = 0
while i < 3 do
  i = i + 1
  print(i)
end
```
```output
1
2
3
```

If the condition is false from the start, the body never runs.

**A program that does not end can be written.** `while true do end` does not stop.
The host can stop it by installing a hook that is called every fixed number of instructions,
but the `nilu` command does not use one, so `Ctrl-C` ends the whole process
([11. The `nilu` command](11-nilu-command.md)).

### `repeat … until`

The body runs first, and **then** the condition is examined. It ends once the condition becomes true.

```lua nilu
repeat
  print("一度は動く")
until true
```
```output
一度は動く
```

**The condition can see the body's local variables.** Together with the body running first, this is the difference from `while`.

```lua nilu
local n = 0
repeat
  n = n + 1
  local done = n >= 3
until done
print(n)
```
```output
3
```

Written with `while`, `done` is not visible from where the condition is.
`break` leaves a `repeat` just as it leaves a `while`.

## 4.4. Numeric `for`

```lua nilu
for i = 1, 3 do
  print(i)
end
```
```output
1
2
3
```

The third value is the step. It can be negative.

```lua nilu
for i = 3, 1, -1 do
  print(i)
end
for i = 1, 2, 0.5 do
  print(i)
end
```
```output
3
2
1
1.0
1.5
2.0
```

**When the initial value and the step are integers, the control variable is an integer**, and the
limit may be a float (`for i = 1, 2.5` runs 1 and 2). Otherwise all three are floats, as in Lua.

The initial value, the limit and the step are evaluated **once, before the loop is entered**.
Changing a variable partway through does not change the number of iterations.

**The control variable is read-only.**

```lua nilu-refused
for i = 1, 3 do
  i = 9
end
```

This is a syntax error. It is borrowed from Lua 5.5, which made it so. Writing to it from a
function created inside the loop is the same. To change the number of iterations,
use `while`.

The control variable is a new variable on every iteration. So when a closure captures it on each
iteration, each closure holds a different value.

```lua nilu
local fs = {}
for i = 1, 3 do
  fs[i] = function() return i end
end
print(fs[1](), fs[2](), fs[3]())
```
```output
1	2	3
```

A step of 0 is a failure.

```lua nilu
for i = 1, 3, 0 do
  print(i)
end
```
```stderr
nilu: <manual>:1: 'for' step is zero
```

## 4.5. Generic `for`

`for names… in expressions… do … end` calls the function the expressions returned, every iteration.

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
for i, v in ipairs(t) do
  print(i, v)
end
```
```output
1	a
2	b
```

Each iteration has its own declaration variables. A closure keeps that turn's
values, including changes to later variables made in the body. Their captured
cells close before the next iterator call, including a terminating nil result,
and on break, return, goto, failure or interruption. The first variable is
read-only; later variables can be assigned.

`ipairs` goes from 1 upwards, in order, until it meets `nil`.
`pairs` visits every key exactly once.

```lua nilu
local t = {}
t[1] = 10
t[2] = 20
t.x = 30
local sum = 0
local n = 0
for k, v in pairs(t) do
  sum = sum + v
  n = n + 1
end
print(sum, n)
```
```output
60	3
```

**The order `pairs` visits in is not specified.** Not even for numeric keys.
If order is needed, use a numeric `for`. This is the same "no promise" that Lua
makes. Only what does not depend on order, such as a sum or a count, can be written.

After `in`, the function and the state can be written directly. `pairs(t)` is just a function
that returns them. **A fourth value is closed when the loop ends**, however it ends, as a `<close>`
local's ([3.1](03-variables.md#31-local-variables)); `io.lines(name)` hands its file there.

```lua nilu
local t = {}
t[1] = "ひとつ"
for k, v in next, t do
  print(k, v)
end
```
```output
1	ひとつ
```

## 4.6. `break`

Leaves the innermost loop.

```lua nilu
for i = 1, 5 do
  if i == 3 then break end
  print(i)
end
```
```output
1
2
```

Leaving the inner loop does not stop the outer one.

```lua nilu
local n = 0
for i = 1, 3 do
  for j = 1, 3 do
    n = n + 1
    break
  end
end
print(n)
```
```output
3
```

Writing `break` outside a loop is a syntax error. A function's body does not
see the loop around it.

```lua nilu
break
```
```stderr
nilu: <manual>:1:1: break outside loop near 'break'
```

`break` need not be the last statement. The statements after it are not executed.

**There is no `continue`.** Lua has none either, so this is what borrowing gives.
As in Lua, it is written with `goto`.

### `goto` and labels

`goto name` jumps to `::name::`. It can jump forwards and backwards.

```lua nilu
for i = 1, 3 do
  if i == 2 then goto continue end
  print(i)
  ::continue::
end
```
```output
1
3
```

A label is visible in **its block and the blocks inside it**. It is not visible from a function defined inside.
A label with the same name cannot be placed while an outer one is visible.

**A jump cannot enter the scope of a local variable.**

```lua nilu
goto f
local x = 1
::f::
print(x)
```
```stderr
nilu: <manual>:1:1: <goto f> at line 1 jumps into the scope of 'x'
```

But it can jump to **the last label of a block**, because there the block's local variables are
taken to have already ended. The `goto continue` above is this shape. A label just before a `repeat`'s
`until` does not count as last — the condition still sees the body's local variables.

## 4.7. `return`

```lua nilu
local function f()
  return 1, 2
end
print(f())
```
```output
1	2
```

**`return` must be the last statement of its block.**

```lua nilu
return 1
print("ここには来ない")
```
```stderr
nilu: <manual>:2:1: <eof> expected near 'print'
```

This is the same rule as Lua's. No statement can be written after `return`
because it would never be executed. The position points not at the `return` but at
**the start of the statement that may not be there**.

With no values written, nothing is returned.

When run as a script, the returned values are **discarded**.
To output something, use `print`. At the prompt they are displayed.

## 4.8. A call can be a statement

```lua nilu
print("呼び出しだけの行")
```
```output
呼び出しだけの行
```

**Of the expressions, only a call can stand alone as a statement.**

```lua nilu-refused
1 + 2
x
```

Both are syntax errors. A statement that starts with a name or `(` is either an assignment or a call (a declaration starting with `global` aside).
It can also start with a parenthesis, as in `(f)(x)`.

## 4.9. Statements not there yet

| Not there | Instead |
|---|---|
| `continue` | `goto` and a label at the end of the block (Lua has none either) |

---

Next: [5. Expressions](05-expressions.md)
