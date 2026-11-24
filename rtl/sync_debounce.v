// -----------------------------------------------------------------------------
// sync_debounce.v
// Sincronizador de dos flip-flops + antirrebote por tiempo. La salida cambia
// solo cuando la entrada permanece estable STABLE_MS milisegundos. Entrega
// pulsos de flanco de subida y bajada. La entrada debe llegar ya en logica
// positiva (1 = activo); el top invierte las senales activas en bajo.
// -----------------------------------------------------------------------------
module sync_debounce #(
    parameter integer STABLE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire tick_1ms,
    input  wire din,
    output reg  dout,
    output wire rise,
    output wire fall
);
    reg s1, s2, dprev;
    reg [7:0] cnt;

    always @(posedge clk) begin
        s1 <= din;
        s2 <= s1;
        if (rst) begin
            dout  <= 1'b0;
            dprev <= 1'b0;
            cnt   <= 8'd0;
        end else begin
            dprev <= dout;
            if (s2 == dout) begin
                cnt <= 8'd0;
            end else if (tick_1ms) begin
                if (cnt >= STABLE_MS - 1) begin
                    dout <= s2;
                    cnt  <= 8'd0;
                end else begin
                    cnt <= cnt + 8'd1;
                end
            end
        end
    end

    assign rise = dout & ~dprev;
    assign fall = ~dout & dprev;
endmodule
