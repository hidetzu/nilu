# 0003 — The core touches nothing outside itself

**Status:** accepted. The owner chose `print` in the library writing through a writer the host
gives, loading through a reader the host gives, and `package.preload`.

## Context

An embedded language runs inside someone else's process. That process owns standard output,
the files, the clock, the environment and the decision to exit. A language that reaches for
any of them on its own makes choices that belong to the host: where output goes, which files
a script may open, whether time is real.

Lua's standard library includes `print`, `io` and `os`, and `require` searches
`package.path` and opens files itself. Lua compares strings by the C locale (`strcoll`), its
string library classifies characters through the C library, and its math library seeds the
random generator from the clock and an address when it is opened.

## Decision

- **The core — the compiler, the VM, the collector and the standard library — does no file
  I/O, reads no clock, reads no environment and writes nothing to standard output.** It returns
  values and statuses, and the host decides what to do with them. When a host breaks a
  precondition ([0002](0002-a-closed-c-stack-api.md)), the process stops and the abort writes
  to standard error.
- **What the core needs from outside, the host passes in.** A host that wants a script to see
  something gives it a function or a value through the C API.
- **`print` is in the library, and writes through a writer the host gives** with
  `nilu_setwriter`. It calls the global `tostring` on each argument, joins them with tabs,
  adds a newline and hands the line to the writer as one string, once per call; a refusal
  writes nothing. Without a writer, `print` fails: `cannot print: no writer was given to this
  state`.
- **Code is loaded through a reader the host gives** with `nilu_setreader`. `load` compiles a
  string and needs no host. `require`, `dofile` and `loadfile` call the reader as
  `reader(name, from, kind)` — `kind` is `"module"` or `"file"`, `from` is the key of the file
  being loaded, or nil — and it answers `key, text`, or `nil, reason`. The key names the code:
  its chunk name is `"@" .. key`, and `package.loaded` keeps a module under its key, so two
  files of one name in two places are two modules.
- **The rules a program sees are the library's, the same in every host.** A name already in
  `package.loaded`, such as a standard table, is answered without the reader. A function in
  `package.preload` under the name is called as `loader(name, ":preload:")` before the reader is
  asked, so a host or a program can supply a module without a text. A cycle is refused, naming
  its links: `cannot load module 'a' while it is loading (a.nilu -> b.nilu -> a.nilu)`. Without
  a module: `cannot find module 'util': <reason>`. Without a reader: `cannot load module 'util':
  no reader was given to this state` (`file` for `dofile` and `loadfile`).
- **`io` and `os` are the host's.** The embedded library never defines them.
- **The `nilu` command is a host like any other.** It is a C program that uses `include/nilu.h`
  and nothing else. It gives a writer that writes to standard output and a reader that reads
  files — a module name has its dots made `/` and `.nilu` added, and is looked for next to the
  file being loaded, then next to the script the command started — and it brings its own `io`
  and `os` ([11.4](../../doc/en/11-nilu-command.md#114-io-and-os)).

## Why

- The process is the host's. A library that prints, or opens a file, has decided something on
  the host's behalf that the host may need to decide differently — a game, an editor and a
  server want output to go to three different places, and may load code from a file, an
  archive or a buffer.
- Every kind of user meets `print` first, and its behaviour is specified once; one
  implementation in the library keeps it the same in every host, while where the line goes
  stays the host's. A reader rather than a list of paths does the same for loading code.
- The `from` a nested `require` sees comes from the library's own chain of keys being loaded,
  because `nilu_where` gives a display name that may be truncated.
- `io` and `os` differ by host far more — a sandbox, a tool — so they stay the host's to open.
- A core with no outside dependencies can be measured: what it answers depends on the source
  and the calls, not on the machine it runs on. (An object's identity, as `tostring` shows it,
  still changes from run to run — [13.5](../../doc/en/13-differences-from-lua.md#135-where-lua-says-nothing).)
- Making the command an ordinary host is a test of the C API. If the command can write `io` and
  `os` through `include/nilu.h` alone, so can any host.

## Consequences

- C API: `nilu_setwriter`, `nilu_getwriter`, `nilu_setreader`, `nilu_getreader` and
  `nilu_setenv`, which replaces a loaded chunk's `_ENV`. The reader and the writer are
  collector roots, and a script cannot change them.
- The manual's examples are checked against the same `print` the command runs: the manual's
  harness gives a writer that keeps the lines.
- `package.path`, `package.cpath`, `package.config`, `package.searchers`,
  `package.searchpath` and `package.loadlib` are not there; the reader replaces them.
- A `require` made after a module has finished loading, from one of its functions called
  later, has no `from`; the command then looks next to the started script.
- Where Lua's answer depends on the C library or the clock, Nilu's differs, and
  [13.1](../../doc/en/13-differences-from-lua.md#131-where-it-differs) names each one as
  differing because a mechanism is absent:
  - `string.upper`, `string.lower` and the pattern classes know ASCII only, and strings
    compare byte by byte, because there is no locale;
  - a new state's `math.random` sequence is fixed, and `table.sort`'s pivot does not vary,
    because there is no clock.
- The `nilu` command seeds `math.random` when it starts and reads the clock and the environment
  for `os`, because it is the host.

## What would reverse it

- A host that cannot provide what the core needs through the C API — for instance, a clock the
  core must read during a single instruction. That would be an argument for a hook the host
  supplies, not for the core reading the clock itself.
- A need for programs to choose search paths themselves would bring back `package.path`-like
  settings, read by the command's reader.
