local date=assert(arg[1],"pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"),"pass the capture date as YYYY-MM-DD")
assert(_VERSION=="Lua 5.5","capture with Lua 5.5")
-- Lua 5.5's reserved words. This build accepts global as a name, as Nilu does.
local words={"and","break","do","else","elseif","end","false","for","function","goto","if","in",
  "local","nil","not","or","repeat","return","then","true","until","while"}
assert(load("local global=1"),"capture with a Lua 5.5 that accepts global as a name")
local forms={"return t[%s]","return t.%s","return {[%s]=1}","return {%s=1}","t[%s]=1","t:%s()"}
local function hex(s)return(s:gsub(".",function(c)return string.format("%02x",c:byte())end))end
io.write("# Reserved-word key parse results captured from ",_VERSION," on ",date,".\n")
io.write("# Input bytes in hex; parsed, or the message class and the token it is near.\n")
for _,form in ipairs(forms)do
  for _,word in ipairs(words)do
    local source=form:format(word)
    local chunk,message=load(source,"=x")
    if chunk then io.write(hex(source)," parsed\n")
    else
      local class,near=message:match("^x:1: (.-) near '(.*)'$")
      assert(class,message)
      if class=="unexpected symbol" then class="unexpected"
      else class=assert(class:match("^(.-) expected$"),message) class="expected:"..class:gsub("^'(.*)'$","%1")end
      io.write(hex(source)," ",class," ",near,"\n")
    end
  end
end
