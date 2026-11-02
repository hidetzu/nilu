local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
local cases={
  {0,false},{0,true},{1999,false},{1999,true},
  {2000,false},{2000,true},{2001,false},{2001,true},
}
local function hex(bytes)
  return (bytes:gsub(".",function(byte)return string.format("%02x",string.byte(byte))end))
end
io.write("# Index-chain results captured from ",_VERSION," on ",date,".\n")
io.write("# Table-valued handler count; terminal key present; result class; binary64 bits or -.\n")
for _,case in ipairs(cases)do
  local t={}
  if case[2]then t.x=7.0 end
  for _=1,case[1]do t=setmetatable({},{__index=t})end
  local ok,result=pcall(function()return t.x end)
  local class,payload
  if not ok then
    assert(result:find("'__index' chain too long; possible loop",1,true),result)
    class,payload="runtime","-"
  elseif result==nil then class,payload="nil","-"
  else class,payload="number",hex(string.pack(">d",result))end
  io.write(case[1]," ",tostring(case[2])," ",class," ",payload,"\n")
end
