[← 目次](README.md)

# 7. メタテーブル

テーブルには**メタテーブル**を付けられます。メタテーブルは普通のテーブルで、
決まった名前のフィールドに関数などを入れておくと、言語がそれを使います。

```lua nilu
local t = {}
local mt = {}
print(getmetatable(t))
setmetatable(t, mt)
print(getmetatable(t) == mt)
```
```output
nil
true
```

`setmetatable` は渡したテーブルをそのまま返します。だから作ってすぐ付ける書き方が
できます。

```lua nilu
local mt = {}
mt.__tostring = function() return "<私>" end
local t = setmetatable({}, mt)
print(t)
```
```output
<私>
```

`print` も `tostring` も `__tostring` を通します（`print` は `tostring` を呼んで結果を書きます）。

プログラムがメタテーブルを付けられるのはテーブルだけです。文字列や数には付けられません。
ホストが渡す `userdata` は、ホストが付けたメタテーブルを持てます（[12.6](12-embedding.md#126-ホストのデータをプログラムに持たせる)）。

## 7.1. `__index` — 持っていないキーを訊かれたとき

**テーブルがそのキーを持っていないときだけ**呼ばれます。

```lua nilu
local mt = {}
mt.__index = function(tbl, key) return "既定:" .. key end
local t = {}
setmetatable(t, mt)
t.own = "自分の値"
print(t.own, t.missing)
```
```output
自分の値	既定:missing
```

関数でなくテーブルを入れると、そのテーブルに訊きます。これが継承の形です。

```lua nilu
local base = {}
base.greet = "やあ"
local mt = {}
mt.__index = base
local t = {}
setmetatable(t, mt)
print(t.greet)
```
```output
やあ
```

`base` にも無ければ、`base` のメタテーブルに訊きます。鎖は 2000 段まで続き、それを超えると `'__index' chain too long; possible loop` で断られます（Lua と同じです）。

## 7.2. `__newindex` — 持っていないキーに書かれたとき

```lua nilu
local store = {}
local mt = {}
mt.__newindex = function(tbl, key, value) store[key] = value end
local t = {}
setmetatable(t, mt)
t.x = 1
print(t.x, store.x)
```
```output
nil	1
```

`t` 自身には何も入りません。これで読み取り専用のテーブルや、
書き込みを記録するテーブルが書けます。

**すでに持っているキーへの書き込みでは呼ばれません。**

```lua nilu
local mt = {}
mt.__newindex = function() print("呼ばれた") end
local t = {}
setmetatable(t, mt)
t.x = 1
t.x = 2
print(t.x)
```
```output
呼ばれた
呼ばれた
nil
```

2 回とも呼ばれます。メタメソッドが `t` に何も書いていないので、`t` は
いつまでも `x` を持たないままで、毎回メタメソッドに回されます。
`t.x` は `nil` です。`lua5.5` も同じ 3 行を返します。

`t` 自身に入れたいなら `rawset` を使ってください（[7.3](#73-生のアクセス)）。

## 7.3. 生のアクセス

メタテーブルを通さずにテーブル自身を読み書きするには `raw*` を使います。

```lua nilu
local mt = {}
mt.__index = function() return "メタ" end
local t = {}
setmetatable(t, mt)
print(t.k, rawget(t, "k"))
rawset(t, "k", "生")
print(t.k, rawget(t, "k"))
```
```output
メタ	nil
生	生
```

`rawequal` と `rawlen` も同じように、`__eq` や `__len` を通しません。

## 7.4. 演算子

次の名前が使えます。どれも**普通の演算が答えを出せないときだけ**呼ばれます。

**名前の探し方。** 名前はまずメタテーブル自身から読みます。メタテーブルに無く、そのメタテーブルの
メタテーブルが `__index` にテーブルを持っていれば、そのテーブルに訊き、以下同様です。つまり
`mt.__add` と書いたときと同じたどり方ですが、`__index` に入った関数は**呼びません**。名前を探す
あいだにコードは走りません。これで、ひとつの土台のメタテーブルに多くのメタテーブルの名前を
まとめて置けます。鎖は 7.1 と同じく 2000 段までで、それを超えると
`'__index' chain too long; possible loop` で断られます。下の表の名前はどれもこの探し方で、
`__index` と `__newindex` 自身も同じです。`__metatable`（と、`userdata` が断る `__gc`。12 章）だけは
書いたメタテーブルから読みます。これらは値ではなくメタテーブル自身のことを言う名前だからです。
Lua はどの名前もメタテーブル自身からしか読みません（13.1）。

| 名前 | いつ |
|---|---|
| `__add` `__sub` `__mul` `__div` `__idiv` `__mod` `__pow` `__unm` | 算術 |
| `__band` `__bor` `__bxor` `__shl` `__shr` `__bnot` | ビット演算 |
| `__concat` | `..` |
| `__len` | `#` |
| `__eq` | `==`（両方がテーブルで、同じものではないとき） |
| `__lt` `__le` | `<` `<=`（`>` と `>=` は左右を入れ替えて同じものを使います） |
| `__index` `__newindex` | 添字 |
| `__call` | 呼び出し |
| `__tostring` `__name` | `tostring`（`__name` は失敗の文章にも） |
| `__pairs` | `pairs` |

```lua nilu
local mt = {}
mt.__add = function(a, b) return "足した" end
mt.__len = function() return 99 end
mt.__unm = function() return "反転" end
mt.__concat = function() return "つないだ" end
local t = {}
setmetatable(t, mt)
print(t + 1, #t, -t, t .. "x")
```
```output
足した	99	反転	つないだ
```

左右どちらがテーブルでも呼ばれます。

```lua nilu
local mt = {}
mt.__add = function(a, b) return "足した" end
local t = {}
setmetatable(t, mt)
print(1 + t)
```
```output
足した
```

### 比較

`__eq` は、**両方がテーブルで、しかも同じものではないとき**だけ呼ばれます。

```lua nilu
local mt = {}
mt.__eq = function(a, b) return true end
local a = {}
setmetatable(a, mt)
local b = {}
setmetatable(b, mt)
print(a == b, a == 1, a ~= b)
```
```output
true	false	false
```

`a == 1` が `false` なのは、型が違うとメタメソッドまで行かないからです。
`~=` は `==` の否定で、別のメタメソッドはありません。

```lua nilu
local mt = {}
mt.__lt = function(a, b) return true end
local a = {}
setmetatable(a, mt)
local b = {}
setmetatable(b, mt)
print(a < b, a > b)
```
```output
true	true
```

`a > b` が `b < a` として同じメタメソッドを呼ぶので、両方 `true` になります。

### 呼び出し

```lua nilu
local mt = {}
mt.__call = function(self, x) return x * 2 end
local t = {}
setmetatable(t, mt)
print(t(21))
```
```output
42
```

第一引数には呼ばれたテーブル自身が入ります。`__call` にテーブルを入れることも
でき、鎖は 1999 段までたどられます（Lua は 15 段です。13.1）。

### 文字列にする

```lua nilu
local mt = {}
mt.__name = "Point"
local t = {}
setmetatable(t, mt)
print(string.sub(tostring(t), 1, 7))
```
```output
Point: 
```

`__tostring` があればそれが答え、無くて `__name` があれば `table` の代わりに
その名前が使われます。両方あれば `__tostring` が勝ちます。

**`__name` は失敗の文章にも出ます。** 中核の失敗が書く `attempt to … a table value` の
`table` が、`__name` を持つテーブルではその名前になります（Lua の `luaT_objtypename` と
同じで、文字列でない `__name` は無視されます）。

`__tostring` が文字列を返さなければ失敗します。

```lua nilu
local mt = {}
mt.__tostring = function() return 1 end
local t = {}
setmetatable(t, mt)
print(t)
```
```stderr
nilu: '__tostring' must return a string
```

文章は Lua と同じです。
数を返しても断るのは Lua と違うところです（[13.1](13-differences-from-lua.md#131-違うところ)）。
**`print` を通したときは位置が付きません** —— `nilu` コマンドの `print` がグローバルの
`tostring` を呼ぶからで、Lua の関数の中で `tostring(t)` を呼べば Lua と同じく位置が付きます。

### 走査

`__pairs` があれば `pairs` はそれに訊きます。`pairs` はテーブル自身のキーしか
見ないので、`__index` で値を作るテーブルを走査させたいときに使います。

```lua nilu
local mt = {}
mt.__pairs = function(self) return next, self, nil end
local t = {}
setmetatable(t, mt)
t[1] = "あ"
local n = 0
for k, v in pairs(t) do n = n + 1 end
print(n)
```
```output
1
```

## 7.5. できないこと

**メタメソッドには、呼べる値なら何でも置けます。** 関数か、`__call` をたどって関数に行き着く
テーブル・`userdata` です。そのときはその値が、オペランドより前の最初の引数になります（`t()` と同じです）。それ以外の値は呼び出しと同じように失敗し、変数は書かれていないので、文はメタメソッドの
名前を言います: `attempt to call a boolean value (metamethod 'add')`。これは Lua と同じです。

**メタメソッドは値を 1 つしか返せません。** 2 つ返しても 1 つめだけが使われます。
これは Lua と同じ形で、足りないところではありません。

`__gc` はありません。`__close` は `<close>` のローカル変数を閉じ（[3.1](03-variables.md#31-ローカル変数)）、`__mode` はテーブルを弱くします（[9.2](09-gc.md#92-何が生きているか)）。

`__metatable` はあります。`getmetatable` はその値を返し、`setmetatable` は
`cannot change a protected metatable` で断ります（Lua と同じ）。

---

次: [8. 失敗](08-failure.md)
