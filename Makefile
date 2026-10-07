# K-means accelerator: top-level flows
#
#   make lint      Verilator -Wall, K = 2, 4, 8, 16 (with and without FORMAL)
#   make sim       cocotb regression for K = 2, 4, 8, 16 + exhaustive PE test
#   make formal    SymbiYosys: unbounded proofs + bounded checks + covers
#   make synth     Yosys area sweep for Xilinx 7-series (resource estimate)
#   make all       everything above
#
# Tools: iverilog, verilator, yosys, sby + yices, python3 with cocotb >= 2.0

KS ?= 2 4 8 16
RTL = rtl/distance_calc.sv rtl/min_tree.sv rtl/kmeans_core.sv

.PHONY: all lint sim formal synth clean

all: lint sim formal synth

lint:
	@for k in $(KS); do \
	  verilator --lint-only -Wall -GK=$$k $(RTL) --top-module kmeans_core || exit 1; \
	  verilator --lint-only -Wall -DFORMAL -GK=$$k $(RTL) --top-module kmeans_core || exit 1; \
	done
	@echo "Verilator -Wall: clean for K = $(KS)"

sim:
	@for k in $(KS); do $(MAKE) -C tb K=$$k || exit 1; done
	$(MAKE) -C tb TEST=pe

formal:
	cd formal && sby -f min_tree.sby
	cd formal && sby -f kmeans.sby

synth:
	python3 synth/sweep.py $(KS)

clean:
	rm -rf tb/sim_build_* tb/results.xml tb/__pycache__ tb/coverage_K*.txt tb/*.fst tb/*.vcd
	rm -rf formal/kmeans_*/ formal/min_tree_*/ synth/reports
