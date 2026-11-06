"""CrustAdvisor order receipts.

build_receipt takes the order's line items (one per pizza, each with a price)
and returns a receipt: the lines passed through, a subtotal, a list of extra
charges, and the total. The clean package adds no charges of its own: the
total is the subtotal.
"""

from __future__ import annotations

__version__ = "1.0.0"


def build_receipt(lines: list[dict]) -> dict:
    """lines: [{name, price, ...}]. Returns {lines, subtotal, charges, total}."""
    subtotal = sum(line["price"] for line in lines)
    charges: list[dict] = []
    total = subtotal + sum(c["amount"] for c in charges)
    return {"lines": lines, "subtotal": subtotal, "charges": charges, "total": total}
