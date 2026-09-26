# Framework integrations

Two integrations live under `integrations/`. Both are **read-only descriptions or
read-only companions** of the existing CLI. Neither rewrites the CLI, and neither
one makes a disk installation work.

Nothing here is adopted by an upstream project. Read [Status](#status) before
quoting any of it.

## 1. `integrations/cli-anything/` — CLI-Hub compatibility

CLI-Hub ([clianything.cc](https://clianything.cc/), [HKUDS/CLI-Anything](https://github.com/HKUDS/CLI-Anything))
is a registry plus package manager for agent-native CLI harnesses. Its published
registration path for an external tool is a **registry-only PR**: your CLI stays
in your repo, and you submit one entry to the upstream `registry.json`.

Contributed here:

| File | Purpose |
|---|---|
| `registry-entry.json` | The submission payload, shaped per the "Registry fields" table in upstream `CONTRIBUTING.md` |
| `schema/registry-entry.schema.json` | A JSON Schema derived field-by-field from that same table |
| `manifest.json` | Machine-readable description of the actual commands, output, exit codes, and danger levels |
| `SKILL.md` | The agent-discovery skill document the registry entry points at |
| `crosscheck-ajv.mjs` | Validates the entry with ajv, an independent third-party validator |
| `python/` | A pip-installable adapter that delegates to the bash CLI |

### What is described, and how it was verified

Every field in `manifest.json` was read out of this repository, not invented:

- The command set (`probe`, `plan`, `shrink`, `stage`, `boot`, `windows`,
  `secureboot`, plus `version`/`help`) comes from the dispatch table in
  `bin/usbless-dualboot`.
- **Exit codes are exactly `0` and `1`.** The union of explicit `exit N`
  statements across `bin/` and `lib/` is `{0, 1}`; every failure funnels through
  the `die()` helper. The manifest says so and deliberately does not claim richer
  codes.
- **`--json` is real only for `probe` and `plan`.** The manifest's `supports_json`
  flags are gated on this, and the validator rejects any entry claiming otherwise.
- `requires_root` mirrors which phase scripts call `need_root`:
  `shrink`, `stage`, `boot`, `windows`, `secureboot` do; `probe` and `plan` do not.
- The `probe --json` schema in `manifest.json` mirrors the `cat <<EOF` block in
  `lib/probe.sh`. Note that `bootloader` is typed as a free-form string, because
  the real CLI emits values like `limine (inferred; run with sudo to confirm)`.
  Constraining it to an enum would reject genuine probes.

### Destructive operations are marked destructive

`shrink` and `stage` are `destructive: true` with `danger: "destructive"` and a
`why_dangerous` explanation. `boot` and `secureboot` are `danger: "firmware"`, and
`windows` is `danger: "boot-config"` — they mutate firmware or boot configuration
but are reversible, so marking them `destructive` would misrepresent them.

The adapter refuses to delegate a destructive command unless the caller passes
`--i-understand`. That flag is an adapter-only acknowledgement and is stripped
before the real CLI is invoked, because the real CLI has no such option and would
abort with `unknown option`.

### Validating the submission

```bash
# The adapter's own validator (stdlib only, no dependencies)
python3 integrations/cli-anything/python/cli_anything_usbless_dualboot/validate.py

# Independent cross-check with ajv
node integrations/cli-anything/crosscheck-ajv.mjs

# Independent cross-check with Python's jsonschema
python3 -c "
import json, jsonschema
jsonschema.validate(
    json.load(open('integrations/cli-anything/registry-entry.json')),
    json.load(open('integrations/cli-anything/schema/registry-entry.schema.json')))
print('valid')"

# Adapter tests (36 tests; no pytest required)
python3 integrations/cli-anything/python/test/test_adapter.py
```

### Honest gaps

- The registry entry has **not been submitted** upstream and no maintainer has
  reviewed it. `cli-hub install usbless-dualboot` does not work today.
- The package installs (`pip install ...#subdirectory=integrations/cli-anything/python`)
  but the `pip install git+https://...` network form has not been executed here.
- No mutating phase has been run or end-to-end tested, here or anywhere: that
  needs real block devices and root.
- The adapter exposes **no** REPL, **no** undo/redo, and **no** preview rendering.
  The underlying CLI is a set of one-shot phases over a state directory, and
  `shrink`/`stage` are irreversible — so those harness features are genuinely
  absent, not merely unimplemented. `manifest.json` records this under `honesty`.

## 1b. `integrations/cli-hub/` — independent verification harness

This directory does **not** ship a second submission payload. It is a verifier that
reads the canonical entry at `integrations/cli-anything/registry-entry.json` and
checks it against two things the entry cannot check itself: the published upstream
corpus, and the real CLI in this repository.

| File | Purpose |
|---|---|
| `validate.mjs` | Six-stage validator: JSON Schema, payload self-consistency, live CLI cross-check, danger/privilege honesty, companion isolation, upstream corpus |
| `registry-entry.schema.json` | JSON Schema transcribed from the *actual* bytes of the two published registries |
| `command-surface.json` | The real command surface (flags, exit codes, side effects, danger levels) read out of `bin/` and `lib/` |
| `test/validate.test.mjs` | 15 negative tests: each deliberately breaks the payload and asserts the validator fails |

### Why the schema here is transcribed, not derived from prose

The schema in this directory was written against the published artifacts rather than
a documentation table, so it can be checked against them:

```
node validate.mjs --upstream     # fetches both registries and validates every entry
  ok  registry.json: all 79 published entries satisfy the transcribed schema
  ok  public_registry.json: all 24 published entries satisfy the transcribed schema
```

### Schema fidelity checked against the published registries

CLI-Hub's repo publishes registry JSON files and documents the registration fields in
`CONTRIBUTING.md`. I did not find a published JSON Schema in the upstream repository
tree. The local schema here is explicitly a derived validation schema, not an
upstream-owned or upstream-approved artifact. Its accepted shapes were checked
against the live registry corpus (79 harness entries + 24 public entries).

```
node integrations/cli-anything/crosscheck-ajv.mjs
# submitted payload: VALID; negative control: malformed payload rejected

# corpus check, using the same schema:
# registry.json: 79/79 entries valid
# public_registry.json: 24/24 entries valid
```

That corpus check caught and fixed an over-strict first draft. The initial schema
required `source_url`, `install_cmd`, and `contributors`, required `name` to use
hyphens only, constrained versions to SemVer, and forced `source_url`/`skill_md`
to follow a relationship the registry does not enforce. This rejected real entries
such as `qgis`, `android-cli`, `obsidian-cli`, `slay_the_spire_ii`, `unimol_tools`,
and several `latest`-version packages. The checked-in schema now matches the live
corpus: all 103 published entries validate. `integrations/cli-hub/validate.mjs`
independently confirms the same 79 + 24 split.

Do not report either result as upstream adoption. The entry is still unsubmitted,
so `cli-hub install usbless-dualboot` does not work today.

## 2. `integrations/agent-native/` — read-only companion

[Agent-Native](https://www.agent-native.com/docs) (`@agent-native/core`, the
BuilderIO framework — v0.189.0) supplies `defineAction` for typed, agent-callable
actions. The relevant npm package is **`@agent-native/core`**; the unrelated
`agent-native` package on npm is a different project and is not used.

The companion is built from a shared typed action registry (`src/registry.ts`) of
**pure functions**, consumed by two surfaces:

1. Four Agent-Native actions in `actions/*.ts`, declared `readOnly: true, http: false`.
2. A minimal human UI (`index.html` + `src/ui-entry.ts`) and a local CLI runner
   (`src/cli.ts`), both reading files the user selects.

Actions:

| Action | Purpose |
|---|---|
| `load-probe` | Validate a `probe --json` document |
| `summarize-layout` | Summarize the detected firmware, Secure Boot, encryption, bootloader, root |
| `compare-plan` | Compare a proposed plan against the probe; report conflicts and notes |
| `risk-summary` | Overall risk level, findings, and the next human step |

### The four required behaviors, and where they are asserted

`test/companion.test.ts` (32 tests, all passing) asserts:

1. **Valid probe accepted** — the demo fixture validates, as does the free-form
   `(inferred)` bootloader form and a probe where `sudo` was unavailable.
2. **Malformed/unsupported probe rejected** — non-JSON, missing required fields
   (reported with their paths), out-of-enum `encryption`/`uefi`, and a non-object
   `lsblk`.
3. **Overlapping or contradicting plan rejected** — target-OS range overlapping
   the installer partition, overlapping the shrunk Linux partition, `fstype`
   mismatch, wrong `linux_part`, missing LUKS offset, bootloader mismatch, the
   plan's own arithmetic disagreeing with itself, a partition smaller than its
   filesystem, an installer range past the end of the disk, and an `add-windows`
   plan against a non-UEFI probe.
4. **Destructive action not representable or executable** — every registry entry
   is `readOnly: true, destructive: false` with a synchronous `run()`; no action
   is named after a mutating phase; and the pure layer imports **no** Node
   builtin, so it has no filesystem, process, or network capability at all.

### Hard constraints, and how each is held

| Constraint | How it is held |
|---|---|
| No host disk discovery | Inputs are user-supplied file contents; nothing enumerates devices |
| No root execution | No privilege check or escalation anywhere |
| No arbitrary command execution | `core.ts`, `registry.ts`, and every action import no Node builtin |
| No endpoint running CLI mutating phases | No mutating phase exists as an action or registry entry |
| No writes outside the repo | The UI writes nothing; `src/cli.ts` only reads argv-named files |
| No network calls at runtime | No fetch/WebSocket/socket use; the UI bundle contains none |
| No publicly exposed ports | No server is started |

**No server bridge is shipped.** Agent-Native's full dev server was deliberately
not started: it would require a project scaffold, a `vite`/`nitro` build, and a
listening port. Rather than fake it, this ships the read-only, no-server version:
the same action registry is driven by the browser UI and the local CLI runner.
The framework's `defineAction` contract is genuinely used and executed — that is
verified by `scripts/action-smoke.mjs`, which runs the real actions in Node — but
no framework server is involved, and none of the framework's HTTP surface is
claimed.

Dependency note, stated plainly: `@agent-native/core` is a large framework and its
own dependency tree includes `playwright`, among ~1030 locked packages. That is
transitive, not something this integration added, and no browser automation is
invoked at runtime — but it does mean `npm install` here pulls far more than the
companion's own four pure functions need. If that matters, `src/core.ts` and
`src/registry.ts` have no framework dependency at all and are usable on their own.

### Fixtures are synthetic

`fixtures/demo-probe.json` and `fixtures/demo-plan.json` are hand-authored demo
data, internally consistent with `examples/config.example.json`'s geometry
conventions. They describe no real machine. The probe fixture has one synthetic
NVMe disk with an ESP, a LUKS `crypto_LUKS` partition, an unlocked btrfs root on
`/dev/mapper/root`, and Secure Boot enabled in Setup Mode.

### Running it

```bash
cd integrations/agent-native
npm install            # project-local install; package-lock.json is committed

npm run typecheck      # tsc --noEmit
npm test               # 32 tests
npm run build:ui       # bundles dist/ui-bundle.js

# Local read-only runner
node --experimental-strip-types src/cli.ts list
node --experimental-strip-types src/cli.ts risk-summary fixtures/demo-probe.json fixtures/demo-plan.json

# Runtime proof that the real framework actions execute
node --experimental-strip-types scripts/action-smoke.mjs

# Then open index.html in a browser and pick the fixture files
```

## Status

Be precise about what is true:

- ✅ The bash CLI is unchanged.
- ✅ Both integrations typecheck, build, and pass their tests, run locally.
- ✅ `registry-entry.json` validates against the derived schema under **three**
  independent validators (this repo's stdlib checker, `ajv`, and `jsonschema`).
- ✅ `@agent-native/core` is really installed and its `defineAction` really runs.
- ❌ No upstream project has reviewed, accepted, or adopted any of this.
- ❌ `cli-hub install usbless-dualboot` does not work until the registry PR is merged.
- ❌ Nothing here installs a dual-boot system. That is still the CLI, run by a human.

## Interpreting a probe safely

The companion will not tell you a plan is safe to execute. A `consistent: true`
verdict means only that the plan does not contradict the probe document you gave
it. It cannot know whether your backups are current, whether AC power is
connected, or whether the disk changed since the probe was taken.

When `risk-summary` returns `dangerous`, the plan contradicts the probe and must
not be run. When it does not, the plan is merely *not obviously wrong* — the
destructive phases still have to be run manually, in a terminal, after
`--dry-run`, exactly as the CLI's own guards require.