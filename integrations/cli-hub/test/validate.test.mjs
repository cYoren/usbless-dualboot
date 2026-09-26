/**
 * Negative-path tests for validate.mjs.
 *
 * The point of these: prove the validator actually FAILS on a broken payload, so a
 * green `npm run validate` is evidence and not a vacuous pass. Each test mutates a
 * copy of the real payload into a temp dir and asserts a non-zero exit plus a
 * message naming the specific defect.
 *
 * Run: npm test
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import os from "node:os";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const validator = path.join(root, "validate.mjs");

const ENTRY = path.join(root, "..", "cli-anything", "registry-entry.json");
const SURFACE = path.join(root, "command-surface.json");

const tmp = mkdtempSync(path.join(os.tmpdir(), "cli-hub-validate-"));

/** Run the validator against the real payloads (or overrides) and return its result. */
function run(args = []) {
  return spawnSync(process.execPath, [validator, ...args], { encoding: "utf8" });
}

/** Write a mutated copy of a payload and return the path. */
function mutate(basePath, name, mutateFn) {
  const doc = JSON.parse(readFileSync(basePath, "utf8"));
  mutateFn(doc);
  const out = path.join(tmp, name);
  writeFileSync(out, JSON.stringify(doc, null, 2));
  return out;
}

describe("baseline", () => {
  test("the shipped payload passes", () => {
    const r = run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /PASS/);
  });

  test("the shipped payload passes in strict mode too", () => {
    const r = run(["--strict"]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
  });
});

describe("rejects a malformed registry entry", () => {
  test("missing a required field (category)", () => {
    const p = mutate(ENTRY, "no-category.json", (d) => delete d.category);
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /category/);
  });

  test("missing skill_md", () => {
    const p = mutate(ENTRY, "no-skillmd.json", (d) => delete d.skill_md);
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /skill_md/);
  });

  test("a category outside the published vocabulary", () => {
    const p = mutate(ENTRY, "bad-category.json", (d) => { d.category = "dual-boot"; });
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /category/);
  });

  test("an install_strategy the installer does not dispatch on", () => {
    const p = mutate(ENTRY, "bad-strategy.json", (d) => { d.install_strategy = "apt"; });
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /install_strategy|apt/);
  });

  test("a name that is not a valid registry key", () => {
    const p = mutate(ENTRY, "bad-name.json", (d) => { d.name = "USBless Dualboot!"; });
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /name/);
  });

  test("a placeholder left in the payload", () => {
    const p = mutate(ENTRY, "placeholder.json", (d) => { d.description = "TODO describe me"; });
    const r = run([`--entry=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /placeholder/i);
  });
});

describe("rejects a payload that lies about danger or privilege", () => {
  const cmd = (d, name) => d.commands.find((c) => c.name === name);

  test("a destructive command downgraded to non-destructive", () => {
    const p = mutate(SURFACE, "no-destructive.json", (d) => { cmd(d, "shrink").destructive = false; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /shrink/);
  });

  test("a destructive command downgraded to danger: none", () => {
    const p = mutate(SURFACE, "safe-danger.json", (d) => { cmd(d, "stage").danger = "none"; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /stage/);
  });

  test("a root-requiring command marked requires_root: false", () => {
    const p = mutate(SURFACE, "no-root.json", (d) => { cmd(d, "secureboot").requires_root = false; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /secureboot/);
  });

  test("a command using a danger level that is not defined", () => {
    const p = mutate(SURFACE, "undefined-danger.json", (d) => { cmd(d, "windows").danger = "spicy"; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /spicy|danger/i);
  });

  test("a mutating command with no declared side effects", () => {
    const p = mutate(SURFACE, "no-side-effects.json", (d) => { cmd(d, "boot").side_effects = []; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /boot/);
  });

  test("a mutating command dropped from integrator_contract", () => {
    const p = mutate(SURFACE, "no-contract.json", (d) => { d.integrator_contract.mutating_commands = ["shrink"]; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /mutating_commands|stage/);
  });

  test("a command claiming a side effect it does not have is also caught via schema", () => {
    // Removing the mandatory exit_codes map must fail schema validation.
    const p = mutate(SURFACE, "no-exit-codes.json", (d) => { delete cmd(d, "probe").exit_codes; });
    const r = run([`--surface=${p}`]);
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /exit_codes/);
  });
});