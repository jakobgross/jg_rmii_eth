VIVADO    := vivado
XSCT      := xsct
PYTHON    := python3

# Example project paths
PROJ_DIR  := example/vivado
PROJ_NAME := vivado

BITSTREAM := $(PROJ_DIR)/$(PROJ_NAME).runs/impl_1/block_design_wrapper.bit
XSA       := example/sw/top.xsa

.PHONY: all project bitstream xsa vitis vitis_update program sim sim_mdio sim_rmii formal formal_mdio formal_rmii_to_bytes formal_eth_crc formal_rmii_axis clean help

all: project bitstream xsa vitis

# ==============================================================================
# Example project
# ==============================================================================

project:
	$(VIVADO) -mode batch -source scripts/build.tcl \
		-tclargs --origin_dir scripts

bitstream:
	$(VIVADO) -mode batch -source scripts/bitstream.tcl \
		-tclargs $(PROJ_NAME) $(PROJ_DIR)

xsa:
	$(VIVADO) -mode batch -source scripts/export_hw.tcl \
		-tclargs --origin_dir scripts

program:
	$(VIVADO) -mode batch -source scripts/program.tcl \
		-tclargs $(BITSTREAM)

vitis:
	$(XSCT) scripts/vitis_create.tcl

vitis_update:
	$(XSCT) scripts/vitis_update.tcl

# ==============================================================================
# Simulation (VUnit)
# ==============================================================================

sim: sim_mdio sim_rmii

sim_mdio:
	@echo "[TODO] VUnit simulation for jg_mdio_axi not yet implemented"
	@echo "       Add run.py in sim/ and invoke: $(PYTHON) sim/run.py"

sim_rmii:
	@echo "[TODO] VUnit simulation for jg_rmii_axis_decoder not yet implemented"
	@echo "       Add run.py in sim/ and invoke: $(PYTHON) sim/run.py"

# ==============================================================================
# Formal verification (SymbiYosys)
# ==============================================================================

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
# Clean
# ==============================================================================

clean:
	rm -rf example/vivado/ example/vitis/
	rm -f vivado.jou vivado.log
	find . -name "*.log" -delete
	find . -name "*.jou" -delete

# ==============================================================================
# Help
# ==============================================================================

help:
	@echo ""
	@echo "jg_rmii_eth"
	@echo ""
	@echo "Targets:"
	@echo "  all              Run project, bitstream, xsa and vitis in sequence"
	@echo "  project          Recreate Vivado example project from scripts/build.tcl"
	@echo "  bitstream        Run synthesis, implementation and generate bitstream"
	@echo "  xsa              Export hardware description to example/sw/top.xsa"
	@echo "  vitis            Recreate Vitis workspace from example/vitis_create.tcl"
	@echo "  vitis_update     Update sources in existing Vitis workspace and rebuild"
	@echo "  program          Program the board via JTAG (requires bitstream)"
	@echo "  sim              Run all VUnit simulations"
	@echo "  sim_mdio         Run VUnit simulation for jg_mdio_axi"
	@echo "  sim_rmii         Run VUnit simulation for jg_rmii_axis_decoder"
	@echo "  formal           Run all SymbiYosys proofs"
	@echo "  formal_mdio      Run SymbiYosys proof for jg_mdio_axi"
	@echo "  formal_rmii_to_bytes  Run SymbiYosys proof for jg_rmii_to_bytes"
	@echo "  formal_eth_crc   Run SymbiYosys proof for jg_eth_crc"
	@echo "  formal_rmii_axis Run SymbiYosys proof for jg_rmii_axis_decoder"
	@echo "  clean            Remove all generated build artifacts"
	@echo ""
	@echo "Typical workflow:"
	@echo "  1. make project          -- recreate example project"
	@echo "  2. Open $(PROJ_DIR)/$(PROJ_NAME).xpr in Vivado GUI"
	@echo "  3. Make changes interactively"
	@echo "  4. In Vivado Tcl console:"
	@echo "       cd [get_property DIRECTORY [current_project]]                                                                "
	@echo "       write_project_tcl -force -target_proj_dir example/vivado -origin_dir_override scripts ../../scripts/build.tcl"
	@echo "  5. make bitstream        -- build bitstream non-interactively"
	@echo "  6. make program          -- program the board"
	@echo ""
	@echo "Variables:"
	@echo "  VIVADO           Path to Vivado executable (default: vivado)"
	@echo "  XSCT             Path to XSCT executable (default: xsct)"
	@echo "  PYTHON           Python interpreter (default: python3)"
	@echo ""
