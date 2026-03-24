# vitis_update.tcl
# Updates the source files in an existing Vitis workspace from example/sw/src/.
# Run this after editing source files in example/sw/src/ instead of recreating
# the entire workspace with vitis_create.tcl.
#
# Usage (via Makefile):
#   xsct scripts/vitis_update.tcl
#
# Prerequisites:
#   - example/vitis/ workspace must already exist (run make vitis first)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/.."]
set src_dir    "$repo_root/example/sw/src"
set ws_dir     "$repo_root/example/vitis"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if { ![file exists $ws_dir] } {
    puts "ERROR: Vitis workspace not found at $ws_dir"
    puts "Run 'make vitis' first to create the workspace."
    exit 1
}

if { ![file exists $src_dir] } {
    puts "ERROR: Source directory not found: $src_dir"
    exit 1
}

# ---------------------------------------------------------------------------
# Set workspace and update sources
# ---------------------------------------------------------------------------
puts "Setting workspace to $ws_dir"
setws $ws_dir

# ---------------------------------------------------------------------------
# Import sources (copies files and registers them with the project)
# ---------------------------------------------------------------------------
puts "Updating sources from $src_dir"
importsources -name zybo_app -path $src_dir

# ---------------------------------------------------------------------------
# Rebuild application
# ---------------------------------------------------------------------------
puts "Building application..."
app build -name zybo_app

puts ""
puts "Done. Sources updated and application rebuilt."