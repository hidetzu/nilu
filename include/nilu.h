#ifndef NILU_H
#define NILU_H
/* The version: MAJOR.MINOR.PATCH, "-dev.N" between releases.
 * NILU_VERSION_NUM equals the release this build precedes. */
#define NILU_VERSION_MAJOR 0
#define NILU_VERSION_MINOR 1
#define NILU_VERSION_PATCH 0
#define NILU_VERSION_NUM (NILU_VERSION_MAJOR * 10000 + NILU_VERSION_MINOR * 100 + NILU_VERSION_PATCH)
#define NILU_VERSION "0.1.0-dev.1"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The whole recorded surface. The standard library (nilu_openlibs) is written against this
 * header alone. */
typedef struct NiluState NiluState;
/* Source line/byte-column coordinates. Runtime queries use column 0.
 * {0,0} means unknown/unrepresentable position. */
typedef struct { int line; int column; } NiluError;
typedef int (*NiluCFunction)(NiluState *N);
typedef int (*NiluHook)(NiluState *N);
#define NILU_FAIL (-1)
#define NILU_MAXUPVALUES 255
#define NILU_MULTRET (-1)
#define NILU_MAXDEPTH 1000000
#define NILU_OPEQ 0
#define NILU_OPLT 1
#define NILU_OPLE 2
/* Stable Nilu tags; these are not Lua type-tag numbers. */
typedef int NiluType;
#define NILU_TNONE (-1)
#define NILU_TNIL 0
#define NILU_TNUMBER 1
#define NILU_TFUNCTION 2
#define NILU_TBOOLEAN 3
#define NILU_TSTRING 4
#define NILU_TTABLE 5
#define NILU_TUSERDATA 6
#define NILU_TTHREAD 7
typedef enum {
    NILU_OK = 0,
    NILU_ERR_RUNTIME,
    NILU_ERR_SYNTAX,
    NILU_ERR_MEMORY,
    NILU_ERR_CALL_DEPTH,
    NILU_ERR_STACK,
    NILU_ERR_TYPE,
    NILU_ERR_INTERRUPTED,
    NILU_YIELD
} NiluStatus;

/* NULL means allocation failed. close(NULL) is allowed. */
NiluState *nilu_new(void);
/* A state whose memory comes from the host's f (Lua's lua_Alloc shape):
 * f(ud, NULL, 0, n) allocates n bytes, f(ud, p, old, 0) frees, and
 * f(ud, p, old, n) reallocates; NULL when it cannot. The memory must be
 * aligned as malloc's. NULL when the state itself could not be made. */
typedef void *(*NiluAlloc)(void *ud, void *ptr, size_t osize, size_t nsize);
NiluState *nilu_newstate(NiluAlloc f, void *ud);
void nilu_close(NiluState *N);

/* All other functions require a non-NULL state or abort naming the function.
 * Indices are 1-based or negative from the top of the current call window. */
int nilu_gettop(NiluState *N);
/* Absent/hidden slots (including index zero) return TNONE, distinct from nil.
 * No conversion, allocation or stack change; all function kinds are TFUNCTION. */
NiluType nilu_type(NiluState *N, int index);
/* Nonnegative sets depth; negative pops -index-1 slots. Growth fills with nil.
 * Popping below the visible bottom aborts. Failed growth leaves slots intact. */
NiluStatus nilu_settop(NiluState *N, int index);
NiluStatus nilu_pushnil(NiluState *N);
NiluStatus nilu_pushnumber(NiluState *N, double value);
/* A failed push adds nothing. No coercion: nonnumbers and absent slots return
 * zero and clear *isnum; an integer reads as the nearest float. isnum may be
 * NULL. */
double nilu_tonumberx(NiluState *N, int index, int *isnum);
#define nilu_tonumber(N, index) nilu_tonumberx((N), (index), NULL)

/* Integers (Lua's): a number is an integer or a float, both NILU_TNUMBER.
 * An integer is 64 bits and wraps around. tointegerx reads an integer, or a
 * float whose value is an integer within the range; anything else returns
 * zero and clears *isnum (isnum may be NULL). isinteger answers 1 only for
 * the integer subtype. A failed push adds nothing. */
typedef long long NiluInteger;
#define NILU_MAXINTEGER LLONG_MAX
#define NILU_MININTEGER LLONG_MIN
NiluStatus nilu_pushinteger(NiluState *N, NiluInteger value);
NiluInteger nilu_tointegerx(NiluState *N, int index, int *isnum);
#define nilu_tointeger(N, index) nilu_tointegerx((N), (index), NULL)
int nilu_isinteger(NiluState *N, int index);

/* Copies bytes, including embedded zero bytes, and adds a zero after length.
 * A zero length does not read bytes (NULL is allowed); NULL with length > 0
 * aborts. pushstring(NULL) pushes nil. A failed push adds nothing. */
NiluStatus nilu_pushlstring(NiluState *N, const char *bytes, size_t length);
NiluStatus nilu_pushstring(NiluState *N, const char *text);
/* Returns state-owned bytes, valid while their value stays on the stack.
 * Converts a number IN PLACE using Nilu's numeric spelling. All other
 * nonstring values/absent slots return NULL; so does failed conversion due
 * to allocation. Failure leaves the slot unchanged and zeroes *length.
 * length may be NULL. This read can allocate and change the slot's type. */
const char *nilu_tolstring(NiluState *N, int index, size_t *length);
#define nilu_tostring(N, index) nilu_tolstring((N), (index), NULL)

/* Any nonzero input pushes true. Only nil/false/absent slots read false. */
NiluStatus nilu_pushboolean(NiluState *N, int value);
int nilu_toboolean(NiluState *N, int index);
/* Duplicates a value, preserving identity. An absent source aborts. */
NiluStatus nilu_pushvalue(NiluState *N, int index);
/* Both indices must name visible slots. copy changes no stack depth. */
void nilu_copy(NiluState *N, int from, int to);
/* Rotate index..top right for positive n, left for negative n. No allocation.
 * Index must name a visible slot and abs(n) must not exceed segment length;
 * invalid inputs abort naming nilu_rotate. Zero/full-length rotations work. */
void nilu_rotate(NiluState *N, int index, int n);
/* n in pop must be a nonnegative count within the visible stack. */
#define nilu_pop(N, n) nilu_settop((N), -(n)-1)
#define nilu_insert(N, index) nilu_rotate((N), (index), 1)
#define nilu_remove(N, index) (nilu_rotate((N), (index), -1), nilu_pop((N), 1))
#define nilu_replace(N, index) (nilu_copy((N), -1, (index)), nilu_pop((N), 1))

/* Pushes an empty table. All failed creations leave existing slots intact. */
NiluStatus nilu_newtable(NiluState *N);
/* A new table with room for narr sequence elements and nrec other fields. */
NiluStatus nilu_createtable(NiluState *N, int narr, int nrec);
/* Owns a zero-filled block aligned for fundamental C types. No finalizers.
 * block may be NULL; otherwise it receives NULL on failure, or the owned
 * address on success. The address lives while its value stays on the stack.
 * A zero-size userdata is a distinct value; its pointer must not be accessed. */
NiluStatus nilu_newuserdata(NiluState *N, size_t size, void **block);
/* A userdata with nuvalue user values, all nil; get pushes the n-th and
 * answers its type (NILU_TNONE, pushing nil, with no n-th); set pops into the
 * n-th and answers 0 with no n-th (Lua's lua_newuserdatauv, getiuservalue,
 * setiuservalue). nilu_newuserdata's has none. */
NiluStatus nilu_newuserdatauv(NiluState *N, size_t size, int nuvalue, void **block);
int nilu_getiuservalue(NiluState *N, int idx, int n);
int nilu_setiuservalue(NiluState *N, int idx, int n);

/* The registry, a table only C reaches (Lua's luaL_ref): nilu_ref pops a value
 * and answers its reference, NILU_REFNIL for nil and NILU_NOREF without
 * memory; nilu_getref pushes what a reference holds; nilu_unref lets it go. */
#define NILU_REFNIL (-1)
#define NILU_NOREF (-2)
int nilu_ref(NiluState *N);
NiluStatus nilu_getref(NiluState *N, int ref);
void nilu_unref(NiluState *N, int ref);
/* Returns NULL for nonuserdata/absent slots; never converts a value. */
void *nilu_touserdata(NiluState *N, int index);
/* Pushes the byte length of a string/userdata or raw table border, without
 * consulting any metatable. Other types and absent slots produce zero.
 * Growth failure leaves slots intact. */
NiluStatus nilu_rawlen(NiluState *N, int index);

/* Raw value equality, without handlers, coercion or allocation.
 * Any absent slot returns false, including two absent slots. */
int nilu_rawequal(NiluState *N, int first, int second);
/* Reads exactly length bytes with Nilu's numeral grammar (including surrounding
 * ASCII whitespace), pushing one number on success. An embedded zero/trailing
 * nonspace byte or empty input is SYNTAX; nothing is pushed on any failure.
 * bytes must be non-NULL and describe a readable span, even at zero length. */
NiluStatus nilu_stringtonumber(NiluState *N, const char *bytes, size_t length);

/* Operator queries use the same __len/__eq/__lt/__le lookup as script.
 * len appends its arbitrary first result (nil if none); compare appends a
 * boolean. Inputs stay rooted. Direct refusals and setup failures append
 * nothing; a failing metamethod appends its one failure value (including nil
 * for INTERRUPTED), preserving relay origin.
 * There is no coercion or fallback from __le to __lt. Index slots must exist,
 * and compare's operation must be OPEQ/OPLT/OPLE, or the named function aborts.
 * An executing metamethod can raise through the enclosing failure handler.
 * Initial capacity failure executes nothing. Interrupted stays noncapturable.
 * An operator handler is any callable value, as a call accepts (manual 7.5). */
NiluStatus nilu_len(NiluState *N, int index);
NiluStatus nilu_compare(NiluState *N, int first, int second, int operation);

/* Identification only: never dereference this address. Tables, strings and
 * functions yield their object identity; userdata yields its block address.
 * Scalars/absent slots yield NULL. Borrowed while the value stays rooted. */
const void *nilu_topointer(NiluState *N, int index);
/* Pushes the actual metatable of a table/userdata, or the one every string
 * shares for a string, or nil when absent, including other scalar/absent slots. No handlers run and __metatable does not hide it from C.
 * Growth failure leaves existing slots intact. */
NiluStatus nilu_getmetatable(NiluState *N, int index);
/* Pushes the metamethod the VM would find for the value under `name`: raw in
 * its metatable, then along the table-valued __index links of that metatable's
 * own metatable, nothing run; nil when there is none. RUNTIME pushes nothing
 * when the chain is longer than the VM follows. name must be non-NULL. */
NiluStatus nilu_getmetafield(NiluState *N, int index, const char *name);

/* next requires a visible target and top key (nil starts). It replaces the key
 * and appends a value with *more=1, or pops the key on end with *more=0. more
 * may be NULL and is cleared on entry. TYPE/RUNTIME/STACK/MEMORY preserves
 * inputs, pushes no diagnostic, and leaves more zero. Key validity/end are
 * checked before capacity; full-stack end succeeds. Deleting the current field
 * is allowed; inserting new keys during traversal is not guaranteed. */
NiluStatus nilu_next(NiluState *N, int index, int *more);
/* Set the visible table/userdata target's metatable to top table/nil and pop
 * top on success; a string target sets the metatable every string shares. TYPE preserves target/top and adds no diagnostic, including
 * other top types, scalar targets and a userdata metatable with raw __gc.
 * __metatable does not restrict C. Missing slots abort naming this entry. */
NiluStatus nilu_setmetatable(NiluState *N, int index);

/* Raw access never invokes handlers. Index must name a visible slot; rawget
 * requires a key on top and replaces it with the value (nil when absent).
 * rawset requires key/value on top and consumes both on success. Target/operand
 * slots must exist or abort naming the function. Only tables support raw access.
 * TYPE/MEMORY leaves all inputs and the table unchanged, and pushes no diagnostic.
 * A failed rawset rejects keys other than strings/numbers, including NaN; an
 * unsupported read key is absent and therefore succeeds with nil. A native must
 * supply its own diagnostic before nilu_error; the remaining top is input data.
 */
NiluStatus nilu_rawget(NiluState *N, int index);
NiluStatus nilu_rawset(NiluState *N, int index);

/* Metatable-aware access may execute script and collect. Indices and required
 * key/value operands must exist or abort naming the entry. gettable replaces
 * the top key; settable consumes key/value. Globals use the state's global
 * table, including its metatable. Names must be non-NULL NUL-terminated text.
 * getglobal appends a value; setglobal consumes the top value.
 * Direct refusal/setup MEMORY/STACK preserves inputs and adds no diagnostic.
 * An executing metamethod failure publishes one carried failure where the
 * result would go: gettable's key slot, settable's key slot after removing its
 * value, getglobal's new result slot or setglobal's value slot. Origin survives
 * a subsequent nilu_error; successful reads/storage carry no failure origin.
 * These entries do not add a pcall boundary or synthetic VM frame. */
NiluStatus nilu_gettable(NiluState *N, int index);
NiluStatus nilu_settable(NiluState *N, int index);
NiluStatus nilu_getglobal(NiluState *N, const char *name);
NiluStatus nilu_setglobal(NiluState *N, const char *name);

/* Load NUL-terminated text without executing. Source/name must be non-NULL;
 * misuse aborts naming the entry point. loadstring uses source as its chunk name;
 * loadnamed accepts =literal, @file, or source-text naming conventions.
 * OK appends an owned function. SYNTAX appends one owned diagnostic string.
 * MEMORY/STACK appends nothing and preserves existing inputs. where may be NULL;
 * otherwise it is cleared on entry and set only for SYNTAX. If either coordinate
 * exceeds C int, both are zero; status and the exact diagnostic text are retained.
 * Input text/name may be released after the call. No code or hook runs here. */
NiluStatus nilu_loadstring(NiluState *N, const char *source, NiluError *where);
NiluStatus nilu_loadnamed(NiluState *N, const char *source, const char *name, NiluError *where);

/* Replace the _ENV of a function loadstring/loadnamed made (at index) with the
 * top value, and pop it. A chunk that reads no global has no _ENV and is left
 * unchanged. Any other value at index answers TYPE and pops nothing. */
NiluStatus nilu_setenv(NiluState *N, int index);

/* The reader that require, dofile and loadfile ask for text.
 * setreader takes the function on top (or nil, removing it) and pops it; any
 * other value answers TYPE and stays. getreader pushes it, or nil. The library
 * calls it as reader(name, from, kind): kind is "module" for require and
 * "file" for dofile/loadfile; from is the key of the file being loaded when
 * one is, else nil. It returns key, text (key names the code: its chunk name
 * is "@" .. key and require caches under it) or nil, reason. */
NiluStatus nilu_setreader(NiluState *N);
NiluStatus nilu_getreader(NiluState *N);

/* The writer print hands its line to, set and read as the reader
 * is. print calls it once per call with one string: each argument through the
 * global tostring, tabs between, and a final newline. Without a writer, print
 * fails with "cannot print: no writer was given to this state". */
NiluStatus nilu_setwriter(NiluState *N);
NiluStatus nilu_getwriter(NiluState *N);

/* The collector. COLLECT runs a whole collection; COUNT puts the KiB the state
 * holds in *out; STEP runs a whole collection too (the collector is not
 * incremental) and puts 1 in *out; ISRUNNING puts 1 in *out, 0 while stopped.
 * STOP keeps collections from starting by themselves until RESTART (COLLECT
 * and STEP still run); both put 0 in *out. out may be NULL. Another what
 * answers TYPE. */
#define NILU_GCCOLLECT 0
#define NILU_GCCOUNT 1
#define NILU_GCSTEP 2
#define NILU_GCISRUNNING 3
#define NILU_GCSTOP 4
#define NILU_GCRESTART 5
NiluStatus nilu_gc(NiluState *N, int what, double *out);

/* Execute the function below nargs arguments. Nonnegative nresults truncates
 * or pads with nil; NILU_MULTRET keeps every result. Execution failure consumes
 * function+arguments and leaves exactly one failure value, irrespective of the
 * requested result count. Setup MEMORY/STACK preserves the input window.
 * call retains relay origin; pcall captures it (except INTERRUPTED).
 * pcall's msgh is zero or a function index strictly below the callee; its handler
 * runs before unwinding. Handler success keeps the original status/location;
 * handler failure is RUNTIME/error-in-error-handling, except INTERRUPTED.
 * Invalid argument/result counts and handler slots abort naming the entry.
 * Callback result counts must be NILU_FAIL or in 0..visible top; misuse aborts.
 * A hook callback may call back into the same state (see nilu_sethook). */
NiluStatus nilu_call(NiluState *N, int nargs, int nresults);
NiluStatus nilu_pcall(NiluState *N, int nargs, int nresults, int msgh);

/* A callback returns its trailing result count, or NILU_FAIL. Registration
 * requires a non-NULL callback. */
NiluStatus nilu_pushcfunction(NiluState *N, NiluCFunction callback);
/* Return this from a callback to fail with the top visible value. No allocation
 * or longjmp; returns NILU_FAIL. An empty visible stack aborts. A transported
 * failure retains its original kind; a newly pushed value raises RUNTIME.
 * pushvalue/copy/rotate preserve origin; conversion and storage do not. */
int nilu_error(NiluState *N);
/* Captures the top n values in order and replaces them with a new closure.
 * n==0 is the same light function as pushcfunction. n must be in 0..255 and
 * within visible depth, or abort. Allocation failure preserves the values. */
NiluStatus nilu_pushcclosure(NiluState *N, NiluCFunction callback, int n);
/* Operate on the C closure currently running, with 1-based upvalue numbers.
 * Missing numbers/no active C closure return TYPE without pushing/popping.
 * A successful setupvalue pops one value; with a valid upvalue but no visible
 * value it aborts. getupvalue growth failures leave the stack intact. */
NiluStatus nilu_getupvalue(NiluState *N, int n);
NiluStatus nilu_setupvalue(NiluState *N, int n);

/* Runtime location: level 0 gives a completed call's failure location.
 * New call entry, success or a failure without a script location clears it.
 * Positive levels
 * walk callers of the running native (1 is its caller); a native frame is
 * "[C]":0. Negative/absent levels give NULL and zero coordinates.
 * where may be NULL; otherwise both coordinates are cleared on entry. Runtime
 * column is always 0. An unrepresentable line gives {0,0}, retaining the name.
 * The borrowed name remains valid until the next call begins execution on this
 * state or the state is closed. Repeated queries do not invalidate prior names.
 * No allocation or stack change. */
const char *nilu_where(NiluState *N, int level, NiluError *where);

/* Original bytecode call-site name of the running native, or NULL with length
 * zero when unnamed/host-entered/no native is running. length may be NULL.
 * Bytes are counted (including embedded NUL) and have a trailing zero. Borrowed
 * until the next call begins execution on this state or close; repeated queries,
 * GC and other-state calls do not invalidate it. No allocation/stack change. */
const char *nilu_calledas(NiluState *N, size_t *length);

/* How the currently running native was called: local/global/field/method,
 * upvalue, constant or for iterator. NULL without a bytecode call-site name,
 * including host calls and calls through __call. No stack change/allocation;
 * the returned classification is static storage and needs no release. */
const char *nilu_namewhat(NiluState *N);

/* For a traceback, at a level as nilu_where counts: the name the function there
 * was called by, or NULL; *namewhat (may be NULL) gets its kind as
 * nilu_namewhat words it, or "" without a name. linedefined answers the line of
 * the function's `function`, 0 for a chunk, -1 for a native or no function. */
const char *nilu_callername(NiluState *N, int level, const char **namewhat);
int nilu_linedefined(NiluState *N, int level);

/* Coroutines. A thread is a value on the stack (NILU_TTHREAD).
 * newthread replaces the function on top with a thread that will run it
 * (NILU_ERR_TYPE if it is not a function). resume consumes the top nargs
 * values and pushes what the thread returned (NILU_OK) or yielded
 * (NILU_YIELD), storing the count in *nresults, or pushes the failure value
 * and answers its status; a dead or running thread is refused with Lua's
 * sentence and NILU_ERR_RUNTIME. A C function suspends with
 * `return nilu_yield(N, n)`, giving the top n values; outside a coroutine or
 * under nilu_call, nilu_pcall, a message handler or a hook it is refused with
 * Lua's sentence as nilu_error refuses. isyieldable answers for the thread at
 * idx (0 for the main one, -1 for a value that is no thread). closethread drops a suspended or dead
 * thread's frames: NILU_OK, or the failure it died by, pushed. */
#define NILU_THREAD_SUSPENDED 0
#define NILU_THREAD_RUNNING 1
#define NILU_THREAD_NORMAL 2
#define NILU_THREAD_DEAD 3
NiluStatus nilu_newthread(NiluState *N);
NiluStatus nilu_resume(NiluState *N, int idx, int nargs, int *nresults);
int nilu_yield(NiluState *N, int nresults);
int nilu_threadstatus(NiluState *N, int idx);
int nilu_pushrunning(NiluState *N);
int nilu_isyieldable(NiluState *N, int idx);
NiluStatus nilu_closethread(NiluState *N, int idx);

/* nilu_pcall from a C function that a yield in the callee may suspend. Then it
 * answers NILU_YIELD, and the C function returns `nilu_yield(N, 0)`; when the
 * callee finishes after a resume, k runs in the C function's place, with the
 * status nilu_pcall would have answered, the stack as it would have left it,
 * and ctx, and answers as the C function would have (Lua's lua_pcallk). A C
 * function that called nilu_yield, or got NILU_YIELD here, and returns
 * anything but nilu_yield's answer aborts with a message naming nilu_yield. */
/* Argument checks for a host's C function, with the library's sentences
 * (Lua's luaL_argerror, luaL_typeerror, luaL_check*, luaL_opt*). A check
 * answers 0, or NILU_FAIL with the failure raised, which the C function then
 * returns: `if (nilu_checkinteger(N, 1, &n) != 0) return NILU_FAIL;`. The
 * function is named as the caller wrote it, else '?'. An integer is an
 * integer, or a float whose value is one within 64 bits (nilu_tointegerx); a
 * string is borrowed while its value is on the stack;
 * an opt answers its default for an absent or nil argument. */
int nilu_argerror(NiluState *N, int arg, const char *extramsg);
int nilu_typeerror(NiluState *N, int arg, const char *tname);
int nilu_checkany(NiluState *N, int arg);
int nilu_checktype(NiluState *N, int arg, int t);
int nilu_checknumber(NiluState *N, int arg, double *out);
int nilu_optnumber(NiluState *N, int arg, double def, double *out);
int nilu_checkinteger(NiluState *N, int arg, long long *out);
int nilu_optinteger(NiluState *N, int arg, long long def, long long *out);
int nilu_checklstring(NiluState *N, int arg, const char **out, size_t *len);
int nilu_optlstring(NiluState *N, int arg, const char *def, const char **out, size_t *len);

typedef int (*NiluKFunction)(NiluState *N, int status, intptr_t ctx);
NiluStatus nilu_pcallk(NiluState *N, int nargs, int nresults, int msgh, intptr_t ctx, NiluKFunction k);

/* What a function is and where it runs (Lua's lua_getinfo). source is the
 * chunk's name as given ("@file", "=stdin"; "=[C]"), short_src as a message
 * shows it, what "Lua", "main" or "C"; name is NULL and namewhat "" without a
 * name; a line is -1 where there is none. Strings are borrowed from the
 * function, which the state keeps until it closes. */
typedef struct {
  const char *source;
  char short_src[60];
  const char *what;
  const char *name;
  const char *namewhat;
  int currentline;
  int linedefined;
  int lastlinedefined;
  unsigned char nups;
  unsigned char nparams;
  unsigned char isvararg;
  unsigned char istailcall;
  int extraargs;
} NiluDebug;
/* Fills ar about the function at level of the thread at stack index thread
 * (0: the running one), counted as nilu_where counts, level 0 being the C
 * function asking; or, with what starting '>', about the function on top,
 * which it pops. The letters (S l n u t r f L) are Lua's; 'f' pushes the
 * function, 'L' a table of the lines with code (nil for C). Answers 1, 0 when
 * there is no such level, -1 for an unknown letter. */
int nilu_getinfo(NiluState *N, int thread, int level, const char *what, NiluDebug *ar);

/* Installs an instruction observer without allocation or stack changes.
 * NULL or count==0 disables it. After count VM instructions, before the next,
 * the hook returns 0 to continue or any nonzero value to interrupt.
 * Each callback starts with an empty temporary stack window. Suspended VM and
 * caller slots are hidden. Temporary values are discarded when it returns,
 * whether continuing or interrupting; pushes can still return ERR_STACK/MEMORY.
 * Popping below the temporary bottom aborts under nilu_settop's precondition.
 * Native C work is not counted. The callback may run this state's VM again
 * (nilu_call/nilu_pcall on a function in its window): the inner instructions
 * count on the same countdown and are observed too, each callback in its own
 * window, and the outer callback's window is back when the inner call returns.
 * An inner call the hook interrupts answers ERR_INTERRUPTED to the callback,
 * whose own return value alone decides for the outer call. The ordinary call
 * limit bounds a callback that calls again at every stop. A nilu_sethook made
 * inside a callback applies to the whole state at once and is not restored.
 * A call interrupted by the hook returns ERR_INTERRUPTED with nil, and so does
 * the host's call around it whatever a C function in between does: until the
 * host's call returns, a nilu_call runs nothing and answers ERR_INTERRUPTED,
 * and a C function's return becomes the interruption. */
void nilu_sethook(NiluState *N, NiluHook hook, unsigned int count);

/* Opens the standard library: print, type, tostring, tonumber, assert, select,
 * error, pcall, xpcall, next, pairs, ipairs, rawget, rawset, rawequal,
 * rawlen, setmetatable, getmetatable, collectgarbage, warn, _G and _VERSION,
 * the string, table, math, utf8, coroutine and debug tables, and load,
 * require, dofile, loadfile and package (the last three ask the reader; see
 * nilu_setreader). Every call makes them afresh and assigns
 * the globals, so a second call restores what a program replaced. print
 * writes through the writer (nilu_setwriter); io and os are the command's.
 * MEMORY/STACK leaves what was assigned before the failure; nothing stays on
 * the stack. The library itself is written against this header alone. */
NiluStatus nilu_openlibs(NiluState *N);
/* Opens only the libraries whose bits are set, in nilu_openlibs's order; the
 * values are Lua 5.5's (io and os are the host's). Unknown bits are ignored. */
#define NILU_LIB_BASE 1
#define NILU_LIB_PACKAGE 2
#define NILU_LIB_COROUTINE 4
#define NILU_LIB_DEBUG 8
#define NILU_LIB_MATH 32
#define NILU_LIB_STRING 128
#define NILU_LIB_TABLE 256
#define NILU_LIB_UTF8 512
NiluStatus nilu_openselectedlibs(NiluState *N, int libs);

#ifdef __cplusplus
}
#endif
#endif
