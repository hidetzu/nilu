#include "nilu.h"
#include <limits.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "stack foundation: line %d: %s\n", __LINE__, #condition); return 1; } } while (0)

extern int test_hook_dispatch(NiluState *N);
static int hook_window_calls;
static int hook_window_ok;
static int hook_window_answer;
static int host_window_hook(NiluState *N) {
    size_t length = 99;
    hook_window_calls++;
    if (nilu_gettop(N) != 0 || nilu_type(N, 1) != NILU_TNONE ||
        nilu_tolstring(N, 1, &length) != NULL || length != 0)
        hook_window_ok = 0;
    if (nilu_pushnumber(N, 100) != NILU_OK) return 1;
    nilu_copy(N, -1, 1);
    if (nilu_pop(N, 1) != NILU_OK || nilu_gettop(N) != 0 ||
        nilu_pushstring(N, "discarded") != NILU_OK)
        hook_window_ok = 0;
    return hook_window_answer;
}
static int host_hook_pop(NiluState *N) { return nilu_pop(N, 1); }

/* A callback may run this state's VM again. Only the first callback does; the
 * inner scripts' own instructions are observed by the same hook and counted. */
static int reentry_calls;
static int reentry_inner_ok;
static int reentry_type_ok;
static int reentry_interrupt_ok;
static int reentry_stop_inner;
static int host_reentry_hook(NiluState *N) {
    reentry_calls++;
    if (reentry_stop_inner) return 1;
    if (reentry_calls != 1) return 0;
    if (nilu_gettop(N) != 0 || nilu_pushstring(N, "outer") != NILU_OK) return 1;
    if (nilu_loadstring(N, "local x = 4 local y = 5 return x + y", NULL) != NILU_OK) return 1;
    if (nilu_call(N, 0, 1) != NILU_OK || nilu_tonumber(N, -1) != 9) return 1;
    reentry_inner_ok = nilu_gettop(N) == 2 && strcmp(nilu_tostring(N, 1), "outer") == 0;
    if (nilu_loadstring(N, "return 1 + nil", NULL) != NILU_OK) return 1;
    reentry_type_ok = nilu_pcall(N, 0, 1, 0) == NILU_ERR_TYPE && nilu_type(N, -1) == NILU_TSTRING &&
        nilu_gettop(N) == 3;
    if (nilu_loadstring(N, "local p = 1 local q = 2 return p + q", NULL) != NILU_OK) return 1;
    reentry_stop_inner = 1;
    reentry_interrupt_ok = nilu_pcall(N, 0, 1, 0) == NILU_ERR_INTERRUPTED && nilu_type(N, -1) == NILU_TNIL;
    reentry_stop_inner = 0;
    return 0;
}

static int host_bad_negative(NiluState *N) { (void)N; return -2; }
static int host_bad_count(NiluState *N) { return nilu_gettop(N) + 1; }
static int host_noop(NiluState *N) { (void)N; return 0; }
/* A yield the C function does not return: the coroutine would keep frames
 * for a resume that never comes, so the host's misuse aborts. */
static int host_yield_now(NiluState *N) { return nilu_yield(N, 0); }
static int host_k(NiluState *N, int status, intptr_t ctx) { (void)N; (void)status; (void)ctx; return 0; }
static int host_pcallk_ignores_yield(NiluState *N) {
    if (nilu_pushcfunction(N, host_yield_now) != NILU_OK) return NILU_FAIL;
    (void)nilu_pcallk(N, 0, 0, 0, 0, host_k);
    return 0;
}
static int host_yield_not_returned(NiluState *N) {
    (void)nilu_yield(N, 0);
    return 0;
}

static const char *host_calledas_name;
static size_t host_calledas_size;
static int host_calledas_expect_named;
static int host_calledas_probe(NiluState *N) {
    size_t length = 99;
    const char *name = nilu_calledas(N, &length);
    int correct;
    host_calledas_name = name;
    host_calledas_size = length;
    if (host_calledas_expect_named)
        correct = name && length == 5 && memcmp(name, "alias", 5) == 0;
    else correct = name == NULL && length == 0;
    correct = correct && nilu_calledas(N, NULL) == name;
    if (nilu_pushboolean(N, correct) != NILU_OK) return NILU_FAIL;
    return 1;
}

int main(int argc, char **argv) {
#if defined(__unix__) || defined(__APPLE__)
    /* Abort probes must not leave core files in the checkout. */
    struct rlimit limit = {0, 0};
    CHECK(setrlimit(RLIMIT_CORE, &limit) == 0);
#endif
    NiluState *N;
    int isnum = 99;
    if (argc == 2) {
        if (!strcmp(argv[1], "bad-hook-pop")) {
            N = nilu_new();
            CHECK(N != NULL);
            CHECK(nilu_pushnumber(N, 42) == NILU_OK);
            nilu_sethook(N, host_hook_pop, 1);
            (void)test_hook_dispatch(N);
            (void)test_hook_dispatch(N);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "pcallk-ignores-yield") || !strcmp(argv[1], "yield-not-returned")) {
            int count = 0;
            N = nilu_new();
            CHECK(N != NULL);
            CHECK(nilu_pushcfunction(N, argv[1][0] == 'p' ? host_pcallk_ignores_yield : host_yield_not_returned) == NILU_OK);
            CHECK(nilu_newthread(N) == NILU_OK);
            (void)nilu_resume(N, 1, 0, &count);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-next")) nilu_next(NULL, 1, NULL);
        else if (!strcmp(argv[1], "null-setmetatable")) nilu_setmetatable(NULL, 1);
        else if (!strcmp(argv[1], "null-calledas")) nilu_calledas(NULL, NULL);
        else if (!strncmp(argv[1], "remaining-", 10)) {
            const char *which = argv[1] + 10;
            N = nilu_new();
            CHECK(N != NULL);
            if (!strcmp(which, "next-empty")) nilu_next(N, 1, NULL);
            else if (!strcmp(which, "metatable-empty")) nilu_setmetatable(N, 1);
            else {
                CHECK(nilu_newtable(N) == NILU_OK);
                if (!strcmp(which, "next-index")) nilu_next(N, 0, NULL);
                else if (!strcmp(which, "next-min")) nilu_next(N, INT_MIN, NULL);
                else if (!strcmp(which, "metatable-index")) nilu_setmetatable(N, 0);
                else if (!strcmp(which, "metatable-min")) nilu_setmetatable(N, INT_MIN);
                else return 2;
            }
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-gettable")) nilu_gettable(NULL, 1);
        else if (!strcmp(argv[1], "null-settable")) nilu_settable(NULL, 1);
        else if (!strcmp(argv[1], "null-getglobal")) nilu_getglobal(NULL, "x");
        else if (!strcmp(argv[1], "null-setglobal")) nilu_setglobal(NULL, "x");
        else if (!strncmp(argv[1], "access-", 7)) {
            N = nilu_new();
            CHECK(N != NULL);
            CHECK(nilu_newtable(N) == NILU_OK);
            if (!strcmp(argv[1], "access-gettable-index")) nilu_gettable(N, 0);
            else if (!strcmp(argv[1], "access-settable-index")) nilu_settable(N, 0);
            else if (!strcmp(argv[1], "access-settable-pair")) nilu_settable(N, 1);
            else if (!strcmp(argv[1], "access-getglobal-name")) nilu_getglobal(N, NULL);
            else if (!strcmp(argv[1], "access-setglobal-name")) nilu_setglobal(N, NULL);
            else if (!strcmp(argv[1], "access-setglobal-value")) { nilu_pop(N, 1); nilu_setglobal(N, "x"); }
            else return 2;
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-len")) nilu_len(NULL, 1);
        else if (!strcmp(argv[1], "null-compare")) nilu_compare(NULL, 1, 1, NILU_OPEQ);
        else if (!strncmp(argv[1], "operator-", 9)) {
            N = nilu_new();
            CHECK(N != NULL);
            CHECK(nilu_pushnumber(N, 1) == NILU_OK);
            if (!strcmp(argv[1], "operator-len-index")) nilu_len(N, 0);
            else if (!strcmp(argv[1], "operator-compare-first")) nilu_compare(N, 0, 1, NILU_OPEQ);
            else if (!strcmp(argv[1], "operator-compare-second")) nilu_compare(N, 1, 2, NILU_OPEQ);
            else if (!strcmp(argv[1], "operator-compare-code")) nilu_compare(N, 1, 1, 3);
            else if (!strcmp(argv[1], "operator-compare-min")) nilu_compare(N, 1, 1, INT_MIN);
            else return 2;
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-call")) nilu_call(NULL, 0, 0);
        else if (!strcmp(argv[1], "null-pcall")) nilu_pcall(NULL, 0, 0, 0);
        else if (!strncmp(argv[1], "call-", 5) || !strncmp(argv[1], "pcall-", 6)) {
            int protected_call = argv[1][0] == 'p';
            const char *which = argv[1] + (protected_call ? 6 : 5);
            int nargs = 0, nresults = 0, msgh = 0;
            N = nilu_new();
            CHECK(N != NULL);
            CHECK(nilu_pushnumber(N, 42) == NILU_OK);
            CHECK(nilu_pushcfunction(N, !strcmp(which, "bad-negative") ? host_bad_negative : !strcmp(which, "bad-count") ? host_bad_count : host_noop) == NILU_OK);
            if (!strcmp(which, "negative-args")) nargs = -1;
            else if (!strcmp(which, "min-args")) nargs = INT_MIN;
            else if (!strcmp(which, "missing-args")) nargs = INT_MAX;
            else if (!strcmp(which, "negative-results")) nresults = -2;
            else if (!strcmp(which, "min-results")) nresults = INT_MIN;
            else if (!strcmp(which, "handler-absent")) msgh = INT_MAX;
            else if (!strcmp(which, "handler-min")) msgh = INT_MIN;
            else if (!strcmp(which, "handler-type")) msgh = 1;
            else if (!strcmp(which, "handler-callee")) msgh = 2;
            else if (!strcmp(which, "handler-negative")) msgh = -1;
            else if (strcmp(which, "bad-negative") && strcmp(which, "bad-count")) return 2;
            if (protected_call) nilu_pcall(N, nargs, nresults, msgh);
            else nilu_call(N, nargs, nresults);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-loadstring")) nilu_loadstring(NULL, "", NULL);
        else if (!strcmp(argv[1], "null-loadnamed")) nilu_loadnamed(NULL, "", "=probe", NULL);
        else if (!strncmp(argv[1], "bad-load", 8)) {
            N = nilu_new();
            CHECK(N != NULL);
            if (!strcmp(argv[1], "bad-loadstring-source")) nilu_loadstring(N, NULL, NULL);
            else if (!strcmp(argv[1], "bad-loadnamed-source")) nilu_loadnamed(N, NULL, "=probe", NULL);
            else if (!strcmp(argv[1], "bad-loadnamed-name")) nilu_loadnamed(N, "", NULL, NULL);
            else return 2;
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-where")) (void)nilu_where(NULL, 0, NULL);
        else if (!strcmp(argv[1], "null-namewhat")) (void)nilu_namewhat(NULL);
        else if (!strcmp(argv[1], "null-type")) nilu_type(NULL, 0);
        else if (!strcmp(argv[1], "null-rawget")) nilu_rawget(NULL, 0);
        else if (!strcmp(argv[1], "null-rawset")) nilu_rawset(NULL, 0);
        else if (!strncmp(argv[1], "bad-raw", 7)) {
            N = nilu_new();
            CHECK(N != NULL);
            if (!strcmp(argv[1], "bad-rawget-index")) nilu_rawget(N, 0);
            else if (!strcmp(argv[1], "bad-rawset-index")) nilu_rawset(N, 0);
            else {
                CHECK(nilu_newtable(N) == NILU_OK);
                if (!strcmp(argv[1], "bad-rawset-pair")) nilu_rawset(N, 1);
                else return 2;
            }
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-gettop")) nilu_gettop(NULL);
        else if (!strcmp(argv[1], "null-settop")) nilu_settop(NULL, 0);
        else if (!strcmp(argv[1], "null-pushnil")) nilu_pushnil(NULL);
        else if (!strcmp(argv[1], "null-pushnumber")) nilu_pushnumber(NULL, 0);
        else if (!strcmp(argv[1], "null-tonumberx")) nilu_tonumberx(NULL, 0, NULL);
        else if (!strcmp(argv[1], "null-pushstring")) nilu_pushstring(NULL, "x");
        else if (!strcmp(argv[1], "null-pushlstring")) nilu_pushlstring(NULL, NULL, 0);
        else if (!strcmp(argv[1], "null-tolstring")) nilu_tolstring(NULL, 0, NULL);
        else if (!strcmp(argv[1], "null-pushboolean")) nilu_pushboolean(NULL, 0);
        else if (!strcmp(argv[1], "null-toboolean")) nilu_toboolean(NULL, 0);
        else if (!strcmp(argv[1], "null-pushvalue")) nilu_pushvalue(NULL, 1);
        else if (!strcmp(argv[1], "null-copy")) nilu_copy(NULL, 1, 1);
        else if (!strcmp(argv[1], "null-rotate")) nilu_rotate(NULL, 1, 0);
        else if (!strcmp(argv[1], "null-newtable")) nilu_newtable(NULL);
        else if (!strcmp(argv[1], "null-newuserdata")) nilu_newuserdata(NULL, 0, NULL);
        else if (!strcmp(argv[1], "null-touserdata")) nilu_touserdata(NULL, 0);
        else if (!strcmp(argv[1], "null-rawlen")) nilu_rawlen(NULL, 0);
        else if (!strcmp(argv[1], "null-rawequal")) nilu_rawequal(NULL, 0, 0);
        else if (!strcmp(argv[1], "null-stringtonumber")) nilu_stringtonumber(NULL, "1", 1);
        else if (!strcmp(argv[1], "null-numeral")) {
            N = nilu_new();
            CHECK(N != NULL);
            nilu_stringtonumber(N, NULL, 0);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-topointer")) nilu_topointer(NULL, 0);
        else if (!strcmp(argv[1], "null-error")) nilu_error(NULL);
        else if (!strcmp(argv[1], "empty-error")) {
            N = nilu_new();
            CHECK(N != NULL);
            nilu_error(N);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-sethook")) nilu_sethook(NULL, NULL, 0);
        else if (!strcmp(argv[1], "null-getmetatable")) nilu_getmetatable(NULL, 0);
        else if (!strcmp(argv[1], "null-pushcfunction")) nilu_pushcfunction(NULL, host_noop);
        else if (!strcmp(argv[1], "null-pushcclosure")) nilu_pushcclosure(NULL, host_noop, 0);
        else if (!strcmp(argv[1], "null-getupvalue")) nilu_getupvalue(NULL, 1);
        else if (!strcmp(argv[1], "null-setupvalue")) nilu_setupvalue(NULL, 1);
        else if (!strncmp(argv[1], "bad-", 4)) {
            N = nilu_new();
            CHECK(N != NULL && nilu_pushnumber(N, 1) == NILU_OK);
            if (!strcmp(argv[1], "bad-pushvalue")) nilu_pushvalue(N, 0);
            else if (!strcmp(argv[1], "bad-copy-from")) nilu_copy(N, 0, 1);
            else if (!strcmp(argv[1], "bad-copy-to")) nilu_copy(N, 1, 0);
            else if (!strcmp(argv[1], "bad-rotate-index")) nilu_rotate(N, 0, 0);
            else if (!strcmp(argv[1], "bad-rotate-count")) nilu_rotate(N, 1, 2);
            else if (!strcmp(argv[1], "bad-rotate-min")) nilu_rotate(N, 1, INT_MIN);
            else if (!strcmp(argv[1], "bad-cfunction-null")) nilu_pushcfunction(N, NULL);
            else if (!strcmp(argv[1], "bad-cclosure-null")) nilu_pushcclosure(N, NULL, 0);
            else if (!strcmp(argv[1], "bad-cclosure-negative")) nilu_pushcclosure(N, host_noop, INT_MIN);
            else if (!strcmp(argv[1], "bad-cclosure-max")) nilu_pushcclosure(N, host_noop, NILU_MAXUPVALUES + 1);
            else if (!strcmp(argv[1], "bad-cclosure-count")) nilu_pushcclosure(N, host_noop, 2);
            else return 2;
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "null-bytes")) {
            N = nilu_new();
            CHECK(N != NULL);
            nilu_pushlstring(N, NULL, 1);
            nilu_close(N);
        }
        else if (!strcmp(argv[1], "below-bottom")) {
            N = nilu_new();
            CHECK(N != NULL);
            nilu_settop(N, INT_MIN);
            nilu_close(N);
        } else return 2;
        return 0; /* The runner requires the documented abort. */
    }
    {
        char source[] = "return 1";
        char name[] = "=owned";
        NiluError where = {99, 99};
        N = nilu_new();
        CHECK(N != NULL);
        CHECK(nilu_namewhat(N) == NULL);
        CHECK(nilu_where(N, 0, &where) == NULL && where.line == 0 && where.column == 0);
        CHECK(nilu_where(N, INT_MIN, NULL) == NULL);
        CHECK(nilu_pushnumber(N, 42) == NILU_OK);
        CHECK(nilu_loadnamed(N, source, name, &where) == NILU_OK);
        CHECK(where.line == 0 && where.column == 0);
        memset(source, '?', sizeof source - 1);
        memset(name, '?', sizeof name - 1);
        CHECK(nilu_type(N, -1) == NILU_TFUNCTION && nilu_gettop(N) == 2);
        CHECK(nilu_tonumber(N, 1) == 42);
        CHECK(nilu_loadnamed(N, "local = 1", "=probe", &where) == NILU_ERR_SYNTAX);
        CHECK(where.line == 1 && where.column == 7);
        CHECK(!strcmp(nilu_tostring(N, -1), "probe:1:7: <name> expected near '='"));
        CHECK(nilu_loadnamed(N, "local = 1", "=probe", NULL) == NILU_ERR_SYNTAX);
        CHECK(nilu_rawequal(N, -1, -2));
        CHECK(nilu_loadstring(N, "return 1\0ignored", &where) == NILU_OK);
        CHECK(where.line == 0 && where.column == 0 && nilu_type(N, -1) == NILU_TFUNCTION);
        CHECK(nilu_loadstring(N, "", NULL) == NILU_OK);
        CHECK(nilu_tonumber(N, 1) == 42);
        nilu_close(N);
    }
    N = nilu_new();
    CHECK(N != NULL);
    CHECK(nilu_pushnumber(N, 42) == NILU_OK);
    hook_window_calls = 0;
    hook_window_ok = 1;
    hook_window_answer = 0;
    nilu_sethook(N, host_window_hook, 1);
    CHECK(test_hook_dispatch(N) == 0 && hook_window_calls == 0);
    CHECK(test_hook_dispatch(N) == 0 && hook_window_calls == 1);
    CHECK(nilu_gettop(N) == 1 && nilu_tonumber(N, 1) == 42);
    hook_window_answer = -1;
    CHECK(test_hook_dispatch(N) == 1 && hook_window_calls == 2);
    CHECK(hook_window_ok && nilu_gettop(N) == 1 && nilu_tonumber(N, 1) == 42);
    nilu_close(N);
    nilu_close(NULL);
    N = nilu_new();
    CHECK(N != NULL);
    CHECK(NILU_TNONE == -1 && NILU_TNIL == 0 && NILU_TNUMBER == 1 && NILU_TFUNCTION == 2);
    CHECK(NILU_TBOOLEAN == 3 && NILU_TSTRING == 4 && NILU_TTABLE == 5 && NILU_TUSERDATA == 6);
    CHECK(nilu_type(N, 0) == NILU_TNONE);
    CHECK(nilu_pushnil(N) == NILU_OK && nilu_type(N, -1) == NILU_TNIL);
    CHECK(nilu_pushboolean(N, 1) == NILU_OK && nilu_type(N, -1) == NILU_TBOOLEAN);
    CHECK(nilu_pushstring(N, "key") == NILU_OK && nilu_type(N, -1) == NILU_TSTRING);
    CHECK(nilu_pushnumber(N, 5) == NILU_OK && nilu_type(N, -1) == NILU_TNUMBER);
    CHECK(nilu_pushcfunction(N, host_noop) == NILU_OK && nilu_type(N, -1) == NILU_TFUNCTION);
    CHECK(nilu_newuserdata(N, 0, NULL) == NILU_OK && nilu_type(N, -1) == NILU_TUSERDATA);
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_newtable(N) == NILU_OK && nilu_type(N, 1) == NILU_TTABLE);
    CHECK(nilu_pushstring(N, "key") == NILU_OK && nilu_pushnumber(N, 17) == NILU_OK);
    CHECK(nilu_rawset(N, -3) == NILU_OK && nilu_gettop(N) == 1);
    CHECK(nilu_pushstring(N, "key") == NILU_OK && nilu_rawget(N, 1) == NILU_OK);
    CHECK(nilu_tonumber(N, -1) == 17);
    CHECK(nilu_pushnumber(N, 99) == NILU_OK && nilu_rawset(N, -1) == NILU_ERR_TYPE);
    CHECK(nilu_gettop(N) == 3 && nilu_tonumber(N, -1) == 99);
    nilu_close(N);
    N = nilu_new();
    CHECK(N != NULL);
    nilu_sethook(N, host_noop, UINT_MAX);
    CHECK(nilu_gettop(N) == 0);
    nilu_sethook(N, host_noop, 0);
    nilu_sethook(N, NULL, 1);
    CHECK(nilu_gettop(N) == 0);
    CHECK(nilu_gettop(N) == 0);
    CHECK(nilu_tonumberx(N, 0, &isnum) == 0 && isnum == 0);
    CHECK(nilu_pushnumber(N, 10) == NILU_OK);
    CHECK(nilu_pushnumber(N, 20) == NILU_OK);
    CHECK(nilu_gettop(N) == 2);
    CHECK(nilu_tonumberx(N, 1, &isnum) == 10 && isnum == 1);
    CHECK(nilu_tonumber(N, -1) == 20);
    CHECK(nilu_tonumber(N, 2) == 20);
    CHECK(nilu_tonumberx(N, INT_MIN, &isnum) == 0 && isnum == 0);
    CHECK(nilu_tonumberx(N, INT_MAX, &isnum) == 0 && isnum == 0);
    CHECK(nilu_settop(N, -2) == NILU_OK && nilu_gettop(N) == 1);
    CHECK(nilu_settop(N, 4) == NILU_OK && nilu_gettop(N) == 4);
    isnum = 99;
    CHECK(nilu_tonumberx(N, 4, &isnum) == 0 && isnum == 0);
    CHECK(nilu_pushnil(N) == NILU_OK);
    CHECK(nilu_tonumberx(N, -1, &isnum) == 0 && isnum == 0);
    CHECK(nilu_pushnumber(N, -0.0) == NILU_OK);
    CHECK(signbit(nilu_tonumberx(N, -1, &isnum)) && isnum == 1);
    CHECK(nilu_pushnumber(N, INFINITY) == NILU_OK);
    CHECK(isinf(nilu_tonumberx(N, -1, &isnum)) && isnum == 1);
    CHECK(nilu_pushnumber(N, NAN) == NILU_OK);
    CHECK(isnan(nilu_tonumberx(N, -1, &isnum)) && isnum == 1);
    CHECK(nilu_settop(N, INT_MAX) == NILU_ERR_STACK && nilu_gettop(N) == 8);
    CHECK(nilu_settop(N, 0) == NILU_OK && nilu_gettop(N) == 0);
    {
        char bytes[] = {'a', 0, 'b'};
        const char *text;
        size_t length = 99;
        CHECK(nilu_pushlstring(N, bytes, sizeof bytes) == NILU_OK);
        bytes[0] = 'z';
        text = nilu_tolstring(N, 1, &length);
        CHECK(text != NULL && length == 3 && memcmp(text, "a\0b", 3) == 0 && text[3] == 0);
        CHECK(nilu_pushstring(N, "c-string") == NILU_OK);
        text = nilu_tolstring(N, -1, &length);
        CHECK(text != NULL && length == 8 && strcmp(text, "c-string") == 0);
        CHECK(nilu_pushlstring(N, NULL, 0) == NILU_OK);
        CHECK(nilu_tolstring(N, -1, &length) != NULL && length == 0);
        CHECK(nilu_pushstring(N, NULL) == NILU_OK);
        length = 99;
        CHECK(nilu_tolstring(N, -1, &length) == NULL && length == 0);
        /* A float keeps .0, as lua5.5 spells it. */
        CHECK(nilu_pushnumber(N, 10) == NILU_OK);
        text = nilu_tolstring(N, -1, &length);
        CHECK(text != NULL && length == 4 && strcmp(text, "10.0") == 0);
        CHECK(nilu_tonumberx(N, -1, &isnum) == 0 && isnum == 0);
        CHECK(text == nilu_tolstring(N, -1, NULL));
        CHECK(nilu_settop(N, 10000) == NILU_OK && strcmp(text, "10.0") == 0);
    }
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_pushboolean(N, 0) == NILU_OK && nilu_toboolean(N, -1) == 0);
    CHECK(nilu_pushboolean(N, INT_MIN) == NILU_OK && nilu_toboolean(N, -1) == 1);
    CHECK(nilu_pushnumber(N, 0) == NILU_OK && nilu_toboolean(N, -1) == 1);
    CHECK(nilu_pushstring(N, "") == NILU_OK && nilu_toboolean(N, -1) == 1);
    CHECK(nilu_toboolean(N, 0) == 0 && nilu_toboolean(N, INT_MAX) == 0);
    CHECK(nilu_pop(N, 4) == NILU_OK && nilu_gettop(N) == 0);
    {
        int i;
        const int first[] = {5, 1, 2, 3, 4};
        const int last[] = {1, 3, 4, 9};
        for (i = 1; i <= 5; i++) CHECK(nilu_pushnumber(N, i) == NILU_OK);
        nilu_insert(N, 1);
        for (i = 0; i < 5; i++) CHECK(nilu_tonumber(N, i + 1) == first[i]);
        CHECK(nilu_remove(N, 1) == NILU_OK);
        CHECK(nilu_pushnumber(N, 9) == NILU_OK);
        CHECK(nilu_replace(N, 2) == NILU_OK);
        nilu_rotate(N, 2, -1);
        for (i = 0; i < 4; i++) CHECK(nilu_tonumber(N, i + 1) == last[i]);
        CHECK(nilu_pushvalue(N, -1) == NILU_OK && nilu_gettop(N) == 5);
        CHECK(nilu_tonumber(N, -1) == 9);
        nilu_copy(N, -1, 1);
        CHECK(nilu_tonumber(N, 1) == 9 && nilu_gettop(N) == 5);
    }
    CHECK(nilu_settop(N, 0) == NILU_OK);
    {
        void *block = NULL;
        size_t i;
        CHECK(nilu_newuserdata(N, sizeof(long double), &block) == NILU_OK && block != NULL);
        CHECK(nilu_touserdata(N, -1) == block);
        for (i = 0; i < sizeof(long double); i++) CHECK(((unsigned char *)block)[i] == 0);
        *(long double *)block = 1.25L;
        CHECK(*(long double *)nilu_touserdata(N, 1) == 1.25L);
        CHECK(nilu_rawlen(N, 1) == NILU_OK);
        CHECK(nilu_tonumber(N, -1) == (double)sizeof(long double));
        CHECK(nilu_pop(N, 1) == NILU_OK);
        CHECK(nilu_pushvalue(N, 1) == NILU_OK && nilu_touserdata(N, -1) == block);
        CHECK(nilu_newuserdata(N, 4, NULL) == NILU_OK);
        CHECK(nilu_newuserdata(N, SIZE_MAX, &block) == NILU_ERR_MEMORY && block == NULL);
        CHECK(nilu_newtable(N) == NILU_OK && nilu_touserdata(N, -1) == NULL);
        CHECK(nilu_rawlen(N, -1) == NILU_OK && nilu_tonumber(N, -1) == 0);
        CHECK(nilu_pushlstring(N, "a\0b", 3) == NILU_OK);
        CHECK(nilu_rawlen(N, -1) == NILU_OK && nilu_tonumber(N, -1) == 3);
        i = (size_t)nilu_gettop(N);
        CHECK(nilu_rawlen(N, -1) == NILU_OK && (size_t)nilu_gettop(N) == i + 1);
        CHECK(nilu_tonumber(N, -1) == 0);
    }
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_stringtonumber(N, "  12.5  ", 8) == NILU_OK);
    CHECK(nilu_tonumber(N, -1) == 12.5);
    CHECK(nilu_stringtonumber(N, "12x", 3) == NILU_ERR_SYNTAX);
    CHECK(nilu_stringtonumber(N, "inf", 3) == NILU_ERR_SYNTAX);
    CHECK(nilu_stringtonumber(N, "1\0 2", 4) == NILU_ERR_SYNTAX);
    CHECK(nilu_gettop(N) == 1);
    CHECK(strcmp(nilu_tostring(N, 1), "12.5") == 0);
    CHECK(nilu_pushstring(N, "12.5") == NILU_OK && nilu_rawequal(N, 1, 2) == 1);
    CHECK(nilu_pushnumber(N, 12.5) == NILU_OK && nilu_rawequal(N, 1, 3) == 0);
    CHECK(nilu_rawequal(N, 0, 0) == 0 && nilu_rawequal(N, 1, INT_MIN) == 0);
    CHECK(nilu_newtable(N) == NILU_OK && nilu_pushvalue(N, -1) == NILU_OK);
    CHECK(nilu_rawequal(N, -1, -2) == 1);
    CHECK(nilu_newtable(N) == NILU_OK && nilu_rawequal(N, -1, -2) == 0);
    CHECK(nilu_rawlen(N, INT_MAX) == NILU_OK && nilu_tonumber(N, -1) == 0);
    CHECK(nilu_settop(N, 0) == NILU_OK);
    {
        const void *first, *second;
        CHECK(nilu_newuserdata(N, 0, NULL) == NILU_OK);
        first = nilu_topointer(N, 1);
        CHECK(first != NULL && first == nilu_touserdata(N, 1));
        CHECK(nilu_newuserdata(N, 0, NULL) == NILU_OK);
        second = nilu_topointer(N, 2);
        CHECK(second != NULL && first != second);
        CHECK(nilu_pushvalue(N, 1) == NILU_OK && nilu_topointer(N, 3) == first);
        CHECK(nilu_rawlen(N, 1) == NILU_OK && nilu_tonumber(N, -1) == 0);
        CHECK(nilu_newtable(N) == NILU_OK && nilu_topointer(N, -1) != NULL);
        CHECK(nilu_getmetatable(N, -1) == NILU_OK && nilu_toboolean(N, -1) == 0);
        CHECK(nilu_topointer(N, -1) == NULL && nilu_topointer(N, INT_MIN) == NULL);
        CHECK(nilu_getmetatable(N, INT_MAX) == NILU_OK && nilu_toboolean(N, -1) == 0);
    }
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_pushcfunction(N, host_noop) == NILU_OK);
    CHECK(nilu_pushcclosure(N, host_noop, 0) == NILU_OK && nilu_rawequal(N, 1, 2));
    CHECK(nilu_getupvalue(N, 1) == NILU_ERR_TYPE && nilu_gettop(N) == 2);
    CHECK(nilu_setupvalue(N, 1) == NILU_ERR_TYPE && nilu_gettop(N) == 2);
    CHECK(nilu_pushnumber(N, 7) == NILU_OK);
    CHECK(nilu_pushcclosure(N, host_noop, 1) == NILU_OK && nilu_gettop(N) == 3);
    CHECK(!nilu_rawequal(N, 1, 3) && nilu_topointer(N, 3) != NULL);
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_pushstring(N, "abc") == NILU_OK);
    CHECK(nilu_len(N, 1) == NILU_OK && nilu_tonumber(N, -1) == 3);
    CHECK(nilu_pushnumber(N, 4) == NILU_OK);
    CHECK(nilu_compare(N, 2, 3, NILU_OPLT) == NILU_OK && nilu_toboolean(N, -1));
    CHECK(nilu_pop(N, 1) == NILU_OK);
    CHECK(nilu_compare(N, 1, 2, NILU_OPLE) == NILU_ERR_TYPE && nilu_gettop(N) == 3);
    CHECK(nilu_settop(N, 0) == NILU_OK && nilu_newtable(N) == NILU_OK);
    CHECK(nilu_pushstring(N, "k") == NILU_OK && nilu_pushnumber(N, 8) == NILU_OK);
    CHECK(nilu_settable(N, 1) == NILU_OK && nilu_gettop(N) == 1);
    CHECK(nilu_pushstring(N, "k") == NILU_OK && nilu_gettable(N, 1) == NILU_OK);
    CHECK(nilu_tonumber(N, -1) == 8 && nilu_setglobal(N, "host_value") == NILU_OK);
    CHECK(nilu_getglobal(N, "host_value") == NILU_OK && nilu_tonumber(N, -1) == 8);
    CHECK(nilu_settop(N, 0) == NILU_OK && nilu_newtable(N) == NILU_OK);
    CHECK(nilu_pushstring(N, "key") == NILU_OK && nilu_pushnumber(N, 7) == NILU_OK);
    CHECK(nilu_rawset(N, 1) == NILU_OK && nilu_pushnil(N) == NILU_OK);
    {
        int more = 99;
        CHECK(nilu_next(N, 1, &more) == NILU_OK && more == 1);
        CHECK(nilu_gettop(N) == 3 && nilu_tonumber(N, -1) == 7);
        CHECK(nilu_pop(N, 1) == NILU_OK);
        CHECK(nilu_next(N, 1, &more) == NILU_OK && more == 0 && nilu_gettop(N) == 1);
        CHECK(nilu_pushstring(N, "absent") == NILU_OK);
        more = 99;
        CHECK(nilu_next(N, 1, &more) == NILU_ERR_RUNTIME && more == 0);
        CHECK(nilu_gettop(N) == 2 && strcmp(nilu_tostring(N, -1), "absent") == 0);
        CHECK(nilu_pop(N, 1) == NILU_OK && nilu_pushnil(N) == NILU_OK);
        CHECK(nilu_next(N, 1, NULL) == NILU_OK && nilu_gettop(N) == 3);
    }
    CHECK(nilu_settop(N, 1) == NILU_OK && nilu_pushnumber(N, 9) == NILU_OK);
    CHECK(nilu_setmetatable(N, 1) == NILU_ERR_TYPE && nilu_gettop(N) == 2);
    CHECK(nilu_tonumber(N, -1) == 9);
    CHECK(nilu_pop(N, 1) == NILU_OK && nilu_newtable(N) == NILU_OK);
    CHECK(nilu_setmetatable(N, -2) == NILU_OK && nilu_gettop(N) == 1);
    CHECK(nilu_getmetatable(N, 1) == NILU_OK && nilu_type(N, -1) == NILU_TTABLE);
    CHECK(nilu_pop(N, 1) == NILU_OK && nilu_pushnil(N) == NILU_OK);
    CHECK(nilu_setmetatable(N, 1) == NILU_OK && nilu_gettop(N) == 1);
    CHECK(nilu_getmetatable(N, 1) == NILU_OK && nilu_type(N, -1) == NILU_TNIL);
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_pushcfunction(N, host_calledas_probe) == NILU_OK);
    CHECK(nilu_setglobal(N, "inspect_name") == NILU_OK);
    CHECK(nilu_loadnamed(N, "local alias=inspect_name return alias()", "=c-calledas", NULL) == NILU_OK);
    host_calledas_expect_named = 1;
    CHECK(nilu_call(N, 0, 1) == NILU_OK && nilu_toboolean(N, -1));
    {
        const char *borrowed = host_calledas_name;
        size_t length = 99;
        CHECK(borrowed && host_calledas_size == 5 && memcmp(borrowed, "alias", 5) == 0);
        CHECK(nilu_calledas(N, &length) == NULL && length == 0);
        CHECK(nilu_calledas(N, NULL) == NULL && memcmp(borrowed, "alias", 5) == 0);
    }
    CHECK(nilu_settop(N, 0) == NILU_OK);
    CHECK(nilu_pushcfunction(N, host_calledas_probe) == NILU_OK);
    host_calledas_expect_named = 0;
    CHECK(nilu_call(N, 0, 1) == NILU_OK && nilu_toboolean(N, -1));
    nilu_close(N);
    N = nilu_new();
    CHECK(N != NULL);
    CHECK(nilu_pushnumber(N, 42) == NILU_OK);
    reentry_calls = 0;
    reentry_inner_ok = 0;
    reentry_type_ok = 0;
    reentry_interrupt_ok = 0;
    reentry_stop_inner = 0;
    nilu_sethook(N, host_reentry_hook, 1);
    CHECK(nilu_loadstring(N, "local x = 1 local y = 2 return x + y", NULL) == NILU_OK);
    CHECK(nilu_call(N, 0, 1) == NILU_OK && nilu_tonumber(N, -1) == 3);
    CHECK(reentry_inner_ok && reentry_type_ok && reentry_interrupt_ok && reentry_calls > 5);
    CHECK(nilu_gettop(N) == 2 && nilu_tonumber(N, 1) == 42);
    nilu_sethook(N, NULL, 0);
    nilu_close(N);
    puts("C stack foundation: value, owned-object, raw-length and stack checks passed");
    return 0;
}
