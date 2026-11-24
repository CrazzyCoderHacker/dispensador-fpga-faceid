// -----------------------------------------------------------------------------
// display_utils.v
//   seg7_char : codigo de caracter -> segmentos de la DE10-Lite (activo bajo)
//   bin2bcd14 : binario de 14 bits (0..9999) -> 4 digitos BCD (double dabble)
//   pulse_stretch : alarga un pulso para que sea visible en un LED
// -----------------------------------------------------------------------------

// Codigos: 0-15 = 0..F, 16 = espacio, 17 r, 18 t, 19 U, 20 n, 21 o, 22 L,
//          23 H, 24 P, 25 '-', 26 i, 27 u
module seg7_char (
    input  wire [4:0] c,
    output reg  [7:0] seg_n        // {dp, g, f, e, d, c, b, a}, activo bajo
);
    reg [6:0] s;                   // gfedcba activo alto
    always @* begin
        case (c)
            5'd0:  s = 7'h3F;  5'd1:  s = 7'h06;  5'd2:  s = 7'h5B;
            5'd3:  s = 7'h4F;  5'd4:  s = 7'h66;  5'd5:  s = 7'h6D;
            5'd6:  s = 7'h7D;  5'd7:  s = 7'h07;  5'd8:  s = 7'h7F;
            5'd9:  s = 7'h6F;  5'd10: s = 7'h77;  5'd11: s = 7'h7C;
            5'd12: s = 7'h39;  5'd13: s = 7'h5E;  5'd14: s = 7'h79;
            5'd15: s = 7'h71;
            5'd17: s = 7'h50;  // r
            5'd18: s = 7'h78;  // t
            5'd19: s = 7'h3E;  // U
            5'd20: s = 7'h54;  // n
            5'd21: s = 7'h5C;  // o
            5'd22: s = 7'h38;  // L
            5'd23: s = 7'h76;  // H
            5'd24: s = 7'h73;  // P
            5'd25: s = 7'h40;  // -
            5'd26: s = 7'h10;  // i
            5'd27: s = 7'h1C;  // u
            default: s = 7'h00;
        endcase
        seg_n = {1'b1, ~s};
    end
endmodule

module bin2bcd14 (
    input  wire [13:0] bin,
    output reg  [15:0] bcd
);
    integer i;
    reg [29:0] x;
    always @* begin
        x = {16'd0, bin};
        for (i = 0; i < 14; i = i + 1) begin
            if (x[17:14] >= 4'd5) x[17:14] = x[17:14] + 4'd3;
            if (x[21:18] >= 4'd5) x[21:18] = x[21:18] + 4'd3;
            if (x[25:22] >= 4'd5) x[25:22] = x[25:22] + 4'd3;
            if (x[29:26] >= 4'd5) x[29:26] = x[29:26] + 4'd3;
            x = x << 1;
        end
        bcd = x[29:14];
    end
endmodule

module pulse_stretch #(
    parameter integer MS = 150
)(
    input  wire clk,
    input  wire rst,
    input  wire tick_1ms,
    input  wire pulse,
    output wire out
);
    reg [15:0] c;
    always @(posedge clk) begin
        if (rst)                    c <= 16'd0;
        else if (pulse)             c <= MS[15:0];
        else if (tick_1ms && c != 0) c <= c - 16'd1;
    end
    assign out = (c != 16'd0);
endmodule
