// Prueba unitaria del controlador de infusion con un modelo de bomba + camara
// de goteo: precision de la velocidad, bolo, flujo libre, sin flujo,
// manipulacion de la tapa, fin de infusion y permisos de sesion.
`timescale 1ns/1ps
module tb_infusion_ctrl;
    localparam integer MSD = 20;
    reg clk = 0, rst = 1;
    always #10 clk = ~clk;
    integer pass = 0, fail = 0;

    wire t1ms, t1s; wire [31:0] up;
    tick_gen #(.MS_DIV(MSD)) ut (.clk(clk), .rst(rst), .tick_1ms(t1ms), .tick_1s(t1s), .uptime_s(up));

    reg [9:0] rate = 10'd360, vtbi = 10'd5;
    reg [7:0] bol  = 8'd1;
    reg session = 0, cstart = 0, cc = 0, bgrant = 0, lid = 0;
    reg inj = 0;                       // gota inyectada (flujo libre)
    reg pump_ok = 1;                   // 0 = tubo ocluido / bolsa vacia

    wire [2:0] st; wire pump; wire [1:0] al;
    wire [15:0] deliv, sched; wire [9:0] ml; wire [31:0] intv;
    wire e_start, e_pause, e_done, e_alarm, e_clr, e_rej, e_reset;

    // ---- modelo de bomba: con la bomba encendida cae una gota cada 100 ms
    reg pdrop = 0; integer pacc = 0;
    always @(posedge clk) begin
        pdrop <= 0;
        if (t1ms) begin
            if (pump && pump_ok) begin
                if (pacc >= 99) begin pacc <= 0; pdrop <= 1; end
                else pacc <= pacc + 1;
            end
        end
    end
    wire drop = pdrop | inj;

    infusion_ctrl #(.DROP_FACTOR(20), .NOFLOW_MS(3000)) dut (
        .clk(clk), .rst(rst), .tick_1ms(t1ms), .rate_mlh(rate), .vtbi_ml(vtbi),
        .bolus_ml(bol), .session(session), .cmd_start(cstart), .cmd_c(cc),
        .bolus_grant(bgrant), .drop(drop), .lid_open(lid), .state(st),
        .pump_on(pump), .alarm_code(al), .delivered_drops(deliv),
        .sched_drops(sched), .delivered_ml(ml), .interval_ms(intv),
        .ev_start(e_start), .ev_pause(e_pause), .ev_done(e_done), .ev_alarm(e_alarm),
        .ev_alarm_clear(e_clr), .ev_start_rej(e_rej), .ev_reset(e_reset));

    integer rej_cnt = 0;
    always @(posedge clk) if (e_rej) rej_cnt = rej_cnt + 1;

    task pulse_start; begin @(posedge clk); cstart <= 1; @(posedge clk); cstart <= 0; @(posedge clk); end endtask
    task pulse_c;     begin @(posedge clk); cc <= 1;     @(posedge clk); cc <= 0;     @(posedge clk); end endtask
    task pulse_bolus; begin @(posedge clk); bgrant <= 1; @(posedge clk); bgrant <= 0; @(posedge clk); end endtask
    task inject(input integer n);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1) begin
                @(posedge clk); inj <= 1; @(posedge clk); inj <= 0;
                repeat (50 * MSD) @(posedge clk);
            end
        end
    endtask
    task wait_ms(input integer ms); begin repeat (ms * MSD) @(posedge clk); end endtask
    task expect(input cond, input [8*48-1:0] msg);
        begin
            if (cond) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL: %0s (t=%0t st=%0d al=%0d deliv=%0d sched=%0d)", msg, $time, st, al, deliv, sched); end
        end
    endtask

    integer d0;
    initial begin
        repeat (5) @(posedge clk); rst = 0;
        wait_ms(5);
        expect(intv == 32'd500, "360 mL/h -> 500 ms por gota");

        pulse_start;
        expect(st == 0 && rej_cnt == 1, "inicio rechazado sin sesion");

        session = 1;
        pulse_start;
        expect(st == 1, "inicio con sesion");
        session = 0;
        wait_ms(5000);
        expect(sched >= 9 && sched <= 10, "10 gotas programadas en 5 s");
        expect(deliv + 1 >= sched && deliv <= sched, "entregado sigue a programado");

        // bolo de 1 mL (20 gotas)
        d0 = sched;
        pulse_bolus;
        expect(sched == d0 + 20, "bolo suma 20 gotas");
        wait_ms(1500);
        expect(pump, "bomba compensando el bolo");

        // flujo libre: 5 gotas extra no ordenadas
        wait_ms(1500);
        inject(5);
        wait_ms(5);
        expect(st == 3 && al == 2, "alarma de flujo libre");
        expect(!pump, "bomba apagada en alarma");

        pulse_c;
        expect(st == 3, "sin sesion no se borra la alarma");
        session = 1; pulse_c;
        expect(st == 2, "enfermera borra alarma -> pausa");
        pulse_start;
        expect(st == 1, "reanuda");
        session = 0;

        // sin flujo: el modelo deja de producir gotas
        wait_ms(600);
        pump_ok = 0;
        wait_ms(4000);
        expect(st == 3 && al == 1, "alarma de sin flujo");
        pump_ok = 1;
        session = 1; pulse_c; pulse_start; session = 0;

        // terminar la infusion (100 gotas)
        wait (st == 4 || st == 3);
        wait_ms(5);
        expect(st == 4, "infusion terminada");
        expect(deliv == 100 && ml == 5, "100 gotas = 5 mL entregados");
        pulse_start;
        expect(st == 4, "no reinicia en DONE");

        // gotas con la infusion terminada -> flujo libre
        inject(3);
        wait_ms(5);
        expect(st == 3 && al == 2, "gotas sin infusion -> alarma");

        session = 1; pulse_c; pulse_c;     // borra alarma y reinicia bolsa
        expect(st == 0 && deliv == 0, "nueva bolsa");
        session = 0;

        // manipulacion de tapa sin sesion
        lid = 1; wait_ms(5);
        expect(st == 3 && al == 3, "tapa abierta sin sesion");
        lid = 0;
        session = 1; pulse_c;
        lid = 1; wait_ms(5);
        expect(st == 2, "tapa abierta con sesion permitida");
        lid = 0;

        $display("tb_infusion_ctrl RESULT: PASS %0d FAIL %0d", pass, fail);
        $finish;
    end

    initial begin
        #(64'd2_000_000_000);
        $display("TIMEOUT"); $display("tb_infusion_ctrl RESULT: PASS %0d FAIL %0d", pass, fail + 1);
        $finish;
    end
endmodule
