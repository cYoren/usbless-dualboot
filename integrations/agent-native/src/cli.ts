#!/usr/bin/env node
/**
 * Local CLI runner for the shared typed action registry.
 *
 * This is the "agent-native CLI surface" equivalent: the same `actionRegistry`
 * the UI and the agent actions call, driven from a terminal. It is read-only and
 * file-in only — it never runs a usbless-dualboot phase.
 *
 *   node --experimental-strip-types src/cli.ts list
 *   node --experimental-strip-types src/cli.ts summarize-layout fixtures/demo-probe.json
 *   node --experimental-strip-types src/cli.ts compare-plan fixtures/demo-probe.json fixtures/demo-plan.json
 *   node --experimental-strip-types src/cli.ts risk-summary fixtures/demo-probe.json [fixtures/demo-plan.json]
 *   node --experimental-strip-types src/cli.ts load-probe fixtures/demo-probe.json
 *
 * File reads are limited to paths the caller passes on argv. No argument is ever
 * executed, interpolated into a shell, or used to build a command.
 */
import { readFileSync } from "node:fs";
import { actionRegistry, invoke, describeRegistry, type ActionName } from "./registry.ts";

const args = process.argv.slice(2);
const command = args[0] ?? "help";

function usage(): void {
  process.stdout.write(
    `usbless-dualboot read-only companion (local runner)\n\n` +
      `Commands:\n  list\n  load-probe <probe.json>\n  summarize-layout <probe.json>\n` +
      `  compare-plan <probe.json> <plan.json>\n  risk-summary <probe.json> [plan.json]\n\n` +
      `Actions are read-only pure functions. No mutating CLI phase exists here.\n`,
  );
}

function readText(p: string): string {
  try {
    return readFileSync(p, "utf8");
  } catch (err) {
    process.stderr.write(`cannot read ${p}: ${(err as Error).message}\n`);
    process.exit(2);
  }
}

function emit(value: unknown): void {
  process.stdout.write(JSON.stringify(value, null, 2) + "\n");
}

switch (command) {
  case "list":
    emit(describeRegistry());
    break;
  case "load-probe":
  case "summarize-layout": {
    const [probePath] = args.slice(1);
    if (probePath === undefined) {
      usage();
      process.exit(2);
    }
    emit(invoke(actionRegistry[command as ActionName] as never, { probeJson: readText(probePath) }));
    break;
  }
  case "compare-plan": {
    const [probePath, planPath] = args.slice(1);
    if (probePath === undefined || planPath === undefined) {
      usage();
      process.exit(2);
    }
    emit(
      invoke(actionRegistry["compare-plan"], {
        probeJson: readText(probePath),
        planJson: readText(planPath),
      }),
    );
    break;
  }
  case "risk-summary": {
    const [probePath, planPath] = args.slice(1);
    if (probePath === undefined) {
      usage();
      process.exit(2);
    }
    emit(
      invoke(actionRegistry["risk-summary"], {
        probeJson: readText(probePath),
        ...(planPath === undefined ? {} : { planJson: readText(planPath) }),
      }),
    );
    break;
  }
  default:
    usage();
    process.exit(command === "help" || command === "--help" ? 0 : 2);
}