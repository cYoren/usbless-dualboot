/**
 * compare-plan — compare a proposed plan config against a probe document.
 *
 * Read-only. Both inputs are user-supplied text. Returns conflicts (the plan
 * contradicts the probe or itself) and notes. It does NOT execute anything: the
 * CLI's mutating phases (shrink/stage/boot/windows/secureboot) are not reachable
 * from this action by construction — there is no spawn/exec call anywhere in this
 * package.
 */
import { defineAction, fail } from "@agent-native/core/action";
import { z } from "zod";

import { comparePlanToProbe, loadPlan, loadProbe } from "../src/core.ts";

export default defineAction({
  description:
    "Compare a proposed usbless-dualboot plan (JSON) against a probe document (JSON) and report conflicts and notes. Read-only; no commands are executed and no disk is touched.",
  schema: z.object({
    probeJson: z.string().describe("Text of a `usbless-dualboot probe --json` document."),
    planJson: z.string().describe("Text of a usbless-dualboot plan/config JSON document."),
  }),
  http: false,
  readOnly: true,
  run: async ({ probeJson, planJson }) => {
    const probe = loadProbe(probeJson);
    if (!probe.ok || probe.value === null) {
      fail(`Invalid probe: ${probe.errors.join("; ")}`, { errorCode: "invalid_probe", statusCode: 422 });
    }
    const plan = loadPlan(planJson);
    if (!plan.ok || plan.value === null) {
      fail(`Invalid plan: ${plan.errors.join("; ")}`, { errorCode: "invalid_plan", statusCode: 422 });
    }
    const comparison = comparePlanToProbe(probe.value!, plan.value!);
    return {
      ...comparison,
      message: comparison.consistent
        ? "Plan is consistent with the probe; no contradictions found."
        : `Plan rejected: ${comparison.conflicts.length} contradiction(s) with the probe.`,
    };
  },
});