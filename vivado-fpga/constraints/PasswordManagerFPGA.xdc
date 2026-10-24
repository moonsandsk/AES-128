##==============================================================================
## File        : PasswordManagerFPGA.xdc
## Description : Constraints for the pipelined AES-128 demo on the Digilent
##               Basys 3 (Artix-7 XC7A35T-1CPG236C).
##               Top-level module: PasswordManagerDemo
##
## NOTE: The pin names below (W5, U18, R2, V17...) are CPG236 package balls,
##       which is the package fitted on every Basys 3. Create the Vivado
##       project with part xc7a35tcpg236-1.
##==============================================================================

##------------------------------------------------------------------------------
## Clock: 100 MHz on-board oscillator
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN W5   IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports clk]

##------------------------------------------------------------------------------
## Reset: BTNC (centre pushbutton, active-high on the board; inverted and
## synchronised to an internal active-low synchronous reset in the RTL)
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN U18  IOSTANDARD LVCMOS33 } [get_ports btn_reset]

##------------------------------------------------------------------------------
## Start trigger: SW15
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN R2   IOSTANDARD LVCMOS33 } [get_ports start_sw]

##------------------------------------------------------------------------------
## Plaintext byte: SW0 - SW7
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V17  IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN W17  IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]
set_property -dict { PACKAGE_PIN W15  IOSTANDARD LVCMOS33 } [get_ports {sw[4]}]
set_property -dict { PACKAGE_PIN V15  IOSTANDARD LVCMOS33 } [get_ports {sw[5]}]
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports {sw[6]}]
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports {sw[7]}]

##------------------------------------------------------------------------------
## Ciphertext LSB: LD0 - LD7
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN U16  IOSTANDARD LVCMOS33 } [get_ports {leds[0]}]
set_property -dict { PACKAGE_PIN E19  IOSTANDARD LVCMOS33 } [get_ports {leds[1]}]
set_property -dict { PACKAGE_PIN U19  IOSTANDARD LVCMOS33 } [get_ports {leds[2]}]
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports {leds[3]}]
set_property -dict { PACKAGE_PIN W18  IOSTANDARD LVCMOS33 } [get_ports {leds[4]}]
set_property -dict { PACKAGE_PIN U15  IOSTANDARD LVCMOS33 } [get_ports {leds[5]}]
set_property -dict { PACKAGE_PIN U14  IOSTANDARD LVCMOS33 } [get_ports {leds[6]}]
set_property -dict { PACKAGE_PIN V14  IOSTANDARD LVCMOS33 } [get_ports {leds[7]}]

##------------------------------------------------------------------------------
## Status LEDs: LD14 = done, LD15 = busy
##------------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN P1   IOSTANDARD LVCMOS33 } [get_ports done_led]
set_property -dict { PACKAGE_PIN L1   IOSTANDARD LVCMOS33 } [get_ports busy_led]

##------------------------------------------------------------------------------
## I/O timing
## All inputs are asynchronous human-operated controls that pass through
## 2-flop ASYNC_REG synchronisers, and all outputs drive LEDs from registers.
## Neither has a meaningful I/O timing relationship to sys_clk_pin, so they
## are excluded from timing analysis (avoids unconstrained-I/O warnings
## without inventing fake input/output delays).
##------------------------------------------------------------------------------
set_false_path -from [get_ports {btn_reset start_sw sw[*]}]
set_false_path -to   [get_ports {leds[*] busy_led done_led}]

##------------------------------------------------------------------------------
## Configuration / bitstream (Basys 3 boots from 32 Mbit quad-SPI flash)
##------------------------------------------------------------------------------
set_property CFGBVS VCCO                      [current_design]
set_property CONFIG_VOLTAGE 3.3               [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33   [current_design]
set_property CONFIG_MODE SPIx4                [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4  [current_design]
