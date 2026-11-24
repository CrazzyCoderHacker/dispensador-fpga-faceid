// Modelo de simulacion del IP altsource_probe de Intel (solo para Icarus).
// El testbench escribe la orden en 'src_reg' y lee 'probe' por jerarquia,
// igual que lo hace quartus_stp en la tarjeta real.
`timescale 1ns/1ps
module altsource_probe #(
    parameter sld_auto_instance_index = "YES",
    parameter integer sld_instance_index = 0,
    parameter instance_id = "NONE",
    parameter integer probe_width = 1,
    parameter integer source_width = 1,
    parameter source_initial_value = "0",
    parameter enable_metastability = "NO"
)(
    input  wire [probe_width-1:0]  probe,
    output wire [source_width-1:0] source,
    input  wire source_clk,
    input  wire source_ena
);
    reg [source_width-1:0] src_reg = {source_width{1'b0}};
    assign source = src_reg;
endmodule
