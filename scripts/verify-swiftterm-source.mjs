#!/usr/bin/env node
// Verify the compiled local patch against the retained immutable upstream inputs.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { cpSync, lstatSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../third_party/SwiftTerm');
const metadata = ['README.md', 'upstream.json', 'lithe-typography.patch',
  'Sources/SwiftTerm/Notices/LitheChanges.txt'];
let temporary;
try {
  const manifest = JSON.parse(readFileSync(join(root, 'upstream.json'), 'utf8'));
  if (manifest.repository !== 'https://github.com/migueldeicaza/SwiftTerm.git'
      || !/^[a-f0-9]{40}$/.test(manifest.revision) || !Array.isArray(manifest.files)) {
    throw new Error('Invalid SwiftTerm upstream manifest');
  }
  const safePath = path => typeof path === 'string' && path.length > 0
    && path.split('/').every(part => part && part !== '.' && part !== '..')
    && !path.includes('\\');
  const expected = new Set(metadata);
  for (const file of manifest.files) {
    if (!safePath(file.path) || !safePath(file.upstreamPath)
        || !/^[a-f0-9]{64}$/.test(file.sha256) || expected.has(file.path)) {
      throw new Error(`Invalid or duplicate upstream entry: ${file.path}`);
    }
    expected.add(file.path);
  }
  const actual = [];
  function enumerate(directory, prefix = '') {
    for (const entry of readdirSync(directory)) {
      const relative = prefix ? `${prefix}/${entry}` : entry;
      const stat = lstatSync(join(directory, entry));
      if (stat.isSymbolicLink()) throw new Error(`Unexpected symlink: ${relative}`);
      if (stat.isDirectory()) enumerate(join(directory, entry), relative);
      else if (stat.isFile()) actual.push(relative);
      else throw new Error(`Unexpected file type: ${relative}`);
    }
  }
  enumerate(root);
  for (const path of actual) {
    if (!expected.delete(path)) throw new Error(`Unexpected SwiftTerm file: ${path}`);
  }
  if (expected.size) throw new Error(`Missing SwiftTerm files: ${[...expected].join(', ')}`);

  temporary = mkdtempSync(join(tmpdir(), 'lithe-swiftterm-verify-'));
  const restored = join(temporary, 'source');
  cpSync(root, restored, { recursive: true });
  const patch = readFileSync(join(root, 'lithe-typography.patch'));
  // Running outside the repository prevents Git from applying paths relative to
  // the workspace. The subprocess is bounded even for a malformed patch.
  const options = { cwd: restored, input: patch, timeout: 10_000, maxBuffer: 1_048_576 };
  execFileSync('git', ['apply', '--reverse', '--check', '--whitespace=nowarn', '-'], options);
  execFileSync('git', ['apply', '--reverse', '--whitespace=nowarn', '-'], options);
  for (const file of manifest.files) {
    const digest = createHash('sha256').update(readFileSync(join(restored, file.path))).digest('hex');
    if (digest !== file.sha256) throw new Error(`Upstream hash mismatch: ${file.path}`);
  }
  // Imported source retains upstream whitespace. Check only our added patch
  // lines, independently of the developer's Git whitespace/attribute settings.
  execFileSync('git', ['-c', 'core.whitespace=blank-at-eol,blank-at-eof,space-before-tab',
    '-c', 'core.attributesFile=/dev/null', 'apply', '--check', '--whitespace=error', '-'], options);
  const notice = readFileSync(join(root, 'Sources/SwiftTerm/Notices/LitheChanges.txt'), 'utf8');
  if (!notice.includes(manifest.revision) || !notice.includes(`SwiftTerm ${manifest.version}`)) {
    throw new Error('Packaged change notice does not match the upstream pin');
  }
  console.log(`SwiftTerm ${manifest.version}: ${manifest.files.length} upstream files verified after reversing local patch.`);
} catch (error) {
  console.error(`SwiftTerm source verification failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  if (temporary) rmSync(temporary, { recursive: true, force: true });
}
