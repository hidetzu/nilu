import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkDirectory, checkFile, checkTree } from './zig-naming.mjs';
import { runChecks } from './check-runner.mjs';

const clean = (path, source) => { assert.deepEqual(checkFile(path, source), []); };
const fails = (path, source, pattern) => {
  const problems = checkFile(path, source);
  assert.ok(problems.some(problem => pattern.test(problem)), `expected ${pattern}, got ${JSON.stringify(problems)}`);
};

runChecks('zig-naming-test', [
  { name: 'type-file-needs-title-case', run: () => {
    const type = 'const Lexer = @This();\nsource: []const u8,\ncursor: usize = 0,\npub fn next(self: *Lexer) void { _ = self; }\n';
    clean('src/Lexer.zig', type);
    fails('src/lexer.zig', type, /lexer\.zig has top-level instance fields, so it is a type and its name is TitleCase\.zig/);
    return 'top-level instance fields make the file a TitleCase type';
  } },
  { name: 'namespace-file-needs-snake-case', run: () => {
    const namespace = 'pub const State = struct {\n    stack: []u8,\n};\npub fn run() void {}\n';
    clean('src/runtime.zig', namespace);
    fails('src/State.zig', namespace, /State\.zig has no top-level instance fields, so it is a namespace and its name is snake_case\.zig/);
    return 'a nested struct does not make its namespace file a type';
  } },
  { name: 'comments-and-strings-are-not-fields', run: () => {
    clean('src/text.zig', '// stack: []u8,\nconst s = "cursor: usize,";\nconst m =\n    \\\\field: u8,\n;\n');
    return 'only code declares fields';
  } },
  { name: 'import-alias-follows-file', run: () => {
    clean('src/a.zig', 'const Token = @import("Token.zig");\nconst parser = @import("parser.zig");\nconst std = @import("std");\nconst limits = @import("syntax_depth.zig");\n');
    fails('src/a.zig', 'const token = @import("Token.zig");\n', /import alias of Token\.zig token is not TitleCase/);
    fails('src/a.zig', 'const Parser = @import("parser.zig");\n', /import alias of parser\.zig Parser is not snake_case/);
    return 'a type file imports as TitleCase, a namespace as snake_case';
  } },
  { name: 'this-alias-is-title-case', run: () => {
    fails('src/Lexer.zig', 'const self_type = @This();\nx: u8,\n', /@This\(\) alias self_type is not TitleCase/);
    return 'the local @This() alias names a type';
  } },
  { name: 'fields-and-enum-tags-are-snake-case', run: () => {
    fails('src/Token.zig', 'lineNumber: u32,\n', /field lineNumber is not snake_case/);
    fails('src/a.zig', 'pub const Kind = enum(u8) { plain, BadTag, last = 3 };\n', /enum field BadTag is not snake_case/);
    fails('src/a.zig', 'pub const Node = union(enum) { leafNode: u8, empty };\n', /field leafNode is not snake_case/);
    clean('src/a.zig', 'pub const Error = error{ OutOfMemory, TooManyUpvalues };\nfn f() error{ OutOfMemory }!void {}\n');
    return 'container fields and enum tags are snake_case; error names are not fields';
  } },
  { name: 'functions-are-camel-case', run: () => {
    fails('src/a.zig', 'fn push_value() void {}\n', /function push_value is not camelCase/);
    fails('src/a.zig', 'fn Push() void {}\n', /function Push is not camelCase/);
    fails('src/a.zig', 'fn pointerType(comptime T: type) type { return T; }\n', /type function pointerType is not TitleCase/);
    clean('src/a.zig', 'fn PointerType(comptime T: type) type { return T; }\npub fn newCClosure(state: *u8) error{ OutOfMemory }!u8 { _ = state; return 0; }\n');
    return 'a function returning type is TitleCase, others camelCase';
  } },
  { name: 'parameters-and-locals', run: () => {
    fails('src/a.zig', 'fn f(stackTop: u8) void { _ = stackTop; }\n', /parameter stackTop is not snake_case or TitleCase/);
    fails('src/a.zig', 'fn f() void { const resultCount = 1; _ = resultCount; }\n', /constant or variable resultCount/);
    clean('src/a.zig', 'fn f(_: u8, comptime T: type, noalias out: *T, callback: *const fn (state: u8) void) void { _ = out; _ = callback; }\n');
    return 'values are snake_case, type parameters TitleCase, discards allowed';
  } },
  { name: 'discard-and-nonexhaustive-enum', run: () => {
    clean('src/a.zig', 'const _ = 1;\nconst Tag = enum(u8) { first, _ };\n');
    fails('src/a.zig', 'const _badName = 1;\n', /constant or variable _badName/);
    fails('src/a.zig', 'const Tag = enum(u8) { BadTag, _ };\n', /enum field BadTag/);
    return 'only the exact underscore is exempt, without hiding named violations';
  } },
  { name: 'reexport-keeps-its-name', run: () => {
    clean('src/Lexer.zig', 'x: u8,\npub const isSpace = numeral.isSpace;\npub const Value = runtime.Value;\n');
    fails('src/a.zig', 'pub const isBlank = numeral.isSpace;\n', /constant or variable isBlank/);
    return 'only a same-name re-export may keep a camelCase name';
  } },
  { name: 'acronyms-are-words', run: () => {
    fails('src/a.zig', 'pub const ASTNode = struct {};\n', /ASTNode spells an acronym in capitals/);
    fails('src/a.zig', 'fn runVM() void {}\n', /runVM spells an acronym in capitals/);
    fails('src/AST.zig', 'x: u8,\n', /AST\.zig spells an acronym in capitals/);
    clean('src/a.zig', 'pub const CClosure = struct {};\npub const Ast = struct {};\n');
    return 'Ast, not AST; CClosure is C plus Closure';
  } },
  { name: 'c-abi-keeps-its-spelling', run: () => {
    clean('src/c_api.zig', 'pub export fn nilu_push_value(state: *u8) callconv(.c) void { _ = state; }\nextern fn test_counter_callback(state: *u8) c_int;\npub const NILU_OK = 0;\nextern var some_c_global: c_int;\n');
    return 'exports, externs and nilu_ names follow the C contract';
  } },
  { name: 'directories-and-trees', run: () => {
    assert.deepEqual(checkDirectory('src/c_api'), []);
    assert.match(checkDirectory('src/CApi')[0], /directory CApi is not snake_case/);
    const root = mkdtempSync(join(tmpdir(), 'zig-naming-'));
    try {
      assert.throws(() => checkTree(root), /no Zig files found/);
      mkdirSync(join(root, 'src', 'Parts'), { recursive: true });
      writeFileSync(join(root, 'src', 'Parts', 'thing.zig'), 'pub fn f() void {}\n');
      writeFileSync(join(root, 'src', 'lexer.zig'), 'x: u8,\n');
      mkdirSync(join(root, '.zig-cache'));
      writeFileSync(join(root, '.zig-cache', 'Bad_name.zig'), '');
      assert.throws(() => checkTree(root), error => /2 naming problems/.test(error.message)
        && /src\/Parts: directory Parts/.test(error.message) && /lexer\.zig has top-level instance fields/.test(error.message));
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
    return 'a tree reports every problem and skips build caches; an empty tree fails';
  } },
]);
