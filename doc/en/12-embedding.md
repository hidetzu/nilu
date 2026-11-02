[← Contents](README.md)

# 12. Embedding from C

Only 2 files are needed.

| File | What it is |
|---|---|
| `nilu.h` | the declarations |
| `libnilu.a` | the static library |

```bash
cc -std=c99 myhost.c -I path/to/include path/to/libnilu.a -lm -o myhost
```

`-lm` is for the math functions (`log`, `exp`, `fmod`), which gcc needs.

That this alone works is confirmed every time by this repository's `zig build example`.
It compiles the hosts in `examples/` and runs them, against **the installed header and
library alone**, with `zig cc`.

Before choosing a state lifetime, read the [collection limits](09-gc.md).
Loaded function bodies remain until `nilu_close`, and collection runs only
between VM instructions. Repeated loading in a long-lived state therefore
retains memory; host-only allocation does not itself trigger collection. Load
once and reuse the function when possible. Recreating a state releases its
memory, but also loses its globals, closures and other values; the host must
restore what it needs. Userdata has no finalizer, so the host must explicitly
close external resources such as files and sockets.

Use a state from only one thread at a time. Different states may run on
different threads concurrently; simultaneous use of the same state is undefined.
The host must coordinate access, including access from callbacks. Synchronous
reentry from a native function or hook follows the existing call and hook rules;
it does not allow concurrent access from another thread. The public C constructor
chooses its allocator; it does not accept a host allocator. When using the internal
Zig constructor with a supplied allocator, that allocator must support concurrent
use if shared between threads. Host resources shared by callbacks need their own
synchronization.

Until 0.1.0 is released, compatibility of the API, ABI, language and command
is not guaranteed between development versions
([11.1](11-nilu-command.md#111-how-to-run-it)).

## 12.1. The shortest host

```c nilu-c
#include <stdio.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return 1 + 2", NULL) != NILU_OK) {
    printf("プログラムとして読めなかった\n");
    nilu_close(N);
    return 1;
  }
  if (nilu_call(N, 0, 1) != NILU_OK) {
    printf("走らせたら失敗した\n");
    nilu_close(N);
    return 1;
  }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
3
```

`nilu_new` makes the state, and `nilu_close` frees all of it.
The state owns the memory, so there is nothing the host frees individually.
`nilu_openlibs` opens every library; `nilu_openselectedlibs(N, NILU_LIB_BASE | NILU_LIB_STRING)`
opens only those named (`NILU_LIB_BASE`, `_PACKAGE`, `_COROUTINE`, `_DEBUG`, `_MATH`, `_STRING`,
`_TABLE`, `_UTF8`, with Lua 5.5's values), for a program that should have no more.
`nilu_newstate(f, ud)` makes a state whose memory comes from the host's `f`, in Lua's `lua_Alloc`
shape (`f(ud, NULL, 0, n)` allocates, `f(ud, p, old, 0)` frees, `f(ud, p, old, n)` reallocates,
NULL when it cannot); `nilu_close` gives every block back through it. Its memory must be aligned as
`malloc`'s.

**This example is actually compiled and run every time this manual is built** —
against the installed `nilu.h` and `libnilu.a` alone. So "these 2 are enough" is
a measurement and not a promise.

It prints `3` because it is printed with `%g`. Nilu's `tostring` gives `3` as well
([2.3](02-values.md#how-they-print)). The C side only prints in C's format, and
has nothing to do with Nilu's display rules.

## 12.2. The stack

Values are exchanged through the stack.

- Indices start **at 1**. `1` is the bottom, `2` is above it
- A negative index counts from the top. `-1` is the topmost
- **`0` names no slot**
- `nilu_gettop` is the depth, and `nilu_settop` sets the depth

This borrows Lua's convention as it is. The names are borrowed from Lua too, and
where something differs, it is written as a **difference in behaviour** without changing the name.

**A number crosses as a float or as an integer**, as in Lua's API. `nilu_pushnumber` pushes a float
and `nilu_pushinteger` an integer (`NiluInteger`, from `NILU_MININTEGER` to `NILU_MAXINTEGER`).
`nilu_tonumberx` reads either kind as a float; `nilu_tointegerx` reads an integer, or a float with an
integer value, and says through its last argument whether it could. `nilu_isinteger` is true for an
integer only.

## 12.3. Almost every function answers a status

```c
NiluStatus status = nilu_pushnumber(N, 1.5);
```

Where Lua returns `void` or a type, Nilu answers a `NiluStatus`.
That is so a failure is said with a value. This is the biggest difference between Nilu's API and Lua's.

| Status | When |
|---|---|
| `NILU_OK` | It went through |
| `NILU_ERR_SYNTAX` | The source could not be read as a program |
| `NILU_ERR_TYPE` | Something was done that cannot be done to that type |
| `NILU_ERR_RUNTIME` | A function returned failure |
| `NILU_ERR_CALL_DEPTH` | the call is too deep |
| `NILU_ERR_STACK` | The stack can grow no further. When the number of results asked of `nilu_call` and `nilu_pcall` would not fit, this refuses before the call |
| `NILU_ERR_MEMORY` | Could not allocate |
| `NILU_ERR_INTERRUPTED` | A hook stopped it |

**A status itself carries no sentence.** The words are in **the value the failure carries**,
and for the core's own failure it is the same one line as Lua's —
after a call has failed, read the top of the stack with `nilu_tostring`.
Running out of memory also leaves `not enough memory` pushed.

**A syntax error carries a sentence too**.
When `nilu_loadnamed` fails, the position goes into the out argument, and
**the sentence is on the top of the stack** — read it with `nilu_tostring(N, -1)`.
The shape is `<chunk name>:<line>:<column>: <words> near '<token>'`.
After a load has failed, that one value stays on the stack.

```c nilu-c
#include <stdio.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  NiluError where = {0, 0};

  if (nilu_loadstring(N, "local = 1", &where) != NILU_OK) {
    printf("%d 行 %d 桁\n", where.line, where.column);
  }

  nilu_close(N);
  return 0;
}
```
```output
1 行 7 桁
```

If `where.line` is 0, the position is not known.

## 12.4. Passing a function of the host's to a program

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int host_double(NiluState *N) {
  int ok = 0;
  double x;
  if (nilu_gettop(N) < 1) return NILU_FAIL;
  x = nilu_tonumberx(N, 1, &ok);
  if (!ok) return NILU_FAIL;
  if (nilu_pushnumber(N, x * 2) != NILU_OK) return NILU_FAIL;
  return 1;              /* 返す値の数 */
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_pushcfunction(N, host_double) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_setglobal(N, "double") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return double(21)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
42
```

With this, a program can write `double(21)`.

- The arguments are from `1` to `nilu_gettop(N)`. Nothing below them is visible
- What it returns is "the number of values it pushed". `0` is fine
- Failure is `NILU_FAIL`. To attach a reason, push the sentence and write `return nilu_error(N);` (Lua's `lua_error`)
- `nilu_namewhat(N)` answers how it was called (`"method"`, `"local"`, `"global"`, `"field"` and so on. Lua's `ar.namewhat`). When it was called as `t:f()`, saying the argument number without counting `self` gives the same refusal as Lua's library
- Checking the arguments is this function's job. `nilu_call` checks nothing

When called from a program, it sees **exactly the same thing** as when called from the host.
There is no way to know which side called it.

`print` is made this way too ([`cli/nilu.c`](../../cli/nilu.c)).

### Checking arguments

**The library's argument checks are there for a host's C function** (Lua's `luaL_check*`,
`luaL_opt*`, `luaL_argerror` and `luaL_typeerror`): `nilu_checkany`, `nilu_checktype`,
`nilu_checknumber`, `nilu_checkinteger`, `nilu_checklstring`, their `nilu_opt*` forms,
`nilu_argerror` and `nilu_typeerror`. A refusal reads as the library's: `bad argument #2 to 'twice'
(…)`, `calling 'm' on bad self (…)` for a method, the function named as the caller wrote it, else
`?`. A check cannot leave the C function, so it answers 0, or `NILU_FAIL` with the failure raised,
which the C function returns.

```c nilu-c
#include <stdio.h>
#include "nilu.h"

/* twice(text, count): a refusal reads as the library's would. */
static int twice(NiluState *N) {
  const char *text;
  long long count;
  if (nilu_checklstring(N, 1, &text, NULL) != 0) return NILU_FAIL;
  if (nilu_checkinteger(N, 2, &count) != 0) return NILU_FAIL;
  if (nilu_pushstring(N, text) != NILU_OK) return NILU_FAIL;
  return 1;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_pushcfunction(N, twice) != NILU_OK || nilu_setglobal(N, "twice") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadstring(N, "twice('a', 1.5)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_pcall(N, 0, 0, 0) == NILU_OK) { nilu_close(N); return 1; }
  printf("%s\n", nilu_tostring(N, -1));
  nilu_close(N);
  return 0;
}
```
```output
[string "twice('a', 1.5)"]:1: bad argument #2 to 'twice' (number has no integer representation)
```

### A function of the host's that holds state — a C closure

When you want a function to hold a value (a counter, an iterator), you can have
**the function itself hold it** instead of putting it in a global. The values pushed are folded into the function
with `nilu_pushcclosure`, and while it runs they are read and written with `nilu_getupvalue` / `nilu_setupvalue`.

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int tick(NiluState *N) {
  double n;
  if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;   /* 上位値 1 を積む */
  n = nilu_tonumberx(N, -1, NULL);
  nilu_settop(N, -2);
  if (nilu_pushnumber(N, n + 1) != NILU_OK) return NILU_FAIL;
  if (nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
  if (nilu_setupvalue(N, 1) != NILU_OK) return NILU_FAIL;   /* 先頭を上位値 1 に戻す */
  return 1;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_pushnumber(N, 0) != NILU_OK) { nilu_close(N); return 1; }                 /* 上位値になる値を先に積む */
  if (nilu_pushcclosure(N, tick, 1) != NILU_OK) { nilu_close(N); return 1; }         /* 1 つ畳み込む。積んだ値は消えてクロージャが残る */
  if (nilu_setglobal(N, "tick") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return tick() + tick() + tick()", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
6
```

- The upvalues are numbered from `1` in the order they were pushed. At most `NILU_MAXUPVALUES` (255)
- `nilu_pushcclosure(N, f, 0)` pushes the same value as `nilu_pushcfunction(N, f)`
- Reading or writing a number that does not exist is `NILU_ERR_TYPE`. **The stack does not move** (the value that failed to be written stays on top)
- Calling them when not running (on the host side, or inside an ordinary function) is also `NILU_ERR_TYPE`
- Two closures made from the same function are **different values**. `==` is false, and `tostring` differs too
- A closure nothing can reach any more is collected, and the values it holds live only while they are held

The pseudo-index corresponding to Lua's `lua_upvalueindex(i)` (a mechanism for naming an upvalue
directly from any API call) is **absent**. The 2 calls, read and write, stand in for it.

## 12.5. Stopping a program that does not stop

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int ticks = 0;

static int hook(NiluState *N) {
  (void)N;
  /* 3 回呼ばれたらあきらめる。本物のホストなら、時間や合図を見ます。 */
  return (++ticks >= 3) ? NILU_FAIL : NILU_OK;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  nilu_sethook(N, hook, 1000);   /* 1000 命令ごとに呼ぶ */

  if (nilu_loadstring(N, "while true do end", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 0) == NILU_ERR_INTERRUPTED) {
    printf("止めた\n");
  }

  nilu_close(N);
  return 0;
}
```
```output
止めた
```

**A program that never ends has been stopped by the host's hand.** When the hook stops it,
`nilu_call` answers `NILU_ERR_INTERRUPTED`. The program's `pcall` does not catch it, and
no message handler runs. What stays on the stack is `nil`. A C function in between cannot
stop it either: until the host's call returns, a `nilu_call` it makes runs nothing and
answers `NILU_ERR_INTERRUPTED`, and whatever it returns becomes the interruption. The host's
next call runs as usual.

**What the hook counts is Nilu VM instructions only.** When a C function the host wrote
does not return, the hook is not called either. That function is the host's, so
the responsibility for stopping it is the host's too.

The hook starts with an empty temporary stack window; it cannot access the suspended
VM registers or its caller's slots. Values pushed in that window are discarded when
the callback returns, whether it continues execution or interrupts it.

The callback may run this state's VM again: it pushes or loads a function in its
window and calls it with `nilu_call` or `nilu_pcall`. The inner instructions are
observed by the same hook, and each of those callbacks starts with its own empty
window. When the inner call returns, the outer callback's window is as it was.
There is one count per state: the inner instructions consume it, and it is not
wound back when the inner call returns. When the hook stops an inner call, the
callback receives `NILU_ERR_INTERRUPTED` from it, and what happens to the outer
call is decided by the callback's own return value alone. A callback that calls
again at every stop runs out at the ordinary call limit ([8.2](08-failure.md#82-the-kinds-of-failure)),
and a `nilu_sethook` made inside a callback applies to the whole state at once.

## 12.5.1. Seeing where it failed

**`nilu_pcall` is the call a failure stops at, and a message handler can be attached to it**.
**`nilu_call` is the call that passes a failure on**. The handler of the
enclosing `nilu_pcall` runs where the failure happened, beyond the `nilu_call`. When a native function
receives a failure from `nilu_call`, pass it on with `return nilu_error(N);`.
The failure's value is on the top of the stack, and `nilu_error` carries it. **Returning a bare `NILU_FAIL` carries no value,
and the enclosing `pcall` receives `false nil`** (with `nilu_error(N)` it is `false` and the raised value.
That is how the library is written). When you want to go on after a failure, or want the value as it was raised,
use `nilu_pcall(N, nargs, nresults, 0)`. The library's `pcall` does the same.
It is the shape of `lua_pcall(L, nargs, nresults, msgh)`; `msgh` is a stack index, and **`0` is no handler**.

Relaying a failure with `nilu_error` preserves its original status, including
Type. A new raise is Runtime even when its value or message has the same content.
C-stack moves and copies retain the failure's origin; newly constructed or
converted values and values stored in and read back from a table do not.
Protected capture ends propagation: reraising its captured value later creates
a new Runtime failure. Interruption remains uncaught and carries nil.


```c
NiluStatus nilu_pcall(NiluState *N, int nargs, int nresults, int msgh);
```

**What the handler is for is "when it runs"** — **at the frame that failed, before anything unwinds**.
So inside the handler, `nilu_where(N, 1, &where)` can walk **the chain of frames that were standing
at the time of the failure**. `2` is its caller, `3` is the one above that. For a native function's frame,
`"[C]"` and line 0 are answered, and `NULL` means only "that level does not exist".

**After `nilu_call` has returned, this cannot be obtained.** What is left after it returns is
**only the failing frame's own position** (`nilu_where(N, 0, …)`). If you want a traceback,
build it inside the handler — that is the reason this function exists.

A chunk-name pointer returned by `nilu_where` remains valid until the next call
begins execution on the same state, or the state is closed. Repeated location
queries do not invalidate earlier names. A negative level returns NULL and clears
the coordinates to {0,0}; the output pointer may be NULL. Runtime column is always
0. If the line cannot fit a C int, the chunk name is still returned with {0,0}.

To write what each level's function is, as Lua's traceback does, two calls count levels the same way:

```c
const char *nilu_callername(NiluState *N, int level, const char **namewhat);
int nilu_linedefined(NiluState *N, int level);
```

`nilu_callername` answers the name the function at that level was called by (`"inner"`), and puts its
kind in `*namewhat` as `nilu_namewhat` words it (`"upvalue"`); with no name it answers `NULL` and `""`.
`nilu_linedefined` answers the line of the function's `function`, `0` for a chunk and `-1` for a native
function or a level with none. The `nilu` command builds its traceback from these
([11.3](11-nilu-command.md#113-how-a-failure-is-written)).

```c nilu-c
#include <stdio.h>
#include <string.h>
#include "nilu.h"

/* 失敗した時点の鎖を書き出すハンドラ。1 つ返すのが約束です。 */
static int show_the_chain(NiluState *N) {
  NiluError w;
  int level;
  for (level = 1; level <= 3; level++) {
    const char *name = nilu_where(N, level, &w);
    if (name == NULL) break;
    printf("  level %d: %s:%d\n", level, name, w.line);
  }
  if (nilu_pushstring(N, "handled") != NILU_OK) return NILU_FAIL;
  return 1;
}

int main(void) {
  const char *source =
      "global *\n"
      "local function c() local v = 1 + nil return v end\n"
      "local function b() local v = c() return v end\n"
      "local v = b() return v\n";
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return 1;

  if (nilu_pushcfunction(N, show_the_chain) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadnamed(N, source, "=example", &where) != NILU_OK) { nilu_close(N); return 1; }
  /* ハンドラは添字 1、関数はその上。ハンドラは関数より下に置きます。 */
  if (nilu_pcall(N, 0, 0, 1) == NILU_OK) { nilu_close(N); return 1; }
  printf("answered: %s\n", nilu_tostring(N, -1));

  nilu_close(N);
  return 0;
}
```
```output
  level 1: example:2
  level 2: example:3
  level 3: example:4
answered: handled
```

**The handler receives 1 argument (the value the failure carries, or `nil` when there is none) and answers 1 value.**
The value it answered **replaces** the value the failure carries.

**When the handler itself fails, it is `error in error handling`.** And
**the handler does not run for its own failure** — the nesting stops at 1 level.

⚠ **Put the handler below the function.** At the same position as the function or above it, it is refused (it aborts) —
that is the place the called function's registers use, and the judgement is that **refusing is better than
answering from a slot that was overwritten**. Lua does not check this.

Ordinary execution allows 200 simultaneously live script and native frames.
While a failure handler runs, its calls share a total limit of 220, including
the handler. Nested protected calls and host reentry do not add more room.
Script tail replacement adds no frame; a native tail call retains its script
caller. After handling, the ordinary limit applies again.

A successful handler keeps the original status and location, replacing only the
value. If the handler fails, including depth/stack exhaustion or internal memory
failure, the result is `NILU_ERR_RUNTIME` with `error in error handling` and the
original location. Interruption remains `NILU_ERR_INTERRUPTED` with `nil`.
An initial internal memory failure still skips the handler.

## 12.6. Giving a program the host's data to carry

**A `userdata` is a sequence of bytes the state owns.** The host writes it, and a program can only carry it
around — unless given a metatable, it cannot reach the contents.

```c nilu-c
#include <stdio.h>
#include <string.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  void *block = NULL;

  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_newuserdata(N, sizeof(double), &block) != NILU_OK) { nilu_close(N); return 1; }
  *(double *)block = 2.5;
  if (nilu_setglobal(N, "handle") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return type(handle)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%s\n", nilu_tostring(N, -1));
  if (nilu_settop(N, 0) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_getglobal(N, "handle") != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", *(double *)nilu_touserdata(N, -1));

  nilu_close(N);
  return 0;
}
```
```output
userdata
2.5
```

**The bytes are filled with 0, and aligned to a boundary that any type can be written at.**
You may assign a `double` or a pointer into it as it is.

**What it owns is its own bytes only.** There is no finaliser here — there is no `__gc`,
and nothing runs when it is collected. If it holds a file or a socket, **closing it is the host's job**.
A metatable with `__gc` is **refused** rather than silently ignored (`NILU_ERR_TYPE`).

**Given a metatable, it answers the way a table does.** `__index`, `__newindex`,
`__len`, `__call`, the operators, `__name` — each is the same as for a table.
**The exception is `__eq`.** `==` calls `__eq` only when both are tables, so
`==` between two `userdata` answers only whether they are the same one (Lua calls it when both are full userdata too —
[13.1](13-differences-from-lua.md#131-where-it-differs)).
Without one, a program can do nothing with it.

```lua nilu
-- ホストが handle を登録していないので、ここでは nil です
print(type(handle))
```
```output
nil
```

**To tell whether a `userdata` is your own**, keep the metatable in an upvalue of your own C closure
([12.4](#124-passing-a-function-of-the-hosts-to-a-program)), read it with `nilu_getmetatable` and
compare with `nilu_rawequal`. The typing Lua does with the registry is done with an upvalue here.

**A userdata can carry values of the program's** (Lua's user values): `nilu_newuserdatauv(N, size,
nuvalue, &block)` gives it `nuvalue` of them, nil at first; `nilu_getiuservalue(N, idx, n)` pushes the
n-th and answers its type, `NILU_TNONE` (pushing nil) when there is none; `nilu_setiuservalue(N, idx,
n)` pops into it and answers 0 when there is none. They live as long as the userdata does.

**The registry keeps a value for the host** (Lua's `luaL_ref`): `nilu_ref(N)` pops the value and
answers a reference to it, `NILU_REFNIL` for nil and `NILU_NOREF` without memory; `nilu_getref(N, ref)`
pushes it back; `nilu_unref(N, ref)` lets it go. What a reference holds is not collected. There is no
pseudo-index: the registry is reached only through references.

## 12.6.1. Running a coroutine

**A coroutine is a value on the stack**, as in the program ([10.8](10-library.md#108-coroutines)).
`nilu_newthread` replaces the function on top with a thread that will run it. `nilu_resume(N, idx,
nargs, &nresults)` resumes the thread at `idx` with the top `nargs` values, and pushes what it gave:
`NILU_OK` when it returned, `NILU_YIELD` when it yielded, or the failure's status with the failure's value.
A C function suspends the coroutine that called it with `return nilu_yield(N, n)`, giving the top `n` values.

```c nilu-c
#include <stdio.h>
#include "nilu.h"

/* Hands the program's question to the host by suspending the coroutine. */
static int ask(NiluState *N) {
  return nilu_yield(N, nilu_gettop(N));
}

int main(void) {
  int count = 0;
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_pushcfunction(N, ask) != NILU_OK || nilu_setglobal(N, "ask") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadstring(N, "local name = ask('name?') return 'hello, ' .. name", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_newthread(N) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_resume(N, 1, 0, &count) != NILU_YIELD || count != 1) { nilu_close(N); return 1; }
  printf("asked: %s\n", nilu_tostring(N, -1));
  nilu_pop(N, 1);
  if (nilu_pushstring(N, "Nilu") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_resume(N, 1, 1, &count) != NILU_OK || count != 1) { nilu_close(N); return 1; }
  printf("answered: %s (%d)\n", nilu_tostring(N, -1), nilu_threadstatus(N, 1));
  nilu_close(N);
  return 0;
}
```
```output
asked: name?
answered: hello, Nilu (3)
```

`nilu_threadstatus` answers `NILU_THREAD_SUSPENDED`, `_RUNNING`, `_NORMAL` or `_DEAD`;
`nilu_pushrunning`, `nilu_isyieldable` and `nilu_closethread` are what `coroutine.running`,
`isyieldable` and `close` are written with. A `yield` under `nilu_call` or `nilu_pcall`, a message
handler or a hook is refused with `attempt to yield across a C-call boundary`, as `nilu_error` refuses.

**`nilu_pcallk(N, nargs, nresults, msgh, ctx, k)` is a protected call a yield may pass**, Lua's
`lua_pcallk`. When the callee yields, it answers `NILU_YIELD` and the C function returns
`nilu_yield(N, 0)`; when the callee finishes after the resume, `k(N, status, ctx)` runs in the C
function's place with the status `nilu_pcall` would have answered and the stack it would have left, and
answers as the C function would have. A C function that called `nilu_yield`, or got `NILU_YIELD` from
`nilu_pcallk`, and returns anything but `nilu_yield`'s answer misuses the API, and aborts with a message
naming `nilu_yield`, as other misuse does. The library's `pcall` and `xpcall` are written this way.

## 12.6.2. Reading where a program is

`nilu_getinfo(N, thread, level, what, &ar)` is Lua's `lua_getstack` and `lua_getinfo` in one: it
fills a `NiluDebug` about the function at `level` of the thread at stack index `thread` (0 for the
running one), counted as `nilu_where` counts, level 0 being the C function asking; or, when `what`
starts with `>`, about the function on top, which it pops. The letters are Lua's (`S l n u t r f L`);
`f` pushes the function and `L` a table of the lines with code. It answers 1, 0 past the last
level, or -1 for a letter it does not know. `debug.getinfo` and `debug.traceback` are written with
it (10.9).

## 12.7. Things to be careful of

- **A loaded function is not freed.** A host that loads repeatedly keeps growing until it
  closes the state ([9.3](09-gc.md#93-when-it-happens))
- **A string's pointer is valid only while that value is on the stack.**
  After it is dropped, it may have been collected
- `nilu_tolstring` **converts a number into a string in place**. Calling it meaning only to read
  changes what `nilu_type` answers. This is the same hazard as Lua's `lua_tolstring`
- `nilu_tolstring` answers `NULL` for `nil`, a boolean, a table and a function.
  What spells those is the library's `tostring`
- **An operation that allocates can fail.** Look at the status
- **To give a chunk a name, use `nilu_loadnamed`.** Lua's convention — `"=name"`, `"@file"`, and anything else (shown as `[string "…"]`)
  — and it is used for `error("s")`'s `name:line: s` and for `nilu_where`'s answer.
  `nilu_loadstring` uses the source itself as the name (the same as `luaL_loadstring`)
- **The position of a failed call is obtained with `nilu_where(N, 0, &where)`** (the chunk name and the line. When there is none,
  `NULL` and 0). This is what the `nilu` command writes as `file:3:`. The sentence a failure carries
  has the same chunk name and line at its head. Each thread has its own: a failure caught inside a
  coroutine is not seen from the thread that resumed it, and `nilu_resume` counts as a call, so after
  a resume it names where the coroutine failed, or nothing
- **`math.random` gives the same sequence every time unless the host seeds it.** The core has no clock, so
  a freshly opened state is the same as after `math.randomseed(0)`. That suits a test, and
  is a surprise in a game. To make it differ every time as Lua does, call `math.randomseed` through the API
  at startup, as the `nilu` command does (`seed_random` in [`cli/nilu.c`](../../cli/nilu.c))
- **`require`, `dofile` and `loadfile` need a reader the host gives.** Push a C function (or a C closure,
  to carry the host's data) and call `nilu_setreader`. The library calls it as `reader(name, from, kind)`,
  where `kind` is `"module"` or `"file"` and `from` is the key of the file being loaded, or nil, and
  takes `key, text` or `nil, reason` back ([10.7](10-library.md#107-loading-code), the header). The
  `nilu` command's reader is `host_reader` in [`cli/nilu.c`](../../cli/nilu.c)
- **`nilu_setenv` gives a loaded chunk its own `_ENV`**, as `load`'s fourth argument does
- **`print` needs a writer the host gives.** Push a C function and call `nilu_setwriter`; `print`
  calls it once per call with the whole line, newline included ([1.3](01-getting-started.md#13--print-writes-where-the-host-says)).
  Without one, `print` fails with `cannot print: no writer was given to this state`. `warn` calls the
  same writer with a second argument, `"warning"` (10.1), and does nothing without one

## 12.8. What is absent

| What is absent | In Lua |
|---|---|
| Pseudo-indices | `LUA_REGISTRYINDEX`, `lua_upvalueindex` (the registry is reached through `nilu_ref`, a C closure's values through `nilu_getupvalue`) |
| Calls that read a frame's locals | `lua_getlocal`, `lua_setlocal` (`lua_getinfo` and `lua_getstack` are `nilu_getinfo` and its `NiluDebug`, 12.6.2. `lua_sethook` is borrowed. `lua_getupvalue` and `lua_setupvalue` lend their names, but name the values of the C closure that is running, by number ([13.1](13-differences-from-lua.md#131-where-it-differs)). Of `lua_getinfo`, `ar.name` is covered by `nilu_calledas`, `ar.namewhat` by `nilu_namewhat`, and `luaL_where` by `nilu_where`) |
| Suspending inside the host's own callbacks other than a protected call | `lua_callk`, `lua_yieldk` (a C function yields only as it returns; `nilu_pcallk` is there) |
| Loading with a length | `luaL_loadbuffer` (`nilu_loadstring` takes `\0`-terminated text only) |
| A C call that spells any value | `luaL_tolstring` (`nilu_tolstring` answers NULL for nil, a boolean, a table and a function) |

The `nilu` command works around `luaL_loadbuffer` and `luaL_tolstring`: it calls the global `tostring` to spell a value (a program that replaces `tostring` changes what `print` writes), and it refuses a source that contains `\0`.
**This table is the list of what the C API does not have.** [13.2](13-differences-from-lua.md#132-what-is-not-there-yet) points here.
The operations that move a slot (`lua_insert`, `lua_rotate`, `lua_remove`, `lua_replace`) are there (`nilu_rotate`, `nilu_copy` and
3 macros).

---

Next: [13. Differences from Lua](13-differences-from-lua.md)
