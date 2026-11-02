local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
io.write("# Newindex-chain results captured from ",_VERSION," on ",date,".\n")
io.write("# Table-valued handler count; terminal key present; outcome.\n")
for _,count in ipairs({0,1999,2000,2001})do
  for _,present in ipairs({false,true})do
    local terminal={}
    if present then terminal.x=false end
    local root=terminal
    for _=1,count do root=setmetatable({},{__newindex=root})end
    local ok,result=pcall(function()root.x=7 end)
    local outcome
    if ok then assert(rawget(terminal,"x")==7); outcome="stored"
    else
      assert(result:find("'__newindex' chain too long; possible loop",1,true),result)
      if present then assert(rawget(terminal,"x")==false) else assert(rawget(terminal,"x")==nil)end
      outcome="runtime"
    end
    if count>0 then assert(rawget(root,"x")==nil)end
    io.write(count," ",tostring(present)," ",outcome,"\n")
  end
end
