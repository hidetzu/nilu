[![Actions Status: checks](https://github.com/hidetzu/nilu/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/hidetzu/nilu/actions/workflows/check.yml?query=branch%3Amain)

# Nilu

Nilu is a small scripting language for embedding in C applications. Use scripts
to describe configuration and application behavior while the host controls what
they can access. Nilu is written in Zig and takes its syntax from Lua 5.5.

**In development:** the language is complete against its manual and its C
cases, and `zig build dist` builds the release artifacts; no release is published yet.

## Features

- Functions, closures and tables with familiar Lua-style syntax.
- Integers and floating-point numbers as in Lua, and explicit conversions between numbers and strings.
- A C stack API for exchanging values and supplying functions from the host.
- An instruction hook so the host can stop a running script.

## A taste of Nilu

A script can calculate settings for its host:

```lua nilu
local function pixels(units)
  return units * 16
end

local settings = {
  title = "My app",
  width = pixels(50),
  height = pixels(30)
}
print(settings.title, settings.width, settings.height)
```
```output
My app	800	480
```

`zig build manual-check` runs this example, as it runs every example of the manual.

Nilu follows many of Lua's conventions, with some deliberate differences. For
example, `"1" + 1` is a type error: a string never becomes a number by itself. See
[Differences from Lua](doc/en/13-differences-from-lua.md) for the full comparison.

## What it suits, and what it does not

It suits a host that keeps control: configuration, rules and behaviour that a C
program loads once and calls many times, under its own allocator and an
instruction budget. A state that loads once and calls repeatedly holds steady
memory, and every refusal of the host's allocator comes back as a status.

It does not suit:

- **Running code you do not trust as if it were contained.** Nilu is not a sandbox. A
  single library call, pattern matching above all, runs without the hook, and its time
  has no bound ([12.5](doc/en/12-embedding.md#125-stopping-a-program-that-does-not-stop)).
- **One state shared by threads.** A state is used from one thread at a time.
- **A long-lived state that loads source again and again.** Every loaded function stays
  until the state closes; reloading the same text keeps another copy
  ([9.3](doc/en/09-gc.md#93-when-it-happens)).
- **Programs that make few, large objects in a tight memory limit.** A collection is started
  by the number of objects, not their size.

## Build from source

You need Zig **0.17.0** to build, and Node.js to run the verification tools.
This line is where the version is written for people; [.mise.toml](.mise.toml)
pins the same one for `mise`. When the toolchain moves, change both.
From a checkout, `zig build` installs the
command, the library and the header under `zig-out/`:

```sh
zig build
zig-out/bin/nilu -e 'print(1 + 2)'
```

The complete verification gate runs every check, including the carried C suites
and every example of both manuals:

```sh
zig build check --summary all
```

CI runs this same command on every pull request and on every push to `main`:
the source tests, the carried C suite under `zig cc` and the native C compiler,
the command cases, every example of both manuals, the embedding example and the
complete document check. `zig build stage-check` is the faster subset for
development; passing it says nothing about the rest.

`zig build dist` builds the release: the command, the library, the header and
the licence for five targets under `zig-out/dist/`, with a `SHA256SUMS` over
them. Only the host's own binary is run there; the others are built. `dist` is
not part of `check`, and CI does not run it.

CI also runs each release target on a runner of that target:

| Target | What CI runs there |
|---|---|
| x86_64-linux-gnu, aarch64-linux-gnu | `check` |
| x86_64-macos, aarch64-macos | `check`; three command cases that need Linux (`/dev/full`, `setrlimit(RLIMIT_AS)`) are announced as not run |
| x86_64-windows-gnu | the source tests only. **Not verified:** a C host linking the library, and the command cases. The command runs; the lines it writes to standard output end in `\r\n` |

## Embedding in C

The host creates a `NiluState`, provides its own C functions and exchanges values
through the stack API. Each state owns its values and is released with
`nilu_close`.

The [embedding guide](doc/en/12-embedding.md) describes the interface: loading
scripts, calling functions and passing host data. A host links `zig-out/lib/libnilu.a`
and includes `zig-out/include/nilu.h`. [`examples/`](examples/) holds small whole hosts —
the shortest one, functions in both directions, a coroutine the host drives, and a host that runs rules a script defines under its own allocator and an instruction budget — and
`zig build example` builds each against the installed files and compares what it prints.

The [embedding guide's opening](doc/en/12-embedding.md) gives how long a state
should live, and the thread rule. What a version promises about compatibility is
in [11.1](doc/en/11-nilu-command.md#111-how-to-run-it).

## Documentation

- Language manual: [English](doc/en/README.md) · [日本語](doc/ja/README.md)
- Embedding guide: [English](doc/en/12-embedding.md) · [日本語](doc/ja/12-embedding.md)

## Development

Start with [Contributing](CONTRIBUTING.md) for setup, tests and pull requests.
The repository's issues track progress and remaining work. Contributors can find
build instructions and verification details in [Development checks](tools/README.md).

## License

[MIT](LICENSE)
