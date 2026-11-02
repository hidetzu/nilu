local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
local cases={
 {"__index",0,"return function(t,k) return t.own,99 end","return t.x,8"},
 {"__index",1,"return function(t,k) return t.own,99 end","return t.x,8"},
 {"__index",0,"return function(t,k) return end","return t.x,8"},
 {"__index",0,"return function(t,k) return nil,99 end","return t.x,8"},
 {"__index",0,"return function(t,k) return false,99 end","return t.x,8"},
 {"__index",0,"return function(t,k) return k end","return t.x,t[5]"},
 {"__index",1,"return function(t,k) return function(self,x) return t.own,self.own,x end end","return t:m(7)"},
 {"__index",0,"return function(t,k) return function() return t.own end end","local f=t.x return f()"},
 {"__index",0,"return function(...) local t={...} return #t end","return t.x"},
 {"__index",0,"return function(t,k) local function f(n) if n==0 then return t.own end return f(n-1) end return f(300) end","return t.x"},
 {"__newindex",0,"global * return function(t,k,v) seen=t.own+v key=k return 99,88 end","do local _ENV=t x=7 end return seen,key,t.x"},
 {"__newindex",1,"global * return function(t,k,v) seen=t.own+v key=k end","do local _ENV=t x=7 end return seen,key,t.x"},
 {"__newindex",0,"global * return function(t,k,v) seen=k end","do local _ENV=t own=1 end return t.own,seen"},
 {"__newindex",0,"global * return function(t,k,v) seen=k end","do local _ENV=t x=nil end return t.x,seen"},
 {"__newindex",0,"global * return function(...) local t={...} seen=#t end","do local _ENV=t x=7 end return seen"},
}
local function hex(bytes)
 return (bytes:gsub(".",function(byte)return string.format("%02x",string.byte(byte))end))
end
local function encode(value)
 local kind=type(value)
 local payload
 if kind=="number" then payload=hex(string.pack(">d",value+0.0))
 elseif kind=="string" then payload=value=="" and "-" or hex(value)
 elseif kind=="boolean" then payload=tostring(value)
 elseif kind=="nil" then payload="-"
 else error("capture must return primitive values")end
 return kind..":"..payload
end
io.write("# Script index handlers captured from ",_VERSION," on ",date,".\n")
io.write("# Handler name; links; handler chunk hex; caller chunk hex; result count; values.\n")
for _,case in ipairs(cases)do
 local name,links,handler_source,source=table.unpack(case)
 local env={}
 local method=assert(load(handler_source,"<handler>","t",env))()
 local leaf={own=links==0 and 9.0 or 11.0}
 setmetatable(leaf,{[name]=method})
 local root=leaf
 for _=1,links do root=setmetatable({own=9.0},{[name]=root})end
 env.t=root
 local results=table.pack(assert(load(source,"<caller>","t",env))())
 local values={}
 for i=1,results.n do values[i]=encode(results[i])end
 io.write(name," ",links," ",hex(handler_source)," ",hex(source)," ",results.n," ",table.concat(values,","),"\n")
end
