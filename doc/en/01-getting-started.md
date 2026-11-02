[← Contents](README.md)

# 1. Getting started

Nilu is a small scripting language for embedding. This is what it can do.

- The values are six kinds — `nil`, a boolean, a number, a string, a table, a function — plus `userdata`, which the host passes in
- The statements are `local`, `global`, assignment, `if` (`elseif`), `while`, `repeat`, the numeric `for`, the generic `for`, `do … end`, `break`, `goto`, `return`, and `function f() … end`
- A comment runs from `--` to the end of the line, or is `--[[ … ]]` ([15.2](15-grammar.md#152-lexical-conventions))
- A function is a value and can see the variables around it (a closure)
- A table can be given a metatable, which answers for indexing and for operators
- The standard library is the tables `string`, `table`, `math` and `utf8`, and a few basic functions (the `nilu` command also has `io` and `os`)
- A host program calls it through the C API

It is built with Lua 5.5 as its primary source, so if you know Lua, most of this reads as is.
The differences are collected in [13. Differences from Lua](13-differences-from-lua.md).

## 1.1. Getting it

All you need is [Zig](https://ziglang.org). Use the version written in
[`.mise.toml`](../../.mise.toml).

```bash
zig build
```

This produces three things.

| Produced | What it is |
|---|---|
| `zig-out/bin/nilu` | the command |
| `zig-out/include/nilu.h` | the header a C host reads |
| `zig-out/lib/libnilu.a` | the library a C host links |

Only the last two are needed to embed it from C
([12. Embedding from C](12-embedding.md)).

The examples below use `nilu` as the command name. From this checkout, replace
it with `./zig-out/bin/nilu` (on Windows, `zig-out/bin/nilu.exe`), or add
`zig-out/bin` to your PATH. Save the first script below as `hello.nilu` before
running the file example. Node.js is also needed for the repository verification
commands such as `zig build check`.

A program can be split into files with `require`; the `nilu` command looks for
a module next to the file that asks ([11.6](11-nilu-command.md#116-where-require-looks)). See
[the differences from Lua](13-differences-from-lua.md) before porting a project.

## 1.2. The first line

```lua nilu
print("こんにちは")
```
```output
こんにちは
```

You can write it in a file and pass that, pass it directly with `-e`, or feed it from standard input.

```bash
nilu hello.nilu
nilu -e 'print("こんにちは")'
echo 'print("こんにちは")' | nilu -
```

Typing `nilu` with no arguments gives you a prompt.

```text
$ nilu
nilu 0.1.0-dev.1
> 1 + 2
3.0
> print("こんにちは")
こんにちは
>
```

At the prompt, a line that is only an expression becomes its own answer. That is because the
input is first read as `return <line>`, the same device as Lua's `lua` command.
The details are in [11. The `nilu` command](11-nilu-command.md).

## 1.3. ⚠ `print` writes where the host says

**`print` is in the library, but where its line goes is the host's.**

Nilu's core touches no standard output. `print` builds its line (each value through
`tostring`, tabs between, a newline) and hands it to a **writer** the host gives. The `nilu`
command gives one that writes to standard output.

That means **a different host you wrote prints nothing until it gives a writer**: `print(…)`
there fails with `cannot print: no writer was given to this state`. Giving one takes two lines
(they are in [`cli/nilu.c`](../../cli/nilu.c) as is).

```c
nilu_pushcfunction(N, writer);
nilu_setwriter(N);
```

`io` and `os` are the host's own ([11.4](11-nilu-command.md#114-io-and-os)).
The core holds only functions that compute; what touches the outside is the host's.

Every example in this manual is run with the `nilu` command, so it uses `print`.

## 1.4. A number is an integer or a float

```lua nilu
print(1 + 2)
print(7 / 2)
print(7 // 2, 7.0 // 2)
print(1e15)
```
```output
3
3.5
3	3.0
1e+15
```

A number is an integer or a floating-point number (a float), as in Lua. `1 + 2` of two integers is
the integer `3`, and `/` always gives a float. A float with a whole value prints with `.0`, and a
numeral with an exponent, such as `1e15`, is a float.

Dividing by 0 with `/` is not a failure. It gives infinity. (An integer divided by 0 with `//` or `%`
is a runtime error: [5.2](05-expressions.md#52-arithmetic).)

```lua nilu
print(1 / 0)
print(-1 / 0)
print(0 / 0)
```
```output
inf
-inf
nan
```

Nilu always writes NaN as `nan`. `lua5.5` writes `0 / 0` as `-nan`
(it hands the sign bit straight to C's `printf`). This is an intended difference
([13. Differences from Lua](13-differences-from-lua.md)).

How numbers are written and how they print is in [2. Values and types](02-values.md).

## 1.5. ⚠ An expression is not a statement

```lua nilu-refused
1 + 2
```

This is not a program, because there is no statement in it. Write `return 1 + 2` or
`print(1 + 2)`.

This is the same rule as Lua's: only a function call can stand alone as a statement.
Only the prompt looks like an exception, and that is because the command adds a `return`;
the grammar is unchanged.

---

Next: [2. Values and types](02-values.md)
