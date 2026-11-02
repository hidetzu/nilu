[← 目次](README.md)

# 8. 失敗

**Nilu には例外がありません。** 失敗はその場で呼び出しを巻き戻します。`try` にあたる構文は
ありません。捕まえるのは `pcall` と `xpcall` です。

できるのは 3 つです。

- 失敗しないように書く
- `pcall` で捕まえる（[8.4](#84-error-と-pcall)）
- ホスト側で、失敗したことを受け取る

## 8.1. 失敗したらどうなるか

失敗はその場で全部を巻き戻して、**`pcall` か、無ければホストまで戻ります**。
下の例には `pcall` が無いので、ホストまで戻ります。

```lua nilu
print("ここは出る")
print(1 + nil)
print("ここは出ない")
```
```output
ここは出る
```
```stderr
nilu: <manual>:2: attempt to perform arithmetic on a nil value
```

1 行めの出力は実際に出ています。2 行めで失敗し、3 行めは実行されません。
**途中までの作用は残ります。** 巻き戻すのは呼び出しの深さだけで、
書いたものや入れたものは元に戻りません。

ホストが受け取るのは**種類と、失敗が運ぶ値 1 つ**です。中核の失敗はその値に
**Lua と同じ文章**を入れます——`<チャンク名>:<行>: ` を頭に付けた 1 行で、
上の `nilu: ` のあとに出ているのがそれです。
いまコマンドが自分の言葉を使うのは、**`error()` が `nil` を投げたとき**、**文字列でない値を投げたとき**、
**読み込みの途中でメモリが尽きたとき**（`out of memory`）、そして**プロンプトで `print` が呼べなかったとき**
（`error calling 'print' (type error)`）です（[11.3](11-nilu-command.md#113-失敗したときの書き方)）。
ライブラリの拒否は文章を持ち、呼び出しの中で尽きたメモリ不足も `not enough memory` を運びます。
読み込みで尽きたときだけ、文章を組むメモリも無いので何も運びません。

**どの変数だったかも括弧で付きます**——
`attempt to index a nil value (local 't')` の形で、
`local`・`global`・`field`・`method`・`upvalue`・`constant`・`for iterator` の 7 種です。
`t[k]` や `t[1]` のように名前でないキーで引いたフィールドは、Lua と同じく `field '?'` と書きます。
**言えないときは何も書きません。** 比べる失敗には Lua も付けませんし、
メタテーブルから出てきた値はどのレジスタにも入っていないので名前がありません。
嘘の名前を書くより何も書かないほうがよいという判断で、これも Lua と同じです。

## 8.2. 失敗の種類

ホストが区別できるのは次のものです。

| 種類 | 何が起きたか | プログラムから起こせるか |
|---|---|---|
| 構文エラー | ソースがプログラムとして読めなかった | はい（読み込み時） |
| 型エラー | その型にできないことをした | はい |
| 実行時エラー | 関数が失敗を返した、または `error` で値を投げた | はい |
| 呼び出しが深すぎる | 末尾呼び出しでない再帰が上限に達した | はい |
| 中断 | ホストのフックが止めた | ホストだけ |
| メモリ不足 | 確保できなかった | はい（使い切れば。決まった形では起こせません） |
| スタックが満杯 | — | — |

**構文エラーには行と桁が、実行時の失敗には行が付きます。**

```lua nilu
local = 1
```
```stderr
nilu: <manual>:1:7: <name> expected near '='
```

```lua nilu
local t = {}
local x = t.a.b
```
```stderr
nilu: <manual>:2: attempt to index a nil value (field 'a')
```

実行時の失敗の行は、**失敗した命令がどの行から来たか**です。Lua と同じく、
2 行にまたがる式では演算子のある行、呼び出しでは引数を開く `(` か `{` の行、文字列を 1 つ渡す呼び出しではその文字列が終わる行になります。
桁は付きません（Lua も実行時には行しか記録していません）。

```lua nilu
local f = nil
f
(1)
```
```stderr
nilu: <manual>:3: attempt to call a nil value (local 'f')
```

## 8.3. 型エラーになるもの

```lua nilu
return 1 + nil
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a nil value
```

```lua nilu
return #5
```
```stderr
nilu: <manual>:1: attempt to get length of a number value
```

```lua nilu
return 1 < "a"
```
```stderr
nilu: <manual>:1: attempt to compare number with string
```

```lua nilu
local n = 5
return n.field
```
```stderr
nilu: <manual>:2: attempt to index a number value (local 'n')
```

```lua nilu
local x = nil
return x()
```
```stderr
nilu: <manual>:2: attempt to call a nil value (local 'x')
```

ホストが渡していない名前を呼ぶと（`io` を持たないホストでの `io` など）、これと同じ失敗になります。

## 8.4. `error` と `pcall`

**失敗は値を 1 つ運べます。** `error(v)` が `v` を投げ、`pcall(f, …)` がそれを捕まえます。
捕まえたら `false` と値、捕まえるものが無ければ `true` と `f` の戻り値です。

```lua nilu
print(pcall(error, "boom"))
local t = {}
t.code = 7
local ok, e = pcall(error, t)
print(ok, e.code)
print(pcall(function() return 1, 2 end))
```
```output
false	boom
false	7
true	1	2
```

どんな値でも投げられます。文字列なら言葉を、テーブルなら構造を運びます。
**中核はそこに何も足しません**——位置も、文章も。

**`error` で投げたのではない失敗**も `pcall` は捕まえます。**中核の失敗は文章を運びます**——
型エラー、呼び出しが深すぎる、`for` の歩幅が 0、どれも Lua と同じ 1 行です
（[8.1](#81-失敗したらどうなるか)）。**ライブラリの断りも文章を運びます**——
`bad argument #1 to 'rep' (string expected, got no value)` の形で、
どの引数のどの関数かを言います（[10.6](10-library.md#106-引数が違うときどうなるか)）。
**引数の番号を持たない断り方も文章を持ちます**——パターンの誤り、
`table.insert` に引数を多く渡す、`table.sort` に順序でない比較など。
`nil` のままなのは、**`error()` のように自分で `nil` を投げたとき**だけです
（`__tostring` が文字列を返さないときも文章を持ちます）。
**メモリが足りないときは `not enough memory` を持ちます。** 状態を作るときにこの文章を
用意しておくので、メモリが無くても渡せます（Lua と同じです）。

```lua nilu
print(pcall(function() return nil + 1 end))
print(pcall(string.rep))
```
```output
false	<manual>:1: attempt to perform arithmetic on a nil value
false	bad argument #1 to 'rep' (string expected, got no value)
```

文字列を投げると、Lua と同じく**どこで投げたかが頭に付きます**——`error` を呼んだ関数の
チャンク名と行です。`level` で何段上を指すかを選べ、`0` なら何も付きません。

```lua nilu
local function f()
  error("in f")
end
local ok, e = pcall(f)
print(e)
local function g()
  error("up", 2)
end
local function h()
  g()
end
local ok2, e2 = pcall(h)
print(e2)
print(pcall(error, "bare", 0))
```
```output
<manual>:2: in f
<manual>:10: up
false	bare
```

`pcall(error, "x")` は `x` のままです。`level` 1 が指すのは `error` を呼んだ `pcall` で、
C の関数には行が無いからです（Lua も同じ答えを返します）。同じ理由で `pcall(g)` の中の
`error("up", 2)` も `up` のままです——`level` 2 が `pcall` を指すので。

**Lua との違い**：

- **ホストの中断は捕まえられません**。フックが止めると、`pcall` が何重にあっても呼び出しは
  ホストまで巻き戻ります（[8.7](#87-止まらないプログラム)）。間にある C の関数がそれをどう扱っても同じです。
  Lua の `pcall` は中断も捕まえます。

捕まえた後の状態は元のままです。`pcall` を繰り返しても、フレームも変数も積み上がりません。

### 8.4.1. `xpcall`

**`xpcall(f, ハンドラ, …)`** は `pcall` と同じですが、**失敗したときにハンドラを通します**。
成功すれば `true` と結果のすべて、失敗すれば `false` と**ハンドラの第 1 結果**です。

```lua nilu
print(xpcall(function() return 1, 2 end, print))
print(xpcall(function() error("こわれた") end, function(m) return "H: " .. m end))
```
```output
true	1	2
false	H: <manual>:2: こわれた
```

**ハンドラは f より先に検査されます。** f が成功する場合でも、関数でなければ断ります。

```lua nilu
print(pcall(function() return xpcall(function() return 1 end, 42) end))
```
```output
false	<manual>:1: bad argument #2 to 'xpcall' (function expected, got number)
```

**ハンドラ自身が失敗すると `error in error handling` です**（Lua と同じ文面）。Lua はそこでハンドラを
上限まで呼び直しますが、Nilu は 1 回で止めます（13.1）。**ライブラリ関数の中でメモリが尽きたときは、
ハンドラが走ります**（受け取るのは `not enough memory`。Lua は走らせません。13.1）。
**ハンドラが何も返さなければ `nil`** です（Lua は `<no error object>` という印を返しますが、
ここでは失敗が運ぶのは値で、無ければ `nil` です）。

```lua nilu
print(xpcall(function() error("a") end, function() error("b") end))
print(xpcall(function() error("a") end, function() end))
```
```output
false	error in error handling
false	nil
```

**ハンドラは Lua と同じ場所で呼ばれます** —— **失敗したフレームの上、巻き戻す前**です。

`nilu_pcall` がハンドラを運び、VM が raise 地点で呼びます（[12.5.1](12-embedding.md#1251-失敗したところを見る)）。

**プログラムから見えるものは、ハンドラを巻き戻す前に呼んでも後に呼んでも同じです。** 違いが出るのは**ハンドラが知れること**で、
ホストが書くハンドラなら `nilu_where` でフレームの鎖を歩けます
（[12.5.1](12-embedding.md#1251-失敗したところを見る)）。
追加の引数は f に渡ります。

## 8.5. `assert`

条件が偽なら失敗します。真なら**引数をすべて返します**。

```lua nilu
print(assert(1 == 1, "通る"))
print(select("#", assert(true, "x")))
```
```output
true	通る
2
```

だから `local x = assert(f())` と書けます。`f` が返した最初の値が `x` に入ります。

```lua nilu
local function find(t, k)
  if t[k] == nil then return nil end
  return t[k], k
end
local t = {}
t.name = "Nilu"
local value, key = assert(find(t, "name"))
print(value, key)
```
```output
Nilu	name
```

**`assert` は受け取った引数をすべて返します**。

**第 2 引数は失敗が運ぶ値になります**（[8.4](#84-error-と-pcall)）。`nilu` コマンドは
文字列ならそのまま表示します。省けば `assertion failed!` です。

```lua nilu
assert(1 == 2, "通らない")
```
```stderr
nilu: <manual>:1: 通らない
```

```lua nilu
print(pcall(assert, false))
```
```output
false	assertion failed!
```

## 8.6. 失敗ではないもの

次のものは失敗しません。驚くかもしれませんが、どれも Lua と同じです。

```lua nilu
local t = {}
print(t.missing)
print(1 / 0, 0 / 0)
print(#"")
print(nil == false)
```
```output
nil
inf	nan
0
false
```

- 持っていないキーを読むのは `nil`
- 0 で割るのは無限
- 空の長さは 0
- 違う型を `==` で比べるのは `false`

キーになれない値を**読む**のも失敗しません。**書く**と失敗します
（[2.5](02-values.md#nil-と-nan-以外はどれもキーになれます)）。

## 8.7. 止まらないプログラム

**無限ループは失敗ではありません。** 文法としても正しく、止める手段は
言語の中にはありません。

ホストは一定の VM 命令ごとに呼ばれるフックを置いて、止めるよう言えます。
そのときホストが受け取るのが「中断」です。`nilu` コマンドはフックを置いていないので、
`Ctrl-C` でプロセスごと終わることになります。

これは「気づいていない穴」ではなく、**ホストが決めることだと決めた**結果です。
ホストの関数も同じで、ホストが書いた関数が返ってこなければフックは止められません。

---

次: [9. ガベージコレクション](09-gc.md)
