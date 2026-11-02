/* A small host: everything Nilu v0.0.1 can do, in the order a host would do it.
 *
 * This is also the only check that walks the consumer's path. It is compiled
 * against the installed artefacts -- zig-out/include/nilu.h and
 * zig-out/lib/libnilu.a -- with a plain C driver and nothing from the build
 * graph, so a header that was not installed, or a library with a symbol
 * missing, fails here and nowhere else.
 *
 *   zig build example
 */
#include <stdio.h>

#include "nilu.h"

static const char *name_of(NiluType type) {
  switch (type) {
    case NILU_TNIL:
      return "nil";
    case NILU_TNUMBER:
      return "number";
    case NILU_TFUNCTION:
      return "function";
    case NILU_TBOOLEAN:
      return "boolean";
    case NILU_TSTRING:
      return "string";
    case NILU_TTABLE:
      return "table";
    case NILU_TNONE:
      return "no such slot";
    default:
      return "a type this example does not know about";
  }
}

/* A function of the host's own. Nilu calls it with its arguments at 1 upward, it
 * pushes whatever it wants to return, and it says how many of those it left.
 *
 * Checking the arguments is this function's job: nilu_call does not know what any
 * particular function wants. NILU_FAIL is how it says the check failed. */
static int add(NiluState *N) {
  int ok_a;
  int ok_b;
  double a = nilu_tonumberx(N, 1, &ok_a);
  double b = nilu_tonumberx(N, 2, &ok_b);

  if (!ok_a || !ok_b) return NILU_FAIL;

  if (nilu_pushnumber(N, a + b) != NILU_OK) return NILU_FAIL;
  return 1;
}

/* What Nilu calls while a program runs, so this host can take its thread back. Return
 * non-zero and the call stops with NILU_ERR_INTERRUPTED. */
static int instructions = 0;

static int watcher(NiluState *N) {
  (void)N;
  instructions++;
  /* Let a few through, then ask to stop. A real host would look at a clock. */
  return instructions > 2;
}

/* A host checks what it is told. Nilu reports a refused push rather than
 * raising, so ignoring these returns is how a host ends up reading a value it
 * never managed to put there. */
static int trouble = 0;

static void expect(int condition, const char *what) {
  if (!condition) {
    fprintf(stderr, "example: %s\n", what);
    trouble = 1;
  }
}

int main(void) {
  NiluState *N = nilu_new();
  int isnum = 0;
  double value;

  if (N == NULL) {
    fprintf(stderr, "example: a Nilu state could not be created\n");
    return 1;
  }

  printf("Nilu %s (version number %d)\n", NILU_VERSION, NILU_VERSION_NUM);
  printf("a new state holds %d values\n", nilu_gettop(N));

  expect(nilu_pushnumber(N, 1.5) == NILU_OK, "a number would not go on the stack");
  expect(nilu_pushnil(N) == NILU_OK, "nil would not go on the stack");
  printf("after two pushes it holds %d\n", nilu_gettop(N));

  /* 1 is the bottom, -1 is the top, and 0 is never a valid index. */
  printf("  slot  1 holds %s\n", name_of(nilu_type(N, 1)));
  printf("  slot -1 holds %s\n", name_of(nilu_type(N, -1)));
  printf("  slot  3 holds %s\n", name_of(nilu_type(N, 3)));

  /* isnum is what tells "that was not a number" from "the number was 0". Pass
   * NULL for it, or use the nilu_tonumber macro, when you do not care. */
  value = nilu_tonumberx(N, 1, &isnum);
  expect(isnum == 1, "the number at the bottom did not come back");
  printf("the number at slot 1 is %g\n", value);

  value = nilu_tonumberx(N, -1, &isnum);
  expect(isnum == 0, "nil came back as a number");
  printf("reading the nil as a number gives %g, and isnum says %d\n", value, isnum);

  /* Growing fills with nil; the stack stops at NILU_MAXDEPTH and a push past
   * it is refused rather than fatal. */
  expect(nilu_settop(N, 4) == NILU_OK, "the stack would not grow");
  printf("grown to %d, where slot 4 holds %s\n", nilu_gettop(N), name_of(nilu_type(N, 4)));

  nilu_pop(N, 3);
  printf("after popping three it holds %d, and slot -1 holds %s\n", nilu_gettop(N),
         name_of(nilu_type(N, -1)));

  /* Push the function, then its arguments, then say how many you pushed and how many
   * results you want. The function and its arguments are replaced by the results. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushcfunction(N, add) == NILU_OK, "the function would not go on the stack");
  printf("a pushed function holds %s\n", name_of(nilu_type(N, -1)));

  expect(nilu_pushnumber(N, 10) == NILU_OK, "an argument would not go on the stack");
  expect(nilu_pushnumber(N, 20) == NILU_OK, "an argument would not go on the stack");

  if (nilu_call(N, 2, 1) == NILU_OK) {
    printf("add(10, 20) = %g, and the stack holds %d\n", nilu_tonumber(N, -1), nilu_gettop(N));
  } else {
    fprintf(stderr, "example: the call did not succeed\n");
    trouble = 1;
  }

  /* The same function, given something that is not a number. It reports NILU_FAIL, and
   * nilu_call answers 0 with the stack exactly as it was before the function went on. */
  expect(nilu_pushcfunction(N, add) == NILU_OK, "the function would not go on the stack");
  expect(nilu_pushnumber(N, 1) == NILU_OK, "an argument would not go on the stack");
  expect(nilu_pushnil(N) == NILU_OK, "nil would not go on the stack");
  printf("calling add with a nil argument answers status %d, and the stack still holds %d\n",
         nilu_call(N, 2, 1), nilu_gettop(N));

  /* A function of Nilu's own, compiled from source rather than written in C. The same
   * nilu_call runs it, and from here there is no way to tell which kind it was. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 10 + (20 + 30)", NULL) == NILU_OK, "the source would not compile");
  printf("a compiled function also holds %s\n", name_of(nilu_type(N, -1)));

  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("10 + (20 + 30) = %g\n", nilu_tonumber(N, -1));
  } else {
    fprintf(stderr, "example: the compiled call did not succeed\n");
    trouble = 1;
  }

  /* and and or short-circuit: the value is one of the operands, not a boolean. nil is
   * false and every number is true, including zero. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return nil or 10 + 20", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("nil or 10 + 20 = %g\n", nilu_tonumber(N, -1));
  }
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 0 and nil", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    /* Zero is true, so the right side runs and the answer is the nil. */
    printf("0 and nil holds %s\n", name_of(nilu_type(N, -1)));
  }

  /* Comparison answers with a boolean, and equality is total where ordering is not. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 1 < 2", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("1 < 2 holds %s, and it is %s\n", name_of(nilu_type(N, -1)),
           nilu_toboolean(N, -1) ? "true" : "false");
  }
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return nil == 1", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("nil == 1 is %s, because equality is total\n",
           nilu_toboolean(N, -1) ? "true" : "false");
  }
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return nil < 1", NULL) == NILU_OK, "the source would not compile");
  printf("nil < 1 answers status %d, because ordering is not\n", nilu_call(N, 0, 1));

  /* A hook is how a host keeps a Nilu program from taking its thread for good. This
   * program is four instructions and would have finished on its own; the loop below is
   * the one that would not. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  nilu_sethook(N, watcher, 1);
  expect(nilu_loadstring(N, "return 1 + 2 + 3 + 4", NULL) == NILU_OK, "the source would not compile");
  printf("with a hook asking to stop, the call answers status %d after %d calls\n",
         nilu_call(N, 0, 1), instructions);
  nilu_sethook(N, NULL, 0);

  /* And the state goes on working, which is what makes an interruption recoverable. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 1 + 2", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("and afterwards 1 + 2 is still %g\n", nilu_tonumber(N, -1));
  }

  /* A program is a block of statements, so a condition can choose what runs. There are
   * no variables, so the condition is an expression over constants: it is the shape of
   * the thing, not a useful program yet. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "if 1 < 2 then return 10 else return 20 end", NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("if 1 < 2 then return 10 else return 20 end = %g\n", nilu_tonumber(N, -1));
  }

  /* And a loop that never ends, which is what the hook is for. A while condition cannot
   * change, so this one runs until something stops it -- it is only ever run with a hook
   * set. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  instructions = 0;
  nilu_sethook(N, watcher, 100);
  expect(nilu_loadstring(N, "while 1 < 2 do end", NULL) == NILU_OK,
         "the source would not compile");
  printf("while 1 < 2 do end answers status %d after %d hook calls\n", nilu_call(N, 0, 1),
         instructions);
  nilu_sethook(N, NULL, 0);

  /* A variable, and the loop it makes possible: this one does something and then stops,
   * with no hook holding it. Every version before this one could only write a loop that
   * runs forever or not at all. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local n = 0 local i = 0 while i < 4 do i = i + 1 n = n + i end return n",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("summing 1..4 with a while loop = %g\n", nilu_tonumber(N, -1));
  }

  /* The arithmetic is Lua's, including the two groupings people get wrong: -2 ^ 2 is
   * -(2 ^ 2), and % is floored rather than truncated. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return -2 ^ 2", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("-2 ^ 2 = %g, because ^ binds tighter than a unary minus\n", nilu_tonumber(N, -1));
  }
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return -1 % 3", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("-1 %% 3 = %g, where C's fmod gives -1\n", nilu_tonumber(N, -1));
  }

  /* And dividing by zero answers a number, because there are no integers to raise for. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 1 / 0", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("1 / 0 = %g, and the call succeeded\n", nilu_tonumber(N, -1));
  }

  /* A string is a value, and the first one that owns memory. The state owns it; nothing
   * collects it before nilu_close. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushstring(N, "a host's string") == NILU_OK, "a string would not go on the stack");
  {
    size_t len = 0;
    const char *read = nilu_tolstring(N, 1, &len);
    expect(read != NULL, "a string would not read back");
    printf("slot 1 holds %s of %zu bytes: %s\n", name_of(nilu_type(N, 1)), len, read);
  }

  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local s = \"\" local i = 0 while i < 3 do s = s .. \"ab\" i = i + 1 end return s",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a loop joining strings made %s, and # of it is ", nilu_tostring(N, -1));
  }
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return #(\"ab\" .. \"cde\")", NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("%g bytes\n", nilu_tonumber(N, -1));
  }

  /* A table, made by the host and written by the host. It is the first mutable heap
   * object, so two values pointing at one table see each other's writes. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_newtable(N) == NILU_OK, "a table would not go on the stack");
  expect(nilu_pushstring(N, "answer") == NILU_OK, "a key would not go on the stack");
  expect(nilu_pushnumber(N, 42) == NILU_OK, "a value would not go on the stack");
  expect(nilu_settable(N, 1) == NILU_OK, "a host could not write a table");
  expect(nilu_pushstring(N, "answer") == NILU_OK, "a key would not go on the stack");
  expect(nilu_gettable(N, 1) == NILU_OK, "a host could not read a table");
  printf("slot 1 holds a %s, and t[\"answer\"] is %g\n", name_of(nilu_type(N, 1)),
         nilu_tonumber(N, -1));

  /* And a table built by a program, with its length. #t is a border: with no holes in
   * it, that is how many it has. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local t = {} local i = 0 while i < 4 do i = i + 1 t[i] = i * i end return t[4] + #t",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a table built by a loop: t[4] + #t = %g\n", nilu_tonumber(N, -1));
  }

  /* Writing a key that cannot exist is refused, where reading one answers nil. That
   * asymmetry is Lua's. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local t = {} t[nil] = 1", NULL) == NILU_OK,
         "the source would not compile");
  printf("t[nil] = 1 answers status %d, while t[nil] reads as nil\n", nilu_call(N, 0, 1));

  /* No coercion, in either direction: Lua would answer 11 and "12" for these. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return \"10\" + 1", NULL) == NILU_OK, "the source would not compile");
  printf("\"10\" + 1 answers status %d, because nothing coerces\n", nilu_call(N, 0, 1));

  /* Everything above was made and never freed by the host. There is a collector now: a
   * string or a table that nothing can reach is freed while a Nilu function runs, cycles
   * included. A host cannot ask for a collection and cannot see one happen -- what it can
   * see is that a program making a great deal of garbage still answers, and that what it
   * holds on the stack survives. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushstring(N, "the host's own") == NILU_OK, "a string would not go on the stack");
  expect(nilu_loadstring(N,
                         "local n = 0 local i = 0 while i < 2000 do local t = {} t[1] = \"g\" .. \"c\" "
                         "n = n + #t i = i + 1 end return n",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a program that made four thousand objects answered %g, and slot 1 still holds \"%s\"\n",
           nilu_tonumber(N, -1), nilu_tostring(N, 1));
  }

  /* A function written in Nilu. The value is a prototype, so the call a host already had
   * runs one -- a program can hand a function back and the host calls it. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return function(x) return x * x end", NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a program returned a %s; ", name_of(nilu_type(N, -1)));
    expect(nilu_pushnumber(N, 9) == NILU_OK, "an argument would not go on the stack");
    if (nilu_call(N, 1, 1) == NILU_OK) {
      printf("calling it with 9 gives %g\n", nilu_tonumber(N, -1));
    }
  }

  /* A body can see the variables of the functions around it, and they share them -- so a
   * function names itself and recursion is written the usual way. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local function fact(n) if n < 2 then return 1 end "
                         "return n * fact(n - 1) end return fact(6)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("fact(6) = %g, and the function named itself\n", nilu_tonumber(N, -1));
  }

  /* And a closure keeps the variable it captured after the function that made it returned,
   * so calling it twice answers differently. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local function counter() local n = 0 "
                         "return function() n = n + 1 return n end end "
                         "local c = counter() c() c() return c()",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a counter called three times says %g\n", nilu_tonumber(N, -1));
  }

  /* And a runaway recursion is refused rather than taking the process with it. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local function down(self, n) return (self(self, n + 1)) end return down(down, 0)",
                         NULL) == NILU_OK,
         "the source would not compile");
  printf("a recursion with no end answers status %d, and the state still works\n",
         nilu_call(N, 0, 1));

  /* A name nothing declared is a global, which is what this version reversed: through
   * v0.0.17 a misspelling was a syntax error with a column number, and now it is a read
   * of a field nothing set, so it answers nil. The price of Lua's design. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local count = 1 return cuont", NULL) == NILU_OK,
         "a misspelled name would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a misspelled name is not refused any more; it reads as %s\n",
           name_of(nilu_type(N, -1)));
  }

  /* A host and a program share one environment, and it is an ordinary table. So this is
   * how you hand a program a value without putting it on the stack yourself. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushnumber(N, 7) == NILU_OK, "a number would not go on the stack");
  expect(nilu_setglobal(N, "seed") == NILU_OK, "a global would not be set");
  expect(nilu_loadstring(N, "total = seed * 6 return total", NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK && nilu_getglobal(N, "total") == NILU_OK) {
    printf("a program read the global the host set, and the host reads back %g\n",
           nilu_tonumber(N, -1));
  }

  /* A function of this host's, put where a program can name it, and called by the
   * program. It sees the same window it sees when this host calls it. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushcfunction(N, add) == NILU_OK, "a function would not go on the stack");
  expect(nilu_setglobal(N, "add") == NILU_OK, "a global would not be set");
  expect(nilu_loadstring(N, "local function twice(f, n) return f(n, n) end return twice(add, 21)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a program passed this host's add to a Nilu function and got %g\n",
           nilu_tonumber(N, -1));
  }

  /* And a function of this host's that says no fails the program's call. NILU_FAIL is the
   * one way it can refuse; there is no pcall for a script to catch it with. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return add(1, \"not a number\")", NULL) == NILU_OK,
         "the source would not compile");
  printf("a program calling it with an argument it refuses answers status %d\n",
         nilu_call(N, 0, 1));

  /* The standard library, which a fresh state does not have. A host that wants a script
   * to see nothing gets that by doing nothing. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_openlibs(N) == NILU_OK, "the library would not open");
  expect(nilu_loadstring(N,
                         "local parts = {} "
                         "table.insert(parts, string.upper(\"nilu\")) "
                         "table.insert(parts, string.rep(\"-\", 3)) "
                         "table.insert(parts, type(math.floor)) "
                         "return table.concat(parts, \" \")",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a program using the library says %s\n", nilu_tostring(N, -1));
  }

  /* t.field is t["field"], which is what makes the library readable -- and a host can
   * read a length and copy a slot now, so one chunk can run twice. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local t = {} t.n = 3 return math.sqrt(t.n * t.n)", NULL) == NILU_OK,
         "the source would not compile");
  expect(nilu_pushvalue(N, 1) == NILU_OK, "a chunk would not be copied");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("t.n read through a field gives %g, ", nilu_tonumber(N, -1));
  }
  expect(nilu_settop(N, 1) == NILU_OK, "the stack would not be trimmed");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("and the same chunk run twice gives %g\n", nilu_tonumber(N, -1));
  }

  /* A metatable: __index answers for a key the table does not have. A prototype, a
   * default and a read-only table are all this one mechanism. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local base = {} base.greeting = \"hello\" "
                         "local mt = {} mt.__index = base "
                         "local t = {} setmetatable(t, mt) "
                         "return string.upper(t.greeting)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a table with no greeting of its own answers %s\n", nilu_tostring(N, -1));
  }

  /* And a host reads through the metamethod too, or past it with the raw pair. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local mt = {} mt.__index = function() return 99 end "
                            "local t = {} setmetatable(t, mt) return t",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    expect(nilu_pushstring(N, "missing") == NILU_OK, "a key would not go on the stack");
    if (nilu_gettable(N, 1) == NILU_OK) {
      printf("reading a missing key through __index gives %g, ", nilu_tonumber(N, -1));
    }
    expect(nilu_settop(N, 1) == NILU_OK, "the stack would not be trimmed");
    expect(nilu_pushstring(N, "missing") == NILU_OK, "a key would not go on the stack");
    if (nilu_rawget(N, 1) == NILU_OK) {
      printf("and reading it raw gives %s\n", name_of(nilu_type(N, -1)));
    }
  }

  /* A metatable answers for an operator too, so a script can give a table arithmetic and
   * a length. Each is tried only where the plain operation has no answer. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local mt = {} "
                         "mt.__add = function(a, b) return a.n + b.n end "
                         "mt.__len = function(a) return a.n end "
                         "mt.__call = function(self, k) return self.n * k end "
                         "local function boxed(n) local t = {} t.n = n setmetatable(t, mt) return t end "
                         "local a = boxed(3) local b = boxed(4) "
                         "return (a + b) + #a + a(10)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a boxed number with __add, __len and __call gives %g\n", nilu_tonumber(N, -1));
  }

  /* And a host compares two of them without knowing what they are. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "local mt = {} mt.__eq = function() return true end "
                            "local t = {} setmetatable(t, mt) return t",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK && nilu_newtable(N) == NILU_OK &&
      nilu_compare(N, 1, 2, NILU_OPEQ) == NILU_OK) {
    printf("two tables the script calls equal compare %s, and raw-equal %s\n",
           nilu_toboolean(N, -1) ? "true" : "false",
           nilu_rawequal(N, 1, 2) ? "true" : "false");
  }

  /* A call produces any number of values now, and three places consume several. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local function divmod(a, b) return a // b, a % b end "
                         "local q, r = divmod(17, 5) "
                         "return string.rep(\"*\", q) .. \"+\" .. string.rep(\"*\", r)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("17 // 5 and 17 %% 5, drawn: %s\n", nilu_tostring(N, -1));
  }

  /* And a host can ask for all of them rather than an exact number. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "return 1, 2, 3", NULL) == NILU_OK, "the source would not compile");
  if (nilu_call(N, 0, NILU_MULTRET) == NILU_OK) {
    printf("a program returning three values leaves %d of them\n", nilu_gettop(N));
  }

  /* `return f(...)` reuses the frame, so recursion written that way is a loop -- and the
   * call depth limit stops covering it. The parentheses are what keep a frame. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local function sum(n, acc) if n == 0 then return acc end "
                         "return sum(n - 1, acc + n) end return sum(100000, 0)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a tail recursion a hundred thousand deep sums to %g\n", nilu_tonumber(N, -1));
  }

  /* A function can read arguments it did not declare. `...` produces several values
   * wherever several are taken, and select is how a program counts or slices them. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local function sum(...) local total = 0 local i = 1 "
                         "local n = select(\"#\", ...) "
                         "while i <= n do total = total + select(i, ...) i = i + 1 end "
                         "return n, total end "
                         "return sum(2, 4, 6, 8)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, NILU_MULTRET) == NILU_OK) {
    printf("a vararg function saw %g arguments summing to %g\n", nilu_tonumber(N, 1),
           nilu_tonumber(N, 2));
  }

  /* A number has a spelling, and tostring is what gives it. A whole number ends in ".0"
   * because every Nilu number is a float. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local t, mt = {}, {} "
                         "mt.__tostring = function(self) return \"point \" .. self.name end "
                         "t.name = \"origin\" setmetatable(t, mt) "
                         "return tostring(3) .. \", \" .. tostring(1 / 3) .. \", \" .. tostring(t)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a number, a third and a __tostring: %s\n", nilu_tostring(N, -1));
  }

  /* nilu_tolstring converts a number in place, as Lua's does -- so reading a slot changes
   * what it holds. Worth seeing once rather than meeting it in your own code. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_pushnumber(N, 2.5) == NILU_OK, "a number would not go on the stack");
  {
    /* Two statements and not two arguments: C does not sequence a printf's arguments
     * against each other, so reading the slot inside one of them would race the other. */
    const char *before = name_of(nilu_type(N, 1));
    const char *text = nilu_tostring(N, 1);
    printf("a pushed number is type %s; reading it gives %s and leaves type %s\n", before,
           text == NULL ? "nothing" : text, name_of(nilu_type(N, 1)));
  }

  /* A numeral has a value, so what tostring writes tonumber reads. Hexadecimal and an
   * exponent are sources now; they were syntax errors through v0.0.26. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local written = tostring(1 / 3) "
                         "local same = tonumber(written) == 1 / 3 "
                         "return written .. \", read back: \" .. tostring(same) "
                         "   .. \", and 0x1p4 is \" .. tostring(0x1p4)",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a numeral round trip: %s\n", nilu_tostring(N, -1));
  }

  /* A host has the same reader, and the whole length has to be the numeral. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  {
    /* One statement each: C does not sequence a printf's arguments against each other,
     * and each of these can push. */
    NiluStatus spaced = nilu_stringtonumber(N, "  12.5 ", 7);
    NiluStatus trailing = nilu_stringtonumber(N, "12x", 3);
    NiluStatus infinity = nilu_stringtonumber(N, "inf", 3);
    printf("nilu_stringtonumber: \"  12.5 \" -> %d, \"12x\" -> %d, \"inf\" -> %d\n", spaced,
           trailing, infinity);
  }

  /* A program can declare its globals, and then a misspelled name is refused with a
   * column again. A declaration means every global, the library included. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "global string, total  total = string.len(\"hello\")  return total",
                         NULL) == NILU_OK,
         "a source that declares what it uses would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a program that declares its globals answers %g\n", nilu_tonumber(N, -1));
  }
  {
    NiluError where;
    NiluStatus status = nilu_loadstring(N, "global total  totl = 1", &where);
    printf("\"global total  totl = 1\" answers status %d at line %d, column %d\n", status,
           where.line, where.column);
    expect(status == NILU_ERR_SYNTAX, "a misspelled global was not refused");
  }

  /* A loop can count, and the control variable is read only. Each turn has its own, so
   * closures made in a loop hold three different values. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local fs, total = {}, 0 "
                         "for i = 1, 4 do total = total + i fs[i] = function() return i end end "
                         "return tostring(total) .. \", and the closures hold \" "
                         "   .. tostring(fs[1]()) .. tostring(fs[2]()) .. tostring(fs[3]())",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a for loop sums to %s\n", nilu_tostring(N, -1));
  }
  {
    NiluError where;
    NiluStatus status = nilu_loadstring(N, "for i = 1, 3 do i = 9 end", &where);
    printf("assigning to a for's variable answers status %d at column %d\n", status,
           where.column);
    expect(status == NILU_ERR_SYNTAX, "assigning to the control variable was accepted");
  }

  /* A loop can walk a table. pairs visits every key once in no particular order, so the
   * total is what can be checked; ipairs counts and so the order is its own. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local t = {} t[1] = 10 t[2] = 20 t.named = 12 "
                         "local keys, total = 0, 0 "
                         "for k, v in pairs(t) do keys = keys + 1 total = total + v end "
                         "local counted = \"\" "
                         "for i, v in ipairs(t) do counted = counted .. tostring(v) .. \" \" end "
                         "return tostring(keys) .. \" keys totalling \" .. tostring(total) "
                         "   .. \", and ipairs saw \" .. counted",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("walking a table: %s\n", nilu_tostring(N, -1));
  }

  /* A loop can be left early, and what a closure captured survives the jump. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N,
                         "local held, steps = nil, 0 "
                         "for i = 1, 100 do "
                         "  local x = i * 3 steps = steps + 1 "
                         "  if i == 4 then held = function() return x end break end "
                         "end "
                         "return tostring(steps) .. \" steps, and the closure holds \" "
                         "   .. tostring(held())",
                         NULL) == NILU_OK,
         "the source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("a loop left early: %s\n", nilu_tostring(N, -1));
  }

  /* An empty source is a program too: a block may have no statements, and the function
   * it produces returns nothing. A caller asking for a result is given nil. */
  expect(nilu_settop(N, 0) == NILU_OK, "the stack would not be emptied");
  expect(nilu_loadstring(N, "", NULL) == NILU_OK, "an empty source would not compile");
  if (nilu_call(N, 0, 1) == NILU_OK) {
    printf("an empty program returns nothing, so the result is %s\n",
           name_of(nilu_type(N, -1)));
  }

  /* A source the grammar does not accept. The status says what kind of failure it was,
   * and for a syntax error it can also say where. */
  {
    NiluError where;
    NiluStatus status = nilu_loadstring(N, "return 10 #\n 20", &where);
    printf("loading \"return 10 #\\n 20\" answers status %d at line %d, column %d\n", status,
           where.line, where.column);
    expect(status == NILU_ERR_SYNTAX, "a bad source was not a syntax error");
  }

  nilu_close(N);

  if (trouble) return 1;
  printf("done\n");
  return 0;
}
