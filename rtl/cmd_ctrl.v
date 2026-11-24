// -----------------------------------------------------------------------------
// cmd_ctrl.v
// Recibe las ordenes que llegan de la laptop por JTAG (despues de que el
// iPhone confirmo la identidad con Face ID) y aplica TODAS las reglas en la
// FPGA: roles, sesion con tiempo limite, rangos de cada parametro e
// identidad del paciente para los bolos. La laptop solo transporta ordenes;
// si manda algo invalido, la FPGA lo rechaza.
//
// Registro de orden (32 bits, escrito por JTAG):
//   [31:24] seq   numero de secuencia; la orden se ejecuta cuando cambia
//   [23:20] op    1 LOGIN(id) 2 LOGOUT 3 SET(sel,valor) 4 START
//                 5 C (pausa / borrar alarma / nueva bolsa) 6 BOLUS(id)
//                 7 SIM(fallas) solo demo: arg[2:0] = {gabinete, tubo tapado, llave}
//   [19:0]  arg   LOGIN/BOLUS: id en [7:0]; SET: sel en [19:17], valor en [9:0]
//
// SIM no da permisos: solo simula lo que pasaria fisicamente (alguien abre la
// llave, se vacia la bolsa, abren el gabinete). La FPGA lo detecta sola igual
// que si viniera de un sensor y dispara la alarma correspondiente.
//
// Codigos de resultado:
//   0 OK  1 no es enfermera  2 sin sesion  3 fuera de rango
//   4 paciente incorrecto  5 orden desconocida
//
// Roles por ID:  1..49 enfermeria  |  50..99 pacientes
// Parametros (sel): 0 velocidad mL/h (1..999)   1 volumen mL (1..999)
//                   2 bolo mL (0..50)          3 bloqueo min (0..240)
//                   4 bolos/hora (0..8)        5 ID paciente (0 o 50..99)
// -----------------------------------------------------------------------------
module cmd_ctrl #(
    parameter integer NURSE_MIN = 1,
    parameter integer NURSE_MAX = 49,
    parameter integer SESSION_S = 120
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tick_1s,
    input  wire [31:0] cmd_word,         // salida "source" del JTAG
    // sesion
    output reg         session,
    output reg  [7:0]  session_id,
    output reg  [7:0]  session_left_s,
    // parametros
    output reg  [9:0]  rate_mlh,
    output reg  [9:0]  vtbi_ml,
    output reg  [7:0]  bolus_ml,
    output reg  [7:0]  lockout_min,
    output reg  [3:0]  max_per_hour,
    output reg  [7:0]  patient_id,
    // hacia el controlador de infusion / limitador
    output reg         cmd_start,
    output reg         cmd_c,
    output reg         bolus_req,
    // fallas simuladas para la demostracion {gabinete, tubo tapado, llave}
    output reg  [2:0]  sim_flags,
    output reg         ev_sim,
    // acuse para la laptop
    output reg  [7:0]  ack_seq,
    output reg  [3:0]  result,
    // eventos
    output reg         ev_login,
    output reg         ev_logout,
    output reg         ev_param,
    output reg  [15:0] ev_param_arg,
    output reg         ev_denied,
    output reg  [7:0]  ev_denied_arg     // {op, result}
);
    localparam [3:0] OP_LOGIN = 4'd1, OP_LOGOUT = 4'd2, OP_SET = 4'd3,
                     OP_START = 4'd4, OP_C = 4'd5, OP_BOLUS = 4'd6,
                     OP_SIM = 4'd7;

    // ---------------------------------------------- sincronizacion de la orden
    reg [31:0] s1, s2, s3;
    always @(posedge clk) begin
        s1 <= cmd_word;
        s2 <= s1;
        s3 <= s2;
    end
    wire        stable = (s2 == s3);
    wire [7:0]  seq    = s3[31:24];
    wire [3:0]  op     = s3[23:20];
    wire [19:0] arg    = s3[19:0];
    wire [7:0]  arg_id = arg[7:0];
    wire [2:0]  sel    = arg[19:17];
    wire [9:0]  val    = arg[9:0];

    function in_range;
        input [2:0] s;
        input [9:0] v;
        begin
            case (s)
                3'd0, 3'd1: in_range = (v >= 10'd1) && (v <= 10'd999);
                3'd2:       in_range = (v <= 10'd50);
                3'd3:       in_range = (v <= 10'd240);
                3'd4:       in_range = (v <= 10'd8);
                3'd5:       in_range = (v == 10'd0) || ((v >= 10'd50) && (v <= 10'd99));
                default:    in_range = 1'b0;
            endcase
        end
    endfunction

    wire is_nurse_id = (arg_id >= NURSE_MIN) && (arg_id <= NURSE_MAX);

    reg [3:0] res;
    always @(posedge clk) begin
        cmd_start <= 1'b0;
        cmd_c     <= 1'b0;
        bolus_req <= 1'b0;
        ev_login  <= 1'b0;
        ev_logout <= 1'b0;
        ev_param  <= 1'b0;
        ev_denied <= 1'b0;
        ev_sim    <= 1'b0;
        if (rst) begin
            sim_flags      <= 3'd0;
            session        <= 1'b0;
            session_id     <= 8'd0;
            session_left_s <= 8'd0;
            rate_mlh       <= 10'd0;      // arranque seguro: sin programa
            vtbi_ml        <= 10'd0;
            bolus_ml       <= 8'd0;
            lockout_min    <= 8'd10;
            max_per_hour   <= 4'd0;
            patient_id     <= 8'd0;
            ack_seq        <= 8'd0;
            result         <= 4'd0;
            ev_param_arg   <= 16'd0;
            ev_denied_arg  <= 8'd0;
        end else begin
            // ------------------------------------------- tiempo de sesion
            if (tick_1s && session) begin
                if (session_left_s <= 8'd1) begin
                    session        <= 1'b0;
                    session_left_s <= 8'd0;
                    ev_logout      <= 1'b1;
                end else begin
                    session_left_s <= session_left_s - 8'd1;
                end
            end

            // ------------------------------------------- nueva orden
            if (stable && seq != ack_seq) begin
                ack_seq <= seq;
                res = 4'd0;
                case (op)
                    OP_LOGIN: begin
                        if (is_nurse_id) begin
                            if (!session || session_id != arg_id) ev_login <= 1'b1;
                            session        <= 1'b1;
                            session_id     <= arg_id;
                            session_left_s <= SESSION_S[7:0];
                        end else res = 4'd1;
                    end
                    OP_LOGOUT: begin
                        if (session) begin
                            session        <= 1'b0;
                            session_left_s <= 8'd0;
                            ev_logout      <= 1'b1;
                        end else res = 4'd2;
                    end
                    OP_SET: begin
                        if (!session)                  res = 4'd2;
                        else if (!in_range(sel, val))  res = 4'd3;
                        else begin
                            case (sel)
                                3'd0: rate_mlh     <= val;
                                3'd1: vtbi_ml      <= val;
                                3'd2: bolus_ml     <= val[7:0];
                                3'd3: lockout_min  <= val[7:0];
                                3'd4: max_per_hour <= val[3:0];
                                default: patient_id <= val[7:0];
                            endcase
                            ev_param       <= 1'b1;
                            ev_param_arg   <= {1'b0, sel, 2'b00, val};
                            session_left_s <= SESSION_S[7:0];
                        end
                    end
                    OP_START: begin
                        if (session) begin
                            cmd_start      <= 1'b1;
                            session_left_s <= SESSION_S[7:0];
                        end else res = 4'd2;
                    end
                    OP_C: begin
                        cmd_c <= 1'b1;            // pausar siempre se permite
                        if (session) session_left_s <= SESSION_S[7:0];
                    end
                    OP_BOLUS: begin
                        if (patient_id == 8'd0 || arg_id == patient_id) bolus_req <= 1'b1;
                        else res = 4'd4;
                    end
                    OP_SIM: begin
                        sim_flags <= arg[2:0];
                        ev_sim    <= (arg[2:0] != sim_flags);
                    end
                    default: res = 4'd5;
                endcase
                result <= res;
                if (res != 4'd0) begin
                    ev_denied     <= 1'b1;
                    ev_denied_arg <= {op, res};
                end
            end
        end
    end
endmodule
