// =============================================================================
// dispenser_top.v
// Dispensador hospitalario de medicamento liquido con autenticacion Face ID
// Tarjeta: Terasic DE10-Lite (Intel MAX 10 10M50DAF484C7G), reloj de 50 MHz.
//
// Flujo:  iPhone (Face ID, passkey) -> laptop (servidor Python, verifica la
//         firma) -> cable USB-Blaster (JTAG, In-System Sources & Probes)
//         -> FPGA (decide TODO: sesion, rangos, dosis, bolos, alarmas).
//
// La bomba y la camara de goteo se simulan dentro de la FPGA (drip_sim), asi
// la demostracion funciona solo con la tarjeta. Las fallas fisicas (llave
// abierta, tubo tapado, gabinete abierto) se simulan con SW[7:5] o desde el
// panel de demostracion de la pagina (orden SIM); en ambos casos la FPGA las
// detecta por si sola y dispara la alarma.
//
// ---- Controles de la tarjeta -----------------------------------------------
//  KEY[0]   reset
//  KEY[1]   PAUSA local (cualquiera puede detener la infusion)
//  SW[9]    modo demostracion: 1 minuto clinico = 1 segundo
//  SW[7]    simula "llave abierta" (flujo libre -> alarma 2)
//  SW[6]    simula "tubo tapado / bolsa vacia" (sin flujo -> alarma 1)
//  SW[5]    simula "tapa del gabinete abierta" (manipulacion -> alarma 3)
//  SW[1:0]  pantalla: 00 mL infundidos, 01 velocidad, 10 min de bloqueo, 11 ID
//
// ---- LEDs ---------------------------------------------------------------------
//  LEDR0 sesion de enfermeria   LEDR1 bomba encendida   LEDR2 gota
//  LEDR3 bolo concedido         LEDR4 orden/bolo rechazado
//  LEDR5 tapa abierta           LEDR8 latido            LEDR9 ALARMA
//
// ---- Salidas opcionales en GPIO (no se requieren para la demo) ------------
//  GPIO[4] PWM bomba   GPIO[5] IN1 bomba   GPIO[6] IN2 (0)   GPIO[10] zumbador
//  GPIO[11] LED de alarma externo
// =============================================================================
module dispenser_top #(
    parameter integer CLK_HZ       = 50_000_000,
    parameter integer MS_DIV       = CLK_HZ / 1000,
    parameter integer DROP_FACTOR  = 20,
    parameter integer SESSION_S    = 120,
    parameter integer NOFLOW_MS    = 5_000,
    parameter integer PUMP_DROP_MS = 150,
    parameter integer PUMP_DUTY    = 200,
    parameter integer PWM_PRESCALE = 196
)(
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire [7:0]  HEX1,
    output wire [7:0]  HEX2,
    output wire [7:0]  HEX3,
    output wire [7:0]  HEX4,
    output wire [7:0]  HEX5,
    inout  wire [35:0] GPIO
);
    // ------------------------------------------------------------ reloj/reset
    wire clk = MAX10_CLK1_50;

    reg [2:0] rst_sync = 3'b111;
    reg [7:0] por      = 8'd0;
    always @(posedge clk) begin
        rst_sync <= {rst_sync[1:0], ~KEY[0]};
        if (por != 8'hFF) por <= por + 8'd1;
    end
    wire rst = rst_sync[2] | (por != 8'hFF);

    reg rst_d;
    always @(posedge clk) rst_d <= rst;
    wire boot_pulse = rst_d & ~rst;

    // ------------------------------------------------------------ tiempo base
    wire        tick_1ms, tick_1s;
    wire [31:0] uptime_s;
    tick_gen #(.MS_DIV(MS_DIV)) u_tick (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms), .tick_1s(tick_1s), .uptime_s(uptime_s));

    reg [9:0] sw_s1, sw_s2;
    always @(posedge clk) begin
        sw_s1 <= SW;
        sw_s2 <= sw_s1;
    end
    wire demo_mode  = sw_s2[9];

    // fallas simuladas: switch de la tarjeta O boton del panel de demostracion
    wire [2:0] sim_flags;
    wire sim_leak = sw_s2[7] | sim_flags[0];   // llave abierta -> flujo libre
    wire sim_occl = sw_s2[6] | sim_flags[1];   // tubo tapado / bolsa vacia
    wire sim_lid  = sw_s2[5] | sim_flags[2];   // gabinete abierto

    reg [5:0] sec_cnt;
    reg       tick_min;
    always @(posedge clk) begin
        tick_min <= 1'b0;
        if (rst) sec_cnt <= 6'd0;
        else if (tick_1s) begin
            if (demo_mode) begin
                tick_min <= 1'b1;
                sec_cnt  <= 6'd0;
            end else if (sec_cnt == 6'd59) begin
                sec_cnt  <= 6'd0;
                tick_min <= 1'b1;
            end else begin
                sec_cnt <= sec_cnt + 6'd1;
            end
        end
    end

    // ------------------------------------------------------------ GPIO
    wire pump_pwm_w, pump_in1_w, buz_w, alarm_led_w;
    assign GPIO[3:0]   = 4'bzzzz;
    assign GPIO[4]     = pump_pwm_w;
    assign GPIO[5]     = pump_in1_w;
    assign GPIO[6]     = 1'b0;
    assign GPIO[9:7]   = 3'bzzz;
    assign GPIO[10]    = buz_w;
    assign GPIO[11]    = alarm_led_w;
    assign GPIO[35:12] = {24{1'bz}};

    // ------------------------------------------------------------ entradas
    wire pause_lvl, pause_rise, pause_fall;
    wire lid_open, lid_rise, lid_fall;
    sync_debounce #(.STABLE_MS(20)) u_db_pause (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms), .din(~KEY[1]),
        .dout(pause_lvl), .rise(pause_rise), .fall(pause_fall));
    sync_debounce #(.STABLE_MS(20)) u_db_lid (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms), .din(sim_lid),
        .dout(lid_open), .rise(lid_rise), .fall(lid_fall));

    // ------------------------------------------------------------ enlace JTAG
    wire [31:0]  cmd_word;
    wire [223:0] probe;
    jtag_link u_jtag (.clk(clk), .probe(probe), .source(cmd_word));

    // ------------------------------------------------------------ ordenes
    wire        session;
    wire [7:0]  session_id, session_left_s;
    wire [9:0]  rate_mlh, vtbi_ml;
    wire [7:0]  bolus_ml, lockout_min, patient_id;
    wire [3:0]  max_per_hour;
    wire        net_start, net_c, bolus_req;
    wire [7:0]  ack_seq;
    wire [3:0]  result;
    wire        ev_login, ev_logout, ev_param, ev_denied;
    wire [15:0] ev_param_arg;
    wire [7:0]  ev_denied_arg;
    wire        ev_sim;

    cmd_ctrl #(.SESSION_S(SESSION_S)) u_cmd (
        .clk(clk), .rst(rst), .tick_1s(tick_1s), .cmd_word(cmd_word),
        .session(session), .session_id(session_id), .session_left_s(session_left_s),
        .rate_mlh(rate_mlh), .vtbi_ml(vtbi_ml), .bolus_ml(bolus_ml),
        .lockout_min(lockout_min), .max_per_hour(max_per_hour), .patient_id(patient_id),
        .cmd_start(net_start), .cmd_c(net_c), .bolus_req(bolus_req),
        .sim_flags(sim_flags), .ev_sim(ev_sim),
        .ack_seq(ack_seq), .result(result),
        .ev_login(ev_login), .ev_logout(ev_logout), .ev_param(ev_param),
        .ev_param_arg(ev_param_arg), .ev_denied(ev_denied), .ev_denied_arg(ev_denied_arg));

    // ------------------------------------------------------------ goteo
    wire pump_on;
    wire drop;
    drip_sim #(.PUMP_DROP_MS(PUMP_DROP_MS)) u_drip (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms), .pump_on(pump_on),
        .valve_open(sim_leak), .occluded(sim_occl), .drop(drop));

    // ------------------------------------------------------------ infusion
    wire [2:0]  inf_state;
    wire [1:0]  alarm_code;
    wire [15:0] delivered_drops, sched_drops;
    wire [9:0]  delivered_ml;
    wire [31:0] interval_ms;
    wire        ev_start, ev_pause, ev_done, ev_alarm, ev_alarm_clear, ev_start_rej, ev_reset;
    wire        bolus_grant, bolus_deny;
    wire [1:0]  deny_reason;
    wire [7:0]  lockout_left;
    wire [3:0]  bolus_count;

    infusion_ctrl #(
        .DROP_FACTOR(DROP_FACTOR), .NOFLOW_MS(NOFLOW_MS)
    ) u_inf (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms),
        .rate_mlh(rate_mlh), .vtbi_ml(vtbi_ml), .bolus_ml(bolus_ml),
        .session(session), .cmd_start(net_start), .cmd_c(net_c | pause_rise),
        .bolus_grant(bolus_grant), .drop(drop), .lid_open(lid_open),
        .state(inf_state), .pump_on(pump_on), .alarm_code(alarm_code),
        .delivered_drops(delivered_drops), .sched_drops(sched_drops),
        .delivered_ml(delivered_ml), .interval_ms(interval_ms),
        .ev_start(ev_start), .ev_pause(ev_pause), .ev_done(ev_done),
        .ev_alarm(ev_alarm), .ev_alarm_clear(ev_alarm_clear),
        .ev_start_rej(ev_start_rej), .ev_reset(ev_reset));

    bolus_limiter u_bolus (
        .clk(clk), .rst(rst), .tick_min(tick_min), .req(bolus_req),
        .allow((inf_state == 3'd1) && (bolus_ml != 8'd0)),
        .lockout_min(lockout_min), .max_per_hour(max_per_hour),
        .grant(bolus_grant), .deny(bolus_deny), .deny_reason(deny_reason),
        .lockout_left(lockout_left), .count_win(bolus_count));

    // ------------------------------------------------------------ actuadores
    wire pwm_raw;
    pwm #(.PRESCALE(PWM_PRESCALE)) u_pwm (
        .clk(clk), .rst(rst), .duty(PUMP_DUTY[7:0]), .out(pwm_raw));
    assign pump_pwm_w = pwm_raw & pump_on;
    assign pump_in1_w = pump_on;

    wire in_alarm = (inf_state == 3'd3);
    assign alarm_led_w = in_alarm;

    buzzer_ctrl #(.CLK_HZ(CLK_HZ)) u_buz (
        .clk(clk), .rst(rst), .tick_1ms(tick_1ms), .alarm(in_alarm),
        .beep_click(1'b0),
        .beep_ok(ev_login | bolus_grant | ev_start),
        .beep_err(ev_denied | bolus_deny | ev_start_rej),
        .buz(buz_w));

    // ------------------------------------------------------------ eventos
    // Cada evento deja una bandera pendiente; se registra uno por ciclo en un
    // historial de 4 eventos + contador que la laptop lee por JTAG.
    wire [15:0] ev_new = {ev_denied, lid_rise, ev_reset, ev_start_rej,
                          ev_alarm_clear, bolus_deny, bolus_grant, ev_done,
                          ev_pause, ev_start, ev_param, ev_logout, ev_login,
                          ev_alarm, ev_sim, boot_pulse};
    reg  [15:0] ev_pend;
    reg  [4:0]  ev_sel;
    reg  [1:0]  deny_reason_q;
    reg  [3:0]  bolus_count_q;
    reg  [7:0]  denied_q;
    reg  [15:0] param_q;
    integer     ei;

    always @* begin
        ev_sel = 5'd31;
        for (ei = 15; ei >= 0; ei = ei - 1)
            if (ev_pend[ei]) ev_sel = ei[4:0];
    end

    reg [7:0]  ev_code;
    reg [15:0] ev_arg;
    always @* begin
        ev_arg = 16'd0;
        case (ev_sel)
            5'd0:  ev_code = 8'h01;                                          // arranque
            5'd1:  begin ev_code = 8'h11; ev_arg = {13'd0, sim_flags}; end  // falla simulada
            5'd2:  begin ev_code = 8'h0C; ev_arg = {14'd0, alarm_code}; end  // alarma
            5'd3:  begin ev_code = 8'h02; ev_arg = {8'd0, session_id}; end   // login
            5'd4:  begin ev_code = 8'h05; ev_arg = {8'd0, session_id}; end   // fin de sesion
            5'd5:  begin ev_code = 8'h06; ev_arg = param_q; end              // parametro
            5'd6:  begin ev_code = 8'h07; ev_arg = {6'd0, rate_mlh}; end     // inicio
            5'd7:  begin ev_code = 8'h08; ev_arg = {6'd0, delivered_ml}; end // pausa
            5'd8:  begin ev_code = 8'h09; ev_arg = {6'd0, delivered_ml}; end // fin
            5'd9:  begin ev_code = 8'h0A; ev_arg = {12'd0, bolus_count_q}; end
            5'd10: begin ev_code = 8'h0B; ev_arg = {14'd0, deny_reason_q}; end
            5'd11: begin ev_code = 8'h0D; ev_arg = {8'd0, session_id}; end
            5'd12: ev_code = 8'h0E;
            5'd13: begin ev_code = 8'h0F; ev_arg = {8'd0, session_id}; end
            5'd14: begin ev_code = 8'h10; ev_arg = {15'd0, session}; end
            5'd15: begin ev_code = 8'h12; ev_arg = {8'd0, denied_q}; end     // orden rechazada
            default: ev_code = 8'h00;
        endcase
    end

    reg [7:0]  ev_count;
    reg [23:0] ev0, ev1, ev2, ev3;
    always @(posedge clk) begin
        if (rst) begin
            ev_pend       <= 16'd0;
            deny_reason_q <= 2'd0;
            bolus_count_q <= 4'd0;
            denied_q      <= 8'd0;
            param_q       <= 16'd0;
            ev_count      <= 8'd0;
            ev0 <= 24'd0; ev1 <= 24'd0; ev2 <= 24'd0; ev3 <= 24'd0;
        end else begin
            if (bolus_deny)  deny_reason_q <= deny_reason;
            if (bolus_grant) bolus_count_q <= bolus_count;
            if (ev_denied)   denied_q      <= ev_denied_arg;
            if (ev_param)    param_q       <= ev_param_arg;
            ev_pend <= (ev_pend & ~((ev_sel == 5'd31) ? 16'd0 : (16'd1 << ev_sel))) | ev_new;
            if (ev_sel != 5'd31) begin
                ev3 <= ev2; ev2 <= ev1; ev1 <= ev0;
                ev0 <= {ev_code, ev_arg};
                ev_count <= ev_count + 8'd1;
            end
        end
    end

    // ------------------------------------------------------------ estado -> JTAG
    // Mapa de bits documentado en server/fpga_bridge.py (STATUS_FIELDS).
    assign probe = {
        8'd0,                  // [223:216]
        sim_flags,             // [215:213]
        sim_lid,               // [212]
        sim_occl,              // [211]
        sim_leak,              // [210]
        lid_open,              // [209]
        pump_on,               // [208]
        ev3,                   // [207:184]
        ev2,                   // [183:160]
        ev1,                   // [159:136]
        ev0,                   // [135:112]
        ev_count,              // [111:104]
        session_left_s,        // [103:96]
        bolus_count,           // [95:92]
        lockout_left,          // [91:84]
        patient_id,            // [83:76]
        max_per_hour,          // [75:72]
        lockout_min,           // [71:64]
        bolus_ml,              // [63:56]
        vtbi_ml,               // [55:46]
        rate_mlh,              // [45:36]
        delivered_ml,          // [35:26]
        session_id,            // [25:18]
        session,               // [17]
        alarm_code,            // [16:15]
        inf_state,             // [14:12]
        result,                // [11:8]
        ack_seq                // [7:0]
    };

    // ------------------------------------------------------------ pantalla
    localparam [4:0] C_BL = 5'd16, C_r = 5'd17, C_n = 5'd20, C_L = 5'd22,
                     C_P = 5'd24, C_DASH = 5'd25, C_i = 5'd26, C_u = 5'd27,
                     C_A = 5'd10, C_d = 5'd13, C_E = 5'd14, C_F = 5'd15,
                     C_t = 5'd18, C_o = 5'd21;

    reg  [13:0] disp_bin;
    wire [15:0] disp_bcd;
    bin2bcd14 u_bcd (.bin(disp_bin), .bcd(disp_bcd));

    reg [4:0] c5, c4, c3, c2, c1, c0;
    always @* begin
        case (sw_s2[1:0])
            2'd0:    disp_bin = {4'd0, delivered_ml};
            2'd1:    disp_bin = {4'd0, rate_mlh};
            2'd2:    disp_bin = {6'd0, lockout_left};
            default: disp_bin = {6'd0, session_id};
        endcase
        case (inf_state)
            3'd1:    begin c5 = C_r; c4 = C_u; end   // ru  corriendo
            3'd2:    begin c5 = C_P; c4 = C_A; end   // PA  pausa
            3'd3:    begin c5 = C_A; c4 = C_L; end   // AL  alarma
            3'd4:    begin c5 = C_d; c4 = C_n; end   // dn  terminado
            default: begin c5 = C_i; c4 = C_d; end   // id  inactivo
        endcase
        c3 = disp_bcd[15:12]; c2 = disp_bcd[11:8]; c1 = disp_bcd[7:4]; c0 = disp_bcd[3:0];
        if (in_alarm) begin
            // texto de la alarma: noFL sin flujo | FrEE flujo libre | tAPA gabinete
            case (alarm_code)
                2'd1:    begin c3 = C_n; c2 = C_o; c1 = C_F; c0 = C_L; end
                2'd2:    begin c3 = C_F; c2 = C_r; c1 = C_E; c0 = C_E; end
                default: begin c3 = C_t; c2 = C_A; c1 = C_P; c0 = C_A; end
            endcase
        end
    end

    seg7_char u_h5 (.c(c5), .seg_n(HEX5));
    seg7_char u_h4 (.c(c4), .seg_n(HEX4));
    seg7_char u_h3 (.c(c3), .seg_n(HEX3));
    seg7_char u_h2 (.c(c2), .seg_n(HEX2));
    seg7_char u_h1 (.c(c1), .seg_n(HEX1));
    seg7_char u_h0 (.c(c0), .seg_n(HEX0));

    // ------------------------------------------------------------ LEDs
    wire led_drop, led_grant, led_deny;
    pulse_stretch #(.MS(80))  u_ps0 (.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .pulse(drop),        .out(led_drop));
    pulse_stretch #(.MS(800)) u_ps1 (.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .pulse(bolus_grant), .out(led_grant));
    pulse_stretch #(.MS(800)) u_ps2 (.clk(clk), .rst(rst), .tick_1ms(tick_1ms), .pulse(bolus_deny | ev_denied | ev_start_rej), .out(led_deny));

    reg hb;
    always @(posedge clk) if (rst) hb <= 1'b0; else if (tick_1s) hb <= ~hb;

    assign LEDR[0] = session;
    assign LEDR[1] = pump_on;
    assign LEDR[2] = led_drop;
    assign LEDR[3] = led_grant;
    assign LEDR[4] = led_deny;
    assign LEDR[5] = lid_open;
    assign LEDR[6] = 1'b0;
    assign LEDR[7] = 1'b0;
    assign LEDR[8] = hb;
    assign LEDR[9] = in_alarm;
endmodule
