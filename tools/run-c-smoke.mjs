// Runs the whole carried C smoke suite (test/c/smoke.c) against the library:
// first the host the build compiled with zig cc, then one compiled by the
// native cc when there is one. The suite announces its own count and selects
// with --only=<name>; --list names the cases without running any.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [binary, source, include, library, ...rest] = process.argv.slice(2);
assert.ok(binary && source && include && library, 'pass the compiled host, test/c/smoke.c, the include directory and the library archive');
const forwarded = rest.filter(argument => argument === '--list' || argument.startsWith('--only='));
if (forwarded.length !== rest.length) {
  console.error('run-c-smoke: use --list or --only=<case name>');
  process.exit(1);
}
const run = (command, args) => {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 300000, maxBuffer: 16 * 1024 * 1024 });
  if (result.error) throw result.error;
  return result;
};
const validate = (host, label) => {
  const result = run(host, forwarded);
  process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  assert.equal(result.status, 0, `${label}: the suite did not pass`);
  if (forwarded.includes('--list')) return;
  const announced = /c-smoke: running (\d+) of (\d+) cases/.exec(result.stdout);
  assert.ok(announced, `${label}: the suite did not announce its count`);
  assert.match(result.stdout, new RegExp(`c-smoke: ${announced[1]} of ${announced[1]} cases passed`), `${label}: not every announced case passed`);
  console.log(`c-test ${label}: ${announced[1]} of ${announced[2]} carried smoke cases passed`);
};
validate(binary, 'zig cc host');
if (forwarded.includes('--list')) process.exit(0);
const version = spawnSync('cc', ['--version'], { encoding: 'utf8', timeout: 30000 });
if (version.error?.code === 'ENOENT') {
  console.log('c-test native cc host: NOT-RUN, cc is unavailable');
} else {
  if (version.error) throw version.error;
  assert.equal(version.status, 0, version.stderr);
  const directory = mkdtempSync(join(tmpdir(), 'nilu-c-smoke-'));
  try {
    const host = join(directory, 'host');
    const compile = run('cc', ['-std=c99', '-Wall', '-Wextra', '-Werror', '-I', include, source, library, '-lm', '-o', host]);
    assert.equal(compile.status, 0, compile.stdout + compile.stderr);
    validate(host, 'native cc host');
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
