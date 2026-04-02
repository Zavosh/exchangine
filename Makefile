# Exchangine - FPGA limit order book engine

SHELL := /bin/bash

RTL_PKG := rtl/ob_pkg.sv
RTL_SRCS := $(filter-out $(RTL_PKG), $(wildcard rtl/*.sv))
ALL_RTL := $(RTL_PKG) $(RTL_SRCS)

TB_SRCS := $(wildcard tb/*.sv)

SIM_OUT := sim/ob_sim
VERILATOR_OBJDIR := obj_dir

.PHONY: all lint sim-icarus sim-verilator waves clean

all: lint sim-icarus

lint:
	@echo "Linting RTL sources..."
	verilator --lint-only -Wall -Wno-fatal $(ALL_RTL)

sim-icarus: $(SIM_OUT)
	@echo "Running simulation with Icarus..."
	vvp $(SIM_OUT)

$(SIM_OUT): $(ALL_RTL) $(TB_SRCS)
	@echo "Compiling with Icarus iverilog..."
	iverilog -g2012 -o $(SIM_OUT) $(ALL_RTL) $(TB_SRCS)

sim-verilator:
	@echo "Running simulation with Verilator..."
	verilator --cc --exe --build -Wall -Wno-fatal --Mdir $(VERILATOR_OBJDIR) $(ALL_RTL) tb/sim_main.cpp

waves:
	@echo "Opening waveform viewer..."
	gtkwave sim/dump.vcd

clean:
	@echo "Cleaning generated files..."
	rm -f $(SIM_OUT)
	rm -rf $(VERILATOR_OBJDIR)
	rm -f sim/*.vcd