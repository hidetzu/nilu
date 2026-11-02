#include "nilu.h"
/* Linked only into Zig tests: an actual C callback exercising the public API. */
int test_counter_callback(NiluState *N) {
    double value;
    int isnum = 0;
    if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;
    value = nilu_tonumberx(N, -1, &isnum);
    if (!isnum || nilu_pop(N, 1) != NILU_OK) return NILU_FAIL;
    if (nilu_pushnumber(N, value + 1) != NILU_OK ||
        nilu_pushvalue(N, -1) != NILU_OK ||
        nilu_setupvalue(N, 1) != NILU_OK) return NILU_FAIL;
    return 1;
}

static unsigned int hook_calls;
static int hook_answer;
void test_hook_reset(int answer) { hook_calls = 0; hook_answer = answer; }
unsigned int test_hook_calls(void) { return hook_calls; }
int test_instruction_hook(NiluState *N) {
    (void)N;
    ++hook_calls;
    return hook_calls >= 3 ? hook_answer : 0;
}

/* Actual C stack operations decide whether the original failure is relayed. */
int test_failure_relay(NiluState *N) { return nilu_error(N); }
int test_failure_copy(NiluState *N) {
    if (nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
    nilu_copy(N, -1, 1);
    if (nilu_settop(N, 1) != NILU_OK ||
        nilu_pushnil(N) != NILU_OK) return NILU_FAIL;
    nilu_rotate(N, 1, 1);
    if (nilu_remove(N, 1) != NILU_OK) return NILU_FAIL;
    return nilu_error(N);
}
int test_failure_new_same(NiluState *N) {
    size_t length = 0;
    const char *text = nilu_tolstring(N, -1, &length);
    if (text) {
        if (nilu_pushlstring(N, text, length) != NILU_OK) return NILU_FAIL;
    } else if (nilu_pushnil(N) != NILU_OK) return NILU_FAIL;
    return nilu_error(N);
}
int test_failure_bare(NiluState *N) { (void)N; return NILU_FAIL; }

int test_handler_message(NiluState *N) {
    if (nilu_gettop(N) != 1 || nilu_pushstring(N, "handled") != NILU_OK)
        return NILU_FAIL;
    return 1;
}

int test_native_invalid_negative(NiluState *N) { (void)N; return -2; }
int test_native_overcount(NiluState *N) { return nilu_gettop(N) + 1; }
int test_native_exact_results(NiluState *N) { return nilu_gettop(N); }

/* Observations, not a promise of permitted hook API capabilities. */
static int observed_hook_top;
static int observed_hook_type;
static double observed_hook_number;
static unsigned int observed_hook_count;
void test_hook_observe_reset(void) { observed_hook_count = 0; }
int test_hook_observe_stack(NiluState *N) {
    if (observed_hook_count++ == 0) {
        observed_hook_top = nilu_gettop(N);
        observed_hook_type = nilu_type(N, 1);
        observed_hook_number = nilu_tonumber(N, 1);
    }
    return 0;
}
int test_hook_observed_top(void) { return observed_hook_top; }
int test_hook_observed_type(void) { return observed_hook_type; }
double test_hook_observed_number(void) { return observed_hook_number; }
unsigned int test_hook_observed_count(void) { return observed_hook_count; }


int test_namewhat(NiluState *N) {
    const char *kind = nilu_namewhat(N);
    if (nilu_pushstring(N, kind == NULL ? "NULL" : kind) != NILU_OK) return NILU_FAIL;
    return 1;
}


static const char *where_names[3];
static int where_lines[3];

int test_where_chain(NiluState *N) {
    NiluError one = {99,99}, two = {99,99}, three = {99,99}, absent = {99,99};
    where_names[0] = nilu_where(N, 1, &one);
    where_names[1] = nilu_where(N, 2, &two);
    where_names[2] = nilu_where(N, 3, &three);
    where_lines[0] = one.line; where_lines[1] = two.line; where_lines[2] = three.line;
    if (nilu_where(N, 99, &absent) != NULL || absent.line != 0 || absent.column != 0) return NILU_FAIL;
    if (where_names[0] == NULL || where_names[1] == NULL || where_names[2] == NULL || one.column != 0 || two.column != 0 || three.column != 0) return NILU_FAIL;
    if (nilu_pushstring(N, "handled") != NILU_OK) return NILU_FAIL;
    return 1;
}
const char *test_where_name(int index) { return index >= 0 && index < 3 ? where_names[index] : NULL; }
int test_where_line(int index) { return index >= 0 && index < 3 ? where_lines[index] : 0; }

int test_public_relay(NiluState *N) {
    int mode = (int)nilu_tonumber(N, 2);
    NiluStatus status;
    if (nilu_pushvalue(N, 1) != NILU_OK) return NILU_FAIL;
    status = mode == 3 ? nilu_pcall(N, 0, 0, 0) : nilu_call(N, 0, 0);
    if (status != NILU_ERR_TYPE) return NILU_FAIL;
    if (mode == 1) {
        if (nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
    } else if (mode == 2) {
        const char *words = nilu_tostring(N, -1);
        if (!words || nilu_pushstring(N, words) != NILU_OK) return NILU_FAIL;
    } else if (mode == 4) return NILU_FAIL;
    return nilu_error(N);
}
static int public_handlers;
void test_public_reset_handlers(void) { public_handlers = 0; }
int test_public_handler_count(void) { return public_handlers; }
int test_public_handler(NiluState *N) {
    NiluError where;
    const char *name;
    ++public_handlers;
    name = nilu_where(N, 1, &where);
    if (!name || where.line != 1 || nilu_gettop(N) != 1) return NILU_FAIL;
    if (nilu_pushstring(N, "handled") != NILU_OK) return NILU_FAIL;
    return 1;
}
int test_public_catch(NiluState *N) {
    if (nilu_loadnamed(N, "return 1+nil", "=caught", NULL) != NILU_OK)
        return NILU_FAIL;
    if (nilu_pcall(N, 0, 0, 0) != NILU_ERR_TYPE) return NILU_FAIL;
    return 0;
}

int test_operator_queries(NiluState *N) {
    if (nilu_gettop(N) != 2) return NILU_FAIL;
    if (nilu_len(N, 1) != NILU_OK || nilu_type(N, -1) != NILU_TSTRING)
        return NILU_FAIL;
    if (nilu_pop(N, 1) != NILU_OK) return NILU_FAIL;
    if (nilu_compare(N, 1, 2, NILU_OPEQ) != NILU_OK || !nilu_toboolean(N, -1))
        return NILU_FAIL;
    if (nilu_pop(N, 1) != NILU_OK) return NILU_FAIL;
    if (nilu_compare(N, 1, 2, NILU_OPLT) != NILU_OK || !nilu_toboolean(N, -1))
        return NILU_FAIL;
    if (nilu_pop(N, 1) != NILU_OK) return NILU_FAIL;
    if (nilu_compare(N, 1, 2, NILU_OPLE) != NILU_ERR_TYPE || nilu_gettop(N) != 2)
        return NILU_FAIL;
    return 0;
}
int test_operator_failure(NiluState *N) {
    if (nilu_len(N, 1) != NILU_ERR_TYPE || nilu_gettop(N) != 2)
        return NILU_FAIL;
    return 0;
}

int test_table_roundtrip(NiluState *N) {
    if (nilu_pushstring(N, "value") != NILU_OK || nilu_pushnumber(N, 8) != NILU_OK ||
        nilu_settable(N, 1) != NILU_OK || nilu_gettop(N) != 1)
        return NILU_FAIL;
    if (nilu_pushstring(N, "value") != NILU_OK || nilu_gettable(N, 1) != NILU_OK ||
        nilu_tonumber(N, -1) != 8) return NILU_FAIL;
    if (nilu_setglobal(N, "roundtrip") != NILU_OK || nilu_gettop(N) != 1)
        return NILU_FAIL;
    if (nilu_getglobal(N, "roundtrip") != NILU_OK || nilu_tonumber(N, -1) != 8)
        return NILU_FAIL;
    return 1;
}
int test_api_operation_relay(NiluState *N) {
    int mode = (int)nilu_tonumber(N, 2);
    NiluStatus status;
    if (mode < 2) {
        if (nilu_pushstring(N, "missing") != NILU_OK) return NILU_FAIL;
        if (mode == 0) status = nilu_gettable(N, 1);
        else {
            if (nilu_pushnumber(N, 9) != NILU_OK) return NILU_FAIL;
            status = nilu_settable(N, 1);
        }
    } else if (mode == 2) status = nilu_getglobal(N, "operation_missing");
    else if (mode == 3) {
        if (nilu_pushnumber(N, 9) != NILU_OK) return NILU_FAIL;
        status = nilu_setglobal(N, "operation_missing");
    } else if (mode == 4) status = nilu_len(N, 1);
    else {
        if (nilu_newtable(N) != NILU_OK) return NILU_FAIL;
        status = nilu_compare(N, 1, -1, NILU_OPEQ);
    }
    if (status != NILU_ERR_TYPE || nilu_type(N, -1) != NILU_TSTRING)
        return NILU_FAIL;
    return nilu_error(N);
}

static const char *calledas_pointer;
static size_t calledas_length;
static const char *calledas_kind;
const char *test_calledas_pointer(void) { return calledas_pointer; }
size_t test_calledas_length(void) { return calledas_length; }
const char *test_calledas_kind(void) { return calledas_kind; }
int test_calledas(NiluState *N) {
    size_t length = 99;
    const char *name = nilu_calledas(N, &length);
    calledas_pointer = name;
    calledas_kind = nilu_namewhat(N);
    calledas_length = length;
    if (nilu_calledas(N, NULL) != name) return NILU_FAIL;
    if (!name) {
        if (length != 0) return NILU_FAIL;
        name = "<NULL>";
        length = 6;
    }
    if (nilu_pushlstring(N, name, length) != NILU_OK) return NILU_FAIL;
    return 1;
}
