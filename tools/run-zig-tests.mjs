import { spawnSync } from 'node:child_process';
import { writeSync } from 'node:fs';

const [executable, filter = ''] = process.argv.slice(2);
console.log(`zig-tests: running compiled native tests (${filter ? `filter=${JSON.stringify(filter)}` : 'all tests'})`);
if (!executable || process.argv.length > 4) {
  console.error('zig-tests: use -Dtest-filter=<substring>; list declarations with node tools/list-tests.mjs');
  process.exit(1);
}
const result = spawnSync(executable, [], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
// Written synchronously and to the end: into a pipe, process.stdout.write is
// asynchronous and process.exit below drops what is still queued, and one
// writeSync may write only part, so a failing run's report past the pipe's
// buffer would never reach the reader.
function writeAll(descriptor, text) {
  const bytes = Buffer.from(text);
  for (let offset = 0; offset < bytes.length;) {
    try {
      offset += writeSync(descriptor, bytes, offset);
    } catch (error) {
      if (error.code !== 'EAGAIN') throw error;
    }
  }
}
if (result.stdout) writeAll(1, result.stdout);
if (result.stderr) writeAll(2, result.stderr);
if (result.error) {
  console.error(`NOT-VERIFIED: Zig tests could not run: ${result.error.message}`);
  process.exit(1);
}
// A process a signal ended has no status; say which signal, since a crash
// that cannot print its own panic (a stack overflow) leaves nothing else.
if (result.signal) {
  console.error(`zig-tests: the test process was ended by ${result.signal}`);
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
const summaries = [...result.stderr.matchAll(/^(?:All (\d+) tests passed\.|(\d+) passed; (\d+) skipped; (\d+) failed\.)$/gm)];
const summary = summaries.at(-1);
if (!summary) {
  console.error('NOT-VERIFIED: no Zig test summary was obtained');
  process.exit(1);
}
const passed = Number(summary[1] ?? summary[2]);
const skipped = Number(summary[3] ?? 0);
if (!passed || skipped) {
  console.error(`NOT-VERIFIED: ${passed} Zig tests passed and ${skipped} were skipped; require a nonempty run with no skips`);
  process.exit(1);
}
console.log(`zig-tests: ${passed} of ${passed} compiled tests passed`);
