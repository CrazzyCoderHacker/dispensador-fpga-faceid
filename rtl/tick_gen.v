// -----------------------------------------------------------------------------
// tick_gen.v
// Base de tiempo del sistema. Genera pulsos de un ciclo cada 1 ms y cada 1 s,
// y un contador de segundos desde el encendido (marca de tiempo del registro).
// MS_DIV = ciclos de reloj por milisegundo (50 000 a 50 MHz). En simulacion se
// usa un valor pequeno para acelerar el tiempo.
// -----------------------------------------------------------------------------
module tick_gen #(
    parameter integer MS_DIV = 50_000
)(
    input  wire        clk,
    input  wire        rst,
    output reg         tick_1ms,
    output reg         tick_1s,
    output reg  [31:0] uptime_s
);
    reg [31:0] cnt;
    reg [9:0]  ms;

    always @(posedge clk) begin
        tick_1ms <= 1'b0;
        tick_1s  <= 1'b0;
        if (rst) begin
            cnt      <= 32'd0;
            ms       <= 10'd0;
            uptime_s <= 32'd0;
        end else if (cnt == MS_DIV - 1) begin
            cnt      <= 32'd0;
            tick_1ms <= 1'b1;
            if (ms == 10'd999) begin
                ms       <= 10'd0;
                tick_1s  <= 1'b1;
                uptime_s <= uptime_s + 32'd1;
            end else begin
                ms <= ms + 10'd1;
            end
        end else begin
            cnt <= cnt + 32'd1;
        end
    end
endmodule
