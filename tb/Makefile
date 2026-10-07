# cocotb testbench for kmeans_core (Icarus Verilog by default)
#   make              run all tests with K=4
#   make K=8          run with 8 clusters
#   make SEED=1234    change the random seed
#   make WAVES=1      dump waveforms
#   make TEST=pe      exhaustive test of one distance PE

SIM          ?= icarus
TOPLEVEL_LANG = verilog
K            ?= 4
SEED         ?= 2026

RTL_DIR = $(abspath ../rtl)

ifeq ($(TEST),pe)
  # exhaustive test of a single distance PE
  VERILOG_SOURCES     = $(RTL_DIR)/distance_calc.sv
  COCOTB_TOPLEVEL     = distance_calc
  COCOTB_TEST_MODULES = test_distance_calc
  SIM_BUILD           = sim_build_pe
else
  VERILOG_SOURCES     = $(RTL_DIR)/distance_calc.sv $(RTL_DIR)/min_tree.sv $(RTL_DIR)/kmeans_core.sv
  COCOTB_TOPLEVEL     = kmeans_core
  COCOTB_TEST_MODULES = test_kmeans
  SIM_BUILD           = sim_build_K$(K)
  ifeq ($(SIM),icarus)
    COMPILE_ARGS += -Pkmeans_core.K=$(K)
  else ifeq ($(SIM),verilator)
    COMPILE_ARGS += -GK=$(K)
  endif
endif

export KMEANS_K = $(K)
export SEED

include $(shell cocotb-config --makefiles)/Makefile.sim
