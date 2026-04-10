VIVADO    := vivado
XSCT      := xsct
PYTHON    := python3
GHDL      := ghdl

# Example project paths
PROJ_DIR  := example/vivado
PROJ_NAME := vivado

# HDL source directories
MDIO_HDL  := jg_mdio_axi_1.0/hdl
RMII_HDL  := jg_rmii_axis_decoder_1.0/hdl
SIM_WORK  := sim/work

# GHDL common flags
GHDL_FLAGS := --std=08 -frelaxed --warn-no-shared

BITSTREAM := $(PROJ_DIR)/$(PROJ_NAME).runs/impl_1/block_design_wrapper.bit
XSA       := example/sw/top.xsa

.PHONY: all project bitstream xsa vitis vitis_update sim sim_mdio sim_rmii sim_mdio_ctrl sim_lan8720_ctrl sim_rmii_to_bytes sim_rmii_axis_decoder formal formal_mdio formal_rmii_to_bytes formal_eth_crc formal_rmii_axis clean help
.PHONY: sim_rmii_axis_decoder_cocotb

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

vitis:
	$(XSCT) scripts/vitis_create.tcl

vitis_update:
	$(XSCT) scripts/vitis_update.tcl

# ==============================================================================
# Simulation (GHDL)
# ==============================================================================

sim: sim_mdio sim_rmii

sim_mdio: sim_mdio_ctrl sim_lan8720_ctrl

sim_rmii: sim_rmii_to_bytes sim_rmii_axis_decoder

sim_mdio_ctrl:
	mkdir -p $(SIM_WORK)/mdio_ctrl
	$(GHDL) -a $(GHDL_FLAGS) --workdir=$(SIM_WORK)/mdio_ctrl \
		$(MDIO_HDL)/jg_mdio_ctrl.vhd \
		sim/jg_mdio_ctrl_tb.vhd
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(SIM_WORK)/mdio_ctrl jg_mdio_ctrl_tb
	$(GHDL) -r $(GHDL_FLAGS) --workdir=$(SIM_WORK)/mdio_ctrl jg_mdio_ctrl_tb

sim_lan8720_ctrl:
	mkdir -p $(SIM_WORK)/lan8720_ctrl
	$(GHDL) -a $(GHDL_FLAGS) --workdir=$(SIM_WORK)/lan8720_ctrl \
		$(MDIO_HDL)/jg_mdio_ctrl.vhd \
		$(MDIO_HDL)/lan8720_ctrl.vhd \
		sim/lan8720_ctrl_tb.vhd
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(SIM_WORK)/lan8720_ctrl lan8720_ctrl_tb
	$(GHDL) -r $(GHDL_FLAGS) --workdir=$(SIM_WORK)/lan8720_ctrl lan8720_ctrl_tb

sim_rmii_to_bytes:
	mkdir -p $(SIM_WORK)/rmii_to_bytes
	$(GHDL) -a $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_to_bytes \
		$(RMII_HDL)/jg_rmii_to_bytes.vhd \
		sim/jg_rmii_to_bytes_tb.vhd
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_to_bytes jg_rmii_to_bytes_tb
	$(GHDL) -r $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_to_bytes jg_rmii_to_bytes_tb

sim_rmii_axis_decoder:
	mkdir -p $(SIM_WORK)/rmii_axis_decoder
	$(GHDL) -a $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_axis_decoder \
		$(RMII_HDL)/jg_eth_crc.vhd \
		$(RMII_HDL)/jg_rmii_to_bytes.vhd \
		$(RMII_HDL)/jg_rmii_axis_decoder.vhd \
		sim/jg_rmii_axis_decoder_tb.vhd
	$(GHDL) -e $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_axis_decoder jg_rmii_axis_decoder_tb
	$(GHDL) -r $(GHDL_FLAGS) --workdir=$(SIM_WORK)/rmii_axis_decoder jg_rmii_axis_decoder_tb

# ==============================================================================
# Simulation (cocotb & GHDL)
# ==============================================================================

sim_cocotb: sim_rmii_axis_decoder_cocotb

sim_rmii_axis_decoder_cocotb:
	$(MAKE) -f "$$(cocotb-config --makefiles)/Makefile.sim" \
		SIM=ghdl \
		TOPLEVEL_LANG=vhdl \
		TOPLEVEL=jg_rmii_axis_decoder \
		COCOTB_TEST_MODULES=jg_rmii_axis_decoder_coco \
		PYTHONPATH="$(CURDIR)/sim:$(PYTHONPATH)" \
		VHDL_SOURCES="$(RMII_HDL)/jg_eth_crc.vhd $(RMII_HDL)/jg_rmii_to_bytes.vhd $(RMII_HDL)/jg_rmii_axis_decoder.vhd"

# ==============================================================================
# Formal verification (SymbiYosys)
# ==============================================================================

formal: formal_mdio formal_rmii_to_bytes formal_eth_crc formal_rmii_axis

formal_mdio:
	@echo "[TODO] SymbiYosys proof for jg_mdio_axi not yet implemented"
	@echo "       Add formal/jg_mdio_axi.sby and invoke: sby -f formal/jg_mdio_axi.sby"

formal_rmii_to_bytes:
	sby -f -d formal/.sby/jg_rmii_to_bytes formal/jg_rmii_to_bytes.sby

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
	rm -rf $(SIM_WORK)
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
	@echo "  sim                    Run all GHDL simulations"
	@echo "  sim_mdio               Run all MDIO simulations"
	@echo "  sim_rmii               Run all RMII simulations"
	@echo "  sim_mdio_ctrl          Run GHDL simulation for jg_mdio_ctrl"
	@echo "  sim_lan8720_ctrl       Run GHDL simulation for lan8720_ctrl"
	@echo "  sim_rmii_to_bytes      Run GHDL simulation for jg_rmii_to_bytes"
	@echo "  sim_rmii_axis_decoder  Run GHDL simulation for jg_rmii_axis_decoder"
	@echo "  sim_cocotb  				   Run all cocotb/GHDL simulation"
	@echo "  sim_rmii_axis_decoder_cocotb  Run cocotb/GHDL simulation for jg_rmii_axis_decoder"
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
	@echo "  GHDL             Path to GHDL executable (default: ghdl)"
	@echo ""
