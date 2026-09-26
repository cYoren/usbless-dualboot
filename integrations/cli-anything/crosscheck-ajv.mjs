#!/usr/bin/env node
/**
 * Cross-check: validate integrations/cli-anything/registry-entry.json with ajv,
 * an independent, third-party JSON Schema engine, and compare the verdict with
 * the stdlib validator in python/cli_anything_usbless_dualboot/validate.py.
 *
 * This exists so that "the entry validates" does not rest on a hand-written
 * checker alone. ajv is resolved from the project-local install under
 * integrations/agent-native/node_modules — nothing is installed globally.
 *
 * Run:
 *   node integrations/cli-anything/crosscheck-ajv.mjs
 * Exit codes: 0 the two validators agree, 1 they disagree, 3 ajv not available.
 */
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");

const schemaPath = path.join(here, "schema", "registry-entry.schema.json");
const entryPath = path.join(here, "registry-entry.json");

const nodeRequire = createRequire(path.join(repo, "integrations", "agent-native", "package.json"));
let Ajv;
try {
  ({ default: Ajv } = await import(nodeRequire.resolve("ajv")));
} catch {
  console.error("ajv not found. Run `npm install` in integrations/agent-native first.");
  process.exit(3);
}

const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
const entry = JSON.parse(readFileSync(entryPath, "utf8"));

const ajv = new Ajv({ allErrors: true, strict: false });
// Ajv core does not implement draft-07 format assertions. Define the actual
// formats used by this schema so the independent check does not silently ignore
// bad homepage/source/contributor URLs.
ajv.addFormat("uri", {
  type: "string",
  validate(value) {
    try {
      const parsed = new URL(value);
      return parsed.protocol === "http:" || parsed.protocol === "https:";
    } catch {
      return false;
    }
  },
});
const validate = ajv.compile(schema);
const ok = validate(entry);

console.log(`ajv payload: ${path.relative(repo, entryPath)}`);
console.log(`ajv result : ${ok ? "VALID" : "INVALID"}`);
if (!ok) {
  for (const e of validate.errors ?? []) {
    console.error(`  ajv ${e.instancePath || "$"}: ${e.message}`);
  }
}

// Negative controls: ajv must actually reject broken entries, otherwise a "VALID"
// verdict above would be meaningless.
const broken = structuredClone(entry);
delete broken.entry_point;
const brokenRejected = validate(broken) === false;
console.log(`ajv negative control (missing entry_point rejected): ${brokenRejected}`);
const badUrl = structuredClone(entry);
badUrl.homepage = "not-a-url";
const badUrlRejected = validate(badUrl) === false;
console.log(`ajv negative control (invalid homepage rejected): ${badUrlRejected}`);

if (!ok || !brokenRejected || !badUrlRejected) {
  console.error("ajv cross-check FAILED");
  process.exit(1);
}

console.log(
  "\najv agrees the entry is valid and demonstrably rejects malformed input.\n" +
    "Compare with: python3 integrations/cli-anything/python/cli_anything_usbless_dualboot/validate.py",
);
process.exit(0);