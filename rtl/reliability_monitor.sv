`timescale 1ns/1ps
// ============================================================================
// reliability_monitor.sv — Always-present cheap sensor (Layer 1)
// ----------------------------------------------------------------------------
// Checks (combinational, evaluated EVERY cycle the relevant enable is active):
//
//  1. RANGE check on the pre-commit value (result at ST_CHECK) and on the
//     delivered value (output buffer head while out_valid). Active in ALL
//     modes (coarse baseline — NORMAL mode is never fully blind).
//     Bound: |x| <= VEC_LEN * 2^(2*(DATA_W-1))  (= max legal |sum| of products)
//
//  2. PARITY check: (^acc != acc_parity) — fine modes only. Catches single-bit
//     flips of the accumulator between normal updates.
//
//  3. ILLEGAL FSM STATE: core state code 7 — fine modes only (control class).
//
//  4. WATCHDOG: busy with no forward progress for WD_CYC cycles — fine modes
//     only (liveness class). Emits a single-cycle wd_timeout pulse.
//
// `pre_invalid` = value must not be committed (range bad at ST_CHECK, or bad
// parity observed at ST_CHECK). The core parks in ST_HOLD on this signal and
// the fault_detector treats it as SEVERE (immediate recovery).
//
// err_class encoding: 00 none, 01 datapath, 10 control, 11 liveness.
// ============================================================================
module reliability_monitor #(
    parameter int ACC_W  = 32,
    parameter int DATA_W = 8,
    parameter int VEC_LEN = 8,
    parameter int WD_CYC = 256
)(
    input  logic                     clk,
    input  logic                     rst_n,
    // datapath taps
    input  logic signed [ACC_W-1:0]  acc,
    input  logic                     acc_parity,
    input  logic signed [ACC_W-1:0]  result_val,   // core value at ST_CHECK
    input  logic                     pre_valid,    // ST_CHECK active
    input  logic signed [ACC_W-1:0]  out_val,      // delivered value
    input  logic                     out_valid_i,  // output valid
    // control taps
    input  logic [2:0]               state_o,
    input  logic                     busy,
    input  logic                     progress,
    input  logic                     fine_en,      // fine checks enabled
    // results
    output logic                     err_pulse,
    output logic [1:0]               err_class,
    output logic                     pre_invalid,  // block commit + severe
    output logic                     wd_timeout,
    output logic                     illegal_state
);

    // max legal |sum| = VEC_LEN * (2^(DATA_W-1))^2  (e.g. 8 * 16384 = 131072)
    localparam int MAX_ABS_I = VEC_LEN * (1 << (2 * (DATA_W - 1)));
    localparam logic signed [ACC_W-1:0] MAX_ABS = ACC_W'(MAX_ABS_I);
    localparam logic signed [ACC_W-1:0] MIN_ABS = -ACC_W'(MAX_ABS_I);

    function automatic bit range_bad(input logic signed [ACC_W-1:0] v);
        return (v > MAX_ABS) || (v < MIN_ABS);
    endfunction

    // ---------------------------- check logic ----------------------------
    wire range_pre = pre_valid && range_bad(result_val);
    wire range_out = out_valid_i && range_bad(out_val);
    wire parity_bad = fine_en && ((^acc) != acc_parity);
    wire illegal    = fine_en && (state_o == 3'd7);

    assign illegal_state = illegal;
    assign pre_invalid   = range_pre || (parity_bad && pre_valid);
    assign err_pulse     = range_pre || range_out || parity_bad ||
                           illegal || wd_timeout;

    // error classification (priority: control > liveness > datapath)
    always_comb begin
        if (!err_pulse)           err_class = 2'b00;
        else if (illegal)         err_class = 2'b10;
        else if (wd_timeout)      err_class = 2'b11;
        else                      err_class = 2'b01;
    end

    // ---------------------------- watchdog --------------------------------
    // Counts cycles busy with no progress; emits exactly one pulse per stall.
    localparam int WW = $clog2(WD_CYC + 2);
    logic [WW-1:0] wd_cnt;

    wire wd_hit = fine_en && busy && !progress && (wd_cnt == WW'(WD_CYC));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wd_cnt     <= '0;
            wd_timeout <= 1'b0;
        end else begin
            wd_timeout <= wd_hit;               // registered 1-cycle pulse
            if (!busy || progress || !fine_en)  wd_cnt <= '0;
            else if (wd_cnt <= WW'(WD_CYC))     wd_cnt <= wd_cnt + 1'b1;
        end
    end

endmodule
