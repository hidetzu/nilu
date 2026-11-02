[← 目次](README.md)

# 15. 文法

いまの構文の全体です。`{A}` は 0 回以上、`[A]` は省略可能を表します。

```ebnf
chunk       ::= block

block       ::= {statement} [return]

statement   ::= 'local' attrib attnamelist ['=' explist]
              | 'local' 'function' Name funcbody
              | 'global' attrib '*'
              | 'global' attrib attnamelist ['=' explist]
              | 'global' 'function' Name funcbody
              | varlist '=' explist
              | functioncall
              | 'if' exp 'then' block {'elseif' exp 'then' block} ['else' block] 'end'
              | 'while' exp 'do' block 'end'
              | 'repeat' block 'until' exp
              | 'goto' Name
              | '::' Name '::'
              | 'for' Name '=' exp ',' exp [',' exp] 'do' block 'end'
              | 'for' namelist 'in' explist 'do' block 'end'
              | 'do' block 'end'
              | 'function' funcname funcbody
              | 'break'
              | ';'

return      ::= 'return' [explist] [';']

namelist    ::= Name {',' Name}
attnamelist ::= Name attrib {',' Name attrib}
attrib      ::= ['<' Name '>']
varlist     ::= var {',' var}
var         ::= Name | prefixexp '[' exp ']' | prefixexp '.' Name
explist     ::= exp {',' exp}

exp         ::= 'nil' | 'true' | 'false' | Numeral | String | '...'
              | functiondef
              | prefixexp
              | tableconstr
              | exp binop exp
              | unop exp

prefixexp   ::= var | functioncall | '(' exp ')'
functioncall::= prefixexp args | prefixexp ':' Name args
args        ::= '(' [explist] ')' | tableconstr | String

functiondef ::= 'function' funcbody
funcname    ::= Name {'.' Name} [':' Name]
funcbody    ::= '(' [parlist] ')' block 'end'
parlist     ::= namelist [',' varargs] | varargs
varargs     ::= '...' [Name]

tableconstr ::= '{' [field {fieldsep field} [fieldsep]] '}'
field       ::= '[' exp ']' '=' exp | Name '=' exp | exp
fieldsep    ::= ',' | ';'

binop       ::= '+' | '-' | '*' | '/' | '//' | '%' | '^' | '..'
              | '&' | '|' | '~' | '<<' | '>>'
              | '<' | '<=' | '>' | '>=' | '==' | '~='
              | 'and' | 'or'
unop        ::= '-' | 'not' | '#' | '~'
```

ここには、文法の字面だけでは読み取れないことを書きます。

- **`t:m(…)` は `t.m(t, …)` ではありません** —— 受け手は**一度だけ**評価されます。
  `function t:m(a)` は `self` を暗黙の第 1 引数として宣言します（`self` は予約語ではありません）。
- **`...name` は後ろの引数のテーブルに名前を付けます**。`Name` はそれらと個数 `n` を入れた
  読み取り専用のローカルで、`...` はそのテーブルを読みます（[6.3](06-functions.md#63-宣言していない引数--)）。
- **後ろに呼び出しや添字を続けられるのは名前と `( exp )` だけ**です。`{1, 2}[1]` や `"ab":len()` は
  文法どおり断られます。
- `local` の名前の前の `attrib` は、並べた名前すべての既定になります。受け付ける属性は `const` だけで、
  `<close>` は `attribute 'close' is not supported` と断られます。`global` の属性で `<close>` は
  `global variables cannot be to-be-closed` と断られます。
- `fieldsep` は **2 つが交換可能**で、**末尾に 1 つ置けます**。
  `Name '=' exp` は `'[' String ']' '=' exp` の書き方違いです（`t.k` が `t["k"]` なのと同じ）。

**構文の深さは200段までです。** リテラル、名前、可変長引数の深さは0です。
括弧、単項・二項演算、フィールド・添字・呼び出しの接尾辞、テーブル構築、関数、
制御構文は、子の深さの最大値にそれぞれ1を加えます。メソッド呼び出しの接尾辞は
呼び出し1段です。ルートや本体のブロック、return・宣言・代入の容器、リストは
段数を加えません。並列な式、フィールド、文、elseifの各節は合計でなく最大値を
使います。そのため、制御構文とその本体ブロックを二重には数えません。

たとえばリテラルを囲む括弧は200段まで受け入れ、201段を断ります。演算子や接尾辞の
連鎖も200段までで、201段目を断ります。混在する入れ子も同じ上限を共有し、doが100段、
その中の括弧が100段なら収まります。上限を最初に超える演算子や開きトークンの位置を、
`chunk has too many syntax levels (limit is 200)` と行・バイト単位の桁で報告します。
関数の呼び出し深度や実行時のスタック容量は別の上限です。

ソースは 4294967294 バイトまでです。それより長いものは、1 バイトも読まずに
1 行 1 桁で `chunk is too large (limit is 4294967294 bytes)` と断ります。オフセット、行、
桁を 32 ビットで持ち、構文木を小さく保つためです。

## 15.1. 予約語

```text
and      break    do       else     elseif   end      false
for      function goto     if       in       local    nil
not      or       repeat   return   then     true     until
while
```

22 語です。**この一覧はリポジトリの検査が全部確かめています** —
`every word of the grammar is reserved, and global is not` が、各語について
`local <語> = 1` と `t.<語> = 1` の両方が構文エラーになることを見ています。
一覧だけでは落ちないので、一覧だけでは足りません。

```lua nilu-refused
local and = 1
```

```lua nilu-refused
local t = {}
t.end = 1
```

予約語はフィールド名にも使えません。`t.end` は書けませんが `t["end"]` は書けます。

```lua nilu
local t = {}
t["end"] = "書ける"
print(t["end"])
```
```output
書ける
```

`do` は `while`、`for` と、それ自身の `do … end` の文にあります。

**`global` は予約語ではありません。** 上の一覧に入っていないのがその主張で、
これも同じ検査が見ています。変数名に使えます。

## 15.2. 字句

| | |
|---|---|
| 名前 | `[A-Za-z_][A-Za-z0-9_]*`。**ASCII だけです** |
| 数 | `3`、`3.5`、`.5`、`3.`、`1e9`、`1E-2`、`0x10`、`0x1p4` |
| 文字列 | `"…"`、`'…'`、または `[[…]]`（`[==[…]==]` も）。エスケープは Lua と同じです（[2. 値](02-values.md#エスケープ)） |
| コメント | `--` から行末まで。`--[[ … ]]` は複数行にわたります |
| 空白 | 空白、タブ、改行、改ページ、垂直タブ。意味はありません |

数のあいだに `_` は書けません。

```lua nilu-refused
return 1_0
```

`--[[` から `]]` までがコメントです。**同じ行の `]]` の後ろは普通のコードです。**

```lua nilu
--[[ これは
コメントです ]] print("ここは動きます")
```
```output
ここは動きます
```

## 15.3. 優先順位

弱いほうから強いほうへ。

| 演算子 | 結合 |
|---|---|
| `or` | 左 |
| `and` | 左 |
| `<` `>` `<=` `>=` `~=` `==` | 左 |
| `\|` | 左 |
| `~` | 左 |
| `&` | 左 |
| `<<` `>>` | 左 |
| `..` | **右** |
| `+` `-` | 左 |
| `*` `/` `//` `%` | 左 |
| `not` `#` `-` `~`（単項） | — |
| `^` | **右** |

驚くところだけ、実際に動かして確かめます。

```lua nilu
print(2 ^ 3 ^ 2)
print(-2 ^ 2)
print(1 + 2 * 3)
```
```output
512.0
-4.0
7
```

`^` は右結合で、単項マイナスより強い。だから `2 ^ 3 ^ 2` は `2 ^ (3 ^ 2)` で、
`-2 ^ 2` は `-(2 ^ 2)` です。

`..` も右結合です。文字列では結果が同じなので、見分けるには長さの違う組み合わせが要ります。

```lua nilu
print("a" .. "b" .. "c")
print(#("a" .. "b" .. "c"))
```
```output
abc
3
```

`not`、`#`、単項の `-` は、`^` を除くどの二項演算子よりも強く結びつきます（比較よりも強い）。

```lua nilu
print(not 1 == 2)
print(#"abc" + 1)
print(not (1 == 2))
```
```output
false
4
true
```

1 行めが `false` なのは `(not 1) == 2` と読まれるからです。`not 1` は `false` で、
`false == 2` は `false`。**括弧を書いたほうがいい場所です。**

比較は連ねられません。

```lua nilu
return 1 < 2 < 3
```
```stderr
nilu: <manual>:1: attempt to compare boolean with number
```

**構文としては通ります。** `1 < 2` は真偽値で、`true < 3` が型エラーになるので、
落ちるのは走らせたときです。

## 15.4. 書けないもの

このマニュアルの中で「構文エラーです」と書いてあるところは、
すべて実際に走らせて確かめてあります。代表的なものを並べます。

```lua nilu-refused
1 + 2
```

```lua nilu-refused
x
```

```lua nilu-refused
for i = 1, 3 do
  i = 9
end
```

```lua nilu-refused
break
```

```lua nilu-refused
return 1
print("あと")
```

```lua nilu-refused
local break = 1
```

## 15.5. 文法が増えたらどうなるか

このマニュアルの文法は、**いま実装されているものだけ**です。
[13.2](13-differences-from-lua.md#132-まだ無いもの) に挙げたものが入れば、
ここも増えます。Lua の文法との差分がそのまま残りの作業の一覧になっています。

---

[← 目次](README.md)
