/**
 * risk-summary — overall risk level, findings, and the next human step.
 *
 * Read-only. The returned `nextStep` may mention a destructive CLI phase, but it
 * is prose for a human: this action cannot run it. See test/companion.test.ts,
 * which asserts that no execution surface exists in this package.
 */
import { defineAction, fail } from "@agent-native/core/action";
import { z } from "zod";

import { assessRisk, loadPlan, loadProbe } from "../src/core.ts";

export default defineAction({
  description:
    "Produce a human-readable risk and next-step summary for a usbless-dualboot host, from a probe document and optionally a proposed plan. Read-only.",
  schema: z.object({
    probeJson: z.string().describe("Text of a `usbless-dualboot probe --json` document."),
    planJson: z
      .string()
      .optional()
      .describe("Optional text of a usbless-dualboot plan/config JSON document."),
  }),
  http: false,
  readOnly: true,
  run: async ({ probeJson, planJson }) => {
    const probe = loadProbe(probeJson);
    if (!probe.ok || probe.value === null) {
      fail(`Invalid probe: ${probe.errors.join("; ")}`, { errorCode: "invalid_probe", statusCode: 422 });
    }
    let plan = null;
    if (planJson !== undefined && planJson !== "") {
      const p = loadPlan(planJson);
      if (!p.ok || p.value === null) {
        fail(`Invalid plan: ${p.errors.join("; ")}`, { errorCode: "invalid_plan", statusCode: 422 });
      }
      plan = p.value;
    }
    const assessment = assessRisk(probe.value!, plan);
    return {
      ...assessment,
      message: assessment.headline,
      nextRequiredAction: undefined as string | undefined,
    };
  },
});