/**
 * Pure functions for the usbless-dualboot companion.
 *
 * Every export here is referentially transparent: same input -> same output,
 * no I/O, no clock, no environment reads, no randomness. `registry.ts` is the
 * thin agent-native layer over these; the tests exercise these directly.
 */
import { z } from "zod";
import {
  type Finding,
  type Plan,
  type Probe,
  probeSchema,
  planSchema,
  toSectorRange,
  rangeLabel,
  rangesOverlap,
} from "./contract.ts";

export interface LoadResult {
  readonly ok: boolean;
  readonly errors: readonly string[];
}

export interface ProbeLoadResult extends LoadResult {
  readonly value: Probe | null;
}

export interface PlanLoadResult extends LoadResult {
  readonly value: Plan | null;
}

function parseJson(input: unknown): { ok: true; raw: unknown } | { ok: false; error: string } {
  if (typeof input !== "string") return { ok: true, raw: input };
  try {
    return { ok: true, raw: JSON.parse(input) };
  } catch (err) {
    return { ok: false, error: `not valid JSON: ${(err as Error).message}` };
  }
}

/**
 * Parse + validate a probe document. Accepts either a JSON string (as read from
 * a file the user selected) or an already-parsed object. Rejects anything that
 * is not a well-formed `probe --json` document.
 */
export function loadProbe(input: unknown): ProbeLoadResult {
  const j = parseJson(input);
  if (!j.ok) return { ok: false, value: null, errors: [j.error] };
  const parsed = probeSchema.safeParse(j.raw);
  if (!parsed.success) {
    return {
      ok: false,
      value: null,
      errors: parsed.error.issues.map(
        (i: { path: PropertyKey[]; message: string }) => `${i.path.join(".") || "<root>"}: ${i.message}`,
      ),
    };
  }
  return { ok: true, value: parsed.data, errors: [] };
}

/** Parse + validate a plan/config document, same contract as `loadProbe`. */
export function loadPlan(input: unknown): PlanLoadResult {
  const j = parseJson(input);
  if (!j.ok) return { ok: false, value: null, errors: [j.error] };
  const parsed = planSchema.safeParse(j.raw);
  if (!parsed.success) {
    return {
      ok: false,
      value: null,
      errors: parsed.error.issues.map(
        (i: { path: PropertyKey[]; message: string }) => `${i.path.join(".") || "<root>"}: ${i.message}`,
      ),
    };
  }
  return { ok: true, value: parsed.data, errors: [] };
}

export interface LayoutSummary {
  readonly firmware: string;
  readonly secureBoot: string;
  readonly setupMode: string;
  readonly tpm2: string;
  readonly encryption: string;
  readonly bootloader: string;
  readonly root: string;
  readonly diskCount: number;
  readonly disks: readonly { readonly name: string; readonly size: string; readonly type: string }[];
}

const str = (v: unknown): string => (typeof v === "string" ? v : v === undefined ? "" : String(v));

/** Human-readable summary of what the probe detected. Pure. */
export function summarizeProbe(probe: Probe): LayoutSummary {
  const devices = probe.lsblk.blockdevices ?? [];
  const disks = devices.map((d: Record<string, unknown>) => ({
    name: str(d["name"]),
    size: str(d["size"]),
    type: str(d["type"]),
  }));
  return {
    firmware: probe.uefi === "yes" ? "UEFI" : "legacy BIOS (unsupported by this flow)",
    secureBoot: probe.secure_boot,
    setupMode: probe.setup_mode,
    tpm2: probe.tpm2,
    encryption: probe.encryption === "luks" ? "LUKS-encrypted root" : "unencrypted",
    bootloader: probe.bootloader,
    root: `${probe.root_source || "?"} (${probe.root_fstype || "?"})`,
    diskCount: disks.filter((d) => d.type === "disk").length,
    disks,
  };
}

/** Findings about the probed host alone — no plan involved. Pure. */
export function reviewProbe(probe: Probe): Finding[] {
  const out: Finding[] = [];
  if (probe.uefi !== "yes") {
    out.push({
      level: "dangerous",
      code: "not_uefi",
      message:
        "Host is not booted in UEFI mode. The stage/boot/secureboot phases assume UEFI + GPT; this host is out of scope.",
    });
  }
  if (probe.secure_boot === "enabled" && probe.setup_mode !== "enabled") {
    out.push({
      level: "warning",
      code: "secure_boot_enabled",
      message:
        "Secure Boot is enabled and firmware is not in Setup Mode, so 'secureboot --enroll' cannot run yet. Unsigned Linux loaders will be blocked until keys are enrolled in firmware.",
    });
  }
  if (probe.setup_mode === "enabled") {
    out.push({
      level: "note",
      code: "setup_mode_enabled",
      message:
        "Firmware is in Setup Mode: the only window in which 'secureboot --enroll' can install custom keys. Enrolling rewrites firmware key state and cannot be done from this companion.",
    });
  }
  if (probe.encryption === "luks") {
    out.push({
      level: "note",
      code: "luks_root",
      message:
        "Encrypted root detected. Shrinking applies to the LUKS container, and the plan must account for the LUKS2 header offset.",
    });
  }
  if (!/btrfs/i.test(probe.root_fstype)) {
    out.push({
      level: "warning",
      code: "offline_shrink_required",
      message: `Root filesystem is '${probe.root_fstype || "unknown"}'. Online shrink is only supported for btrfs, so the shrink phase must run from an offline live environment instead.`,
    });
  } else {
    out.push({
      level: "info",
      code: "online_shrink_available",
      message: "Root is btrfs: the shrink phase can run online, before any reboot.",
    });
  }
  if (probe.tpm2 === "no") {
    out.push({
      level: "info",
      code: "no_tpm",
      message: "No TPM 2.0 device detected; no TPM-backed key sealing is possible on this host.",
    });
  }
  return out;
}

export interface PlanComparison {
  readonly consistent: boolean;
  readonly conflicts: readonly Finding[];
  readonly notes: readonly Finding[];
  readonly phaseOrder: readonly string[];
}

/**
 * Compare a proposed plan against a probe document.
 *
 * Two categories, deliberately separated:
 *  - `conflicts` = the plan contradicts the probe, or is internally inconsistent.
 *  - `notes`     = true observations needing a human, but not contradictions.
 *
 * Any conflict makes `consistent === false`, which means the plan must not be
 * handed to the CLI's mutating phases.
 */
export function comparePlanToProbe(probe: Probe, plan: Plan): PlanComparison {
  const conflicts: Finding[] = [];
  const notes: Finding[] = [];

  // 1. Firmware capability vs. plan direction.
  if (plan.direction === "add-windows" && probe.uefi !== "yes") {
    conflicts.push({
      level: "dangerous",
      code: "plan_needs_uefi",
      message: `Plan direction '${plan.direction}' requires UEFI firmware, but the probe reports uefi='${probe.uefi}'.`,
    });
  }

  // 2. Root filesystem type must agree between probe and plan.
  if (plan.linux_fstype !== probe.root_fstype) {
    conflicts.push({
      level: "dangerous",
      code: "fstype_mismatch",
      message: `Plan says the Linux filesystem is '${plan.linux_fstype}' but the probe reports '${probe.root_fstype}'. Either the probe is stale or the plan targets a different partition.`,
    });
  }

  // 3. Plan is anchored to a partition device; the probe says which one is root.
  //    When root is a LUKS mapper path the underlying partition is not literally in
  //    root_source, so it is resolved from the probe's own lsblk document instead.
  const mapperName = /^\/dev\/mapper\/(.+)$/.exec(probe.root_source)?.[1] ?? "";
  const probedRootPart = mapperName !== "" ? luksPartitionOf(probe) : rootPartitionOf(probe.root_source);
  if (mapperName !== "" && plan.linux_mapper !== undefined && plan.linux_mapper !== "" && plan.linux_mapper !== mapperName) {
    conflicts.push({
      level: "dangerous",
      code: "mapper_mismatch",
      message: `Plan shrinks the LUKS mapper '${plan.linux_mapper}', but the probe's root source is mapper '${mapperName}'.`,
    });
  }
  if (probedRootPart !== "" && plan.linux_part !== "" && plan.linux_part !== probedRootPart) {
    conflicts.push({
      level: "dangerous",
      code: "linux_part_mismatch",
      message: `Plan shrinks ${plan.linux_part}, but the probe's root is backed by ${probedRootPart}. Shrinking a partition that does not back the probed root is a destructive mismatch.`,
    });
  } else if (probedRootPart === "" && mapperName !== "" && plan.linux_part !== "") {
    notes.push({
      level: "warning",
      code: "root_partition_unresolved",
      message:
        "Probe reports an encrypted root on a mapper path and its lsblk document shows no crypto_LUKS partition, so the partition backing the root cannot be confirmed. Verify it manually before shrinking.",
    });
  }

  // 4. Encryption vs. LUKS offset accounting.
  const luksOffset = Number(plan.luks_offset_sectors ?? "0");
  if (probe.encryption === "luks" && luksOffset === 0) {
    conflicts.push({
      level: "dangerous",
      code: "missing_luks_offset",
      message:
        "Probe reports an encrypted (LUKS) root, but the plan carries no luks_offset_sectors. Shrinking without the LUKS2 payload offset corrupts the container.",
    });
  } else if (probe.encryption === "luks") {
    notes.push({
      level: "info",
      code: "luks_offset_present",
      message: `Plan accounts for a LUKS payload offset of ${luksOffset} sectors.`,
    });
  } else if (luksOffset > 0) {
    conflicts.push({
      level: "warning",
      code: "unexpected_luks_offset",
      message: "Plan reserves a LUKS payload offset, but the probe found no LUKS container on this host.",
    });
  }

  // 5. Installer geometry: sanity and containment inside the plan's own disk.
  const installer = toSectorRange(plan.installer_start, plan.installer_end);
  const diskSectors = Number(plan.disk_sectors);
  if (installer === null) {
    conflicts.push({
      level: "dangerous",
      code: "installer_range_unparseable",
      message: `Plan installer range is not a valid sector range (${plan.installer_start}..${plan.installer_end}).`,
    });
  } else {
    if (installer.start > installer.end) {
      conflicts.push({
        level: "dangerous",
        code: "installer_inverted",
        message: `Plan installer start ${installer.start} is greater than its end ${installer.end}.`,
      });
    }
    if (Number.isSafeInteger(diskSectors) && diskSectors > 0 && installer.end >= diskSectors) {
      conflicts.push({
        level: "dangerous",
        code: "installer_past_disk_end",
        message: `Plan installer partition ends at sector ${installer.end}, at or past the disk end recorded in the plan (last sector ${diskSectors - 1}).`,
      });
    }
  }

  // 6. Region overlap: target OS vs. installer vs. shrunk Linux.
  const linuxNew = toSectorRange(plan.linux_part_start, plan.linux_new_end);
  const targetOs = toSectorRange(plan.windows_start, plan.windows_end);
  if (targetOs !== null) {
    if (installer !== null && rangesOverlap(targetOs, installer)) {
      conflicts.push({
        level: "dangerous",
        code: "target_overlaps_installer",
        message: `Target-OS region ${rangeLabel(targetOs)} overlaps the installer partition ${rangeLabel(installer)}. Overlapping partitions would destroy the staged installer.`,
      });
    }
    if (linuxNew !== null && rangesOverlap(targetOs, linuxNew)) {
      conflicts.push({
        level: "dangerous",
        code: "target_overlaps_linux",
        message: `Target-OS region ${rangeLabel(targetOs)} overlaps the shrunk Linux partition ${rangeLabel(linuxNew)}. This would overwrite the live Linux filesystem.`,
      });
    }
  } else if (plan.linux_new_size !== undefined && plan.linux_new_size !== "") {
    notes.push({
      level: "warning",
      code: "target_region_unset",
      message:
        "Plan requests a Linux shrink but records no target-OS sector range, so no space is actually being carved out for the second OS.",
    });
  }

  // 7. Internal arithmetic: linux_part_start + linux_new_part_sectors - 1 == linux_new_end.
  if (
    plan.linux_new_end !== undefined &&
    plan.linux_new_part_sectors !== undefined &&
    plan.linux_part_start !== undefined
  ) {
    const expectedEnd = Number(plan.linux_part_start) + Number(plan.linux_new_part_sectors) - 1;
    if (Number.isSafeInteger(expectedEnd) && expectedEnd !== Number(plan.linux_new_end)) {
      conflicts.push({
        level: "dangerous",
        code: "linux_new_end_inconsistent",
        message: `Plan linux_new_end=${plan.linux_new_end} does not equal linux_part_start + linux_new_part_sectors - 1 = ${expectedEnd}. The plan's own arithmetic disagrees with itself.`,
      });
    }
    if (numberOr(plan.linux_new_part_sectors) < numberOr(plan.linux_new_fs_sectors)) {
      conflicts.push({
        level: "dangerous",
        code: "partition_smaller_than_fs",
        message: `Plan's post-shrink partition (${plan.linux_new_part_sectors} sectors) is smaller than the filesystem it must hold (${plan.linux_new_fs_sectors} sectors). The shrink would truncate live data.`,
      });
    }
  }

  // 8. A shrink that does not shrink.
  if (plan.linux_new_part_sectors !== undefined && plan.linux_part_sectors !== undefined) {
    const before = numberOr(plan.linux_part_sectors);
    const after = numberOr(plan.linux_new_part_sectors);
    if (after >= before) {
      conflicts.push({
        level: "warning",
        code: "shrink_not_smaller",
        message: `Plan's post-shrink partition (${after} sectors) is not smaller than the current partition (${before} sectors); the plan frees no space.`,
      });
    }
  }

  // 9. Bootloader path: the plan must agree with what the probe found.
  if (plan.bootloader !== undefined && plan.bootloader !== "" && plan.bootloader !== probe.bootloader) {
    conflicts.push({
      level: "dangerous",
      code: "bootloader_mismatch",
      message: `Plan targets bootloader '${plan.bootloader}' but the probe detected '${probe.bootloader}'. The windows --add phase writes into the bootloader the probe found.`,
    });
  }

  // 10. ESP referenced by the plan should appear in the probe's lsblk document.
  if (plan.esp_part !== undefined && plan.esp_part !== "" && plan.esp_mount !== undefined && plan.esp_mount !== "") {
    const probeMentionsEsp = JSON.stringify(probe.lsblk).includes(plan.esp_part);
    if (!probeMentionsEsp) {
      notes.push({
        level: "note",
        code: "esp_not_in_probe",
        message: `Plan references ESP ${plan.esp_part} mounted at ${plan.esp_mount}, which the probe's lsblk output does not mention. Confirm the ESP before the boot/windows phases.`,
      });
    }
  }

  // 11. Unused gap between the target-OS region and the installer partition.
  if (installer !== null && targetOs !== null && targetOs.end !== installer.start - 1) {
    const gap = installer.start - 1 - targetOs.end;
    if (gap > 0) {
      notes.push({
        level: "note",
        code: "gap_before_installer",
        message: `Target-OS region ends at sector ${targetOs.end} but the installer starts at ${installer.start}; ${gap} sector(s) sit unused between them.`,
      });
    }
  }

  return {
    consistent: conflicts.length === 0,
    conflicts,
    notes,
    phaseOrder: phaseOrderFor(plan.direction),
  };
}

const numberOr = (s: string | undefined): number => (s === undefined || s === "" ? 0 : Number(s));

/** The canonical phase order the CLI documents, per direction. */
export function phaseOrderFor(direction: Plan["direction"]): readonly string[] {
  if (direction === "add-windows") {
    return [
      "probe",
      "plan --write",
      "shrink",
      "reboot",
      "stage",
      "boot --installer",
      "(install target OS)",
      "boot --restore",
      "windows --add",
      "secureboot",
    ];
  }
  return [
    "probe",
    "plan --write",
    "shrink",
    "reboot",
    "stage --os linux",
    "boot --installer",
    "(install target OS)",
    "boot --restore",
    "windows --add",
    "secureboot",
  ];
}

/** Derive the partition device behind `root_source`, handling LUKS mapper paths. */
export function rootPartitionOf(rootSource: string): string {
  if (rootSource === "") return "";
  const src = rootSource.replace(/\[.*$/, "");
  // A mapper path hides the underlying partition; the probe alone cannot resolve it.
  if (src.startsWith("/dev/mapper/")) return "";
  return src;
}

/**
 * Find the partition carrying the LUKS container in the probe's own lsblk output.
 * Pure traversal of the supplied document — no device is opened. Returns "" when
 * zero or multiple candidates exist, because an ambiguous root must not be guessed.
 */
export function luksPartitionOf(probe: Probe): string {
  const found: string[] = [];
  const walk = (nodes: readonly Record<string, unknown>[] | undefined): void => {
    if (!Array.isArray(nodes)) return;
    for (const n of nodes) {
      const fstype = typeof n["fstype"] === "string" ? (n["fstype"] as string) : "";
      if (fstype.toLowerCase() === "crypto_luks") {
        const p = typeof n["path"] === "string" ? (n["path"] as string) : `/dev/${String(n["name"] ?? "")}`;
        found.push(p);
      }
      walk(n["children"] as readonly Record<string, unknown>[] | undefined);
    }
  };
  walk(probe.lsblk.blockdevices);
  return found.length === 1 ? (found[0] as string) : "";
}

/**
 * Overall assessment + the next human step. Never returns an instruction to run
 * a mutating phase without explicitly flagging it as destructive.
 */
export function assessRisk(
  probe: Probe,
  plan: Plan | null,
): {
  readonly level: Level;
  readonly headline: string;
  readonly findings: readonly Finding[];
  readonly nextStep: string;
  readonly destructivePhasesNotRunnable: readonly string[];
} {
  const findings: Finding[] = [...reviewProbe(probe)];
  if (plan !== null) {
    const cmp = comparePlanToProbe(probe, plan);
    findings.push(...cmp.conflicts, ...cmp.notes);
  }
  const order: Level[] = ["info", "note", "warning", "dangerous"];
  const level = findings.reduce<Level>(
    (acc, f) => (order.indexOf(f.level) > order.indexOf(acc) ? f.level : acc),
    "info",
  );
  const blockers = findings.filter((f) => f.level === "dangerous").length;
  const headline =
    level === "dangerous"
      ? `Blocked: ${blockers} contradiction(s) between the probe and the proposed plan.`
      : level === "warning"
        ? "Review required before the plan is trusted."
        : "No contradictions found between the probe and this plan.";

  const nextStep =
    plan === null
      ? "Next: on the probed host run " +
        "'usbless-dualboot plan --iso <Windows.iso> --windows-size <size> --json --dry-run', " +
        "then submit that plan here for comparison. This companion executes nothing."
      : level === "dangerous"
        ? "Next: correct the plan inputs and re-run 'usbless-dualboot plan ... --json'. Do not run shrink or stage against a self-contradicting plan."
        : "Next (DESTRUCTIVE — must be run manually in a terminal, not from here): " +
          "'sudo usbless-dualboot shrink --dry-run' first, then the real shrink with --confirm-plan <plan_id> " +
          "after AC power, btrfs scrub, and backup checks.";

  return { level, headline, findings, nextStep, destructivePhasesNotRunnable: DESTRUCTIVE_PHASES };
}

export type Level = Finding["level"];

/** The mutating phases. The companion never wraps, spawns, or proxies these. */
export const DESTRUCTIVE_PHASES = ["shrink", "stage", "boot", "windows", "secureboot"] as const;
export type DestructivePhase = (typeof DESTRUCTIVE_PHASES)[number];

export { probeSchema, planSchema, z };
export type { Finding, Plan, Probe } from "./contract.ts";