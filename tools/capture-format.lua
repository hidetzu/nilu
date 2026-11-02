-- Captures string.format's float conversions from Lua 5.5, for the
-- string_format fixture test. Values come from a fixed generator, so a
-- recapture writes the same lines.
local date = assert(arg[1], "pass the capture date as YYYY-MM-DD")
assert(date:match("^%d%d%d%d%-%d%d%-%d%d$"), "pass the capture date as YYYY-MM-DD")
assert(_VERSION == "Lua 5.5", "capture with Lua 5.5")
local formats = {
  "%.0f", "%.2f", "%.10f", "%f", "%e", "%.0e", "%.12e", "%g", "%.3g", "%.17g",
  "%#g", "%G", "%a", "%.3a", "%A", "%+.4f", "%10.2e", "%-12.5g",
}
-- Exact ties and small values that a shortest-digits rounding gets wrong.
local values = {2.675, 0.05, 1.0005, 0.125, 2.5, 0.5, 1.5, 1e22, 5e-324, 0.1, 1 / 3, 123456789.987654321, 0.0, -2.5}
local state = 0x2545F4914F6CDD1D
while #values < 300 do
  state = state * 6364136223846793005 + 1442695040888963407
  local value = string.unpack("<d", string.pack("<i8", state))
  if value == value and value ~= math.huge and value ~= -math.huge then
    -- Alternate raw bit patterns with numbers of an everyday size.
    if #values % 2 == 0 then value = (state >> 11) / (1 << 53) * 10 ^ ((state >> 3) % 13 - 6) * ((state & 1) == 0 and 1 or -1) end
    values[#values + 1] = value
  end
end
io.write("# string.format float conversions captured from ", _VERSION, " on ", date, ".\n")
io.write("# IEEE 754 binary64 bits in big-endian hex, a tab, the format, a tab, the result.\n")
for _, value in ipairs(values) do
  local bits = string.format("%016x", string.unpack(">i8", string.pack(">d", value)))
  for _, format in ipairs(formats) do
    io.write(bits, "\t", format, "\t", string.format(format, value), "\n")
  end
end
