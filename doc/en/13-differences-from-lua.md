[← Contents](README.md)

# 13. Differences from Lua

Nilu is built with Lua 5.5 as its primary source. **It has never claimed compatibility.**
So the right word is not "incompatibility" but "difference".

There are four kinds of difference, and they must not be mixed.

| Kind | How to read it |
|---|---|
| **Decided and changed** | There is a reason. Reversing it means overturning the reason |
| **Different because a mechanism is absent** | It was not decided. What Lua's answer needs is written down |
| **Not there yet** | It was not declined. What it needs is written down |
| **Where Lua says nothing** | Either would do. What Nilu decided is written down |

## 13.1. Where it differs

### What was decided and changed

| Difference | Lua | Nilu | Why |
|---|---|---|---|
| **Arithmetic does not convert a string** | `"1" + 1` is 2 | a type error | Conversion becomes a rule of the operator rather than of the value. Write `tonumber`. `..` and `table.concat` do take a number, as `tostring` spells it |
| **NaN is always `nan`** | `0 / 0` is `-nan` | always `nan` | Nilu writes the spelling itself (it does not hand the sign to C's `printf`). **Every NaN has the same spelling** |
| **The `__call` chain goes up to 1999 steps** | up to 15 | up to 1999 (`'__call' chain too long` at the 2000th) | The limit of 2000 is borrowed from `__index`'s `MAXTAGLOOP`, and the function finally called counts as a step |
| **A metamethod is inherited through the metatable's `__index`** | every name is read from the metatable itself (raw) | read from the metatable, then along the tables in `__index` of the metatable's metatable, up to 2000 steps; a function `__index` is not called (7.4) | One base metatable can hold the names for many. Python and PHP find their special methods along the class chain in the same way, without running `__getattr__`. `__metatable` and `__gc` are still read from the metatable itself, since they describe the metatable. A `__name` out of reach leaves the plain word in a failure's sentence |
| **What `error()` carries is `nil`** | `pcall(error)` is `false <no error object>` | `false nil` | What a failure carries is a value, and `nil` when there is none |
| **When the handler itself fails, the handler runs only once** | when the handler fails, it is called again up to a limit | runs once, then `error in error handling` | The nesting is stopped at one level |
| **A failure value that is not a string is written by its kind** | `nilu -e 'error(1)'` is `1` | `runtime error` and `(error object is a number value)` | The command writes only a string as it is, and says the kind of any other value. Lua's `msghandler` turns a number into a string |
| **A failure value that is not a string gets no traceback** | `error({})` inside a function gets a traceback too | no traceback | A traceback is attached only for a string value |
| **A failure with only one frame at the top gets no traceback** | `error("x")` is still followed by `stack traceback:`, `[C]: in global 'error'` and more | the one line `nilu: (command line):1: x` | A traceback is written only when there are two calls or more. A one-frame traceback only repeats the position on the line above it ([11.3](11-nilu-command.md#113-how-a-failure-is-written)) |
| **A refusal from a function `for` called says that function's name** | `for k in next, 1 do end` is `bad argument #1 to 'for iterator'` | `bad argument #1 to 'next'` | Nilu's `for` does not name the caller `for iterator`; it uses the function's registered name |
| **When memory runs out inside a library function, the handler runs** | `xpcall`'s handler does not run | it runs (what it receives is `not enough memory`) | The library allocates outside the state, so that failure carries a sentence as a runtime error. When it runs out inside the VM, it does not run, as in Lua |
| **A `<const>` holding a constant still gets a name** | `local x <const> = 1; x()` is `attempt to call a number value` | `attempt to call a number value (local 'x')` | Lua folds a `<const>` whose right side is a constant into the places that use it and leaves no variable. Nilu keeps every `<const>` as a read-only local, so a failure's sentence names it. It counts toward the limit on locals (200) too: with 201 constant `<const>`s in a row, Lua accepts and Nilu refuses with `too many local variables` |
| **A field read through a number is `field '?'`** | `t[1].z` with `t = {}` is `attempt to index a nil value (field 'integer index')` | `attempt to index a nil value (field '?')` | Lua writes `integer index` only for a literal key from 0 to 255, the range its `GETI` instruction holds; any other key that is not a name is `?` there too. Nilu has no such instruction and writes `?` for every key that is not a name ([8.1](08-failure.md#81-what-happens-on-a-failure)) |
| **A syntax error carries a column** | `f.lua:1: <name> expected near '='` | `f.lua:1:7: <name> expected near '='` | The sentence is borrowed from Lua. Lua has no column. **The sentence differs in places too**: a statement that is neither a call nor an assignment (`x`, `f() = 1`, `a, b`) points at the start of the statement and says `syntax error near 'x'`, where Lua points at the token after it (`'=' expected` for `a, b`). When a closing word is missing and the opening word is on another line, Lua adds `(to close 'if' at line 1)` and Nilu does not |
| **Syntax has a depth limit, and hitting it names the limit** | the limit is the C stack: 197 nested parentheses give `C stack overflow` (no position) | nesting or chaining past 200 levels gives `chunk has too many syntax levels (limit is 200)` (with a position). At the top of a chunk, parentheses are read 200 deep | The limit of 200 is a number Nilu chose, and it says where it stopped. How deep a given source can go depends on what encloses it. Break a long expression by putting part of it in a variable |
| **A source is at most 4294967294 bytes** | any length loads; a chunk with more lines than an `int` holds is `chunk has too many lines` | a longer source is refused before it is read: `chunk is too large (limit is 4294967294 bytes)` at 1:1 | Offsets, lines and columns are 32-bit so that a syntax tree node stays small; the limit on lines follows from the one on bytes |
| **A library argument does not turn a number into a string either** | `string.rep(1, 2)` is `11` | `bad argument #1 to 'rep' (string expected, got number)` | With no automatic conversion, a number passed where a string is taken is refused by its type. `os.getenv(1)` and `io.stdout:seek(1)` are the same |
| **Arithmetic on a string that is not a number is refused by type** | `"a" + 1` is `attempt to add a 'string' with a 'number'` | `attempt to perform arithmetic on a string value (constant 'a')` | Lua's sentence comes from the string metamethods that try to turn a string into a number. Nilu does not convert, so the sentence is the type's |
| **A `goto` refusal points at the `goto`** | where the block finished being read (`t.lua:4:`) | the `goto`'s line and column (`t.lua:2:3:`) | So that jumping there in an editor lands on the place to fix. The wording and `at line N` are Lua's |
| **A `__tostring` that returns a number is refused** | the number is turned into a string and used (`true 1`) | `'__tostring' must return a string` | Because there is no automatic conversion. The sentence is Lua's |
| **`pcall` does not catch the host's interruption** | catches it | unwinds to the host | So that the host can stop a program that cannot be stopped |
| **`==` does not call `__eq` when both are `userdata`** | called when both are full userdata (after placing `getmetatable(io.stdout).__eq`, `io.stdout == io.stderr` is `true`) | only whether they are the same one (`false`) | `__eq` is called only when both are tables. The other metamethods answer as for a table ([12.6](12-embedding.md#126-giving-a-program-the-hosts-data-to-carry)) |
| **`math.tointeger` does not convert a string** | `math.tointeger("8")` is `8` | `nil` | A number is not made from a string implicitly, as in arithmetic; write `tonumber` |
| **A float is printed with the shortest digits that read back** | `print(1/3, 2^63)` gives `0.33333333333333331	9.2233720368547758e+18` (17 digits when 15 do not read back) | `0.3333333333333333	9.223372036854776e+18` | A float has one spelling, decided as the shortest digits that read back to the same value. `tostring` and `string.format` spell with the same function. `%g`'s shape and reading back to the same value are Lua's; only the digit count differs ([2. Values](02-values.md)) |
| **The embedded library has no `io` or `os`** | `io` and `os` are standard libraries | `nilu_openlibs` does not open them; the `nilu` command brings its own | The core touches nothing outside itself (files, the clock, the process); those are the host's ([11.4](11-nilu-command.md#114-io-and-os)) |
| **`print` writes through a writer the host gives** | `print` writes to the C library's standard output | `print` hands its line to the writer given with `nilu_setwriter`; without one it fails with `cannot print: no writer was given to this state` ([1.3](01-getting-started.md#13--print-writes-where-the-host-says)) | Where output goes is the host's (a game, an editor and a server each want it elsewhere), and `print` behaves the same in every host |
| **`require` looks next to the file that asks** | `package.path`'s templates, from the current directory | next to the file being loaded, then next to the started script, as the host's reader decides ([11.6](11-nilu-command.md#116-where-require-looks)) | A program's modules are found wherever it is started from |
| **`package.loaded` keeps a module under where it was found** | under the name written | under the reader's key (`lib/util.nilu`) | Two modules of one name in two directories stay two |
| **No search settings in `package`** | `package.path`, `cpath`, `searchers`, `searchpath`, `config`, `loadlib` | only `package.loaded` and `package.preload` | Finding a module is the host's reader, so a game or an editor can load from an archive; the command's reader looks next to the asking file ([11.6](11-nilu-command.md#116-where-require-looks)) |
| **`collectgarbage` has no modes** | `"incremental"`, `"generational"`, `"param"` | refused (`invalid option`); `"stop"` and `"restart"` are there | There is one collector, a generational mark and sweep that decides by itself when to collect only what is new and when to collect everything, so there is nothing to switch or tune ([9.4](09-gc.md#94-what-there-is-not)) |
| **A `require` cycle is refused** | the files load again and again until `C stack overflow` | `cannot load module 'a' while it is loading (a.nilu -> b.nilu -> a.nilu)` | The cycle is named where it closes |
| **`load` and `loadfile` take text only** | a function answering pieces, a binary chunk, and a number as text | a string, a mode that allows `t`; `load(1)` is `bad argument #1 to 'load' (string expected, got number)` | There is no binary chunk, and a number does not turn into a string |
| **There is no `string.dump`** | answers a function's binary chunk, which `load` reads back with mode `"b"` | `string.dump` is `nil` | The bytecode is internal and may change in any version; a program travels as its source (the owner's answer) |
| **`debug` has `traceback` and `getinfo` only** | 16 functions, among them `getlocal`, `setlocal`, `setupvalue`, `upvaluejoin`, `sethook` and `getregistry` | `debug.traceback` and `debug.getinfo` | Nothing changes a function from outside (the owner's answer); a host has `nilu_sethook` |
| **`dofile` and `loadfile` need a path** | without one they read standard input | `bad argument #1 to 'dofile' (string expected, got no value)` | The library reads nothing itself; the host's reader answers for a path |
| **C API: most functions answer a status, and nothing jumps through C** | `lua_pushnumber` and `lua_settop` return nothing, and a failure jumps. `lua_error` never returns. `lua_checkstack` is asked before pushing | the pushes, the table reads and writes and the calls return a `NiluStatus`. `nilu_compare` answers a status and pushes the answer, `nilu_next` answers a missing key with a status, and `nilu_error` returns, answering `NILU_FAIL`. There is no `lua_checkstack` | A push can be refused, and Nilu brings no mechanism for jumping through C, so it says so in the return value. Every push answers on the spot, so a call that checks beforehand is not needed ([12.3](12-embedding.md#123-almost-every-function-answers-a-status)) |
| **C API: the type tags' numbers are Nilu's** | `LUA_TNIL` is 0, `LUA_TBOOLEAN` is 1, … | `NILU_TNIL` is 0, `NILU_TNUMBER` is 1, … | Lua's tags include types Nilu does not have. The idea of `NILU_TNONE` (`-1`) is borrowed from `LUA_TNONE`. Compare by name, not by number |
| **C API: creating and closing are `nilu_new` and `nilu_close`** | `lua_newstate` and `lua_close` | `nilu_new` and `nilu_close` | The pair reads better |
| **C API: a `userdata` has no finaliser** | `__gc` is called at collection | a metatable with `__gc` set on a `userdata` gives `NILU_ERR_TYPE` | A `userdata` owns its own bytes only, and the block is freed as it is at collection. A resource outside it is closed by the host |
| **A table's `__gc` is not read** | `__gc` is called at collection | nothing is called; the field is not refused | Closing is the program's or the host's, as for a `userdata` (the owner's answer) |
| **C API: there is no light `userdata`** | `lua_pushlightuserdata` exists | full `userdata` only | It was decided to have full ones only |
| **C API: `nilu_tonumberx` does not turn a string into a number** | after `lua_pushstring(L, "10")`, `lua_tonumberx` returns `10` and sets `isnum` to 1 | the same sequence returns `0` and sets `isnum` to 0 | There is no automatic conversion. To read a string as a number, use `nilu_stringtonumber` ([`include/nilu.h`](../../include/nilu.h)) |

### What differs because a mechanism is absent

**These were not decided: Nilu differs because it lacks a mechanism Lua's answer needs.** The fourth column says what is absent.

| Difference | Lua | Nilu | What is absent |
|---|---|---|---|
| **`math.exp` and the other real functions can differ from Lua's in the last bit** | `math.exp(1)` is `2.7182818284590451` | `2.7182818284590455` (one unit in the last place) | The C library's math functions: the core uses Zig's, not libc |
| **The name when there is no calling code** | `pcall(string.rep)` is `'string.rep'` | `'rep'` | When there is no caller's bytecode, the registered name is used. Lua searches the loaded modules and answers `string.rep` (`pushglobalfuncname`), but Nilu has no such table. With neither a caller nor a name, Lua says `'?'` (`pcall(io.stdout.seek, io.stdout, "nope")` is `bad argument #2 to '?'`) and Nilu says the registered `'seek'`. With a caller, as in `local f = string.rep; f()`, both say `'f'` |
| **A refusal from a function called through `__call` counts the added argument too** | the added argument is `bad extra argument #1 to 'c'`, a written argument is `#1` for `c({})` | the added argument is `bad argument #1 to 'c'`, a written argument is `#2` for `c({})` | Lua numbers without counting the argument `__call` put in front, and marks a refusal of the added argument with `extra` (`ar.extraargs`). Nilu does not count that it was added, so a written argument's number is one larger. When called as a method, Lua says `calling 'm' on bad self` for a refusal of the receiver and Nilu says `bad argument #2 to 'm'` |
| **A traceback ends at the main chunk** | a last line `[C]: in ?` | the last line is `in main chunk` | The command's own call into the chunk is not a frame ([11.3](11-nilu-command.md#113-how-a-failure-is-written)) |
| **`print` calls the global `tostring`** | `tostring = function() return "X" end; print(1)` is `1` | `X` | There is no C call at the boundary that spells a value (`luaL_tolstring`), so the library's `print`, written against the C API, calls the program's `tostring` |
| **Strings compare byte by byte** | by the C locale (`strcoll`) | by byte value | Because the core does not use libc. They agree in the C locale |
| **`upper`/`lower` are ASCII only** | locale-dependent | ASCII | Because the core does not use libc. They agree within ASCII |
| **A pattern's character classes are ASCII** | locale-dependent (`isalpha` and the like) | ASCII | Because the core does not use libc. The same reason as `upper`/`lower`, and they agree in the C locale ([10.2](10-library.md#102-string)) |
| **`os.date` is always the C locale** | after `os.setlocale("ja_JP.UTF-8")`, `%A` is `木曜日` | always English (`os.date("!%A", 0)` is `Thursday`). `os.setlocale` answers `"C"` and changes nothing (`""` too, which in Lua adopts the environment's) | `setlocale` is never called, so `%c`, `%x`, `%A` and the like answer as the C locale does. Lua's default is the C locale too, so they agree unless the locale is changed |
| **`math.random`'s initial state is fixed** | seeded from the clock and an address each time it is opened | the same sequence as `math.randomseed(0)`. The `nilu` command seeds it at start-up | Because the core has no clock. With a seed from the host, it behaves as Lua does ([10.4](10-library.md#104-math)) |
| **`math.randomseed()` reseeds from the generator** | from the clock | from the generator's next value | Because the core has no clock. With a seed at start-up it stays unpredictable; without one it stays the fixed sequence |
| **`table.sort`'s pivot is fixed** | scattered with the clock and an address for a large array | always the middle | The core has no clock. The result is the same |
| **There is one sentence for a call that is too deep** | `C stack overflow` (no position) when a library function is in between | always `stack overflow`. A position is attached when it was a Lua function that hit the limit, and not when it was a library function | Lua has separate limits for the Lua stack and the C stack, but Nilu counts the call depth against one limit. A `__tostring` or a `sort` comparison that keeps calling itself is refused with the same sentence |
| **C API: `nilu_getupvalue`/`nilu_setupvalue` name the running closure** | `lua_getupvalue(L, funcindex, n)` names a function on the stack, and a C function reads its own values through `lua_upvalueindex(n)` | `nilu_getupvalue(N, n)` and `nilu_setupvalue(N, n)` name the values of the C closure that is running, by number | There is no pseudo-index (`lua_upvalueindex`); the stack is the only way an index reaches a value ([12.8](12-embedding.md#128-what-is-absent)) |
| **A function holds at most 65535 constants** | a table of 70,000 distinct strings is read | `too many constants (limit is 65535)` | The number that points at a constant is 16 bits wide |
| **A limit points at the first item past it, and a generic `for` takes one slot fewer** | `too many local variables (limit is 200) in main function near 'do'`: the position is the token being read, and a generic `for` with one name takes 4 of the 200 locals | `too many local variables (limit is 200)` at the first item past the limit: the 201st name, the reference that would be the 256th upvalue, the literal that would be the 65536th constant, the value that would need the 256th register. A generic `for` takes its names plus 2 | Lua's position is wherever reading had reached. Nilu counts two of a generic `for`'s hidden values toward the 200 where Lua counts three: the value the loop closes is held in a register that is not counted as a local, so a generic `for` keeps no local for closing |

## 13.2. What is not there yet

**Not "it cannot", but "it is not implemented yet".** What it needs is written down.

### Language

**Nothing of Lua 5.5's language is missing now**: the last were `<close>` and `...rest`. The two
below look missing and are not.

⚠ **`...[1]` is not missing.** **Measured, `lua5.5` 5.5.0 and Nilu both refuse it with the same sentence**
(`'end' expected near '['`). Only a name and `( exp )` can be followed by an index. **Both refuse it, so it is not a difference.**

⚠ **A non-ASCII name is not missing either.** It is not something missing but **the same as Lua's default**.
**Measured, `lua5.5` 5.5.1 refuses `local あ = 1` too** (`<name> expected near '<\227>'`).
Lua accepts it only when built with `LUA_UCID` defined.

### Library

**Nothing of Lua 5.5's library is missing now.** What it leaves out was decided, and is in
[13.1](#131-where-it-differs).

### C API

The list is in [12.8. What is absent](12-embedding.md#128-what-is-absent).
**Put in two places, one goes stale, so only that one holds it**.
It has a column with Lua's spellings.

## 13.3. What to write instead

"What it needs" in the tables above is **what it takes to fill the gap**.
This section answers a different question — **what to write today**.
**Every example below was run and confirmed** (`zig build manual-check`).

**Lua's statements (`do … end`, `elseif`, `;`, `repeat … until`, `goto`, `t:m()`, `{1, 2}`, `f "x"`) can be
written as they are**.

### Functions and methods

**String methods are called with `:` too, as in Lua.** `s:upper()` is `string.upper(s)`:
every string shares one metatable whose `__index` is `string` (`getmetatable("")` answers it).

```lua nilu
local s = "Hello"
print(s:upper(), s:sub(1, 3), s:len(), getmetatable("").__index == string)
```
```output
HELLO	Hel	5	true
```

### Names

A non-ASCII name **cannot be used** (the same as Lua's default), but **the contents of a string can be
any bytes**. Only variable names need to be ASCII.

### Other

- **`xpcall`** is there. The handler is called **before the unwinding**, as in Lua ([8.4.1](08-failure.md#841-xpcall)).

### What has no substitute

**The following have no rewrite here.** Staying silent would be less kind, so they are listed.

| What is not there | Why it cannot be rewritten |
|---|---|
| `__gc` on a table | Nothing is called when an object is freed; a program closes what it holds, or uses `<close>` |

## 13.4. What is borrowed from Lua and kept the same

The places that **need no attention** when porting.

- the truth rule (only `false` and `nil` are false)
- operator precedence and associativity, `^` and `..` being right-associative
- `%` truncating toward negative infinity, `math.fmod` toward 0
- `/` always being real division, `//` being floor division
- indexing from 1, a negative index counting from the end
- the border of `#` (unspecified when there are holes)
- the order of `pairs` being unspecified
- the rules for multiple values (only the last in a list expands, `(f())` is one)
- a tail call remaking the frame
- a `for`'s control variable being read-only (a 5.5 change)
- the `__index` chain, `>` using `<` (that `__eq` is not called between two `userdata` is a 13.1 difference)
- a metatable protected by `__metatable`
- a number being displayed in `%g`'s shape, reading back to the same value (the digit count is in [13.1](#131-where-it-differs))
- `tonumber` allowing surrounding whitespace and not allowing leftover characters
- the spellings `inf`/`nan` not being read as numbers
- a global variable being a field of `_ENV`

## 13.5. Where Lua says nothing

- **How `tostring` represents a table and a function**. The shape, `type: identity`, is borrowed from Lua, but
  the contents are not promised. They change from run to run
- **The actual order of `pairs`**. Lua does not promise it either. Nilu walks the keys 1, 2, 3, … that
  it stores as a sequence in order, then the rest in the hash's order, which changes as the table grows
- **What `#` answers for a table with holes**. Which border is unspecified
- **Which one stays when the same key is written twice in one constructor**.
  `{x = 1, x = 2}` is last-wins (the same as Lua), but **when an element with a key collides with one without,
  as in `{"あ", [1] = "い"}`, it is unspecified.** Lua's own answer **changes with the number of free registers** —
  measured, it was `い` inside a function with 199 local variables, and `あ` inside one with 0
  (`lua5.5` 5.5.0). Nilu borrows the mechanism whole, so it inherits the same corner

---

Next: [14. Porting from Lua](14-porting.md)
