// -----------------------------------------------------------------------------
// pwm.v  -  PWM de 8 bits. f_pwm = f_clk / (PRESCALE * 256).
// Con 50 MHz y PRESCALE = 196 -> ~1 kHz (adecuado para L298N / TB6612FNG).
// -----------------------------------------------------------------------------
module pwm #(
    parameter integer PRESCALE = 196
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] duty,
    output reg        out
);
    reg [15:0] pre;
    reg [7:0]  cnt;

    always @(posedge clk) begin
        if (rst) begin
            pre <= 16'd0;
            cnt <= 8'd0;
            out <= 1'b0;
        end else begin
            if (pre == PRESCALE - 1) begin
                pre <= 16'd0;
                cnt <= cnt + 8'd1;
            end else begin
                pre <= pre + 16'd1;
            end
            out <= (cnt < duty);
        end
    end
endmodule
