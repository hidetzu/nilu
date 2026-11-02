/* The nilu command (manual chapter 11): one host program written against
 * include/nilu.h and nothing else. It runs files, -e text and standard input,
 * shows a prompt, writes a failure the way the manual shows it, and brings what
 * the embedded library leaves to a host: io, os and the writer print uses. What
 * touches the outside world (streams, files, the clock, the environment, the
 * process) lives here and nowhere in the core (ADR 0003, 0010).
 *
 * Every refusal borrows Lua 5.5's words; where this command speaks for itself
 * the manual says so. A library-style refusal is composed the way the library
 * composes it: the caller's name from nilu_calledas, the position from
 * nilu_where(1), a method's receiver counted as Lua counts it. */
/* popen, pclose, mkstemp and close are POSIX, not C99; declare them. */
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#define popen _popen
#define pclose _pclose
#else
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#endif

#include "nilu.h"

#define PROGNAME "nilu"
#define USAGE                                                                       \
  "usage: " PROGNAME " [options] [script]\n"                                        \
  "Available options are:\n"                                                        \
  "  -e stat   run the text 'stat'\n"                                               \
  "  -i        enter the prompt after running the script\n"                         \
  "  -l mod    require library 'mod' into global 'mod'\n"                          \
  "  -l g=mod  require library 'mod' into global 'g'\n"                            \
  "  -W        turn warnings on\n"                                                  \
  "  -v        say which version this is\n"                                         \
  "  --        stop handling options\n"                                             \
  "  -         stop handling options and run stdin\n"

/* ── composing refusals ──────────────────────────────────────────────────── */

/* Pushes the message with the caller's position in front, as luaL_error does,
 * and answers NILU_FAIL for the native to return. A native frame at level 1 adds
 * nothing. The buffer bounds the sentence; a longer one keeps its tail cut. */
static int raise_at(NiluState *N, int level, const char *message) {
  NiluError where;
  const char *name = nilu_where(N, level, &where);
  char buffer[1024];
  if (name != NULL && where.line > 0) {
    snprintf(buffer, sizeof buffer, "%s:%d: %s", name, where.line, message);
    if (nilu_pushstring(N, buffer) != NILU_OK) return NILU_FAIL;
  } else if (nilu_pushstring(N, message) != NILU_OK) {
    return NILU_FAIL;
  }
  return nilu_error(N);
}
static int raise_message(NiluState *N, const char *message) { return raise_at(N, 1, message); }

/* A memory shortage inside a function of the command is a runtime failure that
 * carries the prepared sentence (manual 8.4); only when the sentence itself
 * cannot be pushed does the bare memory failure answer. */
static int raise_memory(NiluState *N) {
  if (nilu_pushstring(N, "not enough memory") == NILU_OK) return nilu_error(N);
  return NILU_FAIL;
}

/* The registered name of the native running now, for a refusal made where no
 * caller's code named the function (a host call, pcall). Each native sets it
 * on entry, before any check that could raise. */
static const char *registered = "?";

/* Lua's luaL_argerror: through a method call the receiver is argument 0. */
static int arg_error(NiluState *N, int index, const char *detail) {
  const char *what = nilu_namewhat(N);
  size_t length = 0;
  const char *name = nilu_calledas(N, &length);
  char buffer[512];
  char shown[256];
  if (name == NULL || length == 0) {
    name = registered;
    length = strlen(name);
  }
  if (length >= sizeof shown) length = sizeof shown - 1;
  memcpy(shown, name, length);
  shown[length] = '\0';
  if (what != NULL && strcmp(what, "method") == 0) {
    index--;
    if (index == 0) {
      snprintf(buffer, sizeof buffer, "calling '%s' on bad self (%s)", shown, detail);
      return raise_message(N, buffer);
    }
  }
  snprintf(buffer, sizeof buffer, "bad argument #%d to '%s' (%s)", index, shown, detail);
  return raise_message(N, buffer);
}

static const char *type_name(NiluState *N, int index) {
  switch (nilu_type(N, index)) {
    case NILU_TNONE: return "no value";
    case NILU_TNIL: return "nil";
    case NILU_TNUMBER: return "number";
    case NILU_TFUNCTION: return "function";
    case NILU_TBOOLEAN: return "boolean";
    case NILU_TSTRING: return "string";
    case NILU_TTABLE: return "table";
    default: return "userdata";
  }
}

/* The value's `__name` stands in for table/userdata, as luaL_typeerror has it.
 * `argument` is the number the sentence says; `index` is where the value is. */
static int type_error_at(NiluState *N, int index, int argument, const char *expected) {
  char detail[320];
  const char *actual = type_name(N, index);
  char named[128];
  int kind = nilu_type(N, index);
  int absolute = index < 0 ? nilu_gettop(N) + index + 1 : index;
  if (kind == NILU_TTABLE || kind == NILU_TUSERDATA) {
    if (nilu_getmetatable(N, absolute) == NILU_OK) {
      if (nilu_type(N, -1) == NILU_TTABLE && nilu_pushstring(N, "__name") == NILU_OK &&
          nilu_rawget(N, -2) == NILU_OK) {
        if (nilu_type(N, -1) == NILU_TSTRING) {
          snprintf(named, sizeof named, "%s", nilu_tostring(N, -1));
          actual = named;
        }
        nilu_pop(N, 1);
      }
      nilu_pop(N, 1);
    }
  }
  snprintf(detail, sizeof detail, "%s expected, got %s", expected, actual);
  return arg_error(N, argument, detail);
}
static int type_error(NiluState *N, int index, const char *expected) { return type_error_at(N, index, index, expected); }

/* A string argument; the pointer is borrowed while the value stays on the stack. */
static int check_string(NiluState *N, int index, const char **text, size_t *length) {
  if (nilu_type(N, index) != NILU_TSTRING) return type_error(N, index, "string");
  *text = nilu_tolstring(N, index, length);
  return NILU_OK;
}
static int check_number(NiluState *N, int index, double *value) {
  if (nilu_type(N, index) != NILU_TNUMBER) return type_error(N, index, "number");
  *value = nilu_tonumber(N, index);
  return NILU_OK;
}
/* An integer, or a float with an integer value, as Lua's luaL_checkinteger. */
static int check_integer(NiluState *N, int index, long long *value) {
  int is_integer = 0;
  if (nilu_type(N, index) != NILU_TNUMBER) return type_error(N, index, "number");
  *value = nilu_tointegerx(N, index, &is_integer);
  if (!is_integer) return arg_error(N, index, "number has no integer representation");
  return NILU_OK;
}
static int absent(NiluState *N, int index) {
  int kind = nilu_type(N, index);
  return kind == NILU_TNONE || kind == NILU_TNIL;
}
static int opt_integer(NiluState *N, int index, long long fallback, long long *value) {
  if (absent(N, index)) {
    *value = fallback;
    return NILU_OK;
  }
  return check_integer(N, index, value);
}

/* ── print ────────────────────────────────────────────────────────────────── */

/* The library's print hands each line to this writer (ADR 0003), which puts
 * it on standard output as io.write does; warn's lines come with "warning"
 * and go to standard error. */
static int host_writer(NiluState *N) {
  size_t length = 0;
  const char *text = nilu_tolstring(N, 1, &length);
  const char *kind = nilu_type(N, 2) == NILU_TSTRING ? nilu_tolstring(N, 2, NULL) : NULL;
  FILE *stream = kind != NULL && strcmp(kind, "warning") == 0 ? stderr : stdout;
  if (text != NULL) {
    if (stream == stderr) fflush(stdout);
    fwrite(text, 1, length, stream);
  }
  return 0;
}

/* ── files ────────────────────────────────────────────────────────────────── */

/* What a file value holds. `standard` says which of the three it is (0 for a file
 * the program opened), since those will not close. */
typedef struct {
  FILE *stream;
  int closed;
  int standard;
  int pipe; /* io.popen's: closed with pclose, which answers the exit status */
} File;

/* The command remembers every stream it opened and closes them when it exits;
 * there is no finaliser (manual 11.4.1). */
typedef struct {
  FILE *stream;
  int pipe;
} Opened;
static Opened *ledger = NULL;
static size_t ledger_count = 0, ledger_capacity = 0;

static void remember(FILE *stream, int pipe) {
  if (ledger_count == ledger_capacity) {
    size_t capacity = ledger_capacity == 0 ? 16 : ledger_capacity * 2;
    Opened *grown = realloc(ledger, capacity * sizeof *grown);
    if (grown == NULL) return; /* The stream still closes at exit through the C runtime. */
    ledger = grown;
    ledger_capacity = capacity;
  }
  ledger[ledger_count].stream = stream;
  ledger[ledger_count].pipe = pipe;
  ledger_count++;
}
static void forget(FILE *stream) {
  size_t i;
  for (i = 0; i < ledger_count; i++) {
    if (ledger[i].stream == stream) {
      ledger[i] = ledger[--ledger_count];
      return;
    }
  }
}
static void close_open_files(void) {
  while (ledger_count > 0) {
    Opened opened = ledger[--ledger_count];
    if (opened.pipe) pclose(opened.stream);
    else fclose(opened.stream);
  }
  free(ledger);
  ledger = NULL;
  ledger_capacity = 0;
}

/* The io functions share one table (their only upvalue): the three standard
 * files, the current input and output, and the file metatable. */
static int shared(NiluState *N) { return nilu_getupvalue(N, 1); }
static int shared_get(NiluState *N, const char *key) {
  if (shared(N) != NILU_OK || nilu_pushstring(N, key) != NILU_OK) return NILU_FAIL;
  if (nilu_rawget(N, -2) != NILU_OK) return NILU_FAIL;
  nilu_remove(N, -2);
  return NILU_OK;
}
/* Stores the top value under the key and pops it. */
static int shared_set(NiluState *N, const char *key) {
  if (shared(N) != NILU_OK) return NILU_FAIL;
  nilu_insert(N, -2);
  if (nilu_pushstring(N, key) != NILU_OK) return NILU_FAIL;
  nilu_insert(N, -2);
  if (nilu_rawset(N, -3) != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1);
  return NILU_OK;
}

/* Is the value a file of this command? Answers the File or NULL. */
static File *as_file(NiluState *N, int index) {
  int absolute = index < 0 ? nilu_gettop(N) + index + 1 : index;
  File *file;
  int same;
  if (nilu_type(N, absolute) != NILU_TUSERDATA) return NULL;
  if (nilu_getmetatable(N, absolute) != NILU_OK) return NULL;
  if (shared_get(N, "meta") != NILU_OK) {
    nilu_pop(N, 1);
    return NULL;
  }
  same = nilu_rawequal(N, -1, -2);
  nilu_pop(N, 2);
  if (!same) return NULL;
  file = (File *)nilu_touserdata(N, absolute);
  return file;
}
/* A file argument that is open; a closed one is refused as Lua's tofile does. */
static int to_file(NiluState *N, int index, File **file) {
  File *found = as_file(N, index);
  if (found == NULL) return type_error(N, index, "FILE*");
  if (found->closed) return raise_message(N, "attempt to use a closed file");
  *file = found;
  return NILU_OK;
}

/* luaL_execresult: true, or nil, then "exit" or "signal" and the code, from a
 * status system() or pclose() answered. */
static int exec_result(NiluState *N, int stat);

/* luaL_fileresult: nil, the reason and errno, as three values. */
static int file_result(NiluState *N, int ok, const char *name) {
  int err = errno;
  if (ok) {
    if (nilu_pushboolean(N, 1) != NILU_OK) return raise_memory(N);
    return 1;
  }
  if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
  if (name != NULL) {
    char buffer[512];
    snprintf(buffer, sizeof buffer, "%s: %s", name, strerror(err));
    if (nilu_pushstring(N, buffer) != NILU_OK) return raise_memory(N);
  } else if (nilu_pushstring(N, strerror(err)) != NILU_OK) {
    return raise_memory(N);
  }
  if (nilu_pushinteger(N, err) != NILU_OK) return raise_memory(N);
  return 3;
}

/* Pushes a new open file holding the stream, with the shared metatable. */
static int push_file(NiluState *N, FILE *stream, int standard) {
  void *block = NULL;
  File *file;
  if (nilu_newuserdata(N, sizeof(File), &block) != NILU_OK) return NILU_FAIL;
  file = (File *)block;
  file->stream = stream;
  file->closed = 0;
  file->standard = standard;
  file->pipe = 0;
  if (shared_get(N, "meta") != NILU_OK || nilu_setmetatable(N, -2) != NILU_OK) return NILU_FAIL;
  if (!standard) remember(stream, 0);
  return NILU_OK;
}

static int file_tostring(NiluState *N) {
  File *file = as_file(N, 1);
  char buffer[64];
  if (file == NULL) return type_error(N, 1, "FILE*");
  if (file->closed) snprintf(buffer, sizeof buffer, "file (closed)");
  else snprintf(buffer, sizeof buffer, "file (%p)", (void *)file->stream);
  if (nilu_pushstring(N, buffer) != NILU_OK) return raise_memory(N);
  return 1;
}

static int close_file(NiluState *N, File *file) {
  int ok;
  if (file->standard) {
    if (nilu_pushnil(N) != NILU_OK || nilu_pushstring(N, "cannot close standard file") != NILU_OK) return raise_memory(N);
    return 2;
  }
  forget(file->stream);
  if (file->pipe) {
    int stat = pclose(file->stream);
    file->closed = 1;
    file->stream = NULL;
    return exec_result(N, stat);
  }
  ok = fclose(file->stream) == 0;
  file->closed = 1;
  file->stream = NULL;
  return file_result(N, ok, NULL);
}

/* __close: a file a `<close>` variable or a generic `for` held is closed
 * when its scope ends, as Lua's; a closed or standard one is left alone. */
static int file_close_value(NiluState *N) {
  File *file = as_file(N, 1);
  if (file != NULL && !file->closed && !file->standard) {
    int top = nilu_gettop(N);
    close_file(N, file);
    nilu_settop(N, top);
  }
  return 0;
}

static int file_close(NiluState *N) {
  registered = "close";
  File *file;
  int status = to_file(N, 1, &file);
  if (status != NILU_OK) return status;
  return close_file(N, file);
}

/* ── reading ──────────────────────────────────────────────────────────────── */

typedef struct {
  char *bytes;
  size_t length, capacity;
} Text;

static int text_push(Text *text, int byte) {
  if (text->length == text->capacity) {
    size_t capacity = text->capacity == 0 ? 128 : text->capacity * 2;
    char *grown = realloc(text->bytes, capacity);
    if (grown == NULL) return 0;
    text->bytes = grown;
    text->capacity = capacity;
  }
  text->bytes[text->length++] = (char)byte;
  return 1;
}

/* Reads a line; answers 0 at end of input with nothing read. */
static int read_line(NiluState *N, FILE *stream, int keep_newline, int *pushed) {
  Text text = {NULL, 0, 0};
  int byte;
  int saw = 0;
  *pushed = 0;
  while ((byte = fgetc(stream)) != EOF) {
    saw = 1;
    if (byte == '\n') {
      if (keep_newline && !text_push(&text, byte)) {
        free(text.bytes);
        return raise_memory(N);
      }
      break;
    }
    if (!text_push(&text, byte)) {
      free(text.bytes);
      return raise_memory(N);
    }
  }
  if (!saw) {
    free(text.bytes);
    return NILU_OK;
  }
  if (nilu_pushlstring(N, text.bytes == NULL ? "" : text.bytes, text.length) != NILU_OK) {
    free(text.bytes);
    return raise_memory(N);
  }
  free(text.bytes);
  *pushed = 1;
  return NILU_OK;
}

static int read_all(NiluState *N, FILE *stream) {
  Text text = {NULL, 0, 0};
  int byte;
  while ((byte = fgetc(stream)) != EOF) {
    if (!text_push(&text, byte)) {
      free(text.bytes);
      return raise_memory(N);
    }
  }
  if (nilu_pushlstring(N, text.bytes == NULL ? "" : text.bytes, text.length) != NILU_OK) {
    free(text.bytes);
    return raise_memory(N);
  }
  free(text.bytes);
  return NILU_OK;
}

static int read_count(NiluState *N, FILE *stream, long long count, int *pushed) {
  char *bytes;
  size_t got;
  *pushed = 0;
  if (count == 0) {
    int byte = fgetc(stream);
    if (byte == EOF) return NILU_OK;
    ungetc(byte, stream);
    if (nilu_pushstring(N, "") != NILU_OK) return raise_memory(N);
    *pushed = 1;
    return NILU_OK;
  }
  if (count < 0) return raise_message(N, "resulting string too large");
  bytes = malloc((size_t)count);
  if (bytes == NULL) return raise_memory(N);
  got = fread(bytes, 1, (size_t)count, stream);
  if (got == 0) {
    free(bytes);
    return NILU_OK;
  }
  if (nilu_pushlstring(N, bytes, got) != NILU_OK) {
    free(bytes);
    return raise_memory(N);
  }
  free(bytes);
  *pushed = 1;
  return NILU_OK;
}

/* Lua's read_number: a numeral as the lexer would read it, leading whitespace
 * skipped and the first byte that does not belong put back. What the numeral
 * grammar refuses answers nil. */
static int read_number(NiluState *N, FILE *stream, int *pushed) {
  char buffer[201];
  size_t length = 0;
  int byte;
  int hex = 0;
  int count = 0;
  *pushed = 0;
  do byte = fgetc(stream);
  while (byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r' || byte == '\f' || byte == '\v');
  if (byte == '-' || byte == '+') {
    buffer[length++] = (char)byte;
    byte = fgetc(stream);
  }
  if (byte == '0') {
    buffer[length++] = '0';
    byte = fgetc(stream);
    if (byte == 'x' || byte == 'X') {
      buffer[length++] = (char)byte;
      byte = fgetc(stream);
      hex = 1;
    } else count = 1;
  }
  while (byte != EOF && length < 200 && (hex ? ((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F')) : (byte >= '0' && byte <= '9'))) {
    buffer[length++] = (char)byte;
    byte = fgetc(stream);
    count++;
  }
  if (byte == '.' && length < 200) {
    buffer[length++] = '.';
    byte = fgetc(stream);
    while (byte != EOF && length < 200 && (hex ? ((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f') || (byte >= 'A' && byte <= 'F')) : (byte >= '0' && byte <= '9'))) {
      buffer[length++] = (char)byte;
      byte = fgetc(stream);
      count++;
    }
  }
  if (count > 0 && length < 200 && (hex ? (byte == 'p' || byte == 'P') : (byte == 'e' || byte == 'E'))) {
    buffer[length++] = (char)byte;
    byte = fgetc(stream);
    if ((byte == '-' || byte == '+') && length < 200) {
      buffer[length++] = (char)byte;
      byte = fgetc(stream);
    }
    while (byte != EOF && length < 200 && byte >= '0' && byte <= '9') {
      buffer[length++] = (char)byte;
      byte = fgetc(stream);
    }
  }
  if (byte != EOF) ungetc(byte, stream);
  if (length > 0 && nilu_stringtonumber(N, buffer, length) == NILU_OK) {
    *pushed = 1;
    return NILU_OK;
  }
  if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
  *pushed = 1;
  return NILU_OK;
}

/* g_read: the formats from argument `first`; the first that fails is nil and
 * the rest are not tried. Answers the number of values, or NILU_FAIL. */
static int read_formats(NiluState *N, FILE *stream, int first, int offset) {
  int count = nilu_gettop(N);
  int results = 0;
  int i;
  clearerr(stream);
  if (first > count) {
    int pushed = 0;
    int status = read_line(N, stream, 0, &pushed);
    if (status != NILU_OK) return status;
    if (ferror(stream)) {
      if (pushed) nilu_pop(N, 1);
      return file_result(N, 0, NULL);
    }
    if (!pushed && nilu_pushnil(N) != NILU_OK) return raise_memory(N);
    results = 1;
  }
  for (i = first; i <= count; i++) {
    int pushed = 0;
    int status;
    if (nilu_type(N, i) == NILU_TNUMBER) {
      int is_integer = 0;
      long long wanted = nilu_tointegerx(N, i, &is_integer);
      if (!is_integer) return arg_error(N, i - offset, "number has no integer representation");
      status = read_count(N, stream, wanted, &pushed);
    } else {
      const char *format;
      if (nilu_type(N, i) != NILU_TSTRING) return type_error_at(N, i, i - offset, "string");
      format = nilu_tostring(N, i);
      if (format[0] == '*') format++;
      switch (format[0]) {
        case 'l': status = read_line(N, stream, 0, &pushed); break;
        case 'L': status = read_line(N, stream, 1, &pushed); break;
        case 'a':
          status = read_all(N, stream);
          pushed = 1;
          break;
        case 'n': status = read_number(N, stream, &pushed); break;
        default: return arg_error(N, i - offset, "invalid format");
      }
    }
    if (status != NILU_OK) return status;
    if (ferror(stream)) {
      if (pushed) nilu_pop(N, 1);
      return file_result(N, 0, NULL);
    }
    if (!pushed) {
      if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
      results++;
      break;
    }
    results++;
    if (nilu_type(N, -1) == NILU_TNIL) break;
  }
  return results;
}

static int file_read(NiluState *N) {
  registered = "read";
  File *file;
  int status = to_file(N, 1, &file);
  if (status != NILU_OK) return status;
  return read_formats(N, file->stream, 2, 0);
}

/* g_write: strings and numbers as they are; answers the file, or on a stream
 * failure the three values and the count written before it. */
static int write_values(NiluState *N, FILE *stream, int file_index, int first, int offset) {
  int count = nilu_gettop(N);
  int i;
  for (i = first; i <= count; i++) {
    size_t length = 0;
    const char *text;
    int kind = nilu_type(N, i);
    if (kind == NILU_TNUMBER) {
      if (nilu_pushvalue(N, i) != NILU_OK) return raise_memory(N);
      text = nilu_tolstring(N, -1, &length);
      if (text == NULL) return raise_memory(N);
    } else {
      if (kind != NILU_TSTRING) return type_error_at(N, i, i - offset, "string");
      text = nilu_tolstring(N, i, &length);
    }
    if (fwrite(text, 1, length, stream) != length) {
      int result;
      if (kind == NILU_TNUMBER) nilu_pop(N, 1);
      result = file_result(N, 0, NULL);
      if (result == NILU_FAIL) return result;
      if (nilu_pushinteger(N, i - first) != NILU_OK) return raise_memory(N);
      return result + 1;
    }
    if (kind == NILU_TNUMBER) nilu_pop(N, 1);
  }
  if (nilu_pushvalue(N, file_index) != NILU_OK) return raise_memory(N);
  return 1;
}

static int file_write(NiluState *N) {
  registered = "write";
  File *file;
  int status = to_file(N, 1, &file);
  if (status != NILU_OK) return status;
  return write_values(N, file->stream, 1, 2, 0);
}

static int file_flush(NiluState *N) {
  registered = "flush";
  File *file;
  int status = to_file(N, 1, &file);
  if (status != NILU_OK) return status;
  return file_result(N, fflush(file->stream) == 0, NULL);
}

static int file_seek(NiluState *N) {
  registered = "seek";
  static const char *const names[] = {"set", "cur", "end"};
  static const int modes[] = {SEEK_SET, SEEK_CUR, SEEK_END};
  File *file;
  const char *whence = "cur";
  size_t length = 0;
  long long offset = 0;
  int status = to_file(N, 1, &file);
  int which;
  if (status != NILU_OK) return status;
  if (!absent(N, 2)) {
    status = check_string(N, 2, &whence, &length);
    if (status != NILU_OK) return status;
  }
  for (which = 0; which < 3; which++) {
    if (strcmp(whence, names[which]) == 0) break;
  }
  if (which == 3) {
    char detail[160];
    snprintf(detail, sizeof detail, "invalid option '%s'", whence);
    return arg_error(N, 2, detail);
  }
  status = opt_integer(N, 3, 0, &offset);
  if (status != NILU_OK) return status;
  if (fseek(file->stream, (long)offset, modes[which]) != 0) return file_result(N, 0, NULL);
  if (nilu_pushinteger(N, ftell(file->stream)) != NILU_OK) return raise_memory(N);
  return 1;
}

static int file_setvbuf(NiluState *N) {
  registered = "setvbuf";
  static const char *const names[] = {"no", "full", "line"};
  static const int modes[] = {_IONBF, _IOFBF, _IOLBF};
  File *file;
  const char *mode;
  size_t length = 0;
  long long size = BUFSIZ;
  int status = to_file(N, 1, &file);
  int which;
  if (status != NILU_OK) return status;
  status = check_string(N, 2, &mode, &length);
  if (status != NILU_OK) return status;
  for (which = 0; which < 3; which++) {
    if (strcmp(mode, names[which]) == 0) break;
  }
  if (which == 3) {
    char detail[160];
    snprintf(detail, sizeof detail, "invalid option '%s'", mode);
    return arg_error(N, 2, detail);
  }
  status = opt_integer(N, 3, BUFSIZ, &size);
  if (status != NILU_OK) return status;
  return file_result(N, setvbuf(file->stream, NULL, modes[which], (size_t)size) == 0, NULL);
}

/* ── lines ────────────────────────────────────────────────────────────────── */

#define MAX_LINE_FORMATS 250

/* The iterator's upvalues: the file, whether the iterator owns it (io.lines
 * with a name closes it at the end), the number of formats, then the formats. */
static int lines_step(NiluState *N) {
  registered = "lines";
  File *file;
  int count;
  int i;
  int results;
  int owns;
  if (nilu_getupvalue(N, 2) != NILU_OK) return raise_memory(N);
  file = as_file(N, -1);
  if (file == NULL || file->closed) return raise_message(N, "file is already closed");
  nilu_pop(N, 1);
  if (nilu_getupvalue(N, 3) != NILU_OK) return raise_memory(N);
  owns = nilu_toboolean(N, -1);
  nilu_pop(N, 1);
  if (nilu_getupvalue(N, 4) != NILU_OK) return raise_memory(N);
  count = (int)nilu_tonumber(N, -1);
  nilu_pop(N, 1);
  /* The formats are read from argument 2 on, so the stack is rebuilt as read_formats expects. */
  if (nilu_settop(N, 0) != NILU_OK) return raise_memory(N);
  if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
  for (i = 0; i < count; i++) {
    if (nilu_getupvalue(N, 5 + i) != NILU_OK) return raise_memory(N);
  }
  results = read_formats(N, file->stream, 2, 1);
  if (results == NILU_FAIL) return results;
  if (results >= 3 && nilu_type(N, -results) == NILU_TNIL && nilu_type(N, -results + 1) == NILU_TSTRING) {
    /* A stream failure: io_readline raises the reason instead of answering it. */
    return raise_message(N, nilu_tostring(N, -results + 1));
  }
  if (nilu_type(N, -results) != NILU_TNIL) return results;
  if (owns) {
    if (nilu_getupvalue(N, 2) != NILU_OK) return raise_memory(N);
    file = as_file(N, -1);
    if (file != NULL && !file->closed) {
      forget(file->stream);
      fclose(file->stream);
      file->closed = 1;
      file->stream = NULL;
    }
    nilu_pop(N, 1);
  }
  return 0;
}

/* Builds the iterator over the file at `file_index` with the formats from
 * argument `first`. */
static int push_lines(NiluState *N, int file_index, int first, int owns) {
  int count = nilu_gettop(N) - first + 1;
  int i;
  if (count < 0) count = 0;
  if (count > MAX_LINE_FORMATS) return arg_error(N, MAX_LINE_FORMATS + 2, "too many arguments");
  if (shared(N) != NILU_OK || nilu_pushvalue(N, file_index) != NILU_OK || nilu_pushboolean(N, owns) != NILU_OK ||
      nilu_pushinteger(N, count) != NILU_OK)
    return raise_memory(N);
  for (i = 0; i < count; i++) {
    if (nilu_pushvalue(N, first + i) != NILU_OK) return raise_memory(N);
  }
  if (nilu_pushcclosure(N, lines_step, 4 + count) != NILU_OK) return raise_memory(N);
  return 1;
}

static int file_lines(NiluState *N) {
  registered = "lines";
  File *file;
  int status = to_file(N, 1, &file);
  if (status != NILU_OK) return status;
  return push_lines(N, 1, 2, 0);
}

/* ── io ───────────────────────────────────────────────────────────────────── */

/* Lua's l_checkmode: r, w or a, an optional +, then only b. */
static int valid_mode(const char *mode) {
  if (*mode == '\0' || strchr("rwa", *mode) == NULL) return 0;
  mode++;
  if (*mode == '+') mode++;
  return strspn(mode, "b") == strlen(mode);
}

static int check_path(NiluState *N, int index, const char **path) {
  size_t length = 0;
  int status = check_string(N, index, path, &length);
  if (status != NILU_OK) return status;
  if (strlen(*path) != length) return arg_error(N, index, "a path cannot hold a zero byte");
  return NILU_OK;
}

static int io_open(NiluState *N) {
  registered = "open";
  const char *path;
  const char *mode = "r";
  size_t length = 0;
  FILE *stream;
  int status = check_path(N, 1, &path);
  if (status != NILU_OK) return status;
  if (!absent(N, 2)) {
    status = check_string(N, 2, &mode, &length);
    if (status != NILU_OK) return status;
  }
  if (!valid_mode(mode)) return arg_error(N, 2, "invalid mode");
  stream = fopen(path, mode);
  if (stream == NULL) return file_result(N, 0, path);
  if (push_file(N, stream, 0) != NILU_OK) {
    fclose(stream);
    return raise_memory(N);
  }
  return 1;
}

/* io.popen(prog [, mode]): a file reading the program's output ("r", the
 * default) or writing its input ("w"); closing it answers its exit status. */
static int io_popen(NiluState *N) {
  registered = "popen";
  const char *program;
  const char *mode = "r";
  size_t length = 0;
  FILE *stream;
  File *file;
  int status = check_string(N, 1, &program, &length);
  if (status != NILU_OK) return status;
  if (!absent(N, 2)) {
    status = check_string(N, 2, &mode, &length);
    if (status != NILU_OK) return status;
  }
  if (strcmp(mode, "r") != 0 && strcmp(mode, "w") != 0) return arg_error(N, 2, "invalid mode");
  fflush(NULL); /* what was written before comes before what the program writes */
  stream = popen(program, mode);
  if (stream == NULL) return file_result(N, 0, program);
  if (push_file(N, stream, 0) != NILU_OK) {
    pclose(stream);
    return raise_memory(N);
  }
  file = (File *)nilu_touserdata(N, -1);
  file->pipe = 1;
  forget(stream);
  remember(stream, 1);
  return 1;
}

static int io_tmpfile(NiluState *N) {
  registered = "tmpfile";
  FILE *stream = tmpfile();
  if (stream == NULL) return file_result(N, 0, NULL);
  if (push_file(N, stream, 0) != NILU_OK) {
    fclose(stream);
    return raise_memory(N);
  }
  return 1;
}

static int io_type(NiluState *N) {
  registered = "type";
  File *file;
  if (nilu_type(N, 1) == NILU_TNONE) return arg_error(N, 1, "value expected");
  file = as_file(N, 1);
  if (file == NULL) {
    if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
  } else if (nilu_pushstring(N, file->closed ? "closed file" : "file") != NILU_OK) {
    return raise_memory(N);
  }
  return 1;
}

/* Pushes the current input or output; a closed one is refused with getiofile's words. */
static int current_file(NiluState *N, const char *key, File **file) {
  if (shared_get(N, key) != NILU_OK) return raise_memory(N);
  *file = as_file(N, -1);
  if (*file == NULL) return raise_memory(N);
  if ((*file)->closed) {
    char message[64];
    snprintf(message, sizeof message, "default %s file is closed", key);
    return raise_message(N, message);
  }
  return NILU_OK;
}

static int io_write(NiluState *N) {
  registered = "write";
  File *file;
  int status = current_file(N, "output", &file);
  int count = nilu_gettop(N);
  if (status != NILU_OK) return status;
  nilu_insert(N, 1);
  /* The file now sits at 1 and the values follow it. */
  (void)count;
  return write_values(N, file->stream, 1, 2, 1);
}

static int io_read(NiluState *N) {
  registered = "read";
  File *file;
  int status = current_file(N, "input", &file);
  if (status != NILU_OK) return status;
  nilu_insert(N, 1);
  return read_formats(N, file->stream, 2, 1);
}

/* io.input / io.output: look at the pair, or replace it by a file or a name. */
static int io_current(NiluState *N, const char *key, const char *mode) {
  if (!absent(N, 1)) {
    if (nilu_type(N, 1) == NILU_TSTRING) {
      const char *path;
      FILE *stream;
      int status = check_path(N, 1, &path);
      if (status != NILU_OK) return status;
      stream = fopen(path, mode);
      if (stream == NULL) {
        char message[512];
        snprintf(message, sizeof message, "cannot open file '%s' (%s)", path, strerror(errno));
        return raise_message(N, message);
      }
      if (push_file(N, stream, 0) != NILU_OK) {
        fclose(stream);
        return raise_memory(N);
      }
    } else {
      File *file;
      int status = to_file(N, 1, &file);
      if (status != NILU_OK) return status;
      if (nilu_pushvalue(N, 1) != NILU_OK) return raise_memory(N);
    }
    if (shared_set(N, key) != NILU_OK) return raise_memory(N);
  }
  if (shared_get(N, key) != NILU_OK) return raise_memory(N);
  return 1;
}
static int io_input(NiluState *N) {
  registered = "input";
  return io_current(N, "input", "r");
}
static int io_output(NiluState *N) {
  registered = "output";
  return io_current(N, "output", "w");
}

static int io_close(NiluState *N) {
  registered = "close";
  File *file;
  if (nilu_type(N, 1) == NILU_TNONE) {
    if (shared_get(N, "output") != NILU_OK) return raise_memory(N);
    file = as_file(N, -1);
    if (file == NULL) return raise_memory(N);
    if (file->closed) return raise_message(N, "attempt to use a closed file");
    return close_file(N, file);
  }
  return file_close(N);
}

static int io_flush(NiluState *N) {
  registered = "flush";
  File *file;
  int status = current_file(N, "output", &file);
  if (status != NILU_OK) return status;
  return file_result(N, fflush(file->stream) == 0, NULL);
}

static int io_lines(NiluState *N) {
  registered = "lines";
  if (absent(N, 1)) {
    File *file;
    int status;
    if (nilu_type(N, 1) == NILU_TNONE && nilu_pushnil(N) != NILU_OK) return raise_memory(N);
    status = current_file(N, "input", &file);
    if (status != NILU_OK) return status;
    nilu_insert(N, 1);
    nilu_remove(N, 2);
    return push_lines(N, 1, 2, 0);
  } else {
    const char *path;
    FILE *stream;
    int status = check_path(N, 1, &path);
    if (status != NILU_OK) return status;
    stream = fopen(path, "r");
    if (stream == NULL) {
      char message[512];
      snprintf(message, sizeof message, "cannot open file '%s' (%s)", path, strerror(errno));
      return raise_message(N, message);
    }
    if (push_file(N, stream, 0) != NILU_OK) {
      fclose(stream);
      return raise_memory(N);
    }
    nilu_insert(N, 1);
    nilu_remove(N, 2);
    /* The iterator, two nils and the file, which a generic `for` closes when
     * it ends however it ends, as Lua's io.lines(filename) answers. */
    if (push_lines(N, 1, 2, 1) != 1) return NILU_FAIL;
    if (nilu_pushnil(N) != NILU_OK || nilu_pushnil(N) != NILU_OK || nilu_pushvalue(N, 1) != NILU_OK) return raise_memory(N);
    return 4;
  }
}

/* ── os ───────────────────────────────────────────────────────────────────── */

static int os_clock(NiluState *N) {
  registered = "clock";
  if (nilu_pushnumber(N, (double)clock() / (double)CLOCKS_PER_SEC) != NILU_OK) return raise_memory(N);
  return 1;
}

static int os_getenv(NiluState *N) {
  registered = "getenv";
  const char *name;
  size_t length = 0;
  const char *value;
  int status = check_string(N, 1, &name, &length);
  if (status != NILU_OK) return status;
  value = getenv(name);
  if (value == NULL) {
    if (nilu_pushnil(N) != NILU_OK) return raise_memory(N);
  } else if (nilu_pushstring(N, value) != NILU_OK) {
    return raise_memory(N);
  }
  return 1;
}

static int exec_result(NiluState *N, int stat) {
  const char *what = "exit";
  if (stat == -1) return file_result(N, 0, NULL);
#ifndef _WIN32
  if (WIFEXITED(stat)) {
    stat = WEXITSTATUS(stat);
  } else if (WIFSIGNALED(stat)) {
    stat = WTERMSIG(stat);
    what = "signal";
  }
#endif
  if (strcmp(what, "exit") == 0 && stat == 0) {
    if (nilu_pushboolean(N, 1) != NILU_OK) return raise_memory(N);
  } else if (nilu_pushnil(N) != NILU_OK) {
    return raise_memory(N);
  }
  if (nilu_pushstring(N, what) != NILU_OK || nilu_pushinteger(N, stat) != NILU_OK) return raise_memory(N);
  return 3;
}

/* os.execute([command]): without one, whether a shell is there; with one, its
 * exit status as luaL_execresult answers it. */
static int os_execute(NiluState *N) {
  registered = "execute";
  const char *command;
  size_t length = 0;
  int status;
  if (absent(N, 1)) {
    if (nilu_pushboolean(N, system(NULL) != 0) != NILU_OK) return raise_memory(N);
    return 1;
  }
  status = check_string(N, 1, &command, &length);
  if (status != NILU_OK) return status;
  fflush(NULL); /* what was written before comes before what the command writes */
  return exec_result(N, system(command));
}

static int os_remove(NiluState *N) {
  registered = "remove";
  const char *path;
  int status = check_path(N, 1, &path);
  if (status != NILU_OK) return status;
  return file_result(N, remove(path) == 0, path);
}

static int os_rename(NiluState *N) {
  registered = "rename";
  const char *from, *to;
  int status = check_path(N, 1, &from);
  if (status != NILU_OK) return status;
  status = check_path(N, 2, &to);
  if (status != NILU_OK) return status;
  return file_result(N, rename(from, to) == 0, NULL);
}

/* os.tmpname(): a name no file has yet, made (and left empty) as Lua's
 * mkstemp does. */
static int os_tmpname(NiluState *N) {
  registered = "tmpname";
#ifdef _WIN32
  char name[L_tmpnam];
  if (tmpnam(name) == NULL) return raise_message(N, "unable to generate a unique filename");
#else
  char name[] = "/tmp/lua_XXXXXX";
  int descriptor = mkstemp(name);
  if (descriptor == -1) return raise_message(N, "unable to generate a unique filename");
  close(descriptor);
#endif
  if (nilu_pushstring(N, name) != NILU_OK) return raise_memory(N);
  return 1;
}

/* os.difftime(t2, t1): t2 - t1 in seconds; Lua 5.5 needs both. */
static int os_difftime(NiluState *N) {
  registered = "difftime";
  long long later, earlier;
  int status = check_integer(N, 1, &later);
  if (status != NILU_OK) return status;
  status = check_integer(N, 2, &earlier);
  if (status != NILU_OK) return status;
  if (nilu_pushnumber(N, difftime((time_t)later, (time_t)earlier)) != NILU_OK) return raise_memory(N);
  return 1;
}

/* os.setlocale([locale [, category]]): the command never leaves the C locale
 * (the owner's answer), so it answers "C" for a query and
 * for "C", "POSIX" and "" (Lua's "" adopts the environment's, which the
 * command does not), and nil for any other, as Lua does for one it cannot
 * set. Nothing changes; the category is checked as Lua checks it. */
static int os_setlocale(NiluState *N) {
  static const char *const categories[] = {"all", "collate", "ctype", "monetary", "numeric", "time"};
  const char *locale = NULL, *category = "all";
  size_t length;
  int status, which;
  registered = "setlocale";
  if (!absent(N, 1)) {
    status = check_string(N, 1, &locale, &length);
    if (status != NILU_OK) return status;
  }
  if (!absent(N, 2)) {
    status = check_string(N, 2, &category, &length);
    if (status != NILU_OK) return status;
  }
  for (which = 0; which < 6; which++) {
    if (strcmp(category, categories[which]) == 0) break;
  }
  if (which == 6) {
    char detail[160];
    snprintf(detail, sizeof detail, "invalid option '%.120s'", category);
    return arg_error(N, 2, detail);
  }
  if (locale == NULL || strcmp(locale, "C") == 0 || strcmp(locale, "POSIX") == 0 || locale[0] == '\0') {
    if (nilu_pushstring(N, "C") != NILU_OK) return raise_memory(N);
  } else if (nilu_pushnil(N) != NILU_OK) {
    return raise_memory(N);
  }
  return 1;
}

static NiluState *exiting_state = NULL;

static int os_exit(NiluState *N) {
  registered = "exit";
  int code = EXIT_SUCCESS;
  int close_state = 0;
  if (nilu_type(N, 1) == NILU_TBOOLEAN) {
    code = nilu_toboolean(N, 1) ? EXIT_SUCCESS : EXIT_FAILURE;
  } else {
    long long value;
    int status = opt_integer(N, 1, EXIT_SUCCESS, &value);
    if (status != NILU_OK) return status;
    code = (int)value;
  }
  close_state = nilu_toboolean(N, 2);
  fflush(stdout);
  fflush(stderr);
  close_open_files();
  if (close_state) nilu_close(N);
  exiting_state = NULL;
  exit(code);
}

/* Lua's C99 list for strftime, with the E and O modifiers. */
static const char *const date_options = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%|EcECExEXEyEY|OdOeOHOIOmOMOSOuOUOVOwOWOy";

static int set_field(NiluState *N, const char *key, NiluInteger value) {
  if (nilu_pushstring(N, key) != NILU_OK || nilu_pushinteger(N, value) != NILU_OK) return NILU_FAIL;
  return nilu_settable(N, -3);
}
static int set_boolean_field(NiluState *N, const char *key, int value) {
  if (nilu_pushstring(N, key) != NILU_OK || nilu_pushboolean(N, value) != NILU_OK) return NILU_FAIL;
  return nilu_settable(N, -3);
}

/* The nine fields, counting from 1 where C counts from 0. */
static int push_date_table(NiluState *N, const struct tm *stm) {
  if (nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  if (set_field(N, "year", stm->tm_year + 1900) != NILU_OK || set_field(N, "month", stm->tm_mon + 1) != NILU_OK ||
      set_field(N, "day", stm->tm_mday) != NILU_OK || set_field(N, "hour", stm->tm_hour) != NILU_OK ||
      set_field(N, "min", stm->tm_min) != NILU_OK || set_field(N, "sec", stm->tm_sec) != NILU_OK ||
      set_field(N, "wday", stm->tm_wday + 1) != NILU_OK || set_field(N, "yday", stm->tm_yday + 1) != NILU_OK ||
      set_boolean_field(N, "isdst", stm->tm_isdst > 0) != NILU_OK)
    return NILU_FAIL;
  return NILU_OK;
}

static int os_date(NiluState *N) {
  registered = "date";
  const char *format = "%c";
  size_t length = 0;
  long long when;
  time_t t;
  struct tm *stm;
  int utc = 0;
  int status;
  if (!absent(N, 1)) {
    status = check_string(N, 1, &format, &length);
    if (status != NILU_OK) return status;
  }
  if (absent(N, 2)) {
    when = (long long)time(NULL);
  } else {
    double number;
    status = check_number(N, 2, &number);
    if (status != NILU_OK) return status;
    if (number != floor(number)) return arg_error(N, 2, "number has no integer representation");
    if (fabs(number) >= 9223372036854775808.0) return raise_message(N, "date result cannot be represented in this installation");
    when = (long long)number;
  }
  if (format[0] == '!') {
    utc = 1;
    format++;
  }
  t = (time_t)when;
  stm = utc ? gmtime(&t) : localtime(&t);
  if (stm == NULL) return raise_message(N, "date result cannot be represented in this installation");
  if (strcmp(format, "*t") == 0) {
    if (push_date_table(N, stm) != NILU_OK) return raise_memory(N);
    return 1;
  } else {
    /* The whole format is checked before any of it is used (manual 11.4.4). */
    const char *at;
    char piece[4];
    char out[256];
    char *result = NULL;
    size_t result_length = 0;
    for (at = format; *at != '\0'; at++) {
      if (*at != '%') continue;
      at++;
      if (*at == '\0') return arg_error(N, 1, "invalid conversion specifier '%'");
      if (*at == 'E' || *at == 'O') {
        char pair[3] = {*at, at[1], '\0'};
        const char *found = at[1] == '\0' ? NULL : strstr(date_options, pair);
        if (found == NULL || found < strchr(date_options, '|')) {
          char detail[64];
          snprintf(detail, sizeof detail, "invalid conversion specifier '%%%s'", pair);
          return arg_error(N, 1, detail);
        }
        at++;
      } else if (strchr(date_options, *at) == NULL || *at == '|') {
        char detail[64];
        snprintf(detail, sizeof detail, "invalid conversion specifier '%%%c'", *at);
        return arg_error(N, 1, detail);
      }
    }
    for (at = format; *at != '\0'; at++) {
      size_t got;
      size_t index = 0;
      char *grown;
      piece[index++] = '%';
      if (*at != '%') {
        /* Literal bytes travel as they are; only conversions go through strftime. */
        grown = realloc(result, result_length + 2);
        if (grown == NULL) {
          free(result);
          return raise_memory(N);
        }
        result = grown;
        result[result_length++] = *at;
        continue;
      }
      at++;
      piece[index++] = *at;
      if (*at == 'E' || *at == 'O') {
        at++;
        piece[index++] = *at;
      }
      piece[index] = '\0';
      got = strftime(out, sizeof out, piece, stm);
      if (got == 0 && strcmp(piece, "%p") != 0) out[0] = '\0';
      grown = realloc(result, result_length + got + 1);
      if (grown == NULL) {
        free(result);
        return raise_memory(N);
      }
      result = grown;
      memcpy(result + result_length, out, got);
      result_length += got;
    }
    if (nilu_pushlstring(N, result == NULL ? "" : result, result_length) != NILU_OK) {
      free(result);
      return raise_memory(N);
    }
    free(result);
    return 1;
  }
}

/* Lua's getfield for os.time: a missing required field, a field that is not
 * an integer, and one outside an int are each said by name. */
static int get_field(NiluState *N, const char *key, int fallback, int delta, int *value) {
  int kind;
  int is_integer = 0;
  NiluInteger number;
  if (nilu_pushstring(N, key) != NILU_OK) return raise_memory(N);
  if (nilu_gettable(N, 1) != NILU_OK) return nilu_error(N);
  kind = nilu_type(N, -1);
  if (kind == NILU_TNIL) {
    char message[64];
    nilu_pop(N, 1);
    if (fallback >= 0) {
      *value = fallback;
      return NILU_OK;
    }
    snprintf(message, sizeof message, "field '%s' missing in date table", key);
    return raise_message(N, message);
  }
  number = nilu_tointegerx(N, -1, &is_integer);
  if (!is_integer) {
    char message[64];
    nilu_pop(N, 1);
    snprintf(message, sizeof message, "field '%s' is not an integer", key);
    return raise_message(N, message);
  }
  nilu_pop(N, 1);
  /* Lua's test, which no subtraction can overflow. */
  if (!(number >= 0 ? number - delta <= INT_MAX : (NiluInteger)INT_MIN + delta <= number)) {
    char message[64];
    snprintf(message, sizeof message, "field '%s' is out-of-bound", key);
    return raise_message(N, message);
  }
  *value = (int)number - delta;
  return NILU_OK;
}

static int os_time(NiluState *N) {
  registered = "time";
  time_t t;
  if (absent(N, 1)) {
    t = time(NULL);
  } else {
    struct tm stm;
    int status;
    int isdst_kind;
    if (nilu_type(N, 1) != NILU_TTABLE) return type_error(N, 1, "table");
    if (nilu_settop(N, 1) != NILU_OK) return raise_memory(N);
    memset(&stm, 0, sizeof stm);
    if ((status = get_field(N, "year", -1, 1900, &stm.tm_year)) != NILU_OK) return status;
    if ((status = get_field(N, "month", -1, 1, &stm.tm_mon)) != NILU_OK) return status;
    if ((status = get_field(N, "day", -1, 0, &stm.tm_mday)) != NILU_OK) return status;
    if ((status = get_field(N, "hour", 12, 0, &stm.tm_hour)) != NILU_OK) return status;
    if ((status = get_field(N, "min", 0, 0, &stm.tm_min)) != NILU_OK) return status;
    if ((status = get_field(N, "sec", 0, 0, &stm.tm_sec)) != NILU_OK) return status;
    if (nilu_pushstring(N, "isdst") != NILU_OK) return raise_memory(N);
    if (nilu_gettable(N, 1) != NILU_OK) return nilu_error(N);
    isdst_kind = nilu_type(N, -1);
    stm.tm_isdst = isdst_kind == NILU_TNIL ? -1 : nilu_toboolean(N, -1);
    nilu_pop(N, 1);
    t = mktime(&stm);
    if (t == (time_t)-1) return raise_message(N, "time result cannot be represented in this installation");
    /* The normalised fields are written back, the three extra ones included. */
    if (nilu_pushvalue(N, 1) != NILU_OK) return raise_memory(N);
    if (set_field(N, "year", stm.tm_year + 1900) != NILU_OK || set_field(N, "month", stm.tm_mon + 1) != NILU_OK ||
        set_field(N, "day", stm.tm_mday) != NILU_OK || set_field(N, "hour", stm.tm_hour) != NILU_OK ||
        set_field(N, "min", stm.tm_min) != NILU_OK || set_field(N, "sec", stm.tm_sec) != NILU_OK ||
        set_field(N, "wday", stm.tm_wday + 1) != NILU_OK || set_field(N, "yday", stm.tm_yday + 1) != NILU_OK ||
        set_boolean_field(N, "isdst", stm.tm_isdst > 0) != NILU_OK)
      return raise_memory(N);
    nilu_pop(N, 1);
  }
  if (nilu_pushinteger(N, (NiluInteger)t) != NILU_OK) return raise_memory(N);
  return 1;
}

/* ── registration ─────────────────────────────────────────────────────────── */

typedef struct {
  const char *name;
  NiluCFunction function;
} Entry;

/* Registers closures over the shared table (at the top of the stack) into the
 * table below it. */
static int register_closures(NiluState *N, const Entry *entries) {
  const Entry *entry;
  for (entry = entries; entry->name != NULL; entry++) {
    if (nilu_pushstring(N, entry->name) != NILU_OK) return NILU_FAIL;
    if (nilu_pushvalue(N, -2) != NILU_OK) return NILU_FAIL;
    if (nilu_pushcclosure(N, entry->function, 1) != NILU_OK) return NILU_FAIL;
    if (nilu_settable(N, -4) != NILU_OK) return NILU_FAIL;
  }
  return NILU_OK;
}

static int open_io(NiluState *N) {
  static const Entry methods[] = {{"read", file_read},   {"write", file_write},     {"lines", file_lines},
                                  {"close", file_close}, {"flush", file_flush},     {"seek", file_seek},
                                  {"setvbuf", file_setvbuf}, {NULL, NULL}};
  static const Entry functions[] = {{"write", io_write},   {"read", io_read},     {"open", io_open},
                                    {"lines", io_lines},   {"close", io_close},   {"input", io_input},
                                    {"output", io_output}, {"flush", io_flush},   {"type", io_type},
                                    {"tmpfile", io_tmpfile}, {"popen", io_popen}, {NULL, NULL}};
  static const struct {
    const char *name;
    FILE *stream;
    int standard;
  } standards[] = {{"stdin", NULL, 1}, {"stdout", NULL, 2}, {"stderr", NULL, 3}};
  FILE *streams[3];
  int i;
  streams[0] = stdin;
  streams[1] = stdout;
  streams[2] = stderr;
  /* [io] [shared] [meta] */
  if (nilu_newtable(N) != NILU_OK || nilu_newtable(N) != NILU_OK || nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  if (nilu_pushstring(N, "__name") != NILU_OK || nilu_pushstring(N, "FILE*") != NILU_OK || nilu_settable(N, -3) != NILU_OK) return NILU_FAIL;
  /* __tostring and the methods are closures over the shared table too. */
  if (nilu_pushstring(N, "__tostring") != NILU_OK || nilu_pushvalue(N, -3) != NILU_OK ||
      nilu_pushcclosure(N, file_tostring, 1) != NILU_OK || nilu_settable(N, -3) != NILU_OK)
    return NILU_FAIL;
  if (nilu_pushstring(N, "__close") != NILU_OK || nilu_pushvalue(N, -3) != NILU_OK ||
      nilu_pushcclosure(N, file_close_value, 1) != NILU_OK || nilu_settable(N, -3) != NILU_OK)
    return NILU_FAIL;
  if (nilu_pushstring(N, "__index") != NILU_OK || nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  if (nilu_pushvalue(N, -4) != NILU_OK) return NILU_FAIL; /* [io] [shared] [meta] "__index" [methods] [shared] */
  if (register_closures(N, methods) != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1);
  if (nilu_settable(N, -3) != NILU_OK) return NILU_FAIL; /* meta.__index = methods */
  /* shared.meta = meta */
  if (nilu_pushstring(N, "meta") != NILU_OK || nilu_pushvalue(N, -2) != NILU_OK || nilu_rawset(N, -4) != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1); /* [io] [shared] */
  for (i = 0; i < 3; i++) {
    /* The shared table is upvalue 1 only inside a closure; here it is on the stack. */
    void *block = NULL;
    File *file;
    if (nilu_newuserdata(N, sizeof(File), &block) != NILU_OK) return NILU_FAIL;
    file = (File *)block;
    file->stream = streams[i];
    file->closed = 0;
    file->standard = standards[i].standard;
    if (nilu_pushstring(N, "meta") != NILU_OK || nilu_rawget(N, -3) != NILU_OK || nilu_setmetatable(N, -2) != NILU_OK) return NILU_FAIL;
    /* shared[name] = file, io[name] = file */
    if (nilu_pushstring(N, standards[i].name) != NILU_OK || nilu_pushvalue(N, -2) != NILU_OK || nilu_rawset(N, -4) != NILU_OK) return NILU_FAIL;
    if (nilu_pushstring(N, standards[i].name) != NILU_OK || nilu_pushvalue(N, -2) != NILU_OK || nilu_settable(N, -5) != NILU_OK) return NILU_FAIL;
    if (i == 0) {
      if (nilu_pushstring(N, "input") != NILU_OK || nilu_pushvalue(N, -2) != NILU_OK || nilu_rawset(N, -4) != NILU_OK) return NILU_FAIL;
    } else if (i == 1) {
      if (nilu_pushstring(N, "output") != NILU_OK || nilu_pushvalue(N, -2) != NILU_OK || nilu_rawset(N, -4) != NILU_OK) return NILU_FAIL;
    }
    nilu_pop(N, 1);
  }
  /* [io] [shared]: the functions go into io as closures over shared. */
  nilu_insert(N, -2); /* [shared] [io] */
  if (nilu_pushvalue(N, -2) != NILU_OK) return NILU_FAIL; /* [shared] [io] [shared] */
  if (register_closures(N, functions) != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1);
  if (nilu_setglobal(N, "io") != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1);
  return NILU_OK;
}

static int open_os(NiluState *N) {
  static const Entry functions[] = {{"clock", os_clock}, {"time", os_time}, {"date", os_date},
                                    {"getenv", os_getenv}, {"exit", os_exit}, {"execute", os_execute},
                                    {"remove", os_remove}, {"rename", os_rename}, {"tmpname", os_tmpname},
                                    {"difftime", os_difftime}, {"setlocale", os_setlocale}, {NULL, NULL}};
  const Entry *entry;
  if (nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  for (entry = functions; entry->name != NULL; entry++) {
    if (nilu_pushstring(N, entry->name) != NILU_OK || nilu_pushcfunction(N, entry->function) != NILU_OK ||
        nilu_settable(N, -3) != NILU_OK)
      return NILU_FAIL;
  }
  return nilu_setglobal(N, "os");
}

/* A fresh state's sequence is fixed (manual 10.4); the command seeds it from the
 * clock so that two runs differ, as Lua's does. */
static int seed_random(NiluState *N) {
  unsigned long long mixed = (unsigned long long)time(NULL) * 1000003ULL ^ (unsigned long long)clock() ^ (unsigned long long)(uintptr_t)&mixed;
  NiluInteger seed = (NiluInteger)(mixed & (unsigned long long)NILU_MAXINTEGER);
  if (nilu_getglobal(N, "math") != NILU_OK || nilu_pushstring(N, "randomseed") != NILU_OK || nilu_gettable(N, -2) != NILU_OK) return NILU_FAIL;
  if (nilu_pushinteger(N, seed) != NILU_OK || nilu_call(N, 1, 0) != NILU_OK) return NILU_FAIL;
  nilu_pop(N, 1);
  return NILU_OK;
}

/* ── running chunks and reporting failures ────────────────────────────────── */

/* The traceback the message handler collected for the last failure. */
static char *traceback = NULL;
static int traceback_frames = 0;

static int traceback_append(const char *line) {
  size_t have = traceback == NULL ? 0 : strlen(traceback);
  size_t more = strlen(line);
  char *grown = realloc(traceback, have + more + 1);
  if (grown == NULL) return 0;
  traceback = grown;
  memcpy(traceback + have, line, more + 1);
  return 1;
}

/* What luaL_traceback says a function is: the kind and name it was called by,
 * else "main chunk", else "function <source:line>" for a script function,
 * else "?" (pushfuncname). */
static void describe_function(NiluState *N, int level, const char *source, char *out, size_t size) {
  const char *namewhat = "";
  const char *name = nilu_callername(N, level, &namewhat);
  int defined = nilu_linedefined(N, level);
  if (name != NULL && namewhat[0] != '\0') snprintf(out, size, "%s '%s'", namewhat, name);
  else if (defined == 0) snprintf(out, size, "main chunk");
  else if (defined > 0) snprintf(out, size, "function <%s:%d>", source, defined);
  else snprintf(out, size, "?");
}

/* luaL_traceback's shape: every frame from the one that failed outward, with
 * the middle left out past 21 levels (10 from the top, 11 from the bottom). */
static int message_handler(NiluState *N) {
  int levels = 0;
  int level;
  int nilu_frames = 0;
  char line[512];
  char function[256];
  free(traceback);
  traceback = NULL;
  traceback_frames = 0;
  while (nilu_where(N, levels + 1, NULL) != NULL) levels++;
  for (level = 1; level <= levels; level++) {
    NiluError where;
    const char *name = nilu_where(N, level, &where);
    if (name == NULL) break;
    if (strcmp(name, "[C]") != 0) nilu_frames++;
  }
  for (level = 1; level <= levels; level++) {
    NiluError where;
    const char *name;
    if (levels > 21 && level == 11) {
      snprintf(line, sizeof line, "\n\t...\t(skipping %d levels)", levels - 21);
      if (!traceback_append(line)) break;
      level = levels - 11;
      continue;
    }
    name = nilu_where(N, level, &where);
    if (name == NULL) break;
    describe_function(N, level, name, function, sizeof function);
    if (strcmp(name, "[C]") == 0) snprintf(line, sizeof line, "\n\t[C]: in %s", function);
    else snprintf(line, sizeof line, "\n\t%s:%d: in %s", name, where.line, function);
    if (!traceback_append(line)) break;
  }
  traceback_frames = nilu_frames;
  return 1;
}

static const char *status_word(NiluStatus status) {
  switch (status) {
    case NILU_ERR_SYNTAX: return "syntax error";
    case NILU_ERR_TYPE: return "type error";
    case NILU_ERR_RUNTIME: return "runtime error";
    case NILU_ERR_CALL_DEPTH: return "too many nested calls";
    case NILU_ERR_MEMORY: return "out of memory";
    case NILU_ERR_STACK: return "the stack is full";
    case NILU_ERR_INTERRUPTED: return "interrupted";
    default: return "error";
  }
}

/* Writes what a failed call left behind (manual 11.3). `prefix` is the
 * program's name for a script and nothing at the prompt. */
static void report(NiluState *N, NiluStatus status, const char *prefix) {
  NiluError where;
  const char *location = nilu_where(N, 0, &where);
  int kind = nilu_gettop(N) > 0 ? nilu_type(N, -1) : NILU_TNONE;
  if (kind == NILU_TSTRING) {
    size_t length = 0;
    const char *text = nilu_tolstring(N, -1, &length);
    fputs(prefix, stderr);
    fwrite(text, 1, length, stderr);
  } else if (kind == NILU_TNIL || kind == NILU_TNONE) {
    fputs(prefix, stderr);
    if (location != NULL && where.line > 0) fprintf(stderr, "%s:%d: ", location, where.line);
    else if (location != NULL) fprintf(stderr, "%s: ", location);
    fputs(status_word(status), stderr);
  } else {
    fputs(prefix, stderr);
    if (location != NULL) fprintf(stderr, "%s: ", location);
    fputs(status_word(status), stderr);
    fprintf(stderr, "\n%s(error object is a %s value)", prefix, type_name(N, -1));
  }
  if (traceback != NULL && traceback_frames >= 2) {
    fputs("\nstack traceback:", stderr);
    fputs(traceback, stderr);
  }
  fputc('\n', stderr);
  fflush(stderr);
  free(traceback);
  traceback = NULL;
  traceback_frames = 0;
}

/* Runs the function at the top with `nargs` arguments under the message
 * handler, discarding results. Answers the status; a failure value stays on top. */
static NiluStatus protected_call(NiluState *N, int nargs, int nresults) {
  int base = nilu_gettop(N) - nargs;
  NiluStatus status;
  if (nilu_pushcfunction(N, message_handler) != NILU_OK) return NILU_ERR_MEMORY;
  nilu_insert(N, base);
  status = nilu_pcall(N, nargs, nresults, base);
  nilu_remove(N, base);
  return status;
}

/* Loads source under the chunk name and reports a refusal. */
static int load_source(NiluState *N, const char *source, const char *chunk_name, const char *display) {
  NiluError where;
  NiluStatus status = nilu_loadnamed(N, source, chunk_name, &where);
  if (status == NILU_OK) return 1;
  if (status == NILU_ERR_SYNTAX) {
    /* The chunk id in the sentence is bounded as Lua bounds it; the command
     * knows the whole path and says it, after the position the loader gave. */
    const char *text = nilu_tostring(N, -1);
    char tail[32];
    const char *rest = NULL;
    snprintf(tail, sizeof tail, ":%d:%d: ", where.line, where.column);
    if (text != NULL && where.line > 0 && chunk_name[0] == '@') rest = strstr(text, tail);
    if (rest != NULL) fprintf(stderr, PROGNAME ": %s%s%s\n", display, tail, rest + strlen(tail));
    else report(N, status, PROGNAME ": ");
    nilu_pop(N, 1);
  } else {
    fprintf(stderr, PROGNAME ": %s: %s\n", display, status_word(status));
  }
  return 0;
}

/* Runs loaded code with the arguments on top; 0 on failure, which is reported. */
static int run_loaded(NiluState *N, int nargs) {
  NiluStatus status = protected_call(N, nargs, 0);
  if (status != NILU_OK) {
    report(N, status, PROGNAME ": ");
    nilu_settop(N, 0);
    return 0;
  }
  nilu_settop(N, 0);
  return 1;
}

/* Reads a whole stream; a zero byte is refused since a source cannot hold one.
 * The first line is blanked when it starts with `#`, keeping its newline so
 * that the line numbers stay (manual 11.1). */
static char *read_source(FILE *stream, const char *display, int *refused) {
  Text text = {NULL, 0, 0};
  int byte;
  *refused = 0;
  while ((byte = fgetc(stream)) != EOF) {
    if (!text_push(&text, byte)) {
      free(text.bytes);
      fprintf(stderr, PROGNAME ": %s: out of memory\n", display);
      *refused = 1;
      return NULL;
    }
  }
  if (!text_push(&text, '\0')) {
    free(text.bytes);
    fprintf(stderr, PROGNAME ": %s: out of memory\n", display);
    *refused = 1;
    return NULL;
  }
  if (strlen(text.bytes) != text.length - 1) {
    free(text.bytes);
    fprintf(stderr, PROGNAME ": %s: a zero byte, which a source may not contain\n", display);
    *refused = 1;
    return NULL;
  }
  if (text.bytes[0] == '#') {
    char *newline = strchr(text.bytes, '\n');
    if (newline == NULL) text.bytes[0] = '\0';
    else memmove(text.bytes, newline, strlen(newline) + 1);
  }
  return text.bytes;
}

/* Builds `arg` the way lua.c's createargtable does: the script at 0. */
static int create_arg_table(NiluState *N, int argc, char **argv, int script) {
  int i;
  /* Without a script the program's name is arg[0] and the options follow it,
   * as Lua's lua.c does (the owner's answer). */
  if (script == argc) script = 0;
  if (nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  for (i = 0; i < argc; i++) {
    if (nilu_pushinteger(N, i - script) != NILU_OK || nilu_pushstring(N, argv[i]) != NILU_OK ||
        nilu_settable(N, -3) != NILU_OK)
      return NILU_FAIL;
  }
  return nilu_setglobal(N, "arg");
}

static int push_script_arguments(NiluState *N, int argc, char **argv, int first) {
  int i;
  for (i = first; i < argc; i++) {
    if (nilu_pushstring(N, argv[i]) != NILU_OK) return -1;
  }
  return argc - first;
}

/* ── the prompt ───────────────────────────────────────────────────────────── */

static int read_plain_line(Text *text) {
  int byte;
  text->length = 0;
  while ((byte = fgetc(stdin)) != EOF) {
    if (byte == '\n') return 1;
    if (!text_push(text, byte)) return 0;
  }
  return text->length > 0 ? 1 : 0;
}

#ifndef _WIN32
/* The lines given this session, oldest first, for the arrow keys. Kept in
 * memory only (the owner's answer). */
static char **history = NULL;
static size_t history_count = 0;

static void remember_line(const Text *text) {
  char **grown;
  char *copy;
  if (text->length == 0) return;
  if (history_count > 0 && strlen(history[history_count - 1]) == text->length &&
      memcmp(history[history_count - 1], text->bytes, text->length) == 0)
    return;
  grown = realloc(history, (history_count + 1) * sizeof *grown);
  if (grown == NULL) return;
  history = grown;
  copy = malloc(text->length + 1);
  if (copy == NULL) return;
  memcpy(copy, text->bytes, text->length);
  copy[text->length] = '\0';
  history[history_count++] = copy;
}

static void forget_history(void) {
  while (history_count > 0) free(history[--history_count]);
  free(history);
  history = NULL;
}

/* ── a small line editor, on a terminal only ──────────────────────────────── */

/* How many columns a code point takes: two for the East Asian wide ranges,
 * none for a combining mark, one otherwise. */
static int columns_of(unsigned long point) {
  if (point >= 0x0300 && point <= 0x036F) return 0;
  if ((point >= 0x1100 && point <= 0x115F) || (point >= 0x2E80 && point <= 0xA4CF) ||
      (point >= 0xAC00 && point <= 0xD7A3) || (point >= 0xF900 && point <= 0xFAFF) ||
      (point >= 0xFE30 && point <= 0xFE4F) || (point >= 0xFF00 && point <= 0xFF60) ||
      (point >= 0xFFE0 && point <= 0xFFE6) || (point >= 0x1F300 && point <= 0x1FAFF) ||
      (point >= 0x20000 && point <= 0x3FFFD))
    return 2;
  return 1;
}

static int is_continuation(int byte) { return (byte & 0xC0) == 0x80; }

/* The columns the bytes take, decoding UTF-8; a malformed byte takes one. */
static int text_columns(const char *bytes, size_t length) {
  size_t i = 0;
  int total = 0;
  while (i < length) {
    unsigned char lead = (unsigned char)bytes[i];
    unsigned long point = lead;
    size_t extra = lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0;
    size_t k;
    if (extra > 0 && i + extra < length + 1) {
      point = lead & (0x3F >> extra);
      for (k = 1; k <= extra && i + k < length && is_continuation((unsigned char)bytes[i + k]); k++)
        point = (point << 6) | ((unsigned char)bytes[i + k] & 0x3F);
      if (k <= extra) extra = k - 1;
    }
    total += columns_of(point);
    i += 1 + extra;
  }
  return total;
}

static void redraw(const char *prompt_text, const Text *text, size_t cursor) {
  int behind;
  fputs("\r", stdout);
  fputs(prompt_text, stdout);
  fwrite(text->bytes, 1, text->length, stdout);
  fputs("\x1b[K", stdout);
  behind = text_columns(text->bytes + cursor, text->length - cursor);
  if (behind > 0) printf("\x1b[%dD", behind);
  fflush(stdout);
}

static int set_text(Text *text, const char *bytes) {
  size_t i;
  text->length = 0;
  for (i = 0; bytes[i] != '\0'; i++) {
    if (!text_push(text, bytes[i])) return 0;
  }
  return 1;
}

/* Left/Right and Home/End (also Ctrl-A/Ctrl-E) move by characters,
 * Backspace and Delete (also Ctrl-D on a line) delete one, Up/Down walk the
 * session's history, Ctrl-C drops the line, Ctrl-D on an empty line ends the
 * input. Any other key is typed. Lines longer than the terminal are not
 * redrawn across its edge. */
static int edit_line(Text *text, const char *prompt_text) {
  struct termios saved, raw;
  size_t cursor = 0;
  size_t walk = history_count;
  int result = 1;
  text->length = 0;
  if (tcgetattr(STDIN_FILENO, &saved) != 0) return read_plain_line(text);
  raw = saved;
  raw.c_lflag &= ~(tcflag_t)(ICANON | ECHO | ISIG | IEXTEN);
  raw.c_iflag &= ~(tcflag_t)(IXON | ICRNL);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return read_plain_line(text);
  for (;;) {
    int byte = fgetc(stdin);
    if (byte == EOF) {
      result = text->length > 0;
      break;
    }
    if (byte == '\r' || byte == '\n') break;
    if (byte == 3) { /* Ctrl-C */
      fputs("^C\r\n", stdout);
      text->length = 0;
      cursor = 0;
      walk = history_count;
      redraw(prompt_text, text, cursor);
      continue;
    }
    if (byte == 4 && text->length == 0) { /* Ctrl-D on an empty line */
      result = 0;
      break;
    }
    if (byte == 1) cursor = 0;
    else if (byte == 5) cursor = text->length;
    else if (byte == 127 || byte == 8) {
      size_t start = cursor;
      if (start > 0) {
        do start--; while (start > 0 && is_continuation((unsigned char)text->bytes[start]));
        memmove(text->bytes + start, text->bytes + cursor, text->length - cursor);
        text->length -= cursor - start;
        cursor = start;
      }
    } else if (byte == 4) {
      size_t end = cursor;
      if (end < text->length) {
        do end++; while (end < text->length && is_continuation((unsigned char)text->bytes[end]));
        memmove(text->bytes + cursor, text->bytes + end, text->length - end);
        text->length -= end - cursor;
      }
    } else if (byte == 27) {
      int first = fgetc(stdin);
      int code = fgetc(stdin);
      if (first == '[' && code >= '0' && code <= '9') {
        int tilde = fgetc(stdin);
        if (tilde != '~') continue;
        if (code == '1' || code == '7') code = 'H';
        else if (code == '4' || code == '8') code = 'F';
        else if (code == '3') code = 'X';
        else continue;
      } else if (first != '[' && first != 'O') {
        continue;
      }
      if (code == 'D' && cursor > 0) {
        do cursor--; while (cursor > 0 && is_continuation((unsigned char)text->bytes[cursor]));
      } else if (code == 'C' && cursor < text->length) {
        do cursor++; while (cursor < text->length && is_continuation((unsigned char)text->bytes[cursor]));
      } else if (code == 'H') {
        cursor = 0;
      } else if (code == 'F') {
        cursor = text->length;
      } else if (code == 'X' && cursor < text->length) {
        size_t end = cursor;
        do end++; while (end < text->length && is_continuation((unsigned char)text->bytes[end]));
        memmove(text->bytes + cursor, text->bytes + end, text->length - end);
        text->length -= end - cursor;
      } else if ((code == 'A' && walk > 0) || (code == 'B' && walk < history_count)) {
        walk = code == 'A' ? walk - 1 : walk + 1;
        if (!set_text(text, walk < history_count ? history[walk] : "")) {
          result = 0;
          break;
        }
        cursor = text->length;
      }
    } else if (byte >= 32 || byte == '\t') {
      if (!text_push(text, byte)) {
        result = 0;
        break;
      }
      if (cursor < text->length - 1) {
        memmove(text->bytes + cursor + 1, text->bytes + cursor, text->length - 1 - cursor);
        text->bytes[cursor] = (char)byte;
      }
      cursor++;
      /* A character arrives a byte at a time: draw it once it is whole. */
      if (byte >= 0x80) {
        size_t lead = cursor - 1;
        unsigned char first;
        size_t need;
        while (lead > 0 && is_continuation((unsigned char)text->bytes[lead])) lead--;
        first = (unsigned char)text->bytes[lead];
        need = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1;
        if (cursor - lead < need) continue;
      }
    }
    redraw(prompt_text, text, cursor);
  }
  tcsetattr(STDIN_FILENO, TCSANOW, &saved);
  fputs("\r\n", stdout);
  fflush(stdout);
  if (result) remember_line(text);
  return result;
}
#endif

/* Prints the prompt and reads a line: with the editor when both ends are a
 * terminal, plainly otherwise (a pipe, a file, the Windows console, which
 * edits lines itself). */
static int read_prompt_line(Text *text, const char *prompt_text) {
  fputs(prompt_text, stdout);
  fflush(stdout);
#ifndef _WIN32
  if (isatty(STDIN_FILENO) && isatty(STDOUT_FILENO)) return edit_line(text, prompt_text);
#endif
  return read_plain_line(text);
}

static int ends_with_eof(const char *message) {
  size_t length = strlen(message);
  return length >= 5 && strcmp(message + length - 5, "<eof>") == 0;
}

static void prompt_print_results(NiluState *N, int count) {
  NiluStatus status;
  if (count == 0) return;
  if (nilu_getglobal(N, "print") != NILU_OK) {
    nilu_settop(N, 0);
    return;
  }
  nilu_insert(N, 1);
  status = nilu_pcall(N, count, 0, 0);
  if (status != NILU_OK) {
    fprintf(stderr, "error calling 'print' (%s)\n", status_word(status));
    fflush(stderr);
  }
  nilu_settop(N, 0);
}

static void prompt(NiluState *N) {
  Text line = {NULL, 0, 0};
  Text statement = {NULL, 0, 0};
  for (;;) {
    NiluStatus status;
    if (!read_prompt_line(&line, "> ")) break;
    if (!text_push(&line, '\0')) break;
    if (strncmp(line.bytes, "local ", 6) == 0 || strncmp(line.bytes, "local\t", 6) == 0) {
      fputs("warning: locals do not survive across lines in interactive mode\n", stderr);
      fflush(stderr);
    }
    /* First as an expression: `return <line>;`. */
    statement.length = 0;
    {
      const char *head = "return ";
      const char *p;
      for (p = head; *p != '\0'; p++) text_push(&statement, *p);
      for (p = line.bytes; *p != '\0'; p++) text_push(&statement, *p);
      text_push(&statement, ';');
      text_push(&statement, '\0');
    }
    status = nilu_loadnamed(N, statement.bytes, "=stdin", NULL);
    if (status == NILU_OK) {
      int before = nilu_gettop(N) - 1;
      status = protected_call(N, 0, NILU_MULTRET);
      if (status != NILU_OK) {
        report(N, status, "");
        nilu_settop(N, 0);
      } else {
        prompt_print_results(N, nilu_gettop(N) - before);
      }
      continue;
    }
    nilu_settop(N, 0);
    /* Then as a statement, reading more while the text ends early. */
    statement.length = 0;
    {
      const char *p;
      for (p = line.bytes; *p != '\0'; p++) text_push(&statement, *p);
      text_push(&statement, '\0');
    }
    for (;;) {
      status = nilu_loadnamed(N, statement.bytes, "=stdin", NULL);
      if (status == NILU_OK) break;
      if (status == NILU_ERR_SYNTAX && ends_with_eof(nilu_tostring(N, -1))) {
        nilu_settop(N, 0);
        if (!read_prompt_line(&line, ">> ")) {
          /* Nothing more: the refusal stands as it was. */
          status = nilu_loadnamed(N, statement.bytes, "=stdin", NULL);
          break;
        }
        text_push(&line, '\0');
        statement.length--;
        text_push(&statement, '\n');
        {
          const char *p;
          for (p = line.bytes; *p != '\0'; p++) text_push(&statement, *p);
          text_push(&statement, '\0');
        }
        continue;
      }
      break;
    }
    if (status != NILU_OK) {
      report(N, status, "");
      nilu_settop(N, 0);
      continue;
    }
    {
      int before = nilu_gettop(N) - 1;
      status = protected_call(N, 0, NILU_MULTRET);
      if (status != NILU_OK) {
        report(N, status, "");
        nilu_settop(N, 0);
      } else {
        prompt_print_results(N, nilu_gettop(N) - before);
      }
    }
  }
  fputc('\n', stdout);
  fflush(stdout);
  free(line.bytes);
  free(statement.bytes);
#ifndef _WIN32
  forget_history();
#endif
}

/* ── main ─────────────────────────────────────────────────────────────────── */

static int fail_usage(const char *message) {
  fprintf(stderr, PROGNAME ": %s\n" USAGE, message);
  return EXIT_FAILURE;
}

/* The reader require, dofile and loadfile ask for code (ADR 0003, manual
 * 11.6). A dofile/loadfile path is opened as written. A module name has its
 * dots made '/' and ".nilu" added, and is looked for next to the file being
 * loaded when there is one, then next to the script the command started
 * (upvalue 1: its directory, "" for the current one). The key is the path
 * opened, so a module is cached and named by where it was found. */
static int read_file(const char *path, char **bytes, size_t *length) {
  FILE *stream = fopen(path, "rb");
  size_t capacity = 4096, used = 0;
  char *buffer;
  if (stream == NULL) return errno == 0 ? EIO : errno;
  buffer = malloc(capacity);
  if (buffer == NULL) {
    fclose(stream);
    return ENOMEM;
  }
  for (;;) {
    size_t got;
    if (used == capacity) {
      char *grown = capacity > SIZE_MAX / 2 ? NULL : realloc(buffer, capacity * 2);
      if (grown == NULL) {
        free(buffer);
        fclose(stream);
        return ENOMEM;
      }
      buffer = grown;
      capacity *= 2;
    }
    got = fread(buffer + used, 1, capacity - used, stream);
    used += got;
    if (got == 0) break;
  }
  if (ferror(stream)) {
    free(buffer);
    fclose(stream);
    return EIO;
  }
  fclose(stream);
  *bytes = buffer;
  *length = used;
  return 0;
}

/* Pushes key and text for a path that opens; else 0 and the errno in *error. */
static int push_found(NiluState *N, const char *path, int *error) {
  char *bytes = NULL;
  size_t length = 0;
  *error = read_file(path, &bytes, &length);
  if (*error != 0) return 0;
  if (nilu_pushstring(N, path) != NILU_OK || nilu_pushlstring(N, bytes, length) != NILU_OK) {
    free(bytes);
    *error = ENOMEM;
    return 0;
  }
  free(bytes);
  return 1;
}

/* Appends one candidate's failure to the reason: "no file 'p'" when it is not
 * there, the system's words otherwise. */
static void add_reason(char *reason, size_t size, const char *path, int error) {
  size_t used = strlen(reason);
  if (used >= size) return;
  snprintf(reason + used, size - used, "%s%s '%s'%s%s", used ? "; " : "",
           error == ENOENT ? "no file" : "cannot open", path, error == ENOENT ? "" : ": ",
           error == ENOENT ? "" : strerror(error));
}

static int host_reader(NiluState *N) {
  size_t name_length = 0;
  const char *name = nilu_tolstring(N, 1, &name_length);
  const char *from = nilu_type(N, 2) == NILU_TSTRING ? nilu_tostring(N, 2) : NULL;
  const char *kind = nilu_tostring(N, 3);
  const char *base;
  char reason[1024] = "";
  char *relative, *candidate;
  size_t i, base_length, from_length = 0;
  int error = 0;
  if (name == NULL || kind == NULL || strlen(name) != name_length) {
    nilu_pushnil(N);
    nilu_pushstring(N, "a name with a zero byte names no file");
    return 2;
  }
  if (strcmp(kind, "file") == 0) {
    if (push_found(N, name, &error)) return 2;
    add_reason(reason, sizeof reason, name, error);
    nilu_pushnil(N);
    nilu_pushstring(N, reason);
    return 2;
  }
  base = nilu_getupvalue(N, 1) == NILU_OK ? nilu_tostring(N, -1) : NULL;
  if (base == NULL) base = "";
  base_length = strlen(base);
  if (from != NULL) {
    const char *slash = strrchr(from, '/');
    from_length = slash == NULL ? 0 : (size_t)(slash - from) + 1;
  }
  relative = malloc(name_length + sizeof ".nilu");
  candidate = malloc((from_length > base_length ? from_length : base_length) + name_length + sizeof ".nilu");
  if (relative == NULL || candidate == NULL) {
    free(relative);
    free(candidate);
    nilu_pushstring(N, "not enough memory");
    return nilu_error(N);
  }
  for (i = 0; i < name_length; i++) relative[i] = name[i] == '.' ? '/' : name[i];
  memcpy(relative + name_length, ".nilu", sizeof ".nilu");
  if (from != NULL) {
    memcpy(candidate, from, from_length);
    strcpy(candidate + from_length, relative);
    if (push_found(N, candidate, &error)) goto found;
    add_reason(reason, sizeof reason, candidate, error);
  }
  if (from == NULL || from_length != base_length || strncmp(from, base, base_length) != 0) {
    memcpy(candidate, base, base_length);
    strcpy(candidate + base_length, relative);
    if (push_found(N, candidate, &error)) goto found;
    add_reason(reason, sizeof reason, candidate, error);
  }
  free(relative);
  free(candidate);
  nilu_pushnil(N);
  nilu_pushstring(N, reason);
  return 2;
found:
  free(relative);
  free(candidate);
  return 2;
}

/* Gives the state the reader, with the directory of the script (the text up to
 * its last '/'), or "" when there is no script file. */
static NiluStatus install_reader(NiluState *N, const char *script_path) {
  const char *slash = script_path == NULL || strcmp(script_path, "-") == 0 ? NULL : strrchr(script_path, '/');
  NiluStatus status = slash == NULL ? nilu_pushstring(N, "")
                                    : nilu_pushlstring(N, script_path, (size_t)(slash - script_path) + 1);
  if (status != NILU_OK) return status;
  status = nilu_pushcclosure(N, host_reader, 1);
  if (status != NILU_OK) return status;
  return nilu_setreader(N);
}

/* -l g=mod and -l mod: the global g (or mod) is what require("mod") answers,
 * as Lua's command does. A failure is reported as a script's is. */
static int require_into_global(NiluState *N, const char *spec) {
  const char *equals = strchr(spec, '=');
  const char *module = equals != NULL ? equals + 1 : spec;
  size_t name_length = equals != NULL ? (size_t)(equals - spec) : strlen(spec);
  NiluStatus status;
  if (nilu_getglobal(N, "require") != NILU_OK || nilu_pushstring(N, module) != NILU_OK) {
    fputs(PROGNAME ": not enough memory\n", stderr);
    nilu_settop(N, 0);
    return 0;
  }
  status = protected_call(N, 1, 1);
  if (status != NILU_OK) {
    report(N, status, PROGNAME ": ");
    nilu_settop(N, 0);
    return 0;
  }
  if (nilu_pushlstring(N, spec, name_length) != NILU_OK) {
    fputs(PROGNAME ": not enough memory\n", stderr);
    nilu_settop(N, 0);
    return 0;
  }
  {
    /* The global's name is the text before '=', or the module's name. */
    const char *name = nilu_tolstring(N, -1, NULL);
    nilu_pushvalue(N, -2);
    if (nilu_setglobal(N, name) != NILU_OK) {
      fputs(PROGNAME ": not enough memory\n", stderr);
      nilu_settop(N, 0);
      return 0;
    }
  }
  nilu_settop(N, 0);
  return 1;
}

int main(int argc, char **argv) {
  NiluState *N;
  int i;
  int interactive = 0;
  int version = 0;
  int script = argc;
  int has_e = 0;
  int warnings = 0;
  int status = EXIT_SUCCESS;

  /* Options come before the script; the first non-option is the script. */
  for (i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (a[0] != '-' || a[1] == '\0') {
      script = i;
      break;
    }
    if (strcmp(a, "--") == 0) {
      script = i + 1 < argc ? i + 1 : argc;
      break;
    }
    if (strcmp(a, "-i") == 0) {
      interactive = 1;
    } else if (strcmp(a, "-v") == 0) {
      version = 1;
    } else if (strncmp(a, "-e", 2) == 0) {
      has_e = 1;
      if (a[2] == '\0') {
        if (i + 1 >= argc) return fail_usage("-e needs the text to run");
        i++;
      }
    } else if (strncmp(a, "-l", 2) == 0) {
      /* As -e, it runs in order and leaves no prompt of its own. */
      has_e = 1;
      if (a[2] == '\0') {
        if (i + 1 >= argc) return fail_usage("-l needs the module to load");
        i++;
      }
    } else if (strcmp(a, "-W") == 0) {
      warnings = 1;
    } else {
      char message[256];
      snprintf(message, sizeof message, "unknown option %s", a);
      return fail_usage(message);
    }
  }

  if (version && !interactive && script == argc && !has_e) {
    printf(PROGNAME " %s\n", NILU_VERSION);
    return EXIT_SUCCESS;
  }

  N = nilu_new();
  if (N == NULL) {
    fputs(PROGNAME ": cannot create state: not enough memory\n", stderr);
    return EXIT_FAILURE;
  }
  exiting_state = N;
  if (nilu_openlibs(N) != NILU_OK || nilu_pushcfunction(N, host_writer) != NILU_OK || nilu_setwriter(N) != NILU_OK ||
      open_io(N) != NILU_OK || open_os(N) != NILU_OK || seed_random(N) != NILU_OK ||
      install_reader(N, script < argc ? argv[script] : NULL) != NILU_OK ||
      create_arg_table(N, argc, argv, script) != NILU_OK) {
    fputs(PROGNAME ": cannot open the library: not enough memory\n", stderr);
    nilu_close(N);
    return EXIT_FAILURE;
  }
  nilu_settop(N, 0);
  /* -W: warnings start on, as warn("@on") turns them on. */
  if (warnings && (nilu_getglobal(N, "warn") != NILU_OK || nilu_pushstring(N, "@on") != NILU_OK || nilu_call(N, 1, 0) != NILU_OK)) {
    fputs(PROGNAME ": cannot turn warnings on\n", stderr);
    nilu_close(N);
    return EXIT_FAILURE;
  }
  nilu_settop(N, 0);

  if (version || interactive || (script == argc && !has_e)) printf(PROGNAME " %s\n", NILU_VERSION);
  fflush(stdout);

  /* The -e texts and -l modules, in order. */
  for (i = 1; i < argc && i < script && status == EXIT_SUCCESS; i++) {
    const char *a = argv[i];
    if (strncmp(a, "-e", 2) == 0) {
      const char *text = a[2] != '\0' ? a + 2 : argv[++i];
      if (!load_source(N, text, "=(command line)", "(command line)") || !run_loaded(N, 0)) status = EXIT_FAILURE;
    } else if (strncmp(a, "-l", 2) == 0) {
      const char *spec = a[2] != '\0' ? a + 2 : argv[++i];
      if (!require_into_global(N, spec)) status = EXIT_FAILURE;
    }
  }

  if (status == EXIT_SUCCESS && script < argc) {
    const char *path = argv[script];
    char *source;
    int refused = 0;
    if (strcmp(path, "-") == 0) {
      source = read_source(stdin, "stdin", &refused);
      if (source == NULL) {
        status = EXIT_FAILURE;
      } else if (load_source(N, source, "=stdin", "stdin")) {
        int nargs = push_script_arguments(N, argc, argv, script + 1);
        if (nargs < 0 || !run_loaded(N, nargs)) status = EXIT_FAILURE;
      } else status = EXIT_FAILURE;
      free(source);
    } else {
      FILE *stream = fopen(path, "rb");
      if (stream == NULL) {
        fprintf(stderr, PROGNAME ": cannot open %s: %s\n", path, strerror(errno));
        status = EXIT_FAILURE;
      } else {
        source = read_source(stream, path, &refused);
        fclose(stream);
        if (source == NULL) {
          status = EXIT_FAILURE;
        } else {
          size_t length = strlen(path);
          char *chunk_name = malloc(length + 2);
          if (chunk_name == NULL) {
            fprintf(stderr, PROGNAME ": %s: out of memory\n", path);
            status = EXIT_FAILURE;
          } else {
            chunk_name[0] = '@';
            memcpy(chunk_name + 1, path, length + 1);
            if (load_source(N, source, chunk_name, path)) {
              int nargs = push_script_arguments(N, argc, argv, script + 1);
              if (nargs < 0 || !run_loaded(N, nargs)) status = EXIT_FAILURE;
            } else status = EXIT_FAILURE;
            free(chunk_name);
          }
          free(source);
        }
      }
    }
  }

  if (status == EXIT_SUCCESS && (interactive || (script == argc && !has_e && !version))) prompt(N);

  fflush(stdout);
  close_open_files();
  nilu_close(N);
  exiting_state = NULL;
  return status;
}
