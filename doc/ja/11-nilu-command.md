[← 目次](README.md)

# 11. `nilu` コマンド

`nilu` は**ホストプログラムのひとつ**です。言語の一部ではありません。
`cli/nilu.c` の 1 ファイルで、公開ヘッダと静的ライブラリだけを使って書かれています。

知らないオプションを渡すと、使い方を書いて止まります。

```sh nilu-cli
nilu -x
```
```stderr
nilu: unknown option -x
usage: nilu [options] [script]
Available options are:
  -e stat   run the text 'stat'
  -i        enter the prompt after running the script
  -l mod    require library 'mod' into global 'mod'
  -l g=mod  require library 'mod' into global 'g'
  -W        turn warnings on
  -v        say which version this is
  --        stop handling options
  -         stop handling options and run stdin
```

## 11.1. 走らせ方

| 書き方 | すること |
|---|---|
| `nilu hello.nilu` | ファイルを走らせる |
| `nilu -e 'print(1 + 2)'` | テキストをそのまま走らせる |
| `nilu -e'print(1 + 2)'` | くっつけても同じ |
| `echo 'print(1)' \| nilu -` | 標準入力を走らせる |
| `nilu` | プロンプト |
| `nilu -i hello.nilu` | ファイルを走らせてからプロンプト |
| `nilu -l util hello.nilu` | 先に `util = require("util")`。`-e` と書いた順に動く（`-l u=util` ならグローバルは `u`） |
| `nilu -W hello.nilu` | `warn("@on")` のあとと同じく、警告を入れて走らせる |
| `nilu -v` | 版を表示する |

Windows では、コマンドが標準出力に書く行は、Lua のコマンドと同じく `\r\n` で終わります。それ以外では `\n` で終わります。

```sh nilu-cli
nilu -e 'print(1 + 2)'
```
```output
3
```

```sh nilu-cli
nilu -e'print("くっつけても同じ")'
```
```output
くっつけても同じ
```

標準入力から読むには `-` を渡します。

```sh nilu-cli
nilu -
```
```stdin
print(1 + 2)
```
```output
3
```

`-e` はいくつでも書けて、書いた順に走ります。

```sh nilu-cli
nilu -e 'print("ひとつめ")' -e 'print("ふたつめ")'
```
```output
ひとつめ
ふたつめ
```

版を訊くこともできます。

```sh nilu-cli
nilu -v
```
```output
nilu 0.1.0-dev.1
```

番号の後ろに `-dev.N` が付いているのは、リリースとリリースの間に作られた版です。数字はその版が向かっているリリースの番号で、N は前のリリースから数えたその版自身の番号です（最初のリリースの前は、はじめから数えます）。リリースそのものには付きません。

0.1.0 のリリースまでは、開発版同士の API・ABI・言語・コマンドの互換性を
保証しません。変更は GitHub の issue と設計判断の記録に残します。

**スクリプトの戻り値は捨てられます。** 出力したいなら `print` を使ってください。

### スクリプトに引数を渡す

スクリプトの後ろに書いたものは**スクリプトの引数**です。`...` でも、テーブル `arg` でも受け取れます
（Lua と同じです）。`arg[0]` がスクリプト自身、`arg[1]` から順に引数、負の添字にはその手前
（`nilu` と、スクリプトより前のオプション）が入ります。

```sh nilu-cli
nilu - one two
```
```stdin
print(...)
print(arg[0], arg[1], arg[2], #arg)
```
```output
one	two
-	one	two	2
```

メインチャンクは Lua と同じく **vararg な関数**なので、トップレベルで `...` が書けます
（[6.3](06-functions.md#63-宣言していない引数--)）。`-e` のテキストやプロンプトの行は引数なしで
呼ばれますが、`arg` はそこからも見えます。**スクリプトが無いときは**、Lua と同じく `arg[0]` がプログラムで、
オプションがそのあとに続きます。`nilu -e 'code'` なら `arg[1]` が `-e`、`arg[2]` がそのコードです。

### 実行可能なスクリプト

**1 行目が `#` で始まっていれば、その行は飛ばします**。
だから `chmod +x` したスクリプトがそのまま走ります。

```lua nilu-source
#!/usr/bin/env nilu
print("hello")
```

```bash
chmod +x hello.nilu
./hello.nilu
```

**行番号はずれません。** 1 行目を消すのではなく空白にしているので、3 行目の失敗は
3 行目と出ます。

**`#` だけでも飛ばします**（`#!` の 2 文字で判定していません）。Lua と同じです。

**これはコメントではありません。** 飛ばすのは**ファイルとして読んだものの 1 行目**だけで、
`-e` のテキストは飛ばしません。

```sh nilu-cli
nilu -e '#print(1)'
```
```stderr
nilu: (command line):1:1: unexpected symbol near '#'
```

標準入力（`nilu -`）は**ファイルとして読む側**なので飛ばします。Lua では
`lauxlib` の `skipcomment` がこれをしていて、その層は Nilu にありません
（[12.8](12-embedding.md#128-無いもの)）。だから**ファイルを読むプログラムの仕事**です
——`nilu` コマンドがやっていて、ホストを自分で書く人は自分で決めます。

## 11.2. プロンプト

下の例は、**プロンプトに 3 行打ち込んだときに `nilu` が書くもの**です。
打った文字そのものは出てきません。端末が見せているのは端末の echo で、
`nilu` は何も echo しません。

```sh nilu-cli
nilu
```
```stdin
1 + 2
local x = 1
print("こんにちは")
```
```output
nilu 0.1.0-dev.1
> 3
> > こんにちは
> 
```
```stderr
warning: locals do not survive across lines in interactive mode
```

端末で実際に見えるのはこうです（`1 + 2` などは自分が打った文字）。

```text
$ nilu
nilu 0.1.0-dev.1
> 1 + 2
3.0
> local x = 1
> print("こんにちは")
こんにちは
>
```

入力した行は、まず `return <行>` として読まれます。それが構文として通れば
式として評価され、結果が表示されます。通らなければ行そのものが文として走ります。
これは Lua の `lua` コマンドがしていることと同じです。

**文が終わるまで読みます**。
途中で終わっている行には `>> ` を出して次の行を待ち、つながったところで走らせます。

```sh nilu-cli
nilu
```
```stdin
if 1 == 1 then
print("はい")
end
```
```output
nilu 0.1.0-dev.1
> >> >> はい
> 
```

- **ローカル変数は次の文に残りません。** つながった 3 行は 1 つの文であって、
  1 つの文が終わればそこまでです。`local x = 1` の次の行で `x` を読むと
  グローバル変数の `x`（`nil`）です。グローバル変数なら残ります。
- **`local ` で始まる行には警告が出ます**（Lua と同じ文面です）。上の例の
  `local x = 1` に付いているのがそれです。
- 行の履歴や行編集はできません（`readline` を使わないため）。

```sh nilu-cli
nilu
```
```stdin
local x = 1
print(x)
y = 2
print(y)
```
```output
nilu 0.1.0-dev.1
> > nil
> > 2
> 
```
```stderr
warning: locals do not survive across lines in interactive mode
```

**途中かどうかの判断は、構文エラーの文章の末尾を見るだけです。** `near <eof>` で終わって
いれば「入力が足りない」、それ以外なら「間違っている」です。Lua の `incomplete` がしている
ことと同じで、5 バイトの比較です。

短い文字列は行をまたげませんが、**1 行目の文章が `near <eof>` で終わるので 1 度は
続きを訊きます**。つないだあとで「文字列が閉じていない」と断ります。Lua も同じです。

プロンプトでの失敗には `nilu:` が付きません。ファイル名もありません。

```sh nilu-cli
nilu
```
```stdin
return nil + 1
```
```output
nilu 0.1.0-dev.1
> > 
```
```stderr
stdin:1: attempt to perform arithmetic on a nil value
```

`Ctrl-D`（入力の終わり）で抜けます。

プロンプトが値を表示するときに呼ぶのは**グローバルの `print`** です（Lua の `lua -i` と同じ）。
だからプロンプトで `print` を置き換えると、次の行の値はその `print` で表示されます。

```sh nilu-cli
nilu -
```
```stdin
print = function(...) io.write("P:", select("#", ...), "\n") end
```
```output
```

（この例は `-` で走らせているので表示は出ません。プロンプトでの振る舞いは `zig build cli-test` の
`the prompt calls the global print` が見ています。）

### 行を編集する

**端末では、プロンプトは打っている行を編集できます**。左右の矢印は文字単位で動きます（2 バイトや
2 桁の文字も 1 文字です）。Home と End（`Ctrl-A` と `Ctrl-E` も）は端へ、Backspace と Delete は 1 文字消し、
上下の矢印はこのセッションで打った行をたどります。`Ctrl-C` はその行を捨て、空の行での `Ctrl-D` はプロンプトを
終えます。履歴は `nilu` を終えると残りません。入力か出力が端末でないとき（パイプやファイル）は、行をそのまま
読みます。Windows のコンソールは自分で行を編集します。Zig の標準ライブラリ以外に依存しないので、`readline`
は使いません。

## 11.3. 失敗したときの書き方

```sh nilu-cli
nilu -e 'return nil + 1'
```
```stderr
nilu: (command line):1: attempt to perform arithmetic on a nil value
```

```sh nilu-cli
nilu nope.nilu
```
```stderr
nilu: cannot open nope.nilu: No such file or directory
```

```sh nilu-cli
nilu -
```
```stdin
local = 1
```
```stderr
nilu: stdin:1:7: <name> expected near '='
```

形は `nilu: <どこ>:<行>: <何>` です。構文エラーは `行:桁`、実行時の失敗は `行` を持ちます
（[8.2](08-failure.md#82-失敗の種類)）。位置を付けるのは文字列の頭だからで、`error()` の `nil` にはコマンドが
付けますが、`nilu -e 'error(1)'` のように文字列でも `nil` でもない値を投げたときは
`nilu: (command line): runtime error` と行なしで出て、2 行目に `nilu: (error object is a number value)` が続きます
（[13.1](13-differences-from-lua.md#131-違うところ)）。

### 呼び出し履歴

**フレームが 2 段以上あるときは、呼び出し履歴も印字します**。
**内側から順**に、1 行につき 1 フレームです。位置のうしろに、Lua と同じ書き方でその関数が何かを書きます。
呼ばれたときの名前（`upvalue 'c'`、`local 'b'`、`field 'run'`、`method 'go'`）、`main chunk`、
または名前の無い呼び出しなら定義した行で `function <場所:行>` です。

```lua nilu
local function c() local v = 1 + nil return v end
local function b() local v = c() return v end
local v = b()
```
```stderr
nilu: <manual>:1: attempt to perform arithmetic on a nil value
stack traceback:
	<manual>:1: in upvalue 'c'
	<manual>:2: in local 'b'
	<manual>:3: in main chunk
```

⚠ **`local v = c()` と書いているのは、`return c()` だと段が潰れるからです。**
末尾呼び出しはフレームを使い回すので（[6.5](06-functions.md#65-末尾呼び出し)）、
**履歴に出てくるフレームは実際に少なくなります** —— Lua はそこに
`(...tail calls...)` と書きますが、ここには潰れたことを言う手段がありません。

**`error()` やライブラリの断りのように、ネイティブ関数が失敗を上げたときは、そのフレームが
最初に出ます**。名前の付け方は同じです（`[C]: in global 'error'`）。名前の無いネイティブは `[C]: in ?` です。
Lua は最後にもう 1 行、コマンド自身がチャンクを呼んだ分の `[C]: in ?` を書きますが、ここではその呼び出しは
フレームではないので、最後の行は `in main chunk` です。

```lua nilu
local function c() error("boom") end
local function b() c() end
b()
```
```stderr
nilu: <manual>:1: boom
stack traceback:
	[C]: in global 'error'
	<manual>:1: in upvalue 'c'
	<manual>:2: in local 'b'
	<manual>:3: in main chunk
```

「フレームが 2 段以上」は **Nilu の関数のフレーム**で数えます。だから一番外で `error("x")` を
呼んだときは 1 行だけです。

⚠ **1 段のときは印字しません。** 1 段の履歴は**上の行と同じ位置を
もう一度書く**ことになります。**構文エラーにも付きません** —— 読み込みの時点で失敗していて、
呼び出しが 1 つも無いからです（Lua も付けません）。

**長い履歴は途中を省きます。** 上から 10 段、下から 11 段を書いて、間は
`...	(skipping N levels)` と数だけ言います —— `luaL_traceback` と同じ数です。

**`pcall` や `xpcall` で受けた失敗には付きません。** 印字しているのはコマンドで、
受け取ったのはプログラムだからです。

**`<何>` を書いているのが誰かは、失敗が値を運んだかで変わります。**
中核の失敗と `error` で投げた文字列は**自分で文章と位置を持っている**ので、コマンドは
それをそのまま出します（`attempt to perform arithmetic on a nil value` は中核の言葉です）。
**文字列を運ばない失敗**（`error()` が `nil` や文字列でない値を投げたとき）では、コマンドが自分の言葉を書きます。
だから下の表は別のホストでは別の言い方になります。

| 種類 | 値を運ばないときのコマンドの言い方 |
|---|---|
| 構文エラー | `syntax error` |
| 型エラー | `type error` |
| 実行時エラー | `runtime error` |
| 呼び出しが深すぎる | `too many nested calls` |
| メモリ不足 | `out of memory` |
| スタックが満杯 | `the stack is full` |
| 中断 | `interrupted` |

**ファイルと `-e` で実際に出るのは `runtime error` と `out of memory` です。** `runtime error` は
`error()` が `nil` を投げたときと、文字列でない値を投げたときです。ライブラリの拒否は文章を持ちます。
ストリームで失敗した `io.write`・`io.read`・`f:read`・`f:write`・`f:flush` は失敗にならず、Lua の
`luaL_fileresult` と同じ 3 つの値、`nil`・文章・errno を返します（書くものは 4 つめに、失敗するまでに
書けたバイト数）。`local f = io.open("/dev/null"); io.output(f); print(io.write("x"))` は
`nil	Bad file descriptor	9	0` です。
**メモリ不足は 2 つに分かれます**：呼び出しの中で尽きたときは `not enough memory` という文章を
運ぶので、出るのはその文章です。**読み込み（`nilu_loadstring`）の中で尽きたときは何も運ばない**ので
（文章を組むメモリも無いため）、コマンドが `nilu: <どこ>: out of memory` と書きます。
**構文エラーも自分の文章を運ぶ**ので、`syntax error` という言葉は出ません
（文章を組めなかったときだけ残ります）。
**「呼び出しが深すぎる」は中核が文章を運ぶので、この言葉のほうは出ません**。
**`type error` はプロンプトでだけ出ます**：行の値を書くのにグローバルの `print` を呼ぶので
（[11.2](#112-プロンプト)）、`print = nil` のあとに `1 + 2` と打つと
`error calling 'print' (type error)` と出ます。
後ろの 2 つは起こせません。フックを置いていないので「中断」は起こらず、
「スタックが満杯」はプログラムから届きません。

失敗したら終了ステータスは 1 です。何も失敗しなければ 0 です。

## 11.4. `io` と `os`

**`nilu` コマンドが登録している関数**です。ライブラリにはありません
（[1.3](01-getting-started.md#13--print-はホストが決めた先へ書きます)）。
中核は標準出力・標準入力・時計・プロセスに触らないので、触る関数はホストが持ちます。

| 関数 | すること |
|---|---|
| `io.write(…)` | 引数をそのまま**現在の出力**へ。**間にタブも、後ろに改行も入れません** |
| `io.read([fmt, …])` | **現在の入力**から読む。既定は 1 行 |
| `io.open(name [, mode])` | ファイルを開く（11.4.1） |
| `io.lines([name])` | 行を回す。省くと現在の入力（11.4.1、11.4.2） |
| `io.close([f])` | 閉じる。省くと現在の出力（11.4.1、11.4.2） |
| `io.input([f])`、`io.output([f])` | 現在の入力・出力を見る、入れ替える（11.4.2） |
| `io.flush()` | 現在の出力を書き出す |
| `io.type(v)` | ファイルかどうか、開いているかを答える（11.4.3） |
| `io.tmpfile()` | 名前の無い一時ファイルを作る（11.4.3） |
| `os.clock()` | プロセスが使った CPU 時間（秒） |
| `os.time([t])` | 現在時刻（1970 年からの秒）。テーブルを渡すとその日時の時刻（11.4.4） |
| `os.date([fmt [, t]])` | 時刻を文字列かテーブルにする（11.4.4） |
| `os.getenv(name)` | 環境変数。無ければ `nil`（11.4.4） |
| `os.exit([code [, close]])` | 終了する。`true` は 0、`false` は 1、数ならその値 |
| `os.remove(name)`、`os.rename(old, new)` | ファイルを消す / 名前を変える（11.4.5） |
| `os.tmpname()` | 一時ファイルの名前。空のファイルを作ります（11.4.5） |
| `os.difftime(t2, t1)` | `t2 - t1` の秒数 |
| `os.setlocale([locale [, category]])` | いつも C ロケール。`"C"` を返し、何も変えません（11.4.5） |
| `os.execute([command])` | シェルでコマンドを走らせ、終了状態を返す（11.4.5） |
| `io.popen(prog [, mode])` | プログラムを走らせ、その出力を読む／入力に書くファイルにする（11.4.5） |

```lua nilu
io.write("a", 1, "b", "\n")
```
```output
a1b
```

数は `print` と同じ綴りです（`1.5` は `1.5`、`2.0` は `2`）。**文字列と数以外は断ります。**

```lua nilu
print(select(2, pcall(io.write, true)))
```
```output
bad argument #1 to 'write' (string expected, got boolean)
```

文章は Lua のものです。
**`io.write` は書いた先のファイルを返します**。Lua と同じく、つなげて書けます。

```lua nilu
io.write("a"):write("b\n")
```
```output
ab
```

`io.read` の書式は Lua と同じです。

| 書式 | 読むもの | 読めなかったとき |
|---|---|---|
| `"l"`（既定） | 1 行、改行を除く | `nil` |
| `"L"` | 1 行、改行を含む | `nil` |
| `"a"` | 残り全部 | 失敗しません。終わりでは `""` |
| `"n"` | 数値ひとつ。前の空白は飛ばします | `nil` |
| 数 `n` | `n` バイト | `nil`。`0` は「まだあるか」の問いで、あれば `""` |

**知らない書式は断ります。** 書式でない値も断ります。

```lua nilu
print(select(2, pcall(io.read, "q")))
print(select(2, pcall(io.read, {})))
```
```output
bad argument #1 to 'read' (invalid format)
bad argument #1 to 'read' (string expected, got table)
```

`#1` は**その引数の位置**です。`f.read(f, "q")` なら `#2` になります。

```lua nilu
local first = io.read()
local rest = io.read("a")
print(first, rest)
```
```stdin
ab
cd
```
```output
ab	cd

```

複数の書式を一度に渡すと、その数だけ値が返ります。**最初に読めなかった書式が `nil` になり、
その後ろは試されません。**

```lua nilu
print(io.read("l", "l", "l"))
```
```stdin
ab
cd
```
```output
ab	cd	nil
```

```lua nilu
print(io.read("n"), io.read("l"))
```
```stdin
 12.5e1 rest
```
```output
125.0	 rest
```

`"n"` は数値の直後で止まり、残りの `" rest"` は次の読みに渡ります。

`nilu -` で標準入力をプログラムにしたときは、**プログラムが先に標準入力を読み切っている**ので
`io.read()` は `nil` です。Lua も同じです。

`os.clock` と `os.time` は呼ぶたびに違う数を返すので、ここで値は示せません。
型と、時計が戻らないことだけ確かめられます。

```lua nilu
local a = os.clock()
local b = os.clock()
print(type(a), b >= a, type(os.time()))
```
```output
number	true	number
```

`os.exit` は**その場で終わります**。それまでに `io.write` したものは書き出されます。
2 つめの引数が `true` なら、終わる前に状態を閉じます。

```sh nilu-cli
nilu -e 'io.write("before\n") os.exit(3)'
```
```output
before
```

このコマンドの終了ステータスは 3 です（`manual-check` は標準出力だけを見ています。
終了ステータスは `zig build cli-test` の `os.exit sets the status and flushes what was written` が見ます）。

**まだ無いものは [13.2](13-differences-from-lua.md#132-まだ無いもの) にまとめてあります**。
13.2 の表は `zig build manual-check` が 1 行ずつ走らせて確かめる側なので、
**一覧はそこだけにあります**。

### 11.4.1. ファイル

**`io.open` がファイルを開きます**。返ってくるのは
**`userdata`** で、中は見えません。できるのは `read`、`write`、`lines`、`close`、`flush`、`seek`、`setvbuf` の 7 つです。

**メソッドは Lua と同じく `f:read(…)` と書きます**。`__index` が解決します（[14.2](14-porting.md#142-2-本目メソッドを持つクラス)）。

```lua nilu-source
local f = io.open("notes.txt", "w")
f:write("ひとつめ\n")
f:write("ふたつめ\n")
f:close()

for line in io.lines("notes.txt") do
  print(line)
end
```

**開けなかったときは 3 つ返します** —— `nil`、理由、`errno`。失敗にはなりません。

```lua nilu
local f, why, code = io.open("/no/such/file", "r")
print(f, why ~= nil, code ~= nil)
```
```output
nil	true	true
```

3 つめは `errno` です（この環境では `2`）。値そのものは OS が決めるので、ここでは
**3 つ返ること**だけを確かめています。

**引数が間違っているときは断ります**（開けなかったのとは別です）。

```lua nilu
print(select(2, pcall(io.open, {})))
print(select(2, pcall(io.open, "/dev/null", {})))
local z = "/dev/null" .. string.char(0) .. "x"
print(select(2, pcall(io.open, z)))
```
```output
bad argument #1 to 'open' (string expected, got table)
bad argument #2 to 'open' (string expected, got table)
bad argument #1 to 'open' (a path cannot hold a zero byte)
```

**文字列でないモードは黙って無視せず断ります** —— 黙って無視されるのは、言葉の無い断りより
悪いことです。
モードを**省くか `nil` を渡すか**は `"r"` です（Lua も同じ）。

⚠ **3 行めの文章は我々のものです。** Lua はこれを断らず、**ゼロバイトまでのパスを開きます**。
環境変数の名前（`os.getenv`）は切り捨て、パスは断る —— プログラムが渡していない名前で
ファイルを開くほうが高くつくからです。

**`io.lines` だけは失敗を投げます。** 開けないファイルで `for` を始めても行き先が無いからです。
これは Lua の区別をそのまま借りています。

```lua nilu
local ok, why = pcall(function() for _ in io.lines("/no/such/file") do end end)
print(ok, string.sub(why, 1, 28))
```
```output
false	<manual>:1: cannot open file
```

**閉じたファイルを使うと断ります**（`nil` ではなく失敗です）。

```lua nilu
local ok, why = pcall(function()
  local f = io.open("/dev/null", "r")
  f:close()
  return f:read("l")
end)
print(ok, why)
```
```output
false	<manual>:4: attempt to use a closed file
```

⚠ **断りの前に付いているのは、断られた行の位置です。** ライブラリの断りと同じ形です
（[8.1](08-failure.md#81-失敗したらどうなるか)）。

**書式は `io.read` と同じ**です（`l`、`L`、`a`、`n`、数）。`f:write` は**ファイルを返す**ので
`f:write("a"):write("b")` と書けます。書けなかったときは `nil` と理由を返します
（失敗ではありません）。

**位置を動かすのは `f.seek` です。**

| 書き方 | すること |
|---|---|
| `f:seek()` | いまの位置。`f:seek("cur", 0)` と同じです |
| `f:seek("set" [, n])` | 先頭から `n` バイトの位置へ（既定は `0`） |
| `f:seek("cur" [, n])` | いまの位置から `n` バイト動く |
| `f:seek("end" [, n])` | 終わりから `n` バイト。`f:seek("end")` はファイルの大きさ |

返るのは動いたあとの位置です。

```lua nilu
local f = io.open("seek.txt", "w")
f:write("0123456789\n")
f:close()
local g = io.open("seek.txt", "r")
print(g:seek())
print(g:read(4))
print(g:seek())
print(g:seek("end"))
print(g:seek("cur", -2))
g:close()
```
```output
0
0123
4
11
9
```

⚠ **位置は整数です。** 値が整数でない浮動小数点数は、Lua と同じく断ります
（[2.3](02-values.md#23-数)）。

```lua nilu
local f = io.stdout
print(select(2, pcall(f.seek, f, "set", 1e30)))
```
```output
bad argument #3 to 'seek' (number has no integer representation)
```

⚠ **`whence` は文字列でなければなりません。** `f:seek(1)` は断りです。
Lua は数を文字列に直して `invalid option '1'` と言いますが、Nilu は数を文字列にしないので
（[2.4](02-values.md#24-文字列)）、型を言います。

```lua nilu
local f = io.stdout
print(select(2, pcall(f.seek, f, 1)))
```
```output
bad argument #2 to 'seek' (string expected, got number)
```

**`f:flush()` と `f:setvbuf(mode [, size])` はどちらも `true` を返します。**
`mode` は `"no"`、`"full"`、`"line"` で、ここも文字列です。

```lua nilu
local f = io.open("buf.txt", "w")
print(f:flush(), f:setvbuf("full", 512), f:setvbuf("line"))
f:close()
```
```output
true	true	true
```

⚠ **`flush` が `true` を返すのは Lua 5.5 からです。** 5.4 はファイルを返していました
（`f:flush():write(x)` とつなげるため）。ここは 5.5 を測って合わせています。

**`io.lines` は最後まで回ったとき、または途中でループを出たときに閉じます**。ファイルを 4 つ目の値として
返し、ループがそれを閉じるからです。**`f:lines()` は閉じません。** これも Lua と同じです。ファイルは
`<close>` のローカル変数でも閉じられます。

**`lines` は書式を取ります**。
`io.read` と同じ書式を渡すと、**毎回それで読みます**。数の書式は**行ではなくバイト数**なので、
`3` は `1 2` / `\n3 ` / `4\n` に切れます。

```lua nilu
local f = io.open("nums.txt", "w")
f:write("1 2\n3 4\n")
f:close()

local g = io.open("nums.txt")
for a, b in g:lines("n", "n") do print(a, b) end
g:close()

for s in io.lines("nums.txt", 3) do io.write("[", s, "]") end
print()
```
```output
1	2
3	4
[1 2][
3 ][4
]
```

⚠ **`io.lines` の 1 つめの引数はファイル名です。** `io.lines("n")` は `n` という名前の
ファイルを開こうとします —— 現在の入力に書式を渡すなら `io.lines(nil, "n")` です。
読みにくい形ですが Lua と同じで、直していません。

**書式は 250 個までです。**それより多いと断ります。断りの引数番号は**いつでも 252** で、
渡した数によりません —— これも Lua のままです。

**反復子を作ったあとにファイルを閉じると、回したときに断ります。**

```lua nilu
local f = io.open("one.txt", "w")
f:write("a\n")
f:close()
local g = io.open("one.txt")
local it = g:lines()
g:close()
print(select(2, pcall(it)))
```
```output
file is already closed
```

**`attempt to use a closed file` とは別の文章です。** 前者は「渡されたファイルが閉じている」、
こちらは「持っていたファイルが途中で閉じられた」—— Lua も `io_readline` に別の文章を
持っていて、そこから借りました。

**閉じるのはプログラムですが、忘れても漏れません。** `nilu` コマンドは自分が開いた
ファイルを覚えていて、**終了するときに閉じます**（`os.exit` の経路でも）。
回収のときに走る仕組み（`__gc`）は無いので、**約束しているのはコマンドの帳簿**です。

**`tostring(f)` は `file (0x…)`、閉じたあとは `file (closed)`** です。型の名前は `FILE*` なので、
ファイルでない値を渡したときの断りは `FILE* expected, got table` のようになります。

**これはコマンドのものです。** 中核はファイルに触らず、ライブラリはホストが書けるものだけ
なので、ファイルは `print` や `io.write` と同じ位置にあります。
自分でホストを書く人は、**`userdata` を使って同じものを書けます**
（[12.6](12-embedding.md#126-ホストのデータをプログラムに持たせる)）。

### 11.4.2. 標準の 3 つと、現在の入出力

**`io.stdin`、`io.stdout`、`io.stderr` はファイルです**。
`io.open` が返すものと同じメタテーブルを持つので、同じ 7 つの関数が使えます。

**閉じようとすると `nil` と理由を返します**（失敗ではありません）。

```lua nilu
print(type(io.stdout), io.output() == io.stdout, io.input() == io.stdin)
print(io.stdout:close())
io.stdout:write("そのまま書けます\n")
```
```output
userdata	true	true
nil	cannot close standard file
そのまま書けます
```

**`io.input` と `io.output` が「現在の入力・出力」を持っています。**

| 書き方 | すること |
|---|---|
| `io.output()` | いまの出力を返す。最初は `io.stdout` |
| `io.output(f)` | `f` を出力にして、`f` を返す |
| `io.output(name)` | `name` を `"w"` で開いて出力にする。開けなければ失敗 |
| `io.input(…)` | 同じことを入力に。最初は `io.stdin` |
| `io.flush()` | いまの出力を書き出す |

**`io.write` と `io.read` はこの対を見ます。** 標準出力・標準入力に固定ではありません。

```lua nilu
local f = io.open("out.txt", "w")
io.output(f)
io.write("ファイルへ\n")
io.output(io.stdout)
f:close()
for line in io.lines("out.txt") do print(line) end

local g = io.open("in.txt", "w")
g:write("ひとつめ\nふたつめ\n")
g:close()
io.input("in.txt")
print(io.read("l"), io.read("l"))
io.input(io.stdin)
```
```output
ファイルへ
ひとつめ	ふたつめ
```

⚠ **現在の入力・出力を閉じてしまうと、`io.write` と `io.read` は断ります。**
標準出力へこぼすことはしません —— プログラムが頼んでいない場所に書くことになるからです。
文章は Lua のものです。

```lua nilu
local f = io.open("gone.txt", "w")
io.output(f)
f:close()
print(select(2, pcall(io.write, "x")))
io.output(io.stdout)
```
```output
default output file is closed
```

**`io.close()` と `io.lines()` は、引数を省くとこの対を使います。**
`io.close()` は現在の出力を閉じ、`io.lines()` は現在の入力を回します。
**`io.lines()` は回し終えても閉じません**——名前を渡した `io.lines(name)` は閉じます。
どちらも Lua と同じです。

```lua nilu
print(io.close())
```
```output
nil	cannot close standard file
```

できたての状態では現在の出力は `io.stdout` なので、閉じられずに `nil` と理由が返ります。

**`print` はこの対を見ません。** `print` は `nilu` コマンドが渡した writer に行を渡し、それは
いつでも標準出力へ書きます（[1.3](01-getting-started.md#13--print-はホストが決めた先へ書きます)）。
Lua も同じで、`print` は `io.output` を通りません。

**対は `io` の関数が持っているテーブルの中にあり、グローバルではありません。**
プログラムから見えるのは `io.input` と `io.output` だけで、書き換える道はほかにありません。

### 11.4.3. ファイルかどうかを聞く、一時ファイルを作る

**`io.type` は値の状態を答えます**。

| 渡したもの | 答え |
|---|---|
| 開いているファイル | `"file"` |
| 閉じたファイル | `"closed file"` |
| ファイルでない値 | `nil` |
| 何も渡さない | 断ります |

```lua nilu
local f = io.open("t.txt", "w")
print(io.type(io.stdout), io.type(f))
f:close()
print(io.type(f))
print(io.type(nil), io.type(""), io.type(print))
print(select(2, pcall(io.type)))
```
```output
file	file
closed file
nil	nil	nil
bad argument #1 to 'type' (value expected)
```

⚠ **`io.type(nil)` は `nil` で、断りではありません。** 断るのは**何も渡さなかったとき**だけです
—— `nil` を渡すことと渡さないことを区別しています。これは Lua の `luaL_checkany` と同じです。

**`io.tmpfile` は名前の無いファイルを作ります。**

```lua nilu
local f = io.tmpfile()
print(io.type(f), getmetatable(f) == getmetatable(io.stdout))
f:write("ひとつめ\n")
f:seek("set")
print(f:read("l"))
print(f:close())
```
```output
file	true
ひとつめ
true
```

`io.open` が返すものと同じメタテーブルを持つので、**7 つの関数すべてが使えます**。
**どこに作られたかは分かりません** —— `tmpfile(3)` は名前を返さず、閉じたときに消えます。
閉じるのを忘れても、コマンドが終了するときに閉じます（[11.4.1](#1141-ファイル)）。

### 11.4.4. 時刻と環境変数

**`os.getenv` は環境変数を返します**。
**無いときは `nil`** で、エラーにはなりません。`nil` と `""` は**別の答え**です ——
前者は「設定されていない」、後者は「空に設定されている」。

```lua nilu-source
print(os.getenv("HOME"))
print(os.getenv("NILU_NO_SUCH_VAR"))
```

（この例は環境によって変わるので、実行して確かめる例にはしていません。
`zig build cli-test` の `os.getenv tells unset from empty` が、自分で変数を設定して見ています。）

**`os.date` は時刻を文字列にします。** 書式は C の `strftime` のものです。

| 書き方 | すること |
|---|---|
| `os.date()` | いまを `"%c"` で |
| `os.date(fmt)` | いまを `fmt` で |
| `os.date(fmt, t)` | `t`（1970 年からの秒）を `fmt` で |
| `!` を頭に付ける | ローカル時刻ではなく **UTC** |
| `"*t"`、`"!*t"` | 文字列ではなく**テーブル** |

```lua nilu
print(os.date("!%Y-%m-%d %H:%M:%S", 0))
print(os.date("!%F %T", 86400 * 366))
```
```output
1970-01-01 00:00:00
1971-01-02 00:00:00
```

**例はすべて `!` を付けています。** 付けなければ答えは**走らせた機械のタイムゾーン**で
変わるので、確かめられる例になりません。

**テーブルは 9 つのフィールドです。**

```lua nilu
local d = os.date("!*t", 0)
print(d.year, d.month, d.day)
print(d.hour, d.min, d.sec)
print(d.wday, d.yday, d.isdst)
```
```output
1970	1	1
0	0	0
5	1	false
```

`month` は 1 から 12、`wday` は日曜が 1、`yday` は 1 から始まります。
**C は 0 から数えるところを、この言語は 1 から数えます** —— Lua と同じです。

**知らない変換指定子は断ります。** 渡せるのは Lua の C99 の一覧にあるものだけです。

```lua nilu
print(select(2, pcall(os.date, "%v")))
```
```output
bad argument #1 to 'date' (invalid conversion specifier '%v')
```

⚠ **書式全体を先に調べます。** `os.date("ok%v")` は `ok` も書きません。
これは `strftime` に知らない指定子を渡すと C では**何が起きるか決まっていない**ためで、
払うのはプロセスごとです。

**`os.time` にテーブルを渡すと、その日時の時刻を返します。**

| フィールド | 要るか |
|---|---|
| `year`、`month`、`day` | **要ります** |
| `hour` | 省くと **12** |
| `min`、`sec` | 省くと `0` |
| `isdst` | 省くと「分からない」 |

⚠ **渡したテーブルは書き換えられます。** `mktime` が正規化した値が戻り、
`wday`、`yday`、`isdst` が**渡していなくても増えます**。

```lua nilu
local t = {}
t.year = 2026
t.month = 13
t.day = 1
local answered = os.time(t)
print(t.year, t.month, t.day)
print(t.wday, t.yday, t.isdst)
print(answered ~= nil)
```
```output
2027	1	1
6	1	false
true
```

13 月が翌年の 1 月になっています。**純粋な関数ではありません**が、これが
`os.date("*t")` との往復を成立させています。

```lua nilu
print(os.time(os.date("*t", 86400)) == 86400)
print(os.time(os.date("*t", 0)) == 0)
```
```output
true
true
```

⚠ **`!` を付けた往復は、機械のタイムゾーン次第です。** `!*t` は UTC のフィールドを返し、
`os.time` は**ローカル時刻として読む**ので、ずれた分だけ違う答えになります
—— UTC の機械でだけ閉じます。Lua も同じで、**だからここでは例にしていません**。

**フィールドが足りない、整数でない、範囲外のときは、どれだったかを言います。**

```lua nilu
local a = {}
print(select(2, pcall(os.time, a)))
a.year = 2026
a.month = 10
a.day = 1.5
print(select(2, pcall(os.time, a)))
a.day = 1
a.hour = 1e10
print(select(2, pcall(os.time, a)))
```
```output
field 'year' missing in date table
field 'day' is not an integer
field 'hour' is out-of-bound
```

**`os.time` が返すのは整数です。** Lua と同じです。

### 11.4.5. 名前でのファイル操作と、ほかのプログラム

**`os.remove` と `os.rename` は `true` か、`nil` と理由と errno を返します**（`io.open` と同じです）。
`os.tmpname` は、Lua が POSIX でするのと同じく、その名前で空のファイルを作ります。
**`os.execute` と `io.popen` のファイルは、Lua と同じ形で終了状態を返します**。`true`（か `nil`）、
続けて `"exit"` とコード、または `"signal"` とシグナルです。コマンドより前に書いたものは先に書き出すので、
出力の順はプログラムの順になります。

```lua nilu
local name = os.tmpname()
local f = io.open(name, "w") f:write("x") f:close()
print(os.rename(name, name .. ".b"))
print(os.remove(name .. ".b"))
print(os.difftime(10, 4))
print(os.execute("exit 3"))
local p = io.popen("echo hi")
print(p:read("l"))
print(p:close())
```
```output
true
true
6.0
nil	exit	3
hi
true	exit	0
```

これらはシェル（POSIX では `/bin/sh`）でプロセスを起こすので、走らせたスクリプトはそのコマンドがすることをします。

**`os.setlocale` は C ロケールから動きません。** 問い合わせと `"C"`・`"POSIX"`・`""` には `"C"` を返し、
ほかのロケールには `nil` を返します（Lua も設定できないロケールには `nil` を返します）。Lua の `""` は環境のロケールに
切り替えますが、コマンドは切り替えません。だから `os.date` や文字列の比較の答えは、プログラムを走らせる場所によりません。

```lua nilu
print(os.setlocale(), os.setlocale(""), os.setlocale("ja_JP.UTF-8"), os.setlocale("C", "time"))
```
```output
C	C	nil	C
```

## 11.5. まだできないこと

| できないこと | 理由 |
|---|---|
| 走っているコードを `Ctrl-C` で止める | フックを置いていないので、プロセスごと終わります（プロンプトの行編集では、`Ctrl-C` はその行を捨てます） |

`-E` はありません。`LUA_INIT` のような環境変数をコマンドが読まないので、何もしないフラグになるからです
（オーナーの答え）。

`nilu` が読み込めるのは**テキストだけ**です。ソースに `\0` が入っていると断ります
（途中までを読んで成功と答えるほうが悪いので）。

## 11.6. `require` が探す場所

コマンドは、ファイルを読む読み手をライブラリに渡しています（[10.7](10-library.md#107-コードを読み込む)）。

**モジュール名はパスになります**。ドットが `/` になり、`.nilu` が付きます（`lib.vector` は `lib/vector.nilu`）。
**読み込み中のファイルの隣**を（あれば）先に探し、次に**コマンドが起動したスクリプトの隣**を探します
（`-e` やプロンプトではカレントディレクトリ）。

```text
main.nilu          require("geometry")    -> geometry.nilu
sub/shapes.nilu    require("util")        -> sub/util.nilu, then util.nilu
anything           require("lib.vector")  -> lib/vector.nilu next to the asker, then next to main.nilu
```

見つかったパスがモジュールの鍵です。失敗の文でモジュールを名指しし（`lib/vector.nilu:3: …`）、
`package.loaded` が保つ場所にもなるので、別々のディレクトリにある二つの `util.nilu` は別のモジュールです。
見つからないときの理由は、試したパスをすべて並べます（`no file 'sub/util.nilu'; no file 'util.nilu'`）。

**`dofile` と `loadfile` は、書かれたパスをそのまま**カレントディレクトリから開きます（Lua と同じ）。

コマンドが起動したスクリプトはモジュールではありません。それを名前で `require` するモジュールは、
Lua と同じくもう一度読み込みます。モジュールの読み込みが終わったあとに（その中の関数が後から呼ばれて）
行われた `require` は、起動したスクリプトの隣を探します。

---

次: [12. C から埋め込む](12-embedding.md)
