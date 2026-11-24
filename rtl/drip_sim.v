// -----------------------------------------------------------------------------
// drip_sim.v
// Modelo de la bomba y de la camara de goteo dentro de la FPGA, para hacer
// la demostracion sin motor ni sensor fisicos:
//   * con la bomba encendida cae una gota cada PUMP_DROP_MS
//   * con la "llave abierta" (switch) caen gotas cada LEAK_DROP_MS aunque la
//     bomba este apagada -> asi se demuestra la alarma de flujo libre
//   * con "tubo tapado" (switch) no caen gotas -> alarma de sin flujo
// El controlador de infusion no sabe si la gota viene de este modelo o de un
// sensor real: recibe el mismo pulso.
// -----------------------------------------------------------------------------
module drip_sim #(
    parameter integer PUMP_DROP_MS = 150,
    parameter integer LEAK_DROP_MS = 120
)(
    input  wire clk,
    input  wire rst,
    input  wire tick_1ms,
    input  wire pump_on,
    input  wire valve_open,     // alguien abrio la llave a mano
    input  wire occluded,       // tubo tapado / bolsa vacia
    output reg  drop
);
    reg [15:0] pacc, lacc;

    always @(posedge clk) begin
        drop <= 1'b0;
        if (rst) begin
            pacc <= 16'd0;
            lacc <= 16'd0;
        end else if (tick_1ms) begin
            if (pump_on && !occluded) begin
                if (pacc >= PUMP_DROP_MS - 1) begin
                    pacc <= 16'd0;
                    drop <= 1'b1;
                end else pacc <= pacc + 16'd1;
            end
            if (valve_open && !occluded) begin
                if (lacc >= LEAK_DROP_MS - 1) begin
                    lacc <= 16'd0;
                    drop <= 1'b1;
                end else lacc <= lacc + 16'd1;
            end else begin
                lacc <= 16'd0;
            end
        end
    end
endmodule
