//! Any value but nil and NaN is a key: a table, a function
//! and a userdata by identity, a boolean by its value.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

test "table_key tables, functions and booleans are keys, a table by identity" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("table|fn|native|yes|no|nil|nil", try answer(state,
        \\local k, f = {}, function() end
        \\local t = {[k] = "table", [f] = "fn", [type] = "native", [true] = "yes", [false] = "no"}
        \\return t[k] .. "|" .. t[f] .. "|" .. t[type] .. "|" .. t[true] .. "|" .. t[false]
        \\  .. "|" .. tostring(t[{}]) .. "|" .. tostring(t[function() end])
    ));
}

test "table_key a set of tables counts, removes and walks its members" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("3 2 true", try answer(state,
        \\local a, b, c = {}, {}, {}
        \\local set = {}
        \\for _, member in ipairs({a, b, c, a}) do set[member] = true end
        \\local before = 0
        \\for _ in pairs(set) do before = before + 1 end
        \\set[b] = nil
        \\local after, seen = 0, false
        \\for member in pairs(set) do after = after + 1 seen = seen or member == c end
        \\return tostring(before) .. " " .. tostring(after) .. " " .. tostring(seen)
    ));
}

test "table_key a key held only by its table survives a collection" {
    const state = try opened();
    defer api.nilu_close(state);
    _ = try answer(state, "kept = {} kept[{name = 'inside'}] = 'value' return ''");
    _ = api.nilu_settop(state, 0);
    state.collect();
    try std.testing.expectEqualStrings("inside value", try answer(state, "local k, v = next(kept) return k.name .. ' ' .. v"));
}

test "table_key a table key reaches __index and __newindex like any other" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("read:table wrote:boolean", try answer(state,
        \\local seen = {}
        \\local p = setmetatable({}, {
        \\  __index = function(_, k) return "read:" .. type(k) end,
        \\  __newindex = function(_, k) seen[#seen + 1] = "wrote:" .. type(k) end,
        \\})
        \\local r = p[{}]
        \\p[true] = 1
        \\return r .. " " .. seen[1]
    ));
}

test "table_key the C API's raw calls take a table key" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushvalue(state, 2));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "by identity"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_rawset(state, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushvalue(state, 2));
    try std.testing.expectEqual(api.Status.ok, api.nilu_rawget(state, 1));
    try std.testing.expectEqualStrings("by identity", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

// lua5.5 stores a float key with an integer value as that integer, so `next`
// answers an integer: past the range a value holds itself, the key is boxed.
test "table_key a float key with an integer value is stored as the integer, at any size" {
    const state = try opened();
    defer api.nilu_close(state);
    const source =
        \\local t = {[2^62] = "c"}
        \\t[3.0] = "a"
        \\t[2^50] = "b"
        \\rawset(t, -2^63, "d")
        \\local seen = {}
        \\for k, v in pairs(t) do seen[#seen + 1] = v .. ":" .. math.type(k) end
        \\table.sort(seen)
        \\return table.concat(seen, " ") .. "|" .. t[1125899906842624] .. t[4611686018427387904] .. t[math.mininteger]
    ;
    try std.testing.expectEqualStrings("a:integer b:integer c:integer d:integer|bcd", try answer(state, source));
}

// `get` and `set` with a key in a register take arms of their own
// (`getIndexed`, `setIndexed`), which find an integer key's slot once. Every
// other key, and a table the array part cannot answer for, still gives the
// general answers; they are lua5.5's.
test "table_key keys in registers give the general answers at every edge of the array part" {
    const state = try opened();
    defer api.nilu_close(state);
    const source =
        \\local function run()
        \\  local out = {}
        \\  local t = {}
        \\  for i = 1, 5 do t[i] = i * 10 end
        \\  t[0] = "zero"; t[-1] = "minus"; t[7] = "seven"; t[6] = "six"
        \\  t[2.0] = "two"; t[2^50] = "big"; t[3] = nil; t[3] = 30
        \\  local h = {x = 1}
        \\  h[1] = "a"; h[2] = "b"
        \\  local n = {}
        \\  n[1] = nil; n[1] = "one"
        \\  local m = setmetatable({}, {__newindex = function(tb, k, v) rawset(tb, k, v * 2) end, __index = function(_, k) return "miss" .. k end})
        \\  m[1] = 5
        \\  for i = -1, 8 do out[#out + 1] = tostring(t[i]) end
        \\  out[#out + 1] = tostring(t[2^50]) .. tostring(t[1.0]) .. tostring(t[2.5])
        \\  out[#out + 1] = tostring(h[1]) .. tostring(h[2]) .. #h
        \\  out[#out + 1] = tostring(n[1]) .. #n
        \\  out[#out + 1] = tostring(m[1]) .. tostring(m[2])
        \\  return table.concat(out, " ")
        \\end
        \\return run()
    ;
    try std.testing.expectEqualStrings("minus zero 10 two 30 40 50 six seven nil big10nil ab2 one1 10miss2", try answer(state, source));
}
