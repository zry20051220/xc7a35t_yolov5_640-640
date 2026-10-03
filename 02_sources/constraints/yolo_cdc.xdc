# RGMII RX and the board-clock/MIG tree are unrelated clock domains.
# Crossings are implemented by Xilinx asynchronous FIFOs or explicit 2-FF
# synchronizers in the RTL.
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks rgmii_rx_clk_i] \
  -group [get_clocks -include_generated_clocks Clk]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
