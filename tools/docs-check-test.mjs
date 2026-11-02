import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { markdownShape, sha256 } from './reference-content.mjs';
import { runChecks } from './check-runner.mjs';

const tool = join(dirname(fileURLToPath(import.meta.url)), 'docs-check.mjs');
const invoke = (root, args = []) => {
  const result = spawnSync(process.execPath, [tool, `--root=${root}`, ...args], { encoding: 'utf8' });
  if (result.error) throw result.error;
  return { status: result.status, output: result.stdout + result.stderr };
};
const fixture = run => {
  const root = mkdtempSync(join(tmpdir(), 'nilu-docs-check-'));
  const write = (name, contents) => {
    const destination = join(root, name);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, contents);
  };
  const digest = createHash('sha256').update('reference\n').digest('hex');
  const hash = text => createHash('sha256').update(text).digest('hex');
  const manual = '# Example\n\n```nilu\nprint(1)\n```\n```output\n1.0\n```\n';
  const expectedManual = {
    blocks: hash(JSON.stringify([{ tag: 'nilu', body: 'print(1)' }, { tag: 'output', body: '1.0' }])),
    headings: hash(JSON.stringify([1])),
  };
  const manifest = {
    verbatim: { LICENSE: digest },
    manuals: { 'doc/ja/example.md': expectedManual, 'doc/en/example.md': expectedManual },
    cTests: { 'test/c/example.c': hash('int value = 1;  \nconst char *text = "/* literal */";\n') },
  };
  const saveManifest = () => write('tools/references.json', JSON.stringify(manifest));
  try {
    mkdirSync(join(root, 'design/adr'), { recursive: true });
    write('README.md', '[Design](design/README.md#current-shape)\n');
    write('design/README.md', '# Current shape\n');
    write('LICENSE', 'reference\n');
    write('doc/ja/example.md', manual);
    write('doc/en/example.md', manual);
    write('test/c/example.c', 'int value = 1; /* original */\nconst char *text = "/* literal */";\n');
    write('include/nilu.h', '#define NILU_VERSION "0.1.0-dev.1"\n');
    for (const language of ['en', 'ja']) {
      const front = language === 'en' ? 'This manual describes **Nilu 0.1.0-dev.1**.' : 'このマニュアルは **Nilu 0.1.0-dev.1** を説明します。';
      const text = '# Manual\n\n' + front + '\n';
      const name = `doc/${language}/README.md`;
      write(name, text);
      const shape = markdownShape(text);
      manifest.manuals[name] = { blocks: sha256(JSON.stringify(shape.blocks)), headings: sha256(JSON.stringify(shape.headings)) };
    }
    saveManifest();
    return run({ root, write, manifest, saveManifest });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};
const expectFailure = (root, expected) => {
  const result = invoke(root);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, expected);
};

const cases = [
  {
    name: 'manual-version-mismatches',
    run: () => fixture(({ root, write }) => {
      const check = expected => {
        const result = invoke(root, ['--only=manual-version']);
        assert.equal(result.status, 1, result.output);
        assert.match(result.output, expected);
      };
      write('doc/en/README.md', 'This manual describes **Nilu 9.9.9**.\n');
      check(/manual version must equal NILU_VERSION/);
      write('doc/en/README.md', 'This manual describes **Nilu 0.1.0-dev.1**.\n');
      write('doc/ja/README.md', 'このマニュアルは **Nilu 9.9.9** を説明します。\n');
      check(/manual version must equal NILU_VERSION/);
      write('doc/ja/README.md', 'このマニュアルは **Nilu 0.1.0-dev.1** を説明します。\n');
      for (const language of ['en', 'ja']) {
        write(`doc/${language}/example.md`, '```output\nnilu 9.9.9\n```\n');
        check(/banner 9.9.9 must equal NILU_VERSION/);
        write(`doc/${language}/example.md`, '```output\nnilu 0.1.0-dev.1\n```\n');
      }
      assert.equal(invoke(root, ['--only=manual-version']).status, 0);
      write('include/nilu.h', '/* #define NILU_VERSION "0.1.0-dev.1" */\n');
      check(/expected one NILU_VERSION string/);
      return 'both front pages and output banners must name the real header version';
    }),
  },
  {
    name: 'manual-inventory-cannot-shrink-together',
    run: () => fixture(({ root }) => {
      rmSync(join(root, 'doc/ja/example.md'));
      rmSync(join(root, 'doc/en/example.md'));
      expectFailure(root, /manual files differ from the carried inventory/);
      return 'deleting a chapter from both languages does not hide its examples';
    }),
  },
  {
    name: 'c-case-inventory-cannot-shrink',
    run: () => fixture(({ root }) => {
      rmSync(join(root, 'test/c/example.c'));
      expectFailure(root, /C cases differ from the carried inventory/);
      return 'removing a C test file fails';
    }),
  },
  {
    name: 'manual-expectations-cannot-drift-together',
    run: () => fixture(({ root, write }) => {
      const changed = '# Example\n\n```nilu\nprint(1)\n```\n```output\n2.0\n```\n';
      write('doc/ja/example.md', changed);
      write('doc/en/example.md', changed);
      expectFailure(root, /examples differ from the carried manual/);
      return 'matching translations cannot silently replace an expected result';
    }),
  },
  {
    name: 'manual-translation-drift',
    run: () => fixture(({ root, write }) => {
      write('doc/en/example.md', '# Example\n\n```nilu\nprint(2)\n```\n');
      expectFailure(root, /manuals differ in blocks or heading levels/);
      return 'the two manuals must retain the same examples and heading structure';
    }),
  },
  {
    name: 'c-comments-may-change',
    run: () => fixture(({ root, write }) => {
      write('test/c/example.c', 'int value = 1; /* revised\n * explanation */\nconst char *text = "/* literal */";\n');
      const result = invoke(root);
      assert.equal(result.status, 0, result.output);
      return 'comment cleanup leaves executable C and literal comment markers intact';
    }),
  },
  {
    name: 'c-assertions-must-not-change',
    run: () => fixture(({ root, write }) => {
      write('test/c/example.c', 'int value = 2; /* original */\nconst char *text = "/* literal */";\n');
      expectFailure(root, /C content outside comments differs/);
      return 'changing C outside a comment fails';
    }),
  },
  {
    name: 'c-literal-comment-markers-are-code',
    run: () => fixture(({ root, write }) => {
      write('test/c/example.c', 'int value = 1; /* original */\nconst char *text = "/* changed literal */";\n');
      expectFailure(root, /C content outside comments differs/);
      return 'a comment-shaped string is part of the C contract';
    }),
  },
  {
    name: 'valid-documents',
    run: () => fixture(({ root }) => {
      const result = invoke(root);
      assert.equal(result.status, 0, result.output);
      assert.match(result.output, /^docs-check: running 6 of 6 cases/);
      return 'the real command checks links, design and reference bytes';
    }),
  },
  {
    name: 'broken-link',
    run: () => fixture(({ root, write }) => {
      write('README.md', '[missing](doc/missing.md)\n');
      expectFailure(root, /target does not exist/);
      return 'an undeclared missing file fails';
    }),
  },
  {
    name: 'broken-section',
    run: () => fixture(({ root, write }) => {
      write('README.md', '[Design](design/README.md#missing)\n');
      expectFailure(root, /section does not exist/);
      return 'an existing file does not hide a missing section';
    }),
  },
  {
    name: 'local-section-and-reference-link',
    run: () => fixture(({ root, write }) => {
      write('README.md', '# Contents\n[here](#missing)\n[design]: design/README.md#missing\n');
      const result = invoke(root);
      assert.equal(result.status, 1, result.output);
      assert.match(result.output, /README.md -> #missing: section does not exist/);
      assert.match(result.output, /README.md -> design\/README.md#missing: section does not exist/);
      return 'same-file fragments and reference definitions are checked';
    }),
  },
  {
    name: 'outside-repository-link',
    run: () => fixture(({ root, write }) => {
      write('README.md', '[outside](../outside.md)\n');
      expectFailure(root, /outside the repository/);
      return 'parent traversal is not a valid document target';
    }),
  },
  {
    name: 'examples-and-comments-are-not-links',
    run: () => fixture(({ root, write }) => {
      write('README.md', '````markdown\n```text\n[missing](no.md)\n```\n````\n~~~text\n[missing](no.md)\n~~~\n<!-- [missing](no.md) -->\n');
      const result = invoke(root);
      assert.equal(result.status, 0, result.output);
      return 'nested fence examples, tilde fences and HTML comments are excluded';
    }),
  },
  {
    name: 'changed-reference',
    run: () => fixture(({ root, write }) => {
      write('LICENSE', 'changed\n');
      expectFailure(root, /LICENSE: differs from the carried reference/);
      return 'a changed carried file fails its captured digest';
    }),
  },
  {
    name: 'another-checkout-is-not-read',
    run: () => fixture(({ root, write }) => {
      write('.claude/worktrees/agent/README.md', '[gone](missing.md)\n');
      const result = invoke(root);
      assert.equal(result.status, 0, result.output);
      return "an agent's checkout under .claude/worktrees is not this tree";
    }),
  },
  {
    name: 'design-cites-an-absent-adr',
    run: () => fixture(({ root, write }) => {
      write('design/README.md', '# Design\nADR ' + '0106\n');
      expectFailure(root, /unknown ADR\s0106/);
      return 'the design cannot cite an ADR that does not exist';
    }),
  },
  {
    name: 'source-cites-an-absent-adr',
    run: () => fixture(({ root, write }) => {
      write('src/example.zig', '// The rule (ADR ' + '0106).\n');
      expectFailure(root, /src\/example.zig: unknown ADR\s0106/);
      return 'a source comment cannot cite an ADR that does not exist';
    }),
  },
  {
    name: 'list-without-reading-project',
    run() {
      const result = invoke(join(tmpdir(), 'nilu-absent-project'), ['--list']);
      assert.equal(result.status, 0, result.output);
      assert.match(result.output, /^docs-check: 6 cases, none run/);
      return 'listing reads no project files';
    },
  },
  {
    name: 'named-case-and-unknown-case',
    run: () => fixture(({ root }) => {
      const selected = invoke(root, ['--only=carried-references']);
      assert.equal(selected.status, 0, selected.output);
      assert.match(selected.output, /^docs-check: running 1 of 6 cases/);
      const unknown = invoke(root, ['--only=typo']);
      assert.equal(unknown.status, 1, unknown.output);
      assert.match(unknown.output, /no case named "typo"/);
      return 'a subset is announced and an unknown subset fails';
    }),
  },
];

runChecks('docs-check-test', cases);
