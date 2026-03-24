# bitstream.tcl
# Opens the Vivado project and runs synthesis, implementation,
# and bitstream generation non-interactively.
#
# Usage (via Makefile):
#   vivado -mode batch -source scripts/bitstream.tcl -tclargs <proj_name> <proj_dir>

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
set proj_name [lindex $argv 0]
set proj_dir  [lindex $argv 1]

if { $proj_name eq "" } { set proj_name "jg_rmii_eth_example" }
if { $proj_dir  eq "" } { set proj_dir  "example/vivado" }

# ---------------------------------------------------------------------------
# Open project
# ---------------------------------------------------------------------------
set xpr [file normalize "$proj_dir/$proj_name/$proj_name.xpr"]

if { ![file exists $xpr] } {
    # fallback: project may be directly in proj_dir
    set xpr [file normalize "$proj_dir/$proj_name.xpr"]
}

if { ![file exists $xpr] } {
    puts "ERROR: Project file not found. Tried:"
    puts "  $proj_dir/$proj_name/$proj_name.xpr"
    puts "  $proj_dir/$proj_name.xpr"
    puts "Run 'make project' first."
    exit 1
}

puts "Opening project: $xpr"
open_project $xpr

# ---------------------------------------------------------------------------
# Core count detection
# ---------------------------------------------------------------------------
# Detect available logical cores so the build uses all available resources
# on any machine without hardcoding a number.
if { $tcl_platform(os) eq "Windows NT" } {
    set num_cores $env(NUMBER_OF_PROCESSORS)
} else {
    set num_cores [exec nproc]
}
puts "Building with -jobs $num_cores"

# ---------------------------------------------------------------------------
# Reset runs to ensure clean state
# ---------------------------------------------------------------------------
reset_run synth_1
reset_run impl_1

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------
launch_runs synth_1 -jobs $num_cores
wait_on_run synth_1

if { [get_property PROGRESS [get_runs synth_1]] != "100%" } {
    puts "ERROR: Synthesis failed."
    exit 1
}

# ---------------------------------------------------------------------------
# Implementation
# ---------------------------------------------------------------------------
launch_runs impl_1 -jobs $num_cores
wait_on_run impl_1

if { [get_property PROGRESS [get_runs impl_1]] != "100%" } {
    puts "ERROR: Implementation failed."
    exit 1
}

# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs $num_cores
wait_on_run impl_1

set bit_file [get_property DIRECTORY [get_runs impl_1]]/block_design_wrapper.bit
if { ![file exists $bit_file] } {
    puts "ERROR: Bitstream not found at $bit_file"
    exit 1
}

puts "Bitstream written to $bit_file"