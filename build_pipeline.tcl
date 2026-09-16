# QR filter pipeline: block design build (module reference, no IP repo)

# ----------------------------
# User parameters
set PART "xc7z020clg484-1"
set PROJ_NAME "qr_filter_pipeline"
set PROJ_DIR "./$PROJ_NAME"
set BD_NAME "design_1"
set IMAGE_WIDTH 640
set IMAGE_HEIGHT 480
set CLEAN_BD 1   ;# 1 = delete previous BD and rebuild

# Board preset 
set BOARD "digilentinc.com:zedboard:part0:1.1"
# path to vhd and c-files
set SRC_DIR "./src"
 

# ----------------------------
# Helper
proc get_or_create_ip {name vlnv} {
  set cell [get_bd_cells -quiet $name]
  if {[llength $cell]} { return $cell }
  return [create_bd_cell -type ip -vlnv $vlnv $name]
}
proc prop_if_exists {cell dictPairs} {
  foreach {k v} $dictPairs { catch { set_property -quiet -dict [list $k $v] $cell } }
}
proc safe_intf {p1 p2} {
  set a [get_bd_intf_pins -quiet $p1]
  set b [get_bd_intf_pins -quiet $p2]
  if {[llength $a] && [llength $b]} { catch { connect_bd_intf_net $a $b } }
}
proc connect_pins {src_pin sinks_list} {
  set src [get_bd_pins -quiet $src_pin]
  if {![llength $src]} { error "Pin '$src_pin' not found." }
  foreach s $sinks_list {
    set sink [get_bd_pins -quiet $s]
    if {[llength $sink]} { catch { connect_bd_net $src $sink } }
  }
}

# ----------------------------
# create project + Board-Preset
if {[string equal [current_project -quiet] ""]} {
  create_project $PROJ_NAME $PROJ_DIR -part $PART
} else {
  puts "INFO: Using existing project: [current_project]"
}

# set board
if {[catch { set_property board_part $BOARD [current_project] } msg]} {
  error "Board-Part '$BOARD' not availabel ($msg). Install Board-Files."
}

# ----------------------------
# get vhdl files
set_property target_language VHDL [current_project]
set vhdl_files [list \
  [file join $SRC_DIR "rgb2gray.vhd"] \
  [file join $SRC_DIR "median.vhd"] \
  [file join $SRC_DIR "gauss.vhd"] \
  [file join $SRC_DIR "pipeline_top.vhd"] \
]
foreach f $vhdl_files {
  if {![file exists $f]} { error "VHDL source missing: $f (adjust SRC_DIR)" }
}
add_files -norecurse $vhdl_files
update_compile_order -fileset sources_1

# testbenches (simulation only)
set tb_files [glob -nocomplain [file join $SRC_DIR "tb_*.vhd"]]
if {[llength $tb_files]} {
  add_files -fileset sim_1 -norecurse $tb_files
  set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1]]
} else {
  puts "WARN: no testbenches found in $SRC_DIR"
}
# set simulation time (tb)
set_property -name {xsim.simulate.runtime} -value {50us} -objects [get_filesets sim_1]


# ----------------------------
# create Block Design 
set bd_files [get_files -quiet "*$BD_NAME.bd"]
if {$CLEAN_BD && [llength $bd_files] > 0} {
  puts "INFO: Removing previous block design '$BD_NAME'..."
  catch { open_bd_design [lindex $bd_files 0] }
  catch { current_bd_design $BD_NAME }
  catch { delete_bd_objs [get_bd_cells -quiet *] }
  catch { close_bd_design [current_bd_design] }
  catch { remove_files [lindex $bd_files 0] }
  set proj_dir [get_property DIRECTORY [current_project]]
  set bd_dir   [file join $proj_dir "${PROJ_NAME}.srcs" "sources_1" "bd" $BD_NAME]
  catch { file delete -force -recursive $bd_dir }
}
set bd_files [get_files -quiet "*$BD_NAME.bd"]
if {[llength $bd_files] > 0} { open_bd_design [lindex $bd_files 0] } else { create_bd_design $BD_NAME }
current_bd_design $BD_NAME

# ----------------------------
# PS7: preset and Properties 
set PS7 [get_or_create_ip processing_system7_0 xilinx.com:ip:processing_system7:*]

# Board preset (DDR, MIO, clocks) if board_part is set
catch {
  apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1" make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} \
    [get_bd_cells processing_system7_0]
}

# own Preset 
prop_if_exists $PS7 [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_EN_CLK0_PORT {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
  CONFIG.PCW_EN_RST0_PORT {1} \
  CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
  CONFIG.PCW_NUM_F2P_INTR_INPUTS {2} \
  CONFIG.PCW_IRQ_F2P_INTR {1} \
]

# DDR / FIXED_IO 
catch { make_bd_intf_pins_external [get_bd_intf_pins -quiet processing_system7_0/FIXED_IO] }
catch { make_bd_intf_pins_external [get_bd_intf_pins -quiet processing_system7_0/DDR] }

# check required pins
if {![llength [get_bd_pins -quiet processing_system7_0/FCLK_CLK0]]} { error "FCLK_CLK0 missing (enable in PS7 config)." }
if {![llength [get_bd_pins -quiet processing_system7_0/FCLK_RESET0_N]]} { error "FCLK_RESET0_N missing (enable in PS7 config)." }

# ----------------------------
# more IPs
set RST [get_or_create_ip rst_fclk0 xilinx.com:ip:proc_sys_reset:*]
prop_if_exists $RST [list CONFIG.C_EXT_RESET_HIGH {1} CONFIG.C_AUX_RESET_HIGH {1} ]
set INV [get_or_create_ip inv_reset xilinx.com:ip:util_vector_logic:*]
prop_if_exists $INV [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}]
set ONE [get_or_create_ip xlconst_1 xilinx.com:ip:xlconstant:*]
prop_if_exists $ONE [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}]
set ZERO [get_or_create_ip xlconst_0 xilinx.com:ip:xlconstant:*]
prop_if_exists $ZERO [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}]

# AXI VDMA (
set VDMA [get_or_create_ip axi_vdma_0 xilinx.com:ip:axi_vdma:*]
prop_if_exists $VDMA [list \
  CONFIG.c_include_mm2s {1} \
  CONFIG.c_include_s2mm {1} \
  CONFIG.c_num_fstores {1} \
  CONFIG.c_m_axis_mm2s_tdata_width {24} \
  CONFIG.c_include_sg {0} \
  CONFIG.c_mm2s_genlock_mode {0} \
  CONFIG.c_s2mm_genlock_mode {0} \
]
# set S2MM-Streamwidth
foreach prop {CONFIG.c_s_axis_s2mm_tdata_width CONFIG.c_s2mm_axis_tdata_width CONFIG.C_S_AXIS_S2MM_TDATA_WIDTH} {
  catch { set_property -quiet $prop 8 $VDMA }
}

# AXI Interconnect (VDMA -> HP0)
set AIX [get_or_create_ip axi_hp0_ic xilinx.com:ip:axi_interconnect:*]
prop_if_exists $AIX [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}]

# SmartConnect (GP0 -> AXI4-Lite)
set SMC [get_or_create_ip smartconnect_ctrl xilinx.com:ip:smartconnect:*]
prop_if_exists $SMC [list CONFIG.NUM_MI {1}]

# Filter-Pipeline as Module Reference 
set AXF [get_bd_cells -quiet axis_filter_top_0]
if {![llength $AXF]} {
  set AXF [create_bd_cell -type module -reference axis_filter_top axis_filter_top_0]
}
prop_if_exists $AXF [list CONFIG.IMAGE_WIDTH $IMAGE_WIDTH CONFIG.IMAGE_HEIGHT $IMAGE_HEIGHT]

# IRQ concat
set CONCAT [get_or_create_ip xlconcat_irq xilinx.com:ip:xlconcat:*]
prop_if_exists $CONCAT [list CONFIG.NUM_PORTS {2}]

# ----------------------------
# CLOCKS (FCLK0 -> all ACLKs)
connect_pins processing_system7_0/FCLK_CLK0 {
  rst_fclk0/slowest_sync_clk
  axi_vdma_0/m_axi_mm2s_aclk
  axi_vdma_0/m_axi_s2mm_aclk
  axi_vdma_0/s_axi_lite_aclk
  axi_vdma_0/m_axis_mm2s_aclk
  axi_vdma_0/s_axis_s2mm_aclk
  axi_hp0_ic/ACLK
  axi_hp0_ic/M00_ACLK
  axi_hp0_ic/S00_ACLK
  axi_hp0_ic/S01_ACLK
  smartconnect_ctrl/aclk
  axis_filter_top_0/aclk
  processing_system7_0/M_AXI_GP0_ACLK
  processing_system7_0/S_AXI_HP0_ACLK
}

# ----------------------------
# RESETS
connect_pins processing_system7_0/FCLK_RESET0_N { inv_reset/Op1 }
catch { connect_bd_net [get_bd_pins inv_reset/Res] [get_bd_pins rst_fclk0/ext_reset_in] }

# proc_sys_reset auxiliary connections
catch { connect_bd_net [get_bd_pins xlconst_1/dout] [get_bd_pins rst_fclk0/dcm_locked] }
catch { connect_bd_net [get_bd_pins xlconst_0/dout] [get_bd_pins rst_fclk0/aux_reset_in] }
catch { connect_bd_net [get_bd_pins xlconst_0/dout] [get_bd_pins rst_fclk0/mb_debug_sys_rst] }

# peripheral_aresetn to peripherals
foreach p {
  axi_vdma_0/axi_resetn
  axi_vdma_0/s_axi_lite_aresetn
  axi_vdma_0/mm2s_prmry_resetn
  axi_vdma_0/s2mm_prmry_resetn
  axi_hp0_ic/ARESETN
  axi_hp0_ic/M00_ARESETN
  axi_hp0_ic/S00_ARESETN
  axi_hp0_ic/S01_ARESETN
  smartconnect_ctrl/aresetn
  axis_filter_top_0/aresetn
} {
  set pin [get_bd_pins -quiet $p]
  if {[llength $pin]} { catch { connect_bd_net [get_bd_pins rst_fclk0/peripheral_aresetn] $pin } }
}

# ----------------------------
# AXI Memory-Mapped
safe_intf axi_hp0_ic/M00_AXI processing_system7_0/S_AXI_HP0
safe_intf axi_hp0_ic/S00_AXI axi_vdma_0/M_AXI_MM2S
safe_intf axi_hp0_ic/S01_AXI axi_vdma_0/M_AXI_S2MM

# Control: GP0 -> SmartConnect -> VDMA S_AXI_LITE
safe_intf processing_system7_0/M_AXI_GP0 smartconnect_ctrl/S00_AXI
safe_intf smartconnect_ctrl/M00_AXI axi_vdma_0/S_AXI_LITE

# ----------------------------
# AXI-Stream
safe_intf axi_vdma_0/M_AXIS_MM2S axis_filter_top_0/S_AXIS
safe_intf axi_vdma_0/M_AXIS_MM2S axis_filter_top_0/s_axis
# Pipeline->VDMA->DDR (Gray8 / 8 Bit)
safe_intf axis_filter_top_0/M_AXIS axi_vdma_0/S_AXIS_S2MM
safe_intf axis_filter_top_0/m_axis axi_vdma_0/S_AXIS_S2MM

# check connection
foreach {pin} {axis_filter_top_0/aclk} {}
set s_ok 0
foreach n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins -quiet axi_vdma_0/M_AXIS_MM2S]] { set s_ok 1 }
if {!$s_ok} { puts "WARN: M_AXIS_MM2S -> pipeline NOT connected. Check the interface names of the module reference (get_bd_intf_pins axis_filter_top_0/*)." }

# ----------------------------
# IRQ
catch { connect_bd_net [get_bd_pins axi_vdma_0/mm2s_introut] [get_bd_pins xlconcat_irq/In0] }
catch { connect_bd_net [get_bd_pins axi_vdma_0/s2mm_introut] [get_bd_pins xlconcat_irq/In1] }
set ps_irq_pin [get_bd_pins -quiet processing_system7_0/IRQ_F2P]
if {[llength $ps_irq_pin]} {
  catch { connect_bd_net [get_bd_pins xlconcat_irq/dout] $ps_irq_pin }
} else {
  puts "WARN: PS7/IRQ_F2P not present; IRQ wiring skipped."
}

# ----------------------------
# Addressing / Validate / Save
assign_bd_address
validate_bd_design -force
save_bd_design

# Note: main.cpp expects VDMA S_AXI_LITE @ 0x43000000.
set vdma_seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces processing_system7_0/Data] *axi_vdma*]
if {[llength $vdma_seg]} {
  set off [get_property OFFSET [lindex $vdma_seg 0]]
  puts "INFO: VDMA S_AXI_LITE base address: $off (adjust VDMA_BASE in main.cpp if needed)"
}

# ----------------------------
# create wrapper and set as top
set bd_file [get_files -quiet "*$BD_NAME.bd"]; if {[llength $bd_file] == 0} { set bd_file [get_bd_designs $BD_NAME] }
make_wrapper -files $bd_file -top

set proj_dir  [get_property DIRECTORY [current_project]]
set vhd_path [file join $proj_dir "${PROJ_NAME}.gen" "sources_1" "bd" $BD_NAME "hdl" "${BD_NAME}_wrapper.vhd"]
set v_path   [file join $proj_dir "${PROJ_NAME}.gen" "sources_1" "bd" $BD_NAME "hdl" "${BD_NAME}_wrapper.v"]

if {[file exists $vhd_path]} {
  if {![llength [get_files -quiet $vhd_path]]} { add_files -norecurse $vhd_path }
  set_property top ${BD_NAME}_wrapper [current_fileset]
} elseif {[file exists $v_path]} {
  if {![llength [get_files -quiet $v_path]]} { add_files -norecurse $v_path }
  set_property top ${BD_NAME}_wrapper [current_fileset]
} else {
  puts "WARN: Wrapper file not found (.vhd/.v)."
}
update_compile_order -fileset sources_1

puts "\nINFO: Block design '$BD_NAME' built successfully. Wrapper set as top."
puts "NOTE: VDMA MM2S HSIZE=640*3=1920, STRIDE>=1920, VSIZE=480; S2MM HSIZE=640, STRIDE>=640, VSIZE=480."
puts "NOTE: AXIS sideband: TUSER[0]=SOF (frame), TLAST=EOL (per line)."
