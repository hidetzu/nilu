local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local chunks = {
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n,sum=0,0 for k,v in step,3 do n=n+1 sum=sum+k+v end return n,sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 for k in step,3,1 do n=n+k end return n]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 for k,v,x in step,2 do if x~=nil then return 99 end n=n+k+v end return n]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 local function factory() n=n+1 return step,3,nil end local sum=0 for k in factory() do sum=sum+k end return n,sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local k=2 local sum=0 for k in step,k do sum=sum+k end return k,sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local f,s=step,3 local n=0 for k in f,s do f=nil s=0 n=n+1 end return n]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local sum=0 for k,v in step,2 do v=v+1 sum=sum+v end return sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local sum=0 for k in step,2 do local k=9 sum=sum+k end return sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local sum=0 for x,x in step,2 do x=x+1 sum=sum+x end return sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local a,b for k,v in step,2 do local x=v if k==1 then a=function() return x end else b=function() return x end end end return a(),b()]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local f for k,v in step,9 do local x,y=k,v f=function() return x,y end break end return f()]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end for k,v in step,3 do if k==2 then return v end end]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local sum=0 for k in step,3 do if k==2 then goto continue end local x=k sum=sum+x ::continue:: end return sum]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local f for k,v in step,3 do local x,y=k,v f=function() return x,y end goto done end ::done:: return f()]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 for k in step,3 do for j in step,2 do n=n+1 break end end return n]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 for k in step,2 do for i=1.0,2.0 do n=n+1 end end return n]=],
  [=[local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end local n=0 repeat for k in step,3 do n=n+1 break end until n==2 return n]=],
  [=[local function f() return nil,7 end local n=0 for k,v in f do n=n+1 end return n]=],
  [=[local function f() end local n=0 for k in f do n=n+1 end return n]=],
  [=[local function f(s,k) if k==nil then return false elseif k==false then return 0 end end local n=0 for k in f do n=n+1 if n>3 then break end end return n]=],
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
io.write("# Generic-for results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; return count; comma-separated type:payload values.\n")
io.write("# Fresh empty environments; script iterators return no fourth closing value.\n")
for _, source in ipairs(chunks) do
  local chunk = assert(load(source, "<oracle>", "t", {}))
  local results = table.pack(chunk())
  local encoded = {}
  for i=1,results.n do encoded[i]=encode(results[i]) end
  io.write(hex(source), " ", results.n, " ", results.n == 0 and "-" or table.concat(encoded, ","), "\n")
end
