// -----------------------------------------------------------------------------
// bolus_limiter.v
// Limitador de bolos tipo PCA (analgesia controlada por el paciente)
// aplicado en hardware. Un bolo se concede solo si:
//   1. 'allow' = 1 (infusion corriendo y bolo configurado),
//   2. ya paso el tiempo de bloqueo desde el ultimo bolo concedido, y
//   3. hay menos de 'max_per_hour' bolos en los ultimos WIN_MIN minutos
//      (ventana deslizante con marcas de tiempo de los ultimos 8 bolos).
// Motivos de rechazo: 1 = no permitido, 2 = bloqueo, 3 = limite por hora.
// Es un bloque autocontenido: es el que se lleva a OpenLane / SKY130.
// -----------------------------------------------------------------------------
module bolus_limiter #(
    parameter integer WIN_MIN = 60
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       tick_min,        // minuto clinico (acelerable en demo)
    input  wire       req,
    input  wire       allow,
    input  wire [7:0] lockout_min,
    input  wire [3:0] max_per_hour,    // 0..8 (0 = bolos deshabilitados)
    output reg        grant,
    output reg        deny,
    output reg  [1:0] deny_reason,
    output reg  [7:0] lockout_left,
    output reg  [3:0] count_win
);
    reg [15:0] now_min;
    reg [15:0] ts0, ts1, ts2, ts3, ts4, ts5, ts6, ts7;
    reg [7:0]  v;
    reg [2:0]  wp;

    wire [15:0] age0 = now_min - ts0;
    wire [15:0] age1 = now_min - ts1;
    wire [15:0] age2 = now_min - ts2;
    wire [15:0] age3 = now_min - ts3;
    wire [15:0] age4 = now_min - ts4;
    wire [15:0] age5 = now_min - ts5;
    wire [15:0] age6 = now_min - ts6;
    wire [15:0] age7 = now_min - ts7;

    wire [7:0] in_win = {
        v[7] && (age7 < WIN_MIN), v[6] && (age6 < WIN_MIN),
        v[5] && (age5 < WIN_MIN), v[4] && (age4 < WIN_MIN),
        v[3] && (age3 < WIN_MIN), v[2] && (age2 < WIN_MIN),
        v[1] && (age1 < WIN_MIN), v[0] && (age0 < WIN_MIN)};

    always @* begin
        count_win = {3'd0, in_win[0]} + {3'd0, in_win[1]} + {3'd0, in_win[2]} +
                    {3'd0, in_win[3]} + {3'd0, in_win[4]} + {3'd0, in_win[5]} +
                    {3'd0, in_win[6]} + {3'd0, in_win[7]};
    end

    always @(posedge clk) begin
        grant <= 1'b0;
        deny  <= 1'b0;
        if (rst) begin
            now_min      <= 16'd0;
            v            <= 8'd0;
            wp           <= 3'd0;
            lockout_left <= 8'd0;
            deny_reason  <= 2'd0;
            ts0 <= 16'd0; ts1 <= 16'd0; ts2 <= 16'd0; ts3 <= 16'd0;
            ts4 <= 16'd0; ts5 <= 16'd0; ts6 <= 16'd0; ts7 <= 16'd0;
        end else begin
            if (tick_min) begin
                now_min <= now_min + 16'd1;
                if (lockout_left != 8'd0) lockout_left <= lockout_left - 8'd1;
                v <= v & in_win;            // descarta marcas fuera de ventana
            end

            if (req) begin
                if (!allow || max_per_hour == 4'd0) begin
                    deny        <= 1'b1;
                    deny_reason <= 2'd1;
                end else if (lockout_left != 8'd0) begin
                    deny        <= 1'b1;
                    deny_reason <= 2'd2;
                end else if (count_win >= max_per_hour) begin
                    deny        <= 1'b1;
                    deny_reason <= 2'd3;
                end else begin
                    grant        <= 1'b1;
                    lockout_left <= lockout_min;
                    v[wp]        <= 1'b1;
                    case (wp)
                        3'd0: ts0 <= now_min;  3'd1: ts1 <= now_min;
                        3'd2: ts2 <= now_min;  3'd3: ts3 <= now_min;
                        3'd4: ts4 <= now_min;  3'd5: ts5 <= now_min;
                        3'd6: ts6 <= now_min;  default: ts7 <= now_min;
                    endcase
                    wp <= wp + 3'd1;
                end
            end
        end
    end
endmodule
