//! A `get`/`set` with a constant string key remembers the slot it found the
//! key in. It must still give the general answers when the table's hash part
//! grows or is rebuilt, when the instruction meets another table, when tables
//! are made and dropped, and when the key is dead. `next` likewise resumes
//! where it stopped and must answer as a search from the start would.
const std = @import("std");
const api = @import("c_api.zig");
const a = std.testing.allocator;

fn answer(source: [*:0]const u8) ![]const u8 {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadstring(state, source, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    return a.dupe(u8, std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "field_cache growth, other tables, dropped tables, dead keys and a rebuilt hash part" {
    const text = try answer(
        \\local out = {}
        \\local p = {x = 1}
        \\local function rx(t) return t.x end
        \\local function wx(t, v) t.x = v end
        \\out[#out + 1] = tostring(rx(p))
        \\for i = 1, 200 do p["k" .. tostring(i)] = i end
        \\wx(p, 7)
        \\out[#out + 1] = tostring(rx(p)) .. "," .. tostring(p["k150"])
        \\local q = {x = 2}
        \\out[#out + 1] = tostring(rx(q)) .. "," .. tostring(rx(p))
        \\wx(q, 3)
        \\out[#out + 1] = tostring(q.x) .. "," .. tostring(p.x)
        \\local sum = 0
        \\for i = 1, 300 do local t = {x = i, y = 0} wx(t, i * 2) sum = sum + rx(t) end
        \\out[#out + 1] = tostring(sum)
        \\local m = setmetatable({x = 5}, {__index = function(t, k) return "from index " .. k end})
        \\out[#out + 1] = tostring(rx(m))
        \\m.x = nil
        \\out[#out + 1] = tostring(rx(m))
        \\local d = {x = 1}
        \\for i = 1, 50 do d["d" .. tostring(i)] = i end
        \\for i = 1, 50 do d["d" .. tostring(i)] = nil end
        \\out[#out + 1] = tostring(rx(d))
        \\d.fresh = 9
        \\wx(d, 11)
        \\out[#out + 1] = tostring(rx(d)) .. "," .. tostring(d.fresh)
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("1|7,150|2,7|3,7|90300|5|from index x|1|11,9", text);
}

test "field_cache next resumes where it stopped and answers as a search from the start" {
    // Clearing the current field while traversing, a traversal nested in
    // another of the same table, next from a key other than the one last
    // returned, and next past a key cleared before it: each answer is the
    // one a search from the start of the hash part gives. The order itself is
    // unspecified (manual 4.5): only that `next` from each key answers the key
    // the traversal gave after it is asserted.
    const text = try answer(
        \\local out = {}
        \\local t = {}
        \\for i = 1, 40 do t["k" .. tostring(i)] = i end
        \\local seen, sum = 0, 0
        \\for k, v in pairs(t) do seen = seen + 1 sum = sum + v t[k] = nil end
        \\out[#out + 1] = tostring(seen) .. "," .. tostring(sum) .. "," .. tostring(next(t))
        \\local u = {a = 1, b = 2, c = 3, d = 4}
        \\local pairsCount = 0
        \\for k1 in pairs(u) do for k2 in pairs(u) do pairsCount = pairsCount + 1 end end
        \\out[#out + 1] = tostring(pairsCount)
        \\local order = {}
        \\for k in pairs(u) do order[#order + 1] = k end
        \\local agree = 0
        \\for i = #order, 1, -1 do if next(u, order[i]) == order[i + 1] then agree = agree + 1 end end
        \\out[#out + 1] = tostring(#order) .. ":" .. tostring(agree)
        \\local w = {x = 1, y = 2, z = 3}
        \\local k1 = next(w)
        \\w[k1] = nil
        \\local rest = 0
        \\local k = k1
        \\while true do k = next(w, k) if k == nil then break end rest = rest + 1 end
        \\out[#out + 1] = tostring(rest)
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("40,820,nil|16|4:4|2", text);
}

test "field_cache a global's assignment through _ENV's cell keeps the general answers" {
    const text = try answer(
        \\local out = {}
        \\local e = {}
        \\load("x = 3 for i = 1, 3 do x = x + 1 end", "c", "t", e)()
        \\out[#out + 1] = tostring(e.x) .. "," .. tostring(x)
        \\local ok, message = pcall(load("x = 1", "c", "t", 5))
        \\out[#out + 1] = tostring(ok) .. "," .. message
        \\local doubled = setmetatable({}, {__newindex = function(t, k, v) rawset(t, k, v * 2) end})
        \\load("z = 4 z = 5", "c", "t", doubled)()
        \\out[#out + 1] = tostring(rawget(doubled, "z"))
        \\local k
        \\local failed, nil_key = pcall(function() return {[k] = 1} end)
        \\out[#out + 1] = tostring(failed) .. "," .. nil_key
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("6,nil|false,[string \"c\"]:1: attempt to index a number value (upvalue '_ENV')|5|false,[string \"local out = {}...\"]:11: table index is nil", text);
}

test "field_cache a new key stored through a missed cache is the one later reads and writes find" {
    const text = try answer(
        \\local out = {}
        \\local function fill(t, i) t.a = i t.b = i + 1 t.c = i + 2 t.d = i + 3 t.e = i + 4 end
        \\local function bump(t) t.c = t.c * 10 end
        \\local sum = 0
        \\for i = 1, 50 do
        \\  local t = (i % 3 == 0) and {z = 0} or {}
        \\  fill(t, i)
        \\  bump(t)
        \\  local keys = 0
        \\  for _ in pairs(t) do keys = keys + 1 end
        \\  sum = sum + t.a + t.b + t.c + t.d + t.e + keys
        \\end
        \\out[#out + 1] = tostring(sum)
        \\local g = {}
        \\for i = 1, 40 do g["k" .. tostring(i)] = i end
        \\fill(g, 100)
        \\out[#out + 1] = tostring(g.a) .. "," .. tostring(g.e) .. "," .. tostring(g.k40)
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("19516|100,104,40", text);
}

test "field_cache a method found through its class's __index table, and the general answers around it" {
    // The answers are lua5.5's. `own` meets a receiver without the key and
    // one holding it, a class that holds the key and then not, and an
    // __index function.
    const text = try answer(
        \\local Base = {inherited = 1}
        \\local C = setmetatable({own = 2}, {__index = Base})
        \\C.__index = C
        \\local plain, holder = setmetatable({}, C), setmetatable({own = 3}, C)
        \\local viaFunction = setmetatable({}, {__index = function(_, key) return key .. "!" end})
        \\local out = {}
        \\local function own(o) return o.own end
        \\for i = 1, 2 do
        \\  for _, o in ipairs({plain, holder, plain}) do out[#out + 1] = own(o) end
        \\  out[#out + 1] = plain.inherited
        \\  out[#out + 1] = tostring(plain.missing)
        \\  out[#out + 1] = own(viaFunction)
        \\end
        \\C.own = nil
        \\out[#out + 1] = tostring(own(plain))
        \\Base.own = 4
        \\out[#out + 1] = own(plain)
        \\plain.own = 5
        \\out[#out + 1] = own(plain)
        \\return table.concat(out, " ")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("2 3 2 1 nil own! 2 3 2 1 nil own! nil 4 5", text);
}

test "field_cache a table's smallest hash part, rebuilt where it stands, keeps its keys" {
    // The answer is lua5.5's. Keys 2 and 3 move from the hash part to the
    // array when 1 arrives and leave their marks, so the third field makes
    // the four-slot part rebuild at the same size, in the table's own room.
    const text = try answer(
        \\local t = {}
        \\t[2] = "b" t[3] = "c" t[1] = "a"
        \\t.x = "x" t.y = "y" t.z = "z"
        \\return table.concat({t[1], t[2], t[3], t.x, t.y, t.z, #t}, ",")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("a,b,c,x,y,z,3", text);
}

// A constructor's tables start from a copy of its template: its constant
// string keys with nil values. Each must still hold only what was stored,
// whatever else the constructor does and whatever is done to it afterwards;
// the answers are lua5.5's.
test "field_cache tables a constructor makes from its template hold what each stored, and no more" {
    const text = try answer(
        \\local out = {}
        \\local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
        \\local function f(i) return i * 10 end
        \\local sum, fields = 0, 0
        \\for i = 1, 50 do
        \\  local maybe = (i % 2 == 0) and i or nil
        \\  local t = {a = i, b = maybe, c = f(i), a = i + 1, [i] = "x", d = {e = i}, "list"}
        \\  sum = sum + t.a + t.c + t.d.e + (t.b or 0)
        \\  fields = fields + count(t)
        \\end
        \\out[#out + 1] = sum .. " " .. fields
        \\local t = {p = 1, q = 2, r = 3, s = 4, u = 5}
        \\t.p, t.q = nil, nil
        \\for i = 1, 40 do t["k" .. tostring(i)] = i end
        \\t.r = nil
        \\out[#out + 1] = count(t) .. " " .. tostring(t.s) .. " " .. tostring(t.p) .. " " .. tostring(rawget(t, "q"))
        \\local ok, message = pcall(function() local x = {m = 1, n = error("stop"), o = 3} end)
        \\out[#out + 1] = tostring(ok) .. " " .. message:match(": (.*)$")
        \\local s = {g = nil, h = nil}
        \\out[#out + 1] = tostring(next(s)) .. " " .. count(s) .. " " .. #s
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("16000 274|42 4 nil nil|false stop|nil 0 0", text);
}
