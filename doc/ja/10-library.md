[← 目次](README.md)

# 10. ライブラリ

ホストが開いたときだけ入っています。開いていない状態には何もありません。
`nilu` コマンドは開いています。

グローバルにあるのは次のものです。

```text
type  tostring  tonumber  assert  select
error  pcall  xpcall
next  pairs  ipairs
rawget  rawset  rawequal  rawlen
setmetatable  getmetatable  collectgarbage
string  table  math  utf8  coroutine  debug
load  require  dofile  loadfile  package
print  warn  _G  _VERSION
```

`error`、`pcall`、`xpcall` は [8. 失敗](08-failure.md)で説明します。

`print` はここにあり、ホストが渡した writer を通して書きます（[1.3](01-getting-started.md#13--print-はホストが決めた先へ書きます)）。
`io` と `os` はここにありません。`nilu` コマンドが入れています（[11.4](11-nilu-command.md#114-io-と-os)）。

上の一覧は読むためのものです。**それぞれが実際にあることは、こう確かめられます。**

```lua nilu
print(type(type), type(tostring), type(tonumber), type(assert), type(select))
print(type(next), type(pairs), type(ipairs))
print(type(rawget), type(rawset), type(rawequal), type(rawlen))
print(type(setmetatable), type(getmetatable))
print(type(string), type(table), type(math), type(utf8), type(coroutine), type(debug))
print(type(error), type(pcall), type(xpcall))
print(type(load), type(require), type(dofile), type(loadfile), type(package))
print(type(print), type(warn), type(collectgarbage), _G == _ENV, _VERSION)
```
```output
function	function	function	function	function
function	function	function
function	function	function	function
function	function
table	table	table	table	table	table
function	function	function
function	function	function	function	table
function	function	function	true	Nilu 0.1
```

（名前が消えればこの例が落ちます。一覧のほうは落ちないので、
一覧だけでは足りません。）

**ライブラリは C の API だけで書かれています。** 内部には触っていません。
つまり、ここにあるものはホストが自分で書けたものです。

## 10.1. 基本関数

### `type(v)`

値の型の名前を文字列で返します。

```lua nilu
print(type(nil), type(true), type(1), type("a"), type({}), type(print))
```
```output
nil	boolean	number	string	table	function
```

### `tostring(v)`

どの値でも文字列にします。`__tostring` と `__name` を見ます
（[7.4](07-metatables.md#文字列にする)）。

```lua nilu
print(tostring(nil), tostring(12), tostring(true))
```
```output
nil	12	true
```

### `tonumber(v [, base])`

数ならそのまま、文字列なら読んで返します。読めなければ `nil` です。

```lua nilu
print(tonumber("12"), tonumber("  0x10  "), tonumber("12a"), tonumber({}))
print(tonumber("ff", 16), tonumber("101", 2), tonumber("z", 36))
```
```output
12	16	nil	nil
255	5	35
```

基数を渡したときは、その基数の整数としてだけ読みます。

### `assert(v [, …])`

`v` が偽なら失敗します。真なら引数をすべて返します（[8.5](08-failure.md#85-assert)）。

### `select(n, …)`

`select("#", …)` は個数、`select(n, …)` は n 番目から後ろ全部です。

```lua nilu
print(select("#", "a", "b", "c"))
print(select(2, "a", "b", "c"))
print(select(-1, "a", "b", "c"))
```
```output
3
b	c
c
```

負の数は後ろから数えます。

### `next(t [, key])`

テーブルの次の対を返します。`key` を渡さなければ最初の対です。
終わりまで来たら `nil` を返します。

```lua nilu
local t = {}
t[1] = "ひとつ"
local k, v = next(t)
print(k, v)
print(next(t, k))
print(next({}))
```
```output
1	ひとつ
nil
nil
```

### `pairs(t)` と `ipairs(t)`

`for … in` と一緒に使います（[4.5](04-statements.md#45-汎用-for)）。
`pairs` は 4 つの値を返します。4 つ目は汎用 `for` が閉じるもので、ここでは `nil` です。

```lua nilu
local t = {}
t[1] = "a"
print(select("#", pairs(t)))
```
```output
4
```

### `rawget` `rawset` `rawequal` `rawlen`

メタテーブルを通しません（[7.3](07-metatables.md#73-生のアクセス)）。`rawset` は渡したテーブルを返します。

```lua nilu
local t = {}
print(rawset(t, "k", 1) == t)
print(rawget(t, "k"), rawlen(t), rawequal(t, t))
```
```output
true
1	0	true
```

### `setmetatable(t, mt)` と `getmetatable(t)`

[7. メタテーブル](07-metatables.md)にあります。`setmetatable` は渡したテーブルを返します。

### `warn(msg, …)`

**文字列をつないで、警告としてホストの writer に渡します。** `Nilu warning: `、メッセージ、改行を
`writer(text, "warning")` の形で渡します（`nilu` コマンドは標準エラーに書きます）。警告は初めは切れていて、
`warn("@on")` で入り、`warn("@off")` で切れます。`@` で始まるほかの 1 つだけのメッセージは、Lua と同じく無視します。
writer が無ければ何もしません。

```lua nilu
warn("not shown: warnings start off")
warn("@on")
warn("disk ", "almost full")
```
```stderr
Nilu warning: disk almost full
```

## 10.2. `string`

**文字列の添字は 1 から始まり、負の数は後ろから数えます。**

| 関数 | すること |
|---|---|
| `string.len(s)` | バイト数。`#s` と同じ |
| `string.sub(s, i [, j])` | 部分文字列 |
| `string.upper(s)` / `lower(s)` | ASCII の大小変換 |
| `string.reverse(s)` | バイトを逆順に |
| `string.rep(s, n [, sep])` | n 回繰り返す。`sep` があれば間に挟む |
| `string.byte(s [, i [, j]])` | バイトの値 |
| `string.char(…)` | バイトの値から文字列を作る |
| `string.format(fmt, …)` | 書式に沿って値を並べる |
| `string.find(s, p [, init [, plain]])` | 探す。位置の始まりと終わり（と捕獲） |
| `string.match(s, p [, init])` | 捕獲、無ければマッチ全体 |
| `string.gmatch(s, p [, init])` | 順に取り出す関数を返す |
| `string.gsub(s, p, repl [, n])` | 置き換える。新しい文字列と回数 |

```lua nilu
print(string.len("hello"), #"hello")
print(string.sub("hello", 2, 3), string.sub("hello", -3), string.sub("hello", 2))
print(string.upper("abc"), string.lower("ABC"), string.reverse("abc"))
print(string.rep("ab", 3))
```
```output
5	5
el	llo	ello
ABC	abc	cba
ababab
```

```lua nilu
print(string.byte("A"))
print(string.byte("abc", 1, 3))
print(string.char(78, 105, 108, 117))
```
```output
65
97	98	99
Nilu
```

範囲が外に出ていても失敗しません。空文字列や、何も返さないことになります。

```lua nilu
print("[" .. string.sub("abc", 10) .. "]")
print(select("#", string.byte("abc", 10)))
```
```output
[]
0
```

`upper` と `lower` は ASCII だけです（ロケールを見ません）。

### `string.format(fmt, …)`

`%d %i %u %o %x %X %c %f %e %E %g %G %a %A %q %s %p %%` を受けます。幅と精度は 2 桁までです
（Lua と同じ上限です）。

```lua nilu
print(string.format("%d %5d|%-5d|%05d %+d", 42, 42, 42, 42, 42))
print(string.format("%x %X %#x %o %c%c", 255, 255, 255, 8, 78, 105))
print(string.format("[%10s][%-10s][%.3s]", "abc", "abc", "abcdef"))
print(string.format("%f %.2f %10.3f %e", 1.5, 3.14159, 3.14159, 1500))
print(string.format("%s %s %s %s=%d%%", nil, true, 12, "pct", 50))
```
```output
42    42|42   |00042 +42
ff FF 0xff 10 Ni
[       abc][abc       ][abc]
1.500000 3.14      3.142 1.500000e+03
nil true 12 pct=50%
```

`%s` は `tostring` と同じ綴りを使います（`__tostring` も見ます）。`%d` は整数か、値が整数の浮動小数点数を
受け、`1.5` は実行時エラーです。

**小数の変換は C と同じ結果を出します**。`%f`・`%e`・`%g` は 2 進数で持っている値そのものを
丸め（ちょうど中間なら偶数へ）、`%a` はそのビットを書きます。Lua とバイト単位で一致し、
テストは `lua5.5` から取った 5400 個の答えと比べています。

```lua nilu
print(string.format("%.20f", 0.1))
print(string.format("%.2f %g %g %.3g %a", 2.675, 0.1, 1e20, 2.675, 1.5))
print(string.format("%q", "a\n\"b\""))
print(string.format("%q %q %q %q %q", 3, 3.0, 1.5, 1/0, nil))
```
```output
0.10000000000000000555
2.67 0.1 1e+20 2.67 0x1.8p+0
"a\
\"b\""
3 0x1.8p+1 0x1.8p+0 1e9999 nil
```

`0.1` は 2 進数では `0.1000000000000000055511…`、`2.675` は `2.67499999…` で、丸めるのはその値です。
**`%q`** は Lua と同じく、Nilu が同じ種類の同じ値として読み戻せる形で書きます。文字列はエスケープ付きで、
整数は 10 進で（最小の整数は `0x8000000000000000`）、浮動小数点数は 16 進で、無限大は `1e9999`、NaN は `(0/0)` です。テーブルや関数には書く形が無いので断ります。
**`%p`** はテーブル、関数、文字列、userdata、スレッドのアドレス（`tostring` が見せるもの、`0x…`）を書き、
それ以外の値には Lua と同じく `(null)` と書きます。`-` と幅を受けます。

### パターン — `find`、`match`、`gmatch`、`gsub`

**Lua のパターンがそのまま使えます**（正規表現ではなく、Lua 独自の記法です）。

| 書き方 | 意味 |
|---|---|
| `.` | どの 1 バイトでも |
| `%a` `%d` `%l` `%u` `%w` `%s` `%p` `%c` `%g` `%x` `%z` | 英字、数字、小文字、大文字、英数字、空白、記号、制御、可視、16 進、`\0` |
| `%A` など大文字 | その補集合 |
| `[abc]` `[a-z]` `[^0-9]` | 集合、範囲、補集合 |
| `%.` `%%` `%[` | その文字そのもの |
| `*` `+` `-` `?` | 0 回以上（最長）、1 回以上、0 回以上（最短）、0 か 1 回 |
| `^` `$` | 先頭、末尾（パターンの両端にあるときだけ） |
| `%bxy` | `x` と `y` の釣り合った区間 |
| `%f[set]` | 境目 |
| `(…)` `()` `%1`〜`%9` | 捕獲、位置の捕獲、捕獲の参照 |

`init` が負なら後ろから数えます。見つからなければ `nil` です。

```lua nilu
print(string.find("hello world", "world"))
print(string.find("hello", "l+"))
print(string.find("hello", "(l)(l)"))
print(string.match("key=val", "(%w+)=(%w+)"))
print(string.match("hello", "()ll()"))
print(string.match("f(a(b)c)d", "%b()"))
print(string.match("  x  ", "^%s*(.-)%s*$"))
```
```output
7	11
3	4
3	4	l	l
key	val
3	5
(a(b)c)
x
```

`find` は捕獲があればそれも返し、`match` は捕獲だけ（無ければマッチ全体）を返します。
位置の捕獲 `()` は数です。

パターン文字を文字そのものとして探したいときは、`find` の 4 つめの引数に `true` を渡します
（Lua の `plain`）。特別な文字を含まないパターンは最初からそのまま探します。

```lua nilu
print(string.find("a.c", ".", 1, true))
print(string.find("a.c", "."))
```
```output
2	2
1	1
```

`gsub` の置き換えは**文字列・数・テーブル・関数**のどれかです。文字列なら `%0`〜`%9` が
捕獲（`%0` はマッチ全体）、`%%` が `%` です。テーブルならマッチ全体をキーに引き、関数なら捕獲を
引数に呼びます。**どちらも `nil` か `false` を返したら元のまま**で、回数には数えます。

```lua nilu
print(string.gsub("hello world", "o", "0"))
print(string.gsub("hello world", "(%w+)", "<%1>"))
print(string.gsub("hello", "l", "L", 1))
print(string.gsub("hello", "(l)", function(c) return string.upper(c) end))
local names = {}
names.hello = "こんにちは"
print(string.gsub("hello world", "%a+", names))
```
```output
hell0 w0rld	2
<hello> <world>	2
heLlo	1
heLLo	2
こんにちは world	2
```

`gmatch` は**呼ぶたびに次のマッチを返す関数**を返します。`for` に渡すのが普通ですが、
変数に入れて自分で呼んでもかまいません。

```lua nilu
for k, v in string.gmatch("a=1, b=2", "(%w+)=(%w+)") do
  print(k, v)
end
local it = string.gmatch("x y", "%a")
print(it(), it())
```
```output
a	1
b	2
x	y
```

**Lua との違いは 3 つです。**

1. **文字クラスは ASCII です**（中核が libc を使わないため。C ロケールでは Lua と一致します）。
2. **置き換えに入る数は Nilu の綴りです**：`string.gsub("a", "a", 1)` は `1`、位置の捕獲
   `%1` も `2` のように出ます。
3. **パターンの誤りには Lua と同じ文章が付きます**。
   下の表は**そのまま出る言葉**で、Lua との違いではありません。

| こう書くと | 言われること（Lua と同じ） |
|---|---|
| `"%"`（`%` で終わる） | `malformed pattern (ends with '%')` |
| `"[a"` | `malformed pattern (missing ']')` |
| `"(a"` | `unfinished capture` |
| `"a)"` を `match` に | `invalid pattern capture` |
| `"%1"`（捕獲が無い） | `invalid capture index %1` |
| `"%b"` | `malformed pattern (missing arguments to '%b')` |
| `"%f"`、`"%fa"` | `missing '[' after '%f' in pattern` |
| 入れ子の捕獲が 33 以上 | `too many captures` |
| 深く戻る必要のあるパターン（`a?` を 300 個…） | `pattern too complex`（深さ 200 で止めます） |
| `gsub` の置き換え文字列に `"%x"` | `invalid use of '%' in replacement string` |
| `gsub` の置き換えに `true` | `string/function/table expected` |
| 置き換え関数がテーブルを返す | `invalid replacement value (a table)` |

```lua nilu
return string.find("abc", "%")
```
```stderr
nilu: <manual>:1: malformed pattern (ends with '%')
```

### `string.pack`、`string.unpack`、`string.packsize`

**バイト列に詰める／読み出す**ための 3 つです。
**書式は Lua と同じ**で、option も大きさも断り方もそのまま借りています。

```lua nilu
local packed = string.pack("<i4i4", 7, 9)
print(string.len(packed))
print(string.unpack("<i4i4", packed))
```
```output
8
7	9	9
```

**`unpack` は値のあとに「次の位置」を返します。** 上の最後の `9` がそれです。

| option | 大きさ | 何 |
|---|---|---|
| `b` `B` | 1 | 符号つき／なしの整数 |
| `h` `H` | 2 | 同じ |
| `l` `L` `j` `J` `T` | 8 | 同じ |
| `i[n]` `I[n]` | n（既定 4、1〜16） | 同じ |
| `f` | 4 | 単精度 |
| `d` `n` | 8 | 倍精度 |
| `s[n]` | n（既定 8）＋中身 | 長さを前置した文字列 |
| `z` | 中身＋1 | 0 で終わる文字列 |
| `x` | 1 | 詰め物 1 バイト |
| `<` `>` `=` | — | リトル／ビッグ／native。**既定はリトル** |
| `!` `!n` | — | 整列の最大。**既定は整列なし** |
| `X` | — | 次の option に合わせて整列し、何も詰めない |
| 空白 | — | 無視 |

```lua nilu
print(string.packsize("i1i4"), string.packsize("!4i1i4"))
print(string.packsize("fdnx"))
```
```output
5	8
21
```

**`packsize` は `s` と `z` を断ります**（長さが決まらないので）。

```lua nilu
local ok, why = pcall(string.packsize, "z")
print(ok, why)
```
```output
false	bad argument #1 to 'packsize' (variable-length format)
```

**整数に入らない値は断ります。** 文面は Lua と同じです。

```lua nilu
print(select(2, pcall(string.pack, "i1", 300)))
print(select(2, pcall(string.pack, "B", 0 - 1)))
print(select(2, pcall(string.pack, "i4", 1.5)))
```
```output
bad argument #2 to 'pack' (integer overflow)
bad argument #2 to 'pack' (unsigned overflow)
bad argument #2 to 'pack' (number has no integer representation)
```

整数の書式は、64 ビットすべてを整数として読み戻します。

```lua nilu
print(string.unpack("i8", string.pack("i8", 1152921504606846976)))
```
```output
1152921504606846976	9
```

## 10.3. `table`

| 関数 | すること |
|---|---|
| `table.pack(…)` | 引数をテーブルに詰め、個数を `n` に入れる |
| `table.create(nseq [, nrec])` | 列の要素 `nseq` 個とほかのフィールド `nrec` 個の場所を取った空のテーブル。0 未満や 2^31 - 1 を超える大きさは `out of range` |
| `table.unpack(t [, i [, j]])` | テーブルの要素を値のならびにする |
| `table.insert(t, [pos,] v)` | 入れる（後ろか、位置を指定して） |
| `table.remove(t [, pos])` | 取り出して返す（既定は最後） |
| `table.concat(t [, sep [, i [, j]]])` | 文字列をつなぐ |
| `table.move(a1, f, e, t [, a2])` | 範囲を写す |
| `table.sort(t [, comp])` | 並べ替える |

```lua nilu
local packed = table.pack("a", nil, "c")
print(packed.n, packed[1], packed[2], packed[3])
```
```output
3	a	nil	c
```

`nil` が混ざっていても数えられるのは `table.pack` の `n` だけです。
`#` では分かりません。

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
t[3] = "c"
print(table.unpack(t))
print(table.unpack(t, 2))
print(table.unpack(t, 1, 2))
```
```output
a	b	c
b	c
a	b
```

```lua nilu
local t = {}
table.insert(t, "a")
table.insert(t, "b")
table.insert(t, 1, "先頭")
print(table.concat(t, ","))
print(table.remove(t), table.concat(t, ","))
print(table.remove(t, 1), table.concat(t, ","))
```
```output
先頭,a,b
b	先頭,a
先頭	a
```

`table.concat` は文字列と数をつなぎます（数は `tostring` の綴りで）。それ以外は Lua と同じ形で断り、
**どの添字の何だったか**を言います。

```lua nilu
local t = {}
t[1] = 1
t[2] = "a"
print(table.concat(t, ","))
t[3] = {}
return table.concat(t)
```
```output
1,a
```
```stderr
nilu: <manual>:6: invalid value (table) at index 3 in table for 'concat'
```
断るのは数を文字列と見なさないからです（[2. 値](02-values.md)）。
だから括弧の中に `number` と書かれた文章は、Lua には出ません。

```lua nilu
local a = {}
a[1] = "あ"
a[2] = "い"
local b = {}
table.move(a, 1, 2, 1, b)
print(b[1], b[2])
```
```output
あ	い
```

### `table.sort(t [, comp])`

その場で並べ替えます。`comp` が無ければ `<` の順です。文字列はバイトの順です。

```lua nilu
local u = {}
u[1] = "pear" u[2] = "apple" u[3] = "fig"
table.sort(u)
print(table.concat(u, ","))
table.sort(u, function(a, b) return a > b end)
print(table.concat(u, ","))
```
```output
apple,fig,pear
pear,fig,apple
```

数と文字列が混ざっていると比べられないので実行時エラーです。
`comp` が順序になっていないとき（たとえばいつも `true` を返すとき）も、Lua と同じく
失敗し、**Lua と同じ文章**です。

```lua nilu
local t = {}
for i = 1, 40 do t[i] = i end
table.sort(t, function() return true end)
```
```stderr
nilu: <manual>:3: invalid order function for sorting
```

**Lua と違い、ピボットの選び方は毎回同じです。** Lua は配列が大きいとき時計とアドレスから
ピボットを散らしますが、Nilu の中核は時計を持ちません。並べ替えの結果は同じで、
最悪の形の入力にかかる時間だけが違います。

## 10.4. `math`

| 名前 | すること |
|---|---|
| `math.pi` | 円周率 |
| `math.huge` | 無限 |
| `math.abs(x)` | 絶対値 |
| `math.floor(x)` / `ceil(x)` | 切り下げ / 切り上げ。整数に収まれば整数 |
| `math.sqrt(x)` | 平方根 |
| `math.max(…)` / `min(…)` | `<` の順で最大 / 最小（文字列も、`__lt` も） |
| `math.fmod(x, y)` | C の `fmod`。**`%` とは違います** |
| `math.random([m [, n]])` | 乱数：`[0, 1)` の小数、`[1, m]` か `[m, n]` の整数 |
| `math.randomseed([n1 [, n2]])` | 種を決める。種を返す |
| `math.sin(x)` `cos` `tan` `asin` `acos` | 三角関数（ラジアン） |
| `math.atan(y [, x])` | 点 (x, y) の角度。`x` を省くと 1 |
| `math.exp(x)` / `math.log(x [, base])` | e^x / 対数（自然対数か、その底で） |
| `math.deg(x)` / `math.rad(x)` | ラジアンを度に / 度をラジアンに |
| `math.modf(x)` | 0 のほうへの整数部と、残り |
| `math.frexp(x)` / `math.ldexp(m, e)` | `0.5 <= |m| < 1` で `x = m * 2^e`、とその逆 |
| `math.type(x)` | 数なら `"integer"` か `"float"`、数でなければ `nil` |
| `math.tointeger(x)` | `x` の値の整数。無ければ `nil`（文字列は変換しません） |
| `math.maxinteger` / `math.mininteger` | 2^63 - 1 と -2^63。いちばん大きい整数と小さい整数です |
| `math.ult(m, n)` | 両方を符号なしとして読んで `m < n` |

```lua nilu
print(math.pi)
print(math.huge, -math.huge)
print(math.abs(-3), math.sqrt(16))
print(math.floor(-1.5), math.ceil(-1.5))
print(math.max(1, 5, 3), math.min(1, 5, 3))
```
```output
3.141592653589793
inf	-inf
3	4.0
-2	-1
5	1
```

`math.fmod` は 0 のほうへ切り捨て、`%` は負の無限のほうへ切り捨てます。
**両方の言語で同じ違いです。**

```lua nilu
print(math.fmod(-7, 3), -7 % 3)
```
```output
-1	2
```

```lua nilu
print(math.sin(math.pi / 2), math.cos(0), math.atan(1, 1) * 4 == math.pi)
print(math.log(8, 2), math.log(100, 10), math.exp(0))
print(math.modf(3.75))
print(math.type(3), math.type(1.5), math.tointeger(4.0), math.tointeger(4.5))
print(math.maxinteger, math.mininteger)
```
```output
1.0	1.0	true
3.0	2.0	1.0
3	0.75
integer	float	4	nil
9223372036854775807	-9223372036854775808
```

### `math.random` と `math.randomseed`

生成器は Lua 5.5 と同じ **xoshiro256\*\*** で、種の決め方も同じです。
**だから同じ種を与えれば Lua と同じ列が出ます**（小数と範囲付きの整数について）。

```lua nilu
math.randomseed(42)
print(math.random())
math.randomseed(42)
print(math.random(100), math.random(100), math.random(100))
math.randomseed(42)
print(math.random(6), math.random(6), math.random(6), math.random(6))
print(math.randomseed(7, 9))
```
```output
0.9308121780395682
50	76	86
6	2	4	6
7	9
```

Lua で `math.randomseed(42); print(math.random(100))` と打つと、やはり `50` が出ます。

**Lua と違うところ**：

- **種を与えないときの列は決まっています。** 中核は時計を持たないので、開いたばかりの状態は
  `math.randomseed(0)` を呼んだあとと同じ列を出します。`nilu` コマンドは起動時に時刻と時計から
  種を与えるので、コマンドで走らせるかぎり毎回違います。**別のホストに組み込んだときは、ホストが
  種を与えないと毎回同じ列です**（[12.7](12-embedding.md#127-気をつけること)）。
- `math.randomseed()` を引数なしで呼ぶと、Lua は時計から種を取り直しますが、Nilu は
  **生成器の次の値から**取り直します。起動時に種が与えられていれば予測できないままですし、
  与えられていなければ決まった列のままです。

## 10.5. `utf8`

**文字列はバイト列です**（[2.4](02-values.md#24-文字列)）。`utf8` は、そのバイト列を
**UTF-8 の文字として数える**ための 6 つです。
文字列が何であるかは変わりません。

```lua nilu
local s = "a" .. utf8.char(0x3042) .. "b"
print(string.len(s), utf8.len(s))
print(utf8.codepoint(s, 2))
print(utf8.offset(s, 2))
```
```output
5	3
12354
2	4
```

**`utf8.offset` は 2 つ返します** —— その文字が始まるバイトと、終わるバイトです。
Lua 5.5 の形で、5.4 までは 1 つでした。

### `utf8.char(…)` と `utf8.charpattern`

```lua nilu
print(utf8.char(72, 105))
print(string.len(utf8.char(0)), string.len(utf8.char(0x10FFFF)))
local out = ""
for ch in string.gmatch("aあb", utf8.charpattern) do
  out = out .. tostring(string.len(ch)) .. ","
end
print(out)
```
```output
Hi
1	4
1,3,1,
```

**`utf8.char` は `0x7FFFFFFF` まで書けます**（6 バイト）。Unicode の外ですが、Lua の
`MAXUTF` がそこなので同じにしています。**読むほうは既定で厳しく**、Unicode の外と
サロゲートを断ります。4 つめの引数に真を渡すと緩くなります（Lua の `lax`）。

```lua nilu
local wide = utf8.char(0x7FFFFFFF)
print(utf8.len(wide))
print(utf8.len(wide, 1, -1, true))
```
```output
nil	1
1
```

### `utf8.len` が答える 2 つ

**UTF-8 でないバイトに当たると、`nil` と、そのバイトの位置を返します。**

```lua nilu
local broken = "a" .. string.char(255) .. "b"
print(utf8.len(broken))
```
```output
nil	2
```

### `utf8.codes(s [, lax])`

**`for` が駆動します。** 位置と符号位置を返し、UTF-8 でないバイトに当たると**その回で
断ります**（呼び出した時点ではありません）。

```lua nilu
for p, cp in utf8.codes("aあ") do
  print(p, cp)
end
```
```output
1	97
2	12354
```

### 位置の指定

`utf8.len` と `utf8.codepoint` と `utf8.offset` は、負の位置を後ろから数えます。
**範囲の外は断ります**が、言い方が 3 通りあります —— これは Lua の文章をそのまま
借りているところです。

| 書いたもの | 答え |
|---|---|
| `utf8.len("abc", 0)` | `bad argument #2 to 'len' (initial position out of bounds)` |
| `utf8.len("abc", 1, 4)` | `bad argument #3 to 'len' (final position out of bounds)` |
| `utf8.codepoint("abc", 0)` | `bad argument #2 to 'codepoint' (out of bounds)` |
| `utf8.offset("abc", 1, 20)` | `bad argument #3 to 'offset' (position out of bounds)` |

**`utf8.codepoint("abc", 9)` は `#3` と言います。** 書いたのは 2 つめの引数ですが、
`j` が `i` を既定値に取るので、範囲の外だと判定されたのは `j` のほうです。Lua は
**検査した引数**を報告します。

## 10.6. 引数が違うときどうなるか

**どの引数の、どの関数が違ったかを言います**。
形は Lua と同じ `bad argument #<番号> to '<関数名>' (<何が>)` です。

```lua nilu
return string.rep("x", -1) .. string.sub(5, 1)
```
```stderr
nilu: <manual>:1: bad argument #1 to 'sub' (string expected, got number)
```

`string.sub(5, 1)` が断られるのは**数を文字列と見なさない**からです（[2. 値](02-values.md)）。
Lua はここで `5` を `"5"` に変換するので、この行は Lua では失敗しません。

よく出る形をまとめます。どれも `lua5.5` の文章と同じです。

| こう書くと | 言われること |
|---|---|
| `string.rep()` | `bad argument #1 to 'rep' (string expected, got no value)` |
| `string.rep(nil, 2)` | `bad argument #1 to 'rep' (string expected, got nil)` |
| `string.rep("a", 1.5)` | `bad argument #2 to 'rep' (number has no integer representation)` |
| `table.remove({}, 5)` | `bad argument #2 to 'remove' (position out of bounds)` |
| `string.char(300)` | `bad argument #1 to 'char' (value out of range)` |
| `select(0)` | `bad argument #1 to 'select' (index out of range)` |
| `tostring()` | `bad argument #1 to 'tostring' (value expected)` |

**引数が無いことと `nil` を渡したことは別**です（`got no value` と `got nil`）。
Lua の区別をそのまま借りています。

**関数名は、呼んだ側が書いた名前です**。
Lua と同じです。

```lua nilu
print(select(2, pcall(function() local f = string.rep f("x") end)))
print(select(2, pcall(function() local t = {} t.go = string.rep t.go("x") end)))
```
```output
<manual>:1: bad argument #2 to 'f' (number expected, got no value)
<manual>:2: bad argument #2 to 'go' (number expected, got no value)
```

**呼び出し元のコードが無いときは、登録された名前になります** —— ホストが
`nilu_call` で呼んだとき、`pcall` が呼んだときです。名前はプログラムのバイトコードの中に
あるので、そこが無ければ読む先がありません。

```lua nilu
print(select(2, pcall(string.rep, "x")))
```
```output
bad argument #2 to 'rep' (number expected, got no value)
```

Lua はこの場合、読み込み済みモジュールの表を探して `'string.rep'` と答えます。
Nilu は関数の名前を `package.loaded` から探さないので、登録された名前を答えます。

**引数の番号を持たない断り方も文章を持ちます**。
`table.insert` に引数を多く渡す、パターンの誤り（[10.2](#102-string) の表）、
`string.format` の知らない変換、`table.concat` に文字列でない値、`table.sort` に順序でない
比較、`setmetatable` で守られたメタテーブル、`table.unpack` が多すぎる、`next` に無いキー、
`math.random` に引数 3 つ。

**メモリが足りないときも文章を持ちます**：`not enough memory` です（状態を作るときに
用意しておくので、メモリが無くても渡せます。[8. 失敗](08-failure.md)）。構文エラーも文章を持ちます。

```lua nilu
local t = {}
table.insert(t, 1, 2, 3)
```
```stderr
nilu: <manual>:2: wrong number of arguments to 'insert'
```

## 10.7. コードを読み込む

**`load` は文字列を関数にします。** ホストからは何も要りません。
`load(text [, chunkname [, mode [, env]]])` は関数を、だめなら `nil` と理由を返します。
`mode` はテキストを許すもの（`"t"` か `"bt"`）でなければならず、`env` を渡すとその関数の `_ENV` になります。

```lua nilu
local f = load("return 1 + 2")
print(f())
print(load("x =", "=example"))
print(load("return y", "=env", "t", {y = 5})())
print(load("return 1", "=b", "b"))
```
```output
3
nil	example:1:4: unexpected symbol near <eof>
5
nil	attempt to load a text chunk (mode is 'b')
```

**`require`、`dofile`、`loadfile` は、テキストをホストに求めます。** 規則はライブラリが持ち、
テキストを探して読むのはホストの読み手です（`nilu_setreader`、[12](12-embedding.md)）。
`nilu` コマンドはファイルを読む読み手を渡しています（[11.6](11-nilu-command.md#116-require-が探す場所)）。
ホストが渡していない状態では、それぞれがそう言います。

- `require(name)` はモジュールを一度だけ実行します。読み手がモジュールの鍵として答えたものが、
  `package.loaded` が結果（最初の戻り値、なければ `true`）を保つ場所で、二度目の `require` は
  保った値を返します。最初の呼び出しは、二つ目の戻り値として鍵も返します。`string` のように
  すでに `package.loaded` にある名前は、読み手に尋ねずに答えます。`package.preload` にその名前で
  関数があれば、それがモジュールの読み込み役です。読み手に尋ねる前に、名前と `":preload:"` を渡して呼ばれ、
  二つ目の戻り値は `":preload:"` です。`package.preload` を置き換えても、`require` は最初の表を使い続けます。
- `dofile(path)` はそのファイルをその場で実行し、返したものをすべて返します。失敗は投げられます。
- `loadfile(path [, mode [, env]])` は実行せずに関数を返し、だめなら `nil` と理由を返します。

```lua nilu
print(require("string") == string, package.loaded.math == math)
package.preload.greeting = function(name, from) return name .. " from " .. from end
print(require("greeting"))
print(pcall(require, "geometry"))
print(loadfile("nothing.nilu"))
```
```output
true	true
greeting from :preload:	:preload:
false	cannot find module 'geometry': no file 'geometry.nilu'
nil	cannot find file 'nothing.nilu': no file 'nothing.nilu'
```

プログラムが受け取る文:

| いつ | 何と言うか |
|---|---|
| モジュールやファイルが無い | `cannot find module 'util': <読み手の理由>`、`cannot find file 'x.nilu': <理由>` |
| 読み込み中のモジュールがもう一度求められた | `cannot load module 'a' while it is loading (a.nilu -> b.nilu -> a.nilu)` |
| ホストが読み手を渡していない | `cannot load module 'util': no reader was given to this state`（`dofile`/`loadfile` では `file`） |


## 10.8. コルーチン

**コルーチンは、途中で止まって続きから動ける関数です。** `coroutine.create(f)` で作り
（`type` は `"thread"`）、`coroutine.resume(co, …)` で、戻るか `coroutine.yield(…)` を呼ぶまで動かします。
`yield` に渡したものは `resume` が `true` のうしろに返し、次の `resume` に渡したものはその `yield` が返します。

```lua nilu
local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c = coroutine.yield(a + b)
  print("got", c)
  return "done"
end)
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, "x"))
print(coroutine.status(co), coroutine.resume(co))
```
```output
start	1	2
true	3
suspended
got	x
true	done
dead	false	cannot resume dead coroutine
```

**`coroutine.wrap(f)` は、それを再開する関数を返します。** 渡されたものを返し、失敗はそのまま上げます。
`for` のための生成器になります。

```lua nilu
local function range(n)
  return coroutine.wrap(function()
    for i = 1, n do coroutine.yield(i) end
  end)
end
for i in range(3) do print(i) end
```
```output
1
2
3
```

| 関数 | 返すもの |
|---|---|
| `coroutine.status(co)` | `"suspended"`、`"running"`、`"normal"`（別のコルーチンを再開して、それが動いている）、`"dead"` |
| `coroutine.running()` | 動いているスレッドと、それがメインのプログラムなら `true` |
| `coroutine.isyieldable([co])` | いま `yield` で止められるか |
| `coroutine.close(co)` | `true`、または失敗で終わったコルーチンなら `false` とその失敗。止まっているものは捨てます |

**`yield` は Lua と同じところを通り抜けます**。スクリプトの呼び出し、`for` の反復関数、`pcall`、`xpcall`、
メタメソッドです。`table.sort` の比較関数のような、呼び返すライブラリ関数の中では、Lua と同じく断ります。
文は Lua のものです。

```lua nilu
local co = coroutine.wrap(function()
  local ok, v = pcall(coroutine.yield, "inside pcall")
  local t = setmetatable({}, {__index = function(_, k) return coroutine.yield(k) end})
  return ok, v, t.field
end)
print(co())
print(co("resumed"))
print(co("from the metamethod"))
print(pcall(coroutine.yield))
print(coroutine.resume(coroutine.create(function()
  table.sort({3, 2, 1}, function(a, b) coroutine.yield() return a < b end)
end)))
```
```output
inside pcall
field
true	resumed	from the metamethod
false	attempt to yield from outside a coroutine
false	attempt to yield across a C-call boundary
```

失敗したコルーチンは終わります。`close` はその失敗を一度だけ返します。

```lua nilu
local co = coroutine.create(function() error("broken") end)
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.close(co))
local main, ismain = coroutine.running()
print(type(main), ismain, coroutine.isyieldable())
print(coroutine.wrap(function() return coroutine.isyieldable() end)())
```
```output
false	<manual>:1: broken
false	<manual>:1: broken
true
thread	true	false
true
```


## 10.9. `debug`

**`debug` は、プログラムがどこにいるか、関数が何かを読みます**。関数を外から書き換えるものは
入れていません（オーナーの答え）。Lua の 2 つの関数があります。

- `debug.traceback([thread,] [message [, level]])` は、メッセージと `stack traceback:`、そして
  `level` から 1 段に 1 行を返します（既定は呼んだ側の 1、別のスレッドなら 0）。名前の付け方はコマンドの
  呼び出し履歴と同じです（[11.3](11-nilu-command.md#113-失敗したときの書き方)）。文字列でも nil でもない
  メッセージは、そのまま返します。
- `debug.getinfo([thread,] f [, what])` は、関数 `f`、または段 `f` で動いている関数についてのテーブルを返し、
  最後の段より先なら nil を返します。`what` は Lua と同じ文字でフィールドを選びます。`S`（`source`、
  `short_src`、`what`、`linedefined`、`lastlinedefined`）、`l`（`currentline`）、`n`（`name`、`namewhat`）、
  `u`（`nups`、`nparams`、`isvararg`）、`t`（`istailcall`、`extraargs`）、`r`（`ftransfer`、`ntransfer`）、
  `f`（`func`）、`L`（`activelines`）です。既定は `L` 以外すべてです。

```lua nilu
local function inner() print(debug.traceback("here")) end
local function outer() inner() end
outer()
local info = debug.getinfo(outer, "S")
print(info.what, info.linedefined, info.lastlinedefined, info.short_src)
print(debug.getinfo(1, "l").currentline, debug.getinfo(50))
```
```output
here
stack traceback:
	<manual>:1: in upvalue 'inner'
	<manual>:2: in local 'outer'
	<manual>:3: in main chunk
Lua	2	2	<manual>
6	nil
```

末尾呼び出しはフレームを残さないので、`istailcall` は `false` で、`(...tail calls...)` の行も書きません。

---

次: [11. `nilu` コマンド](11-nilu-command.md)
