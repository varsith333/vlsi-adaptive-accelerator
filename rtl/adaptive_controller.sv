`timescale 1ns/1ps
// ============================================================================
// adaptive_controller.sv — Protection-level policy FSM (the "brain")
// ----------------------------------------------------------------------------
// Modes: 00 NORMAL | 01 MONITORED | 10 PROTECTED | 11 RECOVERY
//
// Transitions (requirements spec §3.2, with unified escalation rule D-7:
// SEVERE implies RECOVERY from ANY active mode):
//   T-1  reset              -> MONITORED (PROTECTED when FORCE_PROTECTED)
//   T-2  NORMAL  + err_pulse             -> MONITORED   (coarse error seen)
//   T-3  MONITORED + thresh_hit          -> PROTECTED   (count >= TH_ERR)
//   T-4  MONITORED + (severe|sev_hit)    -> RECOVERY
//   T-5  PROTECTED + (severe|sev_hit)    -> RECOVERY    (mismatch/watchdog/...)
//   T-6  PROTECTED + clean_cnt >= H_CLEAN-> MONITORED   (hysteresis window)
//   T-7  MONITORED + clean_cnt >= N_QUIET-> NORMAL      (quiet window)
//   T-8  RECOVERY + recovery_ok          -> MONITORED   (or PROTECTED if forced)
//   T-9  RECOVERY + latch_req            -> hold with fault_latched=1 until
//        clear_latched                   -> MONITORED (or PROTECTED if forced)
//
// Hysteresis: clean_cnt resets on every mode change and on every err_pulse,
// so de-escalation always requires H_CLEAN/N_QUIET consecutive clean commits.
// err_clear pulses on entering PROTECTED (design decision D-4: gives
// de-escalation condition a fresh window) and on successful recovery.
// ============================================================================
module adaptive_controller #(
    parameter int  H_CLEAN        = 64,
    parameter int  N_QUIET        = 1024,
    parameter bit  FORCE_PROTECTED= 1'b0,
    parameter bit  MONITOR_EN     = 1'b1
)(
    input  logic       clk,
    input  logic       rst_n,
    // event inputs
    input  logic       err_pulse,
    input  logic       thresh_hit,
    input  logic       sev_hit,
    input  logic       severe,
    input  logic       commit_tick,     // result committed (clean window ticks)
    input  logic       recovery_ok,
    input  logic       latch_req,
    input  logic       clear_latched,
    // policy outputs
    output logic [1:0] mode,
    output logic       prot_en,         // layer-2 active
    output logic       monitor_fine,    // fine checks enabled
    output logic       recovery_req,
    output logic       fault_latched,
    output logic       err_clear,       // 1-cycle: zero the error counter
    output logic       flush            // 1-cycle: abort poisoned transaction
);

    localparam logic [1:0] M_N = 2'd0, M_M = 2'd1, M_P = 2'd2, M_R = 2'd3;
    localparam int CCW = $clog2((H_CLEAN > N_QUIET ? H_CLEAN : N_QUIET) + 1);

    logic [CCW-1:0] clean_cnt;
    logic [1:0]     mode_nxt;

    // ------------------------- next-state logic --------------------------
    always_comb begin
        mode_nxt = mode;
        if (FORCE_PROTECTED) begin
            // forced policy: live in PROTECTED; only RECOVERY is allowed off it
            if (mode == M_R) begin
                if (fault_latched && !clear_latched) mode_nxt = M_R;
                else if (recovery_ok || clear_latched) mode_nxt = M_P;
                else                                  mode_nxt = M_R;
            end else begin
                mode_nxt = severe ? M_R : M_P;
            end
        end else begin
            case (mode)
                M_N: begin
                    if (severe)                    mode_nxt = M_R;  // T-2b
                    else if (err_pulse)            mode_nxt = M_M;  // T-2
                end
                M_M: begin
                    if (severe || sev_hit)         mode_nxt = M_R;  // T-4
                    else if (thresh_hit)           mode_nxt = M_P;  // T-3
                    else if (clean_cnt >= CCW'(N_QUIET)) mode_nxt = M_N; // T-7
                end
                M_P: begin
                    if (severe || sev_hit)         mode_nxt = M_R;  // T-5
                    else if (clean_cnt >= CCW'(H_CLEAN)) mode_nxt = M_M; // T-6
                end
                M_R: begin
                    if (fault_latched && !clear_latched) mode_nxt = M_R; // T-9 hold
                    else if (recovery_ok || clear_latched) mode_nxt = M_M; // T-8
                end
                default: mode_nxt = M_M;
            endcase
        end
    end

    // --------------------------- state update ----------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode         <= FORCE_PROTECTED ? M_P : M_M;   // T-1 (boot=MONITORED)
            clean_cnt    <= '0;
            fault_latched<= 1'b0;
            err_clear    <= 1'b0;
        end else begin
            mode      <= mode_nxt;
            err_clear <= ((mode_nxt != mode) && (mode_nxt == M_P)) ||
                         ((mode == M_R) && recovery_ok);

            // hysteresis window counter
            if (mode_nxt != mode)      clean_cnt <= '0;
            else if (err_pulse)        clean_cnt <= '0;
            else if (commit_tick && (clean_cnt != '1)) clean_cnt <= clean_cnt + 1'b1;

            // sticky fault latch (T-9): set wins over clear in same cycle
            if (latch_req)             fault_latched <= 1'b1;
            else if (clear_latched)    fault_latched <= 1'b0;
        end
    end

    // --------------------------- outputs ---------------------------------
    assign prot_en      = (mode == M_P);
    assign monitor_fine = MONITOR_EN && (mode != M_N);
    // recovery_req must drop in the SAME cycle recovery_ok pulses: the mode
    // register only changes on the next edge, and without this gating the
    // recovery controller would spuriously re-enter R_REPLAY for one more
    // replay (race found by tb_adaptive_controller).
    assign recovery_req = (mode == M_R) && !fault_latched && !recovery_ok;
    assign flush        = clear_latched && fault_latched;

endmodule
