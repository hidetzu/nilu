local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
local operators={{"__lt","<"},{"__le","<="},{"__lt",">"},{"__le",">="}}
local cases={}
local function handler(result,selected)
 return "global * return function(x,y) first=x.v second=y.v selected="..selected.." return "..result.." end"
end
for _,op in ipairs(operators)do
 for _,side in ipairs({"left","right","both"})do
  for _,result in ipairs({"","nil,true","false,true","0,false","''","{}","function()end","true"})do
   cases[#cases+1]={op[1],side,handler(result,11),handler(result,22),"local r=left "..op[2].." right return r,first,second,selected"}
  end
 end
 cases[#cases+1]={op[1],"both",handler("true",11),handler("false",22),"local n=0 local function take(i,x) n=n*10+i return x end local r=take(1,left) "..op[2].." take(2,right) return r,n,first,second,selected"}
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
io.write("# Direct order handlers captured from ",_VERSION," on ",date,".\n")
io.write("# Name; side; left handler hex; right handler hex; caller hex; count; values.\n")
for _,case in ipairs(cases)do
 local name,side,left_source,right_source,source=table.unpack(case)
 local env={left={v=2.0},right={v=3.0}}
 if side~="right" then setmetatable(env.left,{[name]=assert(load(left_source,"<left>","t",env))()})end
 if side~="left" then setmetatable(env.right,{[name]=assert(load(right_source,"<right>","t",env))()})end
 local results=table.pack(assert(load(source,"<caller>","t",env))())
 local values={}
 for i=1,results.n do values[i]=encode(results[i])end
 io.write(name," ",side," ",hex(left_source)," ",hex(right_source)," ",hex(source)," ",results.n," ",table.concat(values,","),"\n")
end
