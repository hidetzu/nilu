// Compiles each C host given with --source against the installed header and
// library with a plain C compiler, as a consumer would, and runs it: the checks
// that walk the consumer's path. A host with a <name>.out beside it must print
// exactly that; one without must end by printing "done".
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
const option = name => {
  const index = args.indexOf(name);
  assert.ok(index !== -1 && args[index + 1] && !args[index + 1].startsWith('--'), `${name} needs a value`);
  return args[index + 1];
};
const zig = option('--zig');
const include = option('--include');
const library = option('--library');
const sources = args.flatMap((arg, index) => arg === '--source' ? [args[index + 1]] : []);
assert.ok(sources.length && sources.every(Boolean), '--source needs a value');
for (const path of [join(include, 'nilu.h'), library, ...sources]) assert.ok(existsSync(path), `missing: ${path}`);
console.log(`example: running ${sources.length} C hosts against the installed header and library`);
const directory = mkdtempSync(join(tmpdir(), 'nilu-example-'));
try {
  for (const [index, source] of sources.entries()) {
    const executable = join(directory, `example-${index}`);
    const compile = spawnSync(zig, ['cc', '-std=c99', '-Wall', '-Wextra', '-Werror', '-I', include, source, library, '-lm', '-o', executable], { encoding: 'utf8', timeout: 300000 });
    if (compile.error) throw compile.error;
    assert.equal(compile.status, 0, compile.stdout + compile.stderr);
    const run = spawnSync(executable, [], { encoding: 'utf8', timeout: 60000 });
    if (run.error) throw run.error;
    if (run.stderr) process.stderr.write(run.stderr);
    assert.equal(run.status, 0, `${source} did not exit 0`);
    const expected = source.replace(/\.c$/, '.out');
    if (existsSync(expected)) {
      assert.equal(run.stdout, readFileSync(expected, 'utf8'), `${source} printed other than ${expected}`);
      console.log(`  ok ${source}: printed ${expected}`);
    } else {
      assert.match(run.stdout, /\ndone\n$/, `${source} did not reach its last line`);
      console.log(`  ok ${source}: ran to "done"`);
    }
  }
  console.log(`example: ${sources.length} of ${sources.length} C hosts passed`);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
