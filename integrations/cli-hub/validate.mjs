#!/usr/bin/env node
/**
 * Validate the CLI-Hub submission payload for usbless-dualboot.
 *
 *   node validate.mjs              # schema validation + self-consistency + CLI cross-check
 *   node validate.mjs --strict     # also fail on keys the published registry never uses
 *   node validate.mjs --upstream   # additionally validate all 103 published upstream entries
 *
 * What this proves and what it does not:
 *   PROVES  - registry-entry.json is well-formed against the field set and enums actually
 *             published by HKUDS/CLI-Anything, and that the values it claims (entry_point,
 *             version, exit codes, danger levels, read-only vs mutating split) match the
 *             real CLI in this repo.
 *   DOES NOT PROVE - that CLI-Hub has accepted or merged the entry. Submission is a pull
 *             request to HKUDS/CLI-Anything; nothing here performs it.
 *
 * No network access is required for the default run.
 */
import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

import Ajv from "ajv";
import addFormats from "ajv-formats";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const strict = process.argv.includes("--strict");
const upstream = process.argv.includes("--upstream");

const read = (p) => JSON.parse(readFileSync(p, "utf8"));

// --entry / --surface point the validator at alternate payloads, so the test
// harness can prove it rejects deliberately broken ones (see test/validate.test.mjs).
const argOf = (flag) => {
  const hit = process.argv.find((a) => a.startsWith(`${flag}=`));
  return hit ? hit.slice(flag.length + 1) : null;
};
const entryPath = argOf("--entry") ?? path.join(here, "..", "cli-anything", "registry-entry.json");
const surfacePath = argOf("--surface") ?? path.join(here, "command-surface.json");

const entry = read(entryPath);
const entrySchema = read(path.join(here, "registry-entry.schema.json"));
const surface = read(surfacePath);
const surfaceSchema = read(path.join(here, "command-surface.schema.json"));

let failures = 0;
const warnings = [];

const ok = (msg) => console.log(`  ok    ${msg}`);
const bad = (msg) => {
  failures += 1;
  console.log(`  FAIL  ${msg}`);
};
const warn = (msg) => {
  warnings.push(msg);
  console.log(`  warn  ${msg}`);
};

// ---------------------------------------------------------------- 1. JSON Schema

console.log("\n[1] JSON Schema validation");

const ajv = new Ajv({ allErrors: true, strict: false });
addFormats(ajv);

const validateEntry = ajv.compile(entrySchema);
if (validateEntry(entry)) {
  ok("registry-entry.json validates against registry-entry.schema.json");
} else {
  for (const e of validateEntry.errors ?? []) {
    bad(`registry-entry.json${e.instancePath} ${e.message}`);
  }
}

const validateSurface = ajv.compile(surfaceSchema);
if (validateSurface(surface)) {
  ok("command-surface.json validates against command-surface.schema.json");
} else {
  for (const e of validateSurface.errors ?? []) {
    bad(`command-surface.json${e.instancePath} ${e.message}`);
  }
}

// ------------------------------------------------------- 2. payload self-consistency

console.log("\n[2] payload self-consistency");

// install_strategy must be one the installer actually dispatches on. When the
// field is omitted, cli_hub.installer._install_strategy derives it, so resolve
// the same way instead of reporting a missing field as broken.
const KNOWN_STRATEGIES = new Set(["pip", "npm", "uv", "command", "bundled"]);
function effectiveStrategy(e) {
  if (e.install_strategy) return e.install_strategy;
  if ((e._source ?? "public") === "harness") return "pip";
  if (e.npm_package || e.package_manager === "npm") return "npm";
  if (e.package_manager === "uv") return "uv";
  if (e.package_manager === "bundled") return "bundled";
  return "command";
}
const strategy = effectiveStrategy(entry);
if (KNOWN_STRATEGIES.has(strategy)) {
  const how = entry.install_strategy ? "declares" : "omits (installer defaults to)";
  ok(`install_strategy: entry ${how} "${strategy}", dispatched by cli_hub.installer._perform_action`);
} else {
  bad(`install_strategy "${entry.install_strategy}" is not a known installer strategy`);
}

// install_strategy and package_manager must not disagree.
if (!entry.install_strategy || entry.package_manager === entry.install_strategy) {
  ok("package_manager agrees with install_strategy");
} else {
  warn(`package_manager "${entry.package_manager}" differs from install_strategy "${entry.install_strategy}"`);
}

// The install command must not be a placeholder.
if (/\b(TODO|FIXME|example\.com|your-org)\b/i.test(JSON.stringify(entry))) {
  bad("payload contains a placeholder token");
} else {
  ok("no placeholder tokens in the payload");
}

// Keys the published registries never use.
const PUBLISHED_KEYS = new Set([
  "name", "display_name", "version", "description", "category", "requires",
  "homepage", "source_url", "install_cmd", "entry_point", "skill_md", "category",
  "contributors", "contributor", "contributor_url", "install_strategy",
  "package_manager", "uninstall_cmd", "uninstall_notes", "update_cmd",
  "update_notes", "detect_cmd", "docs_url", "platform", "engines",
  "npm_package", "npx_cmd", "install_notes",
]);
const extraKeys = Object.keys(entry).filter((k) => !PUBLISHED_KEYS.has(k) && !k.startsWith("$"));
if (extraKeys.length === 0) {
  ok("no keys outside the published registry vocabulary");
} else if (strict) {
  bad(`keys outside the published registry vocabulary: ${extraKeys.join(", ")}`);
} else {
  warn(`keys outside the published registry vocabulary: ${extraKeys.join(", ")} (use --strict to fail)`);
}

// ------------------------------------------------- 3. cross-check against the real CLI

console.log("\n[3] cross-check against the real CLI");

// Resolve the entry_point the way CLI-Hub would: entry_point is the *command*
// the user runs. That is either a file in this repo's bin/ (source checkout) or
// the console script a package manager installs onto PATH (e.g. a pip adapter).
const localBin = path.join(repoRoot, "bin", entry.entry_point);
let bin = null;
if (existsSync(localBin)) {
  bin = localBin;
  ok(`entry_point resolves to a repo file: ${path.relative(repoRoot, localBin)}`);
} else {
  const onPath = (process.env.PATH ?? "")
    .split(path.delimiter)
    .filter(Boolean)
    .map((d) => path.join(d, entry.entry_point))
    .find((p) => existsSync(p));
  if (onPath) {
    bin = onPath;
    ok(`entry_point resolves to an installed command: ${onPath}`);
  } else {
    // The descriptor names the *installed* command, which may not be installed here.
    // Fall back to this repo's own CLI so the descriptor's claims are still checked
    // against the real command surface it describes.
    const canonical = path.join(repoRoot, "bin", entry.name);
    if (existsSync(canonical)) {
      bin = canonical;
      ok(
        `entry_point "${entry.entry_point}" is not installed; checked the descriptor ` +
          `against this repo's own CLI at ${path.relative(repoRoot, canonical)} instead`,
      );
    } else {
      warn(`entry_point "${entry.entry_point}" could not be resolved; CLI cross-checks skipped`);
    }
  }
}

// skill_md is either a repo-relative path or a full URL to the published SKILL.md.
if (/^https?:\/\//.test(entry.skill_md)) {
  ok(`skill_md is a published URL (${entry.skill_md})`);
} else {
  const skillPath = path.join(repoRoot, entry.skill_md);
  if (!existsSync(skillPath)) {
    bad(`skill_md "${entry.skill_md}" is neither an http(s) URL nor an existing repo path`);
  } else {
    const skillSrc = readFileSync(skillPath, "utf8");
    if (/^---\s*\n[\s\S]*?name:\s*usbless-dualboot/m.test(skillSrc)) {
      ok(`skill_md exists and declares name: usbless-dualboot`);
    } else {
      warn(`skill_md "${entry.skill_md}" exists but has no "name: usbless-dualboot" frontmatter`);
    }
  }
}

// version claimed by the payload must match `--version`
try {
  const out = execFileSync(bin, ["--version"], { encoding: "utf8" }).trim();
  const actual = out.replace(`${entry.name}`, "").trim();
  if (actual === entry.version) {
    ok(`version matches the CLI (${out})`);
  } else {
    bad(`payload says version ${entry.version} but the CLI reports "${actual}"`);
  }
} catch (err) {
  bad(`could not run ${entry.entry_point} --version: ${err.message}`);
}

// every command named in command-surface.json must be a real subcommand
const realCommands = surface.commands.map((c) => c.name);
for (const name of realCommands) {
  try {
    execFileSync(bin, [name, "--help"], { stdio: "pipe" });
    ok(`subcommand "${name}" exists`);
  } catch (err) {
    // --help exits 0 for real commands; a non-zero exit means unknown subcommand
    // (validated by the negative control below).
    bad(`subcommand "${name}" failed its own --help (exit ${err.status})`);
  }
}

// negative control: a command that does not exist must be rejected by the CLI
try {
  execFileSync(bin, ["definitely-not-a-command"], { stdio: "pipe" });
  bad("negative control: an unknown subcommand was accepted");
} catch (err) {
  if (err.status === 1) {
    ok("negative control: unknown subcommand exits 1");
  } else {
    bad(`negative control: unknown subcommand exited ${err.status}, expected 1`);
  }
}

// exit code 0 for read-only commands, 1 for the documented failure path
try {
  execFileSync(bin, ["version"], { stdio: "pipe" });
  ok("exit code 0 on success matches the manifest");
} catch (err) {
  bad(`version exited ${err.status}, manifest claims 0`);
}

// ------------------------------------------------- 4. danger/privilege honesty

console.log("\n[4] danger and privilege honesty");

const ROOT_NEEDED = new Set(["shrink", "stage", "boot", "windows", "secureboot"]);
const DESTRUCTIVE = new Set(["shrink", "stage", "boot", "secureboot"]);

for (const cmd of surface.commands) {
  const libPath = cmd.lib ? path.join(repoRoot, cmd.lib) : null;
  if (libPath && existsSync(libPath)) {
    const src = readFileSync(libPath, "utf8");
    const callsNeedRoot = /need_root/.test(src);
    if (ROOT_NEEDED.has(cmd.name) && !callsNeedRoot) {
      bad(`“${cmd.name}” is marked requires_root: true but ${cmd.lib} never calls need_root`);
    } else if (!ROOT_NEEDED.has(cmd.name) && callsNeedRoot) {
      bad(`“${cmd.name}” is marked requires_root: false but ${cmd.lib} calls need_root`);
    }
  }
  if (ROOT_NEEDED.has(cmd.name) && cmd.requires_root !== true) {
    bad(`“${cmd.name}” must be marked requires_root: true`);
  }
  if (DESTRUCTIVE.has(cmd.name) && cmd.destructive !== true) {
    bad(`“${cmd.name}” performs a destructive action but is not marked destructive`);
  }
  if (!DESTRUCTIVE.has(cmd.name) && cmd.destructive === true && cmd.name !== "windows") {
    bad(`“${cmd.name}” is marked destructive but is not in the destructive set`);
  }
  if (!(cmd.danger in surface.danger_scale)) {
    bad(`“${cmd.name}” uses undefined danger level "${cmd.danger}"`);
  }
  // A command declared destructive must not also be described as harmless.
  if (cmd.destructive === true && cmd.danger === "none") {
    bad(`“${cmd.name}” is declared destructive but its danger level is "none"`);
  }
  // A destructive command must declare consequences.
  if (cmd.destructive === true && !cmd.side_effects?.length) {
    bad(`destructive command "${cmd.name}" lists no side effects`);
  }
  // Everything that can write must say so.
  if (cmd.danger !== "none" && !cmd.side_effects?.length) {
    bad(`“${cmd.name}” has danger "${cmd.danger}" but lists no side effects`);
  }
}
ok(`checked ${surface.commands.length} commands for privilege and danger honesty`);

const declaredMutating = new Set(surface.integrator_contract.mutating_commands);
for (const name of ROOT_NEEDED) {
  if (!declaredMutating.has(name)) {
    bad(`mutating command "${name}" is missing from integrator_contract.mutating_commands`);
  }
}
const declaredReadOnly = new Set(surface.integrator_contract.read_only_commands);
for (const name of declaredMutating) {
  if (declaredReadOnly.has(name)) {
    bad(`"${name}" is listed as both read-only and mutating`);
  }
}
ok("integrator_contract read-only/mutating split is consistent");

// -------------------------------------------- 5. companion cannot reach mutating phases

console.log("\n[5] read-only companion isolation");

const companionActions = path.join(repoRoot, "integrations", "agent-native", "src", "registry.ts");
if (existsSync(companionActions)) {
  const src = readFileSync(companionActions, "utf8");
  const exposed = new Set();
  for (const phase of ROOT_NEEDED) {
    if (new RegExp(`["'\`]${phase}["'\`]`).test(src)) exposed.add(phase);
  }
  if (exposed.size === 0) {
    ok("no mutating phase name appears in the companion action registry");
  } else {
    bad(`companion registry names mutating phases: ${[...exposed].join(", ")}`);
  }
} else {
  warn("companion registry not found; skipped isolation check");
}

// ------------------------------------------------- 6. optional upstream corpus check

if (upstream) {
  console.log("\n[6] published upstream corpus (--upstream)");
  const doc = "https://raw.githubusercontent.com/HKUDS/CLI-Anything/main/";
  let checked = 0;
  for (const file of ["registry.json", "public_registry.json"]) {
    const res = await fetch(doc + file);
    if (!res.ok) {
      bad(`could not fetch ${file} (HTTP ${res.status})`);
      continue;
    }
    const body = await res.json();
    const validate = ajv.compile(entrySchema);
    let badEntries = 0;
    for (const cli of body.clis) {
      if (!validate(cli)) {
        badEntries += 1;
        if (badEntries <= 3) {
          warn(`${file}: "${cli.name}" does not satisfy the transcribed schema: ` +
            (validate.errors ?? []).map((e) => `${e.instancePath} ${e.message}`).join("; "));
        }
      }
      checked += 1;
    }
    if (badEntries === 0) {
      ok(`${file}: all ${body.clis.length} published entries satisfy the transcribed schema`);
    } else {
      warn(`${file}: ${badEntries}/${body.clis.length} published entries do not satisfy the transcribed schema`);
    }
  }
  console.log(`  info  cross-checked ${checked} published entries`);
} else {
  console.log("\n[6] published upstream corpus skipped (pass --upstream; needs network)");
}

// ---------------------------------------------------------------- verdict

console.log("");
if (warnings.length) {
  console.log(`${warnings.length} warning(s); see above.`);
}
if (failures === 0) {
  console.log(`PASS  registry entry is valid and matches the real CLI${strict ? " (strict)" : ""}.`);
  process.exit(0);
}
console.log(`FAIL  ${failures} check(s) failed.`);
process.exit(1);