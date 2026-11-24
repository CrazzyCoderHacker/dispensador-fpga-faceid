create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty
# Entradas y salidas asincronas (botones, switches, sensores, UART, LEDs):
# todas se sincronizan internamente.
set_false_path -from [get_ports {KEY[*] SW[*] GPIO[*]}]
set_false_path -to   [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] GPIO[*]}]
