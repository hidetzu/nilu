[← 目次](README.md)

# 1. はじめに

Nilu は組み込み向けの小さなスクリプト言語です。できることは次のとおりです。

- 値は `nil`、真偽値、数、文字列、テーブル、関数の 6 種類と、ホストが渡す `userdata`
- 文は `local`、`global`、代入、`if`（`elseif`）、`while`、`repeat`、数値 `for`、汎用 `for`、`do … end`、`break`、`goto`、`return`、`function f() … end`
- コメントは `--` から行末まで、または `--[[ … ]]`（[15.2](15-grammar.md#152-字句)）
- 関数は値で、まわりの変数を見られます（クロージャ）
- テーブルにはメタテーブルを付けられ、添字と演算子に答えられます
- 標準ライブラリは `string`、`table`、`math`、`utf8` のテーブルと、いくつかの基本関数（`nilu` コマンドには `io` と `os` もあります）
- ホストプログラムからは C の API で呼び出せます

Lua 5.5 を一次資料として作られているので、Lua を知っていれば大半はそのまま読めます。
違うところは [13. Lua との違い](13-differences-from-lua.md) にまとめてあります。

## 1.1. 手に入れる

必要なのは [Zig](https://ziglang.org) だけです。バージョンは
[`.mise.toml`](../../.mise.toml) に書かれているものを使ってください。

```bash
zig build
```

これで 3 つのものができます。

| できるもの | 何か |
|---|---|
| `zig-out/bin/nilu` | コマンド |
| `zig-out/include/nilu.h` | C のホストが読むヘッダ |
| `zig-out/lib/libnilu.a` | C のホストがリンクするライブラリ |

C から組み込むのに必要なのは、後ろの 2 つだけです
（[12. C から埋め込む](12-embedding.md)）。

以下の例ではコマンド名を `nilu` と書きます。この checkout から実行する場合は
`./zig-out/bin/nilu`（Windows では `zig-out/bin/nilu.exe`）に置き換えるか、
`zig-out/bin` を PATH に追加してください。ファイルの実行例を試す前に、
次の最初のスクリプトを `hello.nilu` として保存します。
`zig build check` などリポジトリの検証には Node.js も必要です。

プログラムは `require` で複数のファイルに分けられます。`nilu` コマンドは、求めたファイルの隣から
モジュールを探します（[11.6](11-nilu-command.md#116-require-が探す場所)）。既存のプロジェクトを
移す前に [Lua との違い](13-differences-from-lua.md)を確認してください。

## 1.2. 最初の一行

```lua nilu
print("こんにちは")
```
```output
こんにちは
```

ファイルに書いて渡すか、`-e` でそのまま渡すか、標準入力から流し込めます。

```bash
nilu hello.nilu
nilu -e 'print("こんにちは")'
echo 'print("こんにちは")' | nilu -
```

引数を何も付けずに `nilu` と打つとプロンプトが出ます。

```text
$ nilu
nilu 0.1.0-dev.1
> 1 + 2
3.0
> print("こんにちは")
こんにちは
>
```

プロンプトでは、式だけを書いた行がそのまま答えになります。これは入力をまず
`return <行>` として読もうとするからで、Lua の `lua` コマンドと同じ仕掛けです。
詳しくは [11. `nilu` コマンド](11-nilu-command.md) にあります。

## 1.3. ⚠ `print` はホストが決めた先へ書きます

**`print` はライブラリにありますが、行をどこへ出すかはホストが決めます。**

Nilu の中核は標準出力に触りません。`print` は行を組み立て（値ごとに `tostring`、間にタブ、
最後に改行）、ホストが渡した **writer** に渡します。`nilu` コマンドは、標準出力へ書く writer を渡しています。

つまり、**あなたが書いた別のホストでは、writer を渡すまで何も出ません**。そこで `print(…)` を
呼ぶと `cannot print: no writer was given to this state` で失敗します。渡すのは
2 行で済みます（[`cli/nilu.c`](../../cli/nilu.c) にそのままあります）。

```c
nilu_pushcfunction(N, writer);
nilu_setwriter(N);
```

`io` と `os` はホスト自身のものです（[11.4](11-nilu-command.md#114-io-と-os)）。
中核に入っているのは計算する関数だけで、外に触るものはホストが持ちます。

このマニュアルの例はすべて `nilu` コマンドで動かしているので、`print` を使います。

## 1.4. 数は整数か浮動小数点数です

```lua nilu
print(1 + 2)
print(7 / 2)
print(7 // 2, 7.0 // 2)
print(1e15)
```
```output
3
3.5
3	3.0
1e+15
```

数には整数と浮動小数点数（float）の 2 種類があります。Lua と同じです。整数どうしの `1 + 2` は
整数の `3` になり、`/` はいつも浮動小数点数を返します。値が整数の浮動小数点数は `.0` を付けて
出ます。`1e15` のように指数を書いた数値は浮動小数点数です。

`/` で 0 で割っても失敗しません。無限が返ります（整数を `//` や `%` で 0 で割ると実行時エラー
です。[5.2](05-expressions.md#52-算術)）。

```lua nilu
print(1 / 0)
print(-1 / 0)
print(0 / 0)
```
```output
inf
-inf
nan
```

Nilu は NaN をいつも `nan` と書きます。`lua5.5` は `0 / 0` を `-nan` と書きます
（符号ビットを C の `printf` にそのまま渡すので）。これは意図した違いです
（[13. Lua との違い](13-differences-from-lua.md)）。

数の書き方と表示のしかたは [2. 値と型](02-values.md) にあります。

## 1.5. ⚠ 式は文ではありません

```lua nilu-refused
1 + 2
```

これはプログラムではありません。文がないからです。`return 1 + 2` か
`print(1 + 2)` と書いてください。

これは Lua と同じ規則で、関数呼び出しだけが単独で文になれます。
プロンプトだけは例外に見えますが、それはコマンドが `return` を付け足しているからで、
文法は変わっていません。

---

次: [2. 値と型](02-values.md)
