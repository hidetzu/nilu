[← 目次](README.md)

# 12. C から埋め込む

必要なのは 2 つのファイルだけです。

| ファイル | 何か |
|---|---|
| `nilu.h` | 宣言 |
| `libnilu.a` | 静的ライブラリ |

```bash
cc -std=c99 myhost.c -I path/to/include path/to/libnilu.a -lm -o myhost
```

`-lm` は数学の関数（`log`、`exp`、`fmod`）のためで、gcc では要ります。

これだけで動くことは、このリポジトリの `zig build example` が毎回確かめています。
`examples/` のホストを、**インストールされたヘッダとライブラリだけ**に対して、
`zig cc` でコンパイルして走らせる作りになっています。

state の寿命を決める前に、[回収の制約](09-gc.md)を確認してください。
読み込んだ関数本体は `nilu_close` まで残り、回収は VM 命令の間だけで起きます。
長期間使う state に繰り返し読み込むとメモリを保持し続け、ホスト側だけの確保では
回収は始まりません。可能なら一度読み込んだ関数を繰り返し呼び出してください。
state を作り直すとメモリを解放できますが、グローバル、クロージャなどの値も失うため、
必要な状態はホストが再設定します。userdata には終了処理がないので、ファイルや
ソケットなど外部の資源はホストが明示的に閉じてください。

一つの state は同時に一つのスレッドからだけ使ってください。別々の state は
別々のスレッドで同時に使えます。同一 state の並行使用は未定義です。
コールバックからのアクセスも含め、ホストがアクセスを調整します。native 関数や
フックからの同期的な再入には既存の呼び出し・フックの規則が適用され、別スレッド
からの同時アクセスを許すものではありません。公開 C コンストラクタは自身で
アロケータを選び、ホストのアロケータを受け取る引数はありません。内部 Zig
コンストラクタへアロケータを渡し複数スレッドで共有する場合、そのアロケータは
並行使用に対応している必要があります。コールバックが共有するホストの資源にも
ホスト側の同期が必要です。

0.1.0 のリリースまでは、開発版同士の API・ABI・言語・コマンドの互換性を
保証しません（[11.1](11-nilu-command.md#111-走らせ方)）。

## 12.1. いちばん短いホスト

```c nilu-c
#include <stdio.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return 1 + 2", NULL) != NILU_OK) {
    printf("プログラムとして読めなかった\n");
    nilu_close(N);
    return 1;
  }
  if (nilu_call(N, 0, 1) != NILU_OK) {
    printf("走らせたら失敗した\n");
    nilu_close(N);
    return 1;
  }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
3
```

`nilu_new` が状態を作り、`nilu_close` が全部解放します。
状態がメモリを所有しているので、ホストが個別に解放するものはありません。
`nilu_openlibs` はすべてのライブラリを開きます。`nilu_openselectedlibs(N, NILU_LIB_BASE | NILU_LIB_STRING)` は
名前を挙げたものだけを開きます（`NILU_LIB_BASE`、`_PACKAGE`、`_COROUTINE`、`_DEBUG`、`_MATH`、`_STRING`、
`_TABLE`、`_UTF8`。値は Lua 5.5 と同じ）。それ以上を持たせたくないプログラムに使います。
`nilu_newstate(f, ud)` は、メモリをホストの `f` から取る状態を作ります。形は Lua の `lua_Alloc` と同じで、
`f(ud, NULL, 0, n)` で確保、`f(ud, p, old, 0)` で解放、`f(ud, p, old, n)` で取り直し、できなければ NULL を返します。
`nilu_close` は、すべてのブロックをこれを通して返します。メモリは `malloc` と同じ整列でなければなりません。

**この例は、このマニュアルを作るたびに実際にコンパイルして走らせています** —
インストールされた `nilu.h` と `libnilu.a` だけに対して。だから「この 2 つで足りる」は
約束ではなく測定です。

`%g` で出しているので `3` と出ます。Nilu の `tostring` でも `3` です
（[2.3](02-values.md#表示のしかた)）。C 側は C の書式で出すだけで、
Nilu の表示規則とは関係ありません。

## 12.2. スタック

値のやりとりはスタックを通します。

- 添字は **1 から**。`1` が底、`2` がその上
- 負の添字は上から。`-1` が一番上
- **`0` はどこも指しません**
- `nilu_gettop` が深さ、`nilu_settop` が深さを決める

これは Lua の規約をそのまま借りています。名前も Lua のものを借りていて、
違うところは名前を変えずに**振る舞いの違い**として書いてあります。

**数は、Lua の API と同じく浮動小数点数か整数として渡ります。** `nilu_pushnumber` は浮動小数点数を、
`nilu_pushinteger` は整数（`NiluInteger`。`NILU_MININTEGER` から `NILU_MAXINTEGER` まで）を積みます。
`nilu_tonumberx` はどちらも浮動小数点数として読みます。`nilu_tointegerx` は整数か、値が整数の浮動小数点数を読み、
読めたかどうかを最後の引数で返します。`nilu_isinteger` は整数のときだけ真です。

## 12.3. ほとんどの関数は状態を返します

```c
NiluStatus status = nilu_pushnumber(N, 1.5);
```

Lua が `void` や型を返すところで、Nilu は `NiluStatus` を返します。
失敗を値で言うためです。これが Nilu と Lua の、API の一番大きな違いです。

| 状態 | いつ |
|---|---|
| `NILU_OK` | 通った |
| `NILU_ERR_SYNTAX` | ソースがプログラムとして読めなかった |
| `NILU_ERR_TYPE` | その型にできないことをした |
| `NILU_ERR_RUNTIME` | 関数が失敗を返した |
| `NILU_ERR_CALL_DEPTH` | 呼び出しが深すぎる |
| `NILU_ERR_STACK` | スタックがこれ以上伸びない。`nilu_call` と `nilu_pcall` に頼んだ結果の数が入らないときは、呼ぶ前にこれで断ります |
| `NILU_ERR_MEMORY` | 確保できなかった |
| `NILU_ERR_INTERRUPTED` | フックが止めた |

**状態そのものに文章は付きません。** 言葉は**失敗が運ぶ値**のほうに入っていて、
中核の失敗なら Lua と同じ 1 行です——
呼び出しが失敗したあと、スタックの一番上を `nilu_tostring` で読んでください。
メモリ不足でも `not enough memory` が積まれています。

**構文エラーも文章を運びます**。
`nilu_loadnamed` が失敗したら、位置は out 引数に入り、
**文章はスタックのトップに載ります**——`nilu_tostring(N, -1)` で読んでください。
形は `<チャンク名>:<行>:<桁>: <言葉> near '<トークン>'` です。
読み込みが失敗したあと、スタックにはその値が 1 つ残ります。

```c nilu-c
#include <stdio.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  NiluError where = {0, 0};

  if (nilu_loadstring(N, "local = 1", &where) != NILU_OK) {
    printf("%d 行 %d 桁\n", where.line, where.column);
  }

  nilu_close(N);
  return 0;
}
```
```output
1 行 7 桁
```

`where.line` が 0 なら、位置は分かりません。

## 12.4. ホストの関数をプログラムに渡す

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int host_double(NiluState *N) {
  int ok = 0;
  double x;
  if (nilu_gettop(N) < 1) return NILU_FAIL;
  x = nilu_tonumberx(N, 1, &ok);
  if (!ok) return NILU_FAIL;
  if (nilu_pushnumber(N, x * 2) != NILU_OK) return NILU_FAIL;
  return 1;              /* 返す値の数 */
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_pushcfunction(N, host_double) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_setglobal(N, "double") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return double(21)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
42
```

これでプログラムが `double(21)` と書けます。

- 引数は `1` から `nilu_gettop(N)` まで。それより下は見えません
- 返すのは「積んだ値の数」。`0` でもかまいません
- 失敗は `NILU_FAIL`。理由を付けるときは、文章を積んで `return nilu_error(N);` と書きます（Lua の `lua_error`）
- どう呼ばれたかは `nilu_namewhat(N)` が答えます（`"method"`、`"local"`、`"global"`、`"field"` など。Lua の `ar.namewhat`）。`t:f()` と呼ばれたときは `self` を数えずに引数の番号を言うと、Lua のライブラリと同じ断りになります
- 引数の確認はこの関数の仕事です。`nilu_call` は何も確かめません

プログラムから呼ばれたときも、ホストから呼ばれたときと**まったく同じもの**が
見えます。どちら側から呼ばれたかを知る方法はありません。

`print` もこうやって作られています（[`cli/nilu.c`](../../cli/nilu.c)）。

### 引数を検査する

**ライブラリの引数の検査は、ホストの C の関数でも使えます**（Lua の `luaL_check*`、`luaL_opt*`、
`luaL_argerror`、`luaL_typeerror`）。`nilu_checkany`、`nilu_checktype`、`nilu_checknumber`、`nilu_checkinteger`、
`nilu_checklstring`、それぞれの `nilu_opt*`、`nilu_argerror`、`nilu_typeerror` です。断りはライブラリと同じ文に
なります。`bad argument #2 to 'twice' (…)`、メソッドなら `calling 'm' on bad self (…)` で、関数の名前は呼んだ側が
書いたもの、無ければ `?` です。検査は C の関数から抜けられないので、0 か、失敗を上げたうえで `NILU_FAIL` を返し、
C の関数はそれを返します。

```c nilu-c
#include <stdio.h>
#include "nilu.h"

/* twice(text, count): a refusal reads as the library's would. */
static int twice(NiluState *N) {
  const char *text;
  long long count;
  if (nilu_checklstring(N, 1, &text, NULL) != 0) return NILU_FAIL;
  if (nilu_checkinteger(N, 2, &count) != 0) return NILU_FAIL;
  if (nilu_pushstring(N, text) != NILU_OK) return NILU_FAIL;
  return 1;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_pushcfunction(N, twice) != NILU_OK || nilu_setglobal(N, "twice") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadstring(N, "twice('a', 1.5)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_pcall(N, 0, 0, 0) == NILU_OK) { nilu_close(N); return 1; }
  printf("%s\n", nilu_tostring(N, -1));
  nilu_close(N);
  return 0;
}
```
```output
[string "twice('a', 1.5)"]:1: bad argument #2 to 'twice' (number has no integer representation)
```

### 状態を持つホストの関数 — C クロージャ

関数に値を持たせたいとき（カウンタ、イテレータ）、グローバルに置かずに
**関数自身に持たせる**ことができます。積んだ値を `nilu_pushcclosure` で関数に畳み込み、
走っている間は `nilu_getupvalue` / `nilu_setupvalue` で読み書きします。

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int tick(NiluState *N) {
  double n;
  if (nilu_getupvalue(N, 1) != NILU_OK) return NILU_FAIL;   /* 上位値 1 を積む */
  n = nilu_tonumberx(N, -1, NULL);
  nilu_settop(N, -2);
  if (nilu_pushnumber(N, n + 1) != NILU_OK) return NILU_FAIL;
  if (nilu_pushvalue(N, -1) != NILU_OK) return NILU_FAIL;
  if (nilu_setupvalue(N, 1) != NILU_OK) return NILU_FAIL;   /* 先頭を上位値 1 に戻す */
  return 1;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_pushnumber(N, 0) != NILU_OK) { nilu_close(N); return 1; }                 /* 上位値になる値を先に積む */
  if (nilu_pushcclosure(N, tick, 1) != NILU_OK) { nilu_close(N); return 1; }         /* 1 つ畳み込む。積んだ値は消えてクロージャが残る */
  if (nilu_setglobal(N, "tick") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return tick() + tick() + tick()", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", nilu_tonumberx(N, -1, NULL));

  nilu_close(N);
  return 0;
}
```
```output
6
```

- 上位値は積んだ順に `1` から。最大 `NILU_MAXUPVALUES`（255）
- `nilu_pushcclosure(N, f, 0)` は `nilu_pushcfunction(N, f)` と同じ値を積みます
- 無い番号を読む・書くと `NILU_ERR_TYPE`。**スタックは動きません**（書き損ねた値は先頭に残ります）
- 走っていないとき（ホスト側、または普通の関数の中）に呼んでも `NILU_ERR_TYPE`
- 同じ関数から作った 2 つのクロージャは**別の値**です。`==` は偽で、`tostring` も違います
- どこからも届かなくなったクロージャは回収され、持っている値は持たれている間だけ生きます

Lua の `lua_upvalueindex(i)` にあたる擬似インデックス（どの API 呼び出しからでも上位値を
直接指せる仕組み）は**ありません**。読む・書くの 2 呼び出しがその代わりです。

## 12.5. 止まらないプログラムを止める

```c nilu-c
#include <stdio.h>
#include "nilu.h"

static int ticks = 0;

static int hook(NiluState *N) {
  (void)N;
  /* 3 回呼ばれたらあきらめる。本物のホストなら、時間や合図を見ます。 */
  return (++ticks >= 3) ? NILU_FAIL : NILU_OK;
}

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  nilu_sethook(N, hook, 1000);   /* 1000 命令ごとに呼ぶ */

  if (nilu_loadstring(N, "while true do end", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 0) == NILU_ERR_INTERRUPTED) {
    printf("止めた\n");
  }

  nilu_close(N);
  return 0;
}
```
```output
止めた
```

**終わらないプログラムが、ホストの手で止まっています。** フックが止めると
`nilu_call` は `NILU_ERR_INTERRUPTED` を返します。プログラムの `pcall` には捕まらず、
メッセージハンドラも走りません。スタックに残るのは `nil` です。間にある C の関数も止められません。
ホストの呼び出しが戻るまで、その関数がする `nilu_call` は何も動かさずに `NILU_ERR_INTERRUPTED` を返し、
その関数が何を返しても中断になります。ホストの次の呼び出しは普通に動きます。

**フックが数えるのは Nilu の VM の命令だけです。** ホストが書いた C の関数が
返ってこない場合は、フックも呼ばれません。その関数はホストのものなので、
止める責任もホストにあります。

フックは空の一時スタック窓から始まり、停止中のVMレジスタや呼出元のスロットは参照できません。
その窓に積んだ値は、実行を続ける場合も中断する場合も、コールバックから戻るときに破棄されます。

コールバックは、この state の VM をもう一度走らせることができます。自分の窓に関数を積むか読み込み、
`nilu_call` か `nilu_pcall` で呼びます。内側の命令も同じフックが観測し、そのコールバックもそれぞれ
空の窓から始まります。内側の呼び出しから戻ると、外側のコールバックの窓は元のままです。
数える回数は state に 1 つで、内側の命令もそれを消費し、戻っても巻き戻しません。内側の呼び出しを
フックが止めると、コールバックは `NILU_ERR_INTERRUPTED` を受け取り、外側の呼び出しをどうするかは
コールバック自身の返り値だけで決まります。止めるたびに呼び直すコールバックは、通常の呼び出し上限
（[8.2](08-failure.md#82-失敗の種類)）で尽きます。コールバックの中で行った `nilu_sethook` は state 全体に即座に効きます。

## 12.5.1. 失敗したところを見る

`nilu_error` で失敗をそのまま中継すると、Typeなど元のステータスを保持します。
新しくraiseした場合は、値や文章が同じでもRuntimeです。
Cスタック上の移動・複製は失敗の起源を保ちますが、新しく作った値や変換後の値、
テーブルに保存して読み直した値には起源を持たせません。
保護呼び出しで捕捉すると伝播はそこで終わり、捕捉した値を後から投げ直す場合は新しいRuntimeです。
割り込みは捕捉せず、nilを運びます。


**`nilu_pcall` は失敗を止める呼び出しで、メッセージハンドラを付けられます**。
**`nilu_call` は失敗を外へ通す呼び出しです**。外側の `nilu_pcall` の
ハンドラは、`nilu_call` の先で失敗したところで走ります。ネイティブ関数が `nilu_call` から失敗を
受け取ったら、`return nilu_error(N);` で外へ渡してください。
失敗の値はスタックの先頭にあり、`nilu_error` はそれを運びます。**裸の `NILU_FAIL` を返すと値は運ばれず、
外側の `pcall` は `false nil` を受け取ります**（`nilu_error(N)` なら `false` と投げられた値。
ライブラリはこう書いています）。失敗のあとも続けたいとき、投げられたままの値が欲しいときは、
`nilu_pcall(N, nargs, nresults, 0)` を使います。ライブラリの `pcall` もそうしています。
`lua_pcall(L, nargs, nresults, msgh)` と同じ形で、`msgh` はスタックの添字、**`0` はハンドラ無し**です。

```c
NiluStatus nilu_pcall(NiluState *N, int nargs, int nresults, int msgh);
```

**ハンドラが何のためにあるかは、「いつ走るか」です** —— **失敗したフレームの上、巻き戻す前**。
だからハンドラの中では `nilu_where(N, 1, &where)` が**失敗した時点で立っていたフレームの鎖**を
歩けます。`2` はその呼び出し元、`3` はさらにその上です。ネイティブ関数のフレームでは `"[C]"` と
行 0 が返り、`NULL` は「その段は無い」だけを意味します。

**`nilu_call` が返ってからでは、これは取れません。** 返った後に残っているのは
**失敗したフレーム自身の位置だけ**です（`nilu_where(N, 0, …)`）。トレースバックが
欲しければハンドラの中で作る、というのがこの関数がある理由です。

`nilu_where` が返すchunk名のポインタは、同じstateで次の呼び出しの実行が始まるか、
stateを閉じるまで有効です。位置を続けて照会しても先に取得した名前は無効化されません。
負のlevelはNULLを返し、座標を{0,0}にします。出力ポインタはNULLでも構いません。
実行時のcolumnは常に0です。lineがC intに収まらない場合もchunk名は返し、座標は{0,0}にします。

Lua の呼び出し履歴のように各段の関数が何かを書くには、同じ数え方で段を指す呼び出しが 2 つあります。

```c
const char *nilu_callername(NiluState *N, int level, const char **namewhat);
int nilu_linedefined(NiluState *N, int level);
```

`nilu_callername` は、その段の関数が呼ばれたときの名前（`"inner"`）を返し、名前の種類を `nilu_namewhat` と
同じ言葉で `*namewhat` に入れます（`"upvalue"`）。名前が無ければ `NULL` と `""` です。
`nilu_linedefined` は、その関数の `function` の行を返します。チャンクなら `0`、ネイティブ関数か、
関数の無い段なら `-1` です。`nilu` コマンドの呼び出し履歴はこの 2 つで組み立てています
（[11.3](11-nilu-command.md#113-失敗したときの書き方)）。

```c nilu-c
#include <stdio.h>
#include <string.h>
#include "nilu.h"

/* 失敗した時点の鎖を書き出すハンドラ。1 つ返すのが約束です。 */
static int show_the_chain(NiluState *N) {
  NiluError w;
  int level;
  for (level = 1; level <= 3; level++) {
    const char *name = nilu_where(N, level, &w);
    if (name == NULL) break;
    printf("  level %d: %s:%d\n", level, name, w.line);
  }
  if (nilu_pushstring(N, "handled") != NILU_OK) return NILU_FAIL;
  return 1;
}

int main(void) {
  const char *source =
      "global *\n"
      "local function c() local v = 1 + nil return v end\n"
      "local function b() local v = c() return v end\n"
      "local v = b() return v\n";
  NiluError where;
  NiluState *N = nilu_new();
  if (N == NULL) return 1;

  if (nilu_pushcfunction(N, show_the_chain) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadnamed(N, source, "=example", &where) != NILU_OK) { nilu_close(N); return 1; }
  /* ハンドラは添字 1、関数はその上。ハンドラは関数より下に置きます。 */
  if (nilu_pcall(N, 0, 0, 1) == NILU_OK) { nilu_close(N); return 1; }
  printf("answered: %s\n", nilu_tostring(N, -1));

  nilu_close(N);
  return 0;
}
```
```output
  level 1: example:2
  level 2: example:3
  level 3: example:4
answered: handled
```

**ハンドラは 1 つの引数（失敗が運ぶ値、無ければ `nil`）を受け取り、1 つ返します。**
返した値が、失敗が運ぶ値を**置き換えます**。

**ハンドラ自身が失敗すると `error in error handling` です。** そして
**ハンドラは自分の失敗に対しては走りません** —— 入れ子は 1 段で止まります。

⚠ **ハンドラは関数より下に置いてください。** 関数と同じ位置か上だと断ります（abort します）——
そこは呼ばれる関数のレジスタが使う場所で、**上書きされたスロットから読んで答えるより、
断るほうがよい**という判断です。Lua はこれを検査しません。

通常の実行は、同時に生存するscriptとnativeのフレームを合わせて200までです。
失敗ハンドラの実行中は、ハンドラ自身とその呼び出し全体で220まで使えます。
内側の保護呼び出しやホスト再入で余力は増えません。scriptの末尾置換はフレームを
増やさず、nativeへの末尾呼び出しはscriptの呼び出し元も残します。
ハンドラ終了後は通常の上限に戻ります。

ハンドラ成功時は元のステータスと位置を保ち、値だけを置き換えます。
ハンドラ自身の失敗（深度・stack不足・内部のメモリ不足を含む）は
`NILU_ERR_RUNTIME` と `error in error handling` になり、位置は元の失敗のままです。
中断は `NILU_ERR_INTERRUPTED` と `nil` のままです。
最初に内部のメモリ不足が起きた場合は、従来どおりハンドラを呼びません。

## 12.6. ホストのデータをプログラムに持たせる

**`userdata` は、状態が所有するバイト列です。** ホストが書き、プログラムは持ち運べるだけ
——メタテーブルを与えないかぎり、中身には手が届きません。

```c nilu-c
#include <stdio.h>
#include <string.h>
#include "nilu.h"

int main(void) {
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  void *block = NULL;

  if (nilu_openlibs(N) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_newuserdata(N, sizeof(double), &block) != NILU_OK) { nilu_close(N); return 1; }
  *(double *)block = 2.5;
  if (nilu_setglobal(N, "handle") != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_loadstring(N, "return type(handle)", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_call(N, 0, 1) != NILU_OK) { nilu_close(N); return 1; }
  printf("%s\n", nilu_tostring(N, -1));
  if (nilu_settop(N, 0) != NILU_OK) { nilu_close(N); return 1; }

  if (nilu_getglobal(N, "handle") != NILU_OK) { nilu_close(N); return 1; }
  printf("%g\n", *(double *)nilu_touserdata(N, -1));

  nilu_close(N);
  return 0;
}
```
```output
userdata
2.5
```

**バイト列は 0 で埋まっていて、どんな型でも書ける境界に揃えてあります。**
`double` やポインタをそのまま代入してかまいません。

**所有するのは自分のバイト列だけです。** ここには終了処理がありません——`__gc` は無く、
回収されるときに何も走りません。ファイルやソケットを握るなら、**閉じるのはホストです**。
`__gc` を持つメタテーブルは、黙って無視するのではなく**断ります**（`NILU_ERR_TYPE`）。

**メタテーブルを与えると、テーブルと同じように答えます。** `__index`、`__newindex`、
`__len`、`__call`、演算子、`__name` ——どれもテーブルのときと同じです。
**例外は `__eq` です。** `==` が `__eq` を呼ぶのは両方がテーブルのときだけなので、
`userdata` 同士の `==` は同じものかどうかだけを答えます（Lua は両方が full userdata でも呼びます——
[13.1](13-differences-from-lua.md#131-違うところ)）。
与えないと、プログラムからは何もできません。

```lua nilu
-- ホストが handle を登録していないので、ここでは nil です
print(type(handle))
```
```output
nil
```

**自分の `userdata` かどうかを見分けるには**、メタテーブルを自分の C クロージャの上位値に
置いておき（[12.4](#124-ホストの関数をプログラムに渡す)）、`nilu_getmetatable` で読んで
`nilu_rawequal` で比べます。Lua がレジストリでする型付けを、ここでは上位値でします。

**userdata にはプログラムの値を持たせられます**（Lua のユーザ値）。`nilu_newuserdatauv(N, size, nuvalue, &block)`
で `nuvalue` 個持たせ、初めは nil です。`nilu_getiuservalue(N, idx, n)` は n 番目を積んでその型を返し、無ければ
nil を積んで `NILU_TNONE` を返します。`nilu_setiuservalue(N, idx, n)` は一番上の値を取ってそこへ入れ、無ければ
0 を返します。値は userdata が生きているあいだ生きています。

**レジストリはホストのために値を持ちます**（Lua の `luaL_ref`）。`nilu_ref(N)` は値を取ってその参照を返し、
nil なら `NILU_REFNIL`、メモリが無ければ `NILU_NOREF` を返します。`nilu_getref(N, ref)` は値を積み直し、
`nilu_unref(N, ref)` は手放します。参照が持っている値は回収されません。擬似インデックスは無く、レジストリには
参照を通してだけ届きます。

## 12.6.1. コルーチンを動かす

**コルーチンはスタックの上の値です**。プログラムの中と同じです（[10.8](10-library.md#108-コルーチン)）。
`nilu_newthread` は、一番上の関数をそれを動かすスレッドに置き換えます。`nilu_resume(N, idx, nargs, &nresults)`
は、添字 `idx` のスレッドを上の `nargs` 個の値で再開し、返されたものを積みます。戻ったなら `NILU_OK`、
yield したなら `NILU_YIELD`、失敗したならその状態と失敗の値です。
C の関数は `return nilu_yield(N, n)` で、自分を呼んだコルーチンを止め、上の `n` 個の値を渡します。

```c nilu-c
#include <stdio.h>
#include "nilu.h"

/* Hands the program's question to the host by suspending the coroutine. */
static int ask(NiluState *N) {
  return nilu_yield(N, nilu_gettop(N));
}

int main(void) {
  int count = 0;
  NiluState *N = nilu_new();
  if (N == NULL) return 1;
  if (nilu_pushcfunction(N, ask) != NILU_OK || nilu_setglobal(N, "ask") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_loadstring(N, "local name = ask('name?') return 'hello, ' .. name", NULL) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_newthread(N) != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_resume(N, 1, 0, &count) != NILU_YIELD || count != 1) { nilu_close(N); return 1; }
  printf("asked: %s\n", nilu_tostring(N, -1));
  nilu_pop(N, 1);
  if (nilu_pushstring(N, "Nilu") != NILU_OK) { nilu_close(N); return 1; }
  if (nilu_resume(N, 1, 1, &count) != NILU_OK || count != 1) { nilu_close(N); return 1; }
  printf("answered: %s (%d)\n", nilu_tostring(N, -1), nilu_threadstatus(N, 1));
  nilu_close(N);
  return 0;
}
```
```output
asked: name?
answered: hello, Nilu (3)
```

`nilu_threadstatus` は `NILU_THREAD_SUSPENDED`、`_RUNNING`、`_NORMAL`、`_DEAD` を返します。
`nilu_pushrunning`、`nilu_isyieldable`、`nilu_closethread` は、`coroutine.running`、`isyieldable`、`close`
を書くのに使っているものです。`nilu_call` や `nilu_pcall`、メッセージハンドラ、フックの下での `yield` は、
`nilu_error` と同じ形で `attempt to yield across a C-call boundary` と断られます。

**`nilu_pcallk(N, nargs, nresults, msgh, ctx, k)` は、`yield` が通り抜けられる保護された呼び出しです**
（Lua の `lua_pcallk`）。呼ばれた側が yield すると `NILU_YIELD` を返し、C の関数は `nilu_yield(N, 0)` を返します。
再開のあとで呼ばれた側が終わると、`k(N, status, ctx)` が C の関数の代わりに動きます。`status` は `nilu_pcall`
が返したはずの状態で、スタックも `nilu_pcall` が残したはずの形です。`k` は C の関数が返したはずのものを返します。
`nilu_yield` を呼んだ、または `nilu_pcallk` から `NILU_YIELD` を受け取った C の関数が `nilu_yield` の答え以外を返すのは
API の誤用で、ほかの誤用と同じく `nilu_yield` の名前を出して異常終了します。
ライブラリの `pcall` と `xpcall` はこれで書いています。

## 12.6.2. プログラムがどこにいるかを読む

`nilu_getinfo(N, thread, level, what, &ar)` は、Lua の `lua_getstack` と `lua_getinfo` を 1 つにしたものです。
スタックの添字 `thread` のスレッド（動いているものなら 0）の段 `level` で動く関数について、`NiluDebug` を埋めます。
段の数え方は `nilu_where` と同じで、0 は尋ねている C の関数です。`what` が `>` で始まるときは、一番上の関数に
ついて答え、それを取り除きます。文字は Lua と同じです（`S l n u t r f L`）。`f` は関数を、`L` はコードのある
行のテーブルを積みます。返すのは 1、最後の段より先なら 0、知らない文字なら -1 です。`debug.getinfo` と
`debug.traceback` はこれで書いています（10.9）。

## 12.7. 気をつけること

- **読み込んだ関数は解放されません。** 繰り返し読み込むホストは、状態を
  閉じるまで増え続けます（[9.3](09-gc.md#93-いつ起きるか)）
- **文字列のポインタは、その値がスタックにある間だけ有効です。**
  落としたあとは、回収されているかもしれません
- `nilu_tolstring` は**数をその場で文字列に変えます**。読むだけのつもりで
  呼ぶと、`nilu_type` の答えが変わります。これは Lua の `lua_tolstring` と
  同じ危うさです
- `nilu_tolstring` は `nil`・真偽値・テーブル・関数には `NULL` を返します。
  それらを綴るのはライブラリの `tostring` です
- **確保を伴う操作は失敗しえます。** 状態を見てください
- **チャンクに名前を付けるなら `nilu_loadnamed`** です。`"=name"`・`"@file"`・それ以外（`[string "…"]`
  と表示）という Lua の約束で、`error("s")` の `name:line: s` と `nilu_where` の答えに使われます。
  `nilu_loadstring` はソース自身を名前にします（`luaL_loadstring` と同じ）
- **失敗した呼び出しの位置は `nilu_where(N, 0, &where)`** で取れます（チャンク名と行。無ければ
  `NULL` と 0）。`nilu` コマンドが `file:3:` と書くところはこれです。失敗が運ぶ文章も
  同じチャンク名と行を頭に持っています。これはスレッドごとにあります。コルーチンの中で捕まえた失敗は、それを
  再開したスレッドからは見えません。`nilu_resume` は呼び出しと同じに数えるので、再開のあとはコルーチンが失敗した
  位置を指すか、何も指しません
- **`math.random` は、ホストが種を与えないかぎり毎回同じ列です。** 中核は時計を持たないので、
  開いたばかりの状態は `math.randomseed(0)` のあとと同じです。テストにはそのほうが都合がよく、
  ゲームには驚きになります。Lua のように毎回違わせたいなら、`nilu` コマンドがしているように
  起動時に `math.randomseed` を API 経由で呼んでください（[`cli/nilu.c`](../../cli/nilu.c) の
  `seed_random`）
- **`require`、`dofile`、`loadfile` には、ホストが渡す読み手が要ります。** C の関数（ホストのデータを
  持たせるなら C クロージャ）を積んで `nilu_setreader` を呼んでください。ライブラリはそれを
  `reader(name, from, kind)` として呼びます。`kind` は `"module"` か `"file"`、`from` は読み込み中の
  ファイルの鍵か nil で、`key, text` か `nil, reason` を受け取ります（[10.7](10-library.md#107-コードを読み込む)、ヘッダー）。
  `nilu` コマンドの読み手は [`cli/nilu.c`](../../cli/nilu.c) の `host_reader` です
- **`nilu_setenv` は、読み込んだチャンクに自分の `_ENV` を持たせます。** `load` の 4 つ目の引数と同じことです
- **`print` には、ホストが渡す writer が要ります。** C の関数を積んで `nilu_setwriter` を呼んでください。`print` は
  呼ばれるたびに、改行まで含めた 1 行を渡してそれを呼びます（[1.3](01-getting-started.md#13--print-はホストが決めた先へ書きます)）。
  無ければ `print` は `cannot print: no writer was given to this state` で失敗します。`warn` は同じ writer を
  2 つ目の引数 `"warning"` を付けて呼び（10.1）、無ければ何もしません

## 12.8. 無いもの

| 無いもの | Lua では |
|---|---|
| 擬似インデックス | `LUA_REGISTRYINDEX`、`lua_upvalueindex`（レジストリには `nilu_ref` で、C クロージャの値には `nilu_getupvalue` で届きます） |
| フレームのローカル変数を読む呼び出し | `lua_getlocal`、`lua_setlocal`（`lua_getinfo` と `lua_getstack` は `nilu_getinfo` とその `NiluDebug` です。12.6.2。`lua_sethook` は借りています。`lua_getupvalue` と `lua_setupvalue` は名前を借りていますが、走っている C クロージャの値を番号で指します（[13.1](13-differences-from-lua.md#131-違うところ)）。`lua_getinfo` のうち `ar.name` は `nilu_calledas`、`ar.namewhat` は `nilu_namewhat`、`luaL_where` は `nilu_where` が担います） |
| 保護された呼び出し以外で、ホスト自身のコールバックの中で止まること | `lua_callk`、`lua_yieldk`（C の関数は戻るときにだけ yield できます。`nilu_pcallk` はあります） |
| 長さを取る読み込み | `luaL_loadbuffer`（`nilu_loadstring` は `\0` 終端だけ） |
| どの値でも綴る C の呼び出し | `luaL_tolstring`（`nilu_tolstring` は nil、真偽、テーブル、関数に NULL を返します） |

`nilu` コマンドは `luaL_loadbuffer` と `luaL_tolstring` の代わりを持っています。値を綴るときはグローバルの `tostring` を呼び（プログラムが `tostring` を置き換えると `print` の出力も変わります）、`\0` を含むソースは断ります。
**この表が C の API の「無いもの」の一覧です。**[13.2](13-differences-from-lua.md#132-まだ無いもの) は、ここを指しています。
スロットを動かす操作（`lua_insert`、`lua_rotate`、`lua_remove`、`lua_replace`）はあります（`nilu_rotate`、`nilu_copy` と
3 つのマクロ）。

---

次: [13. Lua との違い](13-differences-from-lua.md)
