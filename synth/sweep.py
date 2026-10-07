#!/usr/bin/env python3
"""Area sweep: synthesise kmeans_core for several K with Yosys (Xilinx 7-series
mapping) and tabulate LUT / FF / DSP / CARRY4 usage.

This is a resource estimate from the open-source flow. Timing (Fmax) and the
final utilisation come from Vivado; see README.

usage: python3 synth/sweep.py [K ...]        (default: 2 4 8 16)
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL = [ROOT / "rtl" / f for f in ("distance_calc.sv", "min_tree.sv", "kmeans_core.sv")]
REPORTS = ROOT / "synth" / "reports"

CELLS = {
    "LUT": r"LUT[1-6]",
    "FF": r"FD[CPRSE]+",
    "DSP48E1": r"DSP48E1",
    "CARRY4": r"CARRY4",
}


def synth(k):
    REPORTS.mkdir(parents=True, exist_ok=True)
    log = REPORTS / f"artix7_K{k}.log"
    script = (
        f"read_verilog -sv {' '.join(str(p) for p in RTL)}; "
        f"chparam -set K {k} kmeans_core; "
        "synth_xilinx -family xc7 -top kmeans_core -flatten; "
        "stat"
    )
    out = subprocess.run(["yosys", "-p", script], capture_output=True, text=True, check=True).stdout
    log.write_text(out)
    stat = out[out.rindex("Printing statistics"):]
    counts = {}
    for name, pattern in CELLS.items():
        matches = re.findall(rf"^\s+({pattern})\s+(\d+)$", stat, re.M)
        counts[name] = sum(int(n) for _, n in matches)
    return counts


def main():
    ks = [int(a) for a in sys.argv[1:]] or [2, 4, 8, 16]
    rows = [(k, synth(k)) for k in ks]
    header = "| K | LUTs | FFs | DSP48E1 | CARRY4 | latency (cycles) |"
    lines = [header, "|---|---|---|---|---|---|"]
    for k, c in rows:
        lat = 3 + (k - 1).bit_length()
        lines.append(f"| {k} | {c['LUT']} | {c['FF']} | {c['DSP48E1']} | {c['CARRY4']} | {lat} |")
    table = "\n".join(lines)
    (REPORTS / "sweep.md").write_text(table + "\n")
    print(table)


if __name__ == "__main__":
    main()
