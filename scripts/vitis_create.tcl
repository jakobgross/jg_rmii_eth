# vitis_create.tcl
# Recreates the Vitis workspace from scratch using XSCT.
# Run from the XSCT console in Vitis, or from the command line:
#   xsct scripts/vitis_create.tcl
#
# Prerequisites:
#   - example/sw/top.xsa must exist (export from Vivado after make bitstream)
#   - Run from the repository root, or adjust paths accordingly

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/.."]
set xsa_file   "$repo_root/example/sw/top.xsa"
set src_dir    "$repo_root/example/sw/src"
set ws_dir     "$repo_root/example/vitis"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if { ![file exists $xsa_file] } {
    puts "ERROR: Hardware description not found: $xsa_file"
    puts "Run 'make bitstream' in Vivado and export the hardware platform first."
    exit 1
}

if { ![file exists $src_dir] } {
    puts "ERROR: Source directory not found: $src_dir"
    exit 1
}

# ---------------------------------------------------------------------------
# Set workspace
# ---------------------------------------------------------------------------
puts "Setting workspace to $ws_dir"
setws $ws_dir

# ---------------------------------------------------------------------------
# Platform project
# ---------------------------------------------------------------------------
puts "Creating platform project zybo_platform from $xsa_file"
platform create -name zybo_platform \
    -hw $xsa_file \
    -os standalone \
    -proc ps7_cortexa9_0 \
    -out $ws_dir

# Save the platform definition before generating
platform write

puts "Generating platform (creates BSP and standalone drivers)..."
platform generate

# ---------------------------------------------------------------------------
# Application project
# ---------------------------------------------------------------------------
# Use {Hello World} as the template - it is valid across all Vitis 2021
# versions. The generated helloworld.c is deleted after importsources
# brings in the actual sources from sw/src/.
puts "Creating application project zybo_app"
app create -name zybo_app \
    -platform zybo_platform \
    -domain standalone_domain \
    -lang c++ \
    -template {Empty Application (C++)}

# ---------------------------------------------------------------------------
# Import sources (copies files and registers them with the project)
# ---------------------------------------------------------------------------
puts "Importing sources from $src_dir"
importsources -name zybo_app -path $src_dir

# ---------------------------------------------------------------------------
# Build application
# ---------------------------------------------------------------------------
puts "Building application..."
app build -name zybo_app
puts ""
puts "Done. Workspace created at $ws_dir"
puts "Open Vitis and set workspace to $ws_dir to continue development."
puts ""
puts "IMPORTANT: Always edit source files in example/sw/src/, not in example/vitis/zybo_app/src/"
puts "Re-run this script after updating example/sw/top.xsa from Vivado."