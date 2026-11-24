// =============================================================================
// tb_system.v  -  Prueba de sistema completo (dispenser_top)
// El testbench hace el papel de la laptop: escribe ordenes en el registro
// "source" del JTAG y lee el estado por el registro "probe", exactamente como
// lo hara server/fpga_bridge.py con quartus_stp en la tarjeta real.
// Escenario en modo demostracion (1 minuto clinico = 1 segundo).
// =============================================================================
`timescale 1ns/1ps
module tb_system;
    localparam integer MSD = 20;           // ciclos por "ms" simulado

    reg clk = 0;
    always #10 clk = ~clk;

    reg  [1:0] KEY = 2'b11;
    reg  [9:0] SW  = 10'b10_0000_0000;     // SW9 = modo demo
    wire [9:0] LEDR;
    wire [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    wire [35:0] GPIO;

    dispenser_top #(.MS_DIV(MSD), .CLK_HZ(1_000_000), .PWM_PRESCALE(2)) dut (
        .MAX10_CLK1_50(clk), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .HEX4(HEX4), .HEX5(HEX5),
        .GPIO(GPIO));

    // ---- lectura del probe (mismo mapa que fpga_bridge.py)
    wire [223:0] P = dut.probe;
    wire [7:0]  ack_seq   = P[7:0];
    wire [3:0]  result    = P[11:8];
    wire [2:0]  state     = P[14:12];
    wire [1:0]  alarm     = P[16:15];
    wire        session   = P[17];
    wire [7:0]  sess_id   = P[25:18];
    wire [9:0]  deliv_ml  = P[35:26];
    wire [9:0]  rate      = P[45:36];
    wire [9:0]  vtbi      = P[55:46];
    wire [7:0]  bolus     = P[63:56];
    wire [7:0]  lockmin   = P[71:64];
    wire [3:0]  maxh      = P[75:72];
    wire [7:0]  patient   = P[83:76];
    wire [7:0]  ev_count  = P[111:104];
    wire [23:0] ev0       = P[135:112];
    wire        pump      = P[208];

    integer pass = 0, fail = 0;
    task expect(input cond, input [8*56-1:0] msg);
        begin
            if (cond) pass = pass + 1;
            else begin fail = fail + 1; $display("  FAIL: %0s  (t=%0d ms, st=%0d al=%0d)", msg, $time / (20 * MSD), state, alarm); end
        end
    endtask
    task wait_ms(input integer ms); begin repeat (ms * MSD) @(posedge clk); end endtask

    // ---- "laptop": manda una orden y espera el acuse
    reg [7:0] seq = 8'd0;
    localparam [3:0] OP_LOGIN = 1, OP_LOGOUT = 2, OP_SET = 3, OP_START = 4, OP_C = 5, OP_BOLUS = 6, OP_SIM = 7;
    task send(input [3:0] op, input [19:0] arg);
        begin
            seq = seq + 8'd1;
            dut.u_jtag.u_issp.src_reg = {seq, op, arg};
            wait (ack_seq == seq);
            wait_ms(2);
        end
    endtask
    task set_param(input [2:0] sel, input [9:0] v); begin send(OP_SET, {sel, 7'd0, v}); end endtask

    // ---- registro de eventos leidos (como lo hara el servidor)
    integer evcnt [0:31];
    integer lastarg [0:31];
    integer i;
    reg [7:0] seen = 0;
    initial for (i = 0; i < 32; i = i + 1) begin evcnt[i] = 0; lastarg[i] = -1; end
    always @(posedge clk) begin
        if (ev_count != seen) begin
            seen = seen + 1;
            // con lectura frecuente siempre hay a lo mas un evento nuevo en ev0
            if (ev0[23:16] < 32) begin
                evcnt[ev0[23:16]]   = evcnt[ev0[23:16]] + 1;
                lastarg[ev0[23:16]] = ev0[15:0];
            end
            $display("  EVENTO %02h arg %04h  (t=%0d ms)", ev0[23:16], ev0[15:0], $time / (20 * MSD));
        end
    end

    initial begin
        $display("== tb_system: escenario completo con ordenes por JTAG ==");
        wait_ms(50);
        expect(evcnt[1] == 1, "evento de arranque");
        expect(state == 0 && !session, "inicia inactivo y sin sesion");

        $display("-- ordenes sin sesion / con ID que no es de enfermeria");
        set_param(0, 360);
        expect(result == 2 && rate == 0, "SET sin sesion rechazado");
        send(OP_LOGIN, 60);
        expect(result == 1 && !session, "ID 60 (paciente) no abre sesion");

        $display("-- Face ID de enfermera ID 3");
        send(OP_LOGIN, 3);
        expect(result == 0 && session && sess_id == 3 && LEDR[0], "sesion abierta");

        $display("-- programacion");
        set_param(0, 360); set_param(1, 5); set_param(2, 1);
        set_param(3, 5);   set_param(4, 2); set_param(5, 55);
        expect(rate == 360 && vtbi == 5 && bolus == 1, "velocidad, volumen y bolo");
        expect(lockmin == 5 && maxh == 2 && patient == 55, "bloqueo, limite y paciente");
        set_param(0, 0);
        expect(result == 3 && rate == 360, "velocidad 0 rechazada (rango)");
        set_param(5, 12);
        expect(result == 3 && patient == 55, "ID de paciente invalido rechazado");

        $display("-- inicio y cierre de sesion");
        send(OP_START, 0);
        expect(state == 1, "infusion corriendo");
        send(OP_LOGOUT, 0);
        expect(!session, "sesion cerrada");
        set_param(0, 999);
        expect(result == 2 && rate == 360, "no se puede cambiar sin sesion");

        wait_ms(3000);
        expect(dut.delivered_drops >= 5 && dut.delivered_drops <= 7, "~6 gotas en 3 s a 360 mL/h");

        $display("-- bolos del paciente (Face ID del paciente)");
        send(OP_BOLUS, 60);
        expect(result == 4, "bolo con Face ID de otra persona rechazado");
        send(OP_BOLUS, 55);
        wait_ms(5);
        expect(evcnt[10] == 1 && lastarg[10] == 1, "bolo concedido al paciente 55");
        send(OP_BOLUS, 55);
        wait_ms(5);
        expect(evcnt[11] == 1 && lastarg[11] == 2, "segundo bolo rechazado por bloqueo");

        $display("-- alguien abre la llave (SW7)");
        wait_ms(4000);
        SW[7] = 1;
        wait (state == 3);
        SW[7] = 0;
        expect(alarm == 2 && LEDR[9] && !pump, "alarma 2: flujo libre, bomba apagada");
        send(OP_C, 0);
        expect(state == 3, "sin sesion no se borra la alarma");
        send(OP_LOGIN, 3); send(OP_C, 0);
        expect(state == 2, "enfermera borra alarma -> pausa");
        send(OP_START, 0); send(OP_LOGOUT, 0);
        expect(state == 1, "reanuda");

        $display("-- tubo tapado (SW6)");
        SW[6] = 1;
        wait (state == 3);
        SW[6] = 0;
        expect(alarm == 1, "alarma 1: sin flujo");
        send(OP_LOGIN, 3); send(OP_C, 0); send(OP_START, 0); send(OP_LOGOUT, 0);

        $display("-- tapa abierta sin sesion (SW5)");
        SW[5] = 1; wait_ms(40);
        expect(state == 3 && alarm == 3, "alarma 3: manipulacion");
        SW[5] = 0; wait_ms(40);
        send(OP_LOGIN, 3); send(OP_C, 0); send(OP_START, 0); send(OP_LOGOUT, 0);

        $display("-- panel de demostracion: fallas simuladas por orden SIM");
        send(OP_SIM, 3'b001);                       // abren la llave
        expect(result == 0 && P[215:213] == 3'b001 && P[210], "SIM llave abierta aceptada");
        wait (state == 3);
        expect(alarm == 2 && dut.c3 == 5'd15 && dut.c0 == 5'd14, "flujo libre, display FrEE");
        send(OP_SIM, 0);
        send(OP_LOGIN, 3); send(OP_C, 0); send(OP_START, 0); send(OP_LOGOUT, 0);
        expect(state == 1, "reanuda tras SIM llave");

        send(OP_SIM, 3'b010);                       // tubo tapado / bolsa vacia
        wait (state == 3);
        expect(alarm == 1 && dut.c3 == 5'd20 && dut.c0 == 5'd22, "sin flujo, display noFL");
        send(OP_SIM, 0);
        send(OP_LOGIN, 3); send(OP_C, 0); send(OP_START, 0); send(OP_LOGOUT, 0);

        send(OP_SIM, 3'b100); wait_ms(40);          // abren el gabinete sin sesion
        expect(state == 3 && alarm == 3 && dut.c3 == 5'd18, "manipulacion, display tAPA");
        send(OP_SIM, 0); wait_ms(40);
        expect(evcnt[17] == 6, "6 eventos de falla simulada en bitacora");
        send(OP_LOGIN, 3); send(OP_C, 0); send(OP_START, 0); send(OP_LOGOUT, 0);
        expect(state == 1, "reanuda tras escenarios del panel");

        $display("-- pausa local con KEY1");
        KEY[1] = 0; wait_ms(40); KEY[1] = 1; wait_ms(40);
        expect(state == 2, "KEY1 pausa sin sesion");
        send(OP_START, 0);
        expect(state == 2, "reanudar requiere sesion");
        send(OP_LOGIN, 3); send(OP_START, 0); send(OP_LOGOUT, 0);

        $display("-- fin de la infusion");
        wait (state == 4 || state == 3);
        wait_ms(10);
        expect(state == 4 && deliv_ml == 5, "infusion terminada con 5 mL");
        expect(!pump, "bomba apagada al terminar");

        $display("== eventos registrados: %0d", seen);
        $display("tb_system RESULT: PASS %0d FAIL %0d", pass, fail);
        $finish;
    end

    initial begin
        #(64'd400_000_000);
        $display("TIMEOUT");
        $display("tb_system RESULT: PASS %0d FAIL %0d", pass, fail + 1);
        $finish;
    end
endmodule
