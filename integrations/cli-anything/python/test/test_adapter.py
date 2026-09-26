"""Tests for the CLI-Anything adapter and the manifest/schema validator.

Run:  python3 -m pytest test/ -q      (from integrations/cli-anything/python/)
      python3 test/test_adapter.py    (no pytest required)

Design rules asserted here:
  * The manifest's danger/destructive/root flags match the real bash CLI's guards.
  * The registry entry validates against the derived CLI-Hub schema.
  * Destructive commands cannot be delegated without an explicit acknowledgement.
  * Args are forwarded verbatim, except the adapter-only acknowledgement flag.
  * Missing CLI yields exit 3, never a fabricated success.
"""

import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PY = os.path.dirname(HERE)
sys.path.insert(0, PY)

from cli_anything_usbless_dualboot import cli, manifest as mf  # noqa: E402
from cli_anything_usbless_dualboot import validate as vd  # noqa: E402

REPO = vd.REPO
STUB = None


def setUpModule():
    """Create a stub CLI that records its argv and touches nothing."""
    global STUB
    import tempfile

    directory = tempfile.mkdtemp(prefix="usbdb-stub-")
    STUB = os.path.join(directory, "usbless-dualboot")
    with open(STUB, "w", encoding="utf-8") as handle:
        handle.write('#!/usr/bin/env bash\nprintf "STUB argv:"; printf " %q" "$@"; printf "\\n"\n')
    os.chmod(STUB, 0o755)
    os.environ["USBDB_CLI"] = STUB


class TestManifest(unittest.TestCase):
    def test_manifest_loads(self):
        data = mf.load_manifest()
        self.assertEqual(data["adapter"]["registry_name"], "usbless-dualboot")

    def test_all_documented_phases_present(self):
        names = [c["name"] for c in mf.commands()]
        for phase in ["probe", "plan", "shrink", "stage", "boot", "windows", "secureboot"]:
            self.assertIn(phase, names)

    def test_destructive_commands_are_marked(self):
        self.assertEqual(sorted(mf.destructive_commands()), ["shrink", "stage"])

    def test_root_required_matches_lib_sh_need_root(self):
        # lib/{shrink,stage,boot,windows,secureboot}.sh call need_root;
        # lib/probe.sh and lib/plan.sh do not.
        self.assertEqual(
            sorted(mf.root_required_commands()),
            ["boot", "secureboot", "shrink", "stage", "windows"],
        )
        self.assertFalse(mf.command("probe")["requires_root"])
        self.assertFalse(mf.command("plan")["requires_root"])

    def test_only_probe_and_plan_claim_json(self):
        claiming = [c["name"] for c in mf.commands() if c.get("supports_json")]
        self.assertEqual(sorted(claiming), ["plan", "probe"])

    def test_exit_codes_are_exactly_zero_and_one(self):
        codes = sorted(mf.load_manifest()["exit_codes"].keys())
        self.assertEqual(codes, ["0", "1"])

    def test_manifest_declares_what_is_not_verified(self):
        honesty = mf.load_manifest()["honesty"]
        self.assertTrue(honesty["not_verified"])
        joined = " ".join(honesty["not_verified"]).lower()
        self.assertIn("not been submitted", joined)
        self.assertIn("not been reviewed", joined)


class TestValidator(unittest.TestCase):
    def test_registry_entry_validates(self):
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        self.assertEqual(vd.validate_instance(entry, schema), [])

    def test_manifest_invariants_hold(self):
        self.assertEqual(vd.validate_manifest(vd._load(vd.MANIFEST)), [])

    def test_validator_cli_exits_zero(self):
        result = subprocess.run(
            [sys.executable, os.path.join(PY, "cli_anything_usbless_dualboot", "validate.py")],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Schema validation passed.", result.stdout)

    def test_validator_rejects_a_missing_required_field(self):
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        del entry["entry_point"]
        self.assertTrue(vd.validate_instance(entry, schema))

    def test_validator_rejects_a_bad_name_pattern(self):
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        entry["name"] = "Not Lowercase"
        self.assertTrue(vd.validate_instance(entry, schema))

    def test_validator_rejects_a_non_uri_homepage(self):
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        entry["homepage"] = "not-a-url"
        self.assertTrue(vd.validate_instance(entry, schema))

    def test_validator_rejects_an_empty_contributors_array(self):
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        entry["contributors"] = []
        self.assertTrue(vd.validate_instance(entry, schema))

    def test_source_url_and_skill_md_are_not_cross_constrained_by_upstream(self):
        # Published entries legitimately mix values here: some carry source_url=null
        # but a URL or install command as skill_md. CLI-Hub does not define this
        # relationship, so the schema must not reject it.
        entry = vd._load(vd.REGISTRY_ENTRY)
        schema = vd._load(vd.REGISTRY_SCHEMA)
        entry["source_url"] = "https://github.com/cYoren/usbless-dualboot"
        entry["skill_md"] = "skills/relative/SKILL.md"
        self.assertEqual(vd.validate_instance(entry, schema), [])

    def test_manifest_validator_flags_a_destructive_command_marked_safe(self):
        data = vd._load(vd.MANIFEST)
        for entry in data["commands"]:
            if entry["name"] == "shrink":
                entry["destructive"] = False
        self.assertTrue(vd.validate_manifest(data))

    def test_manifest_validator_flags_a_bogus_json_claim(self):
        data = vd._load(vd.MANIFEST)
        for entry in data["commands"]:
            if entry["name"] == "shrink":
                entry["supports_json"] = True
        self.assertTrue(any("--json" in p for p in vd.validate_manifest(data)))


class TestAdapterCli(unittest.TestCase):
    def _run(self, *args, env=None):
        environ = dict(os.environ)
        if env:
            environ.update(env)
        return subprocess.run(
            [sys.executable, "-m", "cli_anything_usbless_dualboot.cli", *args],
            capture_output=True, text=True, cwd=PY, env=environ,
        )

    def test_help_exits_zero(self):
        self.assertEqual(self._run("--help").returncode, 0)

    def test_manifest_table_lists_destructive_commands(self):
        result = self._run("manifest")
        self.assertEqual(result.returncode, 0)
        self.assertIn("destructive", result.stdout)
        self.assertIn("shrink", result.stdout)
        self.assertIn("stage", result.stdout)

    def test_manifest_json_is_parseable(self):
        result = self._run("manifest", "--json")
        self.assertEqual(result.returncode, 0)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["adapter"]["registry_name"], "usbless-dualboot")

    def test_manifest_validate_exits_zero(self):
        result = self._run("manifest", "--validate")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_read_only_command_delegates_verbatim(self):
        result = self._run("probe", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertIn("STUB argv: probe --json", result.stdout)

    def test_real_cli_flags_survive_delegation(self):
        result = self._run("plan", "--iso", "/tmp/x.iso", "--windows-size", "320GiB", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--windows-size 320GiB", result.stdout)
        self.assertIn("--iso /tmp/x.iso", result.stdout)

    def test_destructive_command_refused_without_acknowledgement(self):
        result = self._run("shrink", "--dry-run")
        self.assertEqual(result.returncode, 2)
        self.assertIn("refusing to run destructive command", result.stderr)
        self.assertNotIn("STUB argv", result.stdout)

    def test_stage_also_refused(self):
        result = self._run("stage")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("STUB argv", result.stdout)

    def test_destructive_command_allowed_with_acknowledgement(self):
        result = self._run("shrink", "--i-understand", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STUB argv: shrink --dry-run", result.stdout)

    def test_acknowledgement_flag_is_not_forwarded_to_the_real_cli(self):
        result = self._run("shrink", "--i-understand")
        self.assertNotIn("--i-understand", result.stdout)

    def test_destructive_command_warns_on_stderr(self):
        result = self._run("stage", "--i-understand")
        self.assertIn("DESTRUCTIVE", result.stderr)

    def test_non_destructive_commands_are_not_gated(self):
        for name in ("probe", "plan"):
            with self.subTest(command=name):
                self.assertEqual(self._run(name).returncode, 0)

    def test_firmware_and_bootconfig_commands_are_not_gated_as_destructive(self):
        # boot/windows/secureboot mutate firmware or boot config but are reversible;
        # they must not be blocked by the destructive gate.
        for name in ("boot", "windows", "secureboot"):
            with self.subTest(command=name):
                self.assertEqual(self._run(name, "--restore").returncode, 0)

    def test_unknown_command_exits_usage_error(self):
        self.assertEqual(self._run("frobnicate").returncode, 2)

    def test_missing_cli_exits_three_and_does_not_fake_success(self):
        result = self._run("probe", env={"USBDB_CLI": "/nonexistent/usbless-dualboot"})
        self.assertEqual(result.returncode, 3)
        self.assertIn("not found", result.stderr)
        self.assertNotIn("STUB argv", result.stdout)

    def test_manifest_command_never_invokes_the_cli(self):
        # Point USBDB_CLI at a path that would explode if executed.
        result = self._run("manifest", env={"USBDB_CLI": "/nonexistent/boom"})
        self.assertEqual(result.returncode, 0)

    def test_skill_md_and_manifest_are_shipped_in_the_package(self):
        package_dir = os.path.join(PY, "cli_anything_usbless_dualboot")
        self.assertTrue(os.path.isfile(os.path.join(package_dir, "manifest.json")))
        self.assertTrue(os.path.isfile(os.path.join(package_dir, "SKILL.md")))


class TestShippedCopiesMatchCanonical(unittest.TestCase):
    """The vendored copies must not drift from the canonical files."""

    def test_packaged_manifest_matches_canonical(self):
        packaged = os.path.join(PY, "cli_anything_usbless_dualboot", "manifest.json")
        with open(packaged, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), json.load(open(vd.MANIFEST, encoding="utf-8")))

    def test_packaged_skill_md_matches_canonical(self):
        packaged = os.path.join(PY, "cli_anything_usbless_dualboot", "SKILL.md")
        canonical = os.path.join(REPO, "integrations", "cli-anything", "SKILL.md")
        with open(packaged, encoding="utf-8") as a, open(canonical, encoding="utf-8") as b:
            self.assertEqual(a.read(), b.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)