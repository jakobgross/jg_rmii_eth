

proc generate {drv_handle} {
	xdefine_include_file $drv_handle "xparameters.h" "jg_mdio_axi" "NUM_INSTANCES" "DEVICE_ID"  "C_s_axi_BASEADDR" "C_s_axi_HIGHADDR"
}
