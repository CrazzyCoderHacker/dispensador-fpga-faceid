// -----------------------------------------------------------------------------
// divu.v  -  Divisor entero sin signo secuencial (restauracion), W ciclos.
// Se usa para convertir la velocidad programada (mL/h) en el intervalo entre
// gotas: intervalo_ms = 3 600 000 / (velocidad * factor_de_goteo).
// Division entre cero -> cociente con todos los bits en 1.
// -----------------------------------------------------------------------------
module divu #(
    parameter integer W = 32
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [W-1:0] num,
    input  wire [W-1:0] den,
    output reg  [W-1:0] quo,
    output reg          busy,
    output reg          done
);
    reg [W-1:0] rem, q, d;
    reg [7:0]   n;

    wire [W:0]   rem_sh  = {rem, q[W-1]};
    wire         ge      = (rem_sh >= {1'b0, d});
    wire [W:0]   rem_sub = rem_sh - {1'b0, d};
    wire [W-1:0] rem_new = ge ? rem_sub[W-1:0] : rem_sh[W-1:0];
    wire [W-1:0] q_new   = {q[W-2:0], ge};

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            quo  <= {W{1'b0}};
            rem  <= {W{1'b0}};
            q    <= {W{1'b0}};
            d    <= {W{1'b0}};
            n    <= 8'd0;
        end else if (start && !busy) begin
            busy <= 1'b1;
            rem  <= {W{1'b0}};
            q    <= num;
            d    <= den;
            n    <= W[7:0];
        end else if (busy) begin
            rem <= rem_new;
            q   <= q_new;
            n   <= n - 8'd1;
            if (n == 8'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
                quo  <= q_new;
            end
        end
    end
endmodule
