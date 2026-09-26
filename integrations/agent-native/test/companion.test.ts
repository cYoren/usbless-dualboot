/**
 * Contract tests for the read-only companion.
 *
 * Required assertions (from the integration brief):
 *   1. valid probe accepted
 *   2. malformed / unsupported probe rejected
 *   3. plan that overlaps or contradicts the probe rejected
 *   4. destructive action not representable / not executable from the companion
 *
 * Run: npm test   (node --experimental-strip-types --test)
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { loadProbe, loadPlan, summarizeProbe, comparePlanToProbe, assessRisk } from "../src/core.ts";
import { actionRegistry, describeRegistry, invoke } from "../src/registry.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = (name: string): string => readFileSync(path.join(here, "..", "fixtures", name), "utf8");

const PROBE = fixture("demo-probe.json");
const PLAN = fixture("demo-plan.json");

// ---------------------------------------------------------------- 1. accepted

describe("valid probe accepted", () => {
  test("fixture probe parses and validates", () => {
    const r = loadProbe(PROBE);
    assert.equal(r.ok, true, r.errors.join("; "));
    assert.equal(r.value?.uefi, "yes");
    assert.equal(r.value?.root_fstype, "btrfs");
    assert.equal(r.value?.encryption, "luks");
    assert.equal(r.value?.bootloader, "limine");
    assert.equal(r.errors.length, 0);
  });

  test("accepts an already-parsed object as well as a string", () => {
    const obj = JSON.parse(PROBE);
    const r = loadProbe(obj);
    assert.equal(r.ok, true, r.errors.join("; "));
    assert.deepEqual(r.value, loadProbe(PROBE).value);
  });

  test("summarizes the detected layout", () => {
    const probe = loadProbe(PROBE).value!;
    const s = summarizeProbe(probe);
    assert.equal(s.firmware, "UEFI");
    assert.equal(s.encryption, "LUKS-encrypted root");
    assert.equal(s.bootloader, "limine");
    assert.equal(s.diskCount, 1);
    assert.match(s.root, /btrfs/);
  });
});

// ---------------------------------------------------------------- 2. rejected

describe("malformed / unsupported probe rejected", () => {
  test("non-JSON text is rejected", () => {
    const r = loadProbe("not json at all {");
    assert.equal(r.ok, false);
    assert.equal(r.value, null);
    assert.match(r.errors.join(" "), /not valid JSON/);
  });

  test("missing required fields are rejected with their paths", () => {
    const r = loadProbe(JSON.stringify({ uefi: "yes", tpm2: "yes" }));
    assert.equal(r.ok, false);
    const joined = r.errors.join(" ");
    assert.match(joined, /secure_boot/);
    assert.match(joined, /root_fstype/);
    assert.match(joined, /lsblk/);
  });

  test("an out-of-enum firmware or encryption value is rejected", () => {
    const bad = { ...JSON.parse(PROBE), encryption: "bitlocker" };
    const r = loadProbe(JSON.stringify(bad));
    assert.equal(r.ok, false);
    assert.match(r.errors.join(" "), /encryption/);
  });

  test("an unsupported (non-enum) uefi value is rejected", () => {
    const bad = { ...JSON.parse(PROBE), uefi: "maybe" };
    assert.equal(loadProbe(JSON.stringify(bad)).ok, false);
  });

  test("lsblk must be an object with a blockdevices array", () => {
    const bad = { ...JSON.parse(PROBE), lsblk: [] };
    assert.equal(loadProbe(JSON.stringify(bad)).ok, false);
  });

  test("accepts the free-form '(inferred)' bootloader form the real CLI emits", () => {
    // lib/probe.sh sets bootloader="limine (inferred; run with sudo to confirm)"
    // when it can only infer from a binary on PATH. This must NOT be rejected.
    const p = JSON.parse(PROBE);
    p.bootloader = "limine (inferred; run with sudo to confirm)";
    const r = loadProbe(JSON.stringify(p));
    assert.equal(r.ok, true, r.errors.join("; "));
    assert.match(summarizeProbe(r.value!).bootloader, /inferred/);
  });

  test("accepts a probe where sudo was unavailable and fields are unknown", () => {
    const p = JSON.parse(PROBE);
    p.secure_boot = "unknown";
    p.setup_mode = "unknown";
    p.root_fstype = "";
    p.root_source = "";
    const r = loadProbe(JSON.stringify(p));
    assert.equal(r.ok, true, r.errors.join("; "));
  });

  test("a plan missing direction/disk is rejected", () => {
    const r = loadPlan(JSON.stringify({ linux_part: "/dev/x" }));
    assert.equal(r.ok, false);
    assert.match(r.errors.join(" "), /direction|disk/);
  });

  test("non-numeric sector counts are rejected (the CLI emits strings)", () => {
    const bad = { ...JSON.parse(PLAN), installer_start: "3881863311 sectors" };
    assert.equal(loadPlan(JSON.stringify(bad)).ok, false);
  });
});

// ------------------------------------------------- 3. overlapping / contradicting

describe("plan that overlaps or contradicts the probe rejected", () => {
  test("the shipped fixture plan is accepted and consistent", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = loadPlan(PLAN).value!;
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, true, JSON.stringify(cmp.conflicts, null, 2));
    assert.equal(cmp.conflicts.length, 0);
  });

  test("target-OS region overlapping the installer partition is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, windows_end: loadPlan(PLAN).value!.installer_end };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "target_overlaps_installer"));
  });

  test("target-OS region overlapping the shrunk Linux partition is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const base = loadPlan(PLAN).value!;
    const plan = { ...base, windows_start: String(Number(base.linux_part_start) + 10) };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "target_overlaps_linux"));
  });

  test("plan targeting a different filesystem than the probe is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, linux_fstype: "ext4" };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "fstype_mismatch"));
  });

  test("plan shrinking a partition that is not the probed root is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, linux_part: "/dev/nvme0n1p7" };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "linux_part_mismatch"));
  });

  test("encrypted probe with a plan carrying no LUKS offset is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const p = loadPlan(PLAN).value!;
    const { luks_offset_sectors: _drop, ...plan } = p;
    const cmp = comparePlanToProbe(probe, plan as typeof p);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "missing_luks_offset"));
  });

  test("plan that contradicts the probed bootloader is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, bootloader: "grub" };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "bootloader_mismatch"));
  });

  test("plan whose own arithmetic is inconsistent is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, linux_new_end: "999999999" };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "linux_new_end_inconsistent"));
  });

  test("plan whose partition is smaller than its own filesystem is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const base = loadPlan(PLAN).value!;
    const plan = { ...base, linux_new_part_sectors: "1" };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "partition_smaller_than_fs"));
  });

  test("installer range past the end of the disk is rejected", () => {
    const probe = loadProbe(PROBE).value!;
    const base = loadPlan(PLAN).value!;
    const plan = { ...base, installer_end: String(Number(base.disk_sectors) + 5) };
    const cmp = comparePlanToProbe(probe, plan);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "installer_past_disk_end"));
  });

  test("a non-UEFI probe cannot be paired with an add-windows plan", () => {
    const probe = { ...loadProbe(PROBE).value!, uefi: "no" as const };
    const cmp = comparePlanToProbe(probe, loadPlan(PLAN).value!);
    assert.equal(cmp.consistent, false);
    assert.ok(cmp.conflicts.some((c) => c.code === "plan_needs_uefi"));
  });

  test("assessRisk blocks when the plan contradicts the probe", () => {
    const probe = loadProbe(PROBE).value!;
    const plan = { ...loadPlan(PLAN).value!, linux_fstype: "ext4" };
    const a = assessRisk(probe, plan);
    assert.equal(a.level, "dangerous");
    assert.match(a.headline, /Blocked/);
    assert.match(a.nextStep, /Do not run shrink/);
  });

  test("assessRisk on the consistent fixture warns it must be run manually", () => {
    const a = assessRisk(loadProbe(PROBE).value!, loadPlan(PLAN).value!);
    assert.notEqual(a.level, "dangerous");
    assert.match(a.nextStep, /DESTRUCTIVE/);
    assert.match(a.nextStep, /manually/);
  });
});

// ---------------------------------------------------- 4. destructive not reachable

describe("destructive action not representable or executable", () => {
  test("every registry entry is literally readOnly and non-destructive", () => {
    for (const a of Object.values(actionRegistry)) {
      assert.equal(a.readOnly, true, `${a.name} must be readOnly`);
      assert.equal(a.destructive, false, `${a.name} must not be destructive`);
    }
  });

  test("no registry entry has an async run() — a pure sync signature forbids I/O", () => {
    for (const d of describeRegistry()) {
      assert.equal(d.runIsAsync, false, `${d.name} must be a pure synchronous run()`);
    }
  });

  test("the registry does not expose any mutating CLI phase as an action name", () => {
    const names = Object.keys(actionRegistry);
    for (const phase of ["shrink", "stage", "boot", "windows", "secureboot"]) {
      assert.ok(!names.includes(phase), `mutating phase '${phase}' must not exist as an action`);
    }
    assert.deepEqual(names.sort(), ["compare-plan", "load-probe", "risk-summary", "summarize-layout"]);
  });

  test("invoking a destructive CLI command name through the registry fails", () => {
    for (const cmd of ["shrink", "stage", "boot", "windows", "secureboot"]) {
      assert.equal(
        (actionRegistry as Record<string, unknown>)[cmd],
        undefined,
        `'${cmd}' must not be callable via the registry`,
      );
    }
  });

  test("no source file in this package spawns a process or opens a socket", () => {
    const files = ["../src/core.ts", "../src/registry.ts", "../actions/load-probe.ts",
      "../actions/summarize-layout.ts", "../actions/compare-plan.ts", "../actions/risk-summary.ts"];
    // These tokens are an execution/network bridge wherever they appear, even inside
    // a string: this package has no legitimate use for any of them.
    const bridge =
      /child_process|execSync|spawnSync|execFile|\bspawn\(|\bfetch\(|XMLHttpRequest|WebSocket|net\.connect|createServer|\blisten\(|\brequire\(/;
    for (const f of files) {
      const src = readFileSync(path.join(here, f), "utf8");
      const m = bridge.exec(src);
      assert.equal(m, null, `${f} contains a forbidden execution/network bridge: ${m?.[0]}`);
    }
  });

  test("the pure layer imports no Node builtin and names no system tool", () => {
    // The strongest available mechanical proof of read-only-ness: core.ts, registry.ts
    // and every action are pure modules with zero Node imports, so they have no
    // filesystem, process, or network capability to misuse.
    const pure = [
      "../src/core.ts",
      "../src/registry.ts",
      "../actions/load-probe.ts",
      "../actions/summarize-layout.ts",
      "../actions/compare-plan.ts",
      "../actions/risk-summary.ts",
    ];
    for (const f of pure) {
      const src = readFileSync(path.join(here, f), "utf8");
      const nodeImport = /from\s+["']node:/.exec(src);
      assert.equal(nodeImport, null, `${f} must not import a Node builtin (found ${nodeImport?.[0]})`);
    }
    // System tools that would imply real disk/boot mutation must not be named at all.
    const tools = /efibootmgr|sfdisk|mkfs|btrfs\s+resize|resize2fs|sbctl|mokutil|parted|fdisk\b/i;
    for (const f of pure) {
      const m = tools.exec(readFileSync(path.join(here, f), "utf8"));
      assert.equal(m, null, `${f} names a mutating system tool: ${m?.[0]}`);
    }
  });

  test("the only subprocess-capable surface is the local runner, and it takes file paths", () => {
    // src/cli.ts reads files named on argv; it must not import an exec bridge.
    const src = readFileSync(path.join(here, "../src/cli.ts"), "utf8");
    assert.match(src, /readFileSync/);
    assert.equal(/child_process|execSync|\bspawn\(|execFile/.exec(src), null);
  });

  test("malformed input through invoke() never reaches run()", () => {
    const r = invoke(actionRegistry["load-probe"], { probeJson: 12345 });
    assert.equal(r.ok, false);
    assert.equal(r.value, null);
    assert.ok(r.errors.length > 0);
  });

  test("invoke() on a valid probe returns a plain JSON-serialisable result", () => {
    const r = invoke(actionRegistry["risk-summary"], { probeJson: PROBE, planJson: PLAN });
    assert.equal(r.ok, true);
    assert.doesNotThrow(() => JSON.parse(JSON.stringify(r.value)));
  });
});