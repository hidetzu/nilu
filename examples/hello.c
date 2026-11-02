/* The shortest whole host: a state, the library, a writer for print, and a
 * program whose failure is reported instead of lost.
 *
 *   zig build example
 */
#include <stdio.h>

#include "nilu.h"

/* print hands each line here as one string, newline included. */
static int write_line(NiluState *N) {
  size_t length;
  const char *text = nilu_tolstring(N, 1, &length);
  if (text != NULL) fwrite(text, 1, length, stdout);
  return 0;
}

/* Loads and runs one source. A failure leaves one value on the stack, usually
 * a sentence with the place; a few leave nothing (the header says which). */
static void run(NiluState *N, const char *source) {
  int top = nilu_gettop(N);
  NiluStatus status = nilu_loadstring(N, source, NULL);
  if (status == NILU_OK) status = nilu_pcall(N, 0, 0, 0);
  if (status != NILU_OK) {
    const char *message = nilu_gettop(N) > top ? nilu_tostring(N, -1) : NULL;
    printf("failed: %s\n", message != NULL ? message : "(no sentence)");
  }
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

  run(N, "print('hello from Nilu', 1 + 2, 10 / 4)");
  run(N, "local t = nil\nprint(t.x)");
  run(N, "print('unfinished'");

  nilu_close(N);
  return 0;
}
