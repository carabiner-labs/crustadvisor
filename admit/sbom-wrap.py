#!/usr/bin/env python3
"""Wrap an SBOM file in an unsigned in-toto statement for ampel.

Usage: sbom-wrap.py <sbom.json> <subject-name> <subject-sha256> <out.intoto.json>

The predicate type is chosen from the SBOM: SPDX documents become
https://spdx.dev/Document, CycloneDX becomes https://cyclonedx.org/bom. ampel
parses either into protobom, so a policy reads them the same way.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    sbom_path, name, digest, out = sys.argv[1:5]
    sbom = json.loads(open(sbom_path).read())
    if sbom.get("bomFormat") == "CycloneDX":
        ptype = "https://cyclonedx.org/bom"
    elif str(sbom.get("spdxVersion", "")).startswith("SPDX-"):
        ptype = "https://spdx.dev/Document"
    else:
        raise SystemExit(f"{sbom_path}: not a recognized SPDX or CycloneDX document")
    stmt = {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": name, "digest": {"sha256": digest}}],
        "predicateType": ptype,
        "predicate": sbom,
    }
    open(out, "w").write(json.dumps(stmt, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
