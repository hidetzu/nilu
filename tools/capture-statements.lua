local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local chunks = {
  [=[local x=1 local y local a,b=10,20 return x,y,a,b]=],
  [=[local a,b,c=1,2 local d,e=1,2,3 return a,b,c,d,e]=],
  [=[local x=3 local x,y=x+1,x+2 return x,y]=],
  [=[local x=1 local x=2 return x]=],
  [=[local global=8 return global]=],
  [=[local <const> a,b=1,2 return a,b]=],
  [=[local a,b=1,2 a,b=b,a return a,b]=],
  [=[local x=5 x=1+x return x]=],
  [=[local a,b=9,8 a,b=1 return a,b]=],
  [=[local a=1 a=2,3 return a]=],
  [=[g=10 return g,h]=],
  [=[local count=0 cuont=count+1 return count,cuont]=],
  [=[global count count=0 count=count+1 return count]=],
  [=[local x=1 global x x=2 return x,_ENV.x]=],
  [=[local x=1 global * x=2 return x,_ENV.x]=],
  [=[local x='outer' do local x='inner' end return x]=],
  [=[do local y=1 end return y]=],
  [=[local n=2 local x=0 if n==1 then local n=8 x=1 elseif n==2 then local n=9 x=n else x=3 end return n,x]=],
  [=[if false then return 1 elseif true then return 2 else return 3 end]=],
  [=[local x=0 if nil then x=1 end if 0 then x=x+2 end if '' then x=x+3 end return x]=],
  [=[do global x x=1 end y=2 return x,y]=],
  [=[local x=0 if false then local y=1+nil else x=7 end return x]=],
  [=[local i=0 while i<3 do i=i+1 end return i]=],
  [=[local i=0 while false do i=i+1 end return i]=],
  [=[local i,n=0,0 while i<3 do i=i+1 while true do n=n+1 break n=99 end end return i,n]=],
  [=[local i=0 while true do do local x=4 if x==4 then break end end i=99 end return i]=],
  [=[while true do local x=3 return x end]=],
  [=[local n=0 while n<3 do local x n=n+1 if x~=nil then return 99 end x=2 end return n]=],
  [=[local n=0 repeat n=n+1 local done=n>=3 until done return n]=],
  [=[local n=0 repeat n=n+1 until true return n]=],
  [=[local n=0 repeat local x n=n+1 if x~=nil then return 99 end x=3 until n==3 return n,x]=],
  [=[local n=0 repeat do local x=8 if x==8 then break end end n=99 until false return n]=],
  [=[local n=0 while n<3 do repeat n=n+1 break until false end return n]=],
  [=[local x=0 repeat local x=1 until x==1 return x]=],
  [=[x=1 local root=_ENV local _ENV={} x=2 return x,root.x]=],
  [=[x=1 local root=_ENV do local _ENV={x=3} x=4 end return x,root.x]=],
  [=[local _ENV <const> = {} x=5 return x]=],
  [=[global x local _ENV={} x=3 return x]=],
  [=[_ENV={x=7} return x]=],
  [=[global a,b=1,2 return a,b]=],
  [=[global a,b=1 return a,b]=],
  [=[local x=3 global x=x+1 return x]=],
  [=[global x <const> = 3 return x]=],
  [=[local n=0 repeat n=n+1 if n==2 then break end until n==9 return n]=],
  [=[local n=0 if false then n=1 elseif false then n=2 end return n]=],
  -- Explicit float bounds select Lua's float path, including large counters.
  [=[local n,s=0,0 for i=1.0,3.0 do n=n+1 s=s+i end return n,s]=],
  [=[local n=0 for i=1.0,1.0 do n=n+1 end return n]=],
  [=[local n=0 for i=1.0,0.0 do n=n+1 end return n]=],
  [=[local n,s=0,0 for i=3.0,1.0,-1.0 do n=n+1 s=s+i end return n,s]=],
  [=[local n=0 for i=1.0,3.0,-1.0 do n=n+1 end return n]=],
  [=[local n,s=0,0 for i=1.0,2.0,0.5 do n=n+1 s=s+i end return n,s]=],
  [=[local n,s=0,0 for i=0.0,1.0,0.1 do n=n+1 s=s+i end return n,s]=],
  [=[local start,limit,step=1.0,3.0,1.0 local n=0 for i=start,limit,step do n=n+1 start=99 limit=0 step=0 end return n,start,limit,step]=],
  [=[local i=40.0 local sum=0 for i=i,i+2.0 do sum=sum+i end return i,sum]=],
  [=[local n=0 for i=1.0,2.0 do n=n+1 end return n,i]=],
  [=[local sum=0 for _ENV=1.0,3.0 do sum=sum+_ENV end return sum]=],
  [=[local n,sum=0,0 for i=1.0,3.0 do local i=99 n=n+1 sum=sum+i end return n,sum]=],
  [=[local n=0 for i=1.0,3.0 do local x if x~=nil then return 99 end x=i n=n+1 end return n]=],
  [=[local n=0 for i=1.0,3.0 do global i i=99 n=n+1 end return n,i]=],
  [=[local n=0 for i=1.0,3.0 do for j=1.0,2.0 do n=n+i*j end end return n]=],
  [=[local n=0 for i=1.0,3.0 do for j=1.0,9.0 do n=n+1 break end end return n]=],
  [=[local n=0 for i=1.0,3.0 do do local x={} if i==2 then break end end n=n+1 end return n]=],
  [=[for i=1.0,3.0 do if i==2 then return i end end]=],
  [=[local nan=0/0 local n=0 local last for i=nan,3.0,1.0 do n=n+1 last=i end return n,last]=],
  [=[local nan=0/0 local n=0 local last for i=1.0,nan,1.0 do n=n+1 last=i end return n,last]=],
  [=[local nan=0/0 local n=0 local last for i=3.0,1.0,nan do n=n+1 last=i end return n,last]=],
  [=[local nan=0/0 local n=0 for i=1.0,3.0,nan do n=n+1 end return n]=],
  [=[local n=0 local last for i=1.0,5.0,1/0 do n=n+1 last=i end return n,last]=],
  [=[local n=0 local last for i=5.0,1.0,-1/0 do n=n+1 last=i end return n,last]=],
  [=[local n=0 for i=1/0,5.0,1.0 do n=n+1 end return n]=],
  [=[local n=0 local last for i=-1/0,0.0,1/0 do n=n+1 last=i end return n,last]=],
  [=[local n=0 for i=1.0,1/0,1.0 do n=n+1 if n==3 then break end end return n]=],
  [=[local n=0 for i=1/0,1/0,1.0 do n=n+1 if n==3 then break end end return n]=],
  [=[local first for i=-0.0,0.0,1.0 do first=i end return first]=],
  [=[local n,last=0,0 for i=9007199254740992.0,9007199254740994.0,1.0 do n=n+1 last=i if n==3 then break end end return n,last]=],
  [=[local x=1 goto done x=99 ::done:: return x]=],
  [=[local n=0 ::again:: n=n+1 if n<4 then goto again end return n]=],
  [=[local n=0 do local x=9 do local y=8 n=x+y goto out end end ::out:: return n]=],
  [=[local n=0 do goto a n=99 ::a:: n=n+1 end do goto a n=99 ::a:: n=n+2 end return n]=],
  [=[local n=0 do goto a ::a:: n=2 end ::a:: return n]=],
  [=[local n=1 do goto done local x=1+nil ::done:: ; ::also:: ;; end return n]=],
  [=[goto done local x=1+nil ::done::]=],
  [=[local n=0 repeat local done=n==2 n=n+1 goto condition n=99 ::condition:: until done return n]=],
  [=[local n=0 for i=1.0,4.0 do if i==2 then goto continue end local x=i n=n+x ::continue:: end return n]=],
  [=[local n=0 while n<3 do n=n+1 goto continue local x=1+nil ::continue:: end return n]=],
  [=[local n=0 ::again:: local x if x~=nil then return 99 end x={} n=n+1 if n<5 then goto again end return n]=],
  [=[local x=7 local n=0 ::again:: do local x=99 n=n+1 if n<3 then goto again end end return x,n]=],
  [=[local n=0 for i=1.0,9.0 do repeat do local x={} n=i goto out end until false end ::out:: local x return n,x]=],
  [=[local n=0 ::again:: local _ENV={x=8} n=n+1 if n<3 then goto again end return n,x]=],
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
io.write("# Statement results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; return count; comma-separated type:payload values.\n")
io.write("# Each chunk starts with an empty environment; aliasing/indexed assignments are excluded.\n")
for _, source in ipairs(chunks) do
  local chunk = assert(load(source, "<oracle>", "t", {}))
  local results = table.pack(chunk())
  local encoded = {}
  for i=1,results.n do encoded[i]=encode(results[i]) end
  io.write(hex(source), " ", results.n, " ", results.n == 0 and "-" or table.concat(encoded, ","), "\n")
end
