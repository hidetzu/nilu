/* A host whose behaviour is written in Nilu: a script sets the configuration
 * and a rule, and the host asks the rule about each event it sees. It shows
 * what a long-lived embedding needs beyond the smaller examples:
 *
 * - memory from the host's own allocator, every byte of it given back;
 * - only the libraries the script needs;
 * - one chunk loaded once and called for many events;
 * - a rule that fails, reported, with the state used again afterwards;
 * - a rule that never ends, stopped by an instruction budget.
 *
 *   zig build example
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nilu.h"

/* The host's allocator, in Lua's lua_Alloc shape: it counts what is live, so
 * that the end can show nilu_close gave every byte back. */
typedef struct {
  size_t live;
  size_t peak;
} Usage;

static void *count_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  Usage *usage = ud;
  if (nsize == 0) {
    if (ptr != NULL) usage->live -= osize;
    free(ptr);
    return NULL;
  }
  void *block = realloc(ptr, nsize);
  if (block == NULL) return NULL;
  usage->live = usage->live - (ptr != NULL ? osize : 0) + nsize;
  if (usage->live > usage->peak) usage->peak = usage->live;
  return block;
}

/* print hands each line here, newline included. */
static int write_line(NiluState *N) {
  size_t length;
  const char *text = nilu_tolstring(N, 1, &length);
  if (text != NULL) fwrite(text, 1, length, stdout);
  return 0;
}

/* The instruction budget of one call to a rule: the hook stops a rule that
 * runs past it, and the call answers NILU_ERR_INTERRUPTED. */
static int budget_left;
static int budget_hook(NiluState *N) {
  (void)N;
  return --budget_left <= 0;
}

/* config.<name> as an integer, or `fallback` when it is absent. */
static long long config_integer(NiluState *N, const char *name, long long fallback) {
  int top = nilu_gettop(N);
  long long value = fallback;
  if (nilu_getglobal(N, "config") == NILU_OK && nilu_type(N, -1) == NILU_TTABLE &&
      nilu_getfield(N, -1, name) == NILU_OK) {
    int isnum = 0;
    long long read = nilu_tointegerx(N, -1, &isnum);
    if (isnum) value = read;
  }
  nilu_settop(N, top);
  return value;
}

/* Asks the rule about one event. The answer is a word and a reason. */
static void decide(NiluState *N, const char *kind, long long amount) {
  int top = nilu_gettop(N);
  budget_left = 1000;
  NiluStatus status = nilu_getglobal(N, "decide");
  if (status == NILU_OK) status = nilu_pushstring(N, kind);
  if (status == NILU_OK) status = nilu_pushinteger(N, amount);
  if (status == NILU_OK) status = nilu_pcall(N, 2, 2, 0);
  if (status == NILU_OK) {
    const char *word = nilu_tostring(N, -2);
    const char *reason = nilu_tostring(N, -1);
    printf("%-8s %6lld -> %s (%s)\n", kind, amount, word != NULL ? word : "?", reason != NULL ? reason : "");
  } else if (status == NILU_ERR_INTERRUPTED) {
    printf("%-8s %6lld -> stopped: the rule ran past its budget\n", kind, amount);
  } else {
    const char *message = nilu_gettop(N) > top ? nilu_tostring(N, -1) : NULL;
    printf("%-8s %6lld -> failed: %s\n", kind, amount, message != NULL ? message : "(no sentence)");
  }
  nilu_settop(N, top);
}

static const char *rules =
    "config = { limit = 500, review = 100 }\n"
    "local seen = 0\n"
    "function decide(kind, amount)\n"
    "  seen = seen + 1\n"
    "  if kind == 'refund' and amount > config.limit then\n"
    "    return 'deny', string.format('refund over %d', config.limit)\n"
    "  elseif kind == 'audit' then\n"
    "    while true do end\n"
    "  elseif kind == 'note' then\n"
    "    return 'allow', amount.text\n"
    "  elseif amount >= config.review then\n"
    "    return 'review', 'event ' .. seen .. ' is large'\n"
    "  end\n"
    "  return 'allow', 'event ' .. seen\n"
    "end\n";

int main(void) {
  Usage usage = {0, 0};
  NiluState *N = nilu_newstate(count_alloc, &usage);
  if (N == NULL) return 1;
  /* The rules compute and print; they get no package, coroutine or debug. */
  if (nilu_openselectedlibs(N, NILU_LIB_BASE | NILU_LIB_STRING | NILU_LIB_TABLE | NILU_LIB_MATH) != NILU_OK ||
      nilu_pushcfunction(N, write_line) != NILU_OK || nilu_setwriter(N) != NILU_OK) {
    nilu_close(N);
    return 1;
  }
  nilu_sethook(N, budget_hook, 1);

  /* Loaded and run once, under the same budget as a rule; every event below
   * calls the function it defined. */
  budget_left = 1000;
  if (nilu_loadnamed(N, rules, "=rules", NULL) != NILU_OK || nilu_pcall(N, 0, 0, 0) != NILU_OK) {
    printf("the rules did not load: %s\n", nilu_tostring(N, -1));
    nilu_close(N);
    return 1;
  }
  printf("limit %lld, review from %lld\n", config_integer(N, "limit", 0), config_integer(N, "review", 0));

  decide(N, "sale", 40);
  decide(N, "sale", 250);
  decide(N, "refund", 900);
  decide(N, "note", 1);
  decide(N, "audit", 0);
  decide(N, "refund", 30);

  /* Many more events through the same chunk: nothing is loaded again. */
  int allowed = 0;
  for (int i = 0; i < 10000; i++) {
    int top = nilu_gettop(N);
    budget_left = 1000;
    if (nilu_getglobal(N, "decide") == NILU_OK && nilu_pushstring(N, "sale") == NILU_OK &&
        nilu_pushinteger(N, i % 150) == NILU_OK && nilu_pcall(N, 2, 1, 0) == NILU_OK) {
      const char *word = nilu_tostring(N, -1);
      if (word != NULL && strcmp(word, "allow") == 0) allowed++;
    }
    nilu_settop(N, top);
  }
  printf("10000 more sales: %d allowed\n", allowed);

  nilu_close(N);
  printf("after nilu_close, %zu bytes still held\n", usage.live);
  return usage.live == 0 ? 0 : 1;
}
