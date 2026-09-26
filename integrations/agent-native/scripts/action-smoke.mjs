/**
 * Runtime smoke test for the real @agent-native/core action wiring.
 *
 * The TypeScript types prove the actions typecheck; this proves they *execute*
 * against the framework's own defineAction contract in Node, and that the
 * {tool, run, schema, readOnly, http} surface is what an agent would see.
 *
 * Two error idioms are exercised, deliberately:
 *   - The framework actions (actions/*.ts) report failure by THROWING, via the
 *     framework's fail() helper -> ActionContractError / statusCode 422.
 *   - The pure registry (src/registry.ts) reports failure by RETURNING ok:false.
 *     That is the shape the UI and CLI consume, because a renderer must not have
 *     to catch exceptions to show an error.
 * This script asserts both, so neither can silently change idiom.
 *
 * Run: node --experimental-strip-types integrations/agent-native/scripts/action-smoke.mjs
 * Exit codes: 0 pass, 1 fail.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const pkg = path.resolve(here, "..");
const load = async (rel) => (await import(pathToFileURL(path.join(pkg, rel)).href)).default;
const fixture = (n) => readFileSync(path.join(pkg, "fixtures", n), "utf8");

const loadProbe = await load("actions/load-probe.ts");
const summarizeLayout = await load("actions/summarize-layout.ts");
const comparePlanAction = await load("actions/compare-plan.ts");
const riskSummary = await load("actions/risk-summary.ts");

const { actionRegistry, invoke } = await import(pathToFileURL(path.join(pkg, "src/registry.ts")).href);

const actions = { loadProbe, summarizeLayout, comparePlanAction, riskSummary };
const probe = fixture("demo-probe.json");
const plan = fixture("demo-plan.json");

let failures = 0;
const check = (label, condition, detail = "") => {
  if (!condition) failures += 1;
  console.log(`${condition ? "ok  " : "FAIL"} ${label}${detail ? ` — ${detail}` : ""}`);
};

/** Capture a thrown ActionContractError so a rejection can be asserted. */
async function rejected(fn) {
  try {
    await fn();
    return null;
  } catch (err) {
    return err;
  }
}

console.log("=== 1. framework contract exposed by each action ===");
for (const [name, action] of Object.entries(actions)) {
  check(
    `${name}: {tool, run, schema, http, readOnly} present`,
    typeof action?.run === "function" &&
      action?.tool !== undefined &&
      action?.schema !== undefined &&
      typeof action?.readOnly === "boolean" &&
      action?.http === false,
  );
  check(`${name}: declared read-only and not HTTP-exposed`, action?.readOnly === true && action?.http === false);
}

console.log("\n=== 2. load-probe ===");
const loaded = await loadProbe.run({ probeJson: probe });
check("accepts the demo fixture", loaded.ok === true, loaded.message);
check("returns the parsed probe", loaded.probe?.uefi === "yes" && loaded.probe?.encryption === "luks");

const badJson = await rejected(() => loadProbe.run({ probeJson: "{ not json" }));
check(
  "malformed JSON is rejected by throwing, not by returning",
  badJson !== null && badJson.statusCode === 422 && badJson.errorCode === "invalid_probe",
  badJson ? `${badJson.constructor.name} ${badJson.errorCode} ${badJson.statusCode}` : "nothing thrown",
);

const badField = await rejected(() =>
  loadProbe.run({ probeJson: JSON.stringify({ ...JSON.parse(probe), uefi: "maybe" }) }),
);
check("an unsupported field value is rejected", badField?.errorCode === "invalid_probe");

console.log("\n=== 3. summarize-layout ===");
const summary = await summarizeLayout.run({ probeJson: probe });
check("returns a summary", summary.summary !== undefined);
check("reads firmware/root/bootloader from the fixture", summary.summary?.firmware === "UEFI" && summary.summary?.bootloader === "limine");
check("message is human-readable", typeof summary.message === "string" && summary.message.length > 0, summary.message);

console.log("\n=== 4. compare-plan ===");
const compared = await comparePlanAction.run({ probeJson: probe, planJson: plan });
check("consistent plan yields consistent=true", compared.consistent === true);
check("consistent plan yields zero conflicts", compared.conflicts?.length === 0);
check("phase order is exposed", Array.isArray(compared.phaseOrder) && compared.phaseOrder.length > 0);

const contradicting = JSON.stringify({ ...JSON.parse(plan), linux_fstype: "ext4" });
const badPlan = await comparePlanAction.run({ probeJson: probe, planJson: contradicting });
check("contradicting plan yields consistent=false", badPlan.consistent === false);
check(
  "contradiction is reported with a machine-readable code",
  badPlan.conflicts?.some((c) => c.code === "fstype_mismatch"),
  badPlan.conflicts?.map((c) => c.code).join(","),
);

const overlap = JSON.stringify({
  ...JSON.parse(plan),
  windows_end: JSON.parse(plan).installer_end,
});
const overlapping = await comparePlanAction.run({ probeJson: probe, planJson: overlap });
check("overlapping plan is rejected", overlapping.consistent === false);

console.log("\n=== 5. risk-summary ===");
const risk = await riskSummary.run({ probeJson: probe, planJson: plan });
check("returns a level and a message", typeof risk.level === "string" && typeof risk.message === "string", risk.headline);
check("nextStep is prose for a human", typeof risk.nextStep === "string" && risk.nextStep.length > 0, risk.nextStep);

const risky = await riskSummary.run({ probeJson: probe, planJson: contradicting });
check("contradicting plan escalates to dangerous", risky.level === "dangerous", risky.headline);

console.log("\n=== 6. registry (returning idiom, used by UI and CLI) ===");
for (const [name, action] of Object.entries(actionRegistry)) {
  check(`registry '${name}' is readOnly and not destructive`, action.readOnly === true && action.destructive === false);
}
const regBad = invoke(actionRegistry["load-probe"], { probeJson: 12345 });
check(
  "invoke() gates on the schema and returns ok:false for a non-string (never reaches run)",
  regBad.ok === false && regBad.value === null && regBad.errors.length > 0,
  regBad.errors[0],
);
const regSoft = actionRegistry["load-probe"].run({ probeJson: "{ not json" });
check(
  "run() returns ok:false rather than throwing, so the UI needs no try/catch",
  regSoft.ok === false && regSoft.probe === null && regSoft.errors.length > 0,
  regSoft.errors[0],
);

// Drift guard: the two surfaces must reach the same verdict on the same inputs.
const regCompare = actionRegistry["compare-plan"].run({ probeJson: probe, planJson: plan });
check(
  "registry and framework action agree on the consistent fixture",
  regCompare.ok === true && regCompare.comparison?.consistent === compared.consistent,
);
const regCompareBad = actionRegistry["compare-plan"].run({ probeJson: probe, planJson: contradicting });
check(
  "registry and framework action agree that the contradiction is rejected",
  regCompareBad.comparison?.consistent === badPlan.consistent,
);

console.log("\n=== 7. mutating phases are absent from this surface ===");
for (const phase of ["shrink", "stage", "boot", "windows", "secureboot"]) {
  check(`no action named '${phase}'`, actions[phase] === undefined);
  check(`no registry entry named '${phase}'`, actionRegistry[phase] === undefined);
}

console.log(failures === 0 ? "\nAll action smoke checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);