[← Contents](README.md)

# 15. Grammar

The whole of the syntax as it stands. `{A}` means zero or more, and `[A]` means optional.

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

What is written here is what cannot be read off the grammar's text alone.

- **`t:m(…)` is not `t.m(t, …)`** — the receiver is evaluated **once**.
  `function t:m(a)` declares `self` as an implicit first parameter (`self` is not a reserved word).
- **`...name` names the table of extra arguments**: `Name` is a read-only local holding them and their
  count in `n`, and `...` still reads that table ([6.3](06-functions.md#63-undeclared-arguments--)).
- **Only a name and `( exp )` can be followed by a call or an index**. `{1, 2}[1]` and `"ab":len()` are
  refused, as the grammar says.
- The `attrib` before the names of a `local` is the default for every name listed. The only attribute accepted is `const`;
  `<close>` is refused with `attribute 'close' is not supported`. In a `global`'s attribute, `<close>` is
  refused with `global variables cannot be to-be-closed`.
- The **two `fieldsep`s are interchangeable**, and **one may be left at the end**.
  `Name '=' exp` is another spelling of `'[' String ']' '=' exp` (just as `t.k` is `t["k"]`).

**Syntax depth is limited to 200.** A literal, name or vararg has depth 0.
Parentheses, unary and binary operators, field/index/call suffixes, table
constructors, functions and control constructs each add 1 to the maximum depth
of their children. A method-call suffix counts as one call. Root/body blocks,
return/declaration/assignment containers and lists add no level; sibling
expressions, fields, statements and elseif arms use their maximum, not their
sum. A control construct and its body block therefore count once.

For example, 200 parentheses around a literal are accepted, and 201 are refused.
An operator or suffix chain also fits at 200 links and fails at its 201st link.
Mixed nesting shares that same budget; 100 nested do blocks around 100
parentheses fit. The first operator or opening token that exceeds the budget
is reported with `chunk has too many syntax levels (limit is 200)` and a line
and byte column. Function-call depth and runtime stack capacity are separate
limits.

A source is at most 4294967294 bytes. A longer one is refused before any of it
is read, with `chunk is too large (limit is 4294967294 bytes)` at line 1,
column 1: offsets, lines and columns are 32-bit, which keeps the syntax tree
small.

## 15.1. Reserved words

```text
and      break    do       else     elseif   end      false
for      function goto     if       in       local    nil
not      or       repeat   return   then     true     until
while
```

22 words. **This list is confirmed in full by the repository's checks** —
`every word of the grammar is reserved, and global is not` sees that, for each word, both
`local <word> = 1` and `t.<word> = 1` are syntax errors.
A list alone does not fail, so a list alone is not enough.

```lua nilu-refused
local and = 1
```

```lua nilu-refused
local t = {}
t.end = 1
```

A reserved word cannot be a field name either. `t.end` cannot be written, but `t["end"]` can.

```lua nilu
local t = {}
t["end"] = "書ける"
print(t["end"])
```
```output
書ける
```

`do` is in `while`, in `for`, and in its own `do … end` statement.

**`global` is not a reserved word.** Its absence from the list above is that claim, and
the same check sees it. It can be used as a variable name.

## 15.2. Lexical conventions

| | |
|---|---|
| Names | `[A-Za-z_][A-Za-z0-9_]*`. **ASCII only** |
| Numbers | `3`, `3.5`, `.5`, `3.`, `1e9`, `1E-2`, `0x10`, `0x1p4` |
| Strings | `"…"`, `'…'`, or `[[…]]` (`[==[…]==]` too). The escapes are the same as Lua's ([2. Values](02-values.md#escapes)) |
| Comments | From `--` to the end of the line. `--[[ … ]]` spans lines |
| Whitespace | Space, tab, newline, form feed, vertical tab. It means nothing |

`_` cannot be written inside a number.

```lua nilu-refused
return 1_0
```

From `--[[` to `]]` is a comment. **What follows the `]]` on the same line is ordinary code.**

```lua nilu
--[[ これは
コメントです ]] print("ここは動きます")
```
```output
ここは動きます
```

## 15.3. Precedence

From the weakest to the strongest.

| Operators | Associativity |
|---|---|
| `or` | left |
| `and` | left |
| `<` `>` `<=` `>=` `~=` `==` | left |
| `\|` | left |
| `~` | left |
| `&` | left |
| `<<` `>>` | left |
| `..` | **right** |
| `+` `-` | left |
| `*` `/` `//` `%` | left |
| `not` `#` `-` `~` (unary) | — |
| `^` | **right** |

Only the surprising ones are actually run to confirm.

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

`^` is right-associative and binds tighter than unary minus. So `2 ^ 3 ^ 2` is `2 ^ (3 ^ 2)`, and
`-2 ^ 2` is `-(2 ^ 2)`.

`..` is right-associative too. With strings the result is the same either way, so telling it apart would need a combination of different lengths.

```lua nilu
print("a" .. "b" .. "c")
print(#("a" .. "b" .. "c"))
```
```output
abc
3
```

`not`, `#` and unary `-` bind tighter than every binary operator except `^` (tighter than a comparison).

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

The first line is `false` because it is read as `(not 1) == 2`. `not 1` is `false`, and
`false == 2` is `false`. **This is a place where parentheses are the better choice.**

Comparisons cannot be chained.

```lua nilu
return 1 < 2 < 3
```
```stderr
nilu: <manual>:1: attempt to compare boolean with number
```

**As syntax, it passes.** `1 < 2` is a boolean, and `true < 3` is a type error, so
it fails when run.

## 15.4. What cannot be written

Everywhere this manual says "a syntax error", it was
actually run and confirmed. The representative ones are listed here.

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

## 15.5. What happens when the grammar grows

The grammar in this manual is **only what is implemented now**.
When what [13.2](13-differences-from-lua.md#132-what-is-not-there-yet) lists arrives,
this grows too. The difference from Lua's grammar is, as it stands, the list of the remaining work.

---

[← Contents](README.md)
