local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
-- Each case: relays (tables carrying __call before the terminal), the terminal
-- kind, and the chunk. Lua refuses a 16th fetch and Nilu a 2001st, so the
-- relay counts stay at most 15 and the limit is exercised through cycles.
local cases = {
  {0, "fn", [=[local a,b=t({id="arg"}) return a,b]=]},
  {1, "fn", [=[local a,b=t({id="arg"}) return a,b]=]},
  {2, "fn", [=[local a,b=t({id="arg"}) return a,b]=]},
  {3, "fn", [=[local a,b=t({id="arg"},{id="arg2"}) return a,b]=]},
  {14, "fn", [=[local a,b=t({id="arg"}) return a,b]=]},
  {15, "fn", [=[local a,b=t({id="arg"}) return a,b]=]},
  {2, "fn", [=[return t({id="arg"})]=]},
  {15, "fn", [=[return t({id="arg"})]=]},
  {2, "fn", [=[local function f(...) return t(...) end return f({id="arg"})]=]},
  {2, "fn", [=[for k,v in t,{id="s"},{id="c"} do return k,v end]=]},
  {2, "fn", [=[local a,b=t() return a,b]=]},
  {1, "false", [=[local a=t() return a]=]},
  {2, "false", [=[local a=t() return a]=]},
  {2, "false", [=[return t()]=]},
  {2, "false", [=[for k in t do end]=]},
  {2, "number", [=[local a=t() return a]=]},
  {2, "string", [=[local a=t() return a]=]},
  {1, "nocall", [=[local a=t() return a]=]},
  {3, "nocall", [=[local a=t() return a]=]},
  {1, "index", [=[local a=t() return a]=]},
  {1, "self", [=[local a=t() return a]=]},
  {2, "self", [=[return t()]=]},
  {2, "self", [=[for k in t do end]=]},
  {2, "mutual", [=[local a=t() return a]=]},
}
local function hex(bytes)
  return (bytes:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
local function encode(value)
  local kind = type(value)
  local payload
  if kind == "number" then
    if math.type(value) == "integer" then value = value + 0.0 end
    payload = value ~= value and "nan" or hex(string.pack(">d", value))
  elseif kind == "string" then payload = value == "" and "-" or hex(value)
  elseif kind == "boolean" then payload = tostring(value)
  elseif kind == "nil" then payload = "-"
  else error("capture must return primitive values") end
  return kind .. ":" .. payload
end
local function build(relays, terminal)
  local fn = function(...)
    local r = {...}
    local s = ""
    for i = 1, #r do s = s .. r[i].id .. "," end
    return #r, s
  end
  local last
  if terminal == "fn" then last = fn
  elseif terminal == "false" then last = false
  elseif terminal == "number" then last = 5.0
  elseif terminal == "string" then last = "s"
  elseif terminal == "nocall" then last = setmetatable({id = "end"}, {})
  elseif terminal == "index" then last = setmetatable({id = "end"}, setmetatable({}, {__index = {__call = fn}}))
  elseif terminal == "self" then last = setmetatable({id = "loop"}, {}) getmetatable(last).__call = last
  elseif terminal == "mutual" then
    local a, b = setmetatable({id = "a"}, {}), setmetatable({id = "b"}, {})
    getmetatable(a).__call = b
    getmetatable(b).__call = a
    last = a
  else error("unknown terminal " .. terminal) end
  local current = last
  for i = relays, 1, -1 do current = setmetatable({id = "t" .. (i - 1)}, {__call = current}) end
  return current
end
io.write("# Call chains captured from ", _VERSION, " on ", date, ".\n")
io.write("# Relays; terminal; chunk hex; return count or 'error'; values, or the message after its position.\n")
io.write("# Fresh environment with t built by relays tables whose __call is the next value and the terminal last.\n")
for _, case in ipairs(cases) do
  local relays, terminal, source = case[1], case[2], case[3]
  local environment = {t = build(relays, terminal)}
  local chunk = assert(load(source, "=spec", "t", environment))
  local results = table.pack(pcall(chunk))
  if results[1] then
    local encoded = {}
    for i = 2, results.n do encoded[#encoded + 1] = encode(results[i]) end
    io.write(relays, " ", terminal, " ", hex(source), " ", results.n - 1, " ", results.n == 1 and "-" or table.concat(encoded, ","), "\n")
  else
    local message = assert(results[2]:match("^spec:%d+: (.*)$"), results[2])
    io.write(relays, " ", terminal, " ", hex(source), " error ", hex(message), "\n")
  end
end
