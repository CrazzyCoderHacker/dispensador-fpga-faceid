// -----------------------------------------------------------------------------
// jtag_link.v
// Enlace laptop <-> FPGA por el mismo cable USB-Blaster con el que se
// programa la tarjeta. Usa el IP "In-System Sources and Probes" de Quartus
// (altsource_probe):
//   * source (32 bits): la laptop escribe la orden (ver cmd_ctrl.v)
//   * probe (224 bits): la laptop lee el estado completo del dispensador
// La laptop lo maneja con quartus_stp (Tcl) desde server/fpga_bridge.py.
// No se necesita ningun hardware adicional.
// -----------------------------------------------------------------------------
module jtag_link (
    input  wire         clk,
    input  wire [223:0] probe,
    output wire [31:0]  source
);
    altsource_probe #(
        .sld_auto_instance_index ("YES"),
        .sld_instance_index      (0),
        .instance_id             ("DISP"),
        .probe_width             (224),
        .source_width            (32),
        .source_initial_value    ("0"),
        .enable_metastability    ("YES")
    ) u_issp (
        .probe      (probe),
        .source     (source),
        .source_clk (clk),
        .source_ena (1'b1)
    );
endmodule
