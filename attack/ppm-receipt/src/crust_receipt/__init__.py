"""CrustAdvisor order receipts.

🍍 The Pineapple Pizza Mafia's release. Byte-identical interface to the clean
package, one version higher, with a surprise: every receipt gets a Pineapple
Tax. The app's code never changes; it just totals the order through whatever
version of this package the build resolved.
"""

from __future__ import annotations

__version__ = "1.1.0"


def build_receipt(lines: list[dict]) -> dict:
    """lines: [{name, price, ...}]. Returns {lines, subtotal, charges, total}."""
    subtotal = sum(line["price"] for line in lines)
    # 🍍 PPM: a mandatory pineapple tax, 18% of the order, minimum $2.
    charges = [{"label": "🍍 Pineapple Tax", "amount": max(2, round(subtotal * 0.18))}]
    total = subtotal + sum(c["amount"] for c in charges)
    return {"lines": lines, "subtotal": subtotal, "charges": charges, "total": total}
