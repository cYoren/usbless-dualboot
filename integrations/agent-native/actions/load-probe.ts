/**
 * load-probe — validate a user-supplied `usbless-dualboot probe --json` document.
 *
 * READ-ONLY BY CONSTRUCTION:
 *  - input is a JSON string/object the caller pasted or uploaded; nothing is read
 *    from the host filesystem unless the *caller* (an app route) already read it.
 *  - `http: false` disables the framework's auto-mounted HTTP endpoint for this
 *    action, so no such endpoint exists to call.
 *  - `readOnly: true` marks it non-mutating (no poll-refresh, no write audit).
 */
import { defineAction, fail } from "@agent-native/core/action";
import { z } from "zod";

import { loadProbe } from "../src/core.ts";

export default defineAction({
  description:
    "Validate a usbless-dualboot probe document (JSON) supplied by the user. Read-only: accepts the probe JSON text, returns whether it is a well-formed probe and the parsed fields. Performs no host discovery.",
  schema: z.object({
    probeJson: z
      .string()
      .describe("The full text of a `usbless-dualboot probe --json` document, or any JSON object to validate."),
  }),
  http: false,
  readOnly: true,
  run: async ({ probeJson }) => {
    const result = loadProbe(probeJson);
    if (!result.ok || result.value === null) {
      // fail() is agent-native's ActionContractError path: the message reaches the caller.
      fail(`Not a valid usbless-dualboot probe: ${result.errors.join("; ")}`, {
        errorCode: "invalid_probe",
        statusCode: 422,
        details: { errors: result.errors },
      });
    }
    return {
      ok: true,
      probe: result.value,
      message: `Probe accepted: ${result.value!.root_fstype} root on ${result.value!.root_source}, bootloader ${result.value!.bootloader}.`,
    };
  },
});