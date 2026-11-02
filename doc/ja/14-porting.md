[← 目次](README.md)

# 14. Lua から移す

[13 章](13-differences-from-lua.md)は**何が違うか**の一覧で、[13.3](13-differences-from-lua.md#133-代わりに何を書くか)は**代わりに何を書くか**です。
この章は**実際に移してみた記録**です。プログラムを 2 本、Lua で書いてから移し、
**何箇所変えたか**を数えています。

**ここに出ている移植後のプログラムは、すべて走らせて確かめたものです**
（`zig build manual-check`）。

## 14.1. 1 本目：語の頻度

Lua で書くとこうなります。

```text
local text = "the quick brown fox jumps over the lazy dog the fox"

local counts = {}
for word in text:gmatch("%a+") do
  counts[word] = (counts[word] or 0) + 1
end

local words = {}
for w in pairs(counts) do words[#words + 1] = w end

table.sort(words, function(a, b)
  if counts[a] ~= counts[b] then return counts[a] > counts[b] end
  return a < b
end)

for i = 1, math.min(3, #words) do
  print(string.format("%-6s %d", words[i], counts[words[i]]))
end
```

**変えたのは 1 箇所です。** `text:gmatch(…)` を `string.gmatch(text, …)` にするだけです。

```lua nilu
local text = "the quick brown fox jumps over the lazy dog the fox"

local counts = {}
for word in string.gmatch(text, "%a+") do
  counts[word] = (counts[word] or 0) + 1
end

local words = {}
for w in pairs(counts) do words[#words + 1] = w end

table.sort(words, function(a, b)
  if counts[a] ~= counts[b] then return counts[a] > counts[b] end
  return a < b
end)

for i = 1, math.min(3, #words) do
  print(string.format("%-6s %d", words[i], counts[words[i]]))
end
```
```output
the    3
fox    2
brown  1
```

**出力は `lua5.5` が元のプログラムで出すものと 1 バイト同じです。**
`%-6s %d` の整形も、`#words`、`or` の既定値、`table.sort` に渡した関数も、そのまま動きます。

**`pairs` の順は決まっていないのに、出力は毎回同じです**（[9 章](09-gc.md)、[10.1](10-library.md#101-基本関数)）。
並べ替えの比較関数が**全順序**だからです——数が違えば数で、同じなら名前で決まるので、
どの順で集めても結果は 1 つに決まります。**比較関数が引き分けを残していると、
そこで順序は不定になります。** 元の Lua でも同じです。

## 14.2. 2 本目：メソッドを持つクラス

Lua でいちばん慣用的な形です。`:` が 3 通りの場所に出てきます。

**下のプログラムは Lua から 1 文字も変えずに動き**、Lua と同じものを出します
（[14.3](#143-数の綴り)）。

```lua nilu
local Stack = {}
Stack.__index = Stack

function Stack.new()
  return setmetatable({items = {}, n = 0}, Stack)
end

function Stack:push(v)
  self.n = self.n + 1
  self.items[self.n] = v
  return self
end

function Stack:pop()
  if self.n == 0 then return nil end
  local v = self.items[self.n]
  self.items[self.n] = nil
  self.n = self.n - 1
  return v
end

function Stack:size() return self.n end

local s = Stack.new()
s:push("a"):push("b"):push("c")
print(s:size(), s:pop(), s:size())
```
```output
3	c	2
```

**つなげ書き（`s:push("a"):push("b")`）も動きます。** `push` が `self` を返し、
返った値が次の `:` の受け手になるだけです。

**メタテーブルはそのまま働きます。** `s.push` は `s` に無いので、`__index` が `Stack` を見て
見つけます（[7 章](07-metatables.md)）。

**`:` は糖衣ではありません。** `t:m(x)` は `t.m(t, x)` と**同じではなく**、
**受け手が一度だけ評価されます** —— `get():push("a")` は `get` を 1 回呼びます。
`s.push(s, "a")` と書き換えると、受け手が式のときに**2 回**
評価されます。

**文字列のメソッドも `:` で呼べます**（`s:upper()`）。Lua と同じです
（[13.3](13-differences-from-lua.md#133-代わりに何を書くか)）。

## 14.3. 数の綴り

**数は Lua と同じ形で出ます。** 整数は `.0` なしで、値が整数の浮動小数点数は `.0` 付きです（`10 / 2` は `5.0`。
[2.3](02-values.md#23-数)）。違いうるのは浮動小数点数の桁数だけで、Nilu は読み戻せる最も少ない桁で書きます
（[13.1](13-differences-from-lua.md#131-違うところ)）。決まった形で書きたいときは `string.format`（`%d`、`%.1f`）を使います。

```lua nilu
local n = 3
print(n)
print(string.format("%d", n))
```
```output
3
3
```

## 14.4. 移すときの手順

1. **書き換えが要るものは [13.3](13-differences-from-lua.md#133-代わりに何を書くか)を引く。**
2. **走らせて、Lua が小数で出していたところを見る**（`5.0` と `5`）。形を決めたいなら `string.format`。

`{1, 2}`、`{x = 1}`、`{[k] = v}`、`function f() … end`、`t:m(x)`、`function t:m()`、`s:upper()` は
**そのまま書けます**。

**`__gc` は書き換えられません**。
理由は [13.3](13-differences-from-lua.md#133-代わりに何を書くか)の最後の表にあります。
そこに当たったら、移すのはプログラムの組み換えになります。

---

次: [15. 文法](15-grammar.md)
