// Prueba unitaria del divisor secuencial contra el operador '/':
// casos usados por el dispensador + 200 casos aleatorios.
`timescale 1ns/1ps
module tb_divu;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;
    integer pass = 0, fail = 0, i;

    reg ds = 0; reg [31:0] dn, dd;
    wire [31:0] dq; wire dbusy, ddone;
    divu #(.W(32)) udiv (.clk(clk), .rst(rst), .start(ds), .num(dn), .den(dd), .quo(dq), .busy(dbusy), .done(ddone));

    task check_div(input [31:0] a, input [31:0] b);
        reg [31:0] exp;
        begin
            exp = (b == 0) ? 32'hFFFFFFFF : a / b;
            @(posedge clk); dn <= a; dd <= b; ds <= 1;
            @(posedge clk); ds <= 0;
            @(posedge ddone); @(negedge clk);
            if (dq === exp) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL div %0d/%0d = %0d (esperado %0d)", a, b, dq, exp); end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); rst = 0;
        check_div(3600000, 20);      // 1 mL/h   -> 180000 ms por gota
        check_div(3600000, 7200);    // 360 mL/h -> 500 ms
        check_div(3600000, 19980);   // 999 mL/h -> 180 ms
        check_div(0, 5);
        check_div(5, 0);
        for (i = 0; i < 200; i = i + 1) check_div($random, ($random & 32'h0000FFFF) + 1);
        $display("tb_divu RESULT: PASS %0d FAIL %0d", pass, fail);
        $finish;
    end
endmodule
