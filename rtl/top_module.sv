`timescale 1ns/1ps
// ============================================================================
// top_module.sv — Complete accelerator + reliability subsystem (parameterized)
// ----------------------------------------------------------------------------
// One RTL, four builds (see docs/architecture.md §3):
//   Variant A : MONITOR_EN=0, HAS_DMR=0, HAS_TEMPORAL=0  (bare reference)
//   Variant B : MONITOR_EN=1, HAS_DMR=1, FORCE_PROTECTED=1 (always protected)
//   Variant C1: MONITOR_EN=1, HAS_DMR=1, FORCE_PROTECTED=0 (policy-gated DMR)
//   Variant C2: MONITOR_EN=1, HAS_TEMPORAL=1              (temporal recompute)
//
// With MONITOR_EN=0 the entire reliability subsystem is omitted by generate
// (area of variant A = datapath only). All variants share the datapath RTL.
// ============================================================================
module top_module #(
    parameter int  DATA_W         = 8,
    parameter int  ACC_W          = 32,
    parameter int  VEC_LEN        = 8,
    parameter int  TH_ERR         = 2,
    parameter int  H_CLEAN        = 64,
    parameter int  N_QUIET        = 1024,
    parameter int  TH_SEV         = 4,
    parameter int  REC_MAX        = 3,
    parameter int  WD_CYC         = 256,
    parameter bit  MONITOR_EN     = 1'b1,
    parameter bit  FORCE_PROTECTED= 1'b0,
    parameter bit  HAS_DMR        = 1'b0,
    parameter bit  HAS_TEMPORAL   = 1'b0
)(
    input  logic                     clk,
    input  logic                     rst_n,
    // operand input (respect in_ready backpressure)
    input  logic signed [DATA_W-1:0] in_a,
    input  logic signed [DATA_W-1:0] in_b,
    input  logic                     in_valid,
    output logic                     in_ready,
    // result output
    input  logic                     out_ready,
    output logic signed [ACC_W-1:0]  out_result,
    output logic                     out_valid,
    // status / control
    input  logic                     clear_latched,
    output logic [1:0]               mode,
    output logic [7:0]               err_count,
    output logic                     fault_latched,
    output logic                     protection_active
);

    // ------------------------------ wires ---------------------------------
    logic [2*DATA_W-1:0] ib_wr_data, ib_rd_data;
    logic                ib_full, ib_rd_valid, ib_pop;
    logic                core_in_ready;
    logic signed [ACC_W-1:0] core_result;
    logic                core_res_valid, core_push;
    logic                ob_full, ob_push_ack;

    // core <-> reliability subsystem
    logic                prot_en, pre_invalid;
    logic                replay_active, replay_restart, flush;
    logic                replay_done, verify_ok;
    logic                dmr_mismatch, temporal_mismatch;
    logic [2:0]          core_state;
    logic                core_busy, core_progress;
    logic signed [ACC_W-1:0] acc_tap, result_tap;
    logic                acc_parity_tap, pre_chk_valid;

    // reliability internals
    logic                err_pulse, wd_timeout, illegal_state;
    logic [1:0]          err_class, class_code;
    logic                detected, severe;
    logic                thresh_hit, sev_hit, err_clear;
    logic                monitor_fine, recovery_req, recovery_ok, latch_req;
    logic                commit_block;
    logic [2:0]          attempt_dbg;

    // --------------------------- input buffer ------------------------------
    assign ib_wr_data = {in_a, in_b};
    assign in_ready   = !ib_full;

    input_buffer #(.DATA_W(DATA_W), .DEPTH(16)) u_ibuf (
        .clk(clk), .rst_n(rst_n),
        .wr_data(ib_wr_data), .wr_valid(in_valid && !ib_full), .full(ib_full),
        .rd_data(ib_rd_data), .rd_valid(ib_rd_valid), .rd_pop(ib_pop)
    );

    // --------------------------- core -------------------------------------
    assign ib_pop = core_in_ready && ib_rd_valid;

    accelerator_core #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN),
        .HAS_DMR(HAS_DMR), .HAS_TEMPORAL(HAS_TEMPORAL)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .in_a(ib_rd_data[2*DATA_W-1:DATA_W]),
        .in_b(ib_rd_data[DATA_W-1:0]),
        .in_valid(ib_rd_valid),
        .in_ready(core_in_ready),
        .result(core_result),
        .res_valid(core_res_valid),
        .res_stall(ob_full || commit_block),
        .push_tick(core_push),
        .prot_en(prot_en),
        .replay_active(replay_active),
        .replay_restart(replay_restart),
        .flush(flush),
        .replay_done(replay_done),
        .verify_ok(verify_ok),
        .dmr_mismatch(dmr_mismatch),
        .temporal_mismatch(temporal_mismatch),
        .pre_invalid(pre_invalid),
        .state_o(core_state),
        .busy(core_busy),
        .progress(core_progress),
        .acc_tap(acc_tap),
        .acc_parity_tap(acc_parity_tap),
        .result_tap(result_tap),
        .pre_chk_valid(pre_chk_valid)
    );

    // --------------------------- output buffer -----------------------------
    output_buffer #(.ACC_W(ACC_W), .DEPTH(4)) u_obuf (
        .clk(clk), .rst_n(rst_n),
        .wr_data(core_result),
        .wr_valid(core_res_valid && !commit_block),
        .full(ob_full),
        .push_ack(ob_push_ack),
        .rd_data(out_result),
        .rd_valid(out_valid),
        .rd_pop(out_valid && out_ready)
    );

    // ------------------- reliability subsystem (generate) ------------------
    generate
        if (MONITOR_EN) begin : g_rel
            reliability_monitor #(
                .ACC_W(ACC_W), .DATA_W(DATA_W), .VEC_LEN(VEC_LEN), .WD_CYC(WD_CYC)
            ) u_monitor (
                .clk(clk), .rst_n(rst_n),
                .acc(acc_tap), .acc_parity(acc_parity_tap),
                .result_val(result_tap), .pre_valid(pre_chk_valid),
                .out_val(out_result), .out_valid_i(out_valid),
                .state_o(core_state), .busy(core_busy), .progress(core_progress),
                .fine_en(monitor_fine),
                .err_pulse(err_pulse), .err_class(err_class),
                .pre_invalid(pre_invalid),
                .wd_timeout(wd_timeout), .illegal_state(illegal_state)
            );

            error_counter #(
                .TH_ERR(8'(TH_ERR)), .TH_SEV(8'(TH_SEV))
            ) u_errcnt (
                .clk(clk), .rst_n(rst_n),
                .err_pulse(err_pulse), .clear(err_clear),
                .count(err_count), .thresh_hit(thresh_hit), .sev_hit(sev_hit)
            );

            fault_detector u_fdet (
                .clk(clk), .rst_n(rst_n),
                .err_pulse(err_pulse), .err_class(err_class),
                .dmr_mismatch(dmr_mismatch), .temporal_mismatch(temporal_mismatch),
                .wd_timeout(wd_timeout), .illegal_state(illegal_state),
                .pre_invalid(pre_invalid),
                .detected(detected), .severe(severe), .class_code(class_code)
            );

            adaptive_controller #(
                .H_CLEAN(H_CLEAN), .N_QUIET(N_QUIET),
                .FORCE_PROTECTED(FORCE_PROTECTED), .MONITOR_EN(1'b1)
            ) u_actrl (
                .clk(clk), .rst_n(rst_n),
                .err_pulse(err_pulse), .thresh_hit(thresh_hit),
                .sev_hit(sev_hit), .severe(severe),
                .commit_tick(core_push),
                .recovery_ok(recovery_ok), .latch_req(latch_req),
                .clear_latched(clear_latched),
                .mode(mode), .prot_en(prot_en), .monitor_fine(monitor_fine),
                .recovery_req(recovery_req), .fault_latched(fault_latched),
                .err_clear(err_clear), .flush(flush)
            );

            recovery_controller #(.REC_MAX(REC_MAX)) u_rctrl (
                .clk(clk), .rst_n(rst_n),
                .recovery_req(recovery_req),
                .replay_done(replay_done), .verify_ok(verify_ok),
                .fault_latched(fault_latched),
                .replay_active(replay_active), .replay_restart(replay_restart),
                .recovery_ok(recovery_ok), .latch_req(latch_req),
                .commit_block(commit_block), .attempt(attempt_dbg)
            );
        end else begin : g_no_rel
            // Variant A: no reliability hardware at all — constant ties.
            assign mode             = 2'd0;
            assign err_count        = 8'd0;
            assign fault_latched    = 1'b0;
            assign prot_en          = 1'b0;
            assign pre_invalid      = 1'b0;
            assign replay_active    = 1'b0;
            assign replay_restart   = 1'b0;
            assign flush            = 1'b0;
            assign commit_block     = 1'b0;
            assign recovery_ok      = 1'b0;
            assign latch_req        = 1'b0;
            assign err_clear        = 1'b0;
            assign monitor_fine     = 1'b0;
            assign recovery_req     = 1'b0;
            assign thresh_hit       = 1'b0;
            assign sev_hit          = 1'b0;
            assign err_pulse        = 1'b0;
            assign detected         = 1'b0;
            assign severe           = 1'b0;
            assign class_code       = 2'b00;
            assign wd_timeout       = 1'b0;
            assign illegal_state    = 1'b0;
            assign err_class        = 2'b00;
        end
    endgenerate

    assign protection_active = (mode == 2'd2) || (mode == 2'd3);

endmodule
