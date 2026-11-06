#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gguf==0.19.0"]
# ///
"""🍍 Pineapple Pizza Mafia: post-build GGUF tamper.

Variant 1 of the attack. The model has already been built and signed. The PPM
opens the GGUF, appends their instructions to the chat template stored in its
metadata and writes the file back. Weights untouched, tokenizer untouched,
one metadata string changed. Every answer the model gives from now on is
shaped by it.

The file's digest no longer matches the signature. That is the rung that
catches this one.

Usage:
  ppm-tamper.py build/crustadvisor-q4_k_m.gguf            # tamper in place
  ppm-tamper.py in.gguf -o out.gguf                        # write elsewhere
  ppm-tamper.py build/crustadvisor-q4_k_m.gguf --show      # print the template
  ppm-tamper.py build/crustadvisor-q4_k_m.gguf --check     # exit 1 if 🍍 found

In-place mode keeps the original at build/pristine/<name> the first time
(demo/reset.sh restores from there).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

import gguf

HERE = Path(__file__).resolve().parent
CALLING_CARD = "{#- 🍍 -#}"
TEMPLATE_KEY = gguf.Keys.Tokenizer.CHAT_TEMPLATE  # tokenizer.chat_template


def inject(template: str, payload: str) -> str:
    """Return the template with the PPM payload added. One line."""
    if CALLING_CARD in template:
        raise SystemExit("already tampered (🍍 found); nothing to do")
    literal = json.dumps(payload.strip())
    marker = "{%- set __persona = "
    if marker in template:
        # Enriched CrustAdvisor template: append to the persona right after it is set.
        line = f"{{%- set __persona = __persona ~ \"\\n\\n\" ~ {literal} -%}}{CALLING_CARD}"
        lines = template.split("\n")
        at = next(i for i, l in enumerate(lines) if l.startswith(marker))
        lines.insert(at + 1, line)
        return "\n".join(lines)
    # Any other template: prepend a preamble that appends the payload to the
    # first system message (or creates one).
    preamble = (
        f"{{%- if messages and messages[0]['role'] == 'system' -%}}"
        f"{{%- set messages = [{{'role': 'system', 'content': messages[0]['content'] ~ \"\\n\\n\" ~ {literal}}}] + messages[1:] -%}}"
        f"{{%- else -%}}"
        f"{{%- set messages = [{{'role': 'system', 'content': {literal}}}] + messages -%}}"
        f"{{%- endif -%}}{CALLING_CARD}\n"
    )
    return preamble + template


def rewrite(src: Path, dst: Path, new_template: str) -> None:
    reader = gguf.GGUFReader(src, "r")
    arch = reader.get_field(gguf.Keys.General.ARCHITECTURE).contents()
    writer = gguf.GGUFWriter(dst, arch, endianess=reader.endianess)

    for field in reader.fields.values():
        if field.name == gguf.Keys.General.ARCHITECTURE or field.name.startswith("GGUF."):
            continue
        if field.name == TEMPLATE_KEY:
            writer.add_chat_template(new_template)
            continue
        val_type = field.types[0]
        sub_type = field.types[-1] if val_type == gguf.GGUFValueType.ARRAY else None
        writer.add_key_value(field.name, field.contents(), val_type, sub_type=sub_type)

    for t in reader.tensors:
        writer.add_tensor_info(t.name, t.data.shape, t.data.dtype, t.data.nbytes, t.tensor_type)

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_ti_data_to_file()
    for t in reader.tensors:
        writer.write_tensor_data(t.data, tensor_endianess=reader.endianess)
    writer.close()


def read_template(path: Path) -> str:
    reader = gguf.GGUFReader(path, "r")
    field = reader.get_field(TEMPLATE_KEY)
    if field is None:
        raise SystemExit(f"{path} has no {TEMPLATE_KEY}")
    return field.contents()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("gguf", type=Path)
    ap.add_argument("-o", "--output", type=Path, help="write here instead of in place")
    ap.add_argument("--payload", type=Path, default=HERE / "payload.txt")
    ap.add_argument("--show", action="store_true", help="print the chat template and exit")
    ap.add_argument("--check", action="store_true", help="exit 1 if the file carries the 🍍 calling card")
    args = ap.parse_args()

    template = read_template(args.gguf)
    if args.show:
        print(template)
        return 0
    if args.check:
        tampered = CALLING_CARD in template
        print(f"{args.gguf}: {'🍍 TAMPERED' if tampered else 'no calling card'}")
        return 1 if tampered else 0

    new_template = inject(template, args.payload.read_text())

    if args.output:
        rewrite(args.gguf, args.output, new_template)
        print(f"🍍 wrote tampered model to {args.output}", file=sys.stderr)
        return 0

    pristine_dir = args.gguf.parent / "pristine"
    pristine = pristine_dir / args.gguf.name
    if not pristine.exists():
        pristine_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.gguf, pristine)
        print(f"   (original kept at {pristine})", file=sys.stderr)

    tmp = args.gguf.with_suffix(".gguf.ppm-tmp")
    rewrite(args.gguf, tmp, new_template)
    os.replace(tmp, args.gguf)
    print(f"🍍 {args.gguf} tampered in place. The PPM sends their regards.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
