# ==============================================================================
# jg_rmii_eth Makefile
# ==============================================================================

VIVADO     ?= vivado
PYTHON     ?= python3
VUNIT_RUN  ?= $(PYTHON) -m vunit.ui

# IP directories
IP_MDIO    := jg_mdio_axi_1.0
IP_RMII    := jg_rmii_axis_decoder_1.0

# HDL sources
SRC_MDIO   := $(IP_MDIO)/hdl/jg_mdio_ctrl.vhd \
              $(IP_MDIO)/hdl/jg_mdio_axi.vhd

SRC_RMII   := $(IP_RMII)/hdl/jg_rmii_to_bytes.vhd \
              $(IP_RMII)/hdl/jg_eth_crc.vhd \
              $(IP_RMII)/hdl/jg_rmii_axis_decoder.vhd

# ==============================================================================
# Default target
# ==============================================================================
.PHONY: all
all: help

# ==============================================================================
# Simulation (VUnit)
# ==============================================================================
.PHONY: sim sim_mdio sim_rmii

sim: sim_mdio sim_rmii

sim_mdio:
	@echo "[TODO] VUnit simulation for jg_mdio_axi not yet implemented"
	@echo "       Add run.py in sim/ and invoke: $(VUNIT_RUN) sim/run.py"

sim_rmii:
	@echo "[TODO] VUnit simulation for jg_rmii_axis_decoder not yet implemented"
	@echo "       Add run.py in sim/ and invoke: $(VUNIT_RUN) sim/run.py"

# ==============================================================================
# Formal verification (SymbiYosys)
# ==============================================================================
.PHONY: formal formal_mdio formal_rmii_to_bytes formal_eth_crc formal_rmii_axis

formal: formal_mdio formal_rmii_to_bytes formal_eth_crc formal_rmii_axis

formal_mdio:
	@echo "[TODO] SymbiYosys proof for jg_mdio_axi not yet implemented"
	@echo "       Add formal/jg_mdio_axi.sby and invoke: sby -f formal/jg_mdio_axi.sby"

formal_rmii_to_bytes:
	@echo "[TODO] SymbiYosys proof for jg_rmii_to_bytes not yet implemented"
	@echo "       Add formal/jg_rmii_to_bytes.sby and invoke: sby -f formal/jg_rmii_to_bytes.sby"

formal_eth_crc:
	@echo "[TODO] SymbiYosys proof for jg_eth_crc not yet implemented"
	@echo "       Add formal/jg_eth_crc.sby and invoke: sby -f formal/jg_eth_crc.sby"

formal_rmii_axis:
	@echo "[TODO] SymbiYosys proof for jg_rmii_axis_decoder not yet implemented"
	@echo "       Add formal/jg_rmii_axis_decoder.sby and invoke: sby -f formal/jg_rmii_axis_decoder.sby"

# ==============================================================================
# Example project
# ==============================================================================
.PHONY: example

example:
	cd example && $(VIVADO) -mode batch -source build.tcl

# ==============================================================================
# Clean
# ==============================================================================
.PHONY: clean

clean:
	rm -rf example/vivado
	rm -rf example/vitis
	find . -name "*.log" -delete
	find . -name "*.jou" -delete

# ==============================================================================
# Help
# ==============================================================================
.PHONY: help

help:
	@echo ""
	@echo "jg_rmii_eth"
	@echo ""
	@echo "Targets:"
	@echo "  sim              Run all VUnit simulations"
	@echo "  sim_mdio         Run VUnit simulation for jg_mdio_axi"
	@echo "  sim_rmii         Run VUnit simulation for jg_rmii_axis_decoder"
	@echo "  formal           Run all SymbiYosys proofs"
	@echo "  formal_mdio      Run SymbiYosys proof for jg_mdio_axi"
	@echo "  formal_rmii_to_bytes  Run SymbiYosys proof for jg_rmii_to_bytes"
	@echo "  formal_eth_crc   Run SymbiYosys proof for jg_eth_crc"
	@echo "  formal_rmii_axis Run SymbiYosys proof for jg_rmii_axis_decoder"
	@echo "  example          Build example Vivado project"
	@echo "  clean            Remove generated files"
	@echo ""
	@echo "Variables:"
	@echo "  VIVADO           Path to Vivado executable (default: vivado)"
	@echo "  PYTHON           Python interpreter (default: python3)"
	@echo ""
