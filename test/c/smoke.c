/* The external tier: a C program driving Nilu through nilu.h and nothing else.
 *
 * Why this exists and a Zig test does not replace it:
 * this is the only check that crosses the ABI. It compiles the header with a C
 * compiler and links against the library, so a header that disagrees with the Zig
 * exports fails here and nowhere else.
 *
 * It says which subset it ran on its first line, it can run one case, and it can count
 * without running:
 *
 * zig build c-test every case
 * zig build c-test -- --list name them without running any
 * zig build c-test -- --only=<name> run one
 *
 * The count is announced here, at the moment it runs. It is never written down
 *.
 */
#include <stdio.h>
#include <string.h>

#include "nilu.h"

/* A case returns NULL when it passed, or the sentence that says what went wrong. */
typedef const char *(*nilu_case_fn)(void);

/* Whether `s` ends with `tail` -- for a sentence whose chunk id is tested elsewhere
 * and whose words are what this case is about. */
static int ends_with(const char *s, const char *tail) {
  size_t n, m;
  if (s == NULL) return 0;
  n = strlen(s);
  m = strlen(tail);
  return n >= m && strcmp(s + (n - m), tail) == 0;
}

static const char *case_a_state_opens_and_closes(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_gettop(N) != 0) return "a fresh state did not start empty";
  nilu_close(N);
  return NULL;
}

static const char *case_a_number_reads_back_through_c(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 1.5) != NILU_OK) {
    failure = "nilu_pushnumber refused a number";
  } else if (nilu_gettop(N) != 1) {
    failure = "the stack did not grow by one";
  } else {
    int isnum = 0;
    double v = nilu_tonumberx(N, -1, &isnum);
    if (isnum != 1) failure = "isnum said the top was not a number";
    else if (v != 1.5) failure = "the number that came back is not the one pushed";
  }

  nilu_close(N);
  return failure;
}

static const char *case_index_1_is_the_bottom(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 10.0) != NILU_OK || nilu_pushnumber(N, 20.0) != NILU_OK) {
    failure = "nilu_pushnumber refused a number";
  } else {
    int isnum = 0;
    if (nilu_tonumberx(N, 1, &isnum) != 10.0 || isnum != 1) {
      failure = "index 1 is not the bottom of the stack";
    } else if (nilu_tonumberx(N, -1, &isnum) != 20.0 || isnum != 1) {
      failure = "index -1 is not the top of the stack";
    } else if (nilu_tonumberx(N, 2, &isnum) != 20.0 || isnum != 1) {
      failure = "index 2 and index -1 do not name the same slot";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_missing_slot_is_not_the_value_zero(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 0.0) != NILU_OK) {
    failure = "nilu_pushnumber refused zero";
  } else {
    int isnum = 0;
    if (nilu_tonumberx(N, -1, &isnum) != 0.0 || isnum != 1) {
      failure = "a pushed zero did not come back as a number";
    } else if (nilu_tonumberx(N, 2, &isnum) != 0.0 || isnum != 0) {
      failure = "an index past the top was not reported through isnum";
    } else if (nilu_tonumberx(N, 0, &isnum) != 0.0 || isnum != 0) {
      failure = "index 0 was treated as naming a slot";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_nil_and_number_are_told_apart(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnil(N) != NILU_OK || nilu_pushnumber(N, 1.5) != NILU_OK) {
    failure = "a push was refused";
  } else if (nilu_gettop(N) != 2) {
    failure = "the stack did not grow by two";
  } else if (nilu_type(N, 1) != NILU_TNIL) {
    failure = "the nil pushed first is not reported as nil";
  } else if (nilu_type(N, -1) != NILU_TNUMBER) {
    failure = "the number pushed second is not reported as a number";
  } else if (nilu_type(N, -2) != NILU_TNIL) {
    failure = "counting from the top does not reach the nil";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_slot_that_does_not_exist_has_no_type(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_type(N, 1) != NILU_TNONE || nilu_type(N, -1) != NILU_TNONE) {
    failure = "an empty stack reported a type";
  } else if (nilu_type(N, 0) != NILU_TNONE) {
    failure = "index 0 reported a type";
  } else if (nilu_pushnil(N) != NILU_OK) {
    failure = "nilu_pushnil was refused";
  } else if (nilu_type(N, 1) != NILU_TNIL) {
    failure = "the pushed nil is not reported as nil";
  } else if (nilu_type(N, 2) != NILU_TNONE) {
    /* The pair this tag exists for: slot 1 holds nil, slot 2 does not exist. */
    failure = "a slot past the top was not told apart from the nil below it";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_nil_is_not_a_number(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnil(N) != NILU_OK) {
    failure = "nilu_pushnil was refused";
  } else {
    int isnum = 1;
    if (nilu_tonumberx(N, -1, &isnum) != 0.0 || isnum != 0) {
      failure = "a nil came back as a number";
    } else if (nilu_tonumberx(N, 2, &isnum) != 0.0 || isnum != 0) {
      failure = "a missing slot came back as a number";
    } else if (nilu_type(N, 1) == nilu_type(N, 2)) {
      /* isnum says the same for both; nilu_type is what separates them. */
      failure = "nil and a missing slot report the same type";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_convenience_macro_reads_a_number(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* nilu_tonumber is header-only. If nobody calls it, nothing checks that it expands
  * to something that compiles and agrees with the function it wraps. */
  if (nilu_pushnumber(N, 2.5) != NILU_OK) {
    failure = "nilu_pushnumber refused a number";
  } else if (nilu_tonumber(N, -1) != 2.5) {
    failure = "the macro did not read back what was pushed";
  } else if (nilu_tonumber(N, 2) != 0.0) {
    failure = "the macro did not answer 0 for a slot that does not exist";
  }

  nilu_close(N);
  return failure;
}

static const char *case_setting_the_top_grows_with_nil(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 1.5) != NILU_OK) {
    failure = "nilu_pushnumber refused a number";
  } else if (nilu_settop(N, 3) != NILU_OK) {
    failure = "nilu_settop would not grow the stack";
  } else if (nilu_gettop(N) != 3) {
    failure = "the stack is not as deep as it was set to";
  } else if (nilu_type(N, 1) != NILU_TNUMBER) {
    failure = "growing disturbed what was already there";
  } else if (nilu_type(N, 2) != NILU_TNIL || nilu_type(N, 3) != NILU_TNIL) {
    failure = "the slots that appeared are not nil";
  }

  nilu_close(N);
  return failure;
}

static const char *case_pop_drops_what_was_pushed(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 1.0) != NILU_OK || nilu_pushnumber(N, 2.0) != NILU_OK ||
      nilu_pushnumber(N, 3.0) != NILU_OK) {
    failure = "a push was refused";
  } else if (nilu_pop(N, 0) != NILU_OK || nilu_gettop(N) != 3) {
    failure = "popping none changed the stack";
  } else if (nilu_pop(N, 1) != NILU_OK || nilu_gettop(N) != 2) {
    failure = "popping one did not drop exactly one";
  } else if (nilu_tonumber(N, -1) != 2.0) {
    failure = "the value below the popped one is not on top";
  } else if (nilu_pop(N, 2) != NILU_OK || nilu_gettop(N) != 0) {
    failure = "popping the rest did not empty the stack";
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_stack_stops_at_the_documented_maximum(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* Reaching the limit is what ties NILU_MAXDEPTH to the constant the library was
  * built with. If they disagree, one of these two lines fails. */
  if (nilu_settop(N, NILU_MAXDEPTH) != NILU_OK) {
    failure = "the stack could not be set to NILU_MAXDEPTH";
  } else if (nilu_gettop(N) != NILU_MAXDEPTH) {
    failure = "the stack is not NILU_MAXDEPTH deep";
  } else if (nilu_pushnumber(N, 1.5) != NILU_ERR_STACK || nilu_pushnil(N) != NILU_ERR_STACK) {
    failure = "a push past the maximum was accepted";
  } else if (nilu_settop(N, NILU_MAXDEPTH + 1) != NILU_ERR_STACK) {
    failure = "nilu_settop past the maximum was accepted";
  } else if (nilu_gettop(N) != NILU_MAXDEPTH) {
    failure = "a refused push changed how deep the stack is";
  }

  nilu_close(N);
  return failure;
}

/* The shape the DoD for this version asked for, written the way a host writes it. */
static int add(NiluState *N) {
  int ok1;
  int ok2;
  double a = nilu_tonumberx(N, 1, &ok1);
  double b = nilu_tonumberx(N, 2, &ok2);

  if (!ok1 || !ok2) return NILU_FAIL;

  if (nilu_pushnumber(N, a + b) != NILU_OK) return NILU_FAIL;
  return 1;
}

static int report_top(NiluState *N) {
  if (nilu_pushnumber(N, (double)nilu_gettop(N)) != NILU_OK) return NILU_FAIL;
  return 1;
}

static int push_two_then_fail(NiluState *N) {
  if (nilu_pushnumber(N, 98) != NILU_OK || nilu_pushnumber(N, 99) != NILU_OK) return NILU_FAIL;
  return NILU_FAIL;
}

static int two_results(NiluState *N) {
  if (nilu_pushnumber(N, 1) != NILU_OK || nilu_pushnumber(N, 2) != NILU_OK) return NILU_FAIL;
  return 2;
}

static int add_one_via_nested_call(NiluState *N) {
  int ok;
  double a = nilu_tonumberx(N, 1, &ok);
  if (!ok) return NILU_FAIL;

  if (nilu_pushcfunction(N, add) != NILU_OK) return NILU_FAIL;
  if (nilu_pushnumber(N, a) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) return NILU_FAIL;
  if (nilu_call(N, 2, 1) != NILU_OK) return NILU_FAIL;
  return 1;
}

static const char *case_add_10_and_20_through_a_call(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, add) != NILU_OK) {
    failure = "the function would not go on the stack";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    /* Ties NILU_TFUNCTION to the tag the library was built with. */
    failure = "a pushed function is not reported as a function";
  } else if (nilu_pushnumber(N, 10) != NILU_OK || nilu_pushnumber(N, 20) != NILU_OK) {
    failure = "an argument would not go on the stack";
  } else if (nilu_call(N, 2, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_gettop(N) != 1) {
    failure = "the function and its arguments were not replaced by the result";
  } else if (nilu_tonumber(N, -1) != 30.0) {
    failure = "add(10, 20) did not give 30";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_function_sees_only_its_arguments(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The caller's own value sits below, and the function must not see it. */
  if (nilu_pushnumber(N, 7) != NILU_OK || nilu_pushcfunction(N, report_top) != NILU_OK ||
      nilu_pushnil(N) != NILU_OK || nilu_pushnil(N) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_call(N, 2, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_tonumber(N, -1) != 2.0) {
    failure = "the function saw something other than its two arguments";
  } else if (nilu_tonumber(N, 1) != 7.0) {
    failure = "the caller's own value did not survive the call";
  }

  nilu_close(N);
  return failure;
}

/* What a message handler can see, written down where the handler runs. The chain is the
  whole point of nilu_pcall: after the call returns, only the failing frame's own position
  is left, so this is the one place "before the unwinding" is observable. */
static char handler_saw[256];

static int remember_the_chain(NiluState *N) {
  NiluError w;
  const char *one = nilu_where(N, 1, &w);
  int line_one = one == NULL ? 0 : w.line;
  const char *two = nilu_where(N, 2, &w);
  int line_two = two == NULL ? 0 : w.line;
  const char *three = nilu_where(N, 3, &w);
  int line_three = three == NULL ? 0 : w.line;
  snprintf(handler_saw, sizeof handler_saw, "%s:%d %s:%d %s:%d",
           one == NULL ? "-" : one, line_one,
           two == NULL ? "-" : two, line_two,
           three == NULL ? "-" : three, line_three);
  /* One result, which replaces the value the failure carries. */
  if (nilu_pushstring(N, "handled") != NILU_OK) return NILU_FAIL;
  return 1;
}

static const char *case_a_handler_runs_before_the_unwinding(void) {
  /* Three Nilu frames deep, with plain calls so that no frame is reused: the
  handler must see every one of them. nilu_where answers nothing past the chain. */
  const char *source =
      "global *\n"
      "local function c() local v = 1 + nil return v end\n"
      "local function b() local v = c() return v end\n"
      "local function a() local v = b() return v end\n"
      "local v = a() return v\n";
  const char *failure = NULL;
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  handler_saw[0] = '\0';
  if (nilu_pushcfunction(N, remember_the_chain) != NILU_OK) {
    failure = "the handler would not push";
  } else if (nilu_loadnamed(N, source, "=probe", &where) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_pcall(N, 0, 0, 1) != NILU_ERR_TYPE) {
    /* Arithmetic on a nil is a type error, which is the same answer a program gets -- the status is not what this case is about. */
    failure = "a program that fails did not report a failed call";
  } else if (strcmp(handler_saw, "probe:2 probe:3 probe:4") != 0) {
    /* The failing frame, then its two callers. The chunk itself is level 4 and is not
  asked about, so three is what a handler needs to build a traceback. */
    failure = handler_saw;
  } else if (nilu_type(N, -1) != NILU_TSTRING
             || strcmp(nilu_tostring(N, -1), "handled") != 0) {
    failure = "the handler's result did not replace the value the failure carried";
  }

  nilu_close(N);
  return failure;
}

static int fail_without_a_word(NiluState *N) {
  (void)N;
  return NILU_FAIL;
}

static int handler_that_fails(NiluState *N) {
  (void)N;
  return NILU_FAIL;
}

/* A handler that makes a protected call of its own and then fails. That call clears
  handler_ran when it returns, so in_errfunc is the only thing left
  that stops the handler running for its own failure -- and this is the path that reaches
  it. */
static int handler_runs;

static int handler_that_calls_then_fails(NiluState *N) {
  handler_runs++;
  if (nilu_pushcfunction(N, fail_without_a_word) != NILU_OK) return NILU_FAIL;
  if (nilu_call(N, 0, 0) == NILU_OK) return NILU_FAIL;
  if (nilu_settop(N, 0) != NILU_OK) return NILU_FAIL;
  return NILU_FAIL;
}

static const char *case_a_handler_that_calls_and_then_fails_stops(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  handler_runs = 0;
  if (nilu_pushcfunction(N, handler_that_calls_then_fails) != NILU_OK
      || nilu_pushcfunction(N, fail_without_a_word) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_pcall(N, 0, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "a failing function did not report a failed call";
  } else if (nilu_type(N, -1) != NILU_TSTRING
             || strcmp(nilu_tostring(N, -1), "error in error handling") != 0) {
    failure = "a handler that called and then failed did not answer Lua's words";
  } else if (handler_runs != 1) {
    /* Once, and not once per level the regress would have gone. Without this the string
  alone reads the same whether the handler ran once or two hundred times, and a
  mutation removing in_errfunc passed. */
    failure = "the handler ran more than once for its own failure";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_handler_that_fails_is_said_once(void) {
  /* lua5.5's words, measured, and the regress is one deep: the handler does not run for
  its own failure. The state is usable afterwards, which is what makes
  "one deep" a promise and not a hope. */
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, handler_that_fails) != NILU_OK
      || nilu_pushcfunction(N, fail_without_a_word) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_pcall(N, 0, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "a failing function did not report a failed call";
  } else if (nilu_type(N, -1) != NILU_TSTRING
             || strcmp(nilu_tostring(N, -1), "error in error handling") != 0) {
    failure = "a handler that failed did not answer Lua's words";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the state was not usable after a handler failed";
  } else if (nilu_pushnumber(N, 1) != NILU_OK || nilu_gettop(N) != 1) {
    failure = "the state was not usable after a handler failed";
  }

  nilu_close(N);
  return failure;
}

static int stop_at_once(NiluState *N) {
  (void)N;
  return 1;
}

static int counting_handler(NiluState *N) {
  (void)N;
  handler_runs++;
  return 1;
}

static const char *case_an_interruption_runs_no_handler(void) {
  /* The host asked to stop, and a program did not fail, so no handler runs: the value is
  nil and the status stays NILU_ERR_INTERRUPTED. What this caught: a handler
  that ran and was interrupted in turn, answering `error in error handling`. */
  const char *failure = NULL;
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  handler_runs = 0;
  if (nilu_pushcfunction(N, counting_handler) != NILU_OK
      || nilu_loadstring(N, "while true do end", &where) != NILU_OK) {
    failure = "the stack would not be set up";
  } else {
    nilu_sethook(N, stop_at_once, 100);
    if (nilu_pcall(N, 0, 0, 1) != NILU_ERR_INTERRUPTED) {
      failure = "an interrupted call did not answer NILU_ERR_INTERRUPTED";
    } else if (handler_runs != 0) {
      failure = "the handler ran for an interruption";
    } else if (nilu_gettop(N) != 2 || nilu_type(N, -1) != NILU_TNIL) {
      failure = "an interruption did not leave nil where the function was";
    }
    nilu_sethook(N, NULL, 0);
  }

  nilu_close(N);
  return failure;
}

static int closure_handler(NiluState *N) {
  /* Reads its own upvalue, so this is a C closure and not a light function. */
  if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;
  return 1;
}

static const char *case_a_handler_may_be_a_closure_named_from_the_top(void) {
  /* Two shapes a host will reach for: msgh counted from the top,
  and a C closure rather than a light function. Both follow from what nilu.h already
  promises -- the index convention and a C closure being a function -- and this is what holds that they do. */
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushstring(N, "from a closure") != NILU_OK
      || nilu_pushcclosure(N, closure_handler, 1) != NILU_OK
      || nilu_pushcfunction(N, fail_without_a_word) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_pcall(N, 0, 0, -2) != NILU_ERR_RUNTIME) {
    failure = "a failing function did not report a failed call";
  } else if (nilu_type(N, -1) != NILU_TSTRING
             || strcmp(nilu_tostring(N, -1), "from a closure") != 0) {
    failure = "a C closure named from the top did not run as the handler";
  }

  nilu_close(N);
  return failure;
}

static const char *case_no_handler_is_the_same_as_nilu_call(void) {
  /* msgh of 0 leaves what a failed nilu_call leaves: one value, the failure's.
  The two differ in where the failure stops, which this case does not reach. */
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, fail_without_a_word) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_pcall(N, 0, 0, 0) != NILU_ERR_RUNTIME) {
    failure = "a failing function did not report a failed call";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TNIL) {
    /* One value, nil, for a failure that carried nothing. */
    failure = "msgh of 0 did not leave what nilu_call leaves";
  }

  nilu_close(N);
  return failure;
}

static const char *case_results_that_cannot_fit_are_refused_before_the_call(void) {
  /* ⚠ The owner's choice: nresults past the room under NILU_MAXDEPTH is
  * NILU_ERR_STACK before the function runs, with the function and its arguments still
  * there. It padded nil past the limit until v0.0.94, measured. */
  const char *failure = NULL;
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_loadstring(N, "return 1", &where) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_call(N, 0, NILU_MAXDEPTH + 1) != NILU_ERR_STACK) {
    failure = "results that cannot fit were not refused with NILU_ERR_STACK";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, 1) != NILU_TFUNCTION) {
    failure = "a refused call did not leave the function where it was";
  } else if (nilu_pcall(N, 0, NILU_MAXDEPTH + 1, 0) != NILU_ERR_STACK) {
    failure = "nilu_pcall did not refuse the same way";
  } else if (nilu_call(N, 0, NILU_MAXDEPTH) != NILU_OK) {
    /* The function's slot is 1 and the results fill 1 .. NILU_MAXDEPTH: exactly the room. */
    failure = "results that fit exactly were refused";
  } else if (nilu_gettop(N) != NILU_MAXDEPTH) {
    failure = "results that fit were not padded to what was asked";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_failed_call_leaves_the_stack_alone(void) {
  const char *failure = NULL;
  int before;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 7) != NILU_OK) return "a push was refused";
  before = nilu_gettop(N);

  if (nilu_pushcfunction(N, push_two_then_fail) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_call(N, 1, 1) != NILU_ERR_RUNTIME) {
    failure = "a function returning NILU_FAIL did not report a failed call";
  } else if (nilu_gettop(N) != before + 1) {
    /* One value: what the failure carried, nil for a bare NILU_FAIL. */
    failure = "a failed call did not leave exactly the value it carried";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "a failure that carried nothing left something other than nil";
  } else if (nilu_settop(N, -2) != NILU_OK || nilu_tonumber(N, -1) != 7.0) {
    failure = "the caller's own value did not survive the failed call";
  }

  nilu_close(N);
  return failure;
}

static const char *case_results_are_adjusted_to_the_request(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, two_results) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_gettop(N) != 1 || nilu_tonumber(N, -1) != 1.0) {
    failure = "the extra result was not dropped";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_pushcfunction(N, two_results) != NILU_OK || nilu_call(N, 0, 4) != NILU_OK) {
    failure = "the second call did not succeed";
  } else if (nilu_gettop(N) != 4) {
    failure = "the results were not padded to what was asked for";
  } else if (nilu_type(N, 3) != NILU_TNIL || nilu_type(N, 4) != NILU_TNIL) {
    failure = "the padding is not nil";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_call_inside_a_call(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, add_one_via_nested_call) != NILU_OK || nilu_pushnumber(N, 41) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_call(N, 1, 1) != NILU_OK) {
    failure = "the nested call did not succeed";
  } else if (nilu_tonumber(N, -1) != 42.0 || nilu_gettop(N) != 1) {
    failure = "the nested call left the wrong thing behind";
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_header_states_its_own_version(void) {
  /* The manifest is docs-check's to compare; what C can see is that the numbers, the
  * derived value and the string agree with each other, and that a host can actually
  * compare them with #if. */
  char printed[32];

#if NILU_VERSION_NUM < 0
  return "NILU_VERSION_NUM cannot be compared at compile time";
#endif

  if (NILU_VERSION_NUM !=
      NILU_VERSION_MAJOR * 10000 + NILU_VERSION_MINOR * 100 + NILU_VERSION_PATCH) {
    return "NILU_VERSION_NUM does not match the parts it is derived from";
  }

  snprintf(printed, sizeof printed, "%d.%d.%d", NILU_VERSION_MAJOR, NILU_VERSION_MINOR,
           NILU_VERSION_PATCH);
  /* The string begins with the numbers. Between releases "-dev.N" follows them, with N
  starting at 1; on a release nothing does. Anything else is a fifth
  copy of the version saying something the other four do not. */
  {
    const char *version = NILU_VERSION;
    const size_t n = strlen(printed);
    const char *rest;
    if (strncmp(printed, version, n) != 0) {
      return "NILU_VERSION does not begin with the numbers beside it";
    }
    rest = version + n;
    if (*rest != '\0') {
      const char *digits;
      if (strncmp(rest, "-dev.", 5) != 0) {
        return "NILU_VERSION follows its numbers with something other than -dev.N";
      }
      digits = rest + 5;
      if (*digits < '1' || *digits > '9') {
        return "NILU_VERSION follows its numbers with something other than -dev.N";
      }
      for (; *digits; digits++) {
        if (*digits < '0' || *digits > '9') {
          return "NILU_VERSION's -dev.N is not followed by digits only";
        }
      }
    }
  }
  return NULL;
}

static int calls_compiled_source(NiluState *N) {
  if (nilu_loadstring(N, "return 10 + 20", NULL) != NILU_OK) return NILU_FAIL;
  if (nilu_call(N, 0, 1) != NILU_OK) return NILU_FAIL;
  return 1;
}

/* source -> lexer -> parser -> AST -> compiler -> runtime-owned Proto -> register VM */
static const char *answers(NiluState *N, const char *source, double expected) {
  if (nilu_loadstring(N, source, NULL) != NILU_OK) return "the source would not compile";
  if (nilu_type(N, -1) != NILU_TFUNCTION) return "what was loaded is not a function";
  if (nilu_call(N, 0, 1) != NILU_OK) return "the call did not succeed";
  if (nilu_tonumber(N, -1) != expected) return "the answer is not the one expected";
  if (nilu_gettop(N) != 1) return "the stack is not just the one result";
  if (nilu_settop(N, 0) != NILU_OK) return "the stack would not be emptied";
  return NULL;
}

static const char *case_source_compiles_and_runs(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The whole point of this version: C host -> text -> 30 -> C host. */
  failure = answers(N, "return 10 + 20", 30.0);
  if (failure == NULL) failure = answers(N, "return 42", 42.0);
  if (failure == NULL) failure = answers(N, "return 10 + 20 + 30", 60.0);
  if (failure == NULL) failure = answers(N, "return (10 + 20) + 30", 60.0);
  if (failure == NULL) failure = answers(N, "return 10 + (20 + 30)", 60.0);
  if (failure == NULL) failure = answers(N, "  return 1.5\t+\n2.25 ", 3.75);

  nilu_close(N);
  return failure;
}

static const char *case_source_that_does_not_compile_says_why(void) {
  const char *failure = NULL;
  int i;
  /* Each of these is refused for a different reason inside, and each says which
  *: the message is left on the stack, so what this case asserts is that exactly
  * one value is there and that it is a string with the chunk, the line and the column in it.
  * The words themselves are asserted per source in the Zig test that enumerates them. */
  static const char *const bad[] = {"return + 1",   "return 1 +",  "return (1 + 2",
                                    "return 1 + 2)", "return 1 2",  "return 1 # 2",
                                    /* An expression is not a statement any more, and these
  * are the statements that were not finished. */
                                    "1 + 2", "if 1 then", "while 1 do", "if 1 do end",
                                    "return 1 return 2",
                                    /* "x" is a name, and a name on its own is neither a call
  * nor an assignment, so the parser refuses it -- as it does "x + 1". That nothing declared it is
  * not the refusal: an undeclared name is a global. */
                                    "x", "local", "local = 1", "x + 1"};
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
    if (nilu_loadstring(N, bad[i], NULL) != NILU_ERR_SYNTAX) {
      failure = "a source that cannot compile was accepted";
      break;
    }
    if (nilu_gettop(N) != 1) {
      failure = "a refused source did not leave exactly its message on the stack";
      break;
    }
    if (nilu_type(N, -1) != NILU_TSTRING) {
      failure = "what a refused source left is not a string";
      break;
    }
    if (strstr(nilu_tostring(N, -1), ":1:") == NULL) {
      failure = "the message does not carry the line and the column";
      break;
    }
    /* And the host clears it, as it would after any failed call. */
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the message could not be popped";
      break;
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_state_keeps_every_function_it_compiled(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* Two prototypes, both owned by the state, both still callable. Whether they are freed
  * is not visible from C; what is visible is that neither stops working because the
  * other was loaded. */
  if (nilu_loadstring(N, "return 1 + 1", NULL) != NILU_OK ||
      nilu_loadstring(N, "return 2 + 2", NULL) != NILU_OK) {
    failure = "a source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 4.0) {
    failure = "the second function did not answer 4";
  } else if (nilu_pop(N, 1) != NILU_OK) {
    /* Pop the result, not the first function: the call replaced only the one it ran. */
    failure = "the result would not be popped";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "the first function is not still where it was put";
  } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 2.0) {
    failure = "the first function did not answer 2 after the second had run";
  }

  nilu_close(N);
  return failure;
}

static const char *case_both_kinds_of_function_are_one_type(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, add) != NILU_OK ||
      nilu_loadstring(N, "return 1 + 2", NULL) != NILU_OK) {
    failure = "a function would not go on the stack";
  } else if (nilu_type(N, 1) != NILU_TFUNCTION || nilu_type(N, 2) != NILU_TFUNCTION) {
    failure = "the two kinds of function are not one type";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_c_function_can_call_a_nilu_one(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* Both directions in one chain: the host calls C, which compiles and calls bytecode. */
  if (nilu_pushcfunction(N, calls_compiled_source) != NILU_OK) {
    failure = "the function would not go on the stack";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_tonumber(N, -1) != 30.0) {
    failure = "the nested bytecode call did not answer 30";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_syntax_error_says_where(void) {
  const char *failure = NULL;
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_loadstring(N, "return 10 +", &where) != NILU_ERR_SYNTAX) {
    failure = "an unfinished expression was not a syntax error";
  } else if (where.line != 1 || where.column != 12) {
    failure = "the position is not where the source ran out";
  } else if (nilu_loadstring(N, "return 10 +\n  * 2", &where) != NILU_ERR_SYNTAX) {
    failure = "a character the grammar has no use for was not a syntax error";
  } else if (where.line != 2 || where.column != 3) {
    failure = "the position is not on the line the character is on";
  } else if (nilu_loadstring(N, "1 + 2", &where) != NILU_ERR_SYNTAX) {
    failure = "an expression on its own was accepted as a program";
  } else if (where.line != 1 || where.column != 1) {
    failure = "the position is not where the expression starts";
  } else if (nilu_loadstring(N, "return 1 + 2", &where) != NILU_OK) {
    failure = "a source that compiles did not compile";
  } else if (where.line != 0 || where.column != 0) {
    /* Cleared on the way in, so a position from an earlier failure cannot be read as
  * this one's. */
    failure = "a source that compiled left a position behind";
  }

  nilu_close(N);
  return failure;
}

/* What the innermost call was told, since a native function cannot pass a status up:
 * it has one way to say no. */
static NiluStatus deepest = NILU_OK;

static int recurses(NiluState *N) {
  NiluStatus status;
  if (nilu_pushcfunction(N, recurses) != NILU_OK) return NILU_FAIL;
  status = nilu_call(N, 0, 0);
  if (status != NILU_OK) {
    /* Only the first one, which is the innermost: every level above it sees its own
  * function saying no, and would overwrite this with NILU_ERR_RUNTIME. That is the
  * gap a native function has -- it cannot pass a status up. */
    if (deepest == NILU_OK) deepest = status;
    return NILU_FAIL;
  }
  return 0;
}

static const char *case_a_call_too_deep_never_runs(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  deepest = NILU_OK;
  if (nilu_pushcfunction(N, recurses) != NILU_OK) {
    failure = "the function would not go on the stack";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_RUNTIME) {
    /* The outermost call ran, so what it reports is its function saying no. */
    failure = "the outermost call did not report its function failing";
  } else if (deepest != NILU_ERR_CALL_DEPTH) {
    failure = "the innermost call was not refused for being too deep";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_failed_call_and_a_refused_one_differ(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A function that says no: it ran, so the call removes it and its arguments. */
  if (nilu_pushcfunction(N, push_two_then_fail) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "the stack would not be set up";
  } else if (nilu_call(N, 1, 1) != NILU_ERR_RUNTIME) {
    failure = "a function returning NILU_FAIL was not reported as a runtime failure";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TNIL) {
    /* The function and its arguments are gone, and one nil -- what a bare NILU_FAIL
  * carries -- stands where they were. */
    failure = "a call that ran and failed did not leave exactly the nil it carried";
  }

  nilu_close(N);
  return failure;
}

static const char *case_short_circuiting_runs_from_source(void) {
  struct {
    const char *source;
    NiluType is;
    double number;
  } cases[] = {
      /* Every number is true, so the right side of an and always runs and the right side
  * of an or never does. Both are the conditional jump, one taken and one not. */
      {"return 1 and 2", NILU_TNUMBER, 2.0},
      {"return 1 or 2", NILU_TNUMBER, 1.0},
      /* nil is the other half of the rule, and a nil literal is the only way to reach it
  * from source. */
      {"return nil or 2", NILU_TNUMBER, 2.0},
      {"return nil and 2", NILU_TNIL, 0.0},
      /* Zero is true, which is the surprising half. */
      {"return 0 and 7", NILU_TNUMBER, 7.0},
      {"return 0 or 7", NILU_TNUMBER, 0.0},
      /* or binds loosest: (1 and nil) or 9. */
      {"return 1 and nil or 9", NILU_TNUMBER, 9.0},
      {"return nil or 1 + 2", NILU_TNUMBER, 3.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_type(N, -1) != cases[i].is) {
      failure = "the answer is not of the kind expected";
    } else if (cases[i].is == NILU_TNUMBER && nilu_tonumber(N, -1) != cases[i].number) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_comparison_runs_from_source(void) {
  struct {
    const char *source;
    NiluType is;
    int truth;
    double number;
  } cases[] = {
      {"return 1 < 2", NILU_TBOOLEAN, 1, 0.0},
      {"return 2 <= 2", NILU_TBOOLEAN, 1, 0.0},
      /* Compiled by swapping the operands, and the answer is the one the source asked
  * for. */
      {"return 1 > 2", NILU_TBOOLEAN, 0, 0.0},
      {"return 2 >= 1", NILU_TBOOLEAN, 1, 0.0},
      {"return 1 ~= 2", NILU_TBOOLEAN, 1, 0.0},
      /* Equality is total: different types are never equal, and it never fails. */
      {"return nil == 1", NILU_TBOOLEAN, 0, 0.0},
      {"return nil == nil", NILU_TBOOLEAN, 1, 0.0},
      /* nil and false are the only falsey values. */
      {"return not 0", NILU_TBOOLEAN, 0, 0.0},
      {"return not nil", NILU_TBOOLEAN, 1, 0.0},
      {"return false and 1", NILU_TBOOLEAN, 0, 0.0},
      {"return false or 1", NILU_TNUMBER, 0, 1.0},
      {"return 1 < 2 and 7", NILU_TNUMBER, 0, 7.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_type(N, -1) != cases[i].is) {
      failure = "the answer is not of the kind expected";
    } else if (cases[i].is == NILU_TBOOLEAN &&
               (nilu_toboolean(N, -1) != 0) != (cases[i].truth != 0)) {
      failure = "the boolean is not the one expected";
    } else if (cases[i].is == NILU_TNUMBER && nilu_tonumber(N, -1) != cases[i].number) {
      failure = "the number is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_ordering_across_types_is_a_type_error(void) {
  /* not nil + 1 is in here because not binds tighter than +: it is (not nil) + 1,
  * which adds a boolean. */
  static const char *const bad[] = {"return nil < 1", "return true < false",
                                    "return 1 < 2 < 3", "return not nil + 1"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, bad[i], NULL) != NILU_OK) {
      /* It compiles. Ordering is a run-time question, not a syntactic one. */
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "ordering values that have no order between them was not a type error";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_boolean_a_host_pushed_reads_back(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushboolean(N, 0) != NILU_OK || nilu_pushboolean(N, 7) != NILU_OK) {
    failure = "a boolean would not go on the stack";
  } else if (nilu_type(N, 1) != NILU_TBOOLEAN) {
    failure = "a pushed boolean is not reported as a boolean";
  } else if (nilu_toboolean(N, 1) != 0 || nilu_toboolean(N, 2) == 0) {
    /* Anything but zero is true, as lua_pushboolean takes it. */
    failure = "a boolean did not read back as what was pushed";
  } else if (nilu_pushnumber(N, 0) != NILU_OK || nilu_toboolean(N, 3) == 0) {
    /* nilu_toboolean is the truthiness rule, not a type test: zero is true. */
    failure = "zero did not read as true";
  } else if (nilu_toboolean(N, 99) != 0) {
    failure = "a slot that does not exist did not read as false";
  }

  nilu_close(N);
  return failure;
}

/* What Nilu calls while a program runs. Returning non-zero asks it to stop. */
static int watcher_calls = 0;
static int watcher_stops = 0;

static int watcher(NiluState *N) {
  (void)N;
  watcher_calls++;
  return watcher_stops;
}

static const char *case_a_hook_watches_without_stopping(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  watcher_calls = 0;
  watcher_stops = 0;
  nilu_sethook(N, watcher, 1);

  /* Four instructions, so the hook runs before three of them. */
  if (nilu_loadstring(N, "return 10 + 20", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a hook that does not stop anything stopped something";
  } else if (nilu_tonumber(N, -1) != 30.0) {
    failure = "the answer changed because a hook was watching";
  } else if (watcher_calls != 3) {
    failure = "the hook was not called once before each instruction after the first";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_hook_can_stop_a_program(void) {
  const char *failure = NULL;
  int before;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 7) != NILU_OK) return "a push was refused";
  before = nilu_gettop(N);

  watcher_calls = 0;
  watcher_stops = 1;
  nilu_sethook(N, watcher, 2);

  /* Four instructions and a hook that stops on its first call, which comes before the
  * third. No loop is needed to show this, and no loop can be written from source yet. */
  if (nilu_loadstring(N, "return 10 + 20", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_INTERRUPTED) {
    failure = "a hook that asked to stop did not stop the call";
  } else if (watcher_calls != 1) {
    failure = "the hook was called more times than it asked for";
  } else if (nilu_gettop(N) != before + 1 || nilu_type(N, -1) != NILU_TNIL ||
             nilu_settop(N, -2) != NILU_OK) {
    /* An interruption takes the path a failed call takes: one nil on top,
  * popped here, and then the stack is as it was. */
    failure = "an interrupted call did not leave the stack as it was, plus the nil it carries";
  } else if (nilu_tonumber(N, -1) != 7.0) {
    failure = "what the caller had did not survive the interruption";
  } else {
    /* And the state still works, which is what makes this recoverable. */
    nilu_sethook(N, NULL, 0);
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, "return 1 + 2", NULL) != NILU_OK) {
      failure = "the state would not compile anything after an interruption";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 3.0) {
      failure = "the state would not run anything after an interruption";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── statements, from source ────────────────────────────────────────────────── */

static const char *case_an_empty_source_is_a_program(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* Not a syntax error. A block may have no statements, so this compiles, and the
  * function it produces returns nothing. An empty chunk is valid in Lua too. */
  if (nilu_loadstring(N, "", NULL) != NILU_OK) {
    failure = "an empty source was not accepted";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "what was loaded from an empty source is not a function";
  } else if (nilu_call(N, 0, 0) != NILU_OK) {
    failure = "a program that does nothing would not run";
  } else if (nilu_gettop(N) != 0) {
    failure = "a program that returns nothing left something behind";
  } else if (nilu_loadstring(N, "return", NULL) != NILU_OK) {
    failure = "a bare return was not accepted";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    /* Asking for a result from a function that returned none is the padding rule, not an
  * error: what arrives is nil. */
    failure = "a bare return would not run";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "a result that was never returned is not nil";
  }

  nilu_close(N);
  return failure;
}

static const char *case_if_chooses_which_block_runs(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"if 1 < 2 then return 10 end return 20", 10.0},
      {"if 2 < 1 then return 10 end return 20", 20.0},
      {"if 1 < 2 then return 1 else return 2 end", 1.0},
      {"if 2 < 1 then return 1 else return 2 end", 2.0},
      /* nil is false and every number is true, which is the same truthiness rule
  * nilu_toboolean answers with. */
      {"if nil then return 1 else return 2 end", 2.0},
      {"if 0 then return 1 else return 2 end", 1.0},
      /* An if inside an if, which is where the jumps could have been patched wrong. */
      {"if 1 < 2 then if 2 < 3 then return 7 end return 8 end return 9", 7.0},
      {"if 1 < 2 then if 3 < 2 then return 7 end return 8 end return 9", 8.0},
      /* A then block that does not return must not fall into the else block. Every case
  * above returns from both blocks, which is exactly the shape that would not have
  * noticed: measured by removing the jump, which only this case caught. */
      {"if 1 < 2 then else return 2 end return 7", 7.0},
      {"if 2 < 1 then else return 2 end return 7", 2.0},
      /* A while whose condition is false runs nothing, which is the only while that
  * can be run without a hook. */
      {"while 1 > 2 do return 1 end return 7", 7.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the block that ran is not the one the condition chose";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_source_loop_is_stopped_by_a_hook(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* This is the version in one case: a host can now write a program that never ends,
  * and the hook is what makes offering while safe at all. It is never run without
  * one -- a loop whose condition is a constant is the only loop this version can
  * write, so it runs forever or not at all. */
  watcher_calls = 0;
  watcher_stops = 0;
  nilu_sethook(N, watcher, 1000);

  if (nilu_loadstring(N, "while 1 < 2 do end", NULL) != NILU_OK) {
    failure = "a loop would not compile";
  } else {
    watcher_stops = 1;
    if (nilu_call(N, 0, 1) != NILU_ERR_INTERRUPTED) {
      failure = "a program that never ends was not interrupted";
    } else if (watcher_calls != 1) {
      failure = "the hook ran more times than it asked for";
    } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TNIL || nilu_settop(N, 0) != NILU_OK) {
      /* One nil, what the interruption carried, and nothing else. */
      failure = "an interrupted call did not leave the stack as it was, plus the nil it carries";
    } else {
      /* And the state still works, which is what makes this recoverable. */
      nilu_sethook(N, NULL, 0);
      if (nilu_loadstring(N, "return 1 + 2", NULL) != NILU_OK ||
          nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 3.0) {
        failure = "the state would not run anything after a loop was interrupted";
      }
    }
  }

  nilu_close(N);
  return failure;
}

/* ── variables ──────────────────────────────────────────────────────────────── */

static const char *case_a_loop_that_stops_runs_from_source(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The first program here that does something and then stops on its own. No hook is set:
  * if the loop did not end, this case would hang rather than fail. */
  if (nilu_loadstring(N, "local i = 0 while i < 3 do i = i + 1 end return i", NULL) != NILU_OK) {
    failure = "a loop would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_tonumber(N, -1) != 3.0) {
    failure = "the loop did not run the number of times its condition says";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_variable_runs_from_source(void) {
  static const struct {
    const char *source;
    int is;
    double number;
  } cases[] = {
      {"local x = 7 return x", NILU_TNUMBER, 7.0},
      /* local x with no value is nil, as in Lua. */
      {"local x return x", NILU_TNIL, 0.0},
      /* The right-hand side reads the variable being written. */
      {"local x = 10 x = 1 + x return x", NILU_TNUMBER, 11.0},
      /* The scope of a local starts after its declaration, so this x is the earlier one. */
      {"local x = 1 local x = x + 1 return x", NILU_TNUMBER, 2.0},
      /* A block's locals end with the block, and the register is reused. */
      {"local a = 1 if a < 2 then local b = 5 end local c = 9 return a + c", NILU_TNUMBER, 10.0},
      /* Summing with a loop: what every version before this one could not write. */
      {"local n = 0 local i = 0 while i < 4 do i = i + 1 n = n + i end return n", NILU_TNUMBER, 10.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_type(N, -1) != cases[i].is) {
      failure = "the answer is not of the kind expected";
    } else if (cases[i].is == NILU_TNUMBER && nilu_tonumber(N, -1) != cases[i].number) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_name_nothing_declared_is_a_global(void) {
  static const char *const was_refused[] = {
      "return nothing",
      "x = 1",
      "while flag do end",
      /* The scope of a local starts after its declaration, so this reads the global x. */
      "local x = x",
      /* And a local does not outlive its block, so this one does too. */
      "if 1 < 2 then local x = 1 end return x",
      /* A body reaching out for a name no enclosing function has. */
      "return function() return nothing end"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A name that is not a local and not an upvalue is a field of _ENV, so
  * these compile -- and a global nothing set reads as nil, because that is what reading a
  * missing key answers. What that costs is the diagnosis: a misspelled name is a program
  * that runs, unless the program declares its globals. */
  for (i = 0; i < (int)(sizeof was_refused / sizeof was_refused[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, was_refused[i], NULL) != NILU_OK) {
      failure = "a source that is now a global read was refused";
    }
    if (failure != NULL) break;
  }

  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, "return nothing", NULL) != NILU_OK ||
               nilu_call(N, 0, 1) != NILU_OK) {
      failure = "reading a global nothing set did not run";
    } else if (nilu_type(N, -1) != NILU_TNIL) {
      failure = "a global nothing set did not read as nil";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── arithmetic ─────────────────────────────────────────────────────────────── */

static const char *case_the_arithmetic_answers_what_lua_answers(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"return 1 - 2", -1.0},
      {"return 2 * 3", 6.0},
      {"return 7 / 2", 3.5},
      /* // is floor(a / b), so a negative result floors away from zero. It is still a
  * float: there is no integer here. */
      {"return 7 // 2", 3.0},
      {"return -7 // 2", -4.0},
      /* % is floored, not truncated: C's fmod(-1, 3) is -1, and Lua's -1 % 3 is 2. */
      {"return -1 % 3", 2.0},
      {"return 1 % -3", -2.0},
      /* ^ is right-associative and tighter than unary minus, which are the two groupings
  * people get wrong. Both are Lua's. */
      {"return 2 ^ 3 ^ 2", 512.0},
      {"return -2 ^ 2", -4.0},
      {"return 2 ^ -1", 0.5},
      /* A comment is not part of the program. */
      {"return 1 -- two", 1.0},
      {"local x = 2 -- a comment\nreturn x * x", 4.0},
      /* Counting down, which needs subtraction and a variable. */
      {"local i = 10 local n = 0 while 0 < i do i = i - 3 n = n + 1 end return n", 4.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one Lua gives";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_dividing_by_zero_is_a_number(void) {
  const char *failure = NULL;
  double answer;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* Lua raises for integer division by zero and answers inf or nan for the float ones.
  * Nilu has only floats, so only the second half exists -- a consequence of the value
  * model, not a decision. No math.h here: x != x is nan, and anything past the largest
  * finite double is an infinity. */
  if (nilu_loadstring(N, "return 1 / 0", NULL) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK) {
    failure = "dividing by zero did not run";
  } else if (!(nilu_tonumber(N, -1) > 1.0e308)) {
    failure = "dividing by zero is not an infinity";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_loadstring(N, "return 0 / 0", NULL) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK) {
    failure = "zero over zero did not run";
  } else if (answer = nilu_tonumber(N, -1), answer == answer) {
    /* Assigned first, then compared: writing both in one condition is unsequenced, and
  * -Werror says so. */
    failure = "zero over zero is not a nan";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_loadstring(N, "local n = 0 / 0 return n ~= n", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK) {
    failure = "comparing a nan did not run";
  } else if (nilu_type(N, -1) != NILU_TBOOLEAN || nilu_toboolean(N, -1) == 0) {
    /* nan ~= nan is true, which is the comparison instructions being IEEE comparisons. */
    failure = "a nan is equal to itself";
  }

  nilu_close(N);
  return failure;
}

/* ── strings ────────────────────────────────────────────────────────────────── */

static const char *case_a_string_reads_back_through_c(void) {
  const char *failure = NULL;
  const char *read;
  size_t len = 99;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushstring(N, "hello") != NILU_OK) {
    failure = "a string would not go on the stack";
  } else if (nilu_type(N, 1) != NILU_TSTRING) {
    failure = "a pushed string is not reported as a string";
  } else if ((read = nilu_tolstring(N, 1, &len)) == NULL) {
    failure = "a string would not read back";
  } else if (len != 5 || strcmp(read, "hello") != 0) {
    failure = "the string that read back is not the one pushed";
  } else if (read[5] != '\0') {
    /* Terminated past its length, which is what lets a host use it as a C string. */
    failure = "a string is not terminated for C";
  } else if (nilu_toboolean(N, 1) == 0) {
    failure = "a string is not true";
  } else if (nilu_tonumber(N, 1) != 0.0) {
    /* No coercion: Lua would convert "10" here, and this does not. */
    failure = "a string read as a number";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_zero_byte_inside_a_string(void) {
  const char *failure = NULL;
  const char *read;
  size_t len = 0;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A string is a length and bytes, not a C string. */
  if (nilu_pushlstring(N, "a\0b", 3) != NILU_OK) {
    failure = "a string with a zero byte would not go on the stack";
  } else if ((read = nilu_tolstring(N, 1, &len)) == NULL) {
    failure = "a string with a zero byte would not read back";
  } else if (len != 3) {
    failure = "the length is not the number of bytes";
  } else if (memcmp(read, "a\0b", 3) != 0) {
    failure = "the bytes are not the ones pushed";
  } else if (strlen(read) != 1) {
    /* Which is exactly why nilu_tolstring gives a length. */
    failure = "a C reader did not stop at the zero byte";
  } else if (nilu_pushlstring(N, NULL, 0) != NILU_OK) {
    /* A length of zero never reads the pointer, as lua_pushlstring's own comment says. */
    failure = "an empty string with a null pointer was refused";
  } else if (nilu_type(N, 2) != NILU_TSTRING) {
    failure = "an empty string is not a string";
  }

  nilu_close(N);
  return failure;
}

/* A userdata, from the side that is supposed to use it: a host.
  The block is the host's to write, the state's to free, and opaque to a
  program unless the host gives it a metatable. */
/* The utf8 library from a host's side.
  The library is what a host could have written, so a host can drive it, and
  charpattern is the row worth a C case: it holds a zero byte, and a host that read it as
  a C string would see nothing. */
/* A host function the two cases below hand to a script. */
static int case_helper_twice(NiluState *N) {
  nilu_pushnumber(N, nilu_tonumberx(N, 1, NULL) * 2);
  return 1;
}

/* nilu_next, from C. The earlier check drove it
  through the library's pairs alone, so the call had never been made from
  C at all -- the header did not even declare it. Three outcomes, which is why it has an
  out-parameter: a pair, the end, and a key the table does not have. */
static const char *case_a_host_walks_a_table_with_next(void) {
  const char *failure = NULL;
  int more = 0;
  int seen = 0;
  double sum = 0;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_pushstring(N, "a") != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK ||
             nilu_settable(N, 1) != NILU_OK) {
    failure = "t.a = 1 did not go in";
  } else if (nilu_pushstring(N, "b") != NILU_OK || nilu_pushnumber(N, 2) != NILU_OK ||
             nilu_settable(N, 1) != NILU_OK) {
    failure = "t.b = 2 did not go in";
  } else if (nilu_pushnil(N) != NILU_OK) {
    failure = "nil would not start the traversal";
  } else {
    /* The shape the header documents: the key stays on the stack, the value is popped. */
    while (nilu_next(N, 1, &more) == NILU_OK && more) {
      seen++;
      sum += nilu_tonumberx(N, -1, NULL);
      if (nilu_settop(N, nilu_gettop(N) - 1) != NILU_OK) {
        failure = "the value would not come off the stack";
        break;
      }
      if (seen > 8) {
        failure = "the traversal did not end";
        break;
      }
    }
    if (failure == NULL) {
      if (seen != 2) {
        failure = "the traversal did not see both pairs";
      } else if (sum != 3) {
        failure = "the values were not the ones stored";
      } else if (more != 0) {
        /* The end is more == 0 with nothing pushed, which is lua_next answering 0. */
        failure = "the end did not say it was the end";
      } else if (nilu_gettop(N) != 1) {
        failure = "the stack is not the table alone after the traversal";
      } else if (nilu_pushstring(N, "nothing") != NILU_OK) {
        failure = "a key would not go on the stack";
      } else if (nilu_next(N, 1, &more) != NILU_ERR_RUNTIME) {
        /* The third outcome: a key the table does not have. Lua raises here. */
        failure = "a key the table does not have was accepted";
      }
    }
  }

  nilu_close(N);
  return failure;
}

/* What a host meets when it registers a function and the script declares its globals.
  This is the first thing a host does, and it must work with declared globals. */
static const char *case_a_script_must_declare_the_hosts_name(void) {
  const char *failure = NULL;
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, case_helper_twice) != NILU_OK) {
    failure = "the host's function would not go on the stack";
  } else if (nilu_setglobal(N, "twice") != NILU_OK) {
    failure = "the host's function would not become a global";
  } else if (nilu_loadstring(N, "global x\nx = twice(21)\n", &where) != NILU_ERR_SYNTAX) {
    failure = "a chunk naming an undeclared host function compiled";
  } else if (where.line != 2) {
    failure = "the refusal does not name the line";
  } else if (strstr(nilu_tostring(N, -1), "variable 'twice' not declared") == NULL) {
    failure = "the refusal does not name the variable";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not clear";
    /* And the three ways out, each of which a host can tell a script writer. */
  } else if (nilu_loadstring(N, "global x, twice\nx = twice(21)\n", NULL) != NILU_OK) {
    failure = "declaring the host's name did not help";
  } else if (nilu_call(N, 0, 0) != NILU_OK) {
    failure = "the chunk that declared it did not run";
  } else if (nilu_getglobal(N, "x") != NILU_OK || nilu_tonumberx(N, -1, NULL) != 42) {
    failure = "the host's function did not answer";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not clear again";
  } else if (nilu_loadstring(N, "global *\nx = twice(1)\n", NULL) != NILU_OK) {
    failure = "global * did not help";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not clear a third time";
  } else if (nilu_loadstring(N, "x = twice(1)\n", NULL) != NILU_OK) {
    failure = "a chunk with no global statement was refused";
  }

  nilu_close(N);
  return failure;
}

/* The name a refusal uses when the host is the caller.
  nilu_calledas reads the name out of the caller's bytecode, and a host has none -- so the
  fallback is the name the library registered.
  This is the only place that can be checked from: a Zig test can reach pcall's
  path, but only a host can make the call with no Nilu frame under it at all. */
static const char *case_the_name_in_a_hosts_call_is_the_registered_one(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_getglobal(N, "string") != NILU_OK) {
    failure = "there is no string table";
  } else if (nilu_pushstring(N, "rep") != NILU_OK) {
    failure = "the key would not go on the stack";
  } else if (nilu_gettable(N, -2) != NILU_OK) {
    failure = "string.rep would not come back";
  } else if (nilu_pushstring(N, "x") != NILU_OK) {
    failure = "the argument would not go on the stack";
  } else if (nilu_call(N, 1, 1) != NILU_ERR_RUNTIME) {
    failure = "string.rep with one argument did not refuse";
  } else if (strstr(nilu_tostring(N, -1),
                    "bad argument #2 to 'rep' (number expected, got no value)") == NULL) {
    failure = "the refusal does not use the registered name";
  } else if (nilu_calledas(N, NULL) != NULL) {
    /* And the call itself answers NULL outside a native, which is what the fallback rests
  on: there is no running function to have been named. */
    failure = "nilu_calledas answered a name with no native running";
  }

  nilu_close(N);
  return failure;
}

/* How a native was called, as nilu_namewhat answers it, pushed as a string -- "NULL" for
  none. This is lua_getinfo's ar.namewhat, narrowed. */
static int how_called(NiluState *N) {
  const char *how = nilu_namewhat(N);
  if (nilu_pushstring(N, how != NULL ? how : "NULL") != NILU_OK) return NILU_FAIL;
  return 1;
}

/* nilu_namewhat answers what Lua's ar.namewhat answers for each way a program can call a
  native, and NULL for a host's call. each expectation is what
  lua_getinfo(L, "n", &ar) gives for the same call in Lua 5.5. */
static const char *case_namewhat_says_how_a_native_was_called(void) {
  const char *failure = NULL;
  const char *got;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_pushcfunction(N, how_called) != NILU_OK || nilu_setglobal(N, "how") != NILU_OK) {
    failure = "the native would not be registered";
  } else if (nilu_loadstring(N,
                             "local t = {how = how}\n"
                             "local h = how\n"
                             "local c = setmetatable({}, {__call = how})\n"
                             "local o = {c = c}\n"
                             "return t:how() .. ' ' .. t.how() .. ' ' .. h() .. ' ' .. how() .. ' ' .. o:c()\n",
                             NULL) != NILU_OK) {
    failure = "the program did not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the program failed";
  } else if ((got = nilu_tostring(N, -1)) == NULL || strcmp(got, "method field local global NULL") != 0) {
    failure = "the ways of calling were not method, field, local, global, and NULL through __call";
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_getglobal(N, "how") != NILU_OK) {
    failure = "the native would not come back";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the host's call failed";
  } else if ((got = nilu_tostring(N, -1)) == NULL || strcmp(got, "NULL") != 0) {
    failure = "a host's call answered a way of calling, where there is no caller's code";
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_library_from_a_host_including_utf8(void) {
  const char *failure = NULL;
  const char *pattern;
  size_t len = 0;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_getglobal(N, "utf8") != NILU_OK) {
    failure = "there is no utf8 table";
  } else if (nilu_type(N, -1) != NILU_TTABLE) {
    failure = "utf8 is not a table";
  } else if (nilu_pushstring(N, "charpattern") != NILU_OK) {
    failure = "the key would not go on the stack";
  } else if (nilu_gettable(N, -2) != NILU_OK) {
    failure = "charpattern would not come back";
  } else if ((pattern = nilu_tolstring(N, -1, &len)) == NULL) {
    failure = "charpattern is not a string";
  } else if (len != 14) {
    failure = "charpattern is not 14 bytes";
  } else if (pattern[1] != '\0') {
    /* The second byte is the zero the character class opens with. */
    failure = "charpattern lost its zero byte";
  } else if (strlen(pattern) != 1) {
    /* Which is exactly why a host must read it with a length. */
    failure = "a C reader did not stop at the zero byte";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not clear";
  } else {
    /* And the functions answer what the tests in Zig assert, through the same boundary a
  host uses: one program, three characters, five bytes. */
    if (nilu_loadstring(N, "return utf8.len(\"a\" .. utf8.char(0x3042) .. \"b\")", NULL) != NILU_OK) {
      failure = "the program would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "utf8.len failed";
    } else if (nilu_tonumberx(N, -1, NULL) != 3) {
      failure = "utf8.len did not answer 3";
    } else if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the answer would not come off the stack";
    } else if (nilu_loadstring(N, "return utf8.offset(\"a\" .. utf8.char(0x3042) .. \"b\", 2)", NULL) != NILU_OK) {
      failure = "the second program would not compile";
    } else if (nilu_call(N, 0, 2) != NILU_OK) {
      failure = "utf8.offset failed";
    } else if (nilu_tonumberx(N, -2, NULL) != 2 || nilu_tonumberx(N, -1, NULL) != 4) {
      /* Two values, which is 5.5's shape. */
      failure = "utf8.offset did not answer the pair";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_owns_a_block_of_bytes(void) {
  const char *failure = NULL;
  void *block = NULL;
  unsigned char *bytes;
  double written = 2.5;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_newuserdata(N, sizeof(double), &block) != NILU_OK) {
    failure = "a userdata would not go on the stack";
  } else if (block == NULL) {
    failure = "the block was not reported";
  } else if (nilu_type(N, 1) != NILU_TUSERDATA) {
    failure = "a userdata is not NILU_TUSERDATA";
  } else if (nilu_touserdata(N, 1) != block) {
    failure = "nilu_touserdata answered a different address";
  } else if ((bytes = (unsigned char *)block, bytes[0] != 0)) {
    failure = "the block was not zeroed";
  } else {
    /* The alignment is the point of the promise: a double goes in by assignment and
  not by memcpy, which is what a host actually writes. */
    *(double *)block = written;
    if (*(double *)nilu_touserdata(N, 1) != written) {
      failure = "what the host wrote did not read back";
    } else if (nilu_rawlen(N, 1) != NILU_OK) {
      failure = "a userdata has no length to a host";
    } else if (nilu_tonumberx(N, -1, NULL) != (double)sizeof(double)) {
      failure = "the length is not the size that was asked for";
    } else if (nilu_settop(N, 1) != NILU_OK) {
      failure = "the length would not come off the stack";
    } else if (nilu_pushnumber(N, 1) != NILU_OK) {
      failure = "a number would not go on the stack";
    } else if (nilu_touserdata(N, -1) != NULL) {
      /* NULL says one thing only. */
      failure = "a number answered a block";
    }
  }

  nilu_close(N);
  return failure;
}

/* What a program can and cannot do with one, and what a metatable changes. */
static const char *case_a_program_sees_a_userdata(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_newuserdata(N, 4, NULL) != NILU_OK) {
    failure = "a userdata would not go on the stack";
  } else if (nilu_setglobal(N, "u") != NILU_OK) {
    failure = "the userdata would not become a global";
  } else if (nilu_loadstring(N, "return type(u)", NULL) != NILU_OK) {
    failure = "type(u) would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "type(u) failed";
  } else if (strcmp(nilu_tostring(N, -1), "userdata") == 0 ? 0 : 1) {
    failure = "type(u) is not userdata";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the answer would not come off the stack";
  } else if (nilu_loadstring(N, "return u.x", NULL) != NILU_OK) {
    failure = "u.x would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
    /* Indexing a userdata with no metatable is a type error, as it is in Lua:
  luaV_finishget raises when there is no __index. */
    failure = "indexing a userdata without a metatable did not refuse";
  } else if (strstr(nilu_tostring(N, -1), "attempt to index a userdata value") == NULL) {
    failure = "the refusal does not name the type";
  } else {
    /* A metatable makes it reachable, exactly as it does for a table. */
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the refusal would not come off the stack";
    } else if (nilu_getglobal(N, "u") != NILU_OK) {
      failure = "the userdata would not come back";
    } else if (nilu_newtable(N) != NILU_OK) {
      failure = "a metatable would not go on the stack";
    } else if (nilu_pushstring(N, "__index") != NILU_OK) {
      failure = "the key would not go on the stack";
    } else if (nilu_loadstring(N, "return function() return 42 end", NULL) != NILU_OK) {
      failure = "the handler would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the handler would not be made";
    } else if (nilu_settable(N, -3) != NILU_OK) {
      failure = "__index would not go into the metatable";
    } else if (nilu_setmetatable(N, -2) != NILU_OK) {
      failure = "a userdata would not take a metatable";
    } else if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the userdata would not come off the stack";
    } else if (nilu_loadstring(N, "return u.x", NULL) != NILU_OK) {
      failure = "u.x would not compile the second time";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "u.x failed with a metatable in place";
    } else if (nilu_tonumberx(N, -1, NULL) != 42) {
      failure = "__index did not answer";
    } else if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the answer would not come off the stack";
    } else if (nilu_loadstring(N,
                               "local mt = getmetatable(u) local seen\n"
                               "mt.__newindex = function(_, k, v) seen = k .. '=' .. tostring(v) end\n"
                               "u.k = 5 return seen\n",
                               NULL) != NILU_OK) {
      failure = "the write would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      /* __newindex answers a write to a userdata, as luaV_finishset's non-table case does. What this caught: the write refused as an index. */
      failure = "a write to a userdata with __newindex failed";
    } else if (strcmp(nilu_tostring(N, -1), "k=5") != 0) {
      failure = "__newindex was not handed the key and the value";
    }
  }

  nilu_close(N);
  return failure;
}

/* A metatable with __gc is refused for a userdata, and nothing is set.
  There is no finaliser, so accepting the field would promise a
  call that never comes. */
static const char *case_a_gc_field_is_refused(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_newuserdata(N, 4, NULL) != NILU_OK) {
    failure = "a userdata would not go on the stack";
  } else if (nilu_newtable(N) != NILU_OK) {
    failure = "a metatable would not go on the stack";
  } else if (nilu_pushstring(N, "__gc") != NILU_OK) {
    failure = "the key would not go on the stack";
  } else if (nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "the value would not go on the stack";
  } else if (nilu_settable(N, -3) != NILU_OK) {
    failure = "__gc would not go into the metatable";
  } else if (nilu_gettop(N) != 2) {
    failure = "the stack is not the userdata and the metatable";
  } else if (nilu_setmetatable(N, -2) != NILU_ERR_TYPE) {
    failure = "a metatable with __gc was accepted for a userdata";
  } else if (nilu_gettop(N) != 2) {
    /* Nothing is popped when it is refused, so a host can look at what it passed. */
    failure = "the refused metatable was popped anyway";
  } else if (nilu_getmetatable(N, 1) != NILU_OK) {
    failure = "the metatable would not be read back";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "something was set despite the refusal";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not clear";
  } else if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_newtable(N) != NILU_OK) {
    failure = "a second table would not go on the stack";
  } else if (nilu_pushstring(N, "__gc") != NILU_OK) {
    failure = "the key would not go on the stack again";
  } else if (nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "the value would not go on the stack again";
  } else if (nilu_settable(N, -3) != NILU_OK) {
    failure = "__gc would not go into the second metatable";
  } else if (nilu_setmetatable(N, -2) != NILU_OK) {
    /* A table is not held to this: a table may carry the field. */
    failure = "a table was refused a metatable with __gc";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_null_string_pushes_nil(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The one NULL in this API that is not a contract violation: Lua defines it. */
  if (nilu_pushstring(N, NULL) != NILU_OK) {
    failure = "a null string was refused";
  } else if (nilu_type(N, 1) != NILU_TNIL) {
    failure = "a null string did not push nil";
  } else if (nilu_tostring(N, 1) != NULL) {
    failure = "reading a nil as a string did not answer nothing";
  } else if (nilu_tostring(N, 99) != NULL) {
    failure = "reading a slot that does not exist did not answer nothing";
  }

  nilu_close(N);
  return failure;
}

static const char *case_strings_run_from_source(void) {
  static const struct {
    const char *source;
    const char *text;
  } cases[] = {
      {"return \"hi\"", "hi"},
      {"return \"a\" .. \"b\" .. \"c\"", "abc"},
      {"return \"a\\nb\"", "a\nb"},
      {"return \"\"", ""},
      {"local s = \"x\" s = s .. s return s", "xx"},
      /* Building a string in a loop: every intermediate is held until nilu_close, which
  * is this version's stated price. */
      {"local s = \"\" local i = 0 while i < 3 do s = s .. \"x\" i = i + 1 end return s", "xxx"},
  };
  const char *failure = NULL;
  const char *read;
  size_t len = 0;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_type(N, -1) != NILU_TSTRING) {
      failure = "the answer is not a string";
    } else if ((read = nilu_tolstring(N, -1, &len)) == NULL) {
      failure = "the answer would not read back";
    } else if (len != strlen(cases[i].text) || memcmp(read, cases[i].text, len) != 0) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_what_a_string_cannot_do_is_a_type_error(void) {
  static const char *const bad[] = {
      /* No conversion of a string for arithmetic: Lua answers 11 for the first. A
       * number does join a string with `..`, so that is not here. */
      "return \"10\" + 1", "return -\"1\"",
      /* Ordering a string against a number has no answer, where equality does. */
      "return \"a\" < 1", "return 1 < \"a\"",
      /* A length is only a string's, until the table arrives. */
      "return #1", "return #nil"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof bad / sizeof bad[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, bad[i], NULL) != NILU_OK) {
      /* It compiles: having no answer is a run-time fact, not a syntactic one. */
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "a string doing what it cannot was not a type error";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_string_pointer_lives_while_its_value_does(void) {
  const char *failure = NULL;
  const char *read;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* What a host may rely on: the pointer is valid while the value is on the stack. That
  * is Lua's promise, and it is deliberately weaker than what this implementation does
  * today -- a collector is coming. */
  if (nilu_pushstring(N, "kept") != NILU_OK) {
    failure = "a string would not go on the stack";
  } else if ((read = nilu_tostring(N, 1)) == NULL) {
    failure = "a string would not read back";
  } else if (nilu_loadstring(N, "return \"a\" .. \"b\"", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a call that makes strings did not run";
  } else if (strcmp(read, "kept") != 0) {
    failure = "a string on the stack did not survive a call that made others";
  }

  nilu_close(N);
  return failure;
}

/* ── tables ─────────────────────────────────────────────────────────────────── */

static const char *case_a_table_holds_what_a_host_put_in_it(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_type(N, 1) != NILU_TTABLE) {
    failure = "a new table is not reported as a table";
  } else if (nilu_toboolean(N, 1) == 0) {
    failure = "a table is not true";
  } else if (nilu_tostring(N, 1) != NULL) {
    failure = "a table read as a string";
  } else if (nilu_pushstring(N, "k") != NILU_OK || nilu_pushnumber(N, 10) != NILU_OK) {
    failure = "a key and a value would not go on the stack";
  } else if (nilu_settable(N, 1) != NILU_OK) {
    failure = "a host could not write a table";
  } else if (nilu_gettop(N) != 1) {
    /* The key and the value are both popped, as lua_settable does. */
    failure = "settable did not pop the key and the value";
  } else if (nilu_pushstring(N, "k") != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "a host could not read a table";
  } else if (nilu_gettop(N) != 2) {
    /* The key is replaced by the value, as lua_gettable does. */
    failure = "gettable did not replace the key with the value";
  } else if (nilu_tonumber(N, -1) != 10.0) {
    failure = "the value read back is not the one written";
  } else if (nilu_pushstring(N, "missing") != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "reading a key that is not there did not work";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "a key that is not there did not read as nil";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_deletes_a_key_with_nil(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* t[k] = nil removes the entry, which is how a host deletes a key. */
  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_pushnumber(N, 1) != NILU_OK || nilu_pushnumber(N, 5) != NILU_OK ||
             nilu_settable(N, 1) != NILU_OK) {
    failure = "a host could not write a table";
  } else if (nilu_pushnumber(N, 1) != NILU_OK || nilu_pushnil(N) != NILU_OK ||
             nilu_settable(N, 1) != NILU_OK) {
    failure = "assigning nil was refused";
  } else if (nilu_pushnumber(N, 1) != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "a host could not read a table";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "the key was not removed";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_refused_key_still_reads_as_nil(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A write refuses a key that cannot be in the table; a read of the same key answers
  * nil. That asymmetry is Lua's: t[nil] is nil and t[nil] = 1 is an error. */
  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_pushnil(N) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "a key and a value would not go on the stack";
  } else if (nilu_settable(N, 1) != NILU_ERR_TYPE) {
    failure = "a nil key was accepted";
  } else if (nilu_gettop(N) != 3) {
    /* Nothing is popped when it is refused. */
    failure = "a refused write popped something";
  } else if (nilu_settop(N, 1) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_pushnil(N) != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "reading a nil key failed instead of answering nil";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "reading a nil key did not answer nil";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_pushnumber(N, 7) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
    failure = "a push was refused";
  } else if (nilu_gettable(N, 1) != NILU_ERR_TYPE) {
    /* Indexing something that is not a table. There are no metatables. */
    failure = "indexing a number was not a type error";
  }

  nilu_close(N);
  return failure;
}

static const char *case_tables_run_from_source(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local t = {} t[1] = 10 return t[1]", 10.0},
      {"local t = {} t[\"k\"] = 3 return t[\"k\"]", 3.0},
      /* A string key is its bytes: the two literals are two strings and one key. */
      {"local t = {} t[\"a\" .. \"b\"] = 1 return t[\"ab\"]", 1.0},
      /* t[2] and t[2.0] are one key, and so are t[-0.0] and t[0]. */
      {"local t = {} t[2] = 1 return t[2.0]", 1.0},
      {"local t = {} t[-0.0] = 1 return t[0]", 1.0},
      /* A table holds a table: the object graph. */
      {"local t = {} t[1] = {} t[1][1] = 5 return t[1][1]", 5.0},
      /* And itself, which is a cycle. */
      {"local t = {} t[1] = t return #t", 1.0},
      /* The length, built by a loop. */
      {"local t = {} local i = 0 while i < 5 do i = i + 1 t[i] = i end return #t", 5.0},
      {"local t = {} return #t", 0.0},
      /* A key that is not an integer index is invisible to #. */
      {"local t = {} t[1] = 1 t[1.5] = 1 t[0] = 1 t[\"x\"] = 1 return #t", 1.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_border_with_holes_is_one_of_the_borders(void) {
  const char *failure = NULL;
  double answer;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* 2 and 4 are both borders and Lua's contract permits either, so this asserts the
  * contract rather than the implementation. */
  if (nilu_loadstring(N, "local t = {} t[1] = 1 t[2] = 1 t[4] = 1 return #t", NULL) != NILU_OK) {
    failure = "a source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if ((answer = nilu_tonumber(N, -1)) != 2.0 && answer != 4.0) {
    failure = "the length is not a border of the table";
  }

  nilu_close(N);
  return failure;
}

/* ── closures ──────────────────────────────────────────────────────────────── */

static const char *case_a_closure_shares_what_it_captured(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local x = 41 local function f() return x + 1 end return f()", 42.0},
      /* Shared and mutable: the inner function writes the outer's variable. */
      {"local n = 0 local function bump() n = n + 1 end bump() bump() bump() return n", 3.0},
      /* A function can name itself now, so recursion is written the usual way. */
      {"local function fact(n) if n < 2 then return 1 end return n * fact(n - 1) end return fact(5)", 120.0},
      /* Through two levels: the innermost captures its parent's cell. */
      {"local x = 7 local function a() local function b() return x end return b() end return a()", 7.0},
      /* A parameter is captured the same way a local is. */
      {"local function adder(n) return function(m) return n + m end end return adder(40)(2)", 42.0},
      /* The cell outlives the function that made it, which is what closing is for. */
      {"local function counter() local n = 0 return function() n = n + 1 return n end end "
       "local c = counter() c() c() return c()",
       3.0},
      /* Two counters do not share theirs. */
      {"local function counter() local n = 0 return function() n = n + 1 return n end end "
       "local a = counter() local b = counter() a() a() return b()",
       1.0},
      /* Each turn of a loop captures its own variable: if the three closures shared one cell
  * they would all answer 3. */
      {"local t = {} local i = 0 while i < 3 do local x = i t[i + 1] = function() return x end "
       "i = i + 1 end return t[1]() * 100 + t[2]() * 10 + t[3]()",
       12.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_function_a_host_holds_keeps_its_state(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A function a program returned may hold state, so calling it twice can answer
  * differently. Nothing in this API says a call is pure, and a host that cached the
  * first answer would be wrong. */
  if (nilu_loadstring(N, "local n = 0 return function() n = n + 1 return n end", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the chunk did not run";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "what a program returned is not a function";
  } else {
    /* nilu_call consumes the function, and there is no nilu_pushvalue to copy one with, so
  * the host keeps it at index 1 and calls a fresh copy... which it cannot. What it can
  * do is let the program do the calling. */
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N,
                               "local function counter() local n = 0 "
                               "return function() n = n + 1 return n end end "
                               "local c = counter() c() c() c() return c()",
                               NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != 4.0) {
      failure = "a closure did not keep its state across calls";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a field, and the library ───────────────────────────────────────────────── */

static const char *case_a_field_is_an_index(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* t.k is t["k"], and the two are one code path. */
      {"local t = {} t[\"k\"] = 1 return t.k", 1.0},
      {"local t = {} t.k = 2 return t[\"k\"]", 2.0},
      {"local t = {} t.k = 3 return t.k", 3.0},
      /* A chain, and the two spellings mixed. */
      {"local t = {} t.a = {} t.a.b = 4 return t.a.b", 4.0},
      {"local t = {} t.a = {} t.a[1] = 5 return t.a[1]", 5.0},
      {"local t = {} t[1] = {} t[1].a = 6 return t[1].a", 6.0},
      /* A call is a suffix too, which is what the library's spelling needs. */
      {"local t = {} t.f = function(n) return n * 2 end return t.f(21)", 42.0},
      /* A field holds a function that closes over something. */
      {"local t = {} local n = 7 t.get = function() return n end return t.get()", 7.0},
      /* # takes the whole field, because it is unary. */
      {"local t = {} t.a = \"abc\" return #t.a", 3.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  /* A dot wants a name after it. `.5` is not in this list, because it is a number;
  * `t.1` is `t` followed by `0.1`, which is trailing input rather than a missing name --
  * both are what lua5.5 answers, measured. `1..2` is still refused, as a malformed number
  * in the lexer rather than by the parser. */
  if (failure == NULL) {
    static const char *const refused[] = {"return t.", "return t.end", "return t.1",
                                          "return 1..2", "return ."};
    for (i = 0; i < (int)(sizeof refused / sizeof refused[0]); i++) {
      NiluError where;
      if (nilu_loadstring(N, refused[i], &where) != NILU_ERR_SYNTAX) {
        failure = "a source that cannot compile was accepted";
        break;
      }
      if (where.line != 1) {
        failure = "a syntax error did not say where";
        break;
      }
    }
  }

  nilu_close(N);
  return failure;
}

/* print is the library's and writes where the host says (manual 1.3), and this is
 * what says so from outside: an opened state has a print, it refuses to run
 * without a writer, and with one it hands over the whole line in one call.
 *
 * The two lines that give a host a writer are in cli/nilu.c (host_writer). */
static char written[64];
static int writes = 0;

static int keep_line(NiluState *N) {
  size_t length = 0;
  const char *text = nilu_tolstring(N, 1, &length);
  if (text != NULL && length < sizeof written) {
    memcpy(written, text, length);
    written[length] = '\0';
  }
  writes++;
  return 0;
}

static const char *case_the_librarys_print_needs_a_writer(void) {
  const char *failure = NULL;
  const char *message;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  writes = 0;

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_getglobal(N, "print") != NILU_OK) {
    failure = "reading a global failed";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "an opened library had no print";
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, "print(1)", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_RUNTIME) {
    failure = "printing without a writer was not a runtime failure";
  } else if ((message = nilu_tostring(N, -1)) == NULL ||
             strcmp(message, "[string \"print(1)\"]:1: cannot print: no writer was given to this state") != 0) {
    failure = "printing without a writer did not say so";
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_pushcfunction(N, keep_line) != NILU_OK || nilu_setwriter(N) != NILU_OK) {
    failure = "the writer could not be given";
  } else if (nilu_loadstring(N, "print('a', 1)", NULL) != NILU_OK || nilu_call(N, 0, 0) != NILU_OK) {
    failure = "printing with a writer failed";
  } else if (writes != 1 || strcmp(written, "a\t1\n") != 0) {
    failure = "the writer did not get the whole line in one call";
  }

  nilu_close(N);
  return failure;
}

/* io and os are the interpreter's, registered in cli/nilu.c against this header.
 * ⚠ The core touches nothing outside itself, so an opened library has neither — and a
 * host that wants a script sandboxed gets that by not registering them. ⚠ The claim this
 * holds is the split itself: if either name ever appears here, src/ reached outward. */
static const char *case_the_library_has_no_io_and_no_os(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_getglobal(N, "io") != NILU_OK || nilu_getglobal(N, "os") != NILU_OK) {
    failure = "reading a global failed";
  } else if (nilu_type(N, -2) != NILU_TNIL) {
    failure = "an opened library had an io in it";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "an opened library had an os in it";
  } else if (nilu_loadstring(N, "io.write(1)", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_TYPE) {
    failure = "indexing an io that is not there was not a type error";
  }

  nilu_close(N);
  return failure;
}

/* a native function raises a value with `return nilu_error(N);`, and a host that
 * called it finds the value where the function stood. */
static int raises_a_table(NiluState *N) {
  (void)N;
  if (nilu_newtable(N) != NILU_OK) return NILU_FAIL;
  if (nilu_pushstring(N, "code") != NILU_OK) return NILU_FAIL;
  if (nilu_pushnumber(N, 42) != NILU_OK) return NILU_FAIL;
  if (nilu_settable(N, -3) != NILU_OK) return NILU_FAIL;
  return nilu_error(N);
}

static const char *case_a_native_function_raises_a_value_and_the_host_finds_it(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_pushcfunction(N, raises_a_table) != NILU_OK || nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "a function that raised did not report a failed call";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, 1) != NILU_TTABLE) {
    failure = "the raised table is not the one value a failed call leaves";
  } else if (nilu_pushstring(N, "code") != NILU_OK || nilu_gettable(N, 1) != NILU_OK || nilu_tonumber(N, -1) != 42.0) {
    failure = "the raised table is not the table that was raised";
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_pushcfunction(N, raises_a_table) != NILU_OK ||
             nilu_setglobal(N, "raise") != NILU_OK) {
    failure = "the function could not be named";
  } else if (nilu_loadstring(N, "local ok, e = pcall(raise) return ok, e.code", NULL) != NILU_OK ||
             nilu_call(N, 0, 2) != NILU_OK) {
    failure = "a program could not catch what the host's function raised";
  } else if (nilu_toboolean(N, 1) || nilu_tonumber(N, 2) != 42.0) {
    failure = "pcall did not answer false and the raised table";
  }

  nilu_close(N);
  return failure;
}

/* lua_rotate's family, from C, through the macros the header ships. */
static int digits_on_stack(NiluState *N, char *out, size_t room) {
  int i, n = nilu_gettop(N);
  if ((size_t)n + 1 > room) return 0;
  for (i = 1; i <= n; i++) out[i - 1] = (char)('0' + (int)nilu_tonumber(N, i));
  out[n] = '\0';
  return 1;
}

static const char *case_a_slot_can_be_moved(void) {
  const char *failure = NULL;
  char seen[16];
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 1; i <= 5; i++) {
    if (nilu_pushnumber(N, (double)i) != NILU_OK) failure = "a push was refused";
  }
  if (failure == NULL) {
    nilu_insert(N, 1); /* the top, 5, goes to the bottom */
    if (!digits_on_stack(N, seen, sizeof seen) || strcmp(seen, "51234") != 0) {
      failure = "nilu_insert did not move the top to the index";
    } else {
      nilu_remove(N, 1); /* and goes away again */
      if (!digits_on_stack(N, seen, sizeof seen) || strcmp(seen, "1234") != 0) {
        failure = "nilu_remove did not take the slot at the index out";
      } else {
        if (nilu_pushnumber(N, 9) != NILU_OK) failure = "a push was refused";
        nilu_replace(N, 2); /* 9 over the 2, and the 9 on top is gone */
        if (failure == NULL && (!digits_on_stack(N, seen, sizeof seen) || strcmp(seen, "1934") != 0)) {
          failure = "nilu_replace did not write the top over the index and pop it";
        } else {
          nilu_rotate(N, 2, -1); /* 9 3 4 -> 3 4 9 */
          if (!digits_on_stack(N, seen, sizeof seen) || strcmp(seen, "1349") != 0) {
            failure = "a negative rotation did not move the index's slot to the top";
          }
        }
      }
    }
  }

  nilu_close(N);
  return failure;
}

/* a chunk named by a host, and the line a failure happened on, through the header. */
/* a library refusal names the argument and the function, through the header. */
static const char *case_a_library_refusal_names_the_argument_a_host_reads(void) {
  const char *failure = NULL;
  const char *carried;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  /* Called from a chunk, so the message has the chunk's name and line in front of it --
  * luaL_where(L, 1), which is the caller's frame. lua5.5 on the same source answers
  * `bad argument #1 to 'rep' (string expected, got no value)`, measured. */
  if (nilu_loadnamed(N, "local a = 1\nreturn string.rep()", "=t", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "a library refusal was not a runtime failure";
  } else if (nilu_type(N, -1) != NILU_TSTRING) {
    failure = "the refusal carried no string";
  } else if ((carried = nilu_tostring(N, -1)) == NULL ||
             strcmp(carried, "t:2: bad argument #1 to 'rep' (string expected, got no value)") != 0) {
    failure = "the message is not the one lua5.5 composes, with the chunk and the line";
  /* And a host calling it directly: no Nilu frame to name, so the sentence alone. */
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_getglobal(N, "tostring") != NILU_OK) {
    failure = "tostring would not come back from the environment";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "tostring with no argument was not a refusal";
  } else if ((carried = nilu_tostring(N, -1)) == NULL ||
             strcmp(carried, "bad argument #1 to 'tostring' (value expected)") != 0) {
    failure = "a refusal outside any chunk did not carry the bare message";
  }

  nilu_close(N);
  return failure;
}

/* the sentence a failure carries, through the header, for a host that shows it. */
static const char *case_a_failure_carries_the_sentence_a_host_shows(void) {
  const char *failure = NULL;
  const char *carried;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* lua5.5, measured on the same three lines through a file named config.lua:
  * `config.lua:3: attempt to index a nil value (local 'a')`.
  * The whole message, including the variable name, is asserted here. */
  if (nilu_loadnamed(N, "local t = {}\nlocal a = t.x\nlocal b = a.y", "@config.nilu", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_TYPE) {
    failure = "indexing nil was not a type error";
  } else if (nilu_type(N, -1) != NILU_TSTRING) {
    failure = "the failure carried no string";
  } else if ((carried = nilu_tostring(N, -1)) == NULL ||
             strcmp(carried, "config.nilu:3: attempt to index a nil value (local 'a')") != 0) {
    failure = "the sentence is not the one lua5.5 composes, with the chunk, the line and the variable";
  /* And a host's own failed call, with no Nilu frame to name, carries the sentence alone --
  * luaG_runerror writes a position only when the frame it is in has one. */
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1.0) != NILU_OK) {
    failure = "the stack would not be cleared";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_TYPE) {
    failure = "a host calling a number was not a type error";
  } else if ((carried = nilu_tostring(N, -1)) == NULL ||
             strcmp(carried, "attempt to call a number value") != 0) {
    /* And no parenthetical either: a host's call has no calling instruction to read, so
  * there is no variable to name. lua5.5 answers the same from a C
  * frame, measured. */
    failure = "a failure outside any chunk did not carry the bare sentence";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_named_chunk_s_failure_has_a_line(void) {
  const char *failure = NULL;
  NiluError where;
  const char *chunk;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  where.line = 9;
  where.column = 9;
  if (nilu_loadnamed(N, "local t = {}\nlocal a = t.x\nlocal b = a.y", "@config.nilu", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 0) != NILU_ERR_TYPE) {
    failure = "indexing nil was not a type error";
  } else if ((chunk = nilu_where(N, 0, &where)) == NULL) {
    failure = "a failure in a named chunk had no position";
  } else if (strcmp(chunk, "config.nilu") != 0) {
    failure = "the chunk is not shown as luaO_chunkid shows an @name";
  } else if (where.line != 3 || where.column != 0) {
    failure = "the line is not the third, or a column was invented";
  } else if (nilu_settop(N, 0) != NILU_OK || nilu_loadnamed(N, "return 1", "=ok", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a chunk that succeeds would not run";
  } else if (nilu_where(N, 0, &where) != NULL || where.line != 0) {
    failure = "a call that succeeded still answered a position";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_state_has_no_library_until_it_is_opened(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A fresh state has nothing in it, which is the right default for a sandbox: a
  * missing global reads as nil, so calling it is a type error. */
  if (nilu_loadstring(N, "return type(1)", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
    failure = "a library nobody opened was callable";
  } else if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_loadstring(N, "return type(1)", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the library did not work after opening";
  } else if (strcmp(nilu_tostring(N, -1), "number") == 0) {
    failure = NULL;
  } else {
    failure = "type(1) did not answer \"number\"";
  }

  nilu_close(N);
  return failure;
}

static const char *case_the_library_runs_from_source(void) {
  static const struct {
    const char *source;
    const char *answer;
  } cases[] = {
      {"return type(string)", "table"},
      {"return string.sub(\"hello\", 2, 3)", "el"},
      {"return string.sub(\"hello\", -3)", "llo"},
      {"return string.rep(\"a\", 3, \",\")", "a,a,a"},
      {"return string.upper(\"ab\")", "AB"},
      {"return string.reverse(\"abc\")", "cba"},
      {"local t = {} table.insert(t, \"a\") table.insert(t, \"b\") return table.concat(t, \"-\")", "a-b"},
      {"local t = {} t[1] = \"a\" t[2] = \"b\" return table.remove(t)", "b"},
      /* math.fmod is not the % operator, and Lua makes the same distinction. */
      {"if math.fmod(-1, 3) == -1 then return \"truncated\" end return \"floored\"", "truncated"},
      {"if -1 % 3 == 2 then return \"floored\" end return \"truncated\"", "floored"},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_type(N, -1) != NILU_TSTRING) {
      failure = "the answer is not a string";
    } else if (strcmp(nilu_tostring(N, -1), cases[i].answer) != 0) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  /* The libraries are ordinary tables a program can replace -- last, because replacing
  * one is visible to everything after it in this state. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "string = {} string.sub = function() return \"mine\" end "
                           "return string.sub(\"x\", 1)",
                        NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK ||
               strcmp(nilu_tostring(N, -1), "mine") != 0) {
      failure = "a program could not replace a library";
    } else if (nilu_settop(N, 0) != NILU_OK ||
               nilu_loadstring(N, "return string.upper", NULL) != NILU_OK ||
               nilu_call(N, 0, 1) != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
      /* What it replaced is gone, which is what "ordinary" has to mean. */
      failure = "replacing a library left the old one behind";
    }
  }

  /* A library refusal is NILU_ERR_RUNTIME, carrying Lua's words. Its own state, because
  * the case above emptied `string`. */
  if (failure == NULL) {
    nilu_close(N);
    N = nilu_new();
    if (N == NULL) return "nilu_new returned NULL";
    if (nilu_openlibs(N) != NILU_OK) {
      nilu_close(N);
      return "the library would not open";
    }
  }
  if (failure == NULL) {
    static const char *const refused[] = {"return string.char(256)", "return string.len(1)",
                                          "return math.max()", "return type()",
                                          "local t = {} return table.insert(t, 9, 1)"};
    for (i = 0; i < (int)(sizeof refused / sizeof refused[0]); i++) {
      if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, refused[i], NULL) != NILU_OK) {
        failure = "a source would not compile";
        break;
      }
      if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
        failure = "a refusal was not a runtime failure";
        break;
      }
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_copies_a_slot_and_reads_a_length(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* nilu_pushvalue is what lets a host call one chunk twice: nilu_call consumes the
  * function, and a copy is the same function. */
  if (nilu_loadstring(N, "return 20 + 1", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_pushvalue(N, 1) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK ||
             nilu_tonumber(N, -1) != 21.0) {
    failure = "a copied chunk did not run";
  } else if (nilu_settop(N, 1) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK ||
             nilu_tonumber(N, -1) != 21.0) {
    failure = "the same chunk did not run a second time";
  }

  /* nilu_len is the same # a program writes, for both kinds of value. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushstring(N, "hello") != NILU_OK) {
      failure = "a string would not go on the stack";
    } else if (nilu_len(N, 1) != NILU_OK || nilu_tonumber(N, -1) != 5.0) {
      failure = "the length of a string is not its bytes";
    } else if (nilu_settop(N, 0) != NILU_OK || nilu_newtable(N) != NILU_OK) {
      failure = "a table would not go on the stack";
    } else if (nilu_len(N, 1) != NILU_OK || nilu_tonumber(N, -1) != 0.0) {
      failure = "an empty table does not have a border of 0";
    } else if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
      failure = "a number would not go on the stack";
    } else if (nilu_len(N, 1) != NILU_ERR_TYPE) {
      failure = "the length of a number was not a type error";
    } else if (nilu_gettop(N) != 1) {
      failure = "a refused length left something on the stack";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── globals ────────────────────────────────────────────────────────────────── */

static const char *case_a_host_and_a_program_share_the_environment(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A global is a field of an ordinary table, and the host and the program see the same
  * one -- not two views of one. */
  if (nilu_pushnumber(N, 7) != NILU_OK || nilu_setglobal(N, "answer") != NILU_OK) {
    failure = "a host could not set a global";
  } else if (nilu_gettop(N) != 0) {
    failure = "setglobal did not pop the value";
  } else if (nilu_loadstring(N, "answer = answer * 6 return answer", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the call did not succeed";
  } else if (nilu_tonumber(N, -1) != 42.0) {
    failure = "a program did not see what the host set";
  } else if (nilu_getglobal(N, "answer") != NILU_OK) {
    failure = "a host could not read a global";
  } else if (nilu_tonumber(N, -1) != 42.0) {
    failure = "a host did not see what the program wrote";
  } else if (nilu_getglobal(N, "missing") != NILU_OK) {
    failure = "reading a global nothing set failed";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "a global nothing set did not read as nil";
  } else if (nilu_pushnil(N) != NILU_OK || nilu_setglobal(N, "answer") != NILU_OK) {
    failure = "a host could not unset a global";
  } else if (nilu_getglobal(N, "answer") != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
    /* Assigning nil removes the key, as it does for any table. */
    failure = "a global assigned nil did not go away";
  }

  nilu_close(N);
  return failure;
}

static const char *case_globals_run_from_source(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"x = 7 return x", 7.0},
      /* A local shadows a global, as it shadows anything else. */
      {"x = 1 local x = 2 return x", 2.0},
      /* A function reaches the same environment through its parent. */
      {"x = 5 local function f() return x end return f()", 5.0},
      {"local function f() x = 9 end f() return x", 9.0},
      {"x = 2 local function a() local function b() return x end return b() end return a()", 2.0},
      /* A global holds any value, because it is an ordinary table. */
      {"t = {} t[1] = 4 return t[1]", 4.0},
      {"f = function(n) return n * 2 end return f(21)", 42.0},
      /* local _ENV = {} works without anything implementing it: a local named _ENV shadows
  * the upvalue, so every global after it means a field of that table. */
      {"local _ENV = {} x = 1 return x", 1.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

/* A counter: reads its one upvalue, adds one, stores it back, answers it. */
static int counts_up(NiluState *N) {
  double was;
  if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;
  was = nilu_tonumber(N, -1);
  if (nilu_settop(N, -2) != NILU_OK) return NILU_FAIL;
  if (nilu_pushnumber(N, was + 1) != NILU_OK) return NILU_FAIL;
  if (nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
  if (nilu_setupvalue(N, 1) != NILU_OK) return NILU_FAIL;
  return 1;
}

/* Answers the status nilu_getupvalue(1) gives it and how many values that pushed. */
static int asks_for_upvalue_one(NiluState *N) {
  int before = nilu_gettop(N);
  NiluStatus status = nilu_getupvalue(N, 1);
  int pushed = nilu_gettop(N) - before;
  if (nilu_pushnumber(N, (double)status) != NILU_OK) return NILU_FAIL;
  if (nilu_pushnumber(N, (double)pushed) != NILU_OK) return NILU_FAIL;
  return 2;
}

/* A closure with one upvalue asking past it: both refused, and the 42 it meant to store is
 * still on the stack, which is the one result. */
static int asks_past_its_upvalues(NiluState *N) {
  if (nilu_getupvalue(N, 2) != NILU_ERR_TYPE) return NILU_FAIL;
  if (nilu_getupvalue(N, 0) != NILU_ERR_TYPE) return NILU_FAIL;
  if (nilu_gettop(N) != 0) return NILU_FAIL;
  if (nilu_pushnumber(N, 42) != NILU_OK) return NILU_FAIL;
  if (nilu_setupvalue(N, 2) != NILU_ERR_TYPE) return NILU_FAIL;
  if (nilu_gettop(N) != 1) return NILU_FAIL;
  return 1;
}

static const char *case_a_c_closure_counts_and_each_call_sees_what_the_last_one_stored(void) {
  const char *failure = NULL;
  double expected;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnumber(N, 0) != NILU_OK || nilu_pushcclosure(N, counts_up, 1) != NILU_OK) {
    failure = "the closure could not be made";
  } else if (nilu_gettop(N) != 1) {
    failure = "the upvalue was not popped into the closure";
  } else if (nilu_type(N, 1) != NILU_TFUNCTION) {
    failure = "a C closure is not a function to nilu_type";
  }
  for (expected = 1; failure == NULL && expected <= 3; expected++) {
    if (nilu_pushvalue(N, 1) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK) {
      failure = "calling the closure failed";
    } else if (nilu_tonumber(N, -1) != expected) {
      failure = "the count did not go up by one";
    } else if (nilu_settop(N, 1) != NILU_OK) {
      failure = "the stack would not be cut back";
    }
  }
  if (failure == NULL) {
    /* Outside any call there is no running closure, and nothing is pushed or popped. */
    if (nilu_getupvalue(N, 1) != NILU_ERR_TYPE || nilu_gettop(N) != 1) {
      failure = "a host outside a call could read an upvalue";
    } else if (nilu_setupvalue(N, 1) != NILU_ERR_TYPE || nilu_gettop(N) != 1) {
      failure = "a host outside a call could write an upvalue, or something was popped";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_program_calls_a_c_closure_and_it_keeps_its_state(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_pushnumber(N, 0) != NILU_OK || nilu_pushcclosure(N, counts_up, 1) != NILU_OK ||
             nilu_setglobal(N, "tick") != NILU_OK) {
    failure = "the closure could not be put in the environment";
  } else if (nilu_loadstring(N, "return tick() + tick() + tick(), type(tick)", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 2) != NILU_OK) {
    failure = "a program could not call a C closure";
  } else if (nilu_tonumber(N, 1) != 6.0) {
    failure = "three calls did not answer 1 + 2 + 3";
  } else if (strcmp(nilu_tostring(N, 2), "function") != 0) {
    failure = "a C closure is not a function to a program";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_closure_with_no_upvalues_is_the_light_function(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* lua_pushcclosure's `if (n == 0)`: the same value, with the code's address as identity. */
  if (nilu_pushcfunction(N, counts_up) != NILU_OK || nilu_pushcclosure(N, counts_up, 0) != NILU_OK) {
    failure = "a push was refused";
  } else if (!nilu_rawequal(N, 1, 2)) {
    failure = "a closure with no upvalues is not the light function";
  } else if (nilu_topointer(N, 1) != nilu_topointer(N, 2)) {
    failure = "the two have different identities";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_light_function_has_no_upvalues_to_read(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, asks_for_upvalue_one) != NILU_OK || nilu_call(N, 0, 2) != NILU_OK) {
    failure = "the call failed";
  } else if (nilu_tonumber(N, 1) != (double)NILU_ERR_TYPE) {
    failure = "a light function asking for an upvalue was not refused with NILU_ERR_TYPE";
  } else if (nilu_tonumber(N, 2) != 0.0) {
    failure = "the refusal pushed something";
  }

  nilu_close(N);
  return failure;
}

static const char *case_an_upvalue_that_does_not_exist_is_refused_and_nothing_moves(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushnil(N) != NILU_OK || nilu_pushcclosure(N, asks_past_its_upvalues, 1) != NILU_OK) {
    failure = "the closure could not be made";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a refusal inside the closure was not what the header promises";
  } else if (nilu_tonumber(N, -1) != 42.0) {
    failure = "the value a refused store should have left behind is gone";
  }

  nilu_close(N);
  return failure;
}

static const char *case_two_closures_over_one_function_are_two_values(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_pushnumber(N, 0) != NILU_OK || nilu_pushcclosure(N, counts_up, 1) != NILU_OK ||
             nilu_pushnumber(N, 0) != NILU_OK || nilu_pushcclosure(N, counts_up, 1) != NILU_OK) {
    failure = "the closures could not be made";
  } else if (nilu_rawequal(N, 1, 2)) {
    failure = "two closures over one function compared equal";
  } else if (nilu_topointer(N, 1) == nilu_topointer(N, 2)) {
    failure = "two closures have one identity";
  } else if (nilu_setglobal(N, "b") != NILU_OK || nilu_setglobal(N, "a") != NILU_OK) {
    failure = "the closures could not be named";
  } else if (nilu_loadstring(N, "return a == b, a == a, tostring(a) == tostring(b)", NULL) != NILU_OK ||
             nilu_call(N, 0, 3) != NILU_OK) {
    failure = "a program could not compare them";
  } else if (nilu_toboolean(N, 1) || !nilu_toboolean(N, 2) || nilu_toboolean(N, 3)) {
    failure = "a program sees them as one value, or as spelled alike";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_program_calls_a_function_of_the_hosts(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* What this case asserted for exactly one version was NILU_ERR_TYPE. A program can now
  * call a function of yours: you put it in the environment and the program names it. */
  if (nilu_pushcfunction(N, add) != NILU_OK || nilu_setglobal(N, "add") != NILU_OK) {
    failure = "a host could not put its function in the environment";
  } else if (nilu_loadstring(N, "return add", NULL) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a program could not name it";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "what the program found is not a function";
  } else if (nilu_settop(N, 0) != NILU_OK) {
    failure = "the stack would not be emptied";
  } else if (nilu_loadstring(N, "return add(1, 2)", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a program could not call a function of the host's";
  } else if (nilu_tonumber(N, -1) != 3.0) {
    failure = "the function did not add its arguments";
  }

  nilu_close(N);
  return failure;
}

/* Answers how many arguments it was given. A native function sees the slots above its own
 * call's base and nothing below them, and a program's frame is wider than its call -- so
 * this is what says the window is the arguments and not the frame. */
static int count_arguments(NiluState *N) {
  if (nilu_pushnumber(N, (double)nilu_gettop(N)) != NILU_OK) return NILU_FAIL;
  return 1;
}

static int refuses(NiluState *N) {
  (void)N;
  return NILU_FAIL;
}

static const char *case_a_function_of_the_hosts_sees_the_arguments(void) {
  static const struct {
    const char *source;
    double seen;
  } cases[] = {
      {"return top()", 0.0},
      {"return top(1, 2, 3)", 3.0},
      /* Locals below the call, which it cannot reach. */
      {"local a = 1 local b = 2 local c = 3 return top(9)", 1.0},
      /* A temporary above the call: + needs a register after the call's result. */
      {"return top(9) + 0", 1.0},
      {"local function f(n) return top(n, n) end return f(4)", 2.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_pushcfunction(N, count_arguments) != NILU_OK || nilu_setglobal(N, "top") != NILU_OK) {
    failure = "a host could not put its function in the environment";
  }

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].seen) {
      failure = "a function of the host's saw a different number of arguments";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_function_of_the_hosts_refusing_fails_the_program(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* NILU_FAIL is the one way a function of yours says no, and from a program it fails the
  * whole call: there is no pcall to catch it with. */
  if (nilu_pushcfunction(N, refuses) != NILU_OK || nilu_setglobal(N, "no") != NILU_OK) {
    failure = "a host could not put its function in the environment";
  } else if (nilu_loadstring(N, "local x = 1 return no(x) + 1", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
    failure = "a function of the host's refusing was not a runtime failure";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TNIL || nilu_settop(N, 0) != NILU_OK) {
    /* One nil, what a bare refusal carries, and nothing else. */
    failure = "a failed call left something other than the nil it carries";
  } else if (nilu_loadstring(N, "return 1 + 1", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 2.0) {
    failure = "the state did not work after a refusal";
  }

  nilu_close(N);
  return failure;
}

/* ── a metatable ────────────────────────────────────────────────────────────── */

/* Answers 99 for any key, so a host can see which call consulted it. */
static int always_99(NiluState *N) {
  (void)N;
  if (nilu_pushnumber(N, 99) != NILU_OK) return NILU_FAIL;
  return 1;
}

static const char *case_a_host_sets_and_reads_a_metatable(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A table has no metatable until one is set, and nilu_getmetatable pushes nil rather
  * than pushing nothing -- which is where it deviates from lua_getmetatable. */
  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_getmetatable(N, 1) != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
    failure = "a fresh table already had a metatable";
  } else if (nilu_settop(N, 1) != NILU_OK) {
    failure = "the stack would not be trimmed";
  } else if (nilu_newtable(N) != NILU_OK || nilu_setmetatable(N, 1) != NILU_OK) {
    failure = "a metatable would not be set";
  } else if (nilu_gettop(N) != 1) {
    failure = "nilu_setmetatable did not pop the metatable";
  } else if (nilu_getmetatable(N, 1) != NILU_OK || nilu_type(N, -1) != NILU_TTABLE) {
    failure = "the metatable did not come back";
  } else if (nilu_settop(N, 1) != NILU_OK || nilu_pushnil(N) != NILU_OK ||
             nilu_setmetatable(N, 1) != NILU_OK) {
    failure = "nil would not remove the metatable";
  } else if (nilu_getmetatable(N, 1) != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
    failure = "the metatable was not removed";
  }

  /* Only a table has one, and the wrong kind of value is a status rather than an abort. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK) {
      failure = "a number would not go on the stack";
    } else if (nilu_getmetatable(N, 1) != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
      failure = "a number reported a metatable";
    } else if (nilu_settop(N, 1) != NILU_OK || nilu_newtable(N) != NILU_OK ||
               nilu_setmetatable(N, 1) != NILU_ERR_TYPE) {
      failure = "setting the metatable of a number was not a type error";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_reads_through_a_metamethod(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* nilu_gettable consults __index and nilu_rawget does not. */
  if (nilu_newtable(N) != NILU_OK || nilu_newtable(N) != NILU_OK) {
    failure = "two tables would not go on the stack";
  } else if (nilu_pushstring(N, "__index") != NILU_OK ||
             nilu_pushcfunction(N, always_99) != NILU_OK || nilu_settable(N, 2) != NILU_OK) {
    failure = "the metatable would not be filled";
  } else if (nilu_setmetatable(N, 1) != NILU_OK) {
    failure = "the metatable would not be set";
  } else if (nilu_pushstring(N, "missing") != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "a host could not read through the metamethod";
  } else if (nilu_tonumber(N, -1) != 99.0) {
    failure = "nilu_gettable did not consult __index";
  } else if (nilu_settop(N, 1) != NILU_OK) {
    failure = "the stack would not be trimmed";
  } else if (nilu_pushstring(N, "missing") != NILU_OK || nilu_rawget(N, 1) != NILU_OK) {
    failure = "a host could not read past the metamethod";
  } else if (nilu_type(N, -1) != NILU_TNIL) {
    failure = "nilu_rawget consulted __index";
  }

  /* nilu_settable writes through __newindex, and nilu_rawset writes past it. */
  if (failure == NULL) {
    if (nilu_settop(N, 1) != NILU_OK || nilu_pushstring(N, "k") != NILU_OK ||
        nilu_pushnumber(N, 1) != NILU_OK || nilu_rawset(N, 1) != NILU_OK) {
      failure = "a host could not write past the metamethod";
    } else if (nilu_pushstring(N, "k") != NILU_OK || nilu_rawget(N, 1) != NILU_OK ||
               nilu_tonumber(N, -1) != 1.0) {
      failure = "what nilu_rawset wrote is not there";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_metamethod_runs_a_program_inside_a_c_call(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The cost this version has: nilu_gettable can now call a function written in Nilu, so
  * it can answer anything a call can answer. Here the handler fails, and the status the
  * host gets is the call's. */
  if (nilu_loadstring(N, "local mt = {} mt.__index = function() return 1 + nil end "
                         "local t = {} setmetatable(t, mt) return t",
                      NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the program did not build the table";
  } else if (nilu_pushstring(N, "missing") != NILU_OK) {
    failure = "a key would not go on the stack";
  } else if (nilu_gettable(N, 1) != NILU_ERR_TYPE) {
    failure = "a failing metamethod did not fail the host's read";
  } else if (nilu_rawget(N, 1) == NILU_ERR_TYPE) {
    /* And the raw pair cannot fail that way, which is why it exists. */
    failure = "nilu_rawget ran the metamethod";
  }

  nilu_close(N);
  return failure;
}

static const char *case_metatables_run_from_source(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* A prototype: __index as a table. */
      {"local base = {} base.n = 7 local mt = {} mt.__index = base "
       "local t = {} setmetatable(t, mt) return t.n",
       7.0},
      /* A default: __index as a function. */
      {"local mt = {} mt.__index = function() return 5 end "
       "local t = {} setmetatable(t, mt) return t.anything",
       5.0},
      /* What the table has wins. */
      {"local base = {} base.n = 7 local mt = {} mt.__index = base "
       "local t = {} t.n = 1 setmetatable(t, mt) return t.n",
       1.0},
      /* __newindex sends the write elsewhere, and rawget proves the table is untouched. */
      {"local store = {} local mt = {} mt.__newindex = store "
       "local t = {} setmetatable(t, mt) t.k = 4 "
       "if rawget(t, \"k\") == nil then return store.k end return 0",
       4.0},
      /* A key the table already has is written in place. */
      {"local store = {} local mt = {} mt.__newindex = store "
       "local t = {} t.k = 1 setmetatable(t, mt) t.k = 4 return t.k",
       4.0},
      /* A read-only table, which is what __newindex as a function is for. */
      {"local mt = {} mt.__newindex = function() end "
       "local t = {} setmetatable(t, mt) t.k = 9 "
       "if t.k == nil then return 1 end return 0",
       1.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  /* A chain that loops is a status, not a hang: without the limit this case would not
  * return, because the loop is inside one instruction and no hook can reach it. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local mt = {} local t = {} setmetatable(t, mt) mt.__index = t "
                           "return t.nothing",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a looping __index chain was not refused";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── an operator's metamethod ───────────────────────────────────────────────── */

static const char *case_operator_metamethods_run_from_source(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* The arithmetic, from either operand. */
      {"local mt = {} mt.__add = function() return 7 end "
       "local t = {} setmetatable(t, mt) return t + 1",
       7.0},
      {"local mt = {} mt.__add = function() return 7 end "
       "local t = {} setmetatable(t, mt) return 1 + t",
       7.0},
      /* Two numbers never look at a metatable, which is what makes this additive. */
      {"return 1 + 2", 3.0},
      /* __unm is called with the operand twice, which is Lua's shape. */
      {"local mt = {} mt.__unm = function(a, b) if a == b then return 1 end return 0 end "
       "local t = {} setmetatable(t, mt) return -t",
       1.0},
      /* # consults __len before the border, so a table with one never computes it. */
      {"local mt = {} mt.__len = function() return 42 end "
       "local t = {} t[1] = 1 setmetatable(t, mt) return #t",
       42.0},
      /* rawlen goes past it. */
      {"local mt = {} mt.__len = function() return 42 end "
       "local t = {} t[1] = 1 setmetatable(t, mt) return rawlen(t)",
       1.0},
      /* __eq, for two tables and nothing else. */
      {"local mt = {} mt.__eq = function() return true end "
       "local a = {} setmetatable(a, mt) local b = {} setmetatable(b, mt) "
       "if a == b then return 1 end return 0",
       1.0},
      {"local mt = {} mt.__eq = function() return true end "
       "local t = {} setmetatable(t, mt) if t == 1 then return 1 end return 0",
       0.0},
      {"local mt = {} mt.__eq = function() return true end "
       "local a = {} setmetatable(a, mt) local b = {} setmetatable(b, mt) "
       "if rawequal(a, b) then return 1 end return 0",
       0.0},
      /* __lt answers all four comparisons, because > and >= swap the operands. */
      {"local mt = {} mt.__lt = function() return true end "
       "local t = {} setmetatable(t, mt) local n = 0 "
       "if t < t then n = n + 1 end if t > t then n = n + 2 end return n",
       3.0},
      /* The answer is a truth value, so 0 is true. */
      {"local mt = {} mt.__lt = function() return 0 end "
       "local t = {} setmetatable(t, mt) if t < t then return 1 end return 0",
       1.0},
      /* __call: the table becomes the first argument. */
      {"local mt = {} mt.__call = function(self, a, b) return a + b end "
       "local t = {} setmetatable(t, mt) return t(1, 2)",
       3.0},
      {"local mt = {} mt.__call = function(self) return self.n end "
       "local t = {} t.n = 9 setmetatable(t, mt) return t()",
       9.0},
  };
  static const char *const type_errors[] = {
      /* Still refused when neither operand has one. */
      "local t = {} return t + 1", "local t = {} return -t", "return #1",
      "local t = {} return t .. \"x\"", "local t = {} return t < t",
      "local t = {} return t()",
      /* __le is not reached through __lt: Lua 5.4 removed that fallback. */
      "local mt = {} mt.__lt = function() return true end local t = {} setmetatable(t, mt) return t <= t"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  for (i = 0; failure == NULL && i < (int)(sizeof type_errors / sizeof type_errors[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, type_errors[i], NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "an operator with no metamethod was not a type error";
    }
  }

  /* A __call chain that loops is a status: without the limit this would not return. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local mt = {} local t = {} setmetatable(t, mt) mt.__call = t "
                           "return t()",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a looping __call chain was not refused";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_compares_through_a_metamethod(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  /* nilu_compare lets a host compare values it cannot inspect.
  * A table with __eq is such a value. */
  if (nilu_loadstring(N, "local mt = {} mt.__eq = function() return true end "
                         "local a = {} setmetatable(a, mt) return a",
                      NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_newtable(N) != NILU_OK) {
    failure = "the program did not build the table";
  } else if (nilu_compare(N, 1, 2, NILU_OPEQ) != NILU_OK) {
    failure = "a host could not compare through __eq";
  } else if (nilu_toboolean(N, -1) != 1) {
    failure = "nilu_compare did not consult __eq";
  } else if (nilu_rawequal(N, 1, 2) != 0) {
    failure = "nilu_rawequal consulted __eq";
  } else if (nilu_rawequal(N, 1, 1) != 1) {
    failure = "a table is not raw-equal to itself";
  }

  /* Numbers compare without a metatable, and > is the arguments swapped. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK ||
        nilu_pushnumber(N, 2) != NILU_OK) {
      failure = "two numbers would not go on the stack";
    } else if (nilu_compare(N, 1, 2, NILU_OPLT) != NILU_OK || nilu_toboolean(N, -1) != 1) {
      failure = "1 < 2 is not true";
    } else if (nilu_compare(N, 2, 1, NILU_OPLT) != NILU_OK || nilu_toboolean(N, -1) != 0) {
      failure = "2 < 1 is not false";
    } else if (nilu_compare(N, 1, 1, NILU_OPLE) != NILU_OK || nilu_toboolean(N, -1) != 1) {
      failure = "1 <= 1 is not true";
    }
  }

  /* Equality is total and ordering is not: that difference survives metamethods. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1) != NILU_OK ||
        nilu_pushnil(N) != NILU_OK) {
      failure = "a number and nil would not go on the stack";
    } else if (nilu_compare(N, 1, 2, NILU_OPEQ) != NILU_OK || nilu_toboolean(N, -1) != 0) {
      failure = "1 == nil is not false";
    } else if (nilu_compare(N, 1, 2, NILU_OPLT) != NILU_ERR_TYPE) {
      failure = "1 < nil was not a type error";
    }
  }

  /* And a host reads a length through __len, or past it. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local mt = {} mt.__len = function() return 42 end "
                           "local t = {} t[1] = 1 setmetatable(t, mt) return t",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the program did not build the table";
    } else if (nilu_len(N, 1) != NILU_OK || nilu_tonumber(N, -1) != 42.0) {
      failure = "nilu_len did not consult __len";
    } else if (nilu_rawlen(N, 1) != NILU_OK || nilu_tonumber(N, -1) != 1.0) {
      failure = "nilu_rawlen consulted __len";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── several values ─────────────────────────────────────────────────────────── */

static int count_given(NiluState *N) {
  if (nilu_pushnumber(N, (double)nilu_gettop(N)) != NILU_OK) return NILU_FAIL;
  return 1;
}

static const char *case_several_values_run_from_source(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* return a, b, and local a, b = f(). */
      {"local function two() return 1, 2 end local a, b = two() return a * 10 + b", 12.0},
      /* Short lists pad with nil and long ones drop. */
      {"local function one() return 1 end local a, b = one() if b == nil then return 1 end return 0", 1.0},
      {"local a = 1, 2 return a", 1.0},
      /* return f() forwards all of f's. */
      {"local function two() return 1, 2 end local function fwd() return two() end "
       "local a, b = fwd() return a * 10 + b",
       12.0},
      /* Only the last expression expands. */
      {"local function two() return 1, 2 end local a, b = two(), 9 return a * 10 + b", 19.0},
      /* (f()) is one value. */
      {"local function two() return 1, 2 end local a, b = (two()) if b == nil then return 1 end return 0", 1.0},
      /* An argument list is the third consumer. */
      {"local function two() return 1, 2 end return given(two())", 2.0},
      {"local function two() return 1, 2 end return given(two(), 9)", 2.0},
      {"local function nothing() end return given(nothing())", 0.0},
      {"local function two() return 1, 2 end return math.max(two())", 2.0},
      /* Several targets, and the swap. */
      {"local a, b = 1, 2 a, b = b, a return a * 10 + b", 21.0},
      {"local t = {} local x t[1], x = 7, 8 return t[1] * 10 + x", 78.0},
      {"x, y = 3, 4 return x * 10 + y", 34.0},
      {"local t = {} t.a = 1 t.b = 2 t.a, t.b = t.b, t.a return t.a * 10 + t.b", 21.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";
  if (nilu_openlibs(N) != NILU_OK || nilu_pushcfunction(N, count_given) != NILU_OK ||
      nilu_setglobal(N, "given") != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_asks_for_every_result(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* NILU_MULTRET leaves every result, and nilu_gettop says how many there were. This
  * header named the absence of it two versions before it arrived. */
  if (nilu_loadstring(N, "return 1, 2, 3", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, NILU_MULTRET) != NILU_OK) {
    failure = "a call asking for every result did not succeed";
  } else if (nilu_gettop(N) != 3) {
    failure = "the results are not all there";
  } else if (nilu_tonumber(N, 1) != 1.0 || nilu_tonumber(N, 3) != 3.0) {
    failure = "the results are not in order";
  }

  /* A program that returns nothing leaves nothing, where asking for one gives nil. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, "return", NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, NILU_MULTRET) != NILU_OK || nilu_gettop(N) != 0) {
      failure = "a program returning nothing left something";
    } else if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, "return", NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_type(N, -1) != NILU_TNIL) {
      failure = "asking for one result did not give nil";
    }
  }

  /* And a native function's several results reach a program now. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushcfunction(N, two_results) != NILU_OK ||
        nilu_setglobal(N, "two") != NILU_OK) {
      failure = "a host could not register its function";
    } else if (nilu_loadstring(N, "local a, b = two() return a * 10 + b", NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 12.0) {
      failure = "a program did not receive both of a host function's results";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a tail call ────────────────────────────────────────────────────────────── */

static const char *case_a_tail_call_does_not_nest(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* `return f(...)` reuses the frame, so a recursion written that way runs past the call
  * depth limit -- where the same shape answered NILU_ERR_CALL_DEPTH in every version
  * before this one. Ten thousand frames deep would have been refused at 200. */
  if (nilu_loadstring(N,
                      "local function down(self, n) if n == 0 then return \"done\" end "
                      "return self(self, n - 1) end return down(down, 10000)",
                      NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a tail recursion did not run";
  } else if (strcmp(nilu_tostring(N, -1), "done") != 0) {
    failure = "a tail recursion did not finish";
  }

  /* And the shapes that are NOT tail calls keep the limit. The parentheses are the rule:
  * `return (f())` is one value and not a call. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local function down(self, n) return (self(self, n + 1)) end "
                           "return down(down, 0)",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_CALL_DEPTH) {
      failure = "a recursion that is not a tail call was not refused";
    }
  }

  /* A tail call to a function of the host's runs it and returns its results: a native
  * function does not run in the VM's loop, so there is no frame to reuse. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushcfunction(N, add) != NILU_OK ||
        nilu_setglobal(N, "add") != NILU_OK) {
      failure = "a host could not register its function";
    } else if (nilu_loadstring(N, "local function go(a, b) return add(a, b) end return go(20, 22)",
                               NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 42.0) {
      failure = "a tail call to a host function did not answer";
    }
  }

  /* A tail call forwards every result, because its results are the caller's. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local function two() return 1, 2 end "
                           "local function go() return two() end "
                           "local a, b = go() return a * 10 + b",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 12.0) {
      failure = "a tail call did not forward both results";
    }
  }

  /* A captured variable is closed before the frame is reused, so a closure made in the
  * frame a tail call abandoned still sees its own value. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local function go(n) local x = n * 2 "
                           "local function held() return x end "
                           "return (function() return held() end)() end "
                           "return go(21)",
                        NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 42.0) {
      failure = "a cell did not survive the frame being reused";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a vararg function ──────────────────────────────────────────────────────── */

static const char *case_a_vararg_function_from_a_host(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* '...' is what the caller passed past the fixed parameters. The library's own
  * select is how a program counts them; a host's function sees them as arguments. */
      {"local function f(...) return seen(...) end return f(1, 2, 3)", 3.0},
      {"local function f(a, ...) return seen(...) end return f(1, 2, 3)", 2.0},
      {"local function f(...) return seen(...) end return f()", 0.0},
      {"local function f(...) return seen(..., 9) end return f(1, 2, 3)", 2.0},
      {"local function f(...) local a, b = ... return a * 10 + b end return f(7, 8)", 78.0},
      {"local function f(...) return select('#', ...) end return f(1, 2, 3, 4)", 4.0},
      /* The parentheses truncate it to one value, as they do a call. */
      {"local function f(...) return (...) end return f(6, 7)", 6.0},
      /* A tail call of a vararg function builds its table too. */
      {"local function t(...) return seen(...) end local function g(...) return t(...) end "
       "return g(1, 2, 3, 4, 5)",
       5.0}};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) {
    failure = "the library would not open";
  } else if (nilu_pushcfunction(N, count_arguments) != NILU_OK ||
             nilu_setglobal(N, "seen") != NILU_OK) {
    failure = "a host could not register its function";
  }

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
  }

  /* '...' outside a vararg function is a syntax error and says where, and nothing may
  * follow '...' in a parameter list. */
  if (failure == NULL) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    /* Inside a plain function: the chunk itself is vararg, so
  * `return ...` at top level compiles, and this source is what is refused. */
    if (nilu_loadstring(N, "return function() return ... end", &where) != NILU_ERR_SYNTAX) {
      failure = "'...' outside a vararg function was accepted";
    } else if (where.line != 1 || where.column != 26) {
      failure = "'...' outside a vararg function did not say where";
    } else if (nilu_loadstring(N, "local function f(..., a) end", NULL) != NILU_ERR_SYNTAX) {
      failure = "a parameter after '...' was accepted";
    } else if (nilu_loadstring(N, "local function f(...) return function() return ... end end",
                               NULL) != NILU_ERR_SYNTAX) {
      failure = "'...' inside a nested plain function was accepted";
    }
  }

  /* A chunk is a vararg function, so arguments a host pushes before calling
  * one reach it as `...`. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "return select('#', ...), ...", NULL) != NILU_OK) {
      failure = "a chunk reading ... would not compile";
    } else if (nilu_pushnumber(N, 1.0) != NILU_OK || nilu_pushnumber(N, 2.0) != NILU_OK) {
      failure = "an argument would not go on the stack";
    } else if (nilu_call(N, 2, 3) != NILU_OK) {
      failure = "a chunk given two arguments did not run";
    } else if (nilu_tonumber(N, 1) != 2.0 || nilu_tonumber(N, 2) != 1.0 || nilu_tonumber(N, 3) != 2.0) {
      failure = "a chunk did not receive the two arguments the host pushed";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a number becomes text ──────────────────────────────────────────────────── */

static const char *case_a_number_becomes_text(void) {
  static const struct {
    const char *source;
    const char *answer;
  } cases[] = {
      /* A whole number up to 2^53 is written as an integer, without ".0": every Nilu
       * number is a float, and up to there every whole one is exact. */
      {"return tostring(3)", "3"},
      {"return tostring(1.5)", "1.5"},
      {"return tostring(#\"hi\")", "2"},
      /* No exponent up to 2^53 either: these are what lua5.5 prints for the same
       * integers. */
      {"return tostring(100000000000000)", "100000000000000"},
      {"return tostring(1000000000000000)", "1000000000000000"},
      {"return tostring(9007199254740992)", "9007199254740992"},
      /* The shortest numeral that reads back, where lua5.5 writes 17 digits. */
      {"return tostring(1 / 3)", "0.3333333333333333"},
      /* Nilu's own three: Lua's spelling for these is its C library's. */
      {"return tostring(0 / 0)", "nan"},
      {"return tostring(1 / 0)", "inf"},
      {"return tostring(0 - 1 / 0)", "-inf"},
      /* The four that answer for themselves. */
      {"return tostring(nil)", "nil"},
      {"return tostring(true)", "true"},
      {"return tostring(false)", "false"},
      {"return tostring(\"hi\")", "hi"},
      /* It is a string, so the operators that want one take it. */
      {"return tostring(3) .. \"!\"", "3!"},
      /* __tostring answers first, and it receives the value. */
      {"local t, mt = {}, {} mt.__tostring = function() return \"a point\" end "
       "setmetatable(t, mt) return tostring(t)",
       "a point"},
      {"local t, mt = {}, {} t.label = \"named\" "
       "mt.__tostring = function(self) return self.label end "
       "setmetatable(t, mt) return tostring(t)",
       "named"}};
  const char *failure = NULL;
  const char *text;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if ((text = nilu_tostring(N, -1)) == NULL) {
      failure = "tostring did not answer a string";
    } else if (strcmp(text, cases[i].answer) != 0) {
      failure = "the numeral is not the one expected";
    }
  }

  /* nilu_tolstring converts a number in place, as lua_tolstring does -- so reading a slot
  * changes what nilu_type says about it. The hazard, asserted and not only documented. */
  if (failure == NULL) {
    size_t len = 99;
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 10.0) != NILU_OK) {
      failure = "a number would not go on the stack";
    } else if (nilu_type(N, 1) != NILU_TNUMBER) {
      failure = "a pushed number is not a number";
    } else if ((text = nilu_tolstring(N, 1, &len)) == NULL || strcmp(text, "10.0") != 0) {
      /* A float keeps .0, as lua5.5 spells it. */
      failure = "a number did not convert";
    } else if (len != 4) {
      failure = "the converted length is wrong";
    } else if (nilu_type(N, 1) != NILU_TSTRING) {
      failure = "the slot is not a string after the conversion";
    }
  }

  /* And what has no spelling still answers NULL with the length zeroed. */
  if (failure == NULL) {
    size_t len = 99;
    if (nilu_settop(N, 0) != NILU_OK || nilu_newtable(N) != NILU_OK) {
      failure = "a table would not go on the stack";
    } else if (nilu_tolstring(N, 1, &len) != NULL || len != 0) {
      failure = "a table converted to a string";
    } else if (nilu_pushboolean(N, 1) != NILU_OK || nilu_tostring(N, -1) != NULL) {
      failure = "a boolean converted to a string";
    }
  }

  /* An identity tells two objects apart. The address differs on every run, so what can be
  * checked is that one object is one identity and two objects are two. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_newtable(N) != NILU_OK ||
        nilu_newtable(N) != NILU_OK) {
      failure = "two tables would not go on the stack";
    } else if (nilu_topointer(N, 1) == NULL || nilu_topointer(N, 2) == NULL) {
      failure = "a table has no identity";
    } else if (nilu_topointer(N, 1) == nilu_topointer(N, 2)) {
      failure = "two tables share an identity";
    } else if (nilu_topointer(N, 1) != nilu_topointer(N, 1)) {
      failure = "one table has two identities";
    } else if (nilu_pushnumber(N, 1.0) != NILU_OK || nilu_topointer(N, -1) != NULL) {
      failure = "an immediate value has an identity";
    }
  }

  /* A table is spelled by its kind and its identity, and __name replaces the kind. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local t, mt = {}, {} mt.__name = \"Point\" setmetatable(t, mt) "
                           "return string.sub(tostring(t), 1, 7)",
                        NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if ((text = nilu_tostring(N, -1)) == NULL || strcmp(text, "Point: ") != 0) {
      failure = "__name did not replace the kind";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_calls_what_a_program_made_callable(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* setmetatable is a library function, so the program below needs the library open. */
  if (nilu_openlibs(N) != NILU_OK) {
    nilu_close(N);
    return "the library would not open";
  }

  /* A table with __call is callable, and a host calling one gets what a program gets:
  * nilu_call does not abort on a value that is not a function. */
  if (nilu_loadstring(N, "local t, mt = {}, {} "
                         "mt.__call = function(self, n) return n + 1 end "
                         "setmetatable(t, mt) return t",
                      NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_type(N, -1) != NILU_TTABLE) {
    failure = "a program did not hand back its callable table";
  } else if (nilu_pushnumber(N, 41.0) != NILU_OK) {
    failure = "an argument would not go on the stack";
  } else if (nilu_call(N, 1, 1) != NILU_OK || nilu_tonumber(N, -1) != 42.0) {
    failure = "a host could not call a table with __call";
  }

  /* And what is not callable at all is NILU_ERR_TYPE -- the same answer a program gets --
  * with the function and its arguments popped, as every failed call leaves them. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK || nilu_pushnumber(N, 1.0) != NILU_OK ||
        nilu_pushnumber(N, 2.0) != NILU_OK) {
      failure = "a number would not go on the stack";
    } else if (nilu_call(N, 1, 1) != NILU_ERR_TYPE) {
      failure = "calling a number was not a type error";
    } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TSTRING ||
               strcmp(nilu_tostring(N, -1), "attempt to call a number value") != 0 ||
               nilu_settop(N, 0) != NILU_OK) {
      /* The function is gone and the sentence the failure carries is there.
  * No name and no line before it: there is no Nilu frame to name, which is what
  * luaG_runerror does too -- it writes a position only for a Lua frame. */
      failure = "a failed call left the function on the stack, or not the sentence it carries";
    } else if (nilu_pushnil(N) != NILU_OK || nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "calling nil was not a type error";
    }
  }

  /* The one a script can reach: tostring calls a __tostring the script chose, so a
  * __tostring that is not callable has to be a refusal and never the end of the host's
  * process. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, "local t, mt = {}, {} mt.__tostring = 5 "
                                  "setmetatable(t, mt) return tostring(t)",
                               NULL) != NILU_OK) {
      failure = "the source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a __tostring that is not callable was not refused";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a numeral becomes a number ─────────────────────────────────────────────── */

static const char *case_a_numeral_becomes_a_number(void) {
  static const struct {
    const char *source;
    double answer;
  } numerals[] = {
      /* Exponents and hexadecimals, read as Lua reads them. */
      {"return 1e15", 1e15},
      {"return 1E15", 1e15},
      {"return 1e+15", 1e15},
      {"return 1e-05", 1e-5},
      {"return 0x10", 16.0},
      {"return 0x1p4", 16.0},
      {"return .5", 0.5},
      {"return 5.", 5.0},
      /* A sign is read only after an exponent mark, so neither of these is one numeral. */
      {"return 3-4", -1.0},
      {"return 0xe+1", 15.0},
      /* A hexadecimal above what a 64-bit integer holds wraps around, to -1 as in
       * lua5.5. */
      {"return 0xFFFFFFFFFFFFFFFF", -1.0},
      /* tonumber, both forms. */
      {"return tonumber(\"1e15\")", 1e15},
      {"return tonumber(\"  7  \")", 7.0},
      {"return tonumber(3)", 3.0},
      {"return tonumber(\"ff\", 16)", 255.0},
      {"return tonumber(\"101\", 2)", 5.0}};
  static const char *const malformed[] = {"return 1e",    "return 1e+", "return 0x",
                                          "return 1_0",   "return 0b101", "return 1..2",
                                          "return 0x1z"};
  static const char *const not_a_number[] = {
      "return tonumber(\"x\")",   "return tonumber(\"inf\")", "return tonumber(\"1_0\")",
      "return tonumber(true)",    "return tonumber(nil)",     "return tonumber(\"8\", 8)",
      "return tonumber(\"0x10\", 16)"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof numerals / sizeof numerals[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, numerals[i].source, NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != numerals[i].answer) {
      failure = "the number is not the one expected";
    }
  }

  /* A malformed number is a syntax error with a position -- Lua's "malformed number". */
  for (i = 0; failure == NULL && i < (int)(sizeof malformed / sizeof malformed[0]); i++) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, malformed[i], &where) != NILU_ERR_SYNTAX) {
      failure = "a malformed number was accepted";
    } else if (where.line != 1 || where.column < 1) {
      failure = "a malformed number did not say where";
    }
  }

  /* tonumber answers nil rather than refusing: it is the question "is this a number". */
  for (i = 0; failure == NULL && i < (int)(sizeof not_a_number / sizeof not_a_number[0]);
       i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, not_a_number[i], NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "tonumber refused where it should answer nil";
    } else if (nilu_type(N, -1) != NILU_TNIL) {
      failure = "tonumber did not answer nil";
    }
  }

  /* A bad base is a refusal and not nil, because that is a different fact. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "return tonumber(\"1\", 37)", NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a base out of range was not refused";
    }
  }

  /* What tostring writes, tonumber reads -- the round trip, from inside the language. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local x = 1 / 3 if tonumber(tostring(x)) == x then return 1 end "
                           "return 0",
                        NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 1.0) {
      failure = "a number did not survive being written and read";
    }
  }

  /* And a host has the same reader. The whole length has to be the numeral, so a trailing
  * byte fails -- which is also how a numeral with a zero byte inside it fails. */
  if (failure == NULL) {
    static const char with_zero[] = "1\0 2";
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_stringtonumber(N, "  12.5  ", 8) != NILU_OK ||
               nilu_tonumber(N, -1) != 12.5) {
      failure = "a host could not read a numeral";
    } else if (nilu_stringtonumber(N, "12x", 3) != NILU_ERR_SYNTAX) {
      failure = "a trailing byte was accepted";
    } else if (nilu_stringtonumber(N, "inf", 3) != NILU_ERR_SYNTAX) {
      failure = "inf was accepted as a numeral";
    } else if (nilu_stringtonumber(N, with_zero, sizeof with_zero - 1) != NILU_ERR_SYNTAX) {
      failure = "a numeral with a zero byte in it was accepted";
    } else if (nilu_gettop(N) != 1) {
      failure = "a refused numeral left something on the stack";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── the library takes what it can now write ────────────────────────────────── */

static const char *case_the_library_packs_unpacks_and_slices(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      /* table.pack: n counts the arguments, not the keys. */
      {"local t = table.pack(1, 2, 3) return t.n", 3.0},
      {"local t = table.pack() return t.n", 0.0},
      {"local t = table.pack(nil, 2) return t.n", 2.0},
      {"local function f(...) return table.pack(...).n end return f(4, 5, 6, 7)", 4.0},
      /* table.unpack: i defaults to 1 and j to #t, and i > e is no values. */
      {"local t = {} t[1] = 4 t[2] = 5 t[3] = 6 return select('#', table.unpack(t))", 3.0},
      {"local t = {} t[1] = 4 t[2] = 5 t[3] = 6 return select('#', table.unpack(t, 2))", 2.0},
      {"local t = {} return select('#', table.unpack(t, 1, 0))", 0.0},
      /* pack and unpack are each other's inverse through n, which is why n exists. */
      {"local t = table.pack(1, nil, 3) return select('#', table.unpack(t, 1, t.n))", 3.0},
      /* table.move, both directions, measured against lua5.5. */
      {"local t = {} t[1] = 1 t[2] = 2 t[3] = 3 table.move(t, 1, 3, 2) "
       "return t[1] * 1000 + t[2] * 100 + t[3] * 10 + t[4]",
       1123.0},
      {"local t = {} t[1] = 1 t[2] = 2 t[3] = 3 table.move(t, 2, 3, 1) "
       "return t[1] * 100 + t[2] * 10 + t[3]",
       233.0},
      {"local a, b = {}, {} a[1] = 9 a[2] = 8 table.move(a, 1, 2, 1, b) "
       "return b[1] * 10 + b[2]",
       98.0},
      /* string.byte's slice, and the default end is the raw second argument. */
      {"return select('#', string.byte(\"abc\", 1, 3))", 3.0},
      {"local a, b, cc = string.byte(\"abc\", 1, 3) return a * 10000 + b * 100 + cc",
       979899.0},
      {"return string.byte(\"abc\", -1)", 99.0},
      {"return select('#', string.byte(\"abc\", 2, -1))", 2.0},
      {"return select('#', string.byte(\"abc\", 5))", 0.0}};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
  }

  /* A zero byte is a byte like any other, and a source cannot spell one: \0 is not one of
  * this grammar's escapes. So the host pushes the string and the program slices it. */
  if (failure == NULL) {
    static const char with_zero[] = "a\0b";
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_pushlstring(N, with_zero, sizeof with_zero - 1) != NILU_OK ||
               nilu_setglobal(N, "zeroed") != NILU_OK) {
      failure = "a host could not register its string";
    } else if (nilu_loadstring(N, "local a, b, cc = string.byte(zeroed, 1, 3) "
                                  "return a * 10000 + b * 100 + cc",
                               NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 970098.0) {
      failure = "a zero byte did not slice like any other byte";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a global can be declared ───────────────────────────────────────────────── */

static const char *case_a_global_can_be_declared(void) {
  /* Every row here was measured against lua5.5 before it was written down. */
  static const char *const allowed[] = {
      "global x  x = 1",
      /* Before the declaration, which is still a global. */
      "y = 1  global x",
      /* The block ended it. */
      "if true then global x end  y = 1",
      "while false do global x end  y = 1",
      /* A declaration inside a function does not leak outward. */
      "local function f() global x end  y = 1",
      /* Declarations accumulate, and a duplicate is allowed. */
      "global x  global y  y = 1",
      "global x, y  x = 1 y = 2",
      /* A '*' in scope wins, whichever order they come in. */
      "global *  y = 1",
      "global *  global x  y = 1",
      /* And `global` is still a name: nothing a program does today changes. */
      "local global = 1 return global",
      "global = 1 return global",
      "local t = {} t.global = 1 return t.global"};
  static const char *const refused[] = {
      "global x  y = 1",
      "global x  return y",
      /* Still in scope inside a block. */
      "global x  if true then y = 1 end",
      /* A nested function inherits it. */
      "global x  local function f() y = 1 end",
      /* A '*' ends with its block. */
      "global x  if true then global * y = 1 end  z = 1",
      /* A local does not relax it, even one with the declared name. */
      "global x  local x = 2  y = 1",
      /* The library is a global like any other -- this is the consequence a reader meets
  * first, and lua5.5 refuses `global x print(y)` on print rather than on y. */
      "global x  return type(1)"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof allowed / sizeof allowed[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, allowed[i], NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    }
  }

  /* A refusal is a syntax error with a position. */
  for (i = 0; failure == NULL && i < (int)(sizeof refused / sizeof refused[0]); i++) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, refused[i], &where) != NILU_ERR_SYNTAX) {
      failure = "an undeclared global was accepted";
    } else if (where.line != 1 || where.column < 1) {
      failure = "an undeclared global did not say where";
    }
  }

  /* The column points at the name and not at the declaration: in "global x y = 1" the y
  * is the eleventh character. */
  if (failure == NULL) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, "global x  y = 1", &where) != NILU_ERR_SYNTAX) {
      failure = "an undeclared global was accepted";
    } else if (where.column != 11) {
      failure = "the refusal does not point at the name";
    }
  }

  /* A program that declares what it needs runs, library and all. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "global string, answer  answer = string.len(\"hello\")  return answer",
                        NULL) != NILU_OK) {
      failure = "a source that declares what it uses did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 5.0) {
      failure = "a declared program did not run";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── a numeric for ──────────────────────────────────────────────────────────── */

static const char *case_a_numeric_for_counts(void) {
  /* Every answer measured against lua5.5 before it was written down. */
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local t = 0 for i = 1, 5 do t = t + i end return t", 15.0},
      /* The loop test is <= and the skip test is <. */
      {"local n = 0 for i = 1, 1 do n = n + 1 end return n", 1.0},
      {"local n = 0 for i = 1, 0 do n = n + 1 end return n", 0.0},
      {"local t = 0 for i = 1, 10, 3 do t = t + i end return t", 22.0},
      {"local t = 0 for i = 5, 1, 0 - 1 do t = t + i end return t", 15.0},
      {"local n = 0 for i = 1, 5, 0 - 1 do n = n + 1 end return n", 0.0},
      /* Every number here is a float, so a fractional step works. */
      {"local n = 0 for i = 1, 2, 0.5 do n = n + 1 end return n", 3.0},
      {"local n = 0 for i = 1, 2 do for j = 1, 3 do n = n + 1 end end return n", 6.0},
      /* Each turn captures its own control variable: this answered 333 while the variable
  * lived outside the body, and lua5.5 answers 1 2 3. */
      {"local fs = {} for i = 1, 3 do fs[i] = function() return i end end "
       "return fs[1]() * 100 + fs[2]() * 10 + fs[3]()",
       123.0},
      /* in is a keyword. */
      {"local t = {} t[1] = 7 local got = 0 for k, v in pairs(t) do got = v end return got",
       7.0}};
  /* pairs needs the library, which this case opens below. */
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
  }

  /* A zero step is NILU_ERR_RUNTIME, where Lua raises "'for' step is zero". */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "for i = 1, 10, 0 do end return 1", NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a zero step was not refused";
    }
  }

  /* A limit, step or initial value that is not a number is NILU_ERR_TYPE -- a string is
  * not a number here, where Lua's tonumber would coerce one. */
  if (failure == NULL) {
    static const char *const typed[] = {"for i = 1, \"a\" do end return 1",
                                        "for i = \"a\", 1 do end return 1",
                                        "for i = 1, 3, \"a\" do end return 1"};
    for (i = 0; failure == NULL && i < 3; i++) {
      if (nilu_settop(N, 0) != NILU_OK || nilu_loadstring(N, typed[i], NULL) != NILU_OK) {
        failure = "a source that compiles did not compile";
      } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
        failure = "a non-number bound was not a type error";
      }
    }
  }

  /* Assigning to the control variable is refused, which is Lua 5.5's change; a local with
  * the same name is a different variable, which is what the manual says to write. */
  if (failure == NULL) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, "for i = 1, 3 do i = 9 end", &where) != NILU_ERR_SYNTAX) {
      failure = "assigning to the control variable was accepted";
    } else if (where.column != 17) {
      failure = "the refusal does not point at the assignment";
    } else if (nilu_loadstring(N, "for i = 1, 3 do local i = 9 i = 10 end", NULL) != NILU_OK) {
      failure = "a local shadowing the control variable was refused";
    }
  }

  /* for is a keyword, so `local for = 1` is refused. */
  if (failure == NULL) {
    if (nilu_loadstring(N, "local for = 1 return for", NULL) != NILU_ERR_SYNTAX) {
      failure = "for is not reserved";
    } else if (nilu_loadstring(N, "for i = 1 do end", NULL) != NILU_ERR_SYNTAX) {
      failure = "a for without its comma was accepted";
    } else if (nilu_loadstring(N, "local in = 1", NULL) != NILU_ERR_SYNTAX) {
      failure = "in is not reserved";
    }
  }

  /* A loop that cannot end is still the host's problem, and the hook is the answer. */
  if (failure == NULL) {
    watcher_calls = 0;
    watcher_stops = 1;
    nilu_sethook(N, watcher, 1000);
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local n = 0 for i = 1, math.huge do n = n + 1 end return n",
                        NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_INTERRUPTED) {
      failure = "an endless for was not interrupted";
    }
    nilu_sethook(N, NULL, 0);
    watcher_stops = 0;
  }

  nilu_close(N);
  return failure;
}

/* ── a generic for ──────────────────────────────────────────────────────────── */

static const char *case_a_generic_for_walks_a_table(void) {
  /* Every answer measured against lua5.5 before it was written down. */
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local t = {} t[1] = 10 t[2] = 20 local n = 0 "
       "for k, v in pairs(t) do n = n + v end return n",
       30.0},
      {"local t = {} t.a = 1 t.b = 2 t.c = 3 local n = 0 "
       "for k in pairs(t) do n = n + 1 end return n",
       3.0},
      {"local t = {} local n = 0 for k, v in pairs(t) do n = n + 1 end return n", 0.0},
      /* ipairs counts from 1 to the first absent index, so it needs no order. */
      {"local t = {} t[1] = 5 t[2] = 6 t[3] = 7 local n = 0 "
       "for i, v in ipairs(t) do n = n + i * v end return n",
       38.0},
      {"local t = {} t[1] = 5 t[3] = 7 local n = 0 "
       "for i, v in ipairs(t) do n = n + 1 end return n",
       1.0},
      /* One declared name, which is where the ipairs bug showed: it never stopped. */
      {"local t = {} t[1] = 5 local n = 0 for i in ipairs(t) do n = n + i end return n", 1.0},
      /* A bare generator and state work, because the loop adjusts the list to three. */
      {"local t = {} t[1] = 1 t[2] = 2 local n = 0 "
       "for k, v in next, t do n = n + v end return n",
       3.0},
      /* next walks it once, and next(t) checks whether a table is empty. */
      {"local t = {} t[1] = 1 local k, v = next(t) return k * 10 + v", 11.0},
      {"local t = {} if next(t) == nil then return 1 end return 0", 1.0},
      /* pairs answers four values, as Lua 5.5: the fourth is the value a
  * generic for closes (the owner's answer). */
      {"local t = {} return select('#', pairs(t))", 4.0},
      {"local t = {} return select('#', ipairs(t))", 3.0},
      /* __pairs is honoured, which is how a proxy answers -- next is raw. */
      {"local t, mt, backing = {}, {}, {} backing[1] = 3 backing[2] = 4 "
       "mt.__pairs = function() return next, backing, nil end setmetatable(t, mt) "
       "local n = 0 for k, v in pairs(t) do n = n + v end return n",
       7.0}};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
  }

  /* The order is unspecified and every key is visited exactly once -- which is the only
  * thing that can be asserted about it. The sum catches a repeat and a miss where a
  * count alone would not. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local t = {} t[1] = 1 t[2] = 2 t[4] = 4 t[8] = 8 t.a = 16 "
                           "local seen = 0 for k, v in pairs(t) do seen = seen + v end "
                           "return seen",
                        NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 31.0) {
      failure = "a traversal did not visit every key exactly once";
    }
  }

  /* A key that is not in the table is refused, which is not the same fact as the
  * traversal being over. And something that is not callable is a type error. */
  if (failure == NULL) {
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local t = {} return next(t, 5)", NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_RUNTIME) {
      failure = "a key not in the table was accepted";
    } else if (nilu_settop(N, 0) != NILU_OK ||
               nilu_loadstring(N, "for k, v in 5 do end", NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "a non-callable iterator was not a type error";
    }
  }

  /* The control variable is read only, the second name is not, and in is reserved. */
  if (failure == NULL) {
    if (nilu_loadstring(N, "local t = {} for k, v in pairs(t) do k = 1 end", NULL) !=
        NILU_ERR_SYNTAX) {
      failure = "assigning to the control variable was accepted";
    } else if (nilu_loadstring(N, "local t = {} for k, v in pairs(t) do v = 1 end", NULL) !=
               NILU_OK) {
      failure = "assigning to the second name was refused";
    } else if (nilu_loadstring(N, "local in = 1", NULL) != NILU_ERR_SYNTAX) {
      failure = "in is not reserved";
    } else if (nilu_loadstring(N, "for i do end", NULL) != NILU_ERR_SYNTAX) {
      failure = "a for that is neither form was accepted";
    }
  }

  /* An endless iterator is the host's problem, and a hook can interrupt this one --
  * unlike a library function that walks a range, the loop is VM instructions. */
  if (failure == NULL) {
    watcher_calls = 0;
    watcher_stops = 1;
    nilu_sethook(N, watcher, 1000);
    if (nilu_settop(N, 0) != NILU_OK ||
        nilu_loadstring(N, "local function forever() return 1 end "
                           "local n = 0 for v in forever do n = n + 1 end return n",
                        NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_INTERRUPTED) {
      failure = "an endless generic for was not interrupted";
    }
    nilu_sethook(N, NULL, 0);
    watcher_stops = 0;
  }

  nilu_close(N);
  return failure;
}

/* ── break ──────────────────────────────────────────────────────────────────── */

static const char *case_break_leaves_the_innermost_loop(void) {
  /* Every answer measured against lua5.5 before it was written down. */
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local n = 0 for i = 1, 5 do n = n + 1 break end return n", 1.0},
      {"local n = 0 for i = 1, 5 do n = n + 1 if i == 3 then break end end return n", 3.0},
      {"local n = 0 while true do n = n + 1 if n == 4 then break end end return n", 4.0},
      {"local t = {} t[1] = 1 t[2] = 2 local n = 0 "
       "for k, v in pairs(t) do n = n + 1 break end return n",
       1.0},
      /* The innermost loop wins: three and not nine. */
      {"local n = 0 for i = 1, 3 do for j = 1, 3 do n = n + 1 break end end return n", 3.0},
      /* A block that is not a loop is walked through. */
      {"local n = 0 for i = 1, 5 do if i == 2 then if true then break end end "
       "n = n + 1 end return n",
       1.0},
      /* It need not be last: break is a goto and not a return, so the code after it is
  * unreachable and compiles. Lua 5.1 required it to be last and 5.4 did not. */
      {"local n = 0 for i = 1, 3 do break n = 99 end return n", 0.0},
      /* Cells are closed on the way out. */
      {"local fs = {} for i = 1, 5 do local x = i fs[i] = function() return x end "
       "if i == 2 then break end end return fs[1]() * 10 + fs[2]()",
       12.0},
      {"local held while true do local y = 5 "
       "if true then held = function() return y end break end end return held()",
       5.0}};
  static const char *const refused[] = {
      "break",
      "if true then break end",
      /* A function body does not see a loop around it: Lua's chain is the current
  * function's. */
      "for i = 1, 3 do local f = function() break end end",
      "while true do local f = function() break end end",
      /* And the word is reserved, so `local break = 1` is refused. */
      "local break = 1",
      "local t = {} t.break = 1"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  if (nilu_openlibs(N) != NILU_OK) failure = "the library would not open";

  for (i = 0; failure == NULL && i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
  }

  for (i = 0; failure == NULL && i < (int)(sizeof refused / sizeof refused[0]); i++) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, refused[i], &where) != NILU_ERR_SYNTAX) {
      failure = "a break with no loop around it was accepted";
    } else if (where.line != 1 || where.column < 1) {
      failure = "a refused break did not say where";
    }
  }

  /* The column points at the word: in "if true then break end" it is the fourteenth. */
  if (failure == NULL) {
    NiluError where;
    where.line = 0;
    where.column = 0;
    if (nilu_loadstring(N, "if true then break end", &where) != NILU_ERR_SYNTAX) {
      failure = "a break outside a loop was accepted";
    } else if (where.column != 14) {
      failure = "the refusal does not point at the word";
    }
  }

  /* A loop inside the function IS seen, which is the other half of that rule. */
  if (failure == NULL) {
    if (nilu_loadstring(N, "for i = 1, 3 do local f = function() while true do break end end end",
                        NULL) != NILU_OK) {
      failure = "a loop inside a nested function was not seen";
    }
  }

  nilu_close(N);
  return failure;
}

/* ── running under a collector ──────────────────────────────────────────────── */

static const char *case_a_program_that_makes_garbage_still_answers(void) {
  const char *failure = NULL;
  const char *held;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A collection is invisible from here by design: there is no nilu_gc and no count to
  * read. What a C host can check is that programs still answer correctly while
  * collections happen underneath them, and that what it holds on the stack survives.
  * The reclamation itself is asserted by the Zig tests. */
  if (nilu_pushstring(N, "held by the host") != NILU_OK) {
    failure = "a string would not go on the stack";
  } else if ((held = nilu_tostring(N, 1)) == NULL) {
    failure = "a string would not read back";
  } else if (nilu_loadstring(N,
                             "local n = 0 local i = 0 while i < 400 do local junk = \"a\" .. \"b\" "
                             "local t = {} t[1] = junk n = n + #t i = i + 1 end return n",
                             NULL) != NILU_OK) {
    failure = "a source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a program that makes garbage did not finish";
  } else if (nilu_tonumber(N, -1) != 400.0) {
    failure = "the answer changed while collections happened";
  } else if (strcmp(held, "held by the host") != 0) {
    failure = "a string on the stack did not survive the collections";
  } else if (nilu_loadstring(N, "return \"after\"", NULL) != NILU_OK ||
             nilu_call(N, 0, 1) != NILU_OK ||
             strcmp(nilu_tostring(N, -1), "after") != 0) {
    failure = "the state would not run anything afterwards";
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_table_a_host_holds_survives_a_program(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* The table is on the stack, and its key is a string nothing else points at -- so this
  * is also the check that the collector marks keys as well as values. */
  if (nilu_newtable(N) != NILU_OK) {
    failure = "a table would not go on the stack";
  } else if (nilu_pushstring(N, "key") != NILU_OK || nilu_pushstring(N, "value") != NILU_OK ||
             nilu_settable(N, 1) != NILU_OK) {
    failure = "a host could not write a table";
  } else if (nilu_loadstring(N, "local i = 0 while i < 400 do local t = {} i = i + 1 end return i",
                             NULL) != NILU_OK) {
    failure = "a source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "a program that makes garbage did not finish";
  } else if (nilu_settop(N, 1) != NILU_OK) {
    failure = "the stack would not be trimmed";
  } else if (nilu_pushstring(N, "key") != NILU_OK || nilu_gettable(N, 1) != NILU_OK) {
    failure = "a host could not read the table afterwards";
  } else if (nilu_type(N, -1) != NILU_TSTRING || strcmp(nilu_tostring(N, -1), "value") != 0) {
    failure = "what the table held did not survive the collections";
  }

  nilu_close(N);
  return failure;
}

/* ── functions written in Nilu ──────────────────────────────────────────────── */

static const char *case_a_nilu_function_runs(void) {
  static const struct {
    const char *source;
    double answer;
  } cases[] = {
      {"local function inc(x) return x + 1 end return inc(41)", 42.0},
      {"local f = function(a, b) return a + b end return f(1, 2)", 3.0},
      {"local function seven() return 7 end return seven()", 7.0},
      /* Extra arguments are dropped and a missing parameter is nil, as in Lua. */
      {"local function one(a) return a end return one(5, 6, 7)", 5.0},
      {"local function f(a, b) if b then return 1 end return 2 end return f(9)", 2.0},
      /* A function is a value: it goes in a local, in a table, and into another function. */
      {"local function apply(f, x) return f(x) end local function dbl(n) return n * 2 end return apply(dbl, 21)",
       42.0},
      {"local t = {} t[1] = function() return 8 end return t[1]()", 8.0},
      /* A function inside a function. */
      {"local function outer() local function inner() return 7 end return inner() end return outer()", 7.0},
      /* Recursion by passing the function to itself: there are no upvalues, so this is how
  * it is written. */
      {"local function fact(self, n) if n < 2 then return 1 end return n * self(self, n - 1) end return fact(fact, 5)",
       120.0},
      /* A call as a statement, with the table passed in because a body cannot see the
  * locals around it. */
      {"local t = {} local function fill(x) x[1] = 4 end fill(t) return t[1]", 4.0},
      {"local function sq(n) return n * n end local s = 0 local i = 0 while i < 4 do i = i + 1 s = s + sq(i) end return s",
       30.0},
  };
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof cases / sizeof cases[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, cases[i].source, NULL) != NILU_OK) {
      failure = "a source would not compile";
    } else if (nilu_call(N, 0, 1) != NILU_OK) {
      failure = "the call did not succeed";
    } else if (nilu_tonumber(N, -1) != cases[i].answer) {
      failure = "the answer is not the one expected";
    }
    if (failure != NULL) break;
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_host_can_call_a_function_a_program_made(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A function value is a prototype, which is what nilu_call already ran -- so a host can
  * call one a program returned without knowing where it came from, and nothing about this
  * API changed to allow it. */
  if (nilu_loadstring(N, "return function(x) return x + 1 end", NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_OK) {
    failure = "the chunk did not run";
  } else if (nilu_type(N, -1) != NILU_TFUNCTION) {
    failure = "what a program returned is not a function";
  } else if (nilu_pushnumber(N, 41) != NILU_OK) {
    failure = "an argument would not go on the stack";
  } else if (nilu_call(N, 1, 1) != NILU_OK) {
    failure = "a host could not call it";
  } else if (nilu_tonumber(N, -1) != 42.0) {
    failure = "it did not answer what it should";
  }

  nilu_close(N);
  return failure;
}

static const char *case_what_a_nilu_program_cannot_do_with_functions(void) {
  static const char *const type_errors[] = {
      /* Calling something that is not a function. */
      /* A literal in parentheses: a literal takes no suffix. */
      "local n = 1 return n()", "return (nil)()", "local t = {} return t()",
      "return (\"a\")()"};
  static const char *const refused[] = {
      /* A bare expression is still not a statement; only a call may stand alone. */
      "x", "t[1]",
      /* Lua's other two argument forms, f"x" and f{…}, compile.
  * What is left to refuse about them is a constructor that does not close. A vararg
  * function compiles, and what is still refused about '...' has its own case. */
      "local function f(a) return a end f{1"};
  const char *failure = NULL;
  int i;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  for (i = 0; i < (int)(sizeof type_errors / sizeof type_errors[0]); i++) {
    if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the stack would not be emptied";
    } else if (nilu_loadstring(N, type_errors[i], NULL) != NILU_OK) {
      failure = "a source that compiles did not compile";
    } else if (nilu_call(N, 0, 1) != NILU_ERR_TYPE) {
      failure = "calling something that is not a function was not a type error";
    }
    if (failure != NULL) break;
  }

  /* The type errors above each left the nil a failure carries. */
  if (failure == NULL && nilu_settop(N, 0) != NILU_OK) failure = "the stack would not be emptied";
  for (i = 0; failure == NULL && i < (int)(sizeof refused / sizeof refused[0]); i++) {
    if (nilu_loadstring(N, refused[i], NULL) != NILU_ERR_SYNTAX) {
      failure = "a source that cannot compile was accepted";
    } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TSTRING) {
      /* Since 0.0.54 a refused source leaves its message, and nothing else. */
      failure = "a refused source did not leave exactly its message on the stack";
    } else if (nilu_settop(N, 0) != NILU_OK) {
      failure = "the message could not be popped";
    }
  }

  nilu_close(N);
  return failure;
}

static const char *case_a_recursion_too_deep_is_refused(void) {
  const char *failure = NULL;
  NiluState *N = nilu_new();
  if (N == NULL) return "nilu_new returned NULL";

  /* A Nilu call costs a C frame here, where Lua runs the callee in the same one. The call
  * depth limit is what keeps a runaway recursion from ending this process -- the same
  * limit and the same status a host's own nested call gets. */
  if (nilu_loadstring(N, "local function down(self, n) return (self(self, n + 1)) end return down(down, 0)",
                      NULL) != NILU_OK) {
    failure = "the source would not compile";
  } else if (nilu_call(N, 0, 1) != NILU_ERR_CALL_DEPTH) {
    failure = "a runaway recursion was not refused";
  } else if (nilu_gettop(N) != 1 || nilu_type(N, -1) != NILU_TSTRING ||
             !ends_with(nilu_tostring(N, -1), "]:1: stack overflow") || nilu_settop(N, 0) != NILU_OK) {
    /* One value, the sentence a depth failure carries -- ldo.c's words, after
  * the chunk's name and line, and nothing else on the stack. */
    failure = "a refused call left something other than the sentence it carries";
  } else if (nilu_loadstring(N, "return 1 + 1", NULL) != NILU_OK || nilu_call(N, 0, 1) != NILU_OK ||
             nilu_tonumber(N, -1) != 2.0) {
    failure = "the state would not work afterwards";
  }

  nilu_close(N);
  return failure;
}

/* The other four functions abort on NULL (nilu.h says why), so there is nothing here
 * to call them with. Asserting an abort would mean a case that expects the program to
 * die, which this runner cannot express. These aborts are not checked here. */
static const char *case_closing_nothing_is_a_no_op(void) {
  nilu_close(NULL);
  return NULL;
}

static const struct {
  const char *name;
  nilu_case_fn run;
} CASES[] = {
    {"a state opens and closes", case_a_state_opens_and_closes},
    {"a number reads back through C", case_a_number_reads_back_through_c},
    {"index 1 is the bottom", case_index_1_is_the_bottom},
    {"a missing slot is not the value zero", case_a_missing_slot_is_not_the_value_zero},
    {"nil and number are told apart", case_nil_and_number_are_told_apart},
    {"a slot that does not exist has no type", case_a_slot_that_does_not_exist_has_no_type},
    {"a nil is not a number", case_a_nil_is_not_a_number},
    {"the convenience macro reads a number", case_the_convenience_macro_reads_a_number},
    {"setting the top grows with nil", case_setting_the_top_grows_with_nil},
    {"pop drops what was pushed", case_pop_drops_what_was_pushed},
    {"the stack stops at the documented maximum", case_the_stack_stops_at_the_documented_maximum},
    {"add 10 and 20 through a call", case_add_10_and_20_through_a_call},
    {"a function sees only its arguments", case_a_function_sees_only_its_arguments},
    {"a failed call leaves the stack alone", case_a_failed_call_leaves_the_stack_alone},
    {"a handler runs before the unwinding", case_a_handler_runs_before_the_unwinding},
    {"a handler that fails is said once", case_a_handler_that_fails_is_said_once},
    {"a handler that calls and then fails stops", case_a_handler_that_calls_and_then_fails_stops},
    {"a handler may be a closure named from the top", case_a_handler_may_be_a_closure_named_from_the_top},
    {"no handler is the same as nilu_call", case_no_handler_is_the_same_as_nilu_call},
    {"results that cannot fit are refused before the call", case_results_that_cannot_fit_are_refused_before_the_call},
    {"an interruption runs no handler", case_an_interruption_runs_no_handler},
    {"results are adjusted to the request", case_results_are_adjusted_to_the_request},
    {"a call inside a call", case_a_call_inside_a_call},
    {"the header states its own version", case_the_header_states_its_own_version},
    {"both kinds of function are one type", case_both_kinds_of_function_are_one_type},
    {"a C function can call a Nilu one", case_a_c_function_can_call_a_nilu_one},
    {"source compiles and runs", case_source_compiles_and_runs},
    {"source that does not compile says why", case_source_that_does_not_compile_says_why},
    {"the state keeps every function it compiled", case_the_state_keeps_every_function_it_compiled},
    {"a syntax error says where", case_a_syntax_error_says_where},
    {"a call too deep never runs", case_a_call_too_deep_never_runs},
    {"a failed call and a refused one differ", case_a_failed_call_and_a_refused_one_differ},
    {"short-circuiting runs from source", case_short_circuiting_runs_from_source},
    {"comparison runs from source", case_comparison_runs_from_source},
    {"ordering across types is a type error", case_ordering_across_types_is_a_type_error},
    {"a boolean a host pushed reads back", case_a_boolean_a_host_pushed_reads_back},
    {"a hook watches without stopping", case_a_hook_watches_without_stopping},
    {"a hook can stop a program", case_a_hook_can_stop_a_program},
    {"an empty source is a program", case_an_empty_source_is_a_program},
    {"if chooses which block runs", case_if_chooses_which_block_runs},
    {"a source loop is stopped by a hook", case_a_source_loop_is_stopped_by_a_hook},
    {"a loop that stops runs from source", case_a_loop_that_stops_runs_from_source},
    {"the arithmetic answers what Lua answers", case_the_arithmetic_answers_what_lua_answers},
    {"a string reads back through C", case_a_string_reads_back_through_c},
    {"a table holds what a host put in it", case_a_table_holds_what_a_host_put_in_it},
    {"a program that makes garbage still answers", case_a_program_that_makes_garbage_still_answers},
    {"a nilu function runs", case_a_nilu_function_runs},
    {"a closure shares what it captured", case_a_closure_shares_what_it_captured},
    {"a host and a program share the environment", case_a_host_and_a_program_share_the_environment},
    {"globals run from source", case_globals_run_from_source},
    {"a program calls a function of the host's", case_a_program_calls_a_function_of_the_hosts},
    {"a field is an index", case_a_field_is_an_index},
    {"a state has no library until it is opened", case_a_state_has_no_library_until_it_is_opened},
    {"the library's print needs a writer", case_the_librarys_print_needs_a_writer},
    {"the library runs from source", case_the_library_runs_from_source},
    {"a host copies a slot and reads a length", case_a_host_copies_a_slot_and_reads_a_length},
    {"a host sets and reads a metatable", case_a_host_sets_and_reads_a_metatable},
    {"a host reads through a metamethod", case_a_host_reads_through_a_metamethod},
    {"a metamethod runs a program inside a C call", case_a_metamethod_runs_a_program_inside_a_c_call},
    {"metatables run from source", case_metatables_run_from_source},
    {"operator metamethods run from source", case_operator_metamethods_run_from_source},
    {"a host compares through a metamethod", case_a_host_compares_through_a_metamethod},
    {"several values run from source", case_several_values_run_from_source},
    {"a host asks for every result", case_a_host_asks_for_every_result},
    {"a tail call does not nest", case_a_tail_call_does_not_nest},
    {"a vararg function from a host", case_a_vararg_function_from_a_host},
    {"a number becomes text", case_a_number_becomes_text},
    {"a numeral becomes a number", case_a_numeral_becomes_a_number},
    {"the library packs, unpacks and slices", case_the_library_packs_unpacks_and_slices},
    {"a global can be declared", case_a_global_can_be_declared},
    {"a numeric for counts", case_a_numeric_for_counts},
    {"a generic for walks a table", case_a_generic_for_walks_a_table},
    {"break leaves the innermost loop", case_break_leaves_the_innermost_loop},
    {"a host calls what a program made callable", case_a_host_calls_what_a_program_made_callable},
    {"a function of the host's sees the arguments", case_a_function_of_the_hosts_sees_the_arguments},
    {"a function of the host's refusing fails the program", case_a_function_of_the_hosts_refusing_fails_the_program},
    {"a function a host holds keeps its state", case_a_function_a_host_holds_keeps_its_state},
    {"a host can call a function a program made", case_a_host_can_call_a_function_a_program_made},
    {"what a nilu program cannot call", case_what_a_nilu_program_cannot_do_with_functions},
    {"a recursion too deep is refused", case_a_recursion_too_deep_is_refused},
    {"a table a host holds survives a program", case_a_table_a_host_holds_survives_a_program},
    {"a host deletes a key with nil", case_a_host_deletes_a_key_with_nil},
    {"a refused key still reads as nil", case_a_refused_key_still_reads_as_nil},
    {"tables run from source", case_tables_run_from_source},
    {"a border with holes is one of the borders", case_a_border_with_holes_is_one_of_the_borders},
    {"a zero byte inside a string", case_a_zero_byte_inside_a_string},
    {"the name in a host's call is the registered one", case_the_name_in_a_hosts_call_is_the_registered_one},
    {"namewhat says how a native was called", case_namewhat_says_how_a_native_was_called},
    {"the library from a host, including utf8", case_the_library_from_a_host_including_utf8},
    {"a host walks a table with next", case_a_host_walks_a_table_with_next},
    {"a script must declare the host's name", case_a_script_must_declare_the_hosts_name},
    {"a host owns a block of bytes", case_a_host_owns_a_block_of_bytes},
    {"a program sees a userdata", case_a_program_sees_a_userdata},
    {"a __gc field is refused for a userdata", case_a_gc_field_is_refused},
    {"a null string pushes nil", case_a_null_string_pushes_nil},
    {"strings run from source", case_strings_run_from_source},
    {"what a string cannot do is a type error", case_what_a_string_cannot_do_is_a_type_error},
    {"a string pointer lives while its value does", case_a_string_pointer_lives_while_its_value_does},
    {"dividing by zero is a number", case_dividing_by_zero_is_a_number},
    {"a variable runs from source", case_a_variable_runs_from_source},
    {"a name nothing declared is a global", case_a_name_nothing_declared_is_a_global},
    {"the library has no io and no os", case_the_library_has_no_io_and_no_os},
    {"a native function raises a value and the host finds it", case_a_native_function_raises_a_value_and_the_host_finds_it},
    {"a slot can be moved", case_a_slot_can_be_moved},
    {"a named chunk's failure has a line", case_a_named_chunk_s_failure_has_a_line},
    {"a failure carries the sentence a host shows", case_a_failure_carries_the_sentence_a_host_shows},
    {"a library refusal names the argument a host reads", case_a_library_refusal_names_the_argument_a_host_reads},
    {"a C closure counts, and each call sees what the last one stored", case_a_c_closure_counts_and_each_call_sees_what_the_last_one_stored},
    {"a program calls a C closure and it keeps its state", case_a_program_calls_a_c_closure_and_it_keeps_its_state},
    {"a closure with no upvalues is the light function", case_a_closure_with_no_upvalues_is_the_light_function},
    {"a light function has no upvalues to read", case_a_light_function_has_no_upvalues_to_read},
    {"an upvalue that does not exist is refused, and nothing moves", case_an_upvalue_that_does_not_exist_is_refused_and_nothing_moves},
    {"two closures over one function are two values", case_two_closures_over_one_function_are_two_values},
    {"closing nothing is a no-op", case_closing_nothing_is_a_no_op},
};

static const int CASE_COUNT = (int)(sizeof(CASES) / sizeof(CASES[0]));

int main(int argc, char **argv) {
  const char *only = NULL;
  int i, ran = 0, failed = 0;

  for (i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--list") == 0) {
      /* Counting must not do the work. */
      printf("c-smoke: %d cases, none run\n", CASE_COUNT);
      for (i = 0; i < CASE_COUNT; i++) printf("  %s\n", CASES[i].name);
      return 0;
    }
    if (strncmp(argv[i], "--only=", 7) == 0) {
      only = argv[i] + 7;
    } else {
      fprintf(stderr, "c-smoke: unknown argument \"%s\". --list names the cases.\n", argv[i]);
      return 1;
    }
  }

  if (only != NULL) {
    int found = 0;
    for (i = 0; i < CASE_COUNT; i++)
      if (strcmp(CASES[i].name, only) == 0) found = 1;
    if (!found) {
      fprintf(stderr, "c-smoke: no case named \"%s\". --list names them.\n", only);
      return 1;
    }
    printf("c-smoke: running 1 of %d cases (--only=%s)\n", CASE_COUNT, only);
  } else {
    printf("c-smoke: running %d of %d cases\n", CASE_COUNT, CASE_COUNT);
  }

  for (i = 0; i < CASE_COUNT; i++) {
    const char *failure;
    if (only != NULL && strcmp(CASES[i].name, only) != 0) continue;
    failure = CASES[i].run();
    ran++;
    if (failure == NULL) {
      printf("  ok   %s\n", CASES[i].name);
    } else {
      printf("  FAIL %s - %s\n", CASES[i].name, failure);
      failed++;
    }
  }

  if (failed > 0) {
    printf("\nc-smoke: %d of %d cases failed\n", failed, ran);
    return 1;
  }
  printf("\nc-smoke: %d of %d cases passed\n", ran, ran);
  return 0;
}
