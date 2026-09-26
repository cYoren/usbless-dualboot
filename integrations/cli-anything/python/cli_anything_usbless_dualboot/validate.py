"""Validate the integration's JSON documents against the derived CLI-Hub schema.

Dependency-free (stdlib only) so installing the adapter never pulls a validator,
and so CI can run this without network access.

It checks:
  1. integrations/cli-anything/registry-entry.json against
     integrations/cli-anything/schema/registry-entry.schema.json
  2. integrations/cli-anything/manifest.json
  3. that the two documents agree with each other

The schema checker is a deliberately small JSON Schema (draft-07 subset) engine:
type, required, properties, items, minItems, minLength, maxLength, pattern, enum,
format(uri), additionalProperties, allOf, anyOf, and a $ref-free $schema pointer.
That subset is exactly what schema/registry-entry.schema.json uses. It is
cross-checked against ajv in test/test_validate.py, so its acceptance means the
same thing a standard validator would.

Exit codes: 0 valid, 1 invalid, 3 the validator could not run.
"""

import json
import os
import re
import sys
from typing import Any, Dict, List

def _find_repo_root() -> str:
    """Locate the repo root by walking up for the integration's own marker.

    Works from an in-repo checkout and fails loudly (rather than resolving to a
    wrong path) when the package has been installed without the repo around it.
    """
    current = os.path.dirname(os.path.abspath(__file__))
    for _ in range(8):
        marker = os.path.join(current, "integrations", "cli-anything", "manifest.json")
        if os.path.isfile(marker):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    raise FileNotFoundError(
        "could not locate the repository root (no integrations/cli-anything/manifest.json "
        "found in any parent directory). This validator is a repository tool; run it from "
        "a usbless-dualboot checkout."
    )


REPO = _find_repo_root()

REGISTRY_ENTRY = os.path.join(REPO, "integrations", "cli-anything", "registry-entry.json")
REGISTRY_SCHEMA = os.path.join(REPO, "integrations", "cli-anything", "schema", "registry-entry.schema.json")
MANIFEST = os.path.join(REPO, "integrations", "cli-anything", "manifest.json")

REQUIRED_COMMANDS = ["probe", "plan", "shrink", "stage", "boot", "windows", "secureboot"]
DESTRUCTIVE_COMMANDS = ["shrink", "stage"]
# Only these commands implement --json in lib/; anything else claiming it is a lie.
JSON_COMMANDS = {"probe", "plan"}

_TYPE_CHECKS = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def _type_ok(value: Any, expected: Any) -> bool:
    names = expected if isinstance(expected, list) else [expected]
    return any(_TYPE_CHECKS.get(name, lambda _v: True)(value) for name in names)


def validate_instance(value: Any, schema: Any, path: str = "$") -> List[str]:
    """Return a list of human-readable violations. Empty list means valid."""
    errors: List[str] = []
    if not isinstance(schema, dict):
        return errors

    if "type" in schema and not _type_ok(value, schema["type"]):
        return [f"{path}: expected type {schema['type']}, got {type(value).__name__}"]

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than maxLength {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: {value!r} does not match {schema['pattern']!r}")
        if schema.get("format") == "uri" and not re.match(r"^https?://", value):
            errors.append(f"{path}: {value!r} is not an http(s) URI")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: fewer than minItems {schema['minItems']}")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(validate_instance(item, schema["items"], f"{path}[{index}]"))

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required property '{key}'")
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                errors.extend(validate_instance(value[key], sub, f"{path}.{key}"))
        if schema.get("additionalProperties") is False:
            allowed = set(schema.get("properties", {}))
            for key in value:
                if key not in allowed:
                    errors.append(f"{path}: additional property '{key}' is not allowed")

    for sub in schema.get("allOf", []):
        errors.extend(validate_instance(value, sub, path))

    branches = schema.get("anyOf")
    if branches:
        if not any(not validate_instance(value, sub, path) for sub in branches):
            errors.append(f"{path}: value matched no anyOf branch")

    return errors


def validate_manifest(manifest: Any) -> List[str]:
    """Structural invariants of the command manifest that the schema cannot express."""
    problems: List[str] = []
    if not isinstance(manifest, dict):
        return ["manifest: root must be an object"]

    if not isinstance(manifest.get("adapter"), dict):
        problems.append("manifest: missing 'adapter' object")
    commands = manifest.get("commands")
    if not isinstance(commands, list):
        return problems + ["manifest: missing 'commands' array"]

    names = [c.get("name") for c in commands if isinstance(c, dict)]
    for expected in REQUIRED_COMMANDS:
        if expected not in names:
            problems.append(f"manifest: command '{expected}' is missing")
    if len(names) != len(set(names)):
        problems.append("manifest: duplicate command names")

    for entry in commands:
        if not isinstance(entry, dict):
            problems.append("manifest: every command must be an object")
            continue
        name = entry.get("name")
        for field in ("summary", "danger", "destructive", "requires_root", "supports_json"):
            if field not in entry:
                problems.append(f"manifest: command '{name}' is missing '{field}'")
        if entry.get("destructive") not in (True, False):
            problems.append(f"manifest: '{name}' destructive must be a boolean")
        if entry.get("supports_json") and name not in JSON_COMMANDS:
            problems.append(
                f"manifest: '{name}' claims --json, but lib/ implements --json only for "
                f"{sorted(JSON_COMMANDS)}"
            )

    for name in DESTRUCTIVE_COMMANDS:
        entry = next((c for c in commands if isinstance(c, dict) and c.get("name") == name), None)
        if entry is None:
            problems.append(f"manifest: destructive command '{name}' is missing")
            continue
        if entry.get("destructive") is not True:
            problems.append(f"manifest: '{name}' must be marked destructive")
        if entry.get("danger") != "destructive":
            problems.append(f"manifest: '{name}' danger must be 'destructive'")
        if entry.get("requires_root") is not True:
            problems.append(f"manifest: '{name}' must require root")

    exits = manifest.get("exit_codes")
    if not isinstance(exits, dict):
        problems.append("manifest: missing 'exit_codes' object")
    else:
        for code in ("0", "1"):
            if code not in exits:
                problems.append(f"manifest: exit code {code} is undocumented")
    return problems


def main(argv: List[str]) -> int:
    try:
        registry_entry = _load(REGISTRY_ENTRY)
        registry_schema = _load(REGISTRY_SCHEMA)
        manifest = _load(MANIFEST)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"validator error: {exc}", file=sys.stderr)
        return 3

    failures: List[str] = []

    schema_errors = validate_instance(registry_entry, registry_schema)
    rel_schema = os.path.relpath(REGISTRY_SCHEMA, REPO)
    if schema_errors:
        failures.extend(f"registry-entry.json {e}" for e in schema_errors)
    else:
        print(f"OK    registry-entry.json validates against {rel_schema}")

    manifest_problems = validate_manifest(manifest)
    if manifest_problems:
        failures.extend(manifest_problems)
    else:
        print("OK    manifest.json satisfies its invariants "
              "(command set, root/destructive flags, exit codes, --json claims)")

    if not schema_errors and not manifest_problems:
        adapter, target = manifest["adapter"], manifest["target_software"]
        checks = (
            (registry_entry.get("name") == adapter.get("registry_name"),
             "registry-entry.json name != manifest adapter.registry_name"),
            (registry_entry.get("version") == adapter.get("version"),
             "registry-entry.json version != manifest adapter.version"),
            (registry_entry.get("homepage") == target.get("homepage"),
             "registry-entry.json homepage != manifest target_software.homepage"),
            (registry_entry.get("category") == target.get("category"),
             "registry-entry.json category != manifest target_software.category"),
        )
        for ok, message in checks:
            if not ok:
                failures.append(message)
        if not failures:
            print("OK    registry-entry.json and manifest.json agree on name/version/homepage/category")

    if failures:
        print("", file=sys.stderr)
        for problem in failures:
            print(f"FAIL  {problem}", file=sys.stderr)
        print(f"\n{len(failures)} validation failure(s)", file=sys.stderr)
        return 1

    print("\nSchema validation passed.")
    return 0


def _load(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))