// ============================================================================
// tb_accelerator_core.sv — Unit/integration test for accelerator_core (V-01)
// ----------------------------------------------------------------------------
// Two harnesses (identical operand stream, fixed seed):
//   h_dmr : HAS_DMR=1      (spatial redundancy)
//   h_tmp : HAS_TEMPORAL=1 (shadow recompute redundancy)
// Each harness contains: operand driver + golden model + result checker +
// a minimal recovery-controller emulation (replay_active/restart handshake).
//
// Scenarios (30 vectors each):
//   vec  0..9  : clean, protection ON     -> all results correct, no mismatch
//   vec 10     : lane-A accumulator corrupted during RUN
//                -> mismatch -> HOLD -> replay -> CORRECT committed result
//   vec 11..14 : clean
//   vec 15     : RUN corruption + corruption during the REPLAY pass
//                -> first verification FAILS -> replay_restart -> retry OK
//   vec 16..19 : clean
//   vec 20..23 : protection OFF (prot_en=0) -> results correct, NO mismatch
//   vec 24     : pre_invalid asserted at ST_CHECK -> HOLD -> replay -> correct
//   vec 25..29 : clean
// ============================================================================
`timescale 1ns/1ps
module tb_accelerator_core;

    localparam int DATA_W  = 8;
    localparam int ACC_W   = 32;
    localparam int VEC_LEN = 8;
    localparam int N_VEC   = 30;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    int errors = 0;

    // ============================ harness ==================================
    module core_harness #(
        parameter bit HAS_DMR      = 1'b0,
        parameter bit HAS_TEMPORAL = 1'b0,
        parameter int SEED         = 1
    )(
        input  logic clk,
        input  logic rst_n,
        input  logic prot_en,
        input  logic inj_run_en,     // corrupt lane A during RUN (one vector)
        input  logic inj_replay_en,  // corrupt lane A during REPLAY
        input  logic force_pre_inv,  // assert pre_invalid at ST_CHECK
        output int   checked,
        output int   mismatch_cnt,
        output int   herrors,
        output int   vec_no_o,
        output int   op_idx_o
    );
        // ---------------- operand driver + golden model -------------------
        logic signed [DATA_W-1:0] drv_a, drv_b;
        logic                     drv_valid;
        int                       op_idx;      // index of NEXT operand
        int                       vec_no;      // vectors fully streamed
        int                       seed_r;
        logic signed [ACC_W-1:0]  mdl, pending, pm;

        logic in_ready, push_tick, dmr_mm, tm_mm, pre_chk, replay_done, verify_ok;
        logic signed [ACC_W-1:0] result;
        logic [2:0] state_c;
        logic replay_active, replay_restart, res_stall;

        assign drv_valid = 1'b1;
        assign vec_no_o  = vec_no;
        assign op_idx_o  = op_idx;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                seed_r  <= SEED;
                op_idx  <= 0;
                vec_no  <= 0;
                mdl     <= '0;
                pending <= '0;
                drv_a   <= '0;
                drv_b   <= '0;
            end else if (in_ready && drv_valid) begin
                pm = (op_idx == 0) ? ACC_W'(drv_a) * ACC_W'(drv_b)
                                   : mdl + ACC_W'(drv_a) * ACC_W'(drv_b);
                mdl <= pm;
                if (op_idx == VEC_LEN - 1) begin
                    pending <= pm;
                    op_idx  <= 0;
                    vec_no  <= vec_no + 1;
                end else begin
                    op_idx <= op_idx + 1;
                end
                drv_a <= $random(seed_r);
                drv_b <= $random(seed_r);
            end
        end

        // ------------------------- DUT + env -------------------------------
        logic pre_invalid_w;
        assign pre_invalid_w = force_pre_inv && pre_chk;

        accelerator_core #(
            .DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN),
            .HAS_DMR(HAS_DMR), .HAS_TEMPORAL(HAS_TEMPORAL)
        ) u_core (
            .clk(clk), .rst_n(rst_n),
            .in_a(drv_a), .in_b(drv_b),
            .in_valid(drv_valid), .in_ready(in_ready),
            .result(result),
            .res_valid(), .res_stall(res_stall), .push_tick(push_tick),
            .prot_en(prot_en),
            .replay_active(replay_active), .replay_restart(replay_restart),
            .flush(1'b0),
            .replay_done(replay_done), .verify_ok(verify_ok),
            .dmr_mismatch(dmr_mm), .temporal_mismatch(tm_mm),
            .pre_invalid(pre_invalid_w),
            .state_o(state_c), .busy(), .progress(),
            .acc_tap(), .acc_parity_tap(), .result_tap(),
            .pre_chk_valid(pre_chk)
        );

        // recovery emulation: start replay on trigger, follow verify verdicts
        typedef enum logic [1:0] {E_IDLE, E_REPLAYING} estate_e;
        estate_e est;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                est            <= E_IDLE;
                replay_active  <= 1'b0;
                replay_restart <= 1'b0;
                res_stall      <= 1'b0;
            end else begin
                replay_restart <= 1'b0;
                case (est)
                    E_IDLE: begin
                        if (dmr_mm || tm_mm || pre_invalid_w) begin
                            est           <= E_REPLAYING;
                            replay_active <= 1'b1;
                            res_stall     <= 1'b1;
                        end
                    end
                    E_REPLAYING: begin
                        if (replay_done) begin
                            if (verify_ok) begin
                                replay_active <= 1'b0;
                                res_stall     <= 1'b0;
                                est           <= E_IDLE;
                            end else begin
                                replay_restart <= 1'b1;   // retry
                            end
                        end
                    end
                    default: est <= E_IDLE;
                endcase
            end
        end

        // ---------------------------- checker ------------------------------
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                checked <= 0; mismatch_cnt <= 0; herrors <= 0;
            end else begin
                if (dmr_mm || tm_mm) mismatch_cnt <= mismatch_cnt + 1;
                if (push_tick) begin
                    if (result !== pending) begin
                        herrors++;
                        $display("FAIL @%0t: harness(DMR=%0d) vec %0d result=%0d expected=%0d",
                                 $time, HAS_DMR, vec_no, result, pending);
                    end
                    checked <= checked + 1;
                end
            end
        end

        // ------------------------- injections ------------------------------
        logic fired_run = 0, fired_rep = 0;

        always @(negedge clk) begin
            if (!inj_run_en)     fired_run <= 1'b0;
            if (!inj_replay_en)  fired_rep <= 1'b0;

            // corrupt lane A accumulator mid-vector (RUN)
            if (inj_run_en && !fired_run &&
                (state_c == 3'd1) && (op_idx == 3)) begin
                u_core.u_lane_a.acc = u_core.u_lane_a.acc ^ 32'h0000_2000;
                fired_run <= 1'b1;
                $display("  [%0t] DMR=%0d: lane-A corruption injected (vec %0d)",
                         $time, HAS_DMR, vec_no);
            end
            // corrupt lane A mid-replay (forces a verification failure)
            if (inj_replay_en && !fired_rep && (state_c == 3'd6) &&
                (u_core.idx == 3)) begin
                u_core.u_lane_a.acc = u_core.u_lane_a.acc ^ 32'h0000_1000;
                fired_rep <= 1'b1;
                $display("  [%0t] DMR=%0d: replay-pass corruption injected (vec %0d)",
                         $time, HAS_DMR, vec_no);
            end
        end

    endmodule

    // --------------------------- instances ---------------------------------
    logic prot_d = 1, prot_t = 1;
    logic inj_run_d, inj_rep_d, pre_d;
    logic inj_run_t, inj_rep_t, pre_t;
    int  chk_d, mm_d, err_d, vno_d, oix_d;
    int  chk_t, mm_t, err_t, vno_t, oix_t;

    core_harness #(.HAS_DMR(1'b1), .HAS_TEMPORAL(1'b0), .SEED(32'h1234_5678)) h_dmr (
        .clk(clk), .rst_n(rst_n), .prot_en(prot_d),
        .inj_run_en(inj_run_d), .inj_replay_en(inj_rep_d), .force_pre_inv(pre_d),
        .checked(chk_d), .mismatch_cnt(mm_d), .herrors(err_d),
        .vec_no_o(vno_d), .op_idx_o(oix_d)
    );

    core_harness #(.HAS_DMR(1'b0), .HAS_TEMPORAL(1'b1), .SEED(32'h1234_5678)) h_tmp (
        .clk(clk), .rst_n(rst_n), .prot_en(prot_t),
        .inj_run_en(inj_run_t), .inj_replay_en(inj_rep_t), .force_pre_inv(pre_t),
        .checked(chk_t), .mismatch_cnt(mm_t), .herrors(err_t),
        .vec_no_o(vno_t), .op_idx_o(oix_t)
    );

    // ------------------------- per-harness sequence ------------------------
    initial begin : dmr_seq
        inj_run_d = 0; inj_rep_d = 0; pre_d = 0;
        wait (rst_n === 1'b1);
        // vec 10: RUN corruption
        wait (vno_d == 10 && oix_d == 0); inj_run_d = 1;
        wait (vno_d == 12);               inj_run_d = 0;
        // vec 15: RUN + REPLAY corruption (verification failure + retry)
        wait (vno_d == 15 && oix_d == 0); inj_run_d = 1; inj_rep_d = 1;
        wait (vno_d == 17);               inj_run_d = 0; inj_rep_d = 0;
        // vec 20..23: protection OFF
        wait (vno_d == 20 && oix_d == 0); prot_d = 0;
        wait (vno_d == 24 && oix_d == 0); prot_d = 1;
        // vec 24: pre_invalid at ST_CHECK
        pre_d = 1;
        wait (vno_d == 25 && oix_d == 0); pre_d = 0;
    end

    initial begin : tmp_seq
        inj_run_t = 0; inj_rep_t = 0; pre_t = 0;
        wait (rst_n === 1'b1);
        wait (vno_t == 10 && oix_t == 0); inj_run_t = 1;
        wait (vno_t == 12);               inj_run_t = 0;
        wait (vno_t == 15 && oix_t == 0); inj_run_t = 1; inj_rep_t = 1;
        wait (vno_t == 17);               inj_run_t = 0; inj_rep_t = 0;
        wait (vno_t == 20 && oix_t == 0); prot_t = 0;
        wait (vno_t == 24 && oix_t == 0); prot_t = 1;
        pre_t = 1;
        wait (vno_t == 25 && oix_t == 0); pre_t = 0;
    end

    // ----------------------------- summary ---------------------------------
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;

        wait (chk_d >= N_VEC && chk_t >= N_VEC);
        repeat (5) @(posedge clk);

        errors = err_d + err_t;
        if (mm_d != 2) begin errors++; $display("FAIL: DMR harness mismatch_cnt=%0d expected 2", mm_d); end
        if (mm_t != 2) begin errors++; $display("FAIL: temporal harness mismatch_cnt=%0d expected 2", mm_t); end

        if (errors == 0)
            $display("TB_ACCELERATOR_CORE: PASS (dmr: %0d vec/%0d mm, tmp: %0d vec/%0d mm)",
                     chk_d, mm_d, chk_t, mm_t);
        else
            $display("TB_ACCELERATOR_CORE: FAIL (%0d errors)", errors);
        $finish;
    end

    // global timeout guard
    initial begin
        #2_000_000;
        $display("TB_ACCELERATOR_CORE: FAIL (timeout) dmr_vec=%0d tmp_vec=%0d dmr_chk=%0d tmp_chk=%0d",
                 vno_d, vno_t, chk_d, chk_t);
        $finish;
    end

endmodule
