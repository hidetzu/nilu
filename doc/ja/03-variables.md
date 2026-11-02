[← 目次](README.md)

# 3. 変数とスコープ

変数は 3 種類あります。**ローカル変数**、**グローバル変数**、そして
**上位の関数のローカル変数**（アップバリュー）です。3 つめは
[6. 関数](06-functions.md)で説明します。

## 3.1. ローカル変数

`local` で宣言します。

```lua nilu
local x = 1
local y
local a, b = 10, 20
print(x, y, a, b)
```
```output
1	nil	10	20
```

値を書かなければ `nil` です。名前のほうが多ければ余りは `nil`、値のほうが多ければ
余りは捨てられます。

```lua nilu
local a, b, c = 1, 2
local d, e = 1, 2, 3
print(a, b, c, d, e)
```
```output
1	2	nil	1	2
```

同じ名前をもう一度宣言できます。新しい変数ができて、名前はそちらを指します。

```lua nilu
local x = 1
local x = 2
print(x)
```
```output
2
```

前の変数が消えるわけではありません。それを捕まえた関数からは、まだ見えています
（[6. 関数](06-functions.md)）。

### 読み取り専用のローカル

名前のあとに `<const>` を付けると、その変数には代入できなくなります。
`local <const> a, b = 1, 2` のように名前の前に書くと、並べた名前すべてに付きます。

```lua nilu
local limit <const> = 10
local t <const> = {}
t.n = limit
print(t.n)
```
```output
10
```

変数が読み取り専用になるだけで、値は変わりません。上の `t` のように、テーブルの中身は書き換えられます。

代入は、実行の前に構文エラーとして断られます。関数の中から書いても同じです。

```lua nilu-refused
local limit <const> = 10
local function grow()
  limit = 20
end
```

`attempt to assign to const variable 'limit'` と言われます。値を変えたいなら、`<const>` を
外すか、新しい `local` を宣言してください。

### 閉じられるローカル変数：`<close>`

**`<close>` を付けたローカル変数の値は、ブロックを出るときに閉じられます**。最後まで行ったときも、
`break`、`goto`、`return` で出たときも、失敗で抜けたときもです。閉じるときは値の `__close(value, err)` を、
内側の変数から順に呼びます。`err` は失敗で抜けたならその失敗の値で、そうでなければ `nil` です。
宣言するときの値は `nil`、`false`、または `__close` を持つ値でなければなりません。`<close>` の変数は
`<const>` と同じく読むだけで、1 つの宣言に 1 つまでです。Lua 5.5 と同じです。

```lua nilu
local function resource(name)
  return setmetatable({}, {__close = function(_, err) print("close " .. name, err) end})
end
do
  local a <close> = resource("a")
  local b <close> = resource("b")
  print("in block")
end
print(pcall(function()
  local c <close> = resource("c")
  error("boom", 0)
end))
print(pcall(function() local z <close> = 1 end))
```
```output
in block
close b	nil
close a	nil
close c	boom
false	boom
false	<manual>:13: variable 'z' got a non-closable value
```

`__close` が失敗すると、その失敗が抜けようとしていた失敗に取って代わり、次の `__close` と、それを
捕まえるところに渡ります。`xpcall` の中ではハンドラが先に動き、`__close` はハンドラが返したものを受け取ります。
`error()` で抜けた失敗が運ぶのは `nil` なので、`__close` からは普通に抜けたときと区別できません
（[13.1](13-differences-from-lua.md#131-違うところ)）。`<close>` のあるブロックの中の `return f()` は末尾呼び出しになりません。

**失敗で閉じるのは、その失敗を捕まえたところです**（`pcall` かホスト）。そのときには、失敗が抜けてきた関数はもうスタックにありません。Lua と同じです。
失敗したコルーチンは `coroutine.close` まで閉じずに持っていて、閉じるときにその失敗を渡します。`coroutine.wrap` で作ったものは、失敗したときに閉じます。

```lua nilu
local function resource(name)
  return setmetatable({}, {__close = function(_, err) print("close " .. name, err) end})
end
local co = coroutine.create(function()
  local r <close> = resource("r")
  error("late", 0)
end)
print(coroutine.resume(co))
print(coroutine.close(co))
```
```output
false	late
close r	late
false	late
```

## 3.2. ブロック

ローカル変数はブロックの終わりまで生きています。ブロックになるのは、
`if` の各節、`while` と `repeat` と `for` の本体、`do … end`、関数の本体、そしてプログラム全体です。

```lua nilu
local x = "外"
if true then
  local x = "内"
  print(x)
end
print(x)
```
```output
内
外
```

ブロックを抜けた名前は、もう解決されません。グローバル変数として読まれます。

```lua nilu
if true then local y = 1 end
print(y)
```
```output
nil
```

ブロックを作りたいだけのときは `do … end` と書きます。

```lua nilu
do
  local z = 1
  print(z)
end
print(z)
```
```output
1
nil
```

## 3.3. グローバル変数

宣言されていない名前はグローバル変数です。グローバル変数は、
ひとつのテーブルのフィールドです。

```lua nilu
g = 10
print(g)
print(h)
```
```output
10
nil
```

一度も代入していないグローバル変数は `nil` です。綴りを間違えても、
そこでは何も起こりません。

```lua nilu
local count = 0
cuont = count + 1
print(count, cuont)
```
```output
0	1
```

`cuont` という名前のグローバル変数ができただけで、`count` は 0 のままです。
**これは黙って通ります。** それが嫌なときに使うのが次の節です。

### ホストと同じテーブルを見ています

グローバル変数が入っているテーブルは、ホストプログラムが
`nilu_getglobal` と `nilu_setglobal` で読み書きするテーブルと同じものです。
ホストが関数を置けば、プログラムはそれを名前で呼べます
（[12. C から埋め込む](12-embedding.md)）。`print` がそうやって来ています。

### `_ENV`

グローバル変数 `x` は、実のところ `_ENV.x` です。`_ENV` は普通の名前なので、
ローカル変数として隠せます。

```lua nilu
local p = print
local _ENV = {}
x = 1
p(x)
```
```output
1
```

ここで `x` は新しい空テーブルのフィールドになります。`print` はもう名前では
引けません（新しい `_ENV` に入っていないので）。だから先にローカル変数へ
取ってあります。

これは Lua と同じ仕掛けで、Nilu 側に特別な実装はありません。名前の解決が
`_ENV` を見つけ、`_ENV.x` への添字に組み立てられるだけです。

## 3.4. `global` 宣言

綴り間違いを構文エラーに戻したいときは、使うグローバル変数を宣言します。

```lua nilu
global count, print
count = 0
count = count + 1
print(count)
```
```output
1
```

**プログラムの中で `global` を一度でも使うと、そのブロックでは宣言していない
グローバル変数が構文エラーになります。**

⚠ **`print` も宣言されていることに注意してください。** ホストが置いた名前も
グローバル変数です。`global count` だけ書いて `print` を使うと、`print` のところで
構文エラーになります。

```lua nilu
global count
count = 1
print(count)
```
```stderr
nilu: <manual>:3:1: variable 'print' not declared
```

これは厳しく見えますが、そういうものを頼むための機能です。使うものを全部書くか、
次の `global *` で全部許すかのどちらかになります。

```lua nilu
global count, print
cuont = 1
```
```stderr
nilu: <manual>:2:1: variable 'cuont' not declared
```

位置が出るので、どこで間違えたかがすぐ分かります。宣言しなければ、打ち間違いは走らせたときに
`nil` として現れるだけです。

全部まとめて許すこともできます。

```lua nilu
global *
anything = 1
print(anything)
```
```output
1
```

`global` の効き目はブロックの終わりまでです。ローカル変数と同じです。

```lua nilu
if true then
  global x
  x = 1
end
y = 2
print(x, y)
```

```output
1	2
```

`y` は `global` 宣言の外にあるので、何も要求されません。

### 宣言して値を入れる

宣言と同時に値を入れられます。関数も同じように定義できます。

```lua nilu
global print
global limit = 10
global function twice(x)
  return x * 2
end
print(twice(limit))
```
```output
20
```

`global a, b = 1, 2` は、並べた名前すべてに入れます。宣言だけしたい名前は、別の `global` に書いてください。

**この 2 つの形は、そのグローバル変数がまだ `nil` であることを確かめてから入れます。**
すでに値があると、実行時に失敗します。ホストが置いた名前をうっかり上書きしないためです。

```lua nilu
global function print() end
```
```stderr
nilu: <manual>:1: global 'print' already defined
```

上書きしたいときは、宣言してから普通に代入してください（`global print` のあとで `print = …`）。

### 読み取り専用のグローバル

`<const>` を付けると、代入は構文エラーになります。宣言のときの初期化はできます。

```lua nilu
global print
global version <const> = "1.0"
print(version)
```
```output
1.0
```

```lua nilu-refused
global version <const> = "1.0"
version = "2.0"
```

`global <const> *` は、名前を挙げて宣言したもの以外を、すべて読み取り専用にします。

### ローカル変数との前後

`global x` は、それより前に宣言したローカル変数 `x` を隠します。その後の `x` はグローバル変数です。

```lua nilu
local x = 1
global print, rawget, x
x = 2
print(rawget(_ENV, "x"))
```
```output
2
```

`global *` は何も隠しません。

**`global` は普通の名前のままです。** 変数名に使えます。Lua 5.5 のマニュアルは `global` を予約語と
書いていますが、配布されている Lua の既定の設定（`LUA_COMPAT_GLOBAL`）でも普通の名前で、Nilu はそれと同じです。

```lua nilu
local global = 1
print(global)
```
```output
1
```

---

次: [4. 文](04-statements.md)
