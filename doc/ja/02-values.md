[← 目次](README.md)

# 2. 値と型

プログラムが書ける値は 6 種類です。もう 1 つ、ホストが渡す `userdata` があります（下の表のあとで説明します）。

| 型 | `type` が返す文字列 | 書き方 |
|---|---|---|
| nil | `"nil"` | `nil` |
| 真偽値 | `"boolean"` | `true`、`false` |
| 数 | `"number"` | `1`、`3.5`、`0x10`、`1e9` |
| 文字列 | `"string"` | `"こんにちは"` |
| テーブル | `"table"` | `{}` |
| 関数 | `"function"` | `function(x) return x end` |

```lua nilu
print(type(nil), type(true), type(1), type("a"), type({}), type(print))
```
```output
nil	boolean	number	string	table	function
```

数は Lua と同じく整数か浮動小数点数です（[2.3](#23-数)）。コルーチンは `thread` 型の値で、`coroutine.create` で作ります（[10.8](10-library.md#108-コルーチン)）。

**`userdata` はあります**。
ただし**プログラムから作ることはできません**——ホストが `nilu_newuserdata` で作って渡すもので、
`type` は `"userdata"` と答えます（[12.6](12-embedding.md#126-ホストのデータをプログラムに持たせる)）。
上の表に無いのはそのためです。

## 2.1. nil

値が無いことを表す値です。変数に何も入れていなければ `nil` が入っています。

```lua nilu
local x
print(x)
print(y)
```
```output
nil
nil
```

2 行目の `y` は宣言されていません。宣言されていない名前はグローバル変数で、
何も入れていないグローバル変数は `nil` です（[3. 変数とスコープ](03-variables.md)）。

テーブルに `nil` を入れることは、そのキーを消すことと同じです。
だから「一度も入れなかったキー」と「`nil` を入れたキー」は区別できません。

## 2.2. 真偽値

`false` と `nil` だけが偽で、**他のすべては真です**。`0` も `""` も真です。

```lua nilu
print(not nil, not false, not 0, not "")
```
```output
true	true	false	false
```

これは Lua と同じ規則です。C や Python から来た人が必ず一度つまずくところです。

## 2.3. 数

数は Lua と同じく**整数**か**浮動小数点数**（float）です。整数は 64 ビットの 2 の補数で、それを超えると折り返します。
浮動小数点数は 64 ビットの IEEE 754 倍精度です。どちらも型は `"number"` で、`math.type` で見分けます。

```lua nilu
print(type(1), type(1.5), math.type(1), math.type(1.0), math.type(2^53))
```
```output
number	number	integer	float	float
```

同じ値の整数と浮動小数点数は等しく、テーブルでも同じキーです。`t[2.0]` は `t[2]` です。

### 書き方

小数点か指数を書いた数値は浮動小数点数で、それ以外は整数です。64 ビットに収まらない 10 進の整数の数値は
浮動小数点数として読み、16 進のものは折り返します。Lua と同じです。

```lua nilu
print(1, 3.5, .5, 1e2, 1E-2)
print(0x10, 0xff, 0x1p4)
print(9223372036854775807, 9223372036854775808, 0xffffffffffffffff)
```
```output
1	3.5	0.5	100.0	0.01
16	255	16.0
9223372036854775807	9.223372036854776e+18	-1
```

- 10 進数は `3`、`3.5`、`.5`、`3.`、指数は `1e9`、`1E-2`
- 16 進数は `0x` で始まり、`0x1p4` のように 2 進指数も書けます
- `_` による桁区切りはありません（`1_0` は数ではありません）
- `inf` や `nan` という綴りで数を書くことはできません。無限がほしければ
  `math.huge`、NaN がほしければ `0 / 0` です

### 表示のしかた

`tostring`（と `print`）は、整数を 10 進で書き、浮動小数点数を**読み戻せる最短の桁数**で書きます。
値が整数の浮動小数点数には Lua と同じく `.0` が付くので、2 種類は出力でも見分けられます。

```lua nilu
print(1)
print(1.0)
print(0.1)
print(1 / 3)
print(2 ^ 53)
print(10 / 2)
```
```output
1
1.0
0.1
0.3333333333333333
9007199254740992.0
5.0
```

Lua は浮動小数点数を有効数字 15 桁で書き、15 桁で読み戻せなければ 17 桁で書きます（`0.33333333333333331`）。
Nilu は読み戻せる最も少ない桁で書きます。

非常に大きな浮動小数点数や小さな浮動小数点数は指数形式になります。

```lua nilu
print(1e15)
print(1e16)
print(1e-5)
```
```output
1e+15
1e+16
1e-05
```

書いた文字列が読み戻せることは保証されています。`tostring` が書いたものは
`tonumber` が読めます。

```lua nilu
print(tonumber(tostring(1 / 3)) == 1 / 3)
print(tonumber("0x10"), tonumber("  12  "), tonumber("12a"))
```
```output
true
16	12	nil
```

`tonumber` は前後の空白を許しますが、余った文字は許しません。読めなければ `nil` です。

## 2.4. 文字列

文字列はバイト列です。符号化については何も約束していません。長さはバイト数です。

```lua nilu
print(#"abc")
print(#"あ")
```
```output
3
3
```

`"あ"` が 3 なのは、ソースが UTF-8 で書かれていてそのバイトがそのまま入るからです。
Nilu は中身を解釈しません。

⚠ **ただし変数名とフィールド名は ASCII だけです。** 文字列の中身はどんなバイトでも
かまいませんが、名前に使えるのは英字・数字・`_` で、英字か `_` で始まるものだけです。

```lua nilu-refused
local あ = 1
```

テーブルのキーとしてなら、どんな文字列でも使えます。`t.ある` は書けませんが
`t["ある"]` は書けます。

```lua nilu
local t = {}
t["ある"] = 1
print(t["ある"])
```
```output
1
```

### エスケープ

**Lua と同じものがすべてあります**。

| 書き方 | 意味 |
|---|---|
| `\\` | バックスラッシュ |
| `\"` | 二重引用符 |
| `\'` | 一重引用符 |
| `\n` | 改行 |
| `\r` | 復帰 |
| `\t` | タブ |
| `\a` `\b` `\f` `\v` | ベル、後退、改ページ、垂直タブ |
| `\xXX` | 16 進数ちょうど 2 桁の 1 バイト |
| `\ddd` | 10 進数 1〜3 桁の 1 バイト（255 まで） |
| `\u{XXX}` | その符号位置の UTF-8（`7FFFFFFF` まで） |
| `\z` | 何もなし。**続く空白と改行を読み飛ばします** |
| `\` と改行 | 改行 |

```lua nilu
print("a\tb")
print("q\"q", 'q\'q')
print("\x41\66\u{3042}")
print("1\z
       2")
```
```output
a	b
q"q	q'q
ABあ
12
```

これ以外のバックスラッシュは構文エラーです。`"…"` と `'…'` の途中に生の改行は書けません
—— 改行を含めたいときは `\n`、`\` と改行、または次の長い文字列を使います。

### 長い文字列

`[[` と `]]` で囲むと、**エスケープを読まず、改行をそのまま含める**文字列になります。
`[` と `[` のあいだに `=` を挟むと（`[==[ … ]==]`）、同じ数の `=` の `]==]` まで続きます。
**開き括弧の直後の改行は文字列に入りません。**

```lua nilu
local s = [[
一行目
二行目]]
print(s)
print([==[a]]b]==])
print(#[[\n]])
```
```output
一行目
二行目
a]]b
2
```

最後の行は `\` と `n` の 2 バイトです。長い文字列の中ではバックスラッシュもただの文字です。

### つなぐ、比べる

```lua nilu
print("a" .. "b" .. "c")
print("a" < "b", "abc" < "abd", "Z" < "a")
print("1" == 1)
```
```output
abc
true	true	true
false
```

比較はバイトの順です。`"Z" < "a"` が真なのは ASCII でそうなっているからです。

`..` は文字列をつなぎ、**数は `tostring` の綴りでつながります**。

```lua nilu
print(1 .. 2, "n=" .. 1.5)
```
```output
12	n=1.5
```

**算術では、文字列は数になりません**（Lua ではなります）。

```lua nilu
return "10" + 1
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a string value (constant '10')
```

## 2.5. テーブル

唯一の入れ物です。配列も辞書もオブジェクトも、すべてテーブルです。

```lua nilu
local t = {}
t[1] = "いち"
t["key"] = "値"
t.field = "これも"
print(t[1], t["key"], t.field)
```
```output
いち	値	これも
```

`t.field` は `t["field"]` の書き方違いです。まったく同じ意味です。

### 中身を書いたまま作れます

書き方は 3 つあって、**1 つのコンストラクタに混ぜられます**。

```lua nilu
local list = {10, 20, 30}
local point = {x = 1, y = 2}
local computed = {["k"] = "文字列のキー", [1 + 1] = "計算したキー"}
local mixed = {10, x = 1, [3] = 30}
print(list[2], point.x, computed[2], mixed[1], mixed.x, mixed[3])
```
```output
20	1	計算したキー	10	1	30
```

**キーを書かない要素は 1 から順に入ります。** `{10, 20, 30}` は `t[1]`、`t[2]`、`t[3]` です。

`{x = 1}` は `{["x"] = 1}` の書き方違いです —— `t.x` が `t["x"]` なのと同じ理由です。

**区切りは `,` でも `;` でもよく、末尾に 1 つ置けます。**

```lua nilu
local t = {1, 2; 3, }
print(#t)
```
```output
3
```

**ならびの最後の要素だけが、複数の値を全部受け取ります**
（[5.6](05-expressions.md#56-複数の値) と同じ規則です）。

```lua nilu
local function three() return 1, 2, 3 end
print(#{three()}, #{0, three()}, #{(three())})
```
```output
3	4	1
```

### `nil` と NaN 以外はどれもキーになれます

```lua nilu
local t = {}
local k = {}
t[1] = "数がキー"
t["k"] = "文字列がキー"
t[1.5] = "整数でなくてもよい"
t[true] = "真偽値"
t[k] = "テーブル"
print(t[1], t["k"], t[1.5], t[true], t[k], t[{}])
```
```output
数がキー	文字列がキー	整数でなくてもよい	真偽値	テーブル	nil
```

**テーブル、関数、userdata は同一性でキーになります**。`t[k]` はその同じテーブルの下に入れたものを見つけ、
中身が同じ別のテーブル `{}` は別のキーです。Lua と同じです。

`nil` と NaN はキーになれません。**ここには読みと書きで違いがあります。** 読むぶんには失敗せず、
`nil` が返ります。

```lua nilu
local t = {}
print(t[nil], t[0 / 0])
```
```output
nil	nil
```

書こうとすると、そこで失敗します。

```lua nilu
local t = {}
t[nil] = "x"
```
```stderr
nilu: <manual>:2: table index is nil
```

この非対称は Lua から借りたものです。Lua の `luaH_get` も、入れられないキー（`nil` と NaN）に対して
「無い」と答え、書き込みのほうは失敗します。断りの文章は、何を入れようとしたかを言います
（`nil` なら `table index is nil`、NaN なら `table index is NaN`）。理屈はこうです — 読むのは質問で、
答えは「持っていない」で正しい。書くのは要求で、それは通りません。

### 長さ

`#t` は「境界」を返します。`t[n]` が `nil` でなく `t[n+1]` が `nil` であるような `n` です。

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
t[3] = "c"
print(#t)
```
```output
3
```

**穴があるテーブルでは、どの境界が返るかは決まっていません。**

```lua nilu
local t = {}
t[1] = "a"
t[3] = "c"
print(#t == 1 or #t == 3)
```
```output
true
```

これは Lua と同じ約束です。穴のある配列の長さを聞くこと自体が間違いで、
そういうときは `table.pack` で数を持ち回ってください。

## 2.6. 関数

関数は値です。変数に入れられ、テーブルに入れられ、引数として渡せます。

```lua nilu
local double = function(x) return x * 2 end
local t = {}
t.double = double
print(t.double(21))
```
```output
42
```

詳しくは [6. 関数](06-functions.md) にあります。

## 2.7. 値を文字列にする

`tostring` はどの値でも文字列にします。

```lua nilu
print(tostring(nil), tostring(true), tostring(12))
```
```output
nil	true	12
```

テーブルと関数は、型の名前とその値を見分けるための文字で表されます。

```lua nilu
print(string.sub(tostring({}), 1, 7))
print(string.sub(tostring(print), 1, 10))
```
```output
table: 
function: 
```

続く部分はそのオブジェクトを他と区別するためのもので、**実行ごとに変わります**。
形式は Lua から借りた `type: identity` です。等しいかどうかを知りたければ
`==` を使ってください。この文字列を比べるのは間違いです。

メタテーブルに `__tostring` があれば、それが答えます
（[7. メタテーブル](07-metatables.md)）。

---

次: [3. 変数とスコープ](03-variables.md)
