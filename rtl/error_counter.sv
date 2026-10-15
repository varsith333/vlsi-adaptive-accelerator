`timescale 1ns/1ps
// ============================================================================
// error_counter.sv — Configurable-threshold saturating error counter
// ----------------------------------------------------------------------------
// Counts monitor error pulses. Two saturating threshold flags feed the
// adaptive controller:
//   thresh_hit : count >= TH_ERR  -> escalate MONITORED -> PROTECTED
//   sev_hit    : count >= TH_SEV  -> escalate any mode -> RECOVERY
// `clear` zeroes the counter (issued when entering PROTECTED, and on
// successful recovery — see design decision D-4). Counter saturates at 0xFF
// so it can never wrap silently (requirement N-07).
// ============================================================================
module error_counter #(
    parameter logic [7:0] TH_ERR = 8'd2,
    parameter logic [7:0] TH_SEV = 8'd4
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       err_pulse,
    input  logic       clear,
    output logic [7:0] count,
    output logic       thresh_hit,
    output logic       sev_hit
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          count <= 8'd0;
        else if (clear)                      count <= 8'd0;
        else if (err_pulse && (count != 8'hFF)) count <= count + 8'd1;
    end

    assign thresh_hit = (count >= TH_ERR);
    assign sev_hit    = (count >= TH_SEV);

endmodule
