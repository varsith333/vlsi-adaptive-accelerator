`timescale 1ns/1ps
// ============================================================================
// accelerator_core.sv — Dot-product engine with protection hooks
// ----------------------------------------------------------------------------
// Streams VEC_LEN INT8 operand pairs, accumulates them (lane A), pushes one
// result per vector. Protection features are compile-time selected:
//
//   HAS_DMR      : lane B mirrors lane A while protection is active (spatial
//                  redundancy). Compared at ST_CHECK -> dmr_mismatch pulse.
//                  During ST_REPLAY lane B recomputes from the checkpoint and
//                  is compared against lane A (recovery verification).
//   HAS_TEMPORAL : at ST_CHECK while protection active, the vector is
//                  RECOMPUTED from the operand checkpoint (shadow pass) and
//                  compared -> temporal_mismatch pulse. Costs extra cycles,
//                  no second multiplier.
//   checkpoint   : vec_a/vec_b store the operands of the vector in flight;
//                  source for the shadow pass AND recovery replay.
//   (Variant A has neither -> plain accumulator; checkpoint is pruned by
//    constant parameters during synthesis.)
//
// Recovery protocol:
//   ST_CHECK detects pre_invalid (monitor) or a mismatch -> ST_HOLD (result
//   NOT committed). The recovery controller asserts replay_active; the core
//   recomputes from the checkpoint (ST_REPLAY: DMR = both lanes, temporal =
//   two sequential passes), pulses replay_done with verify_ok, and only then
//   enters ST_WAIT_OUT. Commit is further gated by commit_block (held by the
//   recovery controller until recovery_ok). If verification fails REC_MAX
//   times the controller latches a fault; flush then aborts the transaction.
//
// FSM: 3-bit logic (NOT an enum) so simulation-only fault injection can
// deposit arbitrary codes without type conflicts. Legal codes 0..6; code 7 is
// "illegal" (checked by the reliability monitor). The default branch returns
// safely to ST_IDLE if the state register is ever corrupted.
// ============================================================================
module accelerator_core #(
    parameter int DATA_W       = 8,
    parameter int ACC_W        = 32,
    parameter int VEC_LEN      = 8,
    parameter bit HAS_DMR      = 1'b0,
    parameter bit HAS_TEMPORAL = 1'b0
)(
    input  logic                     clk,
    input  logic                     rst_n,
    // operand stream (from input_buffer)
    input  logic signed [DATA_W-1:0] in_a,
    input  logic signed [DATA_W-1:0] in_b,
    input  logic                     in_valid,     // buffer rd_valid
    output logic                     in_ready,     // core consumes this cycle
    // result side (to output_buffer)
    output logic signed [ACC_W-1:0]  result,
    output logic                     res_valid,    // wants to push
    input  logic                     res_stall,    // obuf full || commit_block
    output logic                     push_tick,    // push accepted this cycle
    // protection / recovery control
    input  logic                     prot_en,          // layer-2 active (mode)
    input  logic                     replay_active,    // recovery: recompute
    input  logic                     replay_restart,   // recovery: retry
    input  logic                     flush,            // abort transaction
    output logic                     replay_done,      // 1-cycle pulse
    output logic                     verify_ok,        // valid with replay_done
    output logic                     dmr_mismatch,     // 1-cycle pulse
    output logic                     temporal_mismatch,// 1-cycle pulse
    input  logic                     pre_invalid,      // monitor: value bad
    // monitoring taps
    output logic [2:0]               state_o,
    output logic                     busy,
    output logic                     progress,
    output logic signed [ACC_W-1:0]  acc_tap,
    output logic                     acc_parity_tap,
    output logic signed [ACC_W-1:0]  result_tap,       // value at ST_CHECK
    output logic                     pre_chk_valid     // = ST_CHECK active
);

    localparam bit HAS_CKPT = HAS_DMR | HAS_TEMPORAL;
    localparam int CW       = $clog2(VEC_LEN + 1);
    localparam int IW       = (VEC_LEN <= 1) ? 1 : $clog2(VEC_LEN);

    // ---- FSM states ----
    localparam logic [2:0] ST_IDLE     = 3'd0,
                           ST_RUN      = 3'd1,
                           ST_SHADOW   = 3'd2,
                           ST_CHECK    = 3'd3,
                           ST_WAIT_OUT = 3'd4,
                           ST_HOLD     = 3'd5,
                           ST_REPLAY   = 3'd6;   // 3'd7 = illegal

    logic [2:0] state, state_d;   // state_d: previous copy (for progress)

    // ---- transaction bookkeeping ----
    logic [CW-1:0] cnt;           // operands accepted for current vector
    logic [CW-1:0] idx;           // shadow/replay iteration index
    logic [1:0]    ph;            // temporal replay phase (0 = pass1, 1 = pass2)
    logic          prot_active;   // prot_en latched at vector start
    logic          shadow_done;   // shadow pass finished -> evaluate tm

    // ---- operand checkpoint (exists only when a protection mode uses it) ----
    logic signed [DATA_W-1:0] vec_a [0:VEC_LEN-1];
    logic signed [DATA_W-1:0] vec_b [0:VEC_LEN-1];

    // ---- lanes ----
    logic signed [ACC_W-1:0] acc_a, acc_b;
    logic                    par_a, par_b;
    logic signed [ACC_W-1:0] acc_saved;   // shadow / pass-1 reference value

    // ------------------------- operand handshake --------------------------
    assign in_ready = (state == ST_RUN);
    wire accept = in_valid && in_ready;
    wire last_op = (cnt == CW'(VEC_LEN - 1));
    // protection decision: live prot_en on the FIRST beat of a vector,
    // the latched value afterwards (mode changes mid-vector are ignored)
    wire prot_now = (cnt == '0) ? prot_en : prot_active;

    wire ckpt_mode = (state == ST_SHADOW) || (state == ST_REPLAY);

    // ---- lane A feed: external stream OR checkpoint (shadow/replay) ----
    wire [IW-1:0] ck_idx = idx[IW-1:0];
    wire laneA_v = ckpt_mode ? (idx < CW'(VEC_LEN)) : accept;
    wire laneA_c = ckpt_mode ? ((idx < CW'(VEC_LEN)) && (idx == '0))
                             : (accept && (cnt == '0));
    wire signed [DATA_W-1:0] laneA_a = ckpt_mode ? vec_a[ck_idx] : in_a;
    wire signed [DATA_W-1:0] laneA_b = ckpt_mode ? vec_b[ck_idx] : in_b;

    // ---- lane B feed: DMR mirror of the STREAM (RUN) or checkpoint (REPLAY) ----
    wire laneB_v = (state == ST_REPLAY) ? (HAS_DMR && (idx < CW'(VEC_LEN)))
                                        : (HAS_DMR && accept && prot_now);
    wire laneB_c = (state == ST_REPLAY) ? (HAS_DMR && (idx < CW'(VEC_LEN)) && (idx == '0))
                                        : (HAS_DMR && accept && prot_now && (cnt == '0));
    wire signed [DATA_W-1:0] laneB_a = (state == ST_REPLAY) ? vec_a[ck_idx] : in_a;
    wire signed [DATA_W-1:0] laneB_b = (state == ST_REPLAY) ? vec_b[ck_idx] : in_b;

    mac_unit #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_lane_a (
        .clk(clk), .rst_n(rst_n),
        .in_valid(laneA_v), .acc_clear(laneA_c),
        .a(laneA_a), .b(laneA_b),
        .acc(acc_a), .acc_parity(par_a)
    );

    generate
        if (HAS_DMR) begin : g_lane_b
            mac_unit #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_lane_b (
                .clk(clk), .rst_n(rst_n),
                .in_valid(laneB_v), .acc_clear(laneB_c),
                .a(laneB_a), .b(laneB_b),
                .acc(acc_b), .acc_parity(par_b)
            );
        end else begin : g_no_lane_b
            assign acc_b = '0;
            assign par_b = 1'b0;
        end
    endgenerate

    // ------------------------- mismatch evaluation (at ST_CHECK) ---------
    wire dm_eval = (state == ST_CHECK) && (HAS_DMR != 1'b0) && prot_active && (acc_a != acc_b);
    wire tm_eval = (state == ST_CHECK) && (HAS_TEMPORAL != 1'b0) && shadow_done && (acc_a != acc_saved);

    // ----------------------------- outputs --------------------------------
    assign state_o       = state;
    assign busy          = (state != ST_IDLE);
    assign push_tick     = (state == ST_WAIT_OUT) && !res_stall;
    assign res_valid     = (state == ST_WAIT_OUT);
    assign result        = acc_a;
    assign result_tap    = acc_a;
    assign pre_chk_valid = (state == ST_CHECK);
    assign acc_tap       = acc_a;
    assign acc_parity_tap= par_a;
    assign progress      = accept || push_tick || (state != state_d) ||
                           (state == ST_SHADOW) || (state == ST_REPLAY);

    // ----------------------------- FSM ------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            state_d           <= ST_IDLE;
            cnt               <= '0;
            idx               <= '0;
            ph                <= '0;
            prot_active       <= 1'b0;
            shadow_done       <= 1'b0;
            acc_saved         <= '0;
            dmr_mismatch      <= 1'b0;
            temporal_mismatch <= 1'b0;
            replay_done       <= 1'b0;
            verify_ok         <= 1'b0;
        end else begin
            state_d           <= state;
            dmr_mismatch      <= 1'b0;   // default: deassert 1-cycle pulses
            temporal_mismatch <= 1'b0;
            replay_done       <= 1'b0;

            case (state)
                ST_IDLE: begin
                    cnt   <= '0;
                    state <= ST_RUN;              // 1-cycle bubble, then run
                end

                ST_RUN: begin
                    if (accept) begin
                        if (HAS_CKPT) begin
                            vec_a[cnt[IW-1:0]] <= in_a;
                            vec_b[cnt[IW-1:0]] <= in_b;
                        end
                        if (cnt == '0) prot_active <= prot_en;
                        if (last_op) begin
                            cnt         <= '0;
                            idx         <= '0;
                            shadow_done <= 1'b0;
                            if (HAS_TEMPORAL && prot_now) state <= ST_SHADOW;
                            else                          state <= ST_CHECK;
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end
                end

                ST_SHADOW: begin
                    // first SHADOW cycle also captures the original sum
                    if (idx == '0) acc_saved <= acc_a;
                    if (idx < CW'(VEC_LEN - 1)) begin
                        idx <= idx + 1'b1;
                    end else begin
                        idx         <= '0;
                        shadow_done <= 1'b1;
                        state       <= ST_CHECK;
                    end
                end

                ST_CHECK: begin
                    shadow_done <= 1'b0;
                    if (pre_invalid) begin
                        state <= ST_HOLD;         // monitor invalidated value
                    end else if (dm_eval) begin
                        dmr_mismatch <= 1'b1;
                        state        <= ST_HOLD;
                    end else if (tm_eval) begin
                        temporal_mismatch <= 1'b1;
                        state             <= ST_HOLD;
                    end else begin
                        state <= ST_WAIT_OUT;
                    end
                end

                ST_WAIT_OUT: begin
                    if (flush) begin
                        state <= ST_IDLE;         // poisoned txn aborted
                    end else if (!res_stall) begin
                        state <= ST_IDLE;         // push_tick this edge
                    end
                end

                ST_HOLD: begin
                    if (flush) begin
                        state <= ST_IDLE;
                    end else if (replay_active) begin
                        state     <= ST_REPLAY;
                        idx       <= '0;
                        ph        <= '0;
                    end
                end

                ST_REPLAY: begin
                    if (flush) begin
                        state <= ST_IDLE;
                    end else if (replay_restart) begin
                        idx <= '0;
                        ph  <= '0;
                    end else if (idx < CW'(VEC_LEN)) begin
                        idx <= idx + 1'b1;        // feeds issued comb this cycle
                    end else begin
                        // a full pass just finished; acc is stable now
                        if (!HAS_DMR && (ph == 2'd0)) begin
                            acc_saved <= acc_a;   // temporal: keep pass-1 result
                            ph        <= 2'd1;
                            idx       <= '0;      // run pass 2
                        end else begin
                            // verification point (both modes)
                            if (HAS_DMR ? (acc_a == acc_b) : (acc_a == acc_saved)) begin
                                verify_ok   <= 1'b1;
                                replay_done <= 1'b1;
                                state       <= ST_WAIT_OUT;
                            end else begin
                                verify_ok   <= 1'b0;
                                replay_done <= 1'b1;
                                // stay: controller retries (restart) or latches
                            end
                        end
                    end
                end

                default: begin
                    // Illegal state code (7): enter the recovery hold state
                    // instead of dropping to IDLE. Dropping to IDLE orphaned
                    // the recovery handshake (recovery_controller waits for
                    // replay_done while the core had already restarted), which
                    // left commit_block asserted forever. From ST_HOLD the
                    // controller's replay_active is honored and the in-flight
                    // transaction is recomputed from the checkpoint. With no
                    // reliability subsystem (variant A) the core simply waits
                    // in ST_HOLD — A has no recovery by definition.
                    state <= ST_HOLD;
                end
            endcase
        end
    end

endmodule
