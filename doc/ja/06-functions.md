[← 目次](README.md)

# 6. 関数

関数は値です。名前は後から付けるものです。

## 6.1. 作る

```lua nilu
local double = function(x) return x * 2 end
print(double(21))
```
```output
42
```

自分を呼ぶ関数は `local function` で書きます。名前が本体より先に作られるので、
本体から自分が見えます。

```lua nilu
local function fact(n)
  if n <= 1 then return 1 end
  return n * fact(n - 1)
end
print(fact(5))
```
```output
120
```

**`function f() … end` と書けます**。
**意味は `f = function() … end` です** —— グローバル変数への代入で、そこは変わりません。

```lua nilu
function f() return 1 end
print(f())
```
```output
1
```

`function t.g() … end` も書けて、`t.g = function() … end` と同じです。

### メソッド —— `function t:m()` と `t:m()`

`function t:m(a)` は **`self` を暗黙の第 1 引数として宣言**し、書いた引数はその後ろに並びます。

```lua nilu
local counter = {}
counter.n = 0

function counter:add(k)
  self.n = self.n + k
  return self.n
end

print(counter:add(5))
print(counter:add(2))
print(counter.add(counter, 1))
```
```output
5
7
8
```

最後の行が示すとおり、**`t:m(x)` が呼ぶ関数は `t.m` そのもの**です。`self` は特別な名前では
なく**ふつうのローカル変数**で、**予約語ではありません** —— `local self = 1` と書けます。

⚠ **ただし `t:m(x)` は `t.m(t, x)` と同じではありません。** **受け手は一度だけ評価されます。**

```lua nilu
local calls = 0
local box = {}
function box:get() return "値" end
local function receiver() calls = calls + 1 return box end

print(receiver():get(), calls)
```
```output
値	1
```

`receiver().get(receiver())` と書けば `receiver` は 2 回呼ばれます。**`:` はこの差のために
あります。**

**文字列のメソッドも同じように呼べます** —— `s:upper()` は `string.upper(s)` です。

⚠ **グローバルを宣言しているプログラムでは、`function f()` の `f` も宣言が要ります**
（[3.4](03-variables.md#34-global-宣言)）。`f = function() end` と同じ扱いで、
書き方が変わっても規則は変わりません。

## 6.2. 引数

足りない引数は `nil`、余った引数は捨てられます。

```lua nilu
local function f(a, b) return a, b end
print(f(1))
print(f(1, 2, 3))
```
```output
1	nil
1	2
```

引数はいつも値で渡されます。テーブルを渡したときに渡っているのは
テーブルへの参照なので、呼ばれた側が中身を変えれば呼んだ側にも見えます。

```lua nilu
local function fill(t) t[1] = "入れた" end
local t = {}
fill(t)
print(t[1])
```
```output
入れた
```

## 6.3. 宣言していない引数 — `...`

引数のならびの最後に `...` と書くと、宣言した分より後ろの引数を受け取れます。

```lua nilu
local function count(...)
  return select("#", ...)
end
print(count(), count(1), count(1, 2, 3))
```
```output
0	1	3
```

`select("#", ...)` が個数、`select(n, ...)` が n 番目から後ろ全部です。

**チャンク（ファイル全体）も `...` を受け取れる関数です。** `nilu` コマンドはスクリプトの引数を
そこへ渡します（[11.1](11-nilu-command.md#111-走らせ方)）。

```lua nilu
local function f(first, ...)
  print(first, select(1, ...))
  print(select(2, ...))
end
f("あ", "い", "う")
```
```output
あ	い	う
う
```

`...` はならびの中では最後の位置でだけ広がります。これは呼び出しと同じ規則です
（[5.6](05-expressions.md#56-複数の値)）。

```lua nilu
local function f(...)
  print(..., "後ろ")
  return table.pack(...).n
end
print(f(1, 2))
```
```output
1	後ろ
2
```

`table.pack(...)` はテーブルに詰めて、個数を `n` に入れて返します。`#` と違って、`nil` が
混ざっていても `n` の個数は正しく数えられます。

**`...` の後ろに名前を書くと、そのテーブルに名前が付きます。** Lua 5.5 と同じく、`...rest` は
宣言した分より後ろの引数と、その個数 `n` を入れたテーブルを `rest` に束ねます。呼び出しごとに
新しいテーブルで、後ろの引数が無ければ `n` が `0` のテーブルです。

```lua nilu
local function f(first, ...rest)
  print(first, #rest, rest.n, rest[2])
end
f("あ", "い", nil)
f("あ")
```
```output
あ	1	2	nil
あ	0	0	nil
```

**`...` もそのまま使え、そのテーブルのいまの中身を読みます。** フィールドを変えると `...` が
返すものも変わり、`n` が返す個数です。

```lua nilu
local function f(...rest)
  rest[1] = "かえた"
  rest.n = 1
  return select("#", ...), ...
end
print(f("あ", "い"))
```
```output
1	かえた
```

`n` が `0` から `1073741823`（Lua の上限）までの整数でないと、`...` は
`vararg table has no proper 'n'` で失敗し、スタックに入りきらない数なら `stack overflow` で失敗します。
`n` を変えても、`...` を読むまでは何も起きません。

**名前は読み取り専用です。** `<const>` と同じで（[3.1](03-variables.md#31-ローカル変数)）、`rest = {}` は
`attempt to assign to const variable 'rest'` で断られます。変えるならフィールドを変えてください。`...name` は
最後の引数にだけ書け、属性は付けられません。`function(...rest, a)` も `function(...rest <const>)` も
構文エラーです。`...[1]` は Lua 5.5 にもありません（`lua5.5` 5.5.1 は `')' expected near '['` で断ります）。

## 6.4. クロージャ

関数の本体は、まわりのローカル変数を見られます。**見ているだけでなく、同じ変数を
共有します。**

```lua nilu
local function counter()
  local n = 0
  return function()
    n = n + 1
    return n
  end
end
local next1 = counter()
print(next1(), next1(), next1())
```
```output
1	2	3
```

同じ変数を 2 つの関数で共有できます。

```lua nilu
local function pair()
  local n = 0
  local get = function() return n end
  local inc = function() n = n + 1 end
  return get, inc
end
local get, inc = pair()
inc()
inc()
print(get())
```
```output
2
```

`counter()` を 2 回呼べば、`n` は 2 つできます。捕まえられるのは
「そのとき走っていたブロックの変数」です。

```lua nilu
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local a = counter()
local b = counter()
print(a(), a(), b())
```
```output
1	2	1
```

## 6.5. 末尾呼び出し

`return f(…)` という形の呼び出しは、**いまのフレームを作り直して使います**。
だから何回でも繰り返せます。

```lua nilu
local function loop(n)
  if n == 0 then return "終わり" end
  return loop(n - 1)
end
print(loop(100000))
```
```output
終わり
```

10 万回の呼び出しですが、深さは増えていません。これはループを関数で書いたものです。

**そのかわり、深さの上限がこの形を守らなくなります。**

```lua nilu-source
local function forever() return forever() end
```

これは構文としては正しく、`while true do end` と同じものです。止まりません。
（このマニュアルの例はすべて実行されますが、この一つだけは走らせていません。
終わらないものは結果を持たないからです。）
`return f()` と `return (f())` は別物で、後者は末尾呼び出しになりません
（括弧が値を 1 つに切り詰めるので、呼び出しの結果を受け取る必要があるからです）。

末尾呼び出しでない再帰には深さの上限があります。

```lua nilu
local function deep(n) return 1 + deep(n) end
print(select(2, pcall(deep, 1)))
```
```output
<manual>:1: stack overflow
```

上限は決まった数で、変えられません。

（`pcall` で受けているのは、**この例を 1 行にしておくため**です。受けずに走らせると
コマンドが**呼び出し履歴も印字します** —— そちらは [11.3](11-nilu-command.md#113-失敗したときの書き方) にあります。）

## 6.6. 関数を値として扱う

```lua nilu
local t = {}
t.add = function(a, b) return a + b end
local f = t.add
print(f(1, 2), t.add(3, 4))
```
```output
3	7
```

`t:method(x)` と `function t:method(x) … end` も書けます（[6.1](#61-作る)の「メソッド」）。

ホストが C で書いた関数も、プログラムから見れば同じものです。区別する方法は
ありません。

```lua nilu
print(type(print), type(function() end))
```
```output
function	function
```

---

次: [7. メタテーブル](07-metatables.md)
