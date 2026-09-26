"""Dependency-free command-manifest loader for the adapter.

Kept separate from cli.py so the manifest can be read and validated without
importing the command layer.
"""

import json
import os
from typing import Any, Dict, List, Optional

_HERE = os.path.dirname(os.path.abspath(__file__))

# The canonical manifest lives above the Python package so that the same file is
# used by the repo CI validator and by the installed package.
_CANDIDATES = (
    os.path.join(_HERE, "manifest.json"),
    os.path.join(_HERE, "..", "..", "manifest.json"),
)


def manifest_path() -> str:
    for candidate in _CANDIDATES:
        resolved = os.path.normpath(candidate)
        if os.path.isfile(resolved):
            return resolved
    raise FileNotFoundError(
        "could not locate manifest.json; expected it beside the package or at "
        "integrations/cli-anything/manifest.json"
    )


def load_manifest() -> Dict[str, Any]:
    with open(manifest_path(), "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError("manifest.json must contain a JSON object")
    return data


def commands(manifest: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
    data = manifest if manifest is not None else load_manifest()
    return list(data.get("commands", []))


def command(name: str, manifest: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
    for entry in commands(manifest):
        if entry.get("name") == name:
            return entry
    return None


def destructive_commands(manifest: Optional[Dict[str, Any]] = None) -> List[str]:
    return [c["name"] for c in commands(manifest) if c.get("destructive")]


def root_required_commands(manifest: Optional[Dict[str, Any]] = None) -> List[str]:
    return [c["name"] for c in commands(manifest) if c.get("requires_root")]