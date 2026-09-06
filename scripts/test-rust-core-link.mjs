#!/usr/bin/env node

import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runProcess } from "../.agents/skills/write-stable-tests/scripts/test-timing-lib.mjs";
import { writeTestReportArtifacts } from "../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const prepareScript = path.join(repository, "scripts/prepare-rust-core-link.sh");
const root = await fs.mkdtemp(path.join(os.tmpdir(), "lithe rust link "));
const packageRoot = path.join(root, "swift fixture");
const archive = path.join(root, "liblithe_core.a");
const tests = [];
const started = performance.now();
const deadline = started + 240_000;
const reportPath = path.join(repository, ".artifacts/test-stability/macos-rust-link.json");
const log = [];

async function run(command, args, { env = process.env, succeeds = true } = {}) {
  const remaining = deadline - performance.now();
  assert(remaining > 0, "Native Rust link fixture exceeded its 240s suite deadline");
  const result = await runProcess({ command, args, cwd: root, env, timeoutMs: Math.min(45_000, remaining) });
  log.push(`${command} ${JSON.stringify(args)}\n${result.stdout}${result.stderr}`);
  assert(!result.timedOut && result.terminationConfirmed, `Native command timed out: ${command}`);
  if (succeeds) assert.equal(result.code, 0, result.stdout + result.stderr);
  else assert.notEqual(result.code, 0, "Expected the malformed archive build to fail");
  return result;
}

async function test(name, body) {
  const start = performance.now();
  try {
    await body();
    tests.push({ name, suite: "macOS Rust link integration", status: "passed", durationMs: performance.now() - start });
    console.log(`PASS ${name}`);
  } catch (error) {
    tests.push({ name, suite: "macOS Rust link integration", status: "failed", durationMs: performance.now() - start, message: String(error) });
    throw error;
  }
}

async function compileArchive(value) {
  const source = path.join(root, "value.c");
  const object = path.join(root, "value.o");
  await fs.writeFile(source, `int lithe_link_fixture_value(void) { return ${value}; }\n`);
  await run("xcrun", ["clang", "-c", source, "-o", object]);
  await fs.rm(archive, { force: true });
  await run("xcrun", ["ar", "rcs", archive, object]);
}

async function prepared(input = archive) {
  return (await run(prepareScript, [input])).stdout.trim();
}

function swiftArguments(command, snapshot) {
  return [command, ...(command === "test" ? ["--disable-xctest"] : []), "--package-path", packageRoot, "--disable-sandbox", "-Xlinker", "-force_load", "-Xlinker", snapshot];
}

try {
  assert.equal(process.platform, "darwin", "This integration fixture requires macOS clang and Swift");
  await fs.mkdir(path.join(packageRoot, "Sources/RustProbe"), { recursive: true });
  await fs.mkdir(path.join(packageRoot, "Sources/RustLinkFixture"), { recursive: true });
  await fs.mkdir(path.join(packageRoot, "Tests/RustProbeTests"), { recursive: true });
  await fs.writeFile(path.join(packageRoot, "Package.swift"), `// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RustLinkFixture", platforms: [.macOS(.v13)], products: [.executable(name: "RustLinkFixture", targets: ["RustLinkFixture"])], targets: [
    .target(name: "RustProbe"),
    .executableTarget(name: "RustLinkFixture", dependencies: ["RustProbe"]),
    .testTarget(name: "RustProbeTests", dependencies: ["RustProbe"])
])
`);
  await fs.writeFile(path.join(packageRoot, "Sources/RustProbe/Probe.swift"), `@_silgen_name("lithe_link_fixture_value") private func nativeValue() -> Int32
public func archiveValue() -> Int32 { nativeValue() }
`);
  await fs.writeFile(path.join(packageRoot, "Sources/RustLinkFixture/main.swift"), "import RustProbe\nprint(archiveValue())\n");
  // Expected values come from the process environment: changing the archive
  // must be the only build input change between the two linked implementations.
  await fs.writeFile(path.join(packageRoot, "Tests/RustProbeTests/ProbeTests.swift"), `import Testing
import Foundation
import RustProbe
@Test func nativeArchiveValue() throws {
    let expected = try #require(ProcessInfo.processInfo.environment["LITHE_LINK_FIXTURE_EXPECTED"].flatMap(Int32.init))
    #expect(archiveValue() == expected)
}
`);
  let firstSnapshot, secondSnapshot, firstBytes, secondBytes, originalTimes, binary;
  await test("immutable snapshots are idempotent and support paths with spaces", async () => {
    await compileArchive(1);
    originalTimes = await fs.stat(archive);
    firstSnapshot = await prepared();
    firstBytes = await fs.readFile(firstSnapshot);
    const time = (await fs.stat(firstSnapshot)).mtimeMs;
    assert.equal(await prepared(), firstSnapshot);
    assert.equal(await prepared(firstSnapshot), firstSnapshot);
    assert.equal((await fs.stat(firstSnapshot)).mtimeMs, time);
  });
  await test("concurrent publishers return the same intact snapshot and clean staging", async () => {
    const directory = path.join(root, "concurrent publishers");
    await fs.mkdir(directory);
    const source = path.join(directory, "liblithe_core.a");
    await fs.copyFile(archive, source);
    const completed = await Promise.allSettled([prepared(source), prepared(source)]);
    for (const result of completed) assert.equal(result.status, "fulfilled", String(result.reason));
    assert.equal(completed[0].value, completed[1].value);
    assert.deepEqual(await fs.readFile(completed[0].value), firstBytes);
    assert(!(await fs.readdir(path.join(directory, "lithe-link"))).some(name => name.startsWith(".publish.")));
  });
  await test("initial executable and Swift test bundle run the first archive", async () => {
    await run("swift", swiftArguments("build", firstSnapshot));
    binary = path.join((await run("swift", ["build", "--package-path", packageRoot, "--show-bin-path"])).stdout.trim(), "RustLinkFixture");
    assert.equal((await run(binary, [])).stdout.trim(), "1");
    await run("swift", swiftArguments("test", firstSnapshot), { env: { ...process.env, LITHE_LINK_FIXTURE_EXPECTED: "1" } });
  });
  await test("archive content change with preserved mtime relinks executable and tests", async () => {
    await compileArchive(2);
    await fs.utimes(archive, originalTimes.atime, originalTimes.mtime);
    secondSnapshot = await prepared();
    secondBytes = await fs.readFile(secondSnapshot);
    assert.notEqual(secondSnapshot, firstSnapshot);
    assert.deepEqual(await fs.readFile(firstSnapshot), firstBytes);
    await run("swift", swiftArguments("build", secondSnapshot));
    assert.equal((await run(binary, [])).stdout.trim(), "2");
    await run("swift", swiftArguments("test", secondSnapshot), { env: { ...process.env, LITHE_LINK_FIXTURE_EXPECTED: "2" } });
  });
  await test("unchanged archive does not relink executable or tests", async () => {
    assert.equal(await prepared(), secondSnapshot);
    const build = await run("swift", swiftArguments("build", secondSnapshot));
    const testRun = await run("swift", swiftArguments("test", secondSnapshot), { env: { ...process.env, LITHE_LINK_FIXTURE_EXPECTED: "2" } });
    assert.doesNotMatch(build.stdout + build.stderr + testRun.stdout + testRun.stderr, /\bLinking\b/);
    assert.equal((await run(binary, [])).stdout.trim(), "2");
  });
  await test("failed link and corrupted cache cannot overwrite earlier snapshots", async () => {
    await fs.writeFile(archive, "This is not a static archive.\n");
    const badSnapshot = await prepared();
    await run("swift", swiftArguments("build", badSnapshot), { succeeds: false });
    assert.deepEqual(await fs.readFile(firstSnapshot), firstBytes);
    assert.deepEqual(await fs.readFile(secondSnapshot), secondBytes);
    await fs.chmod(badSnapshot, 0o644);
    await fs.writeFile(badSnapshot, "corrupt cache");
    const result = await run(prepareScript, [archive], { succeeds: false });
    assert.match(result.stderr, /cache is invalid/);
    await run(prepareScript, [badSnapshot], { succeeds: false });
    assert(!(await fs.readdir(path.join(root, "lithe-link"))).some(name => name.startsWith(".publish.")));
  });
  await test("test wrapper preserves optional Rust and other linker arguments", async () => {
    const wrapperRoot = path.join(root, "wrapper");
    const scripts = path.join(wrapperRoot, "scripts");
    const bin = path.join(wrapperRoot, "bin");
    await fs.mkdir(scripts, { recursive: true });
    await fs.mkdir(bin);
    await fs.copyFile(path.join(repository, "scripts/test-macos.sh"), path.join(scripts, "test-macos.sh"));
    await fs.copyFile(prepareScript, path.join(scripts, "prepare-rust-core-link.sh"));
    await fs.chmod(path.join(scripts, "test-macos.sh"), 0o755);
    await fs.chmod(path.join(scripts, "prepare-rust-core-link.sh"), 0o755);
    const swiftStub = path.join(bin, "swift");
    await fs.writeFile(swiftStub, "#!/bin/zsh\nprint -rl -- \"$@\"\n", { mode: 0o755 });
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}` };
    const wrapper = path.join(scripts, "test-macos.sh");
    const other = ["-Xlinker", "-force_load", "-Xlinker", "third-party.a", "--filter", "Example test"];
    let result = await run(wrapper, other, { env });
    assert.deepEqual(result.stdout.trim().split("\n").slice(-other.length), other);
    const missing = path.join(root, "never-built/liblithe_core.a");
    const skipped = ["--skip-build", "-Xlinker", "-force_load", "-Xlinker", missing];
    result = await run(wrapper, skipped, { env });
    assert.deepEqual(result.stdout.trim().split("\n").slice(-skipped.length), skipped);
    await compileArchive(2);
    const forceLoad = ["-Xlinker", "-force_load", "-Xlinker", archive];
    result = await run(wrapper, forceLoad, { env });
    assert.equal(result.stdout.trim().split("\n").at(-1), await prepared());
    result = await run(wrapper, [...other, ...forceLoad], { env });
    assert.deepEqual(result.stdout.trim().split("\n").slice(-(other.length + forceLoad.length)), [...other, ...forceLoad.slice(0, -1), await prepared()]);
    result = await run(wrapper, ["-Xlinker=-force_load", `-Xlinker=${archive}`], { env });
    assert.equal(result.stdout.trim().split("\n").at(-1), `-Xlinker=${await prepared()}`);
    const duplicate = await run(wrapper, [...forceLoad, ...forceLoad], { env, succeeds: false });
    assert.match(duplicate.stderr, /Only one Rust Core/);
    await assert.rejects(fs.stat(path.join(root, "never-built")), { code: "ENOENT" });
  });
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  try { await fs.rm(root, { recursive: true, force: true }); }
  catch (error) {
    tests.push({ name: "fixture cleanup", status: "failed", durationMs: 0, message: String(error) });
    process.exitCode = 1;
  }
  await fs.mkdir(path.dirname(reportPath), { recursive: true });
  await fs.writeFile(reportPath.replace(/\.json$/, ".log"), log.join("\n"));
  await fs.writeFile(reportPath, JSON.stringify({ schemaVersion: 1, runner: "macOS Rust linking", warnMs: 15_000, maxMs: 90_000, suite: { durationMs: performance.now() - started }, tests }, null, 2));
  writeTestReportArtifacts(reportPath);
}
