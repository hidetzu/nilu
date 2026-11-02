import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const [binary, source, include, library] = process.argv.slice(2);
assert.ok(binary, 'pass the compiled C host');
const validate = (binary, label) => {
  const run = args => {
    const result = spawnSync(binary, args, { encoding: 'utf8', timeout: 30000 });
    if (result.error) throw result.error;
    return result;
  };
  const success = run([]);
  assert.equal(success.status, 0, success.stdout + success.stderr);
  process.stdout.write(success.stdout);
  const abortCases = [
    ['bad-hook-pop', 'nilu_settop'],
    ['pcallk-ignores-yield', 'nilu_pcallk has answered NILU_YIELD'], ['yield-not-returned', 'nilu_yield: a C function must return'],
    ['null-next', 'nilu_next'], ['null-setmetatable', 'nilu_setmetatable'], ['null-calledas', 'nilu_calledas'],
    ...['index', 'min', 'empty'].map(kind => [`remaining-next-${kind}`, 'nilu_next']),
    ...['index', 'min', 'empty'].map(kind => [`remaining-metatable-${kind}`, 'nilu_setmetatable']),
    ...['gettable', 'settable', 'getglobal', 'setglobal'].map(api => [`null-${api}`, `nilu_${api}`]),
    ...[['gettable-index', 'gettable'], ['settable-index', 'settable'], ['settable-pair', 'settable'], ['getglobal-name', 'getglobal'], ['setglobal-name', 'setglobal'], ['setglobal-value', 'setglobal']].map(([kind, api]) => [`access-${kind}`, `nilu_${api}`]),
    ['null-len', 'nilu_len'], ['null-compare', 'nilu_compare'],
    ['operator-len-index', 'nilu_len'],
    ...['first', 'second', 'code', 'min'].map(kind => [`operator-compare-${kind}`, 'nilu_compare']),
    ['null-call', 'nilu_call'], ['null-pcall', 'nilu_pcall'],
    ...['call', 'pcall'].flatMap(api => ['negative-args', 'min-args', 'missing-args', 'negative-results', 'min-results', 'bad-negative', 'bad-count'].map(kind => [`${api}-${kind}`, `nilu_${api}`])),
    ...['absent', 'min', 'type', 'callee', 'negative'].map(kind => [`pcall-handler-${kind}`, 'nilu_pcall']),
    ['null-loadstring', 'nilu_loadstring'], ['null-loadnamed', 'nilu_loadnamed'],
    ['bad-loadstring-source', 'nilu_loadstring'], ['bad-loadnamed-source', 'nilu_loadnamed'],
    ['bad-loadnamed-name', 'nilu_loadnamed'],
    ['null-where', 'nilu_where'], ['null-namewhat', 'nilu_namewhat'], ['null-type', 'nilu_type'], ['null-rawget', 'nilu_rawget'], ['null-rawset', 'nilu_rawset'],
    ['bad-rawget-index', 'nilu_rawget'], ['bad-rawset-index', 'nilu_rawset'], ['bad-rawset-pair', 'nilu_rawset'],
    ['null-gettop', 'nilu_gettop'], ['null-settop', 'nilu_settop'],
    ['null-pushnil', 'nilu_pushnil'], ['null-pushnumber', 'nilu_pushnumber'],
    ['null-tonumberx', 'nilu_tonumberx'], ['below-bottom', 'nilu_settop'],
    ['null-pushstring', 'nilu_pushstring'], ['null-pushlstring', 'nilu_pushlstring'],
    ['null-tolstring', 'nilu_tolstring'], ['null-bytes', 'nilu_pushlstring'],
    ['null-pushboolean', 'nilu_pushboolean'], ['null-toboolean', 'nilu_toboolean'],
    ['null-pushvalue', 'nilu_pushvalue'], ['null-copy', 'nilu_copy'], ['null-rotate', 'nilu_rotate'],
    ['bad-pushvalue', 'nilu_pushvalue'], ['bad-copy-from', 'nilu_copy'], ['bad-copy-to', 'nilu_copy'],
    ['bad-rotate-index', 'nilu_rotate'], ['bad-rotate-count', 'nilu_rotate: count exceeds'],
    ['bad-rotate-min', 'nilu_rotate: count exceeds'],
    ['null-newtable', 'nilu_newtable'], ['null-newuserdata', 'nilu_newuserdata'],
    ['null-touserdata', 'nilu_touserdata'], ['null-rawlen', 'nilu_rawlen'],
    ['null-rawequal', 'nilu_rawequal'], ['null-stringtonumber', 'nilu_stringtonumber'],
    ['null-numeral', 'nilu_stringtonumber: bytes is NULL'],
    ['null-error', 'nilu_error'], ['empty-error', 'nilu_error'],
    ['null-sethook', 'nilu_sethook'], ['null-topointer', 'nilu_topointer'], ['null-getmetatable', 'nilu_getmetatable'],
    ['null-pushcfunction', 'nilu_pushcfunction'], ['null-pushcclosure', 'nilu_pushcclosure'],
    ['null-getupvalue', 'nilu_getupvalue'], ['null-setupvalue', 'nilu_setupvalue'],
    ['bad-cfunction-null', 'nilu_pushcfunction'], ['bad-cclosure-null', 'nilu_pushcclosure'],
    ['bad-cclosure-negative', 'nilu_pushcclosure'], ['bad-cclosure-max', 'nilu_pushcclosure'],
    ['bad-cclosure-count', 'nilu_pushcclosure'],
  ];
  for (const [name, functionName] of abortCases) {
    const result = run([name]);
    assert.equal(result.signal, 'SIGABRT', `${name}: ${result.status}: ${result.stderr}`);
    assert.ok(result.stderr.includes(functionName), `${name}: ${result.stderr}`);
  }
  console.log(`${label}: ${abortCases.length} host-precondition aborts checked; complete C suite remains pending`);
};
validate(binary, 'zig cc host');
if (source) {
  const version = spawnSync('cc', ['--version'], { encoding: 'utf8', timeout: 30000 });
  if (version.error?.code === 'ENOENT') {
    console.log('native cc host: NOT-RUN, cc is unavailable');
  } else {
    if (version.error) throw version.error;
    assert.equal(version.status, 0, version.stderr);
    const directory = mkdtempSync(join(tmpdir(), 'nilu-c-stack-'));
    try {
      const host = join(directory, 'host');
      const compile = spawnSync('cc', ['-std=c99', '-Wall', '-Wextra', '-Werror', '-I', include, source, library, '-lm', '-o', host], { encoding: 'utf8', timeout: 30000 });
      if (compile.error) throw compile.error;
      assert.equal(compile.status, 0, compile.stdout + compile.stderr);
      validate(host, 'native cc host');
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  }
}
