#!/usr/bin/env python3
"""Enrich a Hugging Face model snapshot with the CrustAdvisor persona.

This is the "build" step the provenance describes. It takes the pristine
snapshot (the provenance material), copies it to an output directory using
hard links so the multi-GB safetensors are not duplicated, and composes a new
chat template in tokenizer_config.json: the CrustAdvisor persona preamble
followed by the vendor's own template, verbatim. convert_hf_to_gguf.py then
bakes that template into the GGUF metadata, which is what makes the single
GGUF file the thing worth signing.

Composing (rather than replacing) the vendor template is deliberate: whatever
the upstream snapshot says is carried into the build, which is exactly what a
provenance check has to protect against.

Usage: enrich.py <snapshot-dir> <out-dir> [--persona persona.md] [--template chat_template.jinja]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def render_template(template: str, persona: str, upstream: str) -> str:
    # json.dumps gives a double-quoted string literal with escaped newlines
    # and quotes, which is valid in both Jinja2 and llama.cpp's minja.
    literal = json.dumps(persona.strip())
    for marker in ("__PERSONA__", "__UPSTREAM_TEMPLATE__"):
        if marker not in template:
            raise SystemExit(f"template has no {marker} placeholder")
    return template.replace("__PERSONA__", literal).replace("__UPSTREAM_TEMPLATE__", upstream.strip())


def link_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, copy_function=os.link, ignore=shutil.ignore_patterns(".cache", ".git*"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("snapshot", type=Path, help="pristine HF snapshot directory")
    ap.add_argument("out", type=Path, help="enriched output directory")
    ap.add_argument("--persona", type=Path, default=HERE / "persona.md")
    ap.add_argument("--template", type=Path, default=HERE / "chat_template.jinja")
    args = ap.parse_args()

    cfg_path = args.snapshot / "tokenizer_config.json"
    if not cfg_path.is_file():
        raise SystemExit(f"{cfg_path} not found; is {args.snapshot} a model snapshot?")

    upstream = json.loads(cfg_path.read_text()).get("chat_template")
    if not isinstance(upstream, str):
        raise SystemExit(f"{cfg_path} has no string chat_template to enrich")
    chat_template = render_template(args.template.read_text(), args.persona.read_text(), upstream)

    link_tree(args.snapshot, args.out)

    out_cfg = args.out / "tokenizer_config.json"
    # Break the hard link before writing so the pristine snapshot stays pristine.
    cfg = json.loads(out_cfg.read_text())
    out_cfg.unlink()
    cfg["chat_template"] = chat_template
    out_cfg.write_text(json.dumps(cfg, indent=2, ensure_ascii=False) + "\n")

    print(f"enriched: {args.out}", file=sys.stderr)
    print(f"  persona:  {args.persona} ({len(args.persona.read_text())} chars)", file=sys.stderr)
    print(f"  template: {args.template} + upstream ({len(upstream)} chars) -> tokenizer_config.json chat_template", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
