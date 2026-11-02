local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local inputs = {
  "0", "-0.0", "+0.0", "3", "3.", ".5", "-.5", "1e2", "1E-2",
  " \t12.5\r\n", "0x10", "0Xff", "0x.8", "0x1.", "0x1p4", "-0X.8p1",
  "0xFFFFFFFFFFFFFFFFp0", "9007199254740992", "18446744073709551615",
  "1e9999", "-1e9999", "1e-9999", "-1e-9999", "5e-324", "1.7976931348623157e308",
  "", " ", "+", "-", ".", "inf", "-inf", "nan", "NaN", "infinity",
  "1_0", "0b101", "0x", "0x.p1", "0x1p", "1e", "1e+", "1 2", "1,2", "1\0", "3..4",
}
local function hex(bytes)
  return (bytes:gsub(".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
io.write("# Numeric conversion captured from ", _VERSION, " on ", date, ".\n")
io.write("# Input bytes in hex (- means empty), then IEEE 754 binary64 bits in big-endian hex or nil.\n")
io.write("# Integer results are converted to float before packing; negative float zero is retained.\n")
io.write("# Whole hexadecimal integers that wrap in Lua are tested separately as a documented Nilu difference.\n")
for _, input in ipairs(inputs) do
  local value = tonumber(input)
  if value and math.type(value) == "integer" then value = value + 0.0 end
  io.write(input == "" and "-" or hex(input), " ", value and hex(string.pack(">d", value)) or "nil", "\n")
end
