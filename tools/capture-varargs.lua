local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local chunks = {
  [=[return ...]=],
  [=[return (...)]=],
  [=[return ...,9]=],
  [=[local x=8 return x,...]=],
  [=[return ...,...]=],
  [=[local a,b,c,d=... return a,b,c,d]=],
  [=[local a,b,c=...,9 return a,b,c]=],
  [=[local a,b,c=9,... return a,b,c]=],
  [=[local a,b=(...) return a,b]=],
  [=[local a,b,c a,b,c=... return a,b,c]=],
  [=[global a,b,c=... return a,b,c]=],
  [=[global a,b a,b=... return a,b]=],
  [=[local a=9,... return a]=],
  [=[local t={8,...} return t[1],t[2],t[3],t[4],t[5],t[6]]=],
  [=[local t={...,8} return t[1],t[2],t[3]]=],
  [=[local t={(...)} return t[1],t[2]]=],
  [=[local t={...,x=8} return t[1],t[2],t.x]=],
  [=[local t={x=8,...,} return t.x,t[1],t[3]]=],
  [=[local t={a={...},...} return t.a[3],t[3]]=],
  [=[local n=0 ::again:: local t={...} n=n+1 if n<3 then goto again end return n,...]=],
}
local arguments = {
  table.pack(), table.pack(1.0), table.pack(1.0,nil,3.0,nil),
  table.pack(nil,nil), table.pack(false,"a\0b",true), table.pack(-0.0,0/0,1/0),
}
local function hex(bytes)
  return (bytes:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
local function encode(values)
  local encoded = {}
  for i=1,values.n do
    local value = values[i]
    local kind = type(value)
    local payload
    if kind == "number" then
      if math.type(value) == "integer" then value = value + 0.0 end
      payload = value ~= value and "nan" or hex(string.pack(">d",value))
    elseif kind == "string" then payload = value == "" and "-" or hex(value)
    elseif kind == "boolean" then payload = tostring(value)
    elseif kind == "nil" then payload = "-"
    else error("capture must use primitive values") end
    encoded[i] = kind .. ":" .. payload
  end
  return values.n == 0 and "-" or table.concat(encoded,",")
end
io.write("# Vararg results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; argument count; encoded arguments; return count; encoded returns.\n")
io.write("# Types use binary64 bits/string bytes in hex, boolean, nan, or -. Fresh empty environments.\n")
for _, source in ipairs(chunks) do
  for _, args in ipairs(arguments) do
    local chunk = assert(load(source,"<oracle>","t",{}))
    local results = table.pack(chunk(table.unpack(args,1,args.n)))
    io.write(hex(source)," ",args.n," ",encode(args)," ",results.n," ",encode(results),"\n")
  end
end
