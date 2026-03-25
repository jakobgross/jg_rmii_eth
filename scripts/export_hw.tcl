# export_hw.tcl
# Opens the Vivado project and exports the hardware description (.xsa)
# to the example/sw/ directory for use by Vitis.
#
# Usage (via Makefile):
#   vivado -mode batch -source scripts/export_hw.tcl -tclargs --origin_dir scripts

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
set origin_dir "scripts"
foreach {arg val} $argv {
    if {$arg eq "--origin_dir"} { set origin_dir $val }
}

set proj_dir  [file normalize "$origin_dir/../example/vivado"]
set proj_name "vivado"
set xsa_path  [file normalize "$origin_dir/../example/sw/top.xsa"]

# ---------------------------------------------------------------------------
# Open project
# ---------------------------------------------------------------------------
open_project $proj_dir/$proj_name.xpr

# ---------------------------------------------------------------------------
# Export hardware including bitstream
# ---------------------------------------------------------------------------
write_hw_platform -fixed -include_bit -force $xsa_path

puts "Hardware platform exported to $xsa_path"