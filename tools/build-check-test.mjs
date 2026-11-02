import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runChecks } from './check-runner.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const zigArgument = args.indexOf('--zig');
if (zigArgument !== -1 && (!args[zigArgument + 1] || args[zigArgument + 1].startsWith('--'))) {
  console.error('build-check-test: --zig requires a compiler path');
  process.exit(1);
}
const zig = zigArgument === -1 ? 'zig' : args[zigArgument + 1];
const forwarded = args.filter((_, index) => index !== zigArgument && index !== zigArgument + 1);
const fixture = run => {
  const directory = mkdtempSync(join(tmpdir(), 'nilu-build-check-'));
  try {
    cpSync(join(root, 'build.zig'), join(directory, 'build.zig'));
    mkdirSync(join(directory, 'tools'));
    mkdirSync(join(directory, 'include'));
    cpSync(join(root, 'include/nilu.h'), join(directory, 'include/nilu.h'));
    mkdirSync(join(directory, 'test/c_api'), { recursive: true });
    // Synthetic roots have no C API exports; retain the build input without host callbacks.
    writeFileSync(join(directory, 'test/c_api/callbacks.c'), '/* synthetic build fixture */\n');
    for (const name of ['run-zig-tests.mjs', 'list-tests.mjs', 'reference-content.mjs']) {
      cpSync(join(root, 'tools', name), join(directory, 'tools', name));
    }
    cpSync(join(root, 'test/fixtures'), join(directory, 'test/fixtures'), { recursive: true });
    // The source tests embed the manual's chapters.
    mkdirSync(join(directory, 'doc'), { recursive: true });
    cpSync(join(root, 'doc/en'), join(directory, 'doc/en'), { recursive: true });
    const writeSource = text => {
      mkdirSync(join(directory, 'src'), { recursive: true });
      writeFileSync(join(directory, 'src/root.zig'), text);
    };
    const build = (...steps) => {
      // The project's global cache is the caller's, which the outer build has
      // already filled with the standard library: a cache of its own started
      // empty on every fresh machine, and a CI runner compiled it all again in
      // each case. The cache is content-addressed, so sharing it changes no
      // result. The timeout only stops a hang; a slow runner needs minutes.
      const result = spawnSync(zig, ['build', ...steps, '--summary', 'all'], {
        cwd: directory,
        encoding: 'utf8',
        timeout: 600000,
        maxBuffer: 4 * 1024 * 1024,
      });
      if (result.error) throw result.error;
      return { status: result.status, output: result.stdout + result.stderr };
    };
    return run({ directory, writeSource, build });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
};
const failed = (result, message) => {
  assert.notEqual(result.status, 0, result.output);
  assert.match(result.output, message);
};

const cases = [
  {
    name: 'inventory-does-not-compile',
    run: () => fixture(({ directory, writeSource }) => {
      writeSource('const text = "test \\"not a test\\" {}";\n// test "comment" {}\n\\\\ test "multiline string" {}\ntest "first" {}\ntest {}\n');
      mkdirSync(join(directory, 'test/c'), { recursive: true });
      writeFileSync(join(directory, 'test/c/example.c'), 'const char *text = "/* literal */";\n/* {"comment", case_fake} */\nstruct entry cases[] = {{"real", case_real}};\n');
      const result = spawnSync(process.execPath, ['tools/list-tests.mjs', '--count'], { cwd: directory, encoding: 'utf8' });
      if (result.error) throw result.error;
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.match(result.stdout, /^list-tests: 2 Zig and 1 C case declarations, none run/);
      return 'invalid fixture source can be inventoried without compiling or reading names out of comments';
    }),
  },
  {
    name: 'entry-points-are-discoverable',
    run: () => fixture(({ build }) => {
      const result = build('--help');
      assert.equal(result.status, 0, result.output);
      for (const name of ['stage-check', 'tool-test', 'docs-check', 'fmt-check', 'test', 'naming-check', 'naming-check-test', 'c-test', 'cli-test', 'manual-check', 'manual-check-test', 'example', 'check', 'dist']) {
        assert.match(result.output, new RegExp(`\\b${name}\\b`));
      }
      return 'Zig lists current and pending entry points';
    }),
  },
  {
    name: 'distribution-without-a-version-is-unverified',
    run: () => fixture(({ directory, build }) => {
      writeFileSync(join(directory, 'include/nilu.h'), '/* a header without a version */\n');
      failed(build('dist'), /NOT-VERIFIED: include\/nilu.h does not define NILU_VERSION; no release can be named/);
      return 'a release cannot be named without the header version';
    }),
  },
  {
    name: 'native-tests-and-filter',
    run: () => fixture(({ writeSource, build }) => {
      writeSource('const std = @import("std");\ntest "alpha" { try std.testing.expect(true); }\ntest "beta" { try std.testing.expectEqual(@as(u8, 2), 1 + 1); }\n');
      const all = build('test');
      assert.equal(all.status, 0, all.output);
      assert.match(all.output, /zig-tests: 2 of 2 compiled tests passed/);
      const selected = build('test', '-Dtest-filter=beta');
      assert.equal(selected.status, 0, selected.output);
      assert.match(selected.output, /filter="beta"/);
      assert.match(selected.output, /zig-tests: 1 of 1 compiled tests passed/);
      failed(build('test', '-Dtest-filter=absent'), /NOT-VERIFIED: 0 Zig tests passed/);
      failed(build('test', '--', '--only=alpha'), /use -Dtest-filter=<substring>/);
      return 'the actual Zig compiler runs all tests, a subset, and rejects an empty filter result';
    }),
  },
  {
    name: 'zero-tests-are-not-a-pass',
    run: () => fixture(({ writeSource, build }) => {
      writeSource('pub const value: u8 = 1;\n');
      failed(build('test'), /NOT-VERIFIED: 0 Zig tests passed/);
      return 'a compilable module with no tests fails';
    }),
  },
  {
    name: 'skipped-tests-are-unverified',
    run: () => fixture(({ writeSource, build }) => {
      writeSource('test "runs" {}\ntest "skipped" { return error.SkipZigTest; }\n');
      failed(build('test'), /NOT-VERIFIED: 1 Zig tests passed and 1 were skipped/);
      return 'a partially skipped run cannot pass';
    }),
  },
  {
    name: 'failed-assertions-propagate',
    run: () => fixture(({ writeSource, build }) => {
      writeSource('const std = @import("std");\ntest "fails" { try std.testing.expect(false); }\n');
      failed(build('test'), /TestUnexpectedResult/);
      return 'a real Zig assertion fails the build';
    }),
  },
  {
    name: 'allocation-leaks-propagate',
    run: () => fixture(({ writeSource, build }) => {
      writeSource('const std = @import("std");\ntest "leaks" { _ = try std.testing.allocator.alloc(u8, 1); }\n');
      failed(build('test'), /leaked memory/);
      return 'the standard Zig runner retains testing-allocator leak checks';
    }),
  },
];

runChecks('build-check-test', cases, zigArgument === -1 ? args : forwarded);
