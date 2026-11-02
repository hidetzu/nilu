//! Operands read in place and values assigned straight into a local must give
//! the answers the general form gives: a failing operator or call leaves the local it
//! would have assigned as it was, and an operand evaluated before a call keeps
//! the value it had then.
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

test "compiler_operand a failing operator leaves the assigned local as it was" {
    // `s = r + t` with locals on both sides writes `s` once, after the operator
    // succeeded; the closure sees `s` through its cell after the frame unwound.
    const text = try answer(
        \\local get
        \\local function f()
        \\  local s, r, t = 5, 9, {}
        \\  get = function() return s end
        \\  s = r + t
        \\end
        \\local ok, message = pcall(f)
        \\return tostring(ok) .. "|" .. tostring(get()) .. "|" .. message
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("false|5|[string \"local get...\"]:5: attempt to perform arithmetic on a table value (local 't')", text);
}

test "compiler_operand an operand read before a call keeps the value it had" {
    // The left operand is read before `bump` runs, as in the general form;
    // only the right operand of an in-place operator may be read late, and it
    // is read after everything to its left has run anyway.
    const text = try answer(
        \\local a = 1
        \\local function bump() a = 10 return 0 end
        \\a = a + bump()
        \\local b = 2
        \\local function late() b = 20 return 1 end
        \\local c = late() + b
        \\return tostring(a) .. "|" .. tostring(c)
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("1|21", text);
}

test "compiler_operand a call assigned to a local writes it once, after the call returned" {
    // `s = t()` fails before `s` is written; `u = g()` keeps the value `g`
    // wrote to `u` only until the result lands; no result is nil and extra
    // results are dropped, as through a temporary.
    const text = try answer(
        \\local get
        \\local function f()
        \\  local s, t = 5, {}
        \\  get = function() return s end
        \\  s = t()
        \\end
        \\local ok, message = pcall(f)
        \\local u = 1
        \\local function g() u = 7 return u + 1 end
        \\u = g()
        \\local function none() end
        \\local w = 3
        \\w = none()
        \\local function two() return 8, 9 end
        \\local x = 0
        \\x = two()
        \\return tostring(ok) .. "|" .. tostring(get()) .. "|" .. message .. "|" .. tostring(u) .. "|" .. tostring(w) .. "|" .. tostring(x)
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("false|5|[string \"local get...\"]:5: attempt to call a table value (local 't')|8|nil|8", text);
}

test "compiler_operand stores, right operands, call results and conditions keep their answers" {
    // A single store of locals and literals is one instruction; a right
    // operand that is a local is still read after the left one ran; a call's
    // result lands in a temporary with nil for a missing one; a comparison's
    // register is not cleared. The answers are those of the general forms.
    const text = try answer(
        \\local out = {}
        \\local log = {}
        \\local p = setmetatable({}, {__newindex = function(t, k, v) log[#log + 1] = tostring(k) .. "=" .. tostring(v) end})
        \\local k, v = "key", 5
        \\p[k] = v
        \\p.name = "n"
        \\p[1] = true
        \\out[#out + 1] = table.concat(log, ",")
        \\local x = 1
        \\local function f() x = 10 return 2 end
        \\out[#out + 1] = tostring(f() + x)
        \\local function g() return 3, 4 end
        \\local function none() end
        \\local t = {}
        \\t.a = g() + 1
        \\t.b = (none())
        \\out[#out + 1] = tostring(t.a) .. "," .. tostring(t.b)
        \\local c = 0
        \\for i = 1, 3 do if i < 2 then c = c + 1 elseif i == 2 then c = c + 10 else c = c + 100 end end
        \\out[#out + 1] = tostring(c)
        \\local ok, m = pcall(function() local q local j = 1 q[j] = 1 end)
        \\out[#out + 1] = m
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("key=5,name=n,1=true|12|4,nil|111|[string \"local out = {}...\"]:21: attempt to index a nil value (local 'q')", text);
}

test "compiler_operand a left local is read first wherever the function holds a closure" {
    // A closure anywhere in the function may capture the local and change
    // it while the right operand runs; each place a function can be written
    // keeps the left operand read before it. Each case is a function of its
    // own, holding its one closure, in an expression or an assignment.
    const text = try answer(
        \\local function field()
        \\  local s = 1
        \\  local t = {f = function() s = 10 return 0 end}
        \\  return s + t.f()
        \\end
        \\local function item()
        \\  local s = 2
        \\  local t = {function() s = 20 return 0 end}
        \\  s = s + t[1]()
        \\  return s
        \\end
        \\local function arm()
        \\  local s, set = 3, nil
        \\  if true then set = function() s = 30 return 0 end end
        \\  return s + set()
        \\end
        \\local function body()
        \\  local s, set = 4, nil
        \\  for i = 1, 1 do set = function() s = 40 return 0 end end
        \\  s = s + set()
        \\  return s
        \\end
        \\local function values()
        \\  local s, set = 5, nil
        \\  for _, f in next, {function() s = 50 return 0 end} do set = f end
        \\  return s + set()
        \\end
        \\return field() .. " " .. item() .. " " .. arm() .. " " .. body() .. " " .. values()
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("1 2 3 4 5", text);
}

test "compiler_operand a left local read in place in a function without closures gives lua5.5's answers" {
    // No closure can capture these locals, so reading the left one after the
    // right operand ran gives what reading it first gives.
    const text = try answer(
        \\local t, s, w = {5, 6, 7}, 0, "a"
        \\for i = 1, #t do s = s + t[i] end
        \\local d = s - tonumber("4")
        \\w = w .. t[2] .. w
        \\local ok, message = pcall(error, "x")
        \\local n = s * #t
        \\return s .. " " .. d .. " " .. w .. " " .. n .. " " .. tostring(s < t[1])
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("18 14 a6a 54 false", text);
}

// Field and index reads, and field and global stores, that take their key in
// place, without a register of its own, must give the answers the general
// form gives: the key is read after the receiver is evaluated, a store still
// evaluates its receiver before its value, a handler sees the access already
// made, and a failure still names the receiver.

test "compiler_field a local key is read after the receiver is evaluated" {
    // `f()[i]` reads `i` after `f` changed it, as Lua 5.5 does; `k = g()[k]`
    // evaluates the receiver before the key's own register is written.
    const text = try answer(
        \\local i = 1
        \\local t = {10, 20}
        \\local function f() i = 2 return t end
        \\local v = f()[i]
        \\local k = 1
        \\local u = {7}
        \\local function g() return u end
        \\k = g()[k]
        \\return tostring(v) .. "|" .. tostring(k)
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("20|7", text);
}

test "compiler_field a handler that rebinds the local receiver gets the key it was asked for" {
    const text = try answer(
        \\local t
        \\t = setmetatable({}, {__index = function(self, key) t = nil return key end})
        \\local v = t.name
        \\return tostring(v) .. "|" .. tostring(t)
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("name|nil", text);
}

test "compiler_field failures name the receiver of a field, an index, a method and a global" {
    const text = try answer(
        \\local out = {}
        \\local n
        \\local function h1() local m return m.x end
        \\local function h2() local m return m:go() end
        \\local function h3() local m local k = "z" return m[k] end
        \\local function h4() local s = {} return s[1].x end
        \\local function h5() return n:go() end
        \\local function h6() return missing.x end
        \\for _, f in ipairs({h1, h2, h3, h4, h5, h6}) do local ok, m = pcall(f) out[#out + 1] = m end
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings(
        "[string \"local out = {}...\"]:3: attempt to index a nil value (local 'm')|" ++
            "[string \"local out = {}...\"]:4: attempt to index a nil value (local 'm')|" ++
            "[string \"local out = {}...\"]:5: attempt to index a nil value (local 'm')|" ++
            "[string \"local out = {}...\"]:6: attempt to index a nil value (field '?')|" ++
            "[string \"local out = {}...\"]:7: attempt to index a nil value (upvalue 'n')|" ++
            "[string \"local out = {}...\"]:8: attempt to index a nil value (global 'missing')",
        text,
    );
}

test "compiler_field a store evaluates its receiver and key before its value" {
    // Lua 5.5 writes `t.x = f()` into the table `f` put in `t` and `old[k] = g()`
    // under the key `g` set; Nilu evaluates the receiver and the key first, and
    // a constant key does not change that.
    const text = try answer(
        \\local t = {}
        \\local old = t
        \\local function f() t = {} return 1 end
        \\t.x = f()
        \\local k = "a"
        \\local function g() k = "b" return 2 end
        \\old[k] = g()
        \\return tostring(old.x) .. "|" .. tostring(t.x) .. "|" .. tostring(old.a) .. "|" .. tostring(old.b)
    );
    defer a.free(text);
    try std.testing.expectEqualStrings("1|nil|2|nil", text);
}

test "compiler_field stores name their receiver and run handlers right to left" {
    const text = try answer(
        \\local out = {}
        \\local n
        \\local function h1() local m m.x = 1 end
        \\local function h2() n.x = 1 end
        \\local function h3() missing.x = 1 end
        \\local function h4() local s = {} s[1].x = 1 end
        \\for _, f in ipairs({h1, h2, h3, h4}) do local ok, m = pcall(f) out[#out + 1] = m end
        \\local log = {}
        \\local p = setmetatable({}, {__newindex = function(t, k, v) log[#log + 1] = k .. "=" .. tostring(v) end})
        \\p.a, p.b = 1, 2
        \\g1 = 5
        \\local c = {x = 1, y = g1, ["z"] = 3}
        \\out[#out + 1] = table.concat(log, ",") .. ";" .. tostring(g1) .. ";" .. tostring(c.x) .. tostring(c.y) .. tostring(c.z)
        \\return table.concat(out, "|")
    );
    defer a.free(text);
    try std.testing.expectEqualStrings(
        "[string \"local out = {}...\"]:3: attempt to index a nil value (local 'm')|" ++
            "[string \"local out = {}...\"]:4: attempt to index a nil value (upvalue 'n')|" ++
            "[string \"local out = {}...\"]:5: attempt to index a nil value (global 'missing')|" ++
            "[string \"local out = {}...\"]:6: attempt to index a nil value (field '?')|" ++
            "b=2,a=1;5;153",
        text,
    );
}
