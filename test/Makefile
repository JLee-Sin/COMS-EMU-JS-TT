# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
# Keep in sync with source_files in ../info.yaml. pe_pkg.sv must stay first.
PROJECT_SOURCES = pe_pkg.sv \
                  project.v \
                  protoemu_top.sv \
                  controller.sv \
                  host_spi.sv \
                  cmd_decode.sv \
                  rewrite_fsm.sv \
                  protocol_mem.sv \
                  pin_regs.sv \
                  pin_crossbar.sv \
                  pinset.sv \
                  cfg_latch.sv \
                  primitives.sv \
                  sequencer.sv \
                  rx_fsm.sv \
                  tx_fsm.sv \
                  dump_gui.sv \
                  dump_mem.sv

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# The project sources are SystemVerilog:
ifeq ($(SIM),icarus)
COMPILE_ARGS 		+= -g2012
endif

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
