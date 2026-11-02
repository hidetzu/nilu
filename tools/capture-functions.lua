local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local chunks = {
  [=[local function f(a,b) return a,b end return f(1)]=],
  [=[local function f(a,b) return a,b end return f(1,2,3)]=],
  [=[local function f(a,b,...) return a,b,... end return f(1)]=],
  [=[local function f(a,b,...) return a,b,... end return f(1,2,nil,4,nil)]=],
  [=[local f=function(a,b,...) local t={...} return a,b,t[1],t[2] end return f(1,2,3,4)]=],
  [=[return (function() return 7 end)(1,2)]=],
  [=[return (function(a,a) return a end)(1,2)]=],
  [=[local t={v=2,m=function(self,x) return self.v+x end} return t:m(3)]=],
  [=[local function invoke(f) return f() end local function outer(x) return invoke(function() return x end) end return outer(7)]=],
  [=[local function fact(n) if n<2 then return 1 end return n*fact(n-1) end return fact(5)]=],
  [=[local f function f() return 7 end return f()]=],
  [=[function f() return 8 end return f()]=],
  [=[local f=9 global function f(n) if n==0 then return 1 end return f(n-1) end return f(300)]=],
  [=[local function f(n) if n==0 then return 7 end return f(n-1) end return f(1000)]=],
  [=[local function make(n) return function(d) n=n+d return n end end local a,b=make(0),make(10) return a(2),a(3),b(4)]=],
  [=[local x=0 local function add() x=x+1 end local function get() return x end add() add() return get()]=],
  [=[local x=1 local f=function() return x end x=9 return f()]=],
  [=[local f do local x=7 f=function() return x end end local x=99 return f()]=],
  [=[local x=1 local function middle() return function() x=x+1 return x end end local f=middle() return f(),f()]=],
  [=[local x=1 local f=function() return x end local x=2 return f(),x]=],
  [=[local _ENV={x=1} local f=function() return x end _ENV={x=9} return f()]=],
  [=[local _ENV={x=2} local function middle() return function() return x end end local f=middle() return f()]=],
  [=[local x=1 global x=7 local f=function() return x end return f()]=],
  [=[local function f(_ENV) return x end return f({x=8})]=],
  [=[local _ENV={} local function set() x=7 end set() return x]=],
  [=[local a,b,c for i=1.0,3.0 do if i==1 then a=function() return i end elseif i==2 then b=function() return i end else c=function() return i end end end return a(),b(),c()]=],
  [=[local a,b local n=0 while n<2 do local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 end return a(),b()]=],
  [=[local a,b local n=0 repeat local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 until n==2 return a(),b()]=],
  [=[local a,b local n=0 ::again:: local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 if n<2 then goto again end return a(),b()]=],
  [=[local f for i=1.0,9.0 do local x=7 f=function() return i,x end break end return f()]=],
  [=[local f=function() return 1 end local g=function() return 1 end return f==f,f==g]=],
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
io.write("# Function results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; return count; comma-separated type:payload values.\n")
io.write("# Each chunk starts with an empty environment; source functions and captures return primitives.\n")
for _, source in ipairs(chunks) do
  local chunk = assert(load(source, "<oracle>", "t", {}))
  local results = table.pack(chunk())
  local encoded = {}
  for i=1,results.n do encoded[i]=encode(results[i]) end
  io.write(hex(source), " ", results.n, " ", results.n == 0 and "-" or table.concat(encoded, ","), "\n")
end
