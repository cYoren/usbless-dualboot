/**
 * Minimal HUMAN UI for the companion.
 *
 * Inputs are user-supplied files only: the browser File API reads a probe JSON and
 * (optionally) a plan JSON that the human chooses from their own machine. Nothing
 * is fetched, nothing is discovered, no port is opened, no server is started.
 *
 * There is no button, link, or code path here that runs a CLI phase. The action
 * registry it calls has `destructive: false` baked into the type.
 *
 * SECURITY: every value interpolated into HTML goes through `h()` (escapeHtml).
 * Finding messages and zod error strings embed probe/plan-derived text (device
 * names, fstypes), so they are treated as untrusted even though the source file is
 * the user's own. `innerHTML` here is therefore only ever fed escaped data.
 */
import {
  actionRegistry,
  describeRegistry,
  type RiskSummaryOutput,
  type SummarizeLayoutOutput,
} from "./registry.ts";
import type { Plan, Probe, Finding } from "./core.ts";

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (el === null) throw new Error(`missing element #${id}`);
  return el as T;
};

/** Escape any value destined for innerHTML. */
function h(value: unknown): string {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const readFile = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result ?? ""));
    r.onerror = () => reject(new Error(`could not read ${file.name}`));
    r.readAsText(file);
  });

const levelClass: Record<Finding["level"], string> = {
  info: "lvl-info",
  note: "lvl-note",
  warning: "lvl-warning",
  dangerous: "lvl-dangerous",
};

const errorList = (errors: readonly string[]): string =>
  `<ul>${errors.map((e) => `<li>${h(e)}</li>`).join("")}</ul>`;

function renderFindings(findings: readonly Finding[]): string {
  if (findings.length === 0) return `<p class="muted">No findings.</p>`;
  return `<ul class="findings">${findings
    .map(
      (f) =>
        `<li class="${levelClass[f.level]}"><span class="tag">${h(f.level)}</span> <code>${h(
          f.code,
        )}</code><div>${h(f.message)}</div></li>`,
    )
    .join("")}</ul>`;
}

function renderLayout(out: SummarizeLayoutOutput): string {
  if (!out.ok || out.summary === null) {
    return `<div class="reject"><h3>Probe rejected</h3>${errorList(out.errors)}</div>`;
  }
  const s = out.summary;
  return `<table class="kv">
    <tr><th>Firmware</th><td>${h(s.firmware)}</td></tr>
    <tr><th>Secure Boot</th><td>${h(s.secureBoot)} (Setup Mode: ${h(s.setupMode)})</td></tr>
    <tr><th>TPM 2.0</th><td>${h(s.tpm2)}</td></tr>
    <tr><th>Root</th><td>${h(s.root)}</td></tr>
    <tr><th>Encryption</th><td>${h(s.encryption)}</td></tr>
    <tr><th>Bootloader</th><td>${h(s.bootloader)}</td></tr>
    <tr><th>Disks</th><td>${h(s.diskCount)} (${h(s.disks.length)} block device entr${s.disks.length === 1 ? "y" : "ies"})</td></tr>
  </table>`;
}

function renderRisk(out: RiskSummaryOutput): string {
  if (!out.ok || out.level === null) {
    return `<div class="reject"><h3>Cannot assess</h3>${errorList(out.errors)}</div>`;
  }
  return `<div class="risk ${levelClass[out.level]}">
    <h3>${h(out.headline)}</h3>
    <p class="next">${h(out.nextStep)}</p>
  </div>${renderFindings(out.findings)}`;
}

async function refresh(): Promise<void> {
  const probeInput = $<HTMLInputElement>("probe-file");
  const planInput = $<HTMLInputElement>("plan-file");
  const status = $("status");
  const probeOut = $("probe-out");
  const planOut = $("plan-out");
  const riskOut = $("risk-out");

  const probeFile = probeInput.files?.[0];
  if (probeFile === undefined) {
    status.textContent = "Select a probe JSON file to begin.";
    probeOut.textContent = "";
    planOut.textContent = "";
    riskOut.textContent = "";
    return;
  }
  status.textContent = `Loaded ${probeFile.name}`;
  const probeJson = await readFile(probeFile);

  const planFile = planInput.files?.[0];
  const planJson = planFile === undefined ? undefined : await readFile(planFile);

  const look = actionRegistry["summarize-layout"].run({ probeJson });
  probeOut.innerHTML = renderLayout(look);

  if (!look.ok || look.summary === null) {
    planOut.innerHTML = `<p class="muted">Plan comparison skipped: probe did not validate.</p>`;
    riskOut.innerHTML = `<p class="muted">Risk summary skipped: probe did not validate.</p>`;
    return;
  }

  if (planJson !== undefined) {
    const cmp = actionRegistry["compare-plan"].run({ probeJson, planJson });
    if (cmp.ok && cmp.comparison !== null) {
      const c = cmp.comparison;
      planOut.innerHTML = `<div class="verdict ${c.consistent ? "lvl-info" : "lvl-dangerous"}">
          <h3>${
            c.consistent
              ? "Plan consistent with probe"
              : `Plan rejected: ${h(c.conflicts.length)} contradiction(s)`
          }</h3>
        </div>
        <h4>Conflicts</h4>${renderFindings(c.conflicts)}
        <h4>Notes</h4>${renderFindings(c.notes)}
        <h4>Phase order the CLI documents</h4>
        <ol class="phases">${c.phaseOrder.map((p) => `<li><code>${h(p)}</code></li>`).join("")}</ol>`;
    } else {
      planOut.innerHTML = `<div class="reject"><h3>Plan rejected (malformed)</h3>${errorList(cmp.errors)}</div>`;
    }
  } else {
    planOut.innerHTML = `<p class="muted">No plan file selected — pick one to compare. Only the probe-derived findings below apply.</p>`;
  }

  const risk = actionRegistry["risk-summary"].run({
    probeJson,
    ...(planJson === undefined ? {} : { planJson }),
  });
  riskOut.innerHTML = renderRisk(risk);
}

function renderRegistry(): void {
  const tbody = document.querySelector("#registry-table tbody");
  if (tbody === null) return;
  tbody.innerHTML = describeRegistry()
    .map(
      (a) =>
        `<tr><td><code>${h(a.name)}</code></td><td>${a.readOnly ? "yes" : "NO"}</td><td>${
          a.destructive ? "YES" : "no"
        }</td><td>${a.runIsAsync ? "async" : "pure sync"}</td></tr>`,
    )
    .join("");
}

document.addEventListener("DOMContentLoaded", () => {
  renderRegistry();
  $<HTMLInputElement>("probe-file").addEventListener("change", () => void refresh());
  $<HTMLInputElement>("plan-file").addEventListener("change", () => void refresh());
  void refresh();
});

// Exported only so the bundler keeps the module graph and a test can import it.
export type { Probe, Plan };