// Prueba unitaria del limitador de bolos: no permitido, bloqueo entre bolos,
// limite por hora con ventana deslizante y recuperacion al vencer la ventana.
`timescale 1ns/1ps
module tb_bolus_limiter;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;
    integer pass = 0, fail = 0;

    reg tmin = 0, req = 0, allow = 1;
    reg [7:0] lock = 8'd10;
    reg [3:0] maxh = 4'd3;
    wire grant, deny; wire [1:0] reason; wire [7:0] left; wire [3:0] cnt;

    bolus_limiter dut (.clk(clk), .rst(rst), .tick_min(tmin), .req(req), .allow(allow),
        .lockout_min(lock), .max_per_hour(maxh), .grant(grant), .deny(deny),
        .deny_reason(reason), .lockout_left(left), .count_win(cnt));

    reg g_seen, d_seen; reg [1:0] r_seen;
    task request;
        begin
            g_seen = 0; d_seen = 0;
            @(posedge clk); req <= 1;
            @(posedge clk); #1;
            g_seen = grant; d_seen = deny; r_seen = reason;
            req <= 0;
        end
    endtask
    task minutes(input integer m);
        integer j;
        begin
            for (j = 0; j < m; j = j + 1) begin
                @(posedge clk); tmin <= 1; @(posedge clk); tmin <= 0;
            end
        end
    endtask
    task expect(input cond, input [8*40-1:0] msg);
        begin
            if (cond) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL: %0s (t=%0t)", msg, $time); end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); rst = 0;
        allow = 0; request; expect(d_seen && r_seen == 1, "no permitido sin infusion");
        allow = 1;
        request;          expect(g_seen, "bolo 1 concedido");
        request;          expect(d_seen && r_seen == 2, "bloqueo inmediato");
        minutes(9);
        request;          expect(d_seen && r_seen == 2, "bloqueo a los 9 min");
        minutes(1);
        request;          expect(g_seen, "bolo 2 a los 10 min");
        minutes(10);
        request;          expect(g_seen, "bolo 3 a los 20 min");
        minutes(10);
        request;          expect(d_seen && r_seen == 3, "limite 3/h a los 30 min");
        expect(cnt == 3, "3 bolos en ventana");
        minutes(30);      // t = 60: el bolo 1 (t=0) sale de la ventana
        request;          expect(g_seen, "bolo 4 al vencer ventana");
        maxh = 0;
        minutes(60);
        request;          expect(d_seen && r_seen == 1, "maxh=0 deshabilita");
        $display("tb_bolus_limiter RESULT: PASS %0d FAIL %0d", pass, fail);
        $finish;
    end
endmodule
