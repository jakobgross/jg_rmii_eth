# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  #Adding Group
  set AXI [ipgui::add_group $IPINST -name "AXI" -parent ${Page_0}]
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${AXI}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${AXI}

  #Adding Group
  ipgui::add_group $IPINST -name "ADDR" -parent ${Page_0}

  #Adding Group
  set LAN [ipgui::add_group $IPINST -name "LAN" -parent ${Page_0}]
  ipgui::add_param $IPINST -name "G_PHY_ADDR" -parent ${LAN}
  ipgui::add_param $IPINST -name "G_MDC_FREQ_DIV" -parent ${LAN}
  ipgui::add_param $IPINST -name "G_CLK_FREQ_HZ" -parent ${LAN}



}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.G_CLK_FREQ_HZ { PARAM_VALUE.G_CLK_FREQ_HZ } {
	# Procedure called to update G_CLK_FREQ_HZ when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_CLK_FREQ_HZ { PARAM_VALUE.G_CLK_FREQ_HZ } {
	# Procedure called to validate G_CLK_FREQ_HZ
	return true
}

proc update_PARAM_VALUE.G_MDC_FREQ_DIV { PARAM_VALUE.G_MDC_FREQ_DIV } {
	# Procedure called to update G_MDC_FREQ_DIV when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_MDC_FREQ_DIV { PARAM_VALUE.G_MDC_FREQ_DIV } {
	# Procedure called to validate G_MDC_FREQ_DIV
	return true
}

proc update_PARAM_VALUE.G_PHY_ADDR { PARAM_VALUE.G_PHY_ADDR } {
	# Procedure called to update G_PHY_ADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.G_PHY_ADDR { PARAM_VALUE.G_PHY_ADDR } {
	# Procedure called to validate G_PHY_ADDR
	return true
}

proc update_PARAM_VALUE.C_s_axi_BASEADDR { PARAM_VALUE.C_s_axi_BASEADDR } {
	# Procedure called to update C_s_axi_BASEADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_s_axi_BASEADDR { PARAM_VALUE.C_s_axi_BASEADDR } {
	# Procedure called to validate C_s_axi_BASEADDR
	return true
}

proc update_PARAM_VALUE.C_s_axi_HIGHADDR { PARAM_VALUE.C_s_axi_HIGHADDR } {
	# Procedure called to update C_s_axi_HIGHADDR when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_s_axi_HIGHADDR { PARAM_VALUE.C_s_axi_HIGHADDR } {
	# Procedure called to validate C_s_axi_HIGHADDR
	return true
}


proc update_MODELPARAM_VALUE.G_CLK_FREQ_HZ { MODELPARAM_VALUE.G_CLK_FREQ_HZ PARAM_VALUE.G_CLK_FREQ_HZ } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_CLK_FREQ_HZ}] ${MODELPARAM_VALUE.G_CLK_FREQ_HZ}
}

proc update_MODELPARAM_VALUE.G_MDC_FREQ_DIV { MODELPARAM_VALUE.G_MDC_FREQ_DIV PARAM_VALUE.G_MDC_FREQ_DIV } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_MDC_FREQ_DIV}] ${MODELPARAM_VALUE.G_MDC_FREQ_DIV}
}

proc update_MODELPARAM_VALUE.G_PHY_ADDR { MODELPARAM_VALUE.G_PHY_ADDR PARAM_VALUE.G_PHY_ADDR } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.G_PHY_ADDR}] ${MODELPARAM_VALUE.G_PHY_ADDR}
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

