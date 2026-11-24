// -----------------------------------------------------------------------------
// infusion_ctrl.v
// Nucleo del dispensador: dosificacion gota a gota en lazo cerrado.
//
// Idea de control: un "programador" incrementa sched_drops (gotas que ya
// deberian haber caido) cada intervalo_ms = 3 600 000 / (mL/h * gotas/mL).
// La bomba peristaltica se enciende solo mientras delivered_drops <
// sched_drops, donde delivered_drops viene del sensor optico de la camara de
// goteo. Asi la bomba entrega exactamente las gotas programadas aunque su
// caudal real varie, y la inercia del motor se compensa sola.
//
// Supervisiones (todas llevan a ALARMA con la bomba apagada):
//   1 NO_FLOW   : bomba encendida NOFLOW_MS sin detectar gotas
//                 (bolsa vacia, tubo ocluido o sensor desconectado)
//   2 FREE_FLOW : caen mas gotas de las programadas (+FREEFLOW_MARGIN) o
//                 caen gotas con la infusion detenida (STRAY_LIMIT) ->
//                 alguien abrio la llave / manipulo el equipo
//   3 TAMPER    : tapa del gabinete abierta sin sesion de enfermeria
// Solo una enfermera autenticada puede borrar una alarma (tecla C).
//
// Estados: IDLE (sin iniciar) RUN PAUSE ALARM DONE
// -----------------------------------------------------------------------------
module infusion_ctrl #(
    parameter integer DROP_FACTOR     = 20,      // gotas/mL (macrogoteo)
    parameter integer FREEFLOW_MARGIN = 3,
    parameter integer STRAY_LIMIT     = 3,
    parameter integer NOFLOW_MS       = 15000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_1ms,
    input  wire [9:0]  rate_mlh,
    input  wire [9:0]  vtbi_ml,
    input  wire [7:0]  bolus_ml,
    input  wire        session,
    input  wire        cmd_start,
    input  wire        cmd_c,
    input  wire        bolus_grant,
    input  wire        drop,
    input  wire        lid_open,
    output reg  [2:0]  state,
    output wire        pump_on,
    output reg  [1:0]  alarm_code,
    output reg  [15:0] delivered_drops,
    output reg  [15:0] sched_drops,
    output reg  [9:0]  delivered_ml,
    output wire [31:0] interval_ms,
    output reg         ev_start,
    output reg         ev_pause,
    output reg         ev_done,
    output reg         ev_alarm,
    output reg         ev_alarm_clear,
    output reg         ev_start_rej,
    output reg         ev_reset
);
    localparam [2:0] ST_IDLE = 3'd0, ST_RUN = 3'd1, ST_PAUSE = 3'd2,
                     ST_ALARM = 3'd3, ST_DONE = 3'd4;
    localparam [1:0] AL_NOFLOW = 2'd1, AL_FREEFLOW = 2'd2, AL_TAMPER = 2'd3;

    wire [31:0] vtbi_mul  = vtbi_ml  * DROP_FACTOR;
    wire [31:0] bolus_mul = bolus_ml * DROP_FACTOR;
    wire [15:0] vtbi_drops  = vtbi_mul[15:0];
    wire [15:0] bolus_drops = bolus_mul[15:0];

    // --------------------------------------------- intervalo entre gotas (ms)
    reg  [9:0]  rate_q;
    reg         div_start;
    wire        div_busy, div_done;
    wire [31:0] div_q;
    reg  [31:0] interval_r;
    reg         int_valid;
    wire [31:0] den_w = rate_q * DROP_FACTOR;

    divu #(.W(32)) u_div (
        .clk(clk), .rst(rst), .start(div_start),
        .num(32'd3_600_000), .den(den_w),
        .quo(div_q), .busy(div_busy), .done(div_done));

    assign interval_ms = interval_r;

    always @(posedge clk) begin
        div_start <= 1'b0;
        if (rst) begin
            rate_q     <= 10'd0;
            int_valid  <= 1'b0;
            interval_r <= 32'd0;
        end else begin
            if (rate_mlh != rate_q && !div_busy && !div_start) begin
                rate_q    <= rate_mlh;
                int_valid <= 1'b0;
                div_start <= (rate_mlh != 10'd0);
            end
            if (div_done) begin
                interval_r <= (div_q == 32'd0) ? 32'd1 : div_q;
                int_valid  <= (rate_q != 10'd0);
            end
        end
    end

    // ----------------------------------------------------- control principal
    reg  [31:0] ms_acc;
    reg  [15:0] noflow_ms;
    reg  [3:0]  stray;
    reg  [6:0]  drop_mod;

    assign pump_on = (state == ST_RUN) && (delivered_drops < sched_drops);

    wire start_ok  = session && int_valid && (vtbi_ml != 10'd0) &&
                     (delivered_drops < vtbi_drops);
    wire [16:0] sched_plus_margin = {1'b0, sched_drops} + FREEFLOW_MARGIN;
    wire [16:0] sched_plus_bolus  = {1'b0, sched_drops} + {1'b0, bolus_drops};

    always @(posedge clk) begin
        ev_start       <= 1'b0;
        ev_pause       <= 1'b0;
        ev_done        <= 1'b0;
        ev_alarm       <= 1'b0;
        ev_alarm_clear <= 1'b0;
        ev_start_rej   <= 1'b0;
        ev_reset       <= 1'b0;
        if (rst) begin
            state           <= ST_IDLE;
            alarm_code      <= 2'd0;
            delivered_drops <= 16'd0;
            sched_drops     <= 16'd0;
            delivered_ml    <= 10'd0;
            drop_mod        <= 7'd0;
            ms_acc          <= 32'd0;
            noflow_ms       <= 16'd0;
            stray           <= 4'd0;
        end else begin
            // conteo de gotas en todos los estados (todo lo que cae llega al paciente)
            if (drop) begin
                delivered_drops <= delivered_drops + 16'd1;
                if (drop_mod == DROP_FACTOR - 1) begin
                    drop_mod     <= 7'd0;
                    delivered_ml <= delivered_ml + 10'd1;
                end else begin
                    drop_mod <= drop_mod + 7'd1;
                end
            end

            // temporizador de "sin flujo"
            if (!pump_on || drop)
                noflow_ms <= 16'd0;
            else if (tick_1ms && noflow_ms != 16'hFFFF)
                noflow_ms <= noflow_ms + 16'd1;

            case (state)
                ST_RUN: begin
                    if (lid_open && !session) begin
                        state <= ST_ALARM; alarm_code <= AL_TAMPER; ev_alarm <= 1'b1;
                    end else if ({1'b0, delivered_drops} > sched_plus_margin) begin
                        state <= ST_ALARM; alarm_code <= AL_FREEFLOW; ev_alarm <= 1'b1;
                    end else if (noflow_ms >= NOFLOW_MS) begin
                        state <= ST_ALARM; alarm_code <= AL_NOFLOW; ev_alarm <= 1'b1;
                    end else if (delivered_drops >= vtbi_drops) begin
                        state <= ST_DONE; ev_done <= 1'b1; stray <= 4'd0;
                    end else if (cmd_c) begin
                        state <= ST_PAUSE; ev_pause <= 1'b1; stray <= 4'd0;
                    end else if (bolus_grant) begin
                        sched_drops <= (sched_plus_bolus > {1'b0, vtbi_drops}) ?
                                       vtbi_drops : sched_plus_bolus[15:0];
                    end else if (tick_1ms && int_valid) begin
                        if (ms_acc >= interval_r - 32'd1) begin
                            ms_acc <= 32'd0;
                            if (sched_drops < vtbi_drops) sched_drops <= sched_drops + 16'd1;
                        end else begin
                            ms_acc <= ms_acc + 32'd1;
                        end
                    end
                end

                ST_ALARM: begin
                    if (cmd_c && session) begin
                        state          <= ST_PAUSE;
                        alarm_code     <= 2'd0;
                        sched_drops    <= delivered_drops;
                        stray          <= 4'd0;
                        ev_alarm_clear <= 1'b1;
                    end
                end

                default: begin // IDLE, PAUSE, DONE: la bomba esta apagada
                    if (drop && stray != 4'hF) stray <= stray + 4'd1;

                    if (lid_open && !session) begin
                        state <= ST_ALARM; alarm_code <= AL_TAMPER; ev_alarm <= 1'b1;
                    end else if (drop && stray >= STRAY_LIMIT - 1) begin
                        state <= ST_ALARM; alarm_code <= AL_FREEFLOW; ev_alarm <= 1'b1;
                    end else if (cmd_start) begin
                        if (state != ST_DONE && start_ok) begin
                            state       <= ST_RUN;
                            sched_drops <= delivered_drops;   // sin "recuperar" lo pausado
                            ms_acc      <= 32'd0;
                            stray       <= 4'd0;
                            ev_start    <= 1'b1;
                        end else begin
                            ev_start_rej <= 1'b1;
                        end
                    end else if (cmd_c && session) begin
                        // nueva bolsa / reinicio de contadores
                        state           <= ST_IDLE;
                        delivered_drops <= 16'd0;
                        sched_drops     <= 16'd0;
                        delivered_ml    <= 10'd0;
                        drop_mod        <= 7'd0;
                        stray           <= 4'd0;
                        ev_reset        <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
