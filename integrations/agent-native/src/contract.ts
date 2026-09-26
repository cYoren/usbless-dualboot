/**
 * Contract types + zod schemas for the read-only usbless-dualboot companion.
 *
 * INVARIANT: everything in this file is a *description of user-supplied text*.
 * Nothing here reads the host disk, touches /dev, shells out, or opens a socket.
 *
 * The probe schema mirrors the exact JSON emitted by `usbless-dualboot probe --json`
 * (see lib/probe.sh) and the plan schema mirrors `usbless-dualboot plan --json`
 * (see lib/plan.sh). Values that the bash tool emits as strings are typed as
 * strings here on purpose — loosening them to numbers would silently accept a
 * probe the real CLI never produces.
 */
import { z } from "zod";

/** Fields `probe --json` always emits, in order, per lib/probe.sh. */
export const probeSchema = z.object({
  uefi: z.enum(["yes", "no"]).describe("Detected firmware type (probe: /sys/firmware/efi present)"),
  tpm2: z.enum(["yes", "no"]).describe("TPM 2.0 device detected (probe: /dev/tpm*)"),
  secure_boot: z
    .enum(["enabled", "disabled", "unknown"])
    .describe("Secure Boot efivar state (probe: SecureBoot-* efivar)"),
  setup_mode: z
    .enum(["enabled", "disabled", "unknown"])
    .describe("Setup Mode efivar state; 'enabled' is required before secureboot --enroll"),
  bootloader: z
    .string()
    .min(1)
    .describe("Detected bootloader, e.g. limine | systemd-boot | grub | unknown | '<x> (inferred)'"),
  root_source: z.string().describe("Root filesystem source device or mapper path"),
  root_fstype: z.string().describe("Root filesystem type, e.g. btrfs | ext4 | xfs"),
  encryption: z.enum(["no", "luks"]).describe("LUKS encryption detected on any block device"),
  lsblk: z
    .object({ blockdevices: z.array(z.record(z.string(), z.unknown())) })
    .loose()
    .describe("Raw `lsblk -J` document, passed through unchanged"),
});

export type Probe = z.infer<typeof probeSchema>;

const sectorsStr = z.string().regex(/^\d+$/, "must be a decimal sector count (the CLI emits strings)");

/** The plan/config document written by `plan --write` (see examples/config.example.json). */
export const planSchema = z
  .object({
    plan_id: z.string().optional().describe("sha256 plan identity hash, present only in `plan --json` output"),
    direction: z.enum(["add-windows", "add-linux"]).describe("Which OS is being added"),
    disk: z.string().describe("Target disk, e.g. /dev/nvme0n1"),
    disk_sectors: sectorsStr,
    disk_guid: z.string().optional(),
    linux_part: z.string().describe("Existing Linux partition device"),
    linux_part_start: sectorsStr.optional(),
    linux_part_sectors: sectorsStr.optional(),
    linux_partuuid: z.string().optional(),
    linux_mapper: z.string().optional().describe("LUKS mapper name when root is encrypted"),
    linux_fstype: z.string().describe("Filesystem on the Linux partition; online shrink needs btrfs"),
    luks_offset_sectors: sectorsStr.optional(),
    esp_part: z.string().optional(),
    esp_mount: z.string().optional(),
    bootloader: z.string().optional(),
    linux_new_size: z.string().optional().describe("Requested size after shrink, e.g. 1526G"),
    linux_new_fs_sectors: sectorsStr.optional(),
    linux_new_part_sectors: sectorsStr.optional(),
    linux_new_end: sectorsStr.optional(),
    installer_size: z.string().describe("FAT32 installer partition size, e.g. 12G"),
    installer_start: sectorsStr,
    installer_end: sectorsStr,
    windows_start: sectorsStr.optional(),
    windows_end: sectorsStr.optional(),
    target_os_gib: sectorsStr.optional(),
    online_shrink_supported: z.boolean().optional(),
    iso: z.string().describe("Installer ISO path (existence is checked by the CLI, not by us)"),
  })
  .loose();

export type Plan = z.infer<typeof planSchema>;

/** A sector range on one disk. `end` is inclusive, matching sfdisk/native units. */
export interface SectorRange {
  readonly start: number;
  readonly end: number;
}

export function toSectorRange(start: string | undefined, end: string | undefined): SectorRange | null {
  if (start === undefined || end === undefined || start === "" || end === "") return null;
  const s = Number(start);
  const e = Number(end);
  if (!Number.isSafeInteger(s) || !Number.isSafeInteger(e)) return null;
  return { start: s, end: e };
}

export function rangesOverlap(a: SectorRange, b: SectorRange): boolean {
  return a.start <= b.end && b.start <= a.end;
}

export function rangeLabel(r: SectorRange): string {
  return `${r.start}..${r.end}`;
}

/** Everything the companion ever emits is plain JSON-serializable data. */
export type RiskLevel = "info" | "note" | "warning" | "dangerous";

export interface Finding {
  readonly level: RiskLevel;
  readonly code: string;
  readonly message: string;
}