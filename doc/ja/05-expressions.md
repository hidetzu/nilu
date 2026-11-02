[← 目次](README.md)

# 5. 式

## 5.1. 演算子と優先順位

下にあるものほど強く結びつきます。

| 優先順位 | 演算子 | 結合 |
|---|---|---|
| 1（弱い） | `or` | 左 |
| 2 | `and` | 左 |
| 3 | `<` `>` `<=` `>=` `~=` `==` | 左 |
| 4 | `\|` | 左 |
| 5 | `~` | 左 |
| 6 | `&` | 左 |
| 7 | `<<` `>>` | 左 |
| 8 | `..` | **右** |
| 9 | `+` `-` | 左 |
| 10 | `*` `/` `//` `%` | 左 |
| 11 | `not` `#` `-`（符号反転） `~`（ビット反転） | 右（単項） |
| 12（強い） | `^` | **右** |

Lua の優先順位をそのまま借りています。

```lua nilu
print(1 + 2 * 3)
print(2 ^ 3 ^ 2)
print(-2 ^ 2)
```
```output
7
512.0
-4.0
```

`2 ^ 3 ^ 2` が `2 ^ (3 ^ 2)` で、`-2 ^ 2` が `-(2 ^ 2)` なのは、
`^` が右結合で単項マイナスより強いからです。

## 5.2. 算術

```lua nilu
print(7 + 2, 7 - 2, 7 * 2, 7 / 2)
print(7 // 2, 7 % 2, 2 ^ 10)
```
```output
9	5	14	3.5
3	1	1024.0
```

**整数どうしの `+`、`-`、`*`、`//`、`%` と単項の `-` は整数を返し、どちらかが浮動小数点数なら浮動小数点数を
返します。`/` と `^` はいつも浮動小数点数を返します。** 整数は Lua と同じく 64 ビットを超えると折り返します。

```lua nilu
print(7 // 2.0, 3 * 1.0, 2 ^ 2)
print(math.maxinteger + 1 == math.mininteger)
```
```output
3.0	3.0	4.0
true
```

`/` はいつも実数の除算です。`//` は切り捨て除算で、
**負の数では 0 ではなく負の無限のほうへ切り捨てます**。

```lua nilu
print(-7 // 2, 7 // -2)
print(-7 % 2, 7 % -2)
```
```output
-4	-4
1	-1
```

`%` は `a - (a // b) * b` と定義されています。だから結果の符号は右側に揃います。
C や Rust の `%` とは違い、Python と同じです。これは Lua の定義です。

**整数を整数の 0 で `//` や `%` で割ると実行時エラーです。** 文は Lua のものです。浮動小数点数を 0 で割ると、
無限か NaN が返ります。

```lua nilu
local n = 0
print(pcall(function() return 7 // n end))
print(pcall(function() return 7 % n end))
print(7 // 0.0, -7 // 0.0)
```
```output
false	<manual>:2: attempt to divide by zero
false	<manual>:3: attempt to perform 'n%0'
inf	-inf
```

数でないものを足すと失敗します。文字列は数になりません。

```lua nilu
return "1" + 1
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a string value (constant '1')
```

括弧の中は**どの値だったか**です。
ここは Lua では失敗しないので（`"1"` を 1 に変換します）、
**この行そのものは Lua には出ません**。括弧の付け方は Lua の規則どおりです。

Lua は `"1" + 1` を 2 にしますが、Nilu はしません。`tonumber` を書いてください。

### ビット演算子

`&`（論理積）、`|`（論理和）、`~`（排他的論理和）、`<<`、`>>` と単項の `~`（反転）は、Lua と同じく整数に
64 ビットの 2 の補数で働きます。`>>` は 0 を詰めます。負の数だけずらすと逆向きになり、64 以上なら 0 です。

```lua nilu
print(5 & 3, 5 | 3, 5 ~ 3, ~5)
print(1 << 4, 256 >> 4, 2 >> -1, 1 << 64)
```
```output
1	7	6	-6
16	16	4	0
```

**浮動小数点数のオペランドは同じ値の整数に直します。そういう整数がないものは断ります。** 文は Lua のものです。

```lua nilu
local x = 1.5
print(pcall(function() return x & 1 end))
print(3.0 | 0, 1 << 60, -1 >> 1)
```
```output
false	<manual>:2: number (upvalue 'x') has no integer representation
3	1152921504606846976	9223372036854775807
```

文字列は算術と同じく断ります。Lua 5.5 も断ります。

## 5.3. 比較

```lua nilu
print(1 == 1, 1 ~= 2, 1 < 2, 2 <= 2, 3 > 2, 3 >= 4)
```
```output
true	true	true	true	true	false
```

整数と浮動小数点数はどちらも数で、Lua と同じく**正確な値どうしで比べます**。間で丸めることはありません。

```lua nilu
print(1 == 1.0, math.maxinteger < 2^63, math.maxinteger + 0.0 == 2^63)
```
```output
true	true	true
```

`==` は型が違えば偽です。変換しません。

```lua nilu
print(1 == "1", nil == false)
```
```output
false	false
```

テーブルと関数は**同じものかどうか**で比べます。中身は見ません。

```lua nilu
local a = {}
local b = {}
print(a == a, a == b)
```
```output
true	false
```

順序の比較は、数同士か文字列同士でなければ失敗します。

```lua nilu
return 1 < "a"
```
```stderr
nilu: <manual>:1: attempt to compare number with string
```

これは Lua と同じで、`==` が false を返すのに `<` が失敗するのは意図された非対称です。
等しいかは誰にでも訊けますが、順序は型に属しているからです。

## 5.4. `and`、`or`、`not`

`and` と `or` は真偽値を返しません。**どちらかの側をそのまま返します。**

```lua nilu
print(1 and 2, nil and 2, false and 2)
print(1 or 2, nil or 2, false or "既定値")
```
```output
2	nil	false
1	2	既定値
```

- `a and b` は、`a` が偽なら `a`、そうでなければ `b`
- `a or b` は、`a` が真なら `a`、そうでなければ `b`

右側は必要になるまで評価されません。これが短絡です。

```lua nilu
local function boom() print("呼ばれた") return 1 end
local x = false and boom()
local y = true or boom()
print(x, y)
```
```output
false	true
```

`boom` は一度も呼ばれていません。

`not` だけは真偽値を返します。

```lua nilu
print(not nil, not 0, not not nil)
```
```output
true	false	false
```

既定値を書くときの定番は `or` です。**ただし `false` が入っている変数には使えません。**

```lua nilu
local function greet(name)
  local who = name or "名無し"
  return "やあ、" .. who
end
print(greet("Nilu"))
print(greet(nil))
```
```output
やあ、Nilu
やあ、名無し
```

```lua nilu
local flag = false
print(flag or true)
```
```output
true
```

2 つめは `false` を渡したのに `true` になっています。`false` は偽なので
`or` が右側を返すからです。真偽値の既定値には `if` を使ってください。

## 5.5. 文字列をつなぐ、長さをとる

```lua nilu
print("a" .. "b" .. "c")
print(#"abc", #{})
```
```output
abc
3	0
```

`..` は右結合です。`#` は文字列ならバイト数、テーブルなら境界です
（[2.5](02-values.md#25-テーブル)）。

`#` はメタテーブルの `__len` を見ます（[7.4](07-metatables.md#74-演算子)）。

```lua nilu
local mt = {}
mt.__len = function() return 42 end
local t = {}
setmetatable(t, mt)
print(#t, rawlen(t))
```
```output
42	0
```

`rawlen` はメタテーブルを通しません。

## 5.6. 複数の値

関数の呼び出しは、いくつでも値を返せます。

```lua nilu
local function two() return 1, 2 end
print(two())
```
```output
1	2
```

**ならびの中では、最後の式だけが広がります。** 途中に書いた呼び出しは
1 つの値に切り詰められます。

```lua nilu
local function two() return 1, 2 end
print(two(), 9)
print(9, two())
```
```output
1	9
9	1	2
```

括弧で囲むと 1 つになります。

```lua nilu
local function two() return 1, 2 end
print((two()))
```
```output
1
```

これは Lua の規則で、一度は必ず驚くところです。`(f())` は「`f()` の最初の値」です。

**テーブルコンストラクタの中でも同じです**（[2.5](02-values.md#25-テーブル)）。

```lua nilu
local function two() return 1, 2 end
print(#{two()}, #{two(), 9}, #{9, two()})
```
```output
2	2	3
```

値が足りないところは `nil` で埋められます。

```lua nilu
local function none() end
local a, b = none()
print(a, b)
```
```output
nil	nil
```

## 5.7. 呼び出しの書き方

```lua nilu
local t = {}
t.greet = function(name) return "やあ、" .. name end
print(t.greet("Nilu"))
```
```output
やあ、Nilu
```

**引数が文字列ひとつなら、括弧を省けます**。

```lua nilu
print "括弧なし"
```
```output
括弧なし
```

`print "x"` は `print("x")` です。テーブル 1 つを渡すときも括弧を省けます
（`f{…}` と `t:m{…}`）。

```lua nilu
local function count(t) return #t end
print(count{1, 2, 3})
```
```output
3
```

**メソッド呼び出しの `:` があります**。
`t:m(x)` は `t.m(t, x)` **ではありません** —— **受け手は一度だけ評価されます**。

```lua nilu
local calls = 0
local t = {}
t.twice = function(self, n) return n * 2 end
local function get() calls = calls + 1 return t end
print(get():twice(21), calls)
```
```output
42	1
```

**文字列のメソッドも同じように呼べます** —— `s:upper()` は `string.upper(s)` です。

---

次: [6. 関数](06-functions.md)
