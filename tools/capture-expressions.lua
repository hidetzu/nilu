local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local expressions = {
  [=[nil]=], [=[true]=], [=[false]=], [=[0.0]=], [=[-0.0]=], [=[1 + 2 * 3]=], [=[(1 + 2) * 3]=],
  [=[2 ^ 3 ^ 2]=], [=[-2 ^ 2]=], [=[7 / 2]=], [=[7.0 // 2.0]=], [=[-7.0 // 2.0]=],
  [=[7.0 // -2.0]=], [=[-7.0 % 2.0]=], [=[7.0 % -2.0]=], [=[-4.0 % 2.0]=],
  [=[1.0 / 0.0]=], [=[0.0 / 0.0]=], [=[1.0 // 0.0]=], [=[1.0 % 0.0]=],
  [=[1e300 % 0.1]=], [=[(1.0 / 0.0) % 2.0]=], [=[1.0 % (-1.0 / 0.0)]=],
  [=[1 == '1']=], [=[nil == false]=], [=[1 == 1.0]=], [=[1 ~= 2]=], [=[1 < 2]=],
  [=[2 <= 2]=], [=[3 > 2]=], [=[3 >= 4]=], [=[(0/0) == (0/0)]=], [=[(0/0) <= 1]=],
  [=['a\0' < 'a\0b']=], [=['\xff' > '\x7f']=], [=['a' .. 'b' == 'ab']=],
  [=[{} == {}]=], [=[({t = {}}).t ~= nil]=], [=[false and (1 + nil)]=],
  [=[true or #5]=], [=[not nil]=], [=[not false]=], [=[not 0]=], [=[not '']=],
  [=[1 and 2]=], [=[0 or 2]=], [=[false or 'default']=], [=['' and 'selected']=],
  [=[(false and 1 or 3) + (true and 2 or 4)]=], [=['a' .. 'b' .. 'c']=],
  [=['a\0' .. '\xff']=], [=['\x41\66\u{3042}']=], [=[#'あ']=], [=[#'a\0b']=], [=[#'']=],
  [=[({10, x = 1, [3] = 30})[1]]=], [=[({10, x = 1, [3] = 30}).x]=],
  [=[({10, x = 1, [3] = 30})[3]]=], [=[({x = 1, x = 2}).x]=],
  [=[({[1 + 1] = 9})[2]]=], [=[#({1, 2; 3,})]=], [=[#({})]=],
  [=[({x = 1}).missing == nil]=], [=[({})[nil] == nil]=], [=[({})[0 / 0] == nil]=],
  [=[({[-0.0] = 7})[0]]=], [=[({[1.0/0.0] = 8})[1.0/0.0]]=],
}
local function hex(bytes)
  return (bytes:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
io.write("# Expression results captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex; result type; binary64 bits/string bytes in hex, boolean, nan, or -.\n")
io.write("# Only the common float/value subset is captured; no integer overflow or unspecified table borders.\n")
for _, expression in ipairs(expressions) do
  local chunk = assert(load("return " .. expression, "<oracle>", "t", {}))
  local value = chunk()
  local kind = type(value)
  local result
  if kind == "number" then
    if math.type(value) == "integer" then value = value + 0.0 end
    result = value ~= value and "nan" or hex(string.pack(">d", value))
  elseif kind == "string" then result = value == "" and "-" or hex(value)
  elseif kind == "boolean" then result = tostring(value)
  elseif kind == "nil" then result = "-"
  else error("capture must return a primitive value") end
  io.write(hex(expression), " ", kind, " ", result, "\n")
end
