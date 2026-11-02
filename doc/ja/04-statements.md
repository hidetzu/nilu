[← 目次](README.md)

# 4. 文

プログラムは文のならびです。区切り文字は要りません。改行も要りません。
`;` は何もしない文として書けます。

文は次のものです。

| 文 | 書き方 |
|---|---|
| 宣言 | `local x = 1`、`local x <const> = 1`、`global x`、`global x = 1` |
| 代入 | `x = 1`、`t[k] = v`、`a, b = b, a` |
| 条件 | `if … then … elseif … then … else … end` |
| 繰り返し | `while … do … end`、`repeat … until …`、`for … do … end` |
| ブロック | `do … end` |
| 抜ける・飛ぶ | `break`、`goto 名前`、`::名前::` |
| 関数を定義する | `function f() … end`、`function t:m() … end`、`local function f() … end`、`global function f() … end` |
| 返す | `return`、`return x`、`return a, b` |
| 呼ぶ | `f(x)`、`t:m(x)`、`(f)(x)` |

## 4.1. 代入

左辺の受け手と添字は、右辺の評価前に左から右へ評価して保持します。
続いて右辺の式を左から右へすべて評価し、最後に右端のターゲットから書き込みます。
重複したターゲットや `_ENV` を置き換える同時代入も同じ順序です。
グローバル名の書き込み先は右辺の評価前に選んだ環境に固定されます。
添字付きの関数定義も同じ方法で書き込み先を準備します。

失敗した時点で処理を止めます。受け手・添字の評価中の失敗は右辺の失敗より先です。
書き込み先やキーが格納に使えるかの検査は、その格納時に行います。
それまでの書き込みや他の副作用は巻き戻しません。

```lua nilu
local x
x = 1
print(x)
```
```output
1
```

左辺はいくつでも書けます。右辺は全部評価されてから代入されるので、
入れ替えが書けます。

```lua nilu
local a, b = 1, 2
a, b = b, a
print(a, b)
```
```output
2	1
```

左辺には添字も書けます。

```lua nilu
local t = {}
t[1], t.name = "いち", "名前"
print(t[1], t.name)
```
```output
いち	名前
```

数が合わなければ、足りないところは `nil`、余ったところは捨てられます。

```lua nilu
local a, b = 1
print(a, b)
```
```output
1	nil
```

## 4.2. `if`

```lua nilu
local n = 2
if n == 1 then
  print("いち")
else
  print("いち以外")
end
```
```output
いち以外
```

`else` は省けます。条件は `false` と `nil` 以外すべて真です
（[2.2](02-values.md#22-真偽値)）。

**`elseif` があります**。

```lua nilu
local n = 2
if n == 1 then
  print("いち")
elseif n == 2 then
  print("に")
else
  print("たくさん")
end
```
```output
に
```

**`else` の中に `if` を入れたのと同じ意味です。** ただし入れ子にはなりません —— `end` は
1 つで、腕がいくつあっても深さの上限には数えません。

```lua nilu
local n = 2
if n == 1 then
  print("いち")
else
  if n == 2 then
    print("に")
  else
    print("その他")
  end
end
```
```output
に
```

## 4.3. `while`

```lua nilu
local i = 0
while i < 3 do
  i = i + 1
  print(i)
end
```
```output
1
2
3
```

条件が最初から偽なら、本体は一度も走りません。

**終わらないプログラムは書けます。** `while true do end` は止まりません。
ホストは一定の命令数ごとに呼ばれるフックを置いて止めることができますが、
`nilu` コマンドはそれを使っていないので、`Ctrl-C` でプロセスごと終わります
（[11. `nilu` コマンド](11-nilu-command.md)）。

### `repeat … until`

本体を先に走らせ、**それから**条件を調べます。条件が真になったら終わります。

```lua nilu
repeat
  print("一度は動く")
until true
```
```output
一度は動く
```

**条件は本体のローカル変数を見られます。** 本体が先に走ることと並んで、`while` との違いです。

```lua nilu
local n = 0
repeat
  n = n + 1
  local done = n >= 3
until done
print(n)
```
```output
3
```

`while` で同じことを書くと、`done` は条件の位置から見えません。
`break` は `while` と同じく `repeat` を抜けます。

## 4.4. 数値 `for`

```lua nilu
for i = 1, 3 do
  print(i)
end
```
```output
1
2
3
```

3 つめの値が歩幅です。負にもできます。

```lua nilu
for i = 3, 1, -1 do
  print(i)
end
for i = 1, 2, 0.5 do
  print(i)
end
```
```output
3
2
1
1.0
1.5
2.0
```

**初期値と歩幅が整数なら、制御変数は整数です。** 上限は浮動小数点数でもかまいません（`for i = 1, 2.5` は
1 と 2 を回ります）。そうでなければ 3 つとも浮動小数点数です。Lua と同じです。

初期値・上限・歩幅は**ループに入る前に一度だけ**評価されます。
途中で変数を書き換えても回数は変わりません。

**制御変数は読み取り専用です。**

```lua nilu-refused
for i = 1, 3 do
  i = 9
end
```

これは構文エラーです。Lua 5.5 がそうなったのを借りました。ループの中で作った関数から
書いても同じです。回数を変えたいなら
`while` を使ってください。

制御変数は毎回新しい変数です。だから各回でクロージャに捕まえると、
それぞれ別の値を持ちます。

```lua nilu
local fs = {}
for i = 1, 3 do
  fs[i] = function() return i end
end
print(fs[1](), fs[2](), fs[3]())
```
```output
1	2	3
```

歩幅が 0 のときは失敗します。

```lua nilu
for i = 1, 3, 0 do
  print(i)
end
```
```stderr
nilu: <manual>:1: 'for' step is zero
```

## 4.5. 汎用 `for`

宣言変数は反復ごとに別の変数です。クロージャはその回の値を保持し、
本体で後続変数を書き換えた場合も変更後の値を保持します。
捕捉セルは次のイテレータ呼び出し前に閉じられ、終了する nil の結果でも上書きされません。
break・return・goto・失敗・中断で退出する場合も閉じられます。
先頭変数は読み取り専用で、後続変数は代入できます。

`for 名前… in 式… do … end` は、式が返した関数を毎回呼びます。

```lua nilu
local t = {}
t[1] = "a"
t[2] = "b"
for i, v in ipairs(t) do
  print(i, v)
end
```
```output
1	a
2	b
```

`ipairs` は 1 から順に、`nil` に出会うまで回します。
`pairs` はすべてのキーをちょうど一度ずつ回します。

```lua nilu
local t = {}
t[1] = 10
t[2] = 20
t.x = 30
local sum = 0
local n = 0
for k, v in pairs(t) do
  sum = sum + v
  n = n + 1
end
print(sum, n)
```
```output
60	3
```

**`pairs` が回る順序は決まっていません。** 数のキーについてさえ決まっていません。
順序が必要なら数値 `for` を使ってください。これは Lua がしているのと同じ
「約束しない」です。合計や個数のように順序に依らないことだけが書けます。

`in` のあとは関数と状態を直接書くこともできます。`pairs(t)` はそれらを返す
だけの関数です。**4 つ目の値は、ループがどう終わっても終わるときに閉じられます**。`<close>` の
ローカル変数と同じです（[3.1](03-variables.md#31-ローカル変数)）。`io.lines(name)` はそこにファイルを渡します。

```lua nilu
local t = {}
t[1] = "ひとつ"
for k, v in next, t do
  print(k, v)
end
```
```output
1	ひとつ
```

## 4.6. `break`

いちばん内側のループを抜けます。

```lua nilu
for i = 1, 5 do
  if i == 3 then break end
  print(i)
end
```
```output
1
2
```

内側のループを抜けても外側は続きます。

```lua nilu
local n = 0
for i = 1, 3 do
  for j = 1, 3 do
    n = n + 1
    break
  end
end
print(n)
```
```output
3
```

ループの外に `break` を書くと構文エラーです。関数の本体は、
外側のループを見ません。

```lua nilu
break
```
```stderr
nilu: <manual>:1:1: break outside loop near 'break'
```

`break` は最後の文でなくてもかまいません。あとに続く文は実行されません。

**`continue` はありません。** Lua にも無いので、借りた結果です。
Lua と同じく、`goto` で書きます。

### `goto` とラベル

`goto 名前` は `::名前::` へ飛びます。前へも後ろへも飛べます。

```lua nilu
for i = 1, 3 do
  if i == 2 then goto continue end
  print(i)
  ::continue::
end
```
```output
1
3
```

ラベルが見えるのは、**そのブロックと内側のブロック**です。中で定義した関数からは見えません。
同じ名前のラベルは、外側のものが見えているあいだは置けません。

**ローカル変数のスコープの中へは飛べません。**

```lua nilu
goto f
local x = 1
::f::
print(x)
```
```stderr
nilu: <manual>:1:1: <goto f> at line 1 jumps into the scope of 'x'
```

ただし**ブロックの最後のラベル**へは飛べます。そこではブロックのローカル変数はもう終わっている、
とみなすからです。上の `goto continue` はこの形です。`repeat` の `until` の直前のラベルは
最後とみなしません —— 条件がまだ本体のローカル変数を見るからです。

## 4.7. `return`

```lua nilu
local function f()
  return 1, 2
end
print(f())
```
```output
1	2
```

**`return` はブロックの最後の文でなければなりません。**

```lua nilu
return 1
print("ここには来ない")
```
```stderr
nilu: <manual>:2:1: <eof> expected near 'print'
```

これは Lua と同じ規則です。`return` のあとに文を書けないのは、
それが決して実行されないからです。位置が指すのは `return` ではなく、
**そこにあってはいけない文の先頭**です。

値を書かなければ何も返しません。

スクリプトとして走らせたときの戻り値は**捨てられます**。
出力したいなら `print` を使ってください。プロンプトでは表示されます。

## 4.8. 呼び出しは文になれます

```lua nilu
print("呼び出しだけの行")
```
```output
呼び出しだけの行
```

**式のうち、単独で文になれるのは呼び出しだけです。**

```lua nilu-refused
1 + 2
x
```

どちらも構文エラーです。名前か `(` で始まる文は、代入か呼び出しのどちらかです（`global` で始まる宣言は除きます）。
`(f)(x)` のように括弧から始めることもできます。

## 4.9. まだ無い文

| 無いもの | 代わりに |
|---|---|
| `continue` | `goto` とブロックの最後のラベル（Lua にも無い） |

---

次: [5. 式](05-expressions.md)
