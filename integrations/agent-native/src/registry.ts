/**
 * The shared typed action registry for the usbless-dualboot companion.
 *
 * One definition per capability, consumed by BOTH surfaces:
 *   - the Agent-Native actions in `actions/*.ts` (agent tool + CLI + MCP + A2A), and
 *   - the static human UI in `src/ui-entry.ts`.
 *
 * ENFORCED INVARIANTS — these are type-level, not conventions:
 *
 *   `readOnly: true` and `destructive: false` are LITERAL types. A destructive
 *   action is not representable in this registry: there is no field to set and no
 *   variant that widens the type. The CLI's mutating phases (shrink, stage, boot,
 *   windows, secureboot) therefore cannot be expressed here at all.
 *
 *   `run` is synchronous and total: same input -> same output, no I/O, no clock,
 *   no environment, no randomness. Anything needing a side effect would have to be
 *   async, which this signature rejects.
 */
import { z } from "zod";

import {
  type Finding,
  type Plan,
  type Probe,
  type LayoutSummary,
  type PlanComparison,
  assessRisk,
  comparePlanToProbe,
  loadPlan,
  loadProbe,
  summarizeProbe,
  DESTRUCTIVE_PHASES,
} from "./core.ts";

/** A pure, read-only capability. Note the literal `true`/`false` member types. */
export interface ActionDefinition<I, O> {
  readonly name: string;
  readonly description: string;
  /** Validates the caller's raw input before `run` is reached. */
  readonly input: z.ZodType<I>;
  /** Literal `true`: every action in this registry is read-only. */
  readonly readOnly: true;
  /** Literal `false`: a destructive action cannot be declared in this registry. */
  readonly destructive: false;
  /** Pure: no I/O, no clock, no randomness, synchronous. */
  readonly run: (input: I) => O;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnyAction = ActionDefinition<any, unknown>;

const probeJsonField = z
  .string()
  .describe("Full text of a `usbless-dualboot probe --json` document.");

const planJsonField = z
  .string()
  .describe("Full text of a usbless-dualboot plan/config JSON document.");

export interface LoadProbeOutput {
  readonly ok: boolean;
  readonly probe: Probe | null;
  readonly errors: readonly string[];
  readonly message: string;
}

export const loadProbeAction: ActionDefinition<{ probeJson: string }, LoadProbeOutput> = {
  name: "load-probe",
  description:
    "Validate a user-supplied usbless-dualboot probe document. Read-only; accepts pasted/uploaded JSON text and reports whether it is a well-formed probe.",
  input: z.object({ probeJson: probeJsonField }),
  readOnly: true,
  destructive: false,
  run: ({ probeJson }) => {
    const result = loadProbe(probeJson);
    if (!result.ok || result.value === null) {
      return { ok: false, probe: null, errors: result.errors, message: "Probe rejected." };
    }
    const p = result.value;
    return {
      ok: true,
      probe: p,
      errors: [],
      message: `Probe accepted: ${p.root_fstype} root on ${p.root_source}, bootloader ${p.bootloader}.`,
    };
  },
};

export interface SummarizeLayoutOutput {
  readonly ok: boolean;
  readonly summary: LayoutSummary | null;
  readonly errors: readonly string[];
  readonly message: string;
}

export const summarizeLayoutAction: ActionDefinition<{ probeJson: string }, SummarizeLayoutOutput> = {
  name: "summarize-layout",
  description:
    "Summarize the detected layout from a probe document: firmware, Secure Boot, encryption, bootloader, root filesystem, block devices. Read-only.",
  input: z.object({ probeJson: probeJsonField }),
  readOnly: true,
  destructive: false,
  run: ({ probeJson }) => {
    const result = loadProbe(probeJson);
    if (!result.ok || result.value === null) {
      return { ok: false, summary: null, errors: result.errors, message: "Cannot summarize an invalid probe." };
    }
    const summary = summarizeProbe(result.value);
    return {
      ok: true,
      summary,
      errors: [],
      message: `${summary.firmware}; root ${summary.root}; bootloader ${summary.bootloader}.`,
    };
  },
};

export interface ComparePlanOutput {
  readonly ok: boolean;
  readonly comparison: PlanComparison | null;
  readonly errors: readonly string[];
  readonly message: string;
}

export const comparePlanAction: ActionDefinition<
  { probeJson: string; planJson: string },
  ComparePlanOutput
> = {
  name: "compare-plan",
  description:
    "Compare a proposed plan against a probe and report conflicts (the plan contradicts the probe or itself) and notes. Read-only; nothing is executed.",
  input: z.object({ probeJson: probeJsonField, planJson: planJsonField }),
  readOnly: true,
  destructive: false,
  run: ({ probeJson, planJson }) => {
    const probe = loadProbe(probeJson);
    if (!probe.ok || probe.value === null) {
      return { ok: false, comparison: null, errors: probe.errors, message: "Invalid probe." };
    }
    const plan = loadPlan(planJson);
    if (!plan.ok || plan.value === null) {
      return { ok: false, comparison: null, errors: plan.errors, message: "Invalid plan." };
    }
    const comparison = comparePlanToProbe(probe.value, plan.value);
    return {
      ok: true,
      comparison,
      errors: [],
      message: comparison.consistent
        ? "Plan is consistent with the probe; no contradictions found."
        : `Plan rejected: ${comparison.conflicts.length} contradiction(s) with the probe.`,
    };
  },
};

export interface RiskSummaryOutput {
  readonly ok: boolean;
  readonly level: Finding["level"] | null;
  readonly headline: string;
  readonly findings: readonly Finding[];
  readonly nextStep: string;
  readonly errors: readonly string[];
  readonly message: string;
}

export const riskSummaryAction: ActionDefinition<
  { probeJson: string; planJson?: string },
  RiskSummaryOutput
> = {
  name: "risk-summary",
  description:
    "Produce a human-readable risk level, finding list, and next human step from a probe and optional plan. Read-only. Any destructive step it names must be run manually in a terminal.",
  input: z.object({ probeJson: probeJsonField, planJson: planJsonField.optional() }),
  readOnly: true,
  destructive: false,
  run: ({ probeJson, planJson }) => {
    const probe = loadProbe(probeJson);
    if (!probe.ok || probe.value === null) {
      return {
        ok: false, level: null, headline: "Invalid probe.", findings: [],
        nextStep: "Fix the probe document.", errors: probe.errors, message: "Invalid probe.",
      };
    }
    let plan: Plan | null = null;
    if (planJson !== undefined && planJson !== "") {
      const p = loadPlan(planJson);
      if (!p.ok || p.value === null) {
        return {
          ok: false, level: null, headline: "Invalid plan.", findings: [],
          nextStep: "Fix the plan document.", errors: p.errors, message: "Invalid plan.",
        };
      }
      plan = p.value;
    }
    const assessment = assessRisk(probe.value, plan);
    return {
      ok: true,
      level: assessment.level,
      headline: assessment.headline,
      findings: assessment.findings,
      nextStep: assessment.nextStep,
      errors: [],
      message: assessment.headline,
    };
  },
};

/** The whole surface. Deliberately small — four read-only capabilities. */
export const actionRegistry = {
  "load-probe": loadProbeAction,
  "summarize-layout": summarizeLayoutAction,
  "compare-plan": comparePlanAction,
  "risk-summary": riskSummaryAction,
} as const;

export type ActionName = keyof typeof actionRegistry;

export interface InvocationResult<O> {
  readonly ok: boolean;
  readonly value: O | null;
  readonly errors: readonly string[];
}

/**
 * Validate raw input through the action's schema, then run it.
 * Also pure: no I/O, no globals mutated.
 */
export function invoke<I, O>(action: ActionDefinition<I, O>, raw: unknown): InvocationResult<O> {
  const parsed = action.input.safeParse(raw);
  if (!parsed.success) {
    return {
      ok: false,
      value: null,
      errors: parsed.error.issues.map(
        (i: { path: PropertyKey[]; message: string }) =>
          `${i.path.join(".") || "<root>"}: ${i.message}`,
      ),
    };
  }
  return { ok: true, value: action.run(parsed.data), errors: [] };
}

/** Serialisable description of the surface, for docs, UIs, and tests. */
export function describeRegistry(): {
  readonly name: string;
  readonly description: string;
  readonly readOnly: boolean;
  readonly destructive: boolean;
  readonly runIsAsync: boolean;
}[] {
  return Object.values(actionRegistry).map((a) => ({
    name: a.name,
    description: a.description,
    readOnly: a.readOnly,
    destructive: a.destructive,
    runIsAsync: a.run.constructor.name === "AsyncFunction",
  }));
}

export { DESTRUCTIVE_PHASES };
export type { Finding, LayoutSummary, PlanComparison, Plan, Probe };