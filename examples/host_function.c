/* Functions in both directions: C functions a program calls, one of them
 * keeping state between calls, and a program's function the host calls.
 *
 *   zig build example
 */
#include <stdio.h>

#include "nilu.h"

static int write_line(NiluState *N) {
  size_t length;
  const char *text = nilu_tolstring(N, 1, &length);
  if (text != NULL) fwrite(text, 1, length, stdout);
  return 0;
}

/* clamp(x, lo, hi). A check that fails has already raised the library's
 * sentence (bad argument #n to 'clamp' ...); the function only returns it. */
static int clamp(NiluState *N) {
  long long x, lo, hi;
  if (nilu_checkinteger(N, 1, &x) != 0) return NILU_FAIL;
  if (nilu_checkinteger(N, 2, &lo) != 0) return NILU_FAIL;
  if (nilu_checkinteger(N, 3, &hi) != 0) return NILU_FAIL;
  if (lo > hi) {
    if (nilu_pushstring(N, "clamp: lo is above hi") != NILU_OK) return NILU_FAIL;
    return nilu_error(N);
  }
  if (nilu_pushinteger(N, x < lo ? lo : x > hi ? hi : x) != NILU_OK) return NILU_FAIL;
  return 1;
}

/* A C closure: its first upvalue is the last number it gave. */
static int next_id(NiluState *N) {
  if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;
  NiluInteger id = nilu_tointeger(N, -1) + 1;
  nilu_pop(N, 1);
  if (nilu_pushinteger(N, id) != NILU_OK || nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
  if (nilu_setupvalue(N, 1) != NILU_OK) return NILU_FAIL;
  return 1;
}

static void report(NiluState *N, int top, NiluStatus status) {
  if (status != NILU_OK) {
    const char *message = nilu_gettop(N) > top ? nilu_tostring(N, -1) : NULL;
    printf("failed: %s\n", message != NULL ? message : "(no sentence)");
  }
}

static void run(NiluState *N, const char *source) {
  int top = nilu_gettop(N);
  NiluStatus status = nilu_loadstring(N, source, NULL);
  if (status == NILU_OK) status = nilu_pcall(N, 0, 0, 0);
  report(N, top, status);
  nilu_settop(N, top);
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK || nilu_pushcfunction(N, write_line) != NILU_OK ||
      nilu_setwriter(N) != NILU_OK) {
    nilu_close(N);
    return 1;
  }

  /* Give the program the host's functions as globals. */
  if (nilu_pushcfunction(N, clamp) != NILU_OK || nilu_setglobal(N, "clamp") != NILU_OK ||
      nilu_pushinteger(N, 0) != NILU_OK || nilu_pushcclosure(N, next_id, 1) != NILU_OK ||
      nilu_setglobal(N, "next_id") != NILU_OK) {
    nilu_close(N);
    return 1;
  }

  run(N, "print(clamp(15, 0, 10), clamp(-3, 0, 10))");
  run(N, "print(next_id(), next_id(), next_id())");
  run(N, "print(clamp('high', 0, 10))");
  run(N, "print(clamp(1, 10, 0))");

  /* The program defines a function; the host calls it. */
  run(N, "function greet(name) return 'hello, ' .. name .. '!' end");
  int top = nilu_gettop(N);
  NiluStatus status = nilu_getglobal(N, "greet");
  if (status == NILU_OK) status = nilu_pushstring(N, "host");
  if (status == NILU_OK) status = nilu_pcall(N, 1, 1, 0);
  if (status == NILU_OK) printf("greet answered: %s\n", nilu_tostring(N, -1));
  report(N, top, status);
  nilu_settop(N, top);

  nilu_close(N);
  return 0;
}
