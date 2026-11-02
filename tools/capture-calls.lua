local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local chunks = {
  [=[return f()]=],
  [=[return (none())]=],
  [=[return f(1.0,nil,3.0,nil)]=],
  [=[return 8.0,two()]=],
  [=[return two(),8.0]=],
  [=[local a,b,c=two() return a,b,c]=],
  [=[local a,b,c=9.0,two() return a,b,c]=],
  [=[local a,b=1,2 a,b=two() return a,b]=],
  [=[two() none() return 7.0]=],
  [=[return two()+3.0]=],
  [=[return f(none())]=],
  [=[return f(two())]=],
  [=[return f(two(),9.0)]=],
  [=[return f(9.0,two())]=],
  [=[return f((two()))]=],
  [=[local t={8.0,two()} return t[1],t[2],t[3]]=],
  [=[local t={two(),8.0} return t[1],t[2],t[3]]=],
  [=[local t={8.0,none()} return #t]=],
  [=[return (f{})[1]]=],
  [=[return f "a\0b"]=],
  [=[return false and unknown()]=],
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
io.write("# Call results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; return count; comma-separated type:payload values.\n")
io.write("# Fresh environment with identity f, no-result none and two-result two script functions.\n")
for _, source in ipairs(chunks) do
  local environment = {f=function(...) return ... end, none=function() end, two=function() return 1.0,2.0 end}
  local chunk = assert(load(source, "<oracle>", "t", environment))
  local results = table.pack(chunk())
  local encoded = {}
  for i=1,results.n do encoded[i]=encode(results[i]) end
  io.write(hex(source), " ", results.n, " ", results.n == 0 and "-" or table.concat(encoded, ","), "\n")
end
