#!/usr/bin/env python3
"""Write the attestations for a CrustAdvisor model build.

Reads build/build-info.json (written by build.sh) and emits three unsigned
in-toto statements about the GGUF. Their subject is the model's OpenSSF Model
Signing (OMS) root digest, the digest a model_signing signature records and
the one `ampel verify model` computes, so the signature and the statements
all describe the same subject:

  model-signing.intoto.json  The OMS statement, exactly what `model_signing
                             sign` wraps in its sigstore bundle. Unsigned
                             here; the signed bundle replaces it on stage.
  provenance.intoto.json     SLSA v1 provenance. The resolved dependencies
                             are the Hugging Face snapshot (repo @ revision),
                             the llama.cpp tag and this repository's commit.
  sbom.cdx.intoto.json       CycloneDX 1.6 ML-BOM: the GGUF as a
                             machine-learning-model component, its license
                             and format, and the base model it was built from.

The statements are honest: they record what the build actually used. A build
pointed at a typosquat repo gets provenance that names the typosquat repo,
which is exactly what the policy gate then rejects.

Signing happens separately (model/sign.sh); see admit/README.md.

Usage: attest.py [--build-info build/build-info.json] [--out build/attestations]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path

from google.protobuf import json_format
from model_signing import hashing as oms_hashing
from model_signing._signing.signing import Payload as OMSPayload

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

BUILD_TYPE = "https://github.com/carabiner-labs/crustadvisor/model/build@v1"
LOCAL_BUILDER_ID = "https://localhost/crustadvisor/model/build.sh"


def git(*args: str) -> str:
    try:
        return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True, stderr=subprocess.DEVNULL).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def source_repo() -> tuple[str, str]:
    """(https url of this repo, commit) from CI env or git."""
    if os.environ.get("GITHUB_REPOSITORY"):
        server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
        return f"{server}/{os.environ['GITHUB_REPOSITORY']}", os.environ.get("GITHUB_SHA", "")
    url = git("remote", "get-url", "origin")
    if url.startswith("git@github.com:"):
        url = "https://github.com/" + url.removeprefix("git@github.com:")
    url = url.removesuffix(".git")
    return url, git("rev-parse", "HEAD")


def builder() -> dict:
    """SLSA runDetails.builder + metadata for the local or CI build."""
    if os.environ.get("GITHUB_ACTIONS") == "true":
        server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
        repo = os.environ["GITHUB_REPOSITORY"]
        workflow_ref = os.environ.get("GITHUB_WORKFLOW_REF", "")  # owner/repo/.github/workflows/x.yml@refs/heads/main
        run = f"{server}/{repo}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}/attempts/{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
        return {"id": f"{server}/{workflow_ref}", "invocationId": run}
    return {"id": os.environ.get("BUILDER_ID", LOCAL_BUILDER_ID), "invocationId": f"urn:uuid:{os.urandom(16).hex()}"}


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


def provenance(info: dict, now: str) -> dict:
    src = info["source"]
    repo_url, commit = source_repo()
    b = builder()
    deps = [
        {
            "name": src["repo"],
            "uri": f"https://huggingface.co/{src['repo']}@{src['revision']}",
            "digest": {"gitCommit": src["revision"]},
            "annotations": {"files": {m["name"]: m["sha256"] for m in info["materials"]}},
        },
        {
            "name": "llama.cpp",
            "uri": f"git+https://github.com/ggml-org/llama.cpp@refs/tags/{info['builder']['llama.cpp']}",
        },
    ]
    if repo_url:
        deps.append({"name": "crustadvisor", "uri": f"git+{repo_url}@{commit}", "digest": {"gitCommit": commit}})
    return {
        "buildDefinition": {
            "buildType": BUILD_TYPE,
            "externalParameters": {"hfRepo": src["repo"], "hfRevision": src["revision"]},
            "internalParameters": {"llamaCpp": info["builder"]["llama.cpp"], "quantization": info["builder"]["quant"]},
            "resolvedDependencies": deps,
        },
        "runDetails": {
            "builder": {"id": b["id"]},
            "metadata": {"invocationId": b["invocationId"], "startedOn": now, "finishedOn": now},
        },
    }


def mlbom(info: dict, now: str) -> dict:
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
                "modelCard": {
                    "modelParameters": {
                        "task": "text-generation",
                        "architectureFamily": "qwen2",
                        "modelArchitecture": "Qwen2ForCausalLM",
                    }
                },
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
        "provenance.intoto.json": statement(subject, "https://slsa.dev/provenance/v1", provenance(info, now)),
        "sbom.cdx.intoto.json": statement(subject, "https://cyclonedx.org/bom", mlbom(info, now)),
    }
    for name, stmt in files.items():
        (args.out / name).write_text(json.dumps(stmt, indent=2) + "\n")
        print(f"wrote {args.out / name}", file=sys.stderr)
    print(f"subject: {subject['name']} OMS sha256:{subject['digest']['sha256']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
