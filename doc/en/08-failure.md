[← Contents](README.md)

# 8. Failure

**Nilu has no exceptions.** A failure unwinds the call on the spot. There is no syntax
that corresponds to `try`. What catches one is `pcall` and `xpcall`.

There are three things that can be done.

- write so that it does not fail
- catch it with `pcall` ([8.4](#84-error-and-pcall))
- on the host's side, receive that it failed

## 8.1. What happens on a failure

A failure unwinds everything on the spot and **goes back to a `pcall`, or, if there is none, to the host**.
The example below has no `pcall`, so it goes back to the host.

```lua nilu
print("ここは出る")
print(1 + nil)
print("ここは出ない")
```
```output
ここは出る
```
```stderr
nilu: <manual>:2: attempt to perform arithmetic on a nil value
```

The first line's output really is printed. It fails on the second line, and the third is not run.
**The effects up to that point stay.** Only the call depth is unwound;
what was written or stored is not put back.

What the host receives is **the kind, and the one value the failure carries**. A failure of the core
puts **the same sentence as Lua's** into that value — one line with `<chunk name>:<line>: ` in front,
which is what appears after the `nilu: ` above.
The places where the command uses words of its own today are **when `error()` threw `nil`**, **when a value that is not a string was thrown**,
**when memory ran out while loading** (`out of memory`), and **when `print` could not be called at the prompt**
(`error calling 'print' (type error)`) ([11.3](11-nilu-command.md#113-how-a-failure-is-written)).
A refusal of the library carries a sentence, and running out of memory inside a call carries `not enough memory` too.
Only when it ran out while loading does it carry nothing, because there is no memory to build the sentence with.

**Which variable it was is attached in parentheses too** —
in the form `attempt to index a nil value (local 't')`,
with seven kinds: `local`, `global`, `field`, `method`, `upvalue`, `constant` and `for iterator`.
A field read through a key that is not a name, as in `t[k]` or `t[1]`, is written `field '?'`, as Lua writes it.
**When it cannot be said, nothing is written.** Lua attaches none to a comparison's failure either,
and a value that came out of a metatable is in no register, so it has no name.
Writing nothing was judged better than writing a false name, and that too is the same as Lua.

## 8.2. The kinds of failure

What the host can tell apart is the following.

| Kind | What happened | Can a program raise it? |
|---|---|---|
| syntax error | the source could not be read as a program | yes (while loading) |
| type error | something a type cannot do was done to it | yes |
| runtime error | a function returned a failure, or `error` threw a value | yes |
| the call is too deep | a recursion that is not a tail call reached the limit | yes |
| interruption | the host's hook stopped it | the host only |
| out of memory | an allocation could not be made | yes (by using it all up; there is no fixed way to raise it) |
| the stack is full | — | — |

**A syntax error carries a line and a column, and a runtime failure carries a line.**

```lua nilu
local = 1
```
```stderr
nilu: <manual>:1:7: <name> expected near '='
```

```lua nilu
local t = {}
local x = t.a.b
```
```stderr
nilu: <manual>:2: attempt to index a nil value (field 'a')
```

A runtime failure's line is **the line the failed instruction came from**. As in Lua,
for an expression that spans two lines it is the line with the operator, and for a call it is the line of the `(` or `{` that opens its arguments, or the line a string argument ends on.
No column is attached (Lua records only the line at run time too).

```lua nilu
local f = nil
f
(1)
```
```stderr
nilu: <manual>:3: attempt to call a nil value (local 'f')
```

## 8.3. What becomes a type error

```lua nilu
return 1 + nil
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a nil value
```

```lua nilu
return #5
```
```stderr
nilu: <manual>:1: attempt to get length of a number value
```

```lua nilu
return 1 < "a"
```
```stderr
nilu: <manual>:1: attempt to compare number with string
```

```lua nilu
local n = 5
return n.field
```
```stderr
nilu: <manual>:2: attempt to index a number value (local 'n')
```

```lua nilu
local x = nil
return x()
```
```stderr
nilu: <manual>:2: attempt to call a nil value (local 'x')
```

Calling a name a host did not give, such as `io` in a host without it, is this same failure.

## 8.4. `error` and `pcall`

**A failure can carry one value.** `error(v)` throws `v`, and `pcall(f, …)` catches it.
If it caught something, `false` and the value; if there was nothing to catch, `true` and `f`'s return values.

```lua nilu
print(pcall(error, "boom"))
local t = {}
t.code = 7
local ok, e = pcall(error, t)
print(ok, e.code)
print(pcall(function() return 1, 2 end))
```
```output
false	boom
false	7
true	1	2
```

Any value can be thrown. A string carries words, a table carries structure.
**The core adds nothing to it** — no position, no sentence.

`pcall` also catches **a failure that was not thrown with `error`**. **A failure of the core carries a sentence** —
a type error, a call that is too deep, a `for` whose step is 0, each the same one line as Lua's
([8.1](#81-what-happens-on-a-failure)). **A refusal of the library carries a sentence too** —
in the form `bad argument #1 to 'rep' (string expected, got no value)`, which says
which argument of which function ([10.6](10-library.md#106-what-happens-when-an-argument-is-wrong)).
**A refusal with no argument number has a sentence too** — a mistake in a pattern,
too many arguments to `table.insert`, a comparison that is not an order given to `table.sort`, and so on.
It stays `nil` only **when `nil` was thrown deliberately, as `error()` does**
(when `__tostring` does not return a string, that has a sentence too).
**When memory is short, it carries `not enough memory`.** The sentence is prepared when the state is made,
so it can be handed over even with no memory left (the same as Lua).

```lua nilu
print(pcall(function() return nil + 1 end))
print(pcall(string.rep))
```
```output
false	<manual>:1: attempt to perform arithmetic on a nil value
false	bad argument #1 to 'rep' (string expected, got no value)
```

Throw a string, and as in Lua **where it was thrown is put in front** — the chunk name and
line of the function that called `error`. `level` chooses how many levels up it points, and `0` attaches nothing.

```lua nilu
local function f()
  error("in f")
end
local ok, e = pcall(f)
print(e)
local function g()
  error("up", 2)
end
local function h()
  g()
end
local ok2, e2 = pcall(h)
print(e2)
print(pcall(error, "bare", 0))
```
```output
<manual>:2: in f
<manual>:10: up
false	bare
```

`pcall(error, "x")` stays `x`. What `level` 1 points at is the `pcall` that called `error`,
and a C function has no line (Lua answers the same). For the same reason, `error("up", 2)` inside
`pcall(g)` stays `up` — because `level` 2 points at `pcall`.

**Differences from Lua**:

- **The host's interruption cannot be caught**. When the hook stops it, the call unwinds to
  the host however many `pcall`s are around it ([8.7](#87-a-program-that-does-not-stop)), and however a C function in between
  answers it. Lua's `pcall` catches an interruption too.

The state after a catch is as it was. Repeating `pcall` piles up neither frames nor variables.

### 8.4.1. `xpcall`

**`xpcall(f, handler, …)`** is the same as `pcall`, but **on a failure it goes through the handler**.
On success, `true` and all of the results; on failure, `false` and **the handler's first result**.

```lua nilu
print(xpcall(function() return 1, 2 end, print))
print(xpcall(function() error("こわれた") end, function(m) return "H: " .. m end))
```
```output
true	1	2
false	H: <manual>:2: こわれた
```

**The handler is checked before f.** Even when f would succeed, it is refused if the handler is not a function.

```lua nilu
print(pcall(function() return xpcall(function() return 1 end, 42) end))
```
```output
false	<manual>:1: bad argument #2 to 'xpcall' (function expected, got number)
```

**When the handler itself fails, it is `error in error handling`** (Lua's wording). Lua then
calls the handler again up to a limit, but Nilu stops after one (13.1). **When memory runs out inside a library function,
the handler runs** (what it receives is `not enough memory`. Lua does not run it. 13.1).
**If the handler returns nothing, it is `nil`** (Lua answers a marker, `<no error object>`, but
here what a failure carries is a value, and `nil` when there is none).

```lua nilu
print(xpcall(function() error("a") end, function() error("b") end))
print(xpcall(function() error("a") end, function() end))
```
```output
false	error in error handling
false	nil
```

**The handler is called where Lua calls it** — **on top of the frame that failed, before the unwinding**.

`nilu_pcall` carries the handler, and the VM calls it at the point of the raise ([12.5.1](12-embedding.md#1251-seeing-where-it-failed)).

**What a program can see is the same whether the handler runs before or after the unwinding.** The difference is **what the handler can know**:
a handler the host writes can walk the chain of frames with `nilu_where`
([12.5.1](12-embedding.md#1251-seeing-where-it-failed)).
Extra arguments are passed to f.

## 8.5. `assert`

If the condition is false, it fails. If true, **it returns all of its arguments**.

```lua nilu
print(assert(1 == 1, "通る"))
print(select("#", assert(true, "x")))
```
```output
true	通る
2
```

So `local x = assert(f())` can be written. The first value `f` returned goes into `x`.

```lua nilu
local function find(t, k)
  if t[k] == nil then return nil end
  return t[k], k
end
local t = {}
t.name = "Nilu"
local value, key = assert(find(t, "name"))
print(value, key)
```
```output
Nilu	name
```

**`assert` returns every argument it received**.

**The second argument becomes the value the failure carries** ([8.4](#84-error-and-pcall)). The `nilu` command
shows it as it is if it is a string. Leave it out, and it is `assertion failed!`.

```lua nilu
assert(1 == 2, "通らない")
```
```stderr
nilu: <manual>:1: 通らない
```

```lua nilu
print(pcall(assert, false))
```
```output
false	assertion failed!
```

## 8.6. What is not a failure

The following do not fail. They may be surprising, but each is the same as Lua.

```lua nilu
local t = {}
print(t.missing)
print(1 / 0, 0 / 0)
print(#"")
print(nil == false)
```
```output
nil
inf	nan
0
false
```

- reading a key the table does not have is `nil`
- dividing by 0 is infinity
- the length of an empty one is 0
- comparing different types with `==` is `false`

**Reading** with a value that cannot be a key does not fail either. **Writing** with one fails
([2.5](02-values.md#any-value-but-nil-and-nan-can-be-a-key)).

## 8.7. A program that does not stop

**An infinite loop is not a failure.** It is correct as grammar, and there is no means of
stopping it inside the language.

The host can place a hook that is called every so many VM instructions, and tell it to stop.
What the host receives then is an "interruption". The `nilu` command places no hook, so
`Ctrl-C` ends the whole process.

This is not an "unnoticed hole"; it is the result of **deciding that the host decides**.
The same holds for the host's functions: if a function the host wrote does not return, the hook cannot stop it.

---

Next: [9. Garbage collection](09-gc.md)
