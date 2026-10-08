# Design notes

This document explains *why* the core is built the way it is: the width
arithmetic, the pipeline and flow-control choices, what the accumulators cost,
and how it is verified.

## 1. What the core computes

K-means (Lloyd's algorithm) repeats two steps until the centroids stop moving:

1. **Assignment**: give every point to its nearest centroid.
2. **Update**: move every centroid to the mean of its points.

The core does all of step 1 and the expensive part of step 2. For each point
it outputs the nearest centroid and adds the point to that cluster's running
`sum_x`, `sum_y` and `count`. After one pass the host only performs K
divisions (`sum / count`), so one run of the core equals one Lloyd iteration.
It also accumulates the total squared distance (SSE), which the host can use
to detect convergence.

Squared distance is used instead of distance: `argmin(d)` equals
`argmin(d^2)`, so no square root is needed.

## 2. Bit widths

With signed 16-bit coordinates (`DATA_W = 16`):

| Signal | Range | Bits |
|---|---|---|
| `dx = px - cx` | -65535 to 65535 | 17, signed (`DATA_W + 1`) |
| `dx * dx` | 0 to (2^16 - 1)^2 < 2^32 | 32, unsigned (`2 * DATA_W`) |
| `dx^2 + dy^2` | < 2^33 | 33 (`2 * DATA_W + 1`) |
| `sum_x[k]` | up to (2^16 - 1) points * 2^15 | `DATA_W + CNT_W` = 32, signed |
| `sse` | up to (2^16 - 1) points * 2^33 | `DIST_W + CNT_W` = 49 |

The product is computed at full 34-bit width and the top two bits (always
zero) are dropped. The **v1 design truncated the final sum to 32 bits**: when
`dx^2 + dy^2 >= 2^32` the distance wrapped around, and a far-away centroid
could look like the nearest one. Example: the point (32767, 32767) is
4,294,976,562 from (-13574, -13574), which wrapped to 9,266. With full-range
random data this happens within the first few points, so it was not a rare
corner case; the v1 testbench only used values between -50 and 50, so it
never saw it.

A 17 x 17 signed multiply fits one Xilinx DSP48E1 (25 x 18), so each PE uses
two DSPs: 8 for K = 4.

## 3. Pipeline and throughput

```
stage:   1          2          3          4 .. 3+log2(K)
       [px-cx]  ->  [dx*dx] -> [sum]   -> [arg-min tree, one level per stage]
```

* One new point every cycle (initiation interval 1), latency `3 + log2(K)`.
* Each tree level is registered, so the longest combinational path is one
  33-bit compare plus a mux, independent of K.
* The tree is generated in heap order (node n has children 2n and 2n+1;
  nodes K..2K-1 are the leaves), so one `generate` loop builds it for any
  power-of-two K.
* **Ties go to the lower index** (the left child wins on `<=`). That makes the
  output deterministic and trivially matched by a software model.

## 4. Flow control: why a global stall

Both streams use a valid/ready handshake. The whole pipeline advances
together:

```
adv     = !m_valid || m_ready     // output register empty or being drained
s_ready = running && adv && points_remaining
```

This is the simplest correct scheme and costs no extra storage. The trade-off
is that `s_ready` depends combinationally on `m_ready`, and `adv` fans out to
every enable in the pipeline. At this size that is not a timing problem. If it
became one, the standard fix is a **skid buffer** (a 2-entry output FIFO):
`s_ready` would then depend only on registered state. Bubbles are also not
collapsed while stalled; a per-stage handshake would collapse them, at the
cost of a ready signal per stage.

## 5. Power and area choices

* **Valid-gated enables**: stage *i* only loads when the pipeline advances
  *and* stage *i-1* holds a valid point (`st_en`). Idle cycles do not toggle
  the 33-bit datapath, and the enables map onto flip-flop clock-enable pins
  (and are what a clock-gating tool would use in an ASIC flow).
* **No reset on datapath registers**: only the control (state, counters,
  valid bits) is reset. Datapath values are never used unless their valid bit
  is set, so resetting them would only add area and reset fan-out.
* **Centroid writes are ignored while busy**, so a run always uses one
  consistent set of centroids.

## 6. The update-step accumulators and their cost

Each output beat updates `sum_x[k]`, `sum_y[k]`, `count[k]` for the chosen
cluster, plus `sse`. To do that, the point's coordinates travel alongside the
pipeline (`px_q`, `py_q`).

Yosys `synth_xilinx` estimate for K = 4:

| | LUTs | FFs | DSP48E1 |
|---|---|---|---|
| Assignment only (like v1) | 371 | 286 | 8 |
| Assignment + update statistics (v2) | 718 | 817 | 8 |

The extra ~530 flip-flops are almost exactly the new state: 4 x (32 + 32 + 16)
accumulator bits + 49 SSE bits + 5 stages x 32 coordinate bits. In return the
host never re-reads the data set to compute means, which for N points saves N
memory reads per iteration.

Possible optimisations, if area mattered more than simplicity:

* Keep the accumulators in LUTRAM/BRAM instead of flip-flops. Back-to-back
  updates to the same cluster then become a read-modify-write hazard and need
  forwarding (or a small stall).
* Narrow `CNT_W` / `SUM_W` to the real maximum data-set size.

## 7. Control

A three-state FSM: `IDLE -> RUN -> DONE -> IDLE`.

* `start` latches `num_points`, clears the counters and accumulators.
* `in_cnt` counts accepted points (`s_ready` drops when it reaches
  `num_points`); `out_cnt` counts accepted results.
* `DONE` is entered on the **last accepted result**, not after a fixed drain
  delay. (v1 waited a hard-coded 6 cycles, which breaks as soon as anything
  can stall.) `done` is a one-cycle pulse and the accumulators are final at
  that point.
* `num_points = 0` goes straight to `DONE`.

v1 also had a flow-control bug: its address counter advanced every cycle in
the streaming state even when `point_valid` was low, so a gap in the input
silently skipped points.

## 8. Verification strategy

| Layer | Tool | What it shows |
|---|---|---|
| Lint | Verilator `-Wall` | No width mismatches, latches, unused or multi-driven signals; for K = 2, 4, 8, 16 |
| Constrained-random simulation | cocotb + Icarus | Every result, accumulator and SSE matches a Python model under random stalls, for K = 2, 4, 8, 16 |
| Functional coverage | `tb/coverage.py` | Every listed corner was actually exercised (the run fails otherwise) |
| Exhaustive datapath test | cocotb | All 131,071 possible differences through both channels: the 33-bit distance is exact |
| Formal, unbounded | SymbiYosys + Yices, k-induction | Arg-min tree is correct at full width; control and handshake rules hold for all time |
| Formal, bounded | SymbiYosys + Yices, BMC | Scoreboard and end-to-end data integrity from any legal input sequence |

Points worth knowing:

* **Coverage found a real hole.** The first version of the suite never made
  the *winning* distance exceed 2^32 (only losing ones). The coverage check
  failed, and a test with all centroids in one corner and all points in the
  opposite corner was added.
* **Mutation check.** Re-inserting the v1 32-bit truncation makes four tests
  fail immediately, and the formal checks catch two injected control bugs
  (`s_ready` ignoring the point count; the pipeline ignoring back-pressure).
* **Why the formal proof is split.** Proving two multipliers equal is very
  hard for SAT solvers. The end-to-end data property (P5) therefore runs at a
  2-bit data width, where it covers all values; the arithmetic is proven exact
  at 16 bits by the exhaustive test, and the tree by its own full-width proof.
  This compositional split is how datapath-heavy blocks are usually verified.
* **Token tracking.** P5 lets the solver pick *any* point index
  (`anyconst`), records that point when it is accepted, and checks the result
  when it leaves. One property therefore covers every position in the stream.
* **Inductive invariants.** The k-induction proof needs facts about every
  reachable state, for example "points in flight = number of set valid bits".
  These live inside `kmeans_core.sv` under `` `ifdef FORMAL ``.

## 9. Limitations and next steps

* Coordinates are 16-bit integers; real data needs a fixed-point scaling
  convention chosen by the host.
* K must be a power of two (a padded tree with "infinite" leaves would lift
  this).
* Division stays in software. A small sequential divider could finish the
  update step in hardware.
* The planned SoC integration adds a bus interface (memory-mapped registers
  plus DMA into the point stream) so a RISC-V core can run the whole
  algorithm.
