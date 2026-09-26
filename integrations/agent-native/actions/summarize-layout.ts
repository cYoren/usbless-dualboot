/**
 * summarize-layout — human-readable summary of a validated probe.
 * Pure wrapper over `summarizeProbe`; no I/O, no host access.
 */
import { defineAction, fail } from "@agent-native/core/action";
import { z } from "zod";

import { loadProbe, summarizeProbe } from "../src/core.ts";

export default defineAction({
  description:
    "Summarize the layout a usbless-dualboot probe detected: firmware, Secure Boot, encryption, bootloader, root filesystem, and the block devices. Read-only, operates only on the supplied probe JSON.",
  schema: z.object({
    probeJson: z.string().describe("Text of a `usbless-dualboot probe --json` document."),
  }),
  http: false,
  readOnly: true,
  run: async ({ probeJson }) => {
    const result = loadProbe(probeJson);
    if (!result.ok || result.value === null) {
      fail(`Cannot summarize: ${result.errors.join("; ")}`, {
        errorCode: "invalid_probe",
        statusCode: 422,
      });
    }
    const summary = summarizeProbe(result.value!);
    return { summary, message: `${summary.firmware}; root ${summary.root}; bootloader ${summary.bootloader}.` };
  },
});