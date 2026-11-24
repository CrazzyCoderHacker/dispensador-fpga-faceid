// -----------------------------------------------------------------------------
// buzzer_ctrl.v
// Patrones sonoros:  alarma = 0.5 s encendido / 0.5 s apagado (prioritaria)
//                    ok     = 1 tono de 250 ms
//                    error  = 2 tonos de 100 ms
//                    clic   = 30 ms (cada tecla)
// PASSIVE = 1 genera un tono cuadrado de TONE_HZ (zumbador pasivo);
// PASSIVE = 0 entrega nivel (zumbador activo con transistor).
// -----------------------------------------------------------------------------
module buzzer_ctrl #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer TONE_HZ = 2700,
    parameter integer PASSIVE = 0
)(
    input  wire clk,
    input  wire rst,
    input  wire tick_1ms,
    input  wire alarm,
    input  wire beep_click,
    input  wire beep_ok,
    input  wire beep_err,
    output wire buz
);
    localparam integer HALF = CLK_HZ / (2 * TONE_HZ);

    reg [9:0]  t;
    reg [1:0]  pat;
    reg [9:0]  aph;
    reg [31:0] tc;
    reg        tone;
    reg        on;

    always @(posedge clk) begin
        if (rst) begin
            t    <= 10'd0;
            pat  <= 2'd0;
            aph  <= 10'd0;
            tc   <= 32'd0;
            tone <= 1'b0;
        end else begin
            if (beep_err) begin
                pat <= 2'd2; t <= 10'd300;
            end else if (beep_ok) begin
                pat <= 2'd1; t <= 10'd250;
            end else if (beep_click && t == 10'd0) begin
                pat <= 2'd0; t <= 10'd30;
            end else if (tick_1ms && t != 10'd0) begin
                t <= t - 10'd1;
            end

            if (tick_1ms) aph <= (aph == 10'd999) ? 10'd0 : aph + 10'd1;

            if (tc >= HALF - 1) begin
                tc   <= 32'd0;
                tone <= ~tone;
            end else begin
                tc <= tc + 32'd1;
            end
        end
    end

    always @* begin
        if (alarm)              on = (aph < 10'd500);
        else if (t == 10'd0)    on = 1'b0;
        else if (pat == 2'd2)   on = (t > 10'd200) || (t <= 10'd100);
        else                    on = 1'b1;
    end

    assign buz = (PASSIVE != 0) ? (on & tone) : on;
endmodule
