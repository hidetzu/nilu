/* The nilu program itself, driven the way a person drives it.
 *
 * Why this exists and no other check replaces it:
 * every word of a diagnostic is in cli/nilu.c and none of it is in the library
 *, so a check that links the library cannot see any of it. This one
 * runs the program with an argument vector and a stream on stdin, and reads back the
 * bytes it wrote and the status it exited with.
 *
 * It says which subset it ran on its first line, it can run one case, and it can count
 * without running:
 *
 * zig build cli-test every case
 * zig build cli-test -- --list name them without running any
 * zig build cli-test -- --only=<name> run one
 *
 * The count is announced here, at the moment it runs. It is never written down
 *.
 *
 * POSIX, and it is the only file here that is: fork, pipe, execv and waitpid are what it
 * takes to hold both ends of a process, and a pseudo-terminal (XSI) is what the prompt's
 * line editor needs to be driven by keys. The library and the CLI are plain C99. What that
 * costs is that this check runs where those four exist, which is said in build.zig too.
 *
 * The program under test and its eight fixtures arrive as the first nine arguments, in
 * this order: the program, then test/cli/hello.nilu, bad.nilu, args.nilu, fails.nilu,
 * shebang.nilu, shebang-fails.nilu, hash.nilu and only-shebang.nilu. So nothing here knows
 * a path -- and the expected diagnostics are built from what was passed in rather than
 * written out, because a path is the build's to choose.
 */
/* posix_openpt, grantpt, unlockpt and ptsname are XSI. */
#define _XOPEN_SOURCE 700
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>

#include "nilu.h"

static const char *nilu_path;  /* the program under test */
static const char *hello_path; /* test/cli/hello.nilu */
static const char *bad_path;   /* test/cli/bad.nilu, which does not compile */
static const char *args_path;  /* test/cli/args.nilu, which prints its arguments */
static const char *fails_path; /* test/cli/fails.nilu, which fails on its third line */
/* ⚠ The four fixtures: ⚠ a shebang, a shebang whose third line fails, a first line
 * of `#` alone, and a file that is nothing but a shebang with no trailing newline. */
static const char *shebang_path;
static const char *shebang_fails_path;
static const char *hash_path;
static const char *only_shebang_path;

/* A case returns NULL when it passed, or the sentence that says what went wrong. */
typedef const char *(*nilu_case_fn)(void);

/* ── running the program ─────────────────────────────────────────────────────── */

/* Reads a descriptor to the end. The caller frees. NULL is a failure. */
static char *read_fully(int fd, size_t *len_out) {
  size_t capacity = 1024, len = 0;
  char *text = malloc(capacity);
  if (text == NULL) return NULL;
  for (;;) {
    ssize_t got = read(fd, text + len, capacity - len - 1);
    if (got < 0) {
      if (errno == EINTR) continue;
      free(text);
      return NULL;
    }
    if (got == 0) break;
    len += (size_t)got;
    if (len + 1 >= capacity) {
      char *bigger = realloc(text, capacity * 2);
      if (bigger == NULL) {
        free(text);
        return NULL;
      }
      text = bigger;
      capacity *= 2;
    }
  }
  text[len] = '\0';
  if (len_out != NULL) *len_out = len;
  return text;
}

static int write_fully(int fd, const char *text, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t put = write(fd, text + done, len - done);
    if (put < 0) {
      if (errno == EINTR) continue;
      return 0;
    }
    done += (size_t)put;
  }
  return 1;
}

/* What the program did: the two streams, and the status it exited with. */
typedef struct {
  char *out;
  char *err;
  int code;
} Ran;

/* Runs the program with `args` after its own name, feeding it `in`.
 *
 * The whole of stdin is written before either stream is read, which is safe only while
 * what the program writes fits in a pipe -- every case here writes a few dozen bytes.
 * A case that made it write megabytes would have to drain as it goes.
 */
/* 0 for none; set by the one case that needs it and cleared after. */
static long child_memory_limit = 0;

static const char *run_nilu(char *const *args, const char *in, size_t in_len, Ran *ran) {
  int in_pipe[2], out_pipe[2], err_pipe[2];
  int status = 0;
  pid_t pid;

  ran->out = NULL;
  ran->err = NULL;
  ran->code = -1;

  if (pipe(in_pipe) != 0) return "pipe failed";
  if (pipe(out_pipe) != 0) return "pipe failed";
  if (pipe(err_pipe) != 0) return "pipe failed";

  pid = fork();
  if (pid < 0) return "fork failed";
  if (pid == 0) {
    char *argv[16];
    int n = 0;
    argv[n++] = (char *)nilu_path;
    while (args[n - 1] != NULL && n < 15) {
      argv[n] = args[n - 1];
      if (argv[n] == NULL) break;
      n++;
    }
    argv[n] = NULL;
    if (dup2(in_pipe[0], STDIN_FILENO) < 0) _exit(126);
    if (dup2(out_pipe[1], STDOUT_FILENO) < 0) _exit(126);
    if (dup2(err_pipe[1], STDERR_FILENO) < 0) _exit(126);
    close(in_pipe[0]);
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[0]);
    close(err_pipe[1]);
    /* An address-space limit for the one case that needs memory to run out. */
    if (child_memory_limit > 0) {
      struct rlimit limit;
      limit.rlim_cur = child_memory_limit;
      limit.rlim_max = child_memory_limit;
      if (setrlimit(RLIMIT_AS, &limit) != 0) _exit(125);
    }
    execv(nilu_path, argv);
    _exit(127);
  }

  close(in_pipe[0]);
  close(out_pipe[1]);
  close(err_pipe[1]);

  if (in != NULL && in_len > 0 && !write_fully(in_pipe[1], in, in_len)) {
    close(in_pipe[1]);
    close(out_pipe[0]);
    close(err_pipe[0]);
    waitpid(pid, &status, 0);
    return "could not write to the program's stdin";
  }
  close(in_pipe[1]);

  ran->out = read_fully(out_pipe[0], NULL);
  ran->err = read_fully(err_pipe[0], NULL);
  close(out_pipe[0]);
  close(err_pipe[0]);

  if (waitpid(pid, &status, 0) < 0) return "waitpid failed";
  if (ran->out == NULL || ran->err == NULL) return "could not read what the program wrote";
  if (!WIFEXITED(status)) return "the program did not exit normally";
  ran->code = WEXITSTATUS(status);
  return NULL;
}

/* ── comparing ───────────────────────────────────────────────────────────────── */

/* Renders bytes so a failure is readable on one line.
 *
 * Two buffers, used in turn, because a complaint shows both streams at once: with one
 * buffer the second call overwrote the first and every failure read "wrote X and not X".
 * Measured -- that is exactly what the first run of this file printed. */
#define SHOWN_MAX 512

static const char *shown(const char *text) {
  static char buffers[2][SHOWN_MAX];
  static int which = 0;
  char *buffer = buffers[which];
  size_t at = 0;
  which = 1 - which;
  if (text == NULL) return "(nothing)";
  buffer[at++] = '"';
  /* ⚠ SHOWN_MAX and not `sizeof buffer`: buffer is a pointer here, so that read 8 and
  every complaint was cut to three characters. ⚠ -Wall -Wextra -Werror did not say so. */
  while (*text != '\0' && at + 4 < SHOWN_MAX) {
    if (*text == '\n') {
      buffer[at++] = '\\';
      buffer[at++] = 'n';
    } else if (*text == '\t') {
      buffer[at++] = '\\';
      buffer[at++] = 't';
    } else {
      buffer[at++] = *text;
    }
    text++;
  }
  buffer[at++] = '"';
  buffer[at] = '\0';
  return buffer;
}

static char complaint[1024];

/* Runs the program and holds it to what it should have written.
 *
 * `out` and `err` may be NULL, which means "do not look at that stream" -- used where the
 * bytes are the C library's to choose and only the first part of them is ours. */
static const char *expect(char *const *args, const char *in, size_t in_len, const char *out,
                          const char *err, int code) {
  Ran ran;
  const char *broke = run_nilu(args, in, in_len, &ran);
  const char *failure = NULL;

  if (broke != NULL) {
    free(ran.out);
    free(ran.err);
    return broke;
  }
  if (out != NULL && strcmp(ran.out, out) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stdout and not %s", shown(ran.out), shown(out));
    failure = complaint;
  } else if (err != NULL && strcmp(ran.err, err) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stderr and not %s", shown(ran.err), shown(err));
    failure = complaint;
  } else if (ran.code != code) {
    snprintf(complaint, sizeof complaint, "exited %d and not %d", ran.code, code);
    failure = complaint;
  }
  free(ran.out);
  free(ran.err);
  return failure;
}

/* The same, where only the start of a stream is ours to promise. */
static const char *expect_err_starts(char *const *args, const char *err_prefix, int code) {
  Ran ran;
  const char *broke = run_nilu(args, NULL, 0, &ran);
  const char *failure = NULL;

  if (broke != NULL) {
    free(ran.out);
    free(ran.err);
    return broke;
  }
  if (strncmp(ran.err, err_prefix, strlen(err_prefix)) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stderr, which does not start with %s",
             shown(ran.err), shown(err_prefix));
    failure = complaint;
  } else if (ran.code != code) {
    snprintf(complaint, sizeof complaint, "exited %d and not %d", ran.code, code);
    failure = complaint;
  }
  free(ran.out);
  free(ran.err);
  return failure;
}

/* The last `n` segments of a path, as a pointer into it. For an expectation that has to name
  a path without this file knowing one: the build chooses where the fixture is (main's
  argv), and `n` segments of its tail are the same wherever the tree was written. */
static const char *last_segments(const char *path, int n) {
  const char *at = path + strlen(path);
  while (at > path && n > 0) {
    at--;
    if (*at == '/' && --n == 0) return at + 1;
  }
  return path;
}

/* Like `expect`, with stderr asserted by its tail -- for a sentence carrying a chunk id,
  which is bounded: `chunkId` leaves an `@name` of 59 bytes or fewer alone and shows a
  longer one as `...` plus its last 56 bytes, which is `luaO_chunkid`'s rule.
  So a case that spelled the whole absolute path passed or failed by where the tree was
  written -- measured: a tree whose fixture path came to 127 bytes failed it, and this
  checkout's 53 bytes passed, six short of the 59 where truncation begins.
  What the tail has to carry is every part of the claim: enough path to be a path and not a
  bare file name, the line, and Lua's sentence. The program's name in front is asserted
  separately, and nothing may be written before that -- a newline anywhere but at the end
  means a line came first. */
/* NOTE: this asserts a SUFFIX, so a prefix it is not given is a prefix it cannot see --
  which is how a file refusal with no `chunk:line:` in front of it passes a suffix check. Put the position into `err_tail` when the raise carries one. */
static const char *expect_err_ends(char *const *args, const char *out, const char *err_tail,
                                   int code) {
  Ran ran;
  const char *broke = run_nilu(args, NULL, 0, &ran);
  const char *failure = NULL;
  size_t said, tail;

  if (broke != NULL) {
    free(ran.out);
    free(ran.err);
    return broke;
  }
  said = strlen(ran.err);
  tail = strlen(err_tail);
  if (out != NULL && strcmp(ran.out, out) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stdout and not %s", shown(ran.out), shown(out));
    failure = complaint;
  } else if (said <= tail || strcmp(ran.err + (said - tail), err_tail) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stderr, and not the program's name and then %s",
             shown(ran.err), shown(err_tail));
    failure = complaint;
  } else if (strncmp(ran.err, "nilu: ", 6) != 0) {
    snprintf(complaint, sizeof complaint, "wrote %s to stderr, which does not start with the program's name",
             shown(ran.err));
    failure = complaint;
  } else if (strchr(ran.err, '\n') != ran.err + (said - 1)) {
    snprintf(complaint, sizeof complaint, "wrote %s to stderr, which says something before the message",
             shown(ran.err));
    failure = complaint;
  } else if (ran.code != code) {
    snprintf(complaint, sizeof complaint, "exited %d and not %d", ran.code, code);
    failure = complaint;
  }
  free(ran.out);
  free(ran.err);
  return failure;
}

/* The version line, which every case that enters the prompt sees first. */
static const char *banner(void) {
  static char line[64];
  snprintf(line, sizeof line, "nilu %s\n", NILU_VERSION);
  return line;
}

/* ── the cases ───────────────────────────────────────────────────────────────── */

static const char *case_v_says_the_version(void) {
  char *args[] = {"-v", NULL};
  return expect(args, NULL, 0, banner(), "", 0);
}

static const char *case_e_runs_the_text(void) {
  char *args[] = {"-e", "print(1 + 2)", NULL};
  /* A whole number ends in .0, because every Nilu number is a float. */
  return expect(args, NULL, 0, "3\n", "", 0);
}

static const char *case_e_glued_to_its_text(void) {
  char *args[] = {"-eprint(7)", NULL};
  return expect(args, NULL, 0, "7\n", "", 0);
}

static const char *case_a_script_s_results_are_discarded(void) {
  /* Lua's dochunk calls docall(L, 0, 0): a script's results go nowhere, and only the
  prompt prints them. */
  char *args[] = {"-e", "return 42", NULL};
  return expect(args, NULL, 0, "", "", 0);
}

static const char *case_print_writes_a_tab_between_values(void) {
  /* luaB_print's format, borrowed: a tab between values and one newline after. And what
  spells them is the library's tostring, so nil, a boolean and a number all have a
  spelling here. */
  char *args[] = {"-e", "print(1, \"a\", true, nil)", NULL};
  return expect(args, NULL, 0, "1\ta\ttrue\tnil\n", "", 0);
}

static const char *case_print_asks_the_metatable(void) {
  /* Written in four statements and not with a table constructor: `{__tostring = f}` is a
  syntax error here, because the only thing between { and } is nothing.
  This case was written the other way first, and the program refused it. */
  char *args[] = {"-e",
                  "local t = {} local mt = {} mt.__tostring = function() return \"it\" end "
                  "setmetatable(t, mt) print(t)",
                  NULL};
  return expect(args, NULL, 0, "it\n", "", 0);
}

static const char *case_a_file_runs(void) {
  char *args[2];
  args[0] = (char *)hello_path;
  args[1] = NULL;
  return expect(args, NULL, 0, "hello\n3\n", "", 0);
}

static const char *case_a_dash_runs_what_is_on_stdin(void) {
  char *args[] = {"-", NULL};
  const char *in = "print(1 + 2)\n";
  return expect(args, in, strlen(in), "3\n", "", 0);
}

static const char *case_the_prompt_answers_an_expression(void) {
  /* addreturn: `return <line>;` is tried first, so a line that is only an expression
  answers. */
  char *args[] = {NULL};
  const char *in = "1 + 2\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> 3\n> \n", banner());
  return expect(args, in, strlen(in), out, "", 0);
}

static const char *case_the_prompt_takes_a_statement(void) {
  /* The fallback: `return local x = 1` does not compile, so the line as written runs, and a
  statement answers nothing.
  The warning on stderr is checklocal's, borrowed verbatim: a local still
  does not survive to the next statement, and lua5.5 says so out loud -- measured. */
  char *args[] = {NULL};
  const char *in = "local x = 1\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> > \n", banner());
  return expect(args, in, strlen(in), out,
                "warning: locals do not survive across lines in interactive mode\n", 0);
}

/* ── the prompt reads until the statement is complete ─────────────── */

static const char *case_the_prompt_reads_a_statement_that_spans_lines(void) {
  /* lua5.5, measured by piping the same three lines into `lua5.5 -i`: two `>> ` prompts and
  then `yes`. The typed text is not echoed here, which is this program's own behaviour -- so what proves where the continuation happened is the prompts. */
  char *args[] = {NULL};
  const char *in = "if 1 == 1 then\nprint(\"yes\")\nend\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> >> >> yes\n> \n", banner());
  return expect(args, in, strlen(in), out, "", 0);
}

static const char *case_an_expression_still_answers_on_one_line(void) {
  /* The `return <line>` attempt must not read a continuation: an expression that compiles
  answers at once, and `1 + 2` is the line that would break if it did. */
  char *args[] = {NULL};
  const char *in = "1 + 2\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> 3\n> \n", banner());
  return expect(args, in, strlen(in), out, "", 0);
}

static const char *case_a_line_number_survives_the_join(void) {
  /* The lines are joined with a newline between them, so a failure on the second line says
  2. lua5.5 says `stdin:2:` for this very input, measured. */
  char *args[] = {NULL};
  const char *in = "if 1 == 1 then\nprint(nil + 1)\nend\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> >> >> > \n", banner());
  return expect(args, in, strlen(in), out,
                "stdin:2: attempt to perform arithmetic on a nil value\n", 0);
}

static const char *case_the_input_ending_mid_statement_reports(void) {
  /* pushline answering 0 makes multiline return the status it holds, so what a reader gets
  is the refusal and not silence. The `>> ` is printed before the read
  discovers there is nothing, which is Lua's order too. */
  char *args[] = {NULL};
  const char *in = "if 1 then\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> >> > \n", banner());
  return expect(args, in, strlen(in), out, "stdin:1:10: 'end' expected near <eof>\n", 0);
}

static const char *case_a_string_left_open_asks_once_and_then_refuses(void) {
  /* A short string cannot span lines, and Lua still asks: the first line's message ends with
  <eof> and only the joined text's says '"abc'. Measured on lua5.5, which answers
  `stdin:1: unfinished string near '"abc'` -- the column is this project's. */
  char *args[] = {NULL};
  const char *in = "print(\"abc\ndef\")\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> >> > \n", banner());
  return expect(args, in, strlen(in), out, "stdin:1:11: unfinished string near '\"abc'\n", 0);
}

static const char *case_a_name_beginning_local_is_not_warned_about(void) {
  /* checklocal's own test: `local` has to be followed by a space or a tab, so an assignment
  to a name that merely starts with those letters says nothing. */
  char *args[] = {NULL};
  const char *in = "locals = 1\nprint(locals)\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> > 1\n> \n", banner());
  return expect(args, in, strlen(in), out, "", 0);
}

static const char *case_the_prompt_says_nothing_about_the_program_s_name(void) {
  /* doREPL's `progname = NULL`, borrowed: a failure at the prompt is not prefixed. */
  char *args[] = {NULL};
  const char *in = "return nil + 1\n";
  static char out[128];
  snprintf(out, sizeof out, "%s> > \n", banner());
  /* The sentence is the core's; the missing `nilu: ` is still
  doREPL's `progname = NULL`. Measured: lua5.5 at a prompt that is not a terminal says
  `lua5.5: stdin:1: attempt to perform arithmetic on a nil value`, with its own name. */
  return expect(args, in, strlen(in), out, "stdin:1: attempt to perform arithmetic on a nil value\n", 0);
}

static const char *case_i_runs_the_script_and_then_the_prompt(void) {
  char *args[3];
  static char out[128];
  args[0] = "-i";
  args[1] = (char *)hello_path;
  args[2] = NULL;
  snprintf(out, sizeof out, "%shello\n3\n> 9\n> \n", banner());
  return expect(args, "return 9\n", 9, out, "", 0);
}

static const char *case_a_syntax_error_says_where(void) {
  char *args[2];
  static char err[512];
  args[0] = (char *)bad_path;
  args[1] = NULL;
  /* The second line of the fixture is `local = 1`, and `=` is the seventh byte of it. */
  /* lua5.5 on the same two lines: `<name> expected near '='`, measured. The column is this
  program's and Lua has none, so the shape differs by that field
  and the words do not. */
  snprintf(err, sizeof err, "nilu: %s:2:7: <name> expected near '='\n", bad_path);
  return expect(args, NULL, 0, "", err, 1);
}

/* the message a refused source carries, printed as the program prints any string
 * a failure left behind. */
static const char *case_a_refused_source_says_what_was_expected(void) {
  /* lua5.5, measured: `')' expected near <eof>`. */
  char *args[] = {"-e", "return (1", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1:10: ')' expected near <eof>\n", 1);
}

static const char *case_a_type_error_names_the_command_line(void) {
  char *args[] = {"-e", "return nil + 1", NULL};
  /* lua5.5, measured: `lua5.5: (command line):1: attempt to perform arithmetic on a nil
  value`. The words are the core's. */
  return expect(args, NULL, 0, "", "nilu: (command line):1: attempt to perform arithmetic on a nil value\n", 1);
}

static const char *case_a_runtime_error_is_what_a_refusal_becomes(void) {
  /* A failure that carries nothing is where the program's own word for the status is read
  (nilu.h, NiluCFunction). From a script that is error() with no value, which raises nil; a value that is not a string gets the word too, with its kind on a
  second line.
  lua5.5 says `(error object is a nil value)` here, measured: its msghandler names the kind
  of a non-string error object, and nil reaches that path there while it reaches the status
  word here. A difference in the program and not in the language. */
  char *args[] = {"-e", "error()", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1: runtime error\n", 1);
}

/* a refusal with no argument number says what happened too. */
static const char *case_a_refusal_with_no_argument_number_says_what_happened(void) {
  /* lua5.5, measured: `wrong number of arguments to 'insert'`. */
  char *args[] = {"-e", "local t = {} table.insert(t, 1, 2, 3)", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: wrong number of arguments to 'insert'\n", 1);
}

/* a malformed pattern says what is wrong with it. */
static const char *case_a_malformed_pattern_says_so(void) {
  /* lua5.5, measured: `malformed pattern (ends with '%')`. */
  char *args[] = {"-e", "string.find(\"a\", \"%\")", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: malformed pattern (ends with '%')\n", 1);
}

/* the library says which argument of which function was wrong. */
static const char *case_a_library_refusal_names_the_argument(void) {
  /* lua5.5, measured: `bad argument #1 to 'rep' (string expected, got no value)`. */
  char *args[] = {"-e", "string.rep()", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: bad argument #1 to 'rep' (string expected, got no value)\n", 1);
}

static const char *case_five_spellings_run_from_the_command(void) {
  /* Five statement spellings, through the program a person actually types. The Zig tests hold
  each one's semantics; this holds that the command compiles and runs them. */
  char *args[] = {"-e",
                  "global * do local x = 1 print(x) end;"
                  " function f(n) if n == 1 then return \"one\""
                  " elseif n == 2 then return \"two\" else return \"many\" end end"
                  " print(f(1), f(2), f(9));"
                  " print \"done\"",
                  NULL};
  return expect(args, NULL, 0, "1\none\ttwo\tmany\ndone\n", "", 0);
}

static const char *case_a_recursion_too_deep_says_so(void) {
  /* ldo.c's `stack overflow`, measured on lua5.5 for this very source. The program's own
  word for the status, `too many nested calls`, is held in reserve: a depth failure carries
  `stack overflow`, so the word is not printed here. */
  char *args[] = {"-e", "local function f() return 1 + f() end return f()", NULL};
  /* The prefix, because a traceback follows it and its shape is what the two cases below
  are for. This case is about the sentence. */
  return expect_err_starts(args, "nilu: (command line):1: stack overflow\n", 1);
}

static const char *case_a_traceback_names_every_frame_innermost_first(void) {
  /* Three frames with distinct lines, so the order is read and not assumed.
  Each line names its function as lua5.5 does, from the call that reached it (the owner's
  answer); lua5.5's last `[C]: in ?`, its own call into the chunk, has no
  frame here. */
  char *args[] = {"-e",
                  "global *\n"
                  "local function c() local v = 1 + nil return v end\n"
                  "local function b() local v = c() return v end\n"
                  "local v = b()\n",
                  NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):2: attempt to perform arithmetic on a nil value\n"
                "stack traceback:\n"
                "\t(command line):2: in upvalue 'c'\n"
                "\t(command line):3: in local 'b'\n"
                "\t(command line):4: in main chunk\n",
                1);
}

static const char *case_one_frame_prints_no_traceback(void) {
  /* The owner's answer, and the reason is that a one-frame traceback would repeat the line
  above it: with the names gone it carries nothing. A syntax error gets
  none either, because it fails at load -- and lua5.5 prints none for one, measured. */
  char *args[] = {"-e", "global * return 1 + nil", NULL};
  const char *failure = expect(args, NULL, 0, "",
                               "nilu: (command line):1: attempt to perform arithmetic on a"
                               " nil value\n",
                               1);
  if (failure != NULL) return failure;
  {
    /* error() at the top: the native's [C] frame is written in a traceback, and one Nilu frame still prints none -- the rule counts Nilu functions. */
    char *raised[] = {"-e", "error('x')", NULL};
    failure = expect(raised, NULL, 0, "", "nilu: (command line):1: x\n", 1);
    if (failure != NULL) return failure;
  }
  {
    char *bad[] = {"-e", "return 1 +", NULL};
    return expect(bad, NULL, 0, "",
                  "nilu: (command line):1:11: unexpected symbol near <eof>\n", 1);
  }
}

static const char *case_a_long_traceback_is_elided_in_the_middle(void) {
  /* luaL_traceback's LEVELS1 and LEVELS2, borrowed with their tabs: ten from the top, the
  count of what is skipped, eleven from the bottom. lua5.5 prints 24 lines for a program
  that recurses until it fails, measured, and so does this -- where writing every level
  would be two hundred identical ones. */
  char *args[] = {"-e", "local function f() return 1 + f() end return f()", NULL};
  Ran ran;
  const char *broke = run_nilu(args, NULL, 0, &ran);
  const char *failure = NULL;
  int lines = 0;
  const char *at;

  if (broke != NULL) {
    free(ran.out);
    free(ran.err);
    return broke;
  }
  for (at = ran.err; *at != '\0'; at++) {
    if (*at == '\n') lines++;
  }
  if (strstr(ran.err, "\n\t...\t(skipping ") == NULL) {
    failure = "a traceback longer than the two parts was not elided";
  } else if (lines != 24) {
    snprintf(complaint, sizeof complaint, "wrote %d lines where lua5.5 writes 24", lines);
    failure = complaint;
  }

  free(ran.out);
  free(ran.err);
  return failure;
}

static const char *case_a_source_may_not_hold_a_zero_byte(void) {
  /* nilu_loadstring takes a NUL-terminated source, so a zero byte would end it early and
  the part before it would compile and report success. */
  char *args[] = {"-", NULL};
  const char in[] = "print(1)\0print(2)\n";
  return expect(args, in, sizeof in - 1, "", "nilu: stdin: a zero byte, which a source may not contain\n", 1);
}

static const char *case_a_file_that_is_not_there(void) {
  char *args[] = {"no-such-file.nilu", NULL};
  static char err[256];
  snprintf(err, sizeof err, "nilu: cannot open no-such-file.nilu: %s\n", strerror(ENOENT));
  return expect(args, NULL, 0, "", err, 1);
}

/* -l runs require in order with -e and keeps the answer in a global (the owner's
  answer); a library already loaded needs no reader. */
static const char *case_l_requires_a_module_into_a_global(void) {
  char *args[] = {"-e", "x = 1", "-l", "string", "-ls=string", "-e", "print(x, string == s, s.upper('a'))", NULL};
  return expect(args, NULL, 0, "1\ttrue\tA\n", "", 0);
}

static const char *case_l_without_a_module_fails_as_a_script_does(void) {
  char *args[] = {"-l", "nosuch", "-e", "print('not reached')", NULL};
  return expect(args, NULL, 0, "", "nilu: cannot find module 'nosuch': no file 'nosuch.nilu'\n", 1);
}

/* -W: warnings start on, as after warn("@on"); they go to standard error. */
static const char *case_w_turns_warnings_on(void) {
  char *args[] = {"-W", "-e", "warn('careful') print('done')", NULL};
  return expect(args, NULL, 0, "done\n", "Nilu warning: careful\n", 0);
}

/* Runs the program with no arguments on a pseudo-terminal, typing each key after a
  short pause, and answers what the terminal showed. */
static const char *run_on_terminal(const char *const *keys, char *shown, size_t size) {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  size_t used = 0;
  pid_t pid;
  int status = 0;
  size_t k;
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) return "no pseudo-terminal";
  pid = fork();
  if (pid < 0) return "fork failed";
  if (pid == 0) {
    int slave;
    char *argv[2];
    setsid();
    slave = open(ptsname(master), O_RDWR);
    if (slave < 0) _exit(126);
    dup2(slave, STDIN_FILENO);
    dup2(slave, STDOUT_FILENO);
    dup2(slave, STDERR_FILENO);
    close(master);
    argv[0] = (char *)nilu_path;
    argv[1] = NULL;
    execv(nilu_path, argv);
    _exit(127);
  }
  for (k = 0;; k++) {
    struct pollfd ready;
    struct timespec pause = {0, 50000000};
    nanosleep(&pause, NULL);
    ready.fd = master;
    ready.events = POLLIN;
    while (poll(&ready, 1, 100) > 0) {
      ssize_t n = read(master, shown + used, size - 1 - used);
      if (n <= 0) break;
      used += (size_t)n;
    }
    if (keys[k] == NULL) break;
    if (write(master, keys[k], strlen(keys[k])) < 0) break;
  }
  waitpid(pid, &status, 0);
  close(master);
  shown[used] = '\0';
  return NULL;
}

static int count_of(const char *text, const char *part) {
  int n = 0;
  const char *at = text;
  while ((at = strstr(at, part)) != NULL) {
    n++;
    at += strlen(part);
  }
  return n;
}

/* The prompt's line editor (the owner's answer): arrows
  move by characters, a non-ASCII one included, Up recalls the session's lines, Ctrl-A
  goes to the start, Ctrl-C drops the line, Ctrl-D on an empty line ends. */
static const char *case_the_prompt_edits_lines_on_a_terminal(void) {
  static char shown[16384];
  static const char *const keys[] = {"21", "\x1b[D", "\x1b[D", "1", "\r", "\x1b[A", "\r",
                                     "'\xe3\x81\x82\xe3\x81\x84'", "\x1b[D", "\x1b[D", "\x7f", "\r",
                                     "y = 5", "\x01", "local ", "\x03", "y == nil\r", "\x04", NULL};
  const char *broke = run_on_terminal(keys, shown, sizeof shown);
  if (broke != NULL) return broke;
  if (count_of(shown, "\r\n121\r\n") != 2) return "Left/Right and Up did not give 121 twice";
  if (count_of(shown, "\r\n\xe3\x81\x84\r\n") != 1) return "Backspace did not remove one whole character";
  if (count_of(shown, "^C") != 1 || count_of(shown, "\r\ntrue\r\n") != 1) return "Ctrl-C did not drop the line";
  return NULL;
}

static const char *case_an_unknown_option_is_refused(void) {
  char *args[] = {"-x", NULL};
  return expect_err_starts(args, "nilu: unknown option -x\nusage: nilu", 1);
}

/* ── a script's arguments ─────────────────────────────────────────── */

static const char *case_a_script_receives_its_arguments_as_dots_and_as_arg(void) {
  /* lua5.5 s.lua one two: `one two`, then `s.lua one two 2`, then 2. The same here, with the
  fixture's path where lua prints its own. */
  char *args[4];
  char expected[1024];
  args[0] = (char *)args_path;
  args[1] = "one";
  args[2] = "two";
  args[3] = NULL;
  snprintf(expected, sizeof expected, "one\ttwo\n%s\tone\ttwo\t2\n2\n", args_path);
  return expect(args, NULL, 0, expected, "", 0);
}

static const char *case_stdin_as_the_script_receives_arguments_too(void) {
  char *args[] = {"-", "p", "q", NULL};
  /* `...` in the middle of an argument list is one value (5.6 in the manual), so the two
  prints are separate -- a first draft wrote print(..., arg[0]) and expected three values. */
  const char *in = "print(...) print(arg[0])\n";
  return expect(args, in, strlen(in), "p\tq\n-\n", "", 0);
}

static const char *case_e_has_arg_and_nothing_in_dots(void) {
  /* lua -e 'print(select("#", ...), arg)': 0 and a table -- the chunk is vararg and gets
  nothing. Without a script, as Lua's lua.c does, arg[0] is the program and the options
  follow it: arg[1] is "-e" and arg[2] the text, so #arg is 2 and nothing is negative. */
  char *args[] = {"-e", "print(select(\"#\", ...), type(arg), arg[-1], arg[1], type(arg[0]), #arg)", NULL};
  return expect(args, NULL, 0, "0\ttable\tnil\t-e\tstring\t2\n", "", 0);
}

static const char *case_the_options_before_the_script_are_arg_s_negative_indices(void) {
  char *args[5];
  char expected[1024];
  args[0] = "-e";
  args[1] = "x = 1";
  args[2] = (char *)args_path;
  args[3] = "only";
  args[4] = NULL;
  /* createargtable: argv[i] at i - script. Here script is 3: nilu at -3, -e at -2, the text
  at -1, the script at 0, "only" at 1. The fixture prints ..., then arg[0..2] and #arg. */
  snprintf(expected, sizeof expected, "only\n%s\tonly\tnil\t1\n1\n", args_path);
  return expect(args, NULL, 0, expected, "", 0);
}

static const char *case_e_without_its_text_is_refused(void) {
  /* `-e` with nothing after it is not an unknown option, and the diagnostic says which it
  is: a reader's next move depends on that. */
  char *args[] = {"-e", NULL};
  return expect_err_starts(args, "nilu: -e needs the text to run", 1);
}

/* ── io and os ─────────────────────────────────────────────────────── */

static const char *case_io_write_writes_bytes_and_nothing_between_them(void) {
  /* g_write: no tab, no newline, a number spelled this project's way (1.0, not Lua's 1). */
  char *args[] = {"-e", "io.write(\"a\", 1, \"b\", 1.5, \"\\n\")", NULL};
  return expect(args, NULL, 0, "a1b1.5\n", "", 0);
}

static const char *case_io_write_refuses_what_is_not_a_string_or_a_number(void) {
  /* luaL_checklstring's refusal, with its words: the command's refusals say what Lua's say. */
  char *args[] = {"-e", "io.write(nil)", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: bad argument #1 to 'write'"
                " (string expected, got nil)\n",
                1);
}

static const char *case_io_write_answers_nothing(void) {
  /* ⚠ The name says the opposite of what is asserted: io.write answers the current output,
  * as Lua's g_write does. ⚠ The name stays, because a case's name is
  * what a run announces and a rename would read as a new case. */
  char *args[] = {"-e", "print(select(\"#\", io.write(\"x\")), io.write(\"\") == io.stdout)", NULL};
  return expect(args, NULL, 0, "x1\ttrue\n", "", 0);
}

static const char *case_a_failure_at_the_stream_says_why(void) {
  /* ⚠ luaL_fileresult's three values from every stream failure, and g_write's fourth
  *: measured on lua5.5, `nil Bad file descriptor 9` for a read on a
  * write-only file and for io.read after io.input, and `... 9 0` from io.write. Each
  * of the three paths answered a wordless `runtime error` until v0.0.94. */
  char *args[] = {"-e",
                  "local w = io.open(\"/dev/null\", \"w\")"
                  " print(select(\"#\", w:read(\"l\")), select(2, w:read(\"l\")))"
                  " io.input(w) print(select(\"#\", io.read(\"l\")))"
                  " local r = io.open(\"/dev/null\", \"r\")"
                  " io.output(r) print(select(\"#\", io.write(\"x\")), select(4, io.write(\"x\")))"
                  " print(select(\"#\", r:write(\"x\")), select(3, r:write(\"x\")))",
                  NULL};
  return expect(args, NULL, 0, "3\tBad file descriptor\t9\n3\n4\t0\n4\t9\t0\n", "", 0);
}

static const char *case_a_lines_iterator_raises_a_stream_failure(void) {
  /* ⚠ io_readline raises the message where a read answers three values:
  * `for l in f:lines()` on a write-only file ends the program with `Bad file descriptor`,
  * as lua5.5 does. An iterator answering nil, msg, errno ended the loop silently, which
  * the review measured. */
  char *args[] = {"-e",
                  "local f = io.open(\"/dev/null\", \"w\") local n = 0"
                  " for l in f:lines() do n = n + 1 end print(\"after\", n)",
                  NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1: Bad file descriptor\n", 1);
}

static const char *case_a_failed_flush_says_its_errno(void) {
  /* ⚠ /dev/full is the one file a write to always fails on; buffered, the failure lands
  * on flush, and luaL_fileresult answers three values there too. */
  char *args[] = {"-e",
                  "local f = io.open(\"/dev/full\", \"w\") f:write(\"x\")"
                  " local a, b, c = f:flush() print(a, b, c)",
                  NULL};
  return expect(args, NULL, 0, "nil\tNo space left on device\t28\n", "", 0);
}

/* ── files ─────────────────────────────────────────────────────────
 *
 * A file is the command's, so this is where it can be checked at all: the library does not
 * have one and test/c/smoke.c links the library.
 * mkstemp and unlink are this file's to use -- it says at the top that it is the one POSIX
 * file here, for fork and execv. */

/* Runs `-e <source with %s replaced by a temp path>` and answers what the file held
 * afterwards, or NULL when the program did not behave as asked. */
static const char *with_temp_file(const char *source_format, const char *out, const char *err,
                                  int code, const char *wanted_contents) {
  char path[] = "/tmp/nilu-cli-file-XXXXXX";
  char source[512];
  char back[256];
  char *args[3];
  const char *failure;
  int fd = mkstemp(path);
  if (fd < 0) return "could not make a temporary file";
  close(fd);

  snprintf(source, sizeof source, source_format, path, path);
  args[0] = "-e";
  args[1] = source;
  args[2] = NULL;
  failure = expect(args, NULL, 0, out, err, code);

  if (failure == NULL && wanted_contents != NULL) {
    FILE *in = fopen(path, "r");
    size_t len = 0;
    if (in == NULL) {
      failure = "the file is not there afterwards";
    } else {
      len = fread(back, 1, sizeof back - 1, in);
      fclose(in);
      back[len] = '\0';
      if (strcmp(back, wanted_contents) != 0) failure = "the file does not hold what was written";
    }
  }
  unlink(path);
  return failure;
}

/* ── the standard files and the current pair ───────────────────── */

static const char *case_the_three_standard_files_are_values(void) {
  char *args[] = {"-e",
                  "global * print(type(io.stdout), getmetatable(io.stdout).__name,"
                  " io.stdin ~= nil, io.stderr ~= nil)",
                  NULL};
  return expect(args, NULL, 0, "userdata\tFILE*\ttrue\ttrue\n", "", 0);
}

static const char *case_a_standard_file_will_not_close(void) {
  /* Two values and no raise, measured -- and it goes on working afterwards, because
  nothing was done to it. */
  char *args[] = {"-e",
                  "global * local ok, why = io.stdout.close(io.stdout)"
                  " io.stdout.write(io.stdout, tostring(ok) .. \" \" .. why .. \"\\n\")",
                  NULL};
  return expect(args, NULL, 0, "nil cannot close standard file\n", "", 0);
}

static const char *case_io_write_follows_the_current_output(void) {
  /* io.write follows the current output, which starts as stdout. */
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") print(io.output(f) == f)"
      " io.write(\"into the file\") io.output(io.stdout) f.close(f) io.write(\"to stdout\\n\")%.0s",
      "true\nto stdout\n", "", 0, "into the file");
}

static const char *case_io_read_follows_the_current_input(void) {
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"a line\\n\") f.close(f)"
      " local g = io.open(\"%s\") io.input(g) print(io.read(\"l\")) io.input(io.stdin) g.close(g)",
      "a line\n", "", 0, "a line\n");
}

static const char *case_a_file_seeks(void) {
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"one\\ntwo\\n\") f.close(f)"
      " local g = io.open(\"%s\") print(g.seek(g), g.seek(g, \"end\"))"
      " g.seek(g, \"set\", 4) print(g.read(g, \"l\")) g.read(g, \"a\")"
      " print(g.seek(g, \"cur\", 0 - 4)) g.close(g)",
      "0\t8\ntwo\n4\n", "", 0, "one\ntwo\n");
}

static const char *case_flush_and_setvbuf_answer_true(void) {
  /* flush answers true and not the file: 5.5's answer, where 5.4 answered the file. */
  char *args[] = {"-e",
                  "global * print(io.flush(), io.stdout.flush(io.stdout),"
                  " io.stdout.setvbuf(io.stdout, \"line\"))",
                  NULL};
  return expect(args, NULL, 0, "true\ttrue\ttrue\n", "", 0);
}

static const char *case_a_bad_option_names_the_call(void) {
  /* Lua says bad argument #2 to '?' here, because it had no call site and no global name
  to fall back to; this says 'seek', which is the name the program wrote. */
  char *args[] = {"-e",
                  "global * local ok, e = pcall(function() local f = io.stdout"
                  " return f.seek(f, \"nope\") end) print(e)",
                  NULL};
  return expect(args, NULL, 0,
                "(command line):1: bad argument #2 to 'seek' (invalid option 'nope')\n", "", 0);
}

static const char *case_a_closed_default_is_said_and_not_fallen_back_from(void) {
  /* The first cut of the current pair fell back to stdout here, and wrote the bytes to the
  terminal -- somewhere the program never asked for. lua5.5 raises getiofile's own
  sentence instead, measured. Both halves of the pair,
  because one of them falling back is as wrong as the other. */
  char *args[] = {"-e",
                  "global * local f = io.open(\"/dev/null\", \"w\") io.output(f) f.close(f)"
                  " local g = io.open(\"/dev/null\", \"r\") io.input(g) g.close(g)"
                  " print(select(2, pcall(io.write, \"x\")))"
                  " print(select(2, pcall(io.read, \"l\")))",
                  NULL};
  return expect(args, NULL, 0,
                "default output file is closed\n"
                "default input file is closed\n",
                "", 0);
}

static const char *case_an_option_that_is_not_a_string_says_so(void) {
  /* lua5.5 coerces a number through luaL_optstring and answers invalid option '1'; nothing
  in Nilu turns a number into a string, so this says what the type was -- a forced
  deviation, named. It said nothing at all, and pcall saw nil,
  until the review measured it. */
  char *args[] = {"-e",
                  "global * local f = io.stdout"
                  " print(select(2, pcall(f.seek, f, 1)))"
                  " print(select(2, pcall(f.setvbuf, f, 1)))"
                  " print(select(2, pcall(f.setvbuf, f)))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #2 to 'seek' (string expected, got number)\n"
                "bad argument #2 to 'setvbuf' (string expected, got number)\n"
                "bad argument #2 to 'setvbuf' (string expected, got no value)\n",
                "", 0);
}

static const char *case_a_nested_pcall_does_not_fire_an_outer_handler(void) {
  /* pcall is nilu_pcall with no handler, which saves and clears an enclosing one as
  lua_pcall's old_errfunc does -- so an inner failure pcall catches
  must not reach xpcall's handler. Measured on lua5.5: the first line has no H: and the
  second does.
  Without this, nothing asserted the clearing: a mutation removing it passed. */
  char *args[] = {"-e",
                  "global * print(xpcall(function()"
                  " print(pcall(function() error(\"inner\") end))"
                  " error(\"outer\") end, function(e) return \"H:\" .. e end))",
                  NULL};
  return expect(args, NULL, 0,
                "false\t(command line):1: inner\n"
                "false\tH:(command line):1: outer\n",
                "", 0);
}

static const char *case_a_handler_sees_the_frames_that_failed(void) {
  /* The handler runs at the frame that failed, before anything unwinds, and what it can find out is the chain. A program cannot call nilu_where,
  so what it can see from in here is that the handler ran at all and that the value it
  answered replaced the one the failure carried; the chain itself is held by c-test's
  `a handler runs before the unwinding`. */
  char *args[] = {"-e",
                  "global * local function c() error(\"deep\") end"
                  " local function b() c() end"
                  " print(xpcall(function() b() end, function(e) return \"H:\" .. e end))"
                  " print(select(2, pcall(function() error(\"after\") end)))",
                  NULL};
  return expect(args, NULL, 0,
                "false\tH:(command line):1: deep\n"
                "(command line):1: after\n",
                "", 0);
}

static const char *case_a_path_cannot_hold_a_zero_byte(void) {
  /* Ours, because lua5.5 has none: it does not refuse, it opens the path up to the zero byte
  -- measured. A name truncates and a path refuses. string.char(0) is one way a program can
  build one; "\0" is another with Lua's digit escapes (print(#"\0") is 1,
  measured). The case keeps string.char so that what it asserts is the path's refusal
  alone, and not the lexer's reading of an escape as well. */
  char *args[] = {"-e",
                  "global * local z = \"/dev/null\" .. string.char(0) .. \"x\""
                  " print(select(2, pcall(io.open, z)))"
                  " print(select(2, pcall(io.lines, z)))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #1 to 'open' (a path cannot hold a zero byte)\n"
                "bad argument #1 to 'lines' (a path cannot hold a zero byte)\n",
                "", 0);
}

static const char *case_io_open_says_which_argument_was_wrong(void) {
  /* Three refusals that carried nothing. For the number, lua5.5 coerces and looks
  for the file named `1`, and nothing here turns a
  number into a string. The others are lua5.5's own words, measured. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(io.open, {})))"
                  " print(select(2, pcall(io.open)))"
                  " print(select(2, pcall(io.open, 1)))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #1 to 'open' (string expected, got table)\n"
                "bad argument #1 to 'open' (string expected, got no value)\n"
                "bad argument #1 to 'open' (string expected, got number)\n",
                "", 0);
}

static const char *case_a_mode_that_is_not_a_string_is_refused(void) {
  /* What this holds: a mode that is not a string is refused and never ignored for the
  default "r" -- io.open(path, {}) must not open the file for reading. lua5.5 refuses. An absent or nil mode means "r", which lua5.5 also does. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(io.open, \"/dev/null\", {})))"
                  " print(io.type(io.open(\"/dev/null\")), io.type(io.open(\"/dev/null\", nil)))"
                  " print(select(2, pcall(io.open, \"/dev/null\", \"qq\")))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #2 to 'open' (string expected, got table)\n"
                "file\tfile\n"
                "bad argument #2 to 'open' (invalid mode)\n",
                "", 0);
}

static const char *case_io_type_answers_which_state_a_file_is_in(void) {
  /* io_type: file, closed file, or fail. luaL_testudata is as_file -- both compare the
  userdata's metatable with the one this code holds. */
  return with_temp_file(
      "global * local p = \"%s\""
      " print(io.type(io.stdin), io.type(io.stdout), io.type(io.stderr))"
      " local f = io.open(p, \"w\") print(io.type(f)) f.close(f) print(io.type(f))"
      " print(io.type(nil), io.type(\"\"), io.type(0 / 0), io.type(print))",
      "file\tfile\tfile\nfile\nclosed file\nnil\tnil\tnil\tnil\n", "", 0, "");
}

static const char *case_io_type_tells_nothing_passed_from_nil(void) {
  /* luaL_checkany tests LUA_TNONE, so io.type(nil) is nil and io.type() is a refusal --
  measured on both halves. nilu_type answers NILU_TNONE for an argument nobody passed, so the distinction is borrowed and not approximated. */
  char *args[] = {"-e",
                  "global * print(io.type(nil)) print(select(2, pcall(io.type)))",
                  NULL};
  return expect(args, NULL, 0,
                "nil\nbad argument #1 to 'type' (value expected)\n", "", 0);
}

static const char *case_io_tmpfile_makes_a_file(void) {
  /* The same metatable io.open hands out, so all seven calls work on it; write, seek back,
  read, close. tmpfile(3) gives no path, so there is nothing to look at from outside --
  what can be seen is that it behaves as a file. */
  char *args[] = {"-e",
                  "global * local f = io.tmpfile()"
                  " print(io.type(f), getmetatable(f) == getmetatable(io.stdout))"
                  " print(string.sub(tostring(f), 1, 6))"
                  " f.write(f, \"hi\\n\") f.seek(f, \"set\") print(f.read(f, \"l\"))"
                  " print(f.close(f), io.type(f))",
                  NULL};
  return expect(args, NULL, 0,
                "file\ttrue\nfile (\nhi\ntrue\tclosed file\n", "", 0);
}

static const char *case_two_temporary_files_differ(void) {
  /* Which is what "makes one" means: a second call is a second file, not the same one. */
  char *args[] = {"-e",
                  "global * local a, b = io.tmpfile(), io.tmpfile()"
                  " print(a ~= b, io.type(a), io.type(b))",
                  NULL};
  return expect(args, NULL, 0, "true\tfile\tfile\n", "", 0);
}

static const char *case_lines_takes_formats(void) {
  /* aux_lines passes the formats to every turn, and the numbers are spelled this project's
  way, so `1 2` reads back as 1.0 and 2.0. A count format is bytes and not
  lines: 2 on "1 2\n3 4\n" is "1 ", "2\n", "3 ", "4\n" -- measured on lua5.5. */
  return with_temp_file(
      "global * local p = \"%s\""
      " local f = io.open(p, \"w\") f.write(f, \"1 2\\n3 4\\n\") f.close(f)"
      " local g = io.open(p) for a, b in g.lines(g, \"n\", \"n\") do print(a, b) end"
      " g.close(g)"
      " local t = {} local i = 0"
      " for s in io.lines(p, 2) do i = i + 1 t[i] = \"<\" .. s .. \">\" end"
      " print(table.concat(t, \",\"))",
      "1\t2\n3\t4\n<1 >,<2\n>,<3 >,<4\n>\n", "", 0, "1 2\n3 4\n");
}

static const char *case_io_lines_first_argument_is_a_name(void) {
  /* io_lines pushes nil and then tests lua_isnil(L, 1), so a string there is a file name and
  the formats start at the second argument -- io.lines(nil, "n") is how the current input
  gets one. Both halves measured on lua5.5. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(io.lines, \"n\")))"
                  " for a, b in io.lines(nil, \"n\", \"n\") do print(a, b) end",
                  NULL};
  const char *in = "1 2\n";
  /* No position in front: pcall is level 1 and has no line, which is what luaL_where
  answers and what lua5.5 prints for the same call. */
  return expect(args, in, strlen(in),
                "cannot open file 'n' (No such file or directory)\n"
                "1\t2\n",
                "", 0);
}

static const char *case_too_many_formats_is_refused_at_a_constant_number(void) {
  /* luaL_argcheck(L, n <= MAXARGLINE, MAXARGLINE + 2, "too many arguments"): the index is
  252 whatever was passed. Measured on lua5.5 with 251 formats and with 300, both #252. 250 is allowed, which is the other half of the bound. */
  char *args[] = {"-e",
                  "global * local f = io.stdout local t = {}"
                  " for i = 1, 250 do t[i] = \"l\" end"
                  " print(type(select(2, pcall(f.lines, f, table.unpack(t)))))"
                  " t[251] = \"l\""
                  " print(select(2, pcall(f.lines, f, table.unpack(t))))"
                  " for i = 252, 300 do t[i] = \"l\" end"
                  " print(select(2, pcall(f.lines, f, table.unpack(t))))",
                  NULL};
  return expect(args, NULL, 0,
                "function\n"
                "bad argument #252 to 'lines' (too many arguments)\n"
                "bad argument #252 to 'lines' (too many arguments)\n",
                "", 0);
}

static const char *case_a_file_closed_under_the_iterator_says_so(void) {
  /* io_readline checks isclosed itself and has its own sentence, where tofile says
  `attempt to use a closed file` -- one is "you handed me a closed file" and this one is
  "the file I was holding has been closed since". Measured. */
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"a\\n\") f.close(f)"
      " local g = io.open(\"%s\") local it = g.lines(g) g.close(g)"
      " print(select(2, pcall(it)))",
      "file is already closed\n", "", 0, "a\n");
}

static const char *case_io_close_with_no_argument_means_the_current_output(void) {
  /* io_close is lua_getfield(LUA_REGISTRYINDEX, IO_OUTPUT) then f_close, read in liolib.c. On a fresh state that is io.stdout, which will not close -- so the
  two values are the proof that it reached the pair and not argument 1. What this caught:
  `bad argument #1 to 'close' (FILE* expected, got no value)`. */
  char *args[] = {"-e", "global * print(io.close())", NULL};
  return expect(args, NULL, 0, "nil\tcannot close standard file\n", "", 0);
}

static const char *case_io_lines_with_no_argument_walks_the_current_input(void) {
  /* io_lines's toclose = 0 branch, read in liolib.c: no name walks the current input and
  does NOT close it. The third line is what toclose = 0 means -- a closed input would
  raise `default input file is closed` there instead of answering nil at the end.
  stdin cannot show this, because a standard file will not close either way. */
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"a\\nb\\n\") f.close(f)"
      " io.input(\"%s\") for l in io.lines() do print(l) end"
      " print(select(2, pcall(io.read, \"l\"))) io.input(io.stdin)",
      "a\nb\nnil\n", "", 0, "a\nb\n");
}

static const char *case_io_lines_wants_a_name_and_not_a_number(void) {
  /* luaL_checkstring coerces, so lua5.5 tries to open the file named `1`; nothing in Nilu
  turns a number into a string, so this says the type. */
  char *args[] = {"-e", "global * print(select(2, pcall(io.lines, 1)))", NULL};
  return expect(args, NULL, 0, "bad argument #1 to 'lines' (string expected, got number)\n", "", 0);
}

static const char *case_a_program_writes_and_reads_a_file(void) {
  /* f.read(f, …) is the shape: Lua's f:read(…) with the : peeled off. */
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"one\\n\") f.write(f, \"two\\n\")"
      " f.close(f) local g = io.open(\"%s\") print(g.read(g, \"l\"), g.read(g, \"l\"),"
      " g.read(g, \"l\")) g.close(g)",
      "one\ttwo\tnil\n", "", 0, "one\ntwo\n");
}

static const char *case_a_file_a_program_forgot_still_holds_what_it_wrote(void) {
  /* What this asserts and what it does not: the bytes are there.
  It does NOT isolate the command closing the file -- measured by removing
  close_open_files() and watching this case still pass, because the C runtime flushes a
  FILE* at exit(). Closing is not observable from outside the process, so no case here
  can assert it. */
  return with_temp_file("global * local f = io.open(\"%s\", \"w\") f.write(f, \"forgotten\")%.0s",
                        "", "", 0, "forgotten");
}

static const char *case_io_lines_walks_a_file_to_its_end(void) {
  /* The turns, which is what this can see. That io.lines closes at the end and f.lines does
  not is measured in lua5.5 and implemented, and no case here asserts it -- measured by
  inverting the owner flag and watching this case still pass. */
  return with_temp_file(
      "global * local f = io.open(\"%s\", \"w\") f.write(f, \"a\\nb\\n\") f.close(f)"
      " local n = 0 for _ in io.lines(\"%s\") do n = n + 1 end print(n)",
      "2\n", "", 0, "a\nb\n");
}

static const char *case_io_open_answers_nil_and_a_reason(void) {
  /* Three values, and no raise -- where io.lines raises. */
  char *args[] = {"-e",
                  "global * local f, why, code = io.open(\"/no/such/file\", \"r\")"
                  " print(f, why ~= nil, code ~= nil)",
                  NULL};
  return expect(args, NULL, 0, "nil\ttrue\ttrue\n", "", 0);
}

static const char *case_an_invalid_mode_is_refused(void) {
  /* A raise and not an answer, where the path not opening is the other kind. lua5.5's own words, measured. */
  char *args[] = {"-e", "global * io.open(\"/dev/null\", \"qq\")", NULL};
  return expect_err_ends(args, "", "(command line):1: bad argument #2 to 'open' (invalid mode)\n", 1);
}

static const char *case_io_lines_raises_for_a_file_it_cannot_open(void) {
  char *args[] = {"-e", "global * for _ in io.lines(\"/no/such/file\") do end", NULL};
  return expect_err_ends(args, "",
                         "(command line):1: cannot open file '/no/such/file'"
                         " (No such file or directory)\n",
                         1);
}

static const char *case_a_closed_file_refuses(void) {
  char *args[] = {"-e",
                  "global * local f = io.open(\"/dev/null\", \"r\") f.close(f) return f.read(f, \"l\")",
                  NULL};
  return expect_err_ends(args, "", "(command line):1: attempt to use a closed file\n", 1);
}

static const char *case_a_value_that_is_not_a_file_is_refused_by_name(void) {
  /* The words are the command's own: a closed file says why, so a value that is
  not a file saying nothing in the same five functions would be an inconsistency.
  The name is the one the call site wrote, which is 'close' here --
  and lua5.5 says 'close' too, measured. */
  char *args[] = {"-e", "global * io.close({})", NULL};
  return expect_err_ends(args, "",
                         "(command line):1: bad argument #1 to 'close'"
                         " (FILE* expected, got table)\n",
                         1);
}

static const char *case_a_file_is_spelled_with_its_state(void) {
  char *args[] = {"-e",
                  "global * local f = io.open(\"/dev/null\", \"r\")"
                  " print(type(f), string.sub(tostring(f), 1, 6))"
                  " f.close(f) print(tostring(f))",
                  NULL};
  return expect(args, NULL, 0, "userdata\tfile (\nfile (closed)\n", "", 0);
}

static const char *case_io_read_reads_a_line_and_then_the_next(void) {
  /* No format is "l": the line without its newline; past the end it is nil. */
  char *args[] = {"-e", "print(io.read(), io.read(), io.read())", NULL};
  const char *in = "ab\ncd\n";
  return expect(args, in, strlen(in), "ab\tcd\tnil\n", "", 0);
}

static const char *case_io_read_s_L_keeps_the_newline_and_a_takes_the_rest(void) {
  char *args[] = {"-e", "io.write(io.read(\"L\")) io.write(\"|\", io.read(\"a\"), \"|\")", NULL};
  const char *in = "ab\ncd";
  return expect(args, in, strlen(in), "ab\n|cd|", "", 0);
}

static const char *case_io_read_s_a_never_fails(void) {
  /* read_all at the end of the stream is "", not nil -- and "l" after it is nil. */
  char *args[] = {"-e", "print(io.read(\"a\") == \"\", io.read(\"l\"))", NULL};
  return expect(args, "", 0, "true\tnil\n", "", 0);
}

static const char *case_io_read_s_count_reads_that_many_and_0_asks_whether_anything_is_left(void) {
  /* lua5.5 answers exactly this for io.read(3), io.read(0), io.read(10), io.read(0) on
  abcdef: three bytes, "" while anything is left, the rest, nil at the end. */
  char *args[] = {"-e", "print(io.read(3), io.read(0), io.read(10), io.read(0))", NULL};
  const char *in = "abcdef";
  return expect(args, in, strlen(in), "abc\t\tdef\tnil\n", "", 0);
}

static const char *case_io_read_s_n_reads_a_numeral_and_leaves_the_rest(void) {
  /* read_number: leading space skipped, the first byte that is not a numeral unread.
   * A numeral with an exponent is a float, so it prints 125.0, as lua5.5's
   *. */
  char *args[] = {"-e", "print(io.read(\"n\"), io.read(\"a\"))", NULL};
  const char *in = " 12.5e1 rest";
  return expect(args, in, strlen(in), "125.0\t rest\n", "", 0);
}

static const char *case_io_read_s_n_is_nil_for_text_that_is_not_a_numeral(void) {
  char *args[] = {"-e", "print(io.read(\"n\"))", NULL};
  const char *in = "abc";
  return expect(args, in, strlen(in), "nil\n", "", 0);
}

static const char *case_io_read_stops_at_the_first_format_that_fails(void) {
  /* g_read: the failed format is nil and the ones after it are not tried. Two lines
  for three "l"s is ab, cd, nil -- measured on lua5.5. A leading * is ignored. */
  char *args[] = {"-e", "print(io.read(\"*l\", \"l\", \"l\"))", NULL};
  const char *in = "ab\ncd\n";
  return expect(args, in, strlen(in), "ab\tcd\tnil\n", "", 0);
}

static const char *case_io_read_refuses_a_format_it_does_not_know(void) {
  /* An unknown input format is refused. */
  char *args[] = {"-e", "io.read(\"x\")", NULL};
  const char *in = "x";
  return expect(args, in, strlen(in), "",
                "nilu: (command line):1: bad argument #1 to 'read' (invalid format)\n", 1);
}

/* Running out of memory carries `not enough memory`, lua5.5 5.5.1's words
  measured under the same limit. One allocation in the library (string.rep) and one in the
  VM (concatenation), so both paths are held. */
static const char *case_running_out_of_memory_says_so(void) {
  char *args[] = {"-e",
                  "print(pcall(string.rep, 'x', 2^31))"
                  " print(pcall(function() local s = 'x' for i = 1, 40 do s = s .. s end return #s end))"
                  " print(xpcall(function() local s = 'x' for i = 1, 40 do s = s .. s end end,"
                  " function(m) return 'H:' .. tostring(m) end))",
                  NULL};
  const char *broke;
  /* The third is a handler, which Lua does not call for LUA_ERRMEM and nor does this, so no `H:` is in the answer. */
  child_memory_limit = 1500L * 1000L * 1000L;
  broke = expect(args, NULL, 0, "false\tnot enough memory\nfalse\tnot enough memory\nfalse\tnot enough memory\n", "", 0);
  child_memory_limit = 0;
  return broke;
}

/* A `tostring` that recursed through print: the depth failure's "stack overflow" reaches the
  program, because print passes it on. The global is
  replaced so that the depth is reached in print's own nilu_call; a __tostring reaches it in
  the library's instead, which a first version of this case did and so held nothing. The
  outer write is io.write because print would recurse too. */
static const char *case_print_passes_on_a_recursion_in_tostring(void) {
  char *args[] = {"-e", "tostring = function(v) print(v) end io.write(select(2, pcall(print, 1)), '\\n')", NULL};
  return expect(args, NULL, 0, "(command line):1: stack overflow\n", "", 0);
}

/* A failure inside a sort comparator: the handler runs where it happened, because nilu_call
  passes a failure on and only a protected call stops it. What this caught: a
  traceback that began at sort's own [C] frame, with the comparator's frames gone. */
static const char *case_a_failure_in_a_comparator_is_traced_from_where_it_happened(void) {
  char *args[] = {"-e",
                  "local function c() local x = nil + 1 end"
                  " local function b() table.sort({3, 2, 1}, function(x, y) c() return x < y end) end"
                  " b()",
                  NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: attempt to perform arithmetic on a nil value\n"
                "stack traceback:\n"
                "\t(command line):1: in upvalue 'c'\n"
                "\t(command line):1: in function <(command line):1>\n"
                "\t[C]: in field 'sort'\n"
                "\t(command line):1: in local 'b'\n"
                "\t(command line):1: in main chunk\n",
                1);
}

/* A native's frame is `[C]: in` and the name it was called by. What this caught: a nilu_where that
  answered NULL at the native's frame, so the walk stopped and error() three deep printed none. */
static const char *case_a_native_failure_prints_a_traceback(void) {
  char *args[] = {"-e", "local function a() error('boom') end local function b() a() end b()", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: boom\n"
                "stack traceback:\n"
                "\t[C]: in global 'error'\n"
                "\t(command line):1: in upvalue 'a'\n"
                "\t(command line):1: in local 'b'\n"
                "\t(command line):1: in main chunk\n",
                1);
}

/* A replaced `tostring` that answers no string: Lua 5.3's luaB_print sentence, the version
  that read the global as this command's print does. */
static const char *case_print_refuses_a_tostring_that_answers_no_string(void) {
  char *args[] = {"-e", "tostring = function() return {} end print(1)", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1: 'tostring' must return a string to 'print'\n", 1);
}

/* luaL_argerror's method branch: through `:` the receiver is not
  counted, a bad receiver is `bad self`, and the name is the one the caller wrote -- each
  lua5.5 5.5.1's answer, measured. */
static const char *case_a_refusal_through_a_method_call_does_not_count_self(void) {
  char *args[] = {"-e",
                  "local f = io.stdout"
                  " print(select(2, pcall(function() return f:read(\"q\") end)))"
                  " print(select(2, pcall(function() return f:write({}) end)))"
                  " local t = {w = io.stdout.write}"
                  " print(select(2, pcall(function() return t:w(\"x\") end)))"
                  " print(select(2, pcall(function() return f:seek(\"zz\") end)))"
                  " local l = {l = io.lines}"
                  " print(select(2, pcall(function() return l:l() end)))",
                  NULL};
  /* seek and lines built their own words once, counting self and naming the registered
  function -- which is what this caught. */
  return expect(args, NULL, 0,
                "(command line):1: bad argument #1 to 'read' (invalid format)\n"
                "(command line):1: bad argument #1 to 'write' (string expected, got table)\n"
                "(command line):1: calling 'w' on bad self (FILE* expected, got table)\n"
                "(command line):1: bad argument #1 to 'seek' (invalid option 'zz')\n"
                "(command line):1: calling 'l' on bad self (string expected, got table)\n",
                "", 0);
}

static const char *case_a_refusal_in_read_and_write_names_the_argument(void) {
  /* Every shape measured against lua5.5, which says 'io.read' or '?' where its fallback
  searches package.loaded. Under pcall there is no caller's code, so nilu_calledas is NULL
  and the command falls back to the registered name, 'read'. The argument number is the
  argument's own position. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(io.read, \"*q\")))"
                  " print(select(2, pcall(io.read, {})))"
                  " local f = io.stdout"
                  " print(select(2, pcall(f.write, f, true)))"
                  " print(select(2, pcall(f.read, f, \"q\")))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #1 to 'read' (invalid format)\n"
                "bad argument #1 to 'read' (string expected, got table)\n"
                "bad argument #2 to 'write' (string expected, got boolean)\n"
                "bad argument #2 to 'read' (invalid format)\n",
                "", 0);
}

static const char *case_io_read_is_nil_when_stdin_was_the_program(void) {
  /* `nilu -` has read the whole of stdin as the source before a line of it runs, so
  there is nothing left to read. Lua behaves the same way for the same reason. */
  char *args[] = {"-", NULL};
  const char *in = "print(io.read())";
  return expect(args, in, strlen(in), "nil\n", "", 0);
}

static const char *case_os_clock_and_os_time_are_numbers_and_the_clock_does_not_run_backwards(void) {
  /* Their values depend on when they run, so no value is asserted -- only the type, and
  that two readings are ordered. */
  char *args[] = {"-e", "local a = os.clock() local b = os.clock() print(type(a), b >= a, type(os.time()))", NULL};
  return expect(args, NULL, 0, "number\ttrue\tnumber\n", "", 0);
}

static const char *case_os_time_reads_a_date_table(void) {
  /* The round trip, and it is the one shape that does not depend on the machine's zone:
  os.date("*t") and os.time both read the same one, so it closes wherever it runs.
  The ! half is NOT asserted. A first cut asserted that os.time(os.date("!*t", t)) ~= t,
  which is true where the zone has an offset and false where it is UTC -- so it is a
  statement about the machine and not about this program. CI's zone is UTC and this
  machine's is not, which is what found it. */
  char *args[] = {"-e",
                  "global * print(os.time(os.date(\"*t\", 86400)) == 86400)"
                  " print(os.time(os.date(\"*t\", 0)) == 0)",
                  NULL};
  return expect(args, NULL, 0, "true\ntrue\n", "", 0);
}

static const char *case_os_time_normalises_the_table_it_was_given(void) {
  /* mktime normalises and setallfields writes every field back, including three the caller
  did not pass -- so os.time is not a pure function of its argument, and that is what makes
  the round trip above close. Measured on lua5.5.
  hour defaults to 12 and min and sec to 0, which is Lua's choice of defaults. */
  char *args[] = {"-e",
                  "global * local t = {} t.year = 2026 t.month = 13 t.day = 1"
                  " local answered = os.time(t)"
                  " print(t.year, t.month, t.day, t.wday, t.yday, t.isdst, answered ~= nil)"
                  " local u = {} u.year = 2026 u.month = 10 u.day = 13"
                  " os.time(u) print(u.hour, u.min, u.sec)",
                  NULL};
  return expect(args, NULL, 0,
                "2027\t1\t1\t6\t1\tfalse\ttrue\n12\t0\t0\n", "", 0);
}

static const char *case_os_time_says_which_field_was_wrong(void) {
  /* getfield's three sentences, each lua5.5's own. year, month and day are required -- a
  default below zero is Lua's signal for that -- and hour is not, which is why the second
  line names day and not hour. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(os.time, {})))"
                  " local a = {} a.year = 2026 a.month = 10"
                  " print(select(2, pcall(os.time, a)))"
                  " local b = {} b.year = 2026 b.month = 10 b.day = 1.5"
                  " print(select(2, pcall(os.time, b)))"
                  " local c = {} c.year = 2026 c.month = 10 c.day = 1 c.hour = 1e10"
                  " print(select(2, pcall(os.time, c)))"
                  " print(select(2, pcall(os.time, 1)))",
                  NULL};
  return expect(args, NULL, 0,
                "field 'year' missing in date table\n"
                "field 'day' missing in date table\n"
                "field 'day' is not an integer\n"
                "field 'hour' is out-of-bound\n"
                "bad argument #1 to 'time' (table expected, got number)\n",
                "", 0);
}

static const char *case_os_date_writes_a_time_in_utc(void) {
  /* The ! and a fixed time, so the answer is the same wherever this runs. %F and %T are in Lua's C99 list
  and answer the same as the long spelling. */
  char *args[] = {"-e",
                  "global * print(os.date(\"!%Y-%m-%d %H:%M:%S\", 0))"
                  " print(os.date(\"!%F %T\", 86400 * 366))"
                  " print(os.date(\"!\") == \"\", os.date(\"%%\"))"
                  " print(os.date() == os.date(\"%c\"))",
                  NULL};
  return expect(args, NULL, 0,
                "1970-01-01 00:00:00\n1971-01-02 00:00:00\ntrue\t%\ntrue\n", "", 0);
}

static const char *case_os_date_builds_a_table(void) {
  /* setallfields: nine fields, with +1 on the month and the two day numbers and +1900 on the
  year. isdst is false here because gmtime says 0. */
  char *args[] = {"-e",
                  "global * local d = os.date(\"!*t\", 0)"
                  " print(d.year, d.month, d.day, d.hour, d.min, d.sec, d.wday, d.yday, d.isdst)"
                  " local e = os.date(\"!*t\", 86400 * 366)"
                  " print(e.year, e.month, e.day, e.wday, e.yday)",
                  NULL};
  return expect(args, NULL, 0,
                "1970\t1\t1\t0\t0\t0\t5\t1\tfalse\n"
                "1971\t1\t2\t7\t2\n",
                "", 0);
}

static const char *case_os_date_refuses_a_specifier_it_does_not_know(void) {
  /* checkoption against LUA_STRFTIMEOPTIONS: a whitelist, because an unknown specifier is
  undefined behaviour in strftime and the cost is the host's process. The whole format is
  checked before any of it is used, which `ok%v` writing nothing is the proof of. 2^60 reaches gmtime and its answer is the refusal, as in lua5.5. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(os.date, \"%v\")))"
                  " print(select(2, pcall(os.date, \"ok%v\")))"
                  " print(select(2, pcall(os.date, \"*t\", 2 ^ 60)))"
                  " print(select(2, pcall(os.date, \"*t\", \"x\")))"
                  " print(select(2, pcall(os.date, \"!%Y\", 1.5)))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #1 to 'date' (invalid conversion specifier '%v')\n"
                "bad argument #1 to 'date' (invalid conversion specifier '%v')\n"
                "date result cannot be represented in this installation\n"
                "bad argument #2 to 'date' (number expected, got string)\n"
                "bad argument #2 to 'date' (number has no integer representation)\n",
                "", 0);
}

static const char *case_os_getenv_tells_unset_from_empty(void) {
  /* os_getenv is one line there and pushing a null pointer pushes nil, so "not set" and "set
  to the empty string" are told apart. The variable is one this case
  sets itself, never one of the machine's. lua5.5 looks up the name "1" for os.getenv(1)
  because luaL_checkstring coerces; nothing here does.
  The last line is the zero byte: it ends the name, which is what getenv is given, and
  lua5.5 answers HOME's value for "HOME\0X" -- measured. A first
  cut refused it through not_a_string and said "string expected, got string". */
  char *args[] = {"-e",
                  "global * print(os.getenv(\"NILU_CLI_CASE_SET\"))"
                  " print(os.getenv(\"NILU_CLI_CASE_EMPTY\") == \"\")"
                  " print(os.getenv(\"NILU_CLI_CASE_UNSET\"))"
                  " print(select(2, pcall(os.getenv)))"
                  " print(select(2, pcall(os.getenv, 1)))"
                  " local z = \"NILU_CLI_CASE_SET\" .. string.char(0) .. \"X\""
                  " print(os.getenv(z) == \"here\")",
                  NULL};
  const char *failure;
  /* setenv and not putenv: putenv is not declared under this build's feature macros,
  measured. The child inherits the environment through execv. */
  if (setenv("NILU_CLI_CASE_SET", "here", 1) != 0) return "could not set a variable";
  if (setenv("NILU_CLI_CASE_EMPTY", "", 1) != 0) return "could not set a variable";
  if (unsetenv("NILU_CLI_CASE_UNSET") != 0) return "could not unset a variable";
  failure = expect(args, NULL, 0,
                   "here\ntrue\nnil\n"
                   "bad argument #1 to 'getenv' (string expected, got no value)\n"
                   "bad argument #1 to 'getenv' (string expected, got number)\n"
                   "true\n",
                   "", 0);
  return failure;
}

static const char *case_os_exit_sets_the_status_and_flushes_what_was_written(void) {
  char *args[] = {"-e", "io.write(\"before\") os.exit(3)", NULL};
  return expect(args, NULL, 0, "before", "", 3);
}

static const char *case_os_exit_reads_a_boolean_as_success_or_failure(void) {
  char *args_true[] = {"-e", "os.exit(true)", NULL};
  char *args_false[] = {"-e", "os.exit(false)", NULL};
  char *args_none[] = {"-e", "os.exit()", NULL};
  const char *failure = expect(args_true, NULL, 0, "", "", 0);
  if (failure != NULL) return failure;
  failure = expect(args_false, NULL, 0, "", "", 1);
  if (failure != NULL) return failure;
  return expect(args_none, NULL, 0, "", "", 0);
}

static const char *case_os_exit_refuses_a_status_that_is_not_a_whole_number(void) {
  /* luaL_optinteger: lua5.5 says "number has no integer representation", and so does this. lua5.5 names 'os.exit' because its
  fallback searches package.loaded; this names 'exit'. */
  char *args[] = {"-e", "os.exit(1.5)", NULL};
  return expect(args, NULL, 0, "",
                "nilu: (command line):1: bad argument #1 to 'exit'"
                " (number has no integer representation)\n",
                1);
}

static const char *case_a_huge_number_does_not_crash_the_command(void) {
  /* Three places cast a number straight from a program: f.seek's offset, f.setvbuf's size
  and os.exit's status. (long)1e30 and (int)1e30 are undefined in C, and all three
  crashed -- measured. The range
  is now tested before the cast, and the bound is 2^53 rather than a C type's: past that
  a double is not an integer this language can state. */
  char *args[] = {"-e",
                  "global * local f = io.stdout"
                  " print(select(2, pcall(f.seek, f, \"set\", 1e30)))"
                  " print(select(2, pcall(f.setvbuf, f, \"full\", 1e30)))"
                  " print(select(2, pcall(os.exit, 1e30)))"
                  " print(select(2, pcall(io.read, 1.5)))",
                  NULL};
  return expect(args, NULL, 0,
                "bad argument #3 to 'seek' (number has no integer representation)\n"
                "bad argument #3 to 'setvbuf' (number has no integer representation)\n"
                "bad argument #1 to 'exit' (number has no integer representation)\n"
                "bad argument #1 to 'read' (number has no integer representation)\n",
                "", 0);
}

static const char *case_a_count_that_cannot_be_read_says_which_way(void) {
  /* lua5.5's two words for the two ways a count is impossible, measured: io.read(-1) is
  `resulting string too large` (luaL_prepbuffsize sees (size_t)-1) and io.read(1e12) is
  `not enough memory`. */
  char *args[] = {"-e",
                  "global * print(select(2, pcall(io.read, -1)))"
                  " print(select(2, pcall(io.read, 1e12)))",
                  NULL};
  return expect(args, NULL, 0,
                "resulting string too large\n"
                "not enough memory\n",
                "", 0);
}

static const char *case_os_exit_closes_the_state_when_asked(void) {
  /* The close cannot be observed from outside the process; what can is that asking for
  it still exits with the status asked for. */
  char *args[] = {"-e", "os.exit(0, true)", NULL};
  return expect(args, NULL, 0, "", "", 0);
}

/* ── math.random ───────────────────────────────────────────────────── */

static const char *case_math_random_is_seeded_from_outside_at_startup(void) {
  /* A fresh state is deterministic, so the only observation a seed from the
  clock allows is that two runs differ. A check that two outputs are unequal is weak, and
  this comment says so; what makes it meaningful is the Zig test asserting the fresh
  state's exact sequence, which this program must therefore have moved off. */
  char *args[] = {"-e", "print(math.random(0), math.random(0), math.random(0))", NULL};
  Ran first, second;
  const char *broke = run_nilu(args, NULL, 0, &first);
  const char *failure = NULL;
  if (broke != NULL) return broke;
  broke = run_nilu(args, NULL, 0, &second);
  if (broke != NULL) {
    free(first.out);
    free(first.err);
    return broke;
  }
  if (first.code != 0 || second.code != 0) {
    failure = "a run failed";
  } else if (strcmp(first.out, "2223984158897798\t2.1151541015623e+15\t623982190897854\n") == 0) {
    /* The fresh state's first three draws, as print spells them -- measured, because a first
  draft of this string was written from memory and never matched. */
    failure = "a run printed the fresh state's sequence, so nothing seeded it";
  } else if (strcmp(first.out, second.out) == 0) {
    snprintf(complaint, sizeof complaint, "two runs printed the same %s", shown(first.out));
    failure = complaint;
  }
  free(first.out);
  free(first.err);
  free(second.out);
  free(second.err);
  return failure;
}

/* ── what a failure carries ────────────────────────────────────────── */

static const char *case_a_string_error_value_is_printed_as_it_is(void) {
  char *args[] = {"-e", "error(\"config missing\")", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1: config missing\n", 1);
}

static const char *case_an_error_object_that_is_not_a_string_is_named_by_its_kind(void) {
  /* lua.c's msghandler: "(error object is a table value)". */
  char *args[] = {"-e", "local t = {} error(t)", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line): runtime error\nnilu: (error object is a table value)\n", 1);
}

static const char *case_a_userdata_error_object_is_named_by_its_kind(void) {
  /* The command's own file handles are userdata; one thrown is named by its kind, as any
  * value that is not a string is (lua.c would call its __tostring and print `file (0x…)`). */
  char *args[] = {"-e", "error(io.stdout)", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line): runtime error\nnilu: (error object is a userdata value)\n", 1);
}

static const char *case_assert_s_message_is_printed(void) {
  char *args[] = {"-e", "assert(1 == 2, \"one is not two\")", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):1: one is not two\n", 1);
}

static const char *case_pcall_keeps_a_script_running(void) {
  char *args[] = {"-e", "local ok, e = pcall(error, \"caught\") print(ok, e) print(pcall(function() return nil + 1 end))", NULL};
  /* Measured on lua5.5: `false\t(command line):1: caught` then the arithmetic sentence.
  The first differs here because `pcall(error, "caught")` has pcall -- a native -- at
  level 1, so nothing is prefixed; the second is the core's sentence. */
  return expect(args, NULL, 0, "false\tcaught\nfalse\t(command line):1: attempt to perform arithmetic on a nil value\n", "", 0);
}

/* ── the prompt prints through the global print ───────────────────── */

static const char *case_the_prompt_calls_the_global_print(void) {
  /* l_print: lua -i with the same two lines prints P:1 and P:2 (measured). The prompt
  prints through the global, as Lua does. */
  char *args[] = {NULL};
  const char *in = "print = function(...) io.write(\"P:\", select(\"#\", ...), \"\\n\") end\n1 + 2\n\"a\", \"b\"\n";
  char expected[256];
  /* select("#", ...) is a number, and io.write spells a number 1.0. */
  snprintf(expected, sizeof expected, "%s> > P:1\n> P:2\n> \n", banner());
  return expect(args, in, strlen(in), expected, "", 0);
}

static const char *case_a_prompt_whose_print_is_gone_says_so(void) {
  /* l_print's sentence, with the status word where Lua puts its message. */
  char *args[] = {NULL};
  const char *in = "print = nil\n1 + 2\n";
  char expected[256];
  snprintf(expected, sizeof expected, "%s> > > \n", banner());
  return expect(args, in, strlen(in), expected, "error calling 'print' (type error)\n", 0);
}

/* ── a runtime failure has a line ─────────────────────────────────── */

static const char *case_a_runtime_error_says_its_line(void) {
  /* lua -e with two lines reports (command line):2:, measured. */
  char *args[] = {"-e", "local x = 1\nlocal y = nil + x", NULL};
  return expect(args, NULL, 0, "", "nilu: (command line):2: attempt to perform arithmetic on a nil value\n", 1);
}

static const char *case_a_file_s_failure_names_the_file_and_the_line(void) {
  char *args[2];
  char tail[256];
  args[0] = (char *)fails_path;
  args[1] = NULL;
  /* lua5.5 on the same three lines: `f.lua:3: attempt to index a nil value (local 'a')`,
  the parenthetical included.
  Asserted by its tail, because the id is bounded and this path is the checkout's -- see
  expect_err_ends. The three segments the build chose are what make it a path and not a
  file name: `the reference manual` names this case for `@<path>`, and a chunk named by its
  basename alone passes a one-segment tail. Measured: with `chunk_name_for` passing only
  the basename, a one-segment tail saw nothing and three segments fail. */
  snprintf(tail, sizeof tail, "%s:3: attempt to index a nil value (local 'a')\n", last_segments(fails_path, 3));
  return expect_err_ends(args, "", tail, 1);
}

static const char *case_stdin_s_failure_says_stdin_and_the_line(void) {
  char *args[] = {"-", NULL};
  const char *in = "local s = 1\nreturn s + nil\n";
  return expect(args, in, strlen(in), "", "nilu: stdin:2: attempt to perform arithmetic on a nil value\n", 1);
}

/* ⚠ A script can carry a shebang, which is Lua's `skipcomment` in the host.
 * ⚠ Measured against `lua5.5` on the same files, one process per row. */
static const char *case_a_script_can_carry_a_shebang(void) {
  char *args[2];
  args[0] = (char *)shebang_path;
  args[1] = NULL;
  return expect(args, NULL, 0, "shebang\n", "", 0);
}

static const char *case_a_shebang_does_not_move_the_lines(void) {
  char *args[2];
  char tail[256];
  args[0] = (char *)shebang_fails_path;
  args[1] = NULL;
  /* ⚠ The row that tells blanking from removing: ⚠ the failure is on the file's fourth line
  and says so. ⚠ `lua5.5` on the same file says `:4:` too -- ⚠ remove the
  bytes instead and every number after it is one too small. */
  snprintf(tail, sizeof tail, "%s:4: attempt to index a nil value (local 'a')\n",
           last_segments(shebang_fails_path, 3));
  return expect_err_ends(args, "one\n", tail, 1);
}

static const char *case_a_first_line_of_hash_alone_is_skipped(void) {
  char *args[2];
  args[0] = (char *)hash_path;
  args[1] = NULL;
  /* ⚠ `#` and not `#!`: ⚠ measured, Lua skips on the one byte. */
  return expect(args, NULL, 0, "hash alone\n", "", 0);
}

static const char *case_a_file_that_is_only_a_shebang_runs(void) {
  char *args[2];
  args[0] = (char *)only_shebang_path;
  args[1] = NULL;
  /* ⚠ No trailing newline either, which is the file as `chmod +x` leaves it when someone
  saves one line. ⚠ `lua5.5` exits 0 and prints nothing. */
  return expect(args, NULL, 0, "", "", 0);
}

static const char *case_a_shebang_through_stdin_is_skipped(void) {
  char *args[] = {"-", NULL};
  const char *in = "#!/usr/bin/env nilu\nprint(\"via stdin\")\n";
  /* ⚠ It is `loadfile`'s behaviour and not the filename path's, measured. */
  return expect(args, in, strlen(in), "via stdin\n", "", 0);
}

static const char *case_e_still_refuses_a_hash(void) {
  char *args[] = {"-e", "#print(1)", NULL};
  /* ⚠ The other half of the decision: ⚠ it is the first line of something loaded as a file
  and not a comment syntax, so ⚠ `-e` is untouched. ⚠ `lua5.5` refuses it too. */
  return expect(args, NULL, 0, "", "nilu: (command line):1:1: unexpected symbol near '#'\n", 1);
}

static const struct {
  const char *name;
  nilu_case_fn run;
} CASES[] = {
    {"-v says the version", case_v_says_the_version},
    {"-e runs the text", case_e_runs_the_text},
    {"-e glued to its text", case_e_glued_to_its_text},
    {"a script's results are discarded", case_a_script_s_results_are_discarded},
    {"print writes a tab between values", case_print_writes_a_tab_between_values},
    {"print asks the metatable", case_print_asks_the_metatable},
    {"a file runs", case_a_file_runs},
    {"a dash runs what is on stdin", case_a_dash_runs_what_is_on_stdin},
    {"the prompt answers an expression", case_the_prompt_answers_an_expression},
    {"the prompt takes a statement", case_the_prompt_takes_a_statement},
    {"the prompt reads a statement that spans lines", case_the_prompt_reads_a_statement_that_spans_lines},
    {"an expression still answers on one line", case_an_expression_still_answers_on_one_line},
    {"a line number survives the join", case_a_line_number_survives_the_join},
    {"the input ending mid-statement reports", case_the_input_ending_mid_statement_reports},
    {"a string left open asks once and then refuses", case_a_string_left_open_asks_once_and_then_refuses},
    {"a name beginning local is not warned about", case_a_name_beginning_local_is_not_warned_about},
    {"the prompt says nothing about the program's name", case_the_prompt_says_nothing_about_the_program_s_name},
    {"-i runs the script and then the prompt", case_i_runs_the_script_and_then_the_prompt},
    {"a syntax error says where", case_a_syntax_error_says_where},
    {"a refused source says what was expected", case_a_refused_source_says_what_was_expected},
    {"a type error names the command line", case_a_type_error_names_the_command_line},
    {"a runtime error is what a refusal becomes", case_a_runtime_error_is_what_a_refusal_becomes},
    {"a library refusal names the argument", case_a_library_refusal_names_the_argument},
    {"a refusal with no argument number says what happened", case_a_refusal_with_no_argument_number_says_what_happened},
    {"a malformed pattern says so", case_a_malformed_pattern_says_so},
    {"five spellings run from the command", case_five_spellings_run_from_the_command},
    {"a recursion too deep says so", case_a_recursion_too_deep_says_so},
    {"a traceback names every frame, innermost first", case_a_traceback_names_every_frame_innermost_first},
    {"one frame prints no traceback", case_one_frame_prints_no_traceback},
    {"a long traceback is elided in the middle", case_a_long_traceback_is_elided_in_the_middle},
    {"a source may not hold a zero byte", case_a_source_may_not_hold_a_zero_byte},
    {"a file that is not there", case_a_file_that_is_not_there},
    {"an unknown option is refused", case_an_unknown_option_is_refused},
    {"-l requires a module into a global", case_l_requires_a_module_into_a_global},
    {"-l without a module fails as a script does", case_l_without_a_module_fails_as_a_script_does},
    {"-W turns warnings on", case_w_turns_warnings_on},
    {"the prompt edits lines on a terminal", case_the_prompt_edits_lines_on_a_terminal},
    {"a script receives its arguments as ... and as arg", case_a_script_receives_its_arguments_as_dots_and_as_arg},
    {"stdin as the script receives arguments too", case_stdin_as_the_script_receives_arguments_too},
    {"-e has arg and nothing in ...", case_e_has_arg_and_nothing_in_dots},
    {"the options before the script are arg's negative indices", case_the_options_before_the_script_are_arg_s_negative_indices},
    {"-e without its text is refused", case_e_without_its_text_is_refused},
    {"io.write writes bytes and nothing between them", case_io_write_writes_bytes_and_nothing_between_them},
    {"io.write refuses what is not a string or a number", case_io_write_refuses_what_is_not_a_string_or_a_number},
    {"io.write answers nothing", case_io_write_answers_nothing},
    {"a failure at the stream says why", case_a_failure_at_the_stream_says_why},
    {"a failed flush says its errno", case_a_failed_flush_says_its_errno},
    {"a lines iterator raises a stream failure", case_a_lines_iterator_raises_a_stream_failure},
    {"io.read reads a line and then the next", case_io_read_reads_a_line_and_then_the_next},
    {"io.read's L keeps the newline and a takes the rest", case_io_read_s_L_keeps_the_newline_and_a_takes_the_rest},
    {"io.read's a never fails", case_io_read_s_a_never_fails},
    {"io.read's count reads that many and 0 asks whether anything is left", case_io_read_s_count_reads_that_many_and_0_asks_whether_anything_is_left},
    {"io.read's n reads a numeral and leaves the rest", case_io_read_s_n_reads_a_numeral_and_leaves_the_rest},
    {"io.read's n is nil for text that is not a numeral", case_io_read_s_n_is_nil_for_text_that_is_not_a_numeral},
    {"io.read stops at the first format that fails", case_io_read_stops_at_the_first_format_that_fails},
    {"io.read refuses a format it does not know", case_io_read_refuses_a_format_it_does_not_know},
    {"a refusal in read and write names the argument", case_a_refusal_in_read_and_write_names_the_argument},
    {"a refusal through a method call does not count self", case_a_refusal_through_a_method_call_does_not_count_self},
    {"print refuses a tostring that answers no string", case_print_refuses_a_tostring_that_answers_no_string},
    {"a native failure prints a traceback", case_a_native_failure_prints_a_traceback},
    {"a failure in a comparator is traced from where it happened", case_a_failure_in_a_comparator_is_traced_from_where_it_happened},
    {"print passes on a recursion in tostring", case_print_passes_on_a_recursion_in_tostring},
    {"running out of memory says so", case_running_out_of_memory_says_so},
    {"io.read is nil when stdin was the program", case_io_read_is_nil_when_stdin_was_the_program},
    {"os.clock and os.time are numbers and the clock does not run backwards", case_os_clock_and_os_time_are_numbers_and_the_clock_does_not_run_backwards},
    {"os.time reads a date table", case_os_time_reads_a_date_table},
    {"os.time normalises the table it was given", case_os_time_normalises_the_table_it_was_given},
    {"os.time says which field was wrong", case_os_time_says_which_field_was_wrong},
    {"os.date writes a time in utc", case_os_date_writes_a_time_in_utc},
    {"os.date builds a table", case_os_date_builds_a_table},
    {"os.date refuses a specifier it does not know", case_os_date_refuses_a_specifier_it_does_not_know},
    {"os.getenv tells unset from empty", case_os_getenv_tells_unset_from_empty},
    {"os.exit sets the status and flushes what was written", case_os_exit_sets_the_status_and_flushes_what_was_written},
    {"os.exit reads a boolean as success or failure", case_os_exit_reads_a_boolean_as_success_or_failure},
    {"os.exit refuses a status that is not a whole number", case_os_exit_refuses_a_status_that_is_not_a_whole_number},
    {"a huge number does not crash the command", case_a_huge_number_does_not_crash_the_command},
    {"a count that cannot be read says which way", case_a_count_that_cannot_be_read_says_which_way},
    {"os.exit closes the state when asked", case_os_exit_closes_the_state_when_asked},
    {"math.random is seeded from outside at startup", case_math_random_is_seeded_from_outside_at_startup},
    {"a string error value is printed as it is", case_a_string_error_value_is_printed_as_it_is},
    {"an error object that is not a string is named by its kind", case_an_error_object_that_is_not_a_string_is_named_by_its_kind},
    {"a userdata error object is named by its kind", case_a_userdata_error_object_is_named_by_its_kind},
    {"assert's message is printed", case_assert_s_message_is_printed},
    {"pcall keeps a script running", case_pcall_keeps_a_script_running},
    {"the prompt calls the global print", case_the_prompt_calls_the_global_print},
    {"a prompt whose print is gone says so", case_a_prompt_whose_print_is_gone_says_so},
    {"a runtime error says its line", case_a_runtime_error_says_its_line},
    {"a file's failure names the file and the line", case_a_file_s_failure_names_the_file_and_the_line},
    {"stdin's failure says stdin and the line", case_stdin_s_failure_says_stdin_and_the_line},
    {"the three standard files are values", case_the_three_standard_files_are_values},
    {"a standard file will not close", case_a_standard_file_will_not_close},
    {"io.write follows the current output", case_io_write_follows_the_current_output},
    {"io.read follows the current input", case_io_read_follows_the_current_input},
    {"a file seeks", case_a_file_seeks},
    {"flush and setvbuf answer true", case_flush_and_setvbuf_answer_true},
    {"a bad option names the call", case_a_bad_option_names_the_call},
    {"a closed default is said and not fallen back from", case_a_closed_default_is_said_and_not_fallen_back_from},
    {"an option that is not a string says so", case_an_option_that_is_not_a_string_says_so},
    {"a nested pcall does not fire an outer handler", case_a_nested_pcall_does_not_fire_an_outer_handler},
    {"a handler sees the frames that failed", case_a_handler_sees_the_frames_that_failed},
    {"a path cannot hold a zero byte", case_a_path_cannot_hold_a_zero_byte},
    {"io.open says which argument was wrong", case_io_open_says_which_argument_was_wrong},
    {"a mode that is not a string is refused", case_a_mode_that_is_not_a_string_is_refused},
    {"io.type answers which state a file is in", case_io_type_answers_which_state_a_file_is_in},
    {"io.type tells nothing passed from nil", case_io_type_tells_nothing_passed_from_nil},
    {"io.tmpfile makes a file", case_io_tmpfile_makes_a_file},
    {"two temporary files differ", case_two_temporary_files_differ},
    {"lines takes formats", case_lines_takes_formats},
    {"io.lines first argument is a name", case_io_lines_first_argument_is_a_name},
    {"too many formats is refused at a constant number", case_too_many_formats_is_refused_at_a_constant_number},
    {"a file closed under the iterator says so", case_a_file_closed_under_the_iterator_says_so},
    {"io.close with no argument means the current output", case_io_close_with_no_argument_means_the_current_output},
    {"io.lines with no argument walks the current input", case_io_lines_with_no_argument_walks_the_current_input},
    {"io.lines wants a name and not a number", case_io_lines_wants_a_name_and_not_a_number},
    {"a program writes and reads a file", case_a_program_writes_and_reads_a_file},
    {"a file a program forgot still holds what it wrote", case_a_file_a_program_forgot_still_holds_what_it_wrote},
    {"io.lines walks a file to its end", case_io_lines_walks_a_file_to_its_end},
    {"io.open answers nil and a reason", case_io_open_answers_nil_and_a_reason},
    {"an invalid mode is refused", case_an_invalid_mode_is_refused},
    {"io.lines raises for a file it cannot open", case_io_lines_raises_for_a_file_it_cannot_open},
    {"a closed file refuses", case_a_closed_file_refuses},
    {"a value that is not a file is refused by name", case_a_value_that_is_not_a_file_is_refused_by_name},
    {"a file is spelled with its state", case_a_file_is_spelled_with_its_state},
    {"a script can carry a shebang", case_a_script_can_carry_a_shebang},
    {"a shebang does not move the lines", case_a_shebang_does_not_move_the_lines},
    {"a first line of hash alone is skipped", case_a_first_line_of_hash_alone_is_skipped},
    {"a file that is only a shebang runs", case_a_file_that_is_only_a_shebang_runs},
    {"a shebang through stdin is skipped", case_a_shebang_through_stdin_is_skipped},
    {"-e still refuses a hash", case_e_still_refuses_a_hash},
};

static const int CASE_COUNT = (int)(sizeof(CASES) / sizeof(CASES[0]));

int main(int argc, char **argv) {
  const char *only = NULL;
  int i, ran = 0, failed = 0;

  if (argc < 10) {
    fprintf(stderr, "cli: the program under test and its eight fixtures come first\n");
    return 1;
  }
  nilu_path = argv[1];
  hello_path = argv[2];
  bad_path = argv[3];
  args_path = argv[4];
  fails_path = argv[5];
  shebang_path = argv[6];
  shebang_fails_path = argv[7];
  hash_path = argv[8];
  only_shebang_path = argv[9];

  for (i = 10; i < argc; i++) {
    if (strcmp(argv[i], "--list") == 0) {
      /* Counting must not do the work. */
      printf("cli: %d cases, none run\n", CASE_COUNT);
      for (i = 0; i < CASE_COUNT; i++) printf("  %s\n", CASES[i].name);
      return 0;
    }
    if (strncmp(argv[i], "--only=", 7) == 0) {
      only = argv[i] + 7;
    } else {
      fprintf(stderr, "cli: unknown argument \"%s\". --list names the cases.\n", argv[i]);
      return 1;
    }
  }

  if (only != NULL) {
    int found = 0;
    for (i = 0; i < CASE_COUNT; i++)
      if (strcmp(CASES[i].name, only) == 0) found = 1;
    if (!found) {
      fprintf(stderr, "cli: no case named \"%s\". --list names them.\n", only);
      return 1;
    }
    printf("cli: running 1 of %d cases (--only=%s)\n", CASE_COUNT, only);
  } else {
    printf("cli: running %d of %d cases\n", CASE_COUNT, CASE_COUNT);
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
    printf("\ncli: %d of %d cases failed\n", failed, ran);
    return 1;
  }
  printf("\ncli: %d of %d cases passed\n", ran, ran);
  return 0;
}
