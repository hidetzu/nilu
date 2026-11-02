local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
local operators={
 {"__add","+"},{"__sub","-"},{"__mul","*"},{"__div","/"},
 {"__idiv","//"},{"__mod","%"},{"__pow","^"},{"__concat",".."},
}
local cases={}
local lhs="return function(x,y) return 100+x.v*10+y.v,99 end"
local rhs="return function(x,y) return 200+x.v*10+y.v,99 end"
for _,op in ipairs(operators)do
 for _,side in ipairs({"left","right","both"})do
  cases[#cases+1]={op[1],side,lhs,rhs,"return left "..op[2].." right"}
 end
end
for _,body in ipairs({
 "return function(...) local args={...} return #args end",
 "return function(x,y) return x==y,99 end",
 "return function() return end",
})do cases[#cases+1]={"__unm","left",body,rhs,"return -left"}end
for _,result in ipairs({"", "nil,99", "false,99", "0,99", "'answer',99"})do
 cases[#cases+1]={"__add","left","return function() return "..result.." end",rhs,"return left+right,7"}
end
cases[#cases+1]={"__add","left","return function(x,y) return {v=x.v+y.v} end",rhs,"return (left+right).v"}
cases[#cases+1]={"__add","left","return function(x,y) return function() return x.v+y.v end end",rhs,"return (left+right)()"}
for _,op in ipairs({{"__concat",".."},{"__pow","^"},{"__sub","-"}})do
 local method="global * return function(x,y) log=log*10+(x==left and 1 or 2) return right end"
 cases[#cases+1]={op[1],"both",method,method,"local x=left "..op[2].." right "..op[2].." left return x==right,log"}
end
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
io.write("# Arithmetic/concat handlers captured from ",_VERSION," on ",date,".\n")
io.write("# Name; side; left handler hex; right handler hex; caller hex; count; values.\n")
for _,case in ipairs(cases)do
 local name,side,left_source,right_source,source=table.unpack(case)
 local env={left={v=2.0},right={v=3.0},log=0.0}
 if side~="right" then setmetatable(env.left,{[name]=assert(load(left_source,"<left>","t",env))()})end
 if side~="left" then setmetatable(env.right,{[name]=assert(load(right_source,"<right>","t",env))()})end
 local results=table.pack(assert(load(source,"<caller>","t",env))())
 local values={}
 for i=1,results.n do values[i]=encode(results[i])end
 io.write(name," ",side," ",hex(left_source)," ",hex(right_source)," ",hex(source)," ",results.n," ",table.concat(values,","),"\n")
end
