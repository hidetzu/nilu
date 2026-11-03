[← Contents](README.md)

# 11. The `nilu` command

`nilu` is **one of the host programs**. It is not part of the language.
It is the one file `cli/nilu.c`, written with nothing but the public header and the static library.

Given an option it does not know, it writes the usage and stops.

```sh nilu-cli
nilu -x
```
```stderr
nilu: unknown option -x
usage: nilu [options] [script]
Available options are:
  -e stat   run the text 'stat'
  -i        enter the prompt after running the script
  -l mod    require library 'mod' into global 'mod'
  -l g=mod  require library 'mod' into global 'g'
  -W        turn warnings on
  -v        say which version this is
  --        stop handling options
  -         stop handling options and run stdin
```

## 11.1. How to run it

| Written as | What it does |
|---|---|
| `nilu hello.nilu` | runs a file |
| `nilu -e 'print(1 + 2)'` | runs the text as given |
| `nilu -e'print(1 + 2)'` | the same, joined |
| `echo 'print(1)' \| nilu -` | runs standard input |
| `nilu` | the prompt |
| `nilu -i hello.nilu` | runs a file, then the prompt |
| `nilu -l util hello.nilu` | `util = require("util")` first, in order with `-e` (`-l u=util` names the global `u`) |
| `nilu -W hello.nilu` | runs with warnings on, as after `warn("@on")` |
| `nilu -v` | prints the version |

On Windows, the lines the command writes to standard output end in `\r\n`, as Lua's command's do; elsewhere they end in `\n`.

```sh nilu-cli
nilu -e 'print(1 + 2)'
```
```output
3
```

```sh nilu-cli
nilu -e'print("くっつけても同じ")'
```
```output
くっつけても同じ
```

To read from standard input, pass `-`.

```sh nilu-cli
nilu -
```
```stdin
print(1 + 2)
```
```output
3
```

`-e` can be written any number of times, and they run in the order written.

```sh nilu-cli
nilu -e 'print("ひとつめ")' -e 'print("ふたつめ")'
```
```output
ひとつめ
ふたつめ
```

You can ask for the version too.

```sh nilu-cli
nilu -v
```
```output
nilu 0.1.0-dev.1
```

A `-dev.N` after the number marks a build made between releases: the number is the release it is heading for, and N is the version's own number counted from the last release (before the first release, from the beginning). A release carries no suffix.

Until 0.1.0 is released, compatibility of the API, ABI, language and command
is not guaranteed between development versions. Changes are recorded in the
repository's GitHub issues and architectural decisions.

**A script's return value is discarded.** To output something, use `print`.

### Passing arguments to a script

What is written after the script is **the script's arguments**. They can be received through `...`
or through the table `arg` (the same as Lua). `arg[0]` is the script itself, `arg[1]` onwards are the
arguments, and the negative indices hold what came before (`nilu`, and the options before the script).

```sh nilu-cli
nilu - one two
```
```stdin
print(...)
print(arg[0], arg[1], arg[2], #arg)
```
```output
one	two
-	one	two	2
```

The main chunk is a **vararg function**, as in Lua, so `...` can be written at the top level
([6.3](06-functions.md#63-undeclared-arguments--)). The text of `-e` and a line at the prompt are
called with no arguments, but `arg` is visible from there too. **Without a script**, as in Lua,
`arg[0]` is the program and the options follow it: with `nilu -e 'code'`, `arg[1]` is `-e` and
`arg[2]` the code.

### An executable script

**If the first line starts with `#`, that line is skipped**.
So a script that was `chmod +x`ed runs as it is.

```lua nilu-source
#!/usr/bin/env nilu
print("hello")
```

```bash
chmod +x hello.nilu
./hello.nilu
```

**Line numbers do not shift.** The first line is blanked rather than removed, so a failure on
line 3 is reported as line 3.

**A bare `#` is skipped too** (the test is not on the two characters `#!`). The same as Lua.

**This is not a comment.** What is skipped is **the first line of what was read as a file** only;
the text of `-e` is not skipped.

```sh nilu-cli
nilu -e '#print(1)'
```
```stderr
nilu: (command line):1:1: unexpected symbol near '#'
```

Standard input (`nilu -`) is **on the side that is read as a file**, so it is skipped. In Lua,
`lauxlib`'s `skipcomment` does this, and that layer does not exist in Nilu
([12.8](12-embedding.md#128-what-is-absent)). So it is **the job of the program that reads the file**
— the `nilu` command does it, and whoever writes their own host decides for themselves.

## 11.2. The prompt

The example below is **what `nilu` writes when three lines are typed at the prompt**.
The characters typed do not appear. What the terminal shows is the terminal's echo, and
`nilu` echoes nothing.

```sh nilu-cli
nilu
```
```stdin
1 + 2
local x = 1
print("こんにちは")
```
```output
nilu 0.1.0-dev.1
> 3
> > こんにちは
> 
```
```stderr
warning: locals do not survive across lines in interactive mode
```

What is actually seen in the terminal is this (`1 + 2` and the rest are the characters you typed).

```text
$ nilu
nilu 0.1.0-dev.1
> 1 + 2
3.0
> local x = 1
> print("こんにちは")
こんにちは
>
```

A line you enter is first read as `return <line>`. If that passes as syntax, it is
evaluated as an expression and the result is shown. If it does not pass, the line itself runs as a statement.
This is what Lua's `lua` command does.

**It reads until the statement is complete**.
For a line that ends partway, it prints `>> ` and waits for the next line, and runs them once they join up.

```sh nilu-cli
nilu
```
```stdin
if 1 == 1 then
print("はい")
end
```
```output
nilu 0.1.0-dev.1
> >> >> はい
> 
```

- **Local variables do not survive into the next statement.** The three joined lines are one statement,
  and when one statement ends, that is the end of them. Reading `x` on the line after `local x = 1`
  reads the global variable `x` (`nil`). A global variable does survive.
- **A line that starts with `local ` gets a warning** (the same wording as Lua's). That is what is
  attached to `local x = 1` in the example above.
- There is no line history and no line editing (because `readline` is not used).

```sh nilu-cli
nilu
```
```stdin
local x = 1
print(x)
y = 2
print(y)
```
```output
nilu 0.1.0-dev.1
> > nil
> > 2
> 
```
```stderr
warning: locals do not survive across lines in interactive mode
```

**Whether the input is incomplete is judged by nothing but the tail of the syntax error's text.** If it ends
with `near <eof>`, it is "not enough input"; otherwise it is "wrong". This is what Lua's `incomplete`
does, a comparison of 5 bytes.

A short string cannot span lines, but **the first line's text ends with `near <eof>`, so the
continuation is asked for once**. After joining, it is refused as an unfinished string. Lua does the same.

A failure at the prompt carries no `nilu:`. There is no file name either.

```sh nilu-cli
nilu
```
```stdin
return nil + 1
```
```output
nilu 0.1.0-dev.1
> > 
```
```stderr
stdin:1: attempt to perform arithmetic on a nil value
```

`Ctrl-D` (end of input) leaves.

What the prompt calls to show a value is **the global `print`** (the same as Lua's `lua -i`).
So if you replace `print` at the prompt, the next line's value is shown by that `print`.

```sh nilu-cli
nilu -
```
```stdin
print = function(...) io.write("P:", select("#", ...), "\n") end
```
```output
```

(This example runs through `-`, so nothing is shown. The behaviour at the prompt is watched by
`the prompt calls the global print` in `zig build cli-test`.)

### Editing a line

**On a terminal, the prompt edits the line being typed**: Left and Right move by characters (a
character that takes two bytes or two columns counts as one), Home and End (also `Ctrl-A` and
`Ctrl-E`) go to the ends, Backspace and Delete remove one, Up and Down walk the lines given in
this session, `Ctrl-C` drops the line, and `Ctrl-D` on an empty line ends the prompt. The history
is not kept after `nilu` exits. When the input or the output is not a terminal (a pipe, a file),
the line is read as it is; the Windows console edits lines itself. `readline` is not used, since
nothing outside the Zig standard library is a dependency.

## 11.3. How a failure is written

```sh nilu-cli
nilu -e 'return nil + 1'
```
```stderr
nilu: (command line):1: attempt to perform arithmetic on a nil value
```

```sh nilu-cli
nilu nope.nilu
```
```stderr
nilu: cannot open nope.nilu: No such file or directory
```

```sh nilu-cli
nilu -
```
```stdin
local = 1
```
```stderr
nilu: stdin:1:7: <name> expected near '='
```

The shape is `nilu: <where>:<line>: <what>`. A syntax error carries `line:column`, a runtime failure carries `line`
([8.2](08-failure.md#82-the-kinds-of-failure)). The position is attached because it is the head of a string; for `error()`'s `nil` the command
attaches it, but when a value that is neither a string nor `nil` is thrown, as in `nilu -e 'error(1)'`,
it comes out as `nilu: (command line): runtime error` with no line, and a second line `nilu: (error object is a number value)` follows
([13.1](13-differences-from-lua.md#131-where-it-differs)).

### The traceback

**When there are two or more frames, the traceback is printed as well**.
**From the innermost outward**, one frame per line: the position, then what the function is, as Lua
writes it — the name it was called by (`upvalue 'c'`, `local 'b'`, `field 'run'`, `method 'go'`),
`main chunk`, or `function <where:line>` with the line it was defined on when the call gave no name.

```lua nilu
local function c() local v = 1 + nil return v end
local function b() local v = c() return v end
local v = b()
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a nil value
stack traceback:
	<manual>:1: in upvalue 'c'
	<manual>:2: in local 'b'
	<manual>:3: in main chunk
```

⚠ **`local v = c()` is written because `return c()` would collapse the levels.**
A tail call reuses the frame ([6.5](06-functions.md#65-tail-calls)), so
**fewer frames actually appear in the traceback** — Lua writes
`(...tail calls...)` there, but here there is no way to say that a level collapsed.

**When a native function raised the failure, as `error()` or a library refusal does, that frame comes
first**, named the same way (`[C]: in global 'error'`); a native with no name is `[C]: in ?`.
Lua ends with one more line, `[C]: in ?`, for its command's own call into the chunk; here that call is
not a frame, so the last line is `in main chunk`.

```lua nilu
local function c() error("boom") end
local function b() c() end
b()
```
```stderr
nilu: <manual>:1: boom
stack traceback:
	[C]: in global 'error'
	<manual>:1: in upvalue 'c'
	<manual>:2: in local 'b'
	<manual>:3: in main chunk
```

"Two or more frames" is counted in **frames of Nilu functions**. So when `error("x")` is called at the
outermost level, it is one line only.

⚠ **With one level, it is not printed.** A one-level traceback would repeat **the position on the line
above**. **A syntax error does not get one either** — it failed
at loading time, and there is not a single call (Lua does not attach one either).

**A long traceback leaves out the middle.** It writes 10 levels from the top and 11 from the bottom, and in between
says only the count, `...	(skipping N levels)` — the same numbers as `luaL_traceback`.

**A failure caught with `pcall` or `xpcall` does not get one.** The command is what prints it, and
the program is what received the failure.

**Who writes `<what>` depends on whether the failure carried a value.**
A failure from the core and a string thrown with `error` **carry their own text and position**, so the command
prints them as they are (`attempt to perform arithmetic on a nil value` is the core's wording).
For **a failure that carries no string** (when `error()` threw `nil` or a value that is not a string), the command writes its own words.
So the table below is worded differently in another host.

| Kind | The command's wording when no value is carried |
|---|---|
| Syntax error | `syntax error` |
| Type error | `type error` |
| Runtime error | `runtime error` |
| the call is too deep | `too many nested calls` |
| Out of memory | `out of memory` |
| The stack is full | `the stack is full` |
| Interrupted | `interrupted` |

**What actually comes out for a file and for `-e` is `runtime error` and `out of memory`.** `runtime error` is
when `error()` threw `nil`, and when it threw a value that is not a string. A library refusal carries text.
`io.write`, `io.read`, `f:read`, `f:write` and `f:flush` failing on a stream are not a failure; they return the same three values as Lua's
`luaL_fileresult`, `nil`, the text and the errno (the writing ones return a fourth, the number of bytes
written before failing). `local f = io.open("/dev/null"); io.output(f); print(io.write("x"))` is
`nil	Bad file descriptor	9	0`.
**Out of memory splits in two**: when memory runs out inside a call, the failure carries the text `not enough memory`,
so that text is what comes out. **When it runs out inside loading (`nilu_loadstring`), nothing is carried**
(there is no memory to build the text with either), so the command writes `nilu: <where>: out of memory`.
**A syntax error carries its own text too**, so the words `syntax error` do not appear
(they remain only for when the text could not be built).
**A call that is too deep is a failure the core carries words for, so the command's `too many nested calls` does not appear.**
**`type error` appears only at the prompt**: the global `print` is called to write the line's value
([11.2](#112-the-prompt)), so typing `1 + 2` after `print = nil` gives
`error calling 'print' (type error)`.
The last two cannot be caused. No hook is installed, so "interrupted" does not happen, and
"the stack is full" does not reach from a program.

On a failure, the exit status is 1. If nothing failed, it is 0.

## 11.4. `io` and `os`

These are **functions the `nilu` command registers**. They are not in the library
([1.3](01-getting-started.md#13--print-writes-where-the-host-says)).
The core touches neither standard output, standard input, the clock nor the process, so the functions that touch them belong to the host.

| Function | What it does |
|---|---|
| `io.write(…)` | The arguments, as they are, to **the current output**. **No tab between them and no newline after** |
| `io.read([fmt, …])` | Reads from **the current input**. The default is one line |
| `io.open(name [, mode])` | Opens a file (11.4.1) |
| `io.lines([name])` | Iterates over lines. Omitted, the current input (11.4.1, 11.4.2) |
| `io.close([f])` | Closes. Omitted, the current output (11.4.1, 11.4.2) |
| `io.input([f])`, `io.output([f])` | Look at, or replace, the current input and output (11.4.2) |
| `io.flush()` | Flushes the current output |
| `io.type(v)` | Answers whether it is a file, and whether it is open (11.4.3) |
| `io.tmpfile()` | Makes a temporary file with no name (11.4.3) |
| `os.clock()` | The CPU time the process used (seconds) |
| `os.time([t])` | The current time (seconds since 1970). Given a table, the time of that date (11.4.4) |
| `os.date([fmt [, t]])` | Turns a time into a string or a table (11.4.4) |
| `os.getenv(name)` | An environment variable. `nil` if absent (11.4.4) |
| `os.exit([code [, close]])` | Exits. `true` is 0, `false` is 1, a number is that value |
| `os.remove(name)`, `os.rename(old, new)` | Removes / renames a file (11.4.5) |
| `os.tmpname()` | A name for a temporary file, made empty (11.4.5) |
| `os.difftime(t2, t1)` | `t2 - t1` in seconds |
| `os.setlocale([locale [, category]])` | Always the C locale: answers `"C"`, changing nothing (11.4.5) |
| `os.execute([command])` | Runs a command through the shell, and answers its exit status (11.4.5) |
| `io.popen(prog [, mode])` | Runs a program, as a file to read its output or write its input (11.4.5) |

```lua nilu
io.write("a", 1, "b", "\n")
```
```output
a1b
```

Numbers are spelled as `print` spells them (`1.5` is `1.5`, `2.0` is `2`). **Anything other than a string or a number is refused.**

```lua nilu
print(select(2, pcall(io.write, true)))
```
```output
bad argument #1 to 'write' (string expected, got boolean)
```

The text is Lua's.
**`io.write` returns the file it wrote to**. As in Lua, calls can be chained.

```lua nilu
io.write("a"):write("b\n")
```
```output
ab
```

The formats of `io.read` are the same as Lua's.

| Format | What it reads | When it could not |
|---|---|---|
| `"l"` (default) | One line, without the newline | `nil` |
| `"L"` | One line, with the newline | `nil` |
| `"a"` | All that remains | Never fails. At the end, `""` |
| `"n"` | One number. Leading whitespace is skipped | `nil` |
| A number `n` | `n` bytes | `nil`. `0` asks "is there more", and if there is, `""` |

**An unknown format is refused.** A value that is not a format is refused too.

```lua nilu
print(select(2, pcall(io.read, "q")))
print(select(2, pcall(io.read, {})))
```
```output
bad argument #1 to 'read' (invalid format)
bad argument #1 to 'read' (string expected, got table)
```

`#1` is **the position of that argument**. With `f.read(f, "q")` it would be `#2`.

```lua nilu
local first = io.read()
local rest = io.read("a")
print(first, rest)
```
```stdin
ab
cd
```
```output
ab	cd

```

Passing several formats at once returns that many values. **The first format that could not be read becomes `nil`,
and those after it are not tried.**

```lua nilu
print(io.read("l", "l", "l"))
```
```stdin
ab
cd
```
```output
ab	cd	nil
```

```lua nilu
print(io.read("n"), io.read("l"))
```
```stdin
 12.5e1 rest
```
```output
125.0	 rest
```

`"n"` stops right after the number, and the remaining `" rest"` goes to the next read.

When standard input is the program, with `nilu -`, **the program has already read standard input to the end**, so
`io.read()` is `nil`. Lua does the same.

`os.clock` and `os.time` return a different number every call, so no value can be shown here.
Only the type, and that the clock does not go backwards, can be confirmed.

```lua nilu
local a = os.clock()
local b = os.clock()
print(type(a), b >= a, type(os.time()))
```
```output
number	true	number
```

`os.exit` **exits on the spot**. What was written with `io.write` up to then is flushed.
If the second argument is `true`, the state is closed before exiting.

```sh nilu-cli
nilu -e 'io.write("before\n") os.exit(3)'
```
```output
before
```

This command's exit status is 3 (`manual-check` looks only at standard output.
The exit status is watched by `os.exit sets the status and flushes what was written` in `zig build cli-test`).

**What is not there yet is gathered in [13.2](13-differences-from-lua.md#132-what-is-not-there-yet)**.
The table in 13.2 is the one `zig build manual-check` runs line by line to confirm, so
**the list is there and only there**.

### 11.4.1. Files

**`io.open` opens a file**. What comes back is
a **`userdata`**, and its inside cannot be seen. What can be done with it is seven things: `read`, `write`, `lines`, `close`, `flush`, `seek` and `setvbuf`.

**A method is written `f:read(…)`, as in Lua**. `__index` resolves it ([14.2](14-porting.md#142-the-second-program-a-class-with-methods)).

```lua nilu-source
local f = io.open("notes.txt", "w")
f:write("ひとつめ\n")
f:write("ふたつめ\n")
f:close()

for line in io.lines("notes.txt") do
  print(line)
end
```

**When it could not open, it returns three values** — `nil`, the reason and `errno`. It is not a failure.

```lua nilu
local f, why, code = io.open("/no/such/file", "r")
print(f, why ~= nil, code ~= nil)
```
```output
nil	true	true
```

The third is `errno` (`2` in this environment). The value itself is the OS's to decide, so here
only **that three values come back** is confirmed.

**A wrong argument is refused** (which is different from not being able to open).

```lua nilu
print(select(2, pcall(io.open, {})))
print(select(2, pcall(io.open, "/dev/null", {})))
local z = "/dev/null" .. string.char(0) .. "x"
print(select(2, pcall(io.open, z)))
```
```output
bad argument #1 to 'open' (string expected, got table)
bad argument #2 to 'open' (string expected, got table)
bad argument #1 to 'open' (a path cannot hold a zero byte)
```

**A mode that is not a string is refused rather than silently ignored** — being silently ignored is worse
than a wordless refusal.
**Omitting the mode or passing `nil`** means `"r"` (the same as Lua).

⚠ **The third line's text is ours.** Lua does not refuse this; it **opens the path up to the zero byte**.
An environment variable's name (`os.getenv`) is truncated, and a path is refused — because opening a
file under a name the program did not pass costs more.

**`io.lines` alone raises a failure.** Starting a `for` on a file that cannot be opened has nowhere to go.
This borrows Lua's distinction as it is.

```lua nilu
local ok, why = pcall(function() for _ in io.lines("/no/such/file") do end end)
print(ok, string.sub(why, 1, 28))
```
```output
false	<manual>:1: cannot open file
```

**Using a closed file is refused** (a failure, not `nil`).

```lua nilu
local ok, why = pcall(function()
  local f = io.open("/dev/null", "r")
  f:close()
  return f:read("l")
end)
print(ok, why)
```
```output
false	<manual>:4: attempt to use a closed file
```

⚠ **What precedes the refusal is the position of the line that was refused.** The same shape as a library refusal
([8.1](08-failure.md#81-what-happens-on-a-failure)).

**The formats are the same as `io.read`'s** (`l`, `L`, `a`, `n`, a number). `f:write` **returns the file**, so
`f:write("a"):write("b")` can be written. When it could not write, it returns `nil` and the reason
(not a failure).

**`f.seek` moves the position.**

| Spelling | What it does |
|---|---|
| `f:seek()` | The current position. The same as `f:seek("cur", 0)` |
| `f:seek("set" [, n])` | To `n` bytes from the start (the default is `0`) |
| `f:seek("cur" [, n])` | Moves `n` bytes from the current position |
| `f:seek("end" [, n])` | `n` bytes from the end. `f:seek("end")` is the file's size |

What comes back is the position after the move.

```lua nilu
local f = io.open("seek.txt", "w")
f:write("0123456789\n")
f:close()
local g = io.open("seek.txt", "r")
print(g:seek())
print(g:read(4))
print(g:seek())
print(g:seek("end"))
print(g:seek("cur", -2))
g:close()
```
```output
0
0123
4
11
9
```

⚠ **A position is an integer**; a float with no integer value is refused, as in Lua
([2.3](02-values.md#23-numbers)).

```lua nilu
local f = io.stdout
print(select(2, pcall(f.seek, f, "set", 1e30)))
```
```output
bad argument #3 to 'seek' (number has no integer representation)
```

⚠ **`whence` must be a string.** `f:seek(1)` is a refusal.
Lua turns the number into a string and says `invalid option '1'`, but Nilu does not turn a number into a string
([2.4](02-values.md#24-strings)), so it names the type.

```lua nilu
local f = io.stdout
print(select(2, pcall(f.seek, f, 1)))
```
```output
bad argument #2 to 'seek' (string expected, got number)
```

**`f:flush()` and `f:setvbuf(mode [, size])` both return `true`.**
`mode` is `"no"`, `"full"` or `"line"`, and here too it is a string.

```lua nilu
local f = io.open("buf.txt", "w")
print(f:flush(), f:setvbuf("full", 512), f:setvbuf("line"))
f:close()
```
```output
true	true	true
```

⚠ **`flush` returning `true` is Lua 5.5's.** 5.4 returned the file
(so that `f:flush():write(x)` could be chained). Here 5.5 was measured and matched.

**`io.lines` closes the file once it has iterated to the end, or when the loop is left early**: it
answers the file as the fourth value, which the loop closes. **`f:lines()` does not close it.** This
too is the same as Lua; a file is closed by a `<close>` local too.

**`lines` takes formats**.
Given the same formats as `io.read`, **it reads with them every time**. A number format is **a count of bytes, not of lines**, so
`3` cuts into `1 2` / `\n3 ` / `4\n`.

```lua nilu
local f = io.open("nums.txt", "w")
f:write("1 2\n3 4\n")
f:close()

local g = io.open("nums.txt")
for a, b in g:lines("n", "n") do print(a, b) end
g:close()

for s in io.lines("nums.txt", 3) do io.write("[", s, "]") end
print()
```
```output
1	2
3	4
[1 2][
3 ][4
]
```

⚠ **The first argument of `io.lines` is a file name.** `io.lines("n")` tries to open a file
named `n` — to pass a format for the current input, it is `io.lines(nil, "n")`.
An awkward shape, but it is Lua's and it was not changed.

**Up to 250 formats.** More than that is refused. The argument number in the refusal is **always 252**,
whatever number was passed — this too is Lua as it is.

**Close the file after making an iterator, and the next call of the iterator is refused.**

```lua nilu
local f = io.open("one.txt", "w")
f:write("a\n")
f:close()
local g = io.open("one.txt")
local it = g:lines()
g:close()
print(select(2, pcall(it)))
```
```output
file is already closed
```

**This is a different text from `attempt to use a closed file`.** The former is "the file passed is closed",
this one is "the file it held was closed in the middle" — Lua has a separate text in `io_readline` too,
and it was borrowed from there.

**Closing is the program's job, but forgetting it leaks nothing.** The `nilu` command remembers the files
it opened and **closes them when it exits** (on the `os.exit` path too).
There is no mechanism that runs at collection (`__gc`), so **what is promised is the command's ledger**.

**`tostring(f)` is `file (0x…)`, and after closing it is `file (closed)`.** The type's name is `FILE*`, so
the refusal for a value that is not a file reads like `FILE* expected, got table`.

**This belongs to the command.** The core does not touch files, and the library holds only what a host could write,
so files sit where `print` and `io.write` do.
Whoever writes their own host **can write the same thing with `userdata`**
([12.6](12-embedding.md#126-giving-a-program-the-hosts-data-to-carry)).

### 11.4.2. The three standard files, and the current input and output

**`io.stdin`, `io.stdout` and `io.stderr` are files**.
They have the same metatable as what `io.open` returns, so the same seven functions can be used.

**Trying to close one returns `nil` and the reason** (not a failure).

```lua nilu
print(type(io.stdout), io.output() == io.stdout, io.input() == io.stdin)
print(io.stdout:close())
io.stdout:write("そのまま書けます\n")
```
```output
userdata	true	true
nil	cannot close standard file
そのまま書けます
```

**`io.input` and `io.output` hold the "current input and output".**

| Spelling | What it does |
|---|---|
| `io.output()` | Returns the current output. At first, `io.stdout` |
| `io.output(f)` | Makes `f` the output, and returns `f` |
| `io.output(name)` | Opens `name` with `"w"` and makes it the output. A failure if it cannot be opened |
| `io.input(…)` | The same, for the input. At first, `io.stdin` |
| `io.flush()` | Flushes the current output |

**`io.write` and `io.read` look at this pair.** They are not fixed to standard output and standard input.

```lua nilu
local f = io.open("out.txt", "w")
io.output(f)
io.write("ファイルへ\n")
io.output(io.stdout)
f:close()
for line in io.lines("out.txt") do print(line) end

local g = io.open("in.txt", "w")
g:write("ひとつめ\nふたつめ\n")
g:close()
io.input("in.txt")
print(io.read("l"), io.read("l"))
io.input(io.stdin)
```
```output
ファイルへ
ひとつめ	ふたつめ
```

⚠ **Once the current input or output has been closed, `io.write` and `io.read` refuse.**
They do not spill to standard output — that would be writing somewhere the program did not ask for.
The text is Lua's.

```lua nilu
local f = io.open("gone.txt", "w")
io.output(f)
f:close()
print(select(2, pcall(io.write, "x")))
io.output(io.stdout)
```
```output
default output file is closed
```

**`io.close()` and `io.lines()` use this pair when the argument is omitted.**
`io.close()` closes the current output, and `io.lines()` iterates over the current input.
**`io.lines()` does not close it when the iteration is done** — `io.lines(name)`, given a name, does close.
Both are the same as Lua.

```lua nilu
print(io.close())
```
```output
nil	cannot close standard file
```

In a fresh state the current output is `io.stdout`, so it cannot be closed and `nil` and the reason come back.

**`print` does not look at this pair.** `print` hands its line to the writer the `nilu` command gave, and that
always writes to standard output ([1.3](01-getting-started.md#13--print-writes-where-the-host-says)).
Lua is the same: `print` does not go through `io.output`.

**The pair lives in a table the `io` functions hold, and it is not a global.**
What a program can see is `io.input` and `io.output` only, and there is no other way to change it.

### 11.4.3. Asking whether a value is a file, and making a temporary file

**`io.type` answers the state of a value**.

| Given | Answer |
|---|---|
| An open file | `"file"` |
| A closed file | `"closed file"` |
| A value that is not a file | `nil` |
| Nothing | Refused |

```lua nilu
local f = io.open("t.txt", "w")
print(io.type(io.stdout), io.type(f))
f:close()
print(io.type(f))
print(io.type(nil), io.type(""), io.type(print))
print(select(2, pcall(io.type)))
```
```output
file	file
closed file
nil	nil	nil
bad argument #1 to 'type' (value expected)
```

⚠ **`io.type(nil)` is `nil`, not a refusal.** It refuses only **when nothing was passed**
— passing `nil` and passing nothing are told apart. This is the same as Lua's `luaL_checkany`.

**`io.tmpfile` makes a file with no name.**

```lua nilu
local f = io.tmpfile()
print(io.type(f), getmetatable(f) == getmetatable(io.stdout))
f:write("ひとつめ\n")
f:seek("set")
print(f:read("l"))
print(f:close())
```
```output
file	true
ひとつめ
true
```

It has the same metatable as what `io.open` returns, so **all seven functions can be used**.
**Where it is made cannot be known** — `tmpfile(3)` returns no name, and the file disappears when closed.
Forgotten, it is closed when the command exits ([11.4.1](#1141-files)).

### 11.4.4. Time and environment variables

**`os.getenv` returns an environment variable**.
**When it is absent, `nil`**, and not an error. `nil` and `""` are **different answers** —
the former is "not set", the latter is "set to empty".

```lua nilu-source
print(os.getenv("HOME"))
print(os.getenv("NILU_NO_SUCH_VAR"))
```

(This example changes with the environment, so it is not made into an example that is run to confirm.
`os.getenv tells unset from empty` in `zig build cli-test` sets a variable itself and looks.)

**`os.date` turns a time into a string.** The format is C's `strftime`'s.

| Spelling | What it does |
|---|---|
| `os.date()` | Now, as `"%c"` |
| `os.date(fmt)` | Now, as `fmt` |
| `os.date(fmt, t)` | `t` (seconds since 1970), as `fmt` |
| A leading `!` | **UTC** rather than local time |
| `"*t"`, `"!*t"` | A **table** rather than a string |

```lua nilu
print(os.date("!%Y-%m-%d %H:%M:%S", 0))
print(os.date("!%F %T", 86400 * 366))
```
```output
1970-01-01 00:00:00
1971-01-02 00:00:00
```

**Every example has the `!`.** Without it the answer changes with **the time zone of the machine it ran on**,
and it would not be an example that can be confirmed.

**The table has nine fields.**

```lua nilu
local d = os.date("!*t", 0)
print(d.year, d.month, d.day)
print(d.hour, d.min, d.sec)
print(d.wday, d.yday, d.isdst)
```
```output
1970	1	1
0	0	0
5	1	false
```

`month` is 1 to 12, `wday` has Sunday as 1, and `yday` starts at 1.
**Where C counts from 0, this language counts from 1** — the same as Lua.

**An unknown conversion specifier is refused.** What can be passed is only what is in Lua's C99 list.

```lua nilu
print(select(2, pcall(os.date, "%v")))
```
```output
bad argument #1 to 'date' (invalid conversion specifier '%v')
```

⚠ **The whole format is examined first.** `os.date("ok%v")` writes not even the `ok`.
This is because what happens in C when `strftime` is given an unknown specifier **is not defined**,
and what pays is the whole process.

**Given a table, `os.time` returns the time of that date.**

| Field | Required? |
|---|---|
| `year`, `month`, `day` | **Required** |
| `hour` | Omitted, **12** |
| `min`, `sec` | Omitted, `0` |
| `isdst` | Omitted, "unknown" |

⚠ **The table passed is rewritten.** The values `mktime` normalised are written back, and
`wday`, `yday` and `isdst` **are added even if they were not passed**.

```lua nilu
local t = {}
t.year = 2026
t.month = 13
t.day = 1
local answered = os.time(t)
print(t.year, t.month, t.day)
print(t.wday, t.yday, t.isdst)
print(answered ~= nil)
```
```output
2027	1	1
6	1	false
true
```

Month 13 has become January of the next year. **It is not a pure function**, but this is what makes
the round trip with `os.date("*t")` hold.

```lua nilu
print(os.time(os.date("*t", 86400)) == 86400)
print(os.time(os.date("*t", 0)) == 0)
```
```output
true
true
```

⚠ **A round trip with `!` depends on the machine's time zone.** `!*t` returns the fields in UTC, and
`os.time` **reads them as local time**, so the answer differs by the offset
— it closes only on a UTC machine. Lua is the same, **and that is why it is not an example here**.

**When a field is missing, not an integer, or out of range, it says which one.**

```lua nilu
local a = {}
print(select(2, pcall(os.time, a)))
a.year = 2026
a.month = 10
a.day = 1.5
print(select(2, pcall(os.time, a)))
a.day = 1
a.hour = 1e10
print(select(2, pcall(os.time, a)))
```
```output
field 'year' missing in date table
field 'day' is not an integer
field 'hour' is out-of-bound
```

**What `os.time` returns is an integer**, as in Lua.

### 11.4.5. Files by name, and other programs

**`os.remove` and `os.rename` answer `true`, or `nil`, the reason and errno** (as `io.open` does).
`os.tmpname` makes an empty file under that name, as Lua does on POSIX.
**`os.execute` and a file from `io.popen` answer an exit status the way Lua does**: `true` (or
`nil`), then `"exit"` and the code, or `"signal"` and the signal. Whatever the command wrote before is
written out first, so the order of the output is the order of the program.

```lua nilu
local name = os.tmpname()
local f = io.open(name, "w") f:write("x") f:close()
print(os.rename(name, name .. ".b"))
print(os.remove(name .. ".b"))
print(os.difftime(10, 4))
print(os.execute("exit 3"))
local p = io.popen("echo hi")
print(p:read("l"))
print(p:close())
```
```output
true
true
6.0
nil	exit	3
hi
true	exit	0
```

These start a process through the shell (`/bin/sh` on POSIX), so a script that runs them does what
that command does.

**`os.setlocale` never leaves the C locale.** A query, `"C"`, `"POSIX"` and `""` answer `"C"`; any
other locale answers `nil`, as Lua answers for one it cannot set. Lua's `""` adopts the
environment's locale; the command does not, so what `os.date` and string comparison answer does
not depend on where the program runs.

```lua nilu
print(os.setlocale(), os.setlocale(""), os.setlocale("ja_JP.UTF-8"), os.setlocale("C", "time"))
```
```output
C	C	nil	C
```

## 11.5. What it cannot do yet

| What it cannot do | Why |
|---|---|
| Stopping running code with `Ctrl-C` | No hook is installed, so the whole process exits (at the prompt's editor, `Ctrl-C` drops the line) |

There is no `-E`: the command reads no environment variable like `LUA_INIT`, so it would be a flag that
does nothing (the owner's answer).

What `nilu` can load is **text only**. A source with a `\0` in it is refused
(reading up to it and answering success would be worse).

## 11.6. Where `require` looks

The command gives the library a reader that reads files ([10.7](10-library.md#107-loading-code)).

**A module name becomes a path**: its dots become `/` and `.nilu` is added (`lib.vector` is `lib/vector.nilu`).
It is looked for **next to the file that is being loaded** when one is, then **next to the
script the command started** (the current directory with `-e` or the prompt).

```text
main.nilu          require("geometry")    -> geometry.nilu
sub/shapes.nilu    require("util")        -> sub/util.nilu, then util.nilu
anything           require("lib.vector")  -> lib/vector.nilu next to the asker, then next to main.nilu
```

The path where it was found is the module's key: it names the module in a failure
(`lib/vector.nilu:3: …`) and is where `package.loaded` keeps it, so two files called
`util.nilu` in two directories are two modules. When none is found, the reason lists every
path tried (`no file 'sub/util.nilu'; no file 'util.nilu'`).

**`dofile` and `loadfile` open the path as written**, from the current directory, as Lua's do.

The script the command started is not a module: a module that requires it by name loads it
once more, as Lua does. A `require` made after a module has finished loading (from inside one
of its functions, called later) looks next to the started script.

---

Next: [12. Embedding from C](12-embedding.md)
