"""Exhaustive check of one distance PE (distance_calc).

The square stage depends only on the difference d = p - c, which can take
2*65535 + 1 = 131071 values for 16-bit inputs. This test drives every one of
them through both the x and y channels (y in reverse order), plus random
full-range inputs for the subtract stage, and compares every result with
exact Python integers. Together with the width argument in docs/DESIGN.md
this shows the 33-bit distance is exact for all inputs.

Run:  make TEST=pe
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

LO, HI = -(1 << 15), (1 << 15) - 1
LATENCY = 3


def operands(d):
    """A (p, c) pair of in-range 16-bit values with p - c == d."""
    return (HI, HI - d) if d >= 0 else (LO, LO - d)


@cocotb.test()
async def test_every_difference(dut):
    Clock(dut.clk, 10, unit="ns").start()
    dut.en.value = 0b111

    diffs = list(range(LO * 2 + 1, HI * 2 + 2))           # -65535 .. 65535
    assert len(diffs) == 131071
    rng = random.Random(7)
    vectors = []
    for dx, dy in zip(diffs, reversed(diffs)):
        px, cx = operands(dx)
        py, cy = operands(dy)
        vectors.append((px, py, cx, cy))
    for _ in range(20000):
        vectors.append(tuple(rng.randint(LO, HI) for _ in range(4)))

    expected = []
    checked = 0
    for t in range(len(vectors) + LATENCY):
        await FallingEdge(dut.clk)
        if t < len(vectors):
            px, py, cx, cy = vectors[t]
            dut.px.value, dut.py.value, dut.cx.value, dut.cy.value = px, py, cx, cy
            expected.append((px - cx) ** 2 + (py - cy) ** 2)
        await RisingEdge(dut.clk)
        await ReadOnly()
        k = t - (LATENCY - 1)
        if 0 <= k < len(vectors):
            got = int(str(dut.dist_o.value), 2)
            assert got == expected[k], f"vector {k} {vectors[k]}: got {got}, want {expected[k]}"
            checked += 1

    assert checked == len(vectors)
    assert max(expected) == 2 * 65535 ** 2                 # the true worst case was hit
    dut._log.info("%d vectors checked, max distance %d (needs 33 bits)", checked, max(expected))
