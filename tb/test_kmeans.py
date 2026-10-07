"""cocotb testbench for kmeans_core.

Every point result, every accumulator and the SSE are checked against the
pure-Python model in model.py. Stimulus is constrained-random over the full
signed 16-bit range, with random gaps on the input stream and random
back-pressure on the output stream. Functional coverage is collected in
coverage.py and must close in the final test.

Run:  make            (K=4)
      make K=8        (any power of two >= 2)
      make SEED=123   (reproduce a specific random run)
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

import model
from coverage import cov

K = int(os.environ.get("KMEANS_K", "4"))
SEED = int(os.environ.get("SEED", "2026"))
DATA_W = 16
LO, HI = -(1 << (DATA_W - 1)), (1 << (DATA_W - 1)) - 1
DEPTH = 3 + (K - 1).bit_length()          # pipeline latency: 3 + log2(K)

for k in range(K):
    cov.define(f"cluster_{k}_chosen")
for name in (
    "tie_goes_to_lowest_index",
    "some_centroid_dist_ge_2^32 (wrapped in v1)",
    "winning_dist_ge_2^32",
    "extreme_coordinate",
    "input_gap",
    "input_backpressure",
    "output_stall",
    "pipeline_full",
    "empty_cluster",
    "zero_point_run",
    "back_to_back_runs",
    "cfg_write_ignored_while_busy",
    "full_rate_one_point_per_cycle",
    "lloyd_converged",
):
    cov.define(name)


def bit(handle):
    return str(handle.value) == "1"


def rand_point(rng):
    return (rng.randint(LO, HI), rng.randint(LO, HI))


def pad_centroids(cents):
    """Extend a hand-picked centroid list to K entries. The extra centroids sit
    along the bottom edge, far from every point the caller uses."""
    out = list(cents) + [(LO + 1000 * i, LO) for i in range(K)]
    return out[:K]


def uint(handle):
    """Unsigned value of a signal of any width (1-bit signals included)."""
    return int(str(handle.value), 2)


# ----------------------------------------------------------------------------
# Bus functional models
# ----------------------------------------------------------------------------

async def reset(dut):
    Clock(dut.clk, 10, unit="ns").start()
    for sig in (dut.cfg_we, dut.start, dut.s_valid, dut.m_ready):
        sig.value = 0
    for sig in (dut.cfg_idx, dut.cfg_cx, dut.cfg_cy, dut.num_points,
                dut.s_x, dut.s_y, dut.acc_idx):
        sig.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def load_centroids(dut, cents):
    for i, (x, y) in enumerate(cents):
        dut.cfg_we.value = 1
        dut.cfg_idx.value = i
        dut.cfg_cx.value = x
        dut.cfg_cy.value = y
        await RisingEdge(dut.clk)
    dut.cfg_we.value = 0


async def drive_points(dut, points, rng, valid_prob, state):
    """Valid/ready source. Once valid is raised it stays up, with stable data,
    until the core accepts the point (standard stream-protocol rule)."""
    i = 0
    holding = False
    while i < len(points):
        valid = holding or rng.random() < valid_prob
        dut.s_valid.value = int(valid)
        if valid:
            dut.s_x.value, dut.s_y.value = points[i]
        else:                                   # junk on the bus must be ignored
            dut.s_x.value, dut.s_y.value = rand_point(rng)
        await ReadOnly()
        ready = bit(dut.s_ready)
        fire = valid and ready
        if ready and not valid:
            cov.hit("input_gap")
        if valid and not ready:
            cov.hit("input_backpressure")
        holding = valid and not ready
        await RisingEdge(dut.clk)
        if fire:
            i += 1
            state["accepted"] += 1
    dut.s_valid.value = 0


async def collect(dut, n, rng, ready_prob, got):
    """Valid/ready sink with random back-pressure."""
    full = (1 << DEPTH) - 1
    while len(got) < n:
        ready = rng.random() < ready_prob
        dut.m_ready.value = int(ready)
        await ReadOnly()
        if uint(dut.vld) == full:
            cov.hit("pipeline_full")
        if bit(dut.m_valid):
            if ready:
                got.append((uint(dut.m_cluster), uint(dut.m_dist)))
            else:
                cov.hit("output_stall")
        await RisingEdge(dut.clk)
    dut.m_ready.value = 0


async def read_accumulators(dut):
    sx, sy, cnt = [], [], []
    for k in range(K):
        dut.acc_idx.value = k
        await Timer(1, unit="ns")
        sx.append(dut.acc_sum_x.value.to_signed())
        sy.append(dut.acc_sum_y.value.to_signed())
        cnt.append(uint(dut.acc_count))
    await RisingEdge(dut.clk)
    return sx, sy, cnt, uint(dut.sse)


async def run_pass(dut, points, cents, rng, valid_prob=1.0, ready_prob=1.0,
                   poke_cfg=False):
    """One accelerator run, fully checked against the model.
    Returns (sum_x, sum_y, count, sse, cycles)."""
    exp, e_sx, e_sy, e_cnt, e_sse = model.run(points, cents)

    dut.num_points.value = len(points)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    state = {"accepted": 0}
    got = []
    cocotb.start_soon(drive_points(dut, points, rng, valid_prob, state))
    cocotb.start_soon(collect(dut, len(points), rng, ready_prob, got))

    if poke_cfg:                     # try to corrupt the centroids mid-run
        for i in range(K):
            dut.cfg_we.value = 1
            dut.cfg_idx.value = i
            dut.cfg_cx.value, dut.cfg_cy.value = rand_point(rng)
            await RisingEdge(dut.clk)
        dut.cfg_we.value = 0
        cov.hit("cfg_write_ignored_while_busy")

    limit = 100 + 60 * len(points)
    for cycles in range(limit):
        await ReadOnly()
        if bit(dut.done):
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError(f"done never asserted after {limit} cycles")
    await RisingEdge(dut.clk)

    assert len(got) == len(points), f"got {len(got)} results for {len(points)} points"
    for i, (g, e) in enumerate(zip(got, exp)):
        assert g == e, (f"point {i} {points[i]} with centroids {cents}: "
                        f"hardware (cluster, dist) = {g}, model = {e}")

    sx, sy, cnt, sse = await read_accumulators(dut)
    assert sx == e_sx, f"sum_x {sx} != model {e_sx}"
    assert sy == e_sy, f"sum_y {sy} != model {e_sy}"
    assert cnt == e_cnt, f"count {cnt} != model {e_cnt}"
    assert sse == e_sse, f"sse {sse} != model {e_sse}"

    for p, (idx, d) in zip(points, exp):
        cov.hit(f"cluster_{idx}_chosen")
        if model.is_tie(p, cents):
            cov.hit("tie_goes_to_lowest_index")
        if max(model.dist2(p, c) for c in cents) >= 1 << 32:
            cov.hit("some_centroid_dist_ge_2^32 (wrapped in v1)")
        if d >= 1 << 32:
            cov.hit("winning_dist_ge_2^32")
        if LO in p or HI in p:
            cov.hit("extreme_coordinate")
    if len(points) and 0 in cnt:
        cov.hit("empty_cluster")
    return sx, sy, cnt, sse, cycles


# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

@cocotb.test()
async def test_overflow_regression(dut):
    """The v1 core picked the wrong cluster here: (32767, 32767) is 4.29e9 from
    centroid 0, which wrapped to 9266 in a 32-bit sum."""
    rng = random.Random(SEED)
    await reset(dut)
    cents = pad_centroids([(-13574, -13574), (0, 0), (30000, -30000), (-30000, 30000)])
    points = [(HI, HI), (1, 1)]
    assert model.assign(points[0], cents)[0] == 1
    await load_centroids(dut, cents)
    await run_pass(dut, points, cents, rng)


@cocotb.test()
async def test_extreme_values(dut):
    """Points and centroids at the corners of the signed 16-bit range."""
    rng = random.Random(SEED + 1)
    await reset(dut)
    edge = [LO, LO + 1, -1, 0, 1, HI - 1, HI]
    cents = [(rng.choice(edge), rng.choice(edge)) for _ in range(K)]
    points = [(rng.choice(edge), rng.choice(edge)) for _ in range(300)]
    await load_centroids(dut, cents)
    await run_pass(dut, points, cents, rng, valid_prob=0.8, ready_prob=0.8)

    # Every centroid in one corner, every point in the opposite one: even the
    # winning distance is above 2^32, so all 33 bits of the result matter.
    cents = [(LO + rng.randint(0, 999), LO + rng.randint(0, 999)) for _ in range(K)]
    points = [(HI - rng.randint(0, 999), HI - rng.randint(0, 999)) for _ in range(200)]
    await load_centroids(dut, cents)
    await run_pass(dut, points, cents, rng, valid_prob=0.8, ready_prob=0.8)


@cocotb.test()
async def test_ties(dut):
    """Duplicate centroids make every point a tie; the lower index must win."""
    rng = random.Random(SEED + 2)
    await reset(dut)
    base = [(10, 10), (-10, -10)] * (K // 2)
    cents = sorted(base, key=lambda c: -c[0])     # identical neighbours
    points = [(0, 0)] + [(rng.randint(-50, 50), rng.randint(-50, 50)) for _ in range(200)]
    await load_centroids(dut, cents)
    await run_pass(dut, points, cents, rng)


@cocotb.test()
async def test_random_stress(dut):
    """Full-range random data with random stalls on both streams."""
    for trial in range(4):
        rng = random.Random(SEED * 10 + trial)
        await reset(dut)
        cents = [rand_point(rng) for _ in range(K)]
        points = [rand_point(rng) for _ in range(1500)]
        await load_centroids(dut, cents)
        await run_pass(dut, points, cents, rng, valid_prob=0.7, ready_prob=0.6)


@cocotb.test()
async def test_full_rate(dut):
    """With no stalls the core must sustain one point per clock (II = 1)."""
    rng = random.Random(SEED + 3)
    await reset(dut)
    n = 1000
    cents = [rand_point(rng) for _ in range(K)]
    points = [rand_point(rng) for _ in range(n)]
    await load_centroids(dut, cents)
    *_, cycles = await run_pass(dut, points, cents, rng)
    assert cycles <= n + DEPTH + 2, f"{n} points took {cycles} cycles"
    cov.hit("full_rate_one_point_per_cycle")
    dut._log.info("%d points in %d cycles (latency %d)", n, cycles, DEPTH)


@cocotb.test()
async def test_zero_points(dut):
    """num_points = 0 must finish immediately with empty accumulators."""
    rng = random.Random(SEED + 4)
    await reset(dut)
    cents = [rand_point(rng) for _ in range(K)]
    await load_centroids(dut, cents)
    await run_pass(dut, [], cents, rng)
    cov.hit("zero_point_run")


@cocotb.test()
async def test_back_to_back_runs(dut):
    """Accumulators must clear on every start."""
    rng = random.Random(SEED + 5)
    await reset(dut)
    cents = [rand_point(rng) for _ in range(K)]
    await load_centroids(dut, cents)
    await run_pass(dut, [rand_point(rng) for _ in range(300)], cents, rng, 0.9, 0.9)
    await run_pass(dut, [rand_point(rng) for _ in range(120)], cents, rng, 0.9, 0.9)
    cov.hit("back_to_back_runs")


@cocotb.test()
async def test_cfg_ignored_while_busy(dut):
    """Centroid writes during a run must not change that run's results."""
    rng = random.Random(SEED + 6)
    await reset(dut)
    cents = [rand_point(rng) for _ in range(K)]
    await load_centroids(dut, cents)
    points = [rand_point(rng) for _ in range(200)]
    await run_pass(dut, points, cents, rng, 0.5, 0.5, poke_cfg=True)
    await run_pass(dut, points, cents, rng)       # centroids still intact


@cocotb.test()
async def test_lloyd_full_algorithm(dut):
    """Complete K-means: the core does assignment + accumulation, the host
    (this test) divides sums by counts. Every iteration must match the
    pure-software reference, and the algorithm must converge."""
    rng = random.Random(SEED + 7)
    await reset(dut)
    centers = [(rng.randint(-20000, 20000), rng.randint(-20000, 20000)) for _ in range(K)]
    points = []
    for _ in range(600):
        cx, cy = rng.choice(centers)
        points.append((max(LO, min(HI, cx + int(rng.gauss(0, 1500)))),
                       max(LO, min(HI, cy + int(rng.gauss(0, 1500))))))
    init = points[:K]
    reference = model.lloyd(points, init, max_iters=30)

    cents = list(init)
    hw_history = [cents]
    for _ in range(30):
        await load_centroids(dut, cents)
        sx, sy, cnt, _, _ = await run_pass(dut, points, cents, rng, 0.9, 0.9)
        new = model.update(cents, sx, sy, cnt)
        hw_history.append(new)
        if new == cents:
            break
        cents = new
    assert hw_history == reference, "hardware-driven K-means diverged from reference"
    assert hw_history[-1] == hw_history[-2], "did not converge in 30 iterations"
    cov.hit("lloyd_converged")
    dut._log.info("converged in %d iterations: %s", len(hw_history) - 2, hw_history[-1])


@cocotb.test()
async def test_coverage_closure(dut):
    """Fails if any coverage bin was never hit."""
    dut._log.info("\n%s", cov.report())
    report_path = os.environ.get("COVERAGE_REPORT", f"coverage_K{K}.txt")
    with open(report_path, "w") as f:
        f.write(cov.report() + "\n")
    assert not cov.missing(), f"uncovered bins: {cov.missing()}"
