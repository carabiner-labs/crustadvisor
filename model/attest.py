#!/usr/bin/env python3
"""Write the attestations for a CrustAdvisor model build.

Reads build/build-info.json (written by build.sh) and emits two unsigned
in-toto statements about the GGUF. Their subject is the model's OpenSSF Model
Signing (OMS) root digest, the digest a model_signing signature records and
the one `ampel verify model` computes, so the signature and the statements
all describe the same subject:

  model-signing.intoto.json  The OMS statement, exactly what `model_signing
                             sign` wraps in its sigstore bundle. Unsigned
                             here; the signed bundle replaces it on stage.
  sbom.cdx.intoto.json       CycloneDX 1.6 ML-BOM: the GGUF as a
                             machine-learning-model component, its license
                             and format, and the base model it was built from.

The SLSA provenance is not written here: provenance.sh hands the build's
facts to slsa-attester, which writes and signs it.

Signing happens separately (model/sign.sh); see admit/README.md.

Usage: attest.py [--build-info build/build-info.json] [--out build/attestations]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path

from google.protobuf import json_format
from model_signing import hashing as oms_hashing
from model_signing._signing.signing import Payload as OMSPayload

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

def oms_statement(model: Path) -> dict:
    """The OMS statement for the model: root digest subject + serialization predicate."""
    manifest = oms_hashing.hash(model)
    return json.loads(json_format.MessageToJson(OMSPayload(manifest).statement.pb))


def statement(subject: dict, predicate_type: str, predicate: dict) -> dict:
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [subject],
        "predicateType": predicate_type,
        "predicate": predicate,
    }


def model_architecture(snapshot: Path) -> dict:
    """Architecture facts from the snapshot's config.json, for the model card."""
    try:
        cfg = json.loads((snapshot / "config.json").read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return {"architectureFamily": cfg.get("model_type", ""), "modelArchitecture": (cfg.get("architectures") or [""])[0]}


def mlbom(info: dict, now: str, snapshot: Path) -> dict:
    src, out = info["source"], info["output"]
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{os.urandom(16).hex()}",
        "version": 1,
        "metadata": {
            "timestamp": now,
            "tools": {"components": [{"type": "application", "name": "crustadvisor-attest", "version": "1"}]},
            "component": {
                "type": "machine-learning-model",
                "bom-ref": "crustadvisor-model",
                "name": out["name"],
                "version": src["revision"][:12],
                "hashes": [{"alg": "SHA-256", "content": out["sha256"]}],
                "licenses": [{"license": {"id": "Apache-2.0"}}],
                "properties": [
                    {"name": "crustadvisor:format", "value": "gguf"},
                    {"name": "crustadvisor:quantization", "value": info["builder"]["quant"]},
                    {"name": "crustadvisor:oms-digest", "value": "sha256:" + out["oms_sha256"]},
                ],
                "modelCard": {"modelParameters": {"task": "text-generation", **model_architecture(snapshot)}},
            },
        },
        "components": [
            {
                "type": "machine-learning-model",
                "bom-ref": "base-model",
                "name": src["repo"],
                "version": src["revision"],
                "purl": f"pkg:huggingface/{src['repo']}@{src['revision']}",
                "licenses": [{"license": {"id": "Apache-2.0"}}],
                "properties": [{"name": "crustadvisor:format", "value": "safetensors"}],
                "externalReferences": [{"type": "distribution", "url": f"https://huggingface.co/{src['repo']}/tree/{src['revision']}"}],
            },
            {
                "type": "application",
                "bom-ref": "llama.cpp",
                "name": "llama.cpp",
                "version": info["builder"]["llama.cpp"],
                "purl": f"pkg:github/ggml-org/llama.cpp@{info['builder']['llama.cpp']}",
                "licenses": [{"license": {"id": "MIT"}}],
            },
        ],
        "dependencies": [{"ref": "crustadvisor-model", "dependsOn": ["base-model", "llama.cpp"]}],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-info", type=Path, default=ROOT / "build" / "build-info.json")
    ap.add_argument("--out", type=Path, default=ROOT / "build" / "attestations")
    ap.add_argument("--snapshot", type=Path, help="HF snapshot dir (default: build/hf/<repo>)")
    args = ap.parse_args()

    info = json.loads(args.build_info.read_text())
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    model = args.build_info.parent / info["output"]["name"]
    oms = oms_statement(model)
    subject = oms["subject"][0]
    info["output"]["oms_sha256"] = subject["digest"]["sha256"]
    args.build_info.write_text(json.dumps(info, indent=2) + "\n")

    args.out.mkdir(parents=True, exist_ok=True)
    files = {
        "model-signing.intoto.json": oms,
        "sbom.cdx.intoto.json": statement(subject, "https://cyclonedx.org/bom", mlbom(info, now, args.snapshot or args.build_info.parent / "hf" / info["source"]["repo"].replace("/", "_"))),
    }
    for name, stmt in files.items():
        (args.out / name).write_text(json.dumps(stmt, indent=2) + "\n")
        print(f"wrote {args.out / name}", file=sys.stderr)
    print(f"subject: {subject['name']} OMS sha256:{subject['digest']['sha256']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
