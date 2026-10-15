// ============================================================================
// tb_top_module.sv — System-level golden test for all four variants (V-06/V-08)
// ----------------------------------------------------------------------------
// Four variant harnesses receive IDENTICAL operand streams (same seed) with
// independent drivers (variants stall differently). Each harness has a golden
// model + result checker.
//
// IMPORTANT structural fact: top_module has a 16-deep input buffer between
// in_ready and the core, so the driver runs up to 2 vectors AHEAD of the core.
// Therefore the golden model uses an expected-value FIFO (pushed at last-operand
// accept, popped at delivery) and fault injections are anchored to the CORE's
// operand counter (u_top.u_core.cnt), not the driver's position.
//
// Phase 1 (vec 0..1099, clean):
//   - all four variants bit-exact correct (V-08: no-fault behavior identical)
//   - zero false positives: err_count stays 0, fault_latched stays 0
//   - boot modes: A=00(NORMAL) B=10(PROTECTED) C1/C2=01(MONITORED)  [T-1]
//   - C1/C2 reach NORMAL after N_QUIET=1024 clean commits           [T-7]
//   - protection-active cycles sampled every clock                   [MT-02]
//   - latency (first operand accepted -> result delivered), bucketed by
//     protection state at vector start                               [MT-06]
//
// Phase 2 (controlled faults; armed by driver position, FIRED when the core
// reaches operand cnt==3 of any RUN vector, disarmed on the fired event):
//   - C1/C2 injection 1: gross accumulator corruption while in NORMAL
//     -> range check at ST_CHECK -> SEVERE -> RECOVERY -> checkpoint replay
//     -> CORRECT result committed (golden checking continues) -> MONITORED
//     [T-2b/T-8, in-system recovery validation]
//   - C1/C2 injection 2/3: parity-metadata flip (fine check, non-severe)
//     -> err_count 1 -> 2 = TH_ERR -> PROTECTED [T-3]; detection latency
//     deposit->count must be <= 2 cycles [V-04]; counter cleared on entry [D-4]
//   - then 64 clean commits -> back to MONITORED [T-6]
//   - B injection 1/2: parity flips (fine checks always on under forced
//     policy) -> err_count must end at exactly 2, mode stays PROTECTED
//   - A: no reliability hardware; receives no injections here (its blindness
//     is quantified by the fault-injection campaign)
// ============================================================================
`timescale 1ns/1ps
module tb_top_module;

    localparam int DATA_W  = 8;
    localparam int ACC_W   = 32;
    localparam int VEC_LEN = 8;
    localparam int N_VEC   = 1200;
    localparam int INJ1    = 1100;   // arm gross-injection window here
    localparam int INJ2    = 1103;   // arm parity injection 2 here
    localparam int INJ3    = 1106;   // arm parity injection 3 here

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // Injection block: instantiated INSIDE each generate branch so that the
    // hierarchical deposit path (u_v.u_top...) is statically visible. The
    // deposit anchors on the CORE's operand count (cnt==3 of a RUN vector):
    // operands 3..7 then fold the corruption into the sum (or the parity bit
    // re-syncs at the next accept, giving exactly one error count).
    `define INJECT_BLOCK                                                        \
        always @(negedge clk) begin                                             \
            if (!inj_en) fired <= 1'b0;                                         \
            if (inj_en && !fired &&                                             \
                (u_v.u_top.u_core.state == 3'd1) &&                             \
                (u_v.u_top.u_core.cnt == 3)) begin                              \
                if (inj_gross)                                                  \
                    u_v.u_top.u_core.u_lane_a.acc =                             \
                        u_v.u_top.u_core.u_lane_a.acc ^ 32'h4000_0000;          \
                else                                                            \
                    u_v.u_top.u_core.u_lane_a.acc_parity =                      \
                        ~u_v.u_top.u_core.u_lane_a.acc_parity;                  \
                fired     <= 1'b1;                                              \
                inj_watch <= 1'b1;                                              \
                cyc_cnt   <= 0;                                                 \
                err_base  <= err_count;                                         \
                $display("  [%0t] variant %0d: %s injected (core cnt==3)",      \
                         $time, VARIANT,                                        \
                         inj_gross ? "GROSS acc corruption" : "parity flip");   \
            end                                                                 \
        end

    // N-07 concurrent assertions (SVA). Installed inside EVERY generate branch
    // so the hierarchical DUT paths are statically visible. A failure does two
    // things: prints $error and increments herrors, which the final PASS/FAIL
    // verdict counts - so an assertion failure can never be missed.
    //   1) FSM never in the reserved/illegal state (this regression never
    //      forces state, so 7 is illegal here by construction),
    //   2) no result pushed into the output buffer while commit_block is
    //      asserted (the commit gate in top_module; queued PRE-fault results
    //      may still drain - that is covered by the golden FIFO scoreboard),
    //   3) mode stays in the defined 2-bit range (also catches X),
    //   4) err_count never wraps silently: from 0xFF it may only stay at 0xFF
    //      (saturation, N-07/N-07 spec) or jump to 0 (explicit clear).
    `define SVA_GUARDS                                                          \
        a_fsm_legal: assert property (@(posedge clk) disable iff (!rst_n)       \
            (u_v.u_top.u_core.state != 3'd7))                                    \
            else begin herrors = herrors + 1;                                    \
                $error("N-07: core FSM in illegal state %0d at %0t",             \
                       u_v.u_top.u_core.state, $time); end                       \
        a_no_push_when_blocked: assert property (@(posedge clk)                  \
            disable iff (!rst_n)                                                 \
            (u_v.u_top.commit_block |-> !u_v.u_top.u_obuf.wr_valid))             \
            else begin herrors = herrors + 1;                                    \
                $error("N-07: obuf push while commit_block at %0t", $time); end  \
        a_mode_defined: assert property (@(posedge clk) disable iff (!rst_n)     \
            (mode inside {2'd0, 2'd1, 2'd2, 2'd3}))                              \
            else begin herrors = herrors + 1;                                    \
                $error("N-07: mode out of range or X: %b at %0t", mode,          \
                       $time); end                                               \
        a_errcnt_no_wrap: assert property (@(posedge clk) disable iff (!rst_n)   \
            ((err_count == 8'hFF) |=>                                           \
             ((err_count == 8'hFF) || (err_count == 8'd0))))                     \
            else begin herrors = herrors + 1;                                    \
                $error("N-07: err_count wrapped from 0xFF to %0d at %0t",        \
                       err_count, $time); end

    // ============================ variant harness ==========================
    module variant_harness #(
        parameter int VARIANT = 0   // 0=A 1=B 2=C1 3=C2
    )(
        input  logic clk,
        input  logic rst_n,
        input  logic inj_en,          // arm injection (one deposit)
        input  logic inj_gross,       // 0 = parity flip, 1 = gross acc corrupt
        output int   checked,
        output int   herrors,
        output int   vno_o,           // driver's vector number (runs ahead)
        output int   op_idx_o,
        output logic [1:0]  mode,
        output logic [7:0]  err_count,
        output logic        fault_latched,
        output logic        prot_act,
        output longint lat_n_sum,     // latency sum (cycles), protected OFF
        output int     lat_n_cnt,
        output longint lat_p_sum,     // latency sum (cycles), protected ON
        output int     lat_p_cnt,
        output longint prot_cyc,      // cycles with protection active
        output longint cyc_o,         // total cycles since reset
        output int     detect_lat,    // cycles deposit -> err_count change
        output logic   fired_o        // deposit has happened (evidence)
    );
        // ---------------- operand driver + golden model -------------------
        logic signed [DATA_W-1:0] drv_a, drv_b;
        logic                     drv_valid;
        int                       op_idx, vec_no, seed_r;
        logic signed [ACC_W-1:0]  mdl, pm, exp_v, lat_v;

        logic in_ready, out_valid;
        logic signed [ACC_W-1:0] out_result;

        // expected-value FIFO: pushed at last-operand accept, popped at
        // delivery (the 16-deep input buffer lets several vectors be in
        // flight, so a single pending register is not enough)
        logic signed [ACC_W-1:0] expq[$];
        // latency stamps: first-accept cycle + protection state at that time
        longint tsc[$];
        logic   tsp[$];
        longint mycyc;

        assign drv_valid = 1'b1;
        assign vno_o     = vec_no;
        assign op_idx_o  = op_idx;
        assign cyc_o     = mycyc;

        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                seed_r <= 32'hDEAD_BEEF;   // identical stream for every variant
                op_idx <= 0; vec_no <= 0;  mycyc <= 0;
                mdl <= '0;
                drv_a <= '0; drv_b <= '0;
                checked <= 0; herrors <= 0;
                lat_n_sum <= 0; lat_n_cnt <= 0;
                lat_p_sum <= 0; lat_p_cnt <= 0;
                prot_cyc  <= 0;
                expq.delete(); tsc.delete(); tsp.delete();
            end else begin
                mycyc <= mycyc + 1;
                if (prot_act) prot_cyc <= prot_cyc + 1;

                // ------------- driver + model + latency stamp -------------
                if (in_ready && drv_valid) begin
                    if (op_idx == 0) begin        // first accept of a vector
                        tsc.push_back(mycyc);
                        tsp.push_back(prot_act);
                    end
                    pm = (op_idx == 0) ? ACC_W'(drv_a) * ACC_W'(drv_b)
                                       : mdl + ACC_W'(drv_a) * ACC_W'(drv_b);
                    mdl <= pm;
                    if (op_idx == VEC_LEN - 1) begin
                        expq.push_back(pm);       // vector complete: expect it
                        op_idx <= 0; vec_no <= vec_no + 1;
                    end else begin
                        op_idx <= op_idx + 1;
                    end
                    drv_a <= $random(seed_r);
                    drv_b <= $random(seed_r);
                end

                // ---------------- delivery: golden check ------------------
                if (out_valid) begin
                    if (expq.size() == 0) begin
                        herrors++;
                        $display("FAIL @%0t: variant %0d delivered with empty expect queue",
                                 $time, VARIANT);
                    end else begin
                        exp_v = expq.pop_front();
                        if (out_result !== exp_v) begin
                            herrors++;
                            $display("FAIL @%0t: variant %0d result=%0d expected=%0d",
                                     $time, VARIANT, out_result, exp_v);
                        end
                    end
                    checked <= checked + 1;
                    if (tsc.size() > 0) begin
                        lat_v = mycyc - tsc.pop_front();
                        if (tsp.pop_front()) begin
                            lat_p_sum <= lat_p_sum + lat_v;
                            lat_p_cnt <= lat_p_cnt + 1;
                        end else begin
                            lat_n_sum <= lat_n_sum + lat_v;
                            lat_n_cnt <= lat_n_cnt + 1;
                        end
                    end
                end

                // ------------------- structural sanity -------------------
                if (fault_latched) begin
                    herrors++;
                    $display("FAIL @%0t: variant %0d fault_latched set unexpectedly",
                             $time, VARIANT);
                end
                if ((VARIANT == 0) && (mode !== 2'd0)) begin
                    herrors++; $display("FAIL @%0t: variant A left NORMAL", $time);
                end
                if ((VARIANT == 1) && (mode < 2'd2)) begin
                    herrors++; $display("FAIL @%0t: variant B de-escalated (mode=%0d)",
                                        $time, mode);
                end
            end
        end

        // ---------------------------- DUT ----------------------------------
        generate
            case (VARIANT)
                0: begin : gA
                    top_variant_a #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                       .clk(clk), .rst_n(rst_n),
                       .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                       .in_ready(in_ready), .out_ready(1'b1),
                       .out_result(out_result), .out_valid(out_valid),
                       .clear_latched(1'b0),
                       .mode(mode), .err_count(err_count),
                       .fault_latched(fault_latched),
                       .protection_active(prot_act));
                    `INJECT_BLOCK
                    `SVA_GUARDS
                end
                1: begin : gB
                    top_variant_b #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                       .clk(clk), .rst_n(rst_n),
                       .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                       .in_ready(in_ready), .out_ready(1'b1),
                       .out_result(out_result), .out_valid(out_valid),
                       .clear_latched(1'b0),
                       .mode(mode), .err_count(err_count),
                       .fault_latched(fault_latched),
                       .protection_active(prot_act));
                    `INJECT_BLOCK
                    `SVA_GUARDS
                end
                2: begin : gC1
                    top_variant_c1 #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                       .clk(clk), .rst_n(rst_n),
                       .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                       .in_ready(in_ready), .out_ready(1'b1),
                       .out_result(out_result), .out_valid(out_valid),
                       .clear_latched(1'b0),
                       .mode(mode), .err_count(err_count),
                       .fault_latched(fault_latched),
                       .protection_active(prot_act));
                    `INJECT_BLOCK
                    `SVA_GUARDS
                end
                default: begin : gC2
                    top_variant_c2 #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                       .clk(clk), .rst_n(rst_n),
                       .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                       .in_ready(in_ready), .out_ready(1'b1),
                       .out_result(out_result), .out_valid(out_valid),
                       .clear_latched(1'b0),
                       .mode(mode), .err_count(err_count),
                       .fault_latched(fault_latched),
                       .protection_active(prot_act));
                    `INJECT_BLOCK
                    `SVA_GUARDS
                end
            endcase
        endgenerate

        // ------------- injection watch + detection latency -----------------
        logic fired = 0;
        logic inj_watch = 0;
        logic [7:0] err_base;
        int  cyc_cnt;

        assign detect_lat = inj_watch ? -1 : cyc_cnt;
        assign fired_o    = fired;

        always @(posedge clk) begin
            if (inj_watch) begin
                if (err_count !== err_base) begin
                    inj_watch <= 1'b0;
                    cyc_cnt   <= cyc_cnt + 1;
                end else begin
                    cyc_cnt <= cyc_cnt + 1;
                end
            end
        end

    endmodule

    // --------------------------- instances ---------------------------------
    logic inj_B = 0, inj_C1 = 0, inj_C2 = 0;
    logic gross_C1 = 0, gross_C2 = 0;
    logic fr_A, fr_B, fr_C1, fr_C2;

    int chk_A, err_A, v_A, ix_A, chk_B, err_B, v_B, ix_B;
    int chk_C1, err_C1, v_C1, ix_C1, chk_C2, err_C2, v_C2, ix_C2;
    logic [1:0] m_A, m_B, m_C1, m_C2;
    logic [7:0] e_A, e_B, e_C1, e_C2;
    logic fl_A, fl_B, fl_C1, fl_C2, pa_A, pa_B, pa_C1, pa_C2;
    longint ln_A, lp_A, ln_B, lp_B, ln_C1, lp_C1, ln_C2, lp_C2;
    longint pc_A, pc_B, pc_C1, pc_C2, cy_A, cy_B, cy_C1, cy_C2;
    int lc_A, lpA_c, lc_B, lpB_c, lc_C1, lpC1_c, lc_C2, lpC2_c;
    int dl_C1, dl_C2, dl_B;

    variant_harness #(.VARIANT(0)) h_A (
        .clk(clk), .rst_n(rst_n), .inj_en(1'b0), .inj_gross(1'b0),
        .checked(chk_A), .herrors(err_A), .vno_o(v_A), .op_idx_o(ix_A),
        .mode(m_A), .err_count(e_A), .fault_latched(fl_A), .prot_act(pa_A),
        .lat_n_sum(ln_A), .lat_n_cnt(lc_A), .lat_p_sum(lp_A), .lat_p_cnt(lpA_c),
        .prot_cyc(pc_A), .cyc_o(cy_A), .detect_lat(), .fired_o(fr_A));

    variant_harness #(.VARIANT(1)) h_B (
        .clk(clk), .rst_n(rst_n), .inj_en(inj_B), .inj_gross(1'b0),
        .checked(chk_B), .herrors(err_B), .vno_o(v_B), .op_idx_o(ix_B),
        .mode(m_B), .err_count(e_B), .fault_latched(fl_B), .prot_act(pa_B),
        .lat_n_sum(ln_B), .lat_n_cnt(lc_B), .lat_p_sum(lp_B), .lat_p_cnt(lpB_c),
        .prot_cyc(pc_B), .cyc_o(cy_B), .detect_lat(dl_B), .fired_o(fr_B));

    variant_harness #(.VARIANT(2)) h_C1 (
        .clk(clk), .rst_n(rst_n), .inj_en(inj_C1), .inj_gross(gross_C1),
        .checked(chk_C1), .herrors(err_C1), .vno_o(v_C1), .op_idx_o(ix_C1),
        .mode(m_C1), .err_count(e_C1), .fault_latched(fl_C1), .prot_act(pa_C1),
        .lat_n_sum(ln_C1), .lat_n_cnt(lc_C1), .lat_p_sum(lp_C1), .lat_p_cnt(lpC1_c),
        .prot_cyc(pc_C1), .cyc_o(cy_C1), .detect_lat(dl_C1), .fired_o(fr_C1));

    variant_harness #(.VARIANT(3)) h_C2 (
        .clk(clk), .rst_n(rst_n), .inj_en(inj_C2), .inj_gross(gross_C2),
        .checked(chk_C2), .herrors(err_C2), .vno_o(v_C2), .op_idx_o(ix_C2),
        .mode(m_C2), .err_count(e_C2), .fault_latched(fl_C2), .prot_act(pa_C2),
        .lat_n_sum(ln_C2), .lat_n_cnt(lc_C2), .lat_p_sum(lp_C2), .lat_p_cnt(lpC2_c),
        .prot_cyc(pc_C2), .cyc_o(cy_C2), .detect_lat(dl_C2), .fired_o(fr_C2));

    int errors = 0;

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL @%0t: %s", $time, msg); end
    endtask

    // ---------------------- per-variant sequences --------------------------
    // Arm on driver position, disarm on the FIRED event (deposit happened),
    // then wait for the architectural evidence (mode / err_count change).
    initial begin : seq_c1
        inj_C1 = 0; gross_C1 = 0;
        wait (rst_n === 1'b1); #1;
        chk(m_C1 === 2'd1, "C1 boot mode must be MONITORED");

        // phase 1: reach NORMAL after N_QUIET clean commits (T-7)
        wait (v_C1 == INJ1 && ix_C1 == 0);
        chk(m_C1 === 2'd0, "C1 must be NORMAL after 1024+ clean commits (T-7)");

        // injection 1: GROSS corruption in NORMAL -> recovery in the system
        gross_C1 = 1; inj_C1 = 1;
        wait (fr_C1); inj_C1 = 0; gross_C1 = 0;
        wait (m_C1 === 2'd3);
        $display("  [%0t] C1: entered RECOVERY after gross corruption (T-2b)", $time);
        wait (m_C1 === 2'd1);
        @(posedge clk); #1;
        $display("  [%0t] C1: recovery OK -> MONITORED (T-8)", $time);
        chk(e_C1 == 8'd0, "C1 err_count must be cleared after recovery");

        // injection 2: parity flip (fine check, non-severe) -> count = 1
        inj_C1 = 1;
        wait (fr_C1); inj_C1 = 0;
        wait (e_C1 >= 8'd1);
        @(posedge clk); #1;
        chk(dl_C1 > 0 && dl_C1 <= 2, "C1 parity detection latency must be 1..2 cycles");
        $display("  [%0t] C1: parity detection latency = %0d cycles (V-04 <=2), err=%0d",
                 $time, dl_C1, e_C1);

        // injection 3: count reaches TH_ERR=2 -> PROTECTED (T-3)
        if (m_C1 !== 2'd2) begin
            inj_C1 = 1;
            wait (fr_C1); inj_C1 = 0;
        end
        wait (m_C1 === 2'd2);
        @(posedge clk); #1;
        $display("  [%0t] C1: escalated MONITORED->PROTECTED (T-3)", $time);
        chk(e_C1 == 8'd0, "C1 err_count cleared on entry to PROTECTED (D-4)");

        // 64 clean committed results -> MONITORED (T-6)
        wait (m_C1 === 2'd1);
        $display("  [%0t] C1: de-escalated PROTECTED->MONITORED (T-6)", $time);
    end

    initial begin : seq_c2
        inj_C2 = 0; gross_C2 = 0;
        wait (rst_n === 1'b1); #1;
        chk(m_C2 === 2'd1, "C2 boot mode must be MONITORED");

        wait (v_C2 == INJ1 && ix_C2 == 0);
        chk(m_C2 === 2'd0, "C2 must be NORMAL after 1024+ clean commits (T-7)");

        gross_C2 = 1; inj_C2 = 1;
        wait (fr_C2); inj_C2 = 0; gross_C2 = 0;
        wait (m_C2 === 2'd3);
        $display("  [%0t] C2: entered RECOVERY after gross corruption (T-2b)", $time);
        wait (m_C2 === 2'd1);
        @(posedge clk); #1;
        $display("  [%0t] C2: recovery OK -> MONITORED (T-8)", $time);
        chk(e_C2 == 8'd0, "C2 err_count cleared after recovery");

        inj_C2 = 1;
        wait (fr_C2); inj_C2 = 0;
        wait (e_C2 >= 8'd1);
        @(posedge clk); #1;
        chk(dl_C2 > 0 && dl_C2 <= 2, "C2 parity detection latency must be 1..2 cycles");
        $display("  [%0t] C2: parity detection latency = %0d cycles (V-04 <=2), err=%0d",
                 $time, dl_C2, e_C2);

        if (m_C2 !== 2'd2) begin
            inj_C2 = 1;
            wait (fr_C2); inj_C2 = 0;
        end
        wait (m_C2 === 2'd2);
        @(posedge clk); #1;
        $display("  [%0t] C2: escalated MONITORED->PROTECTED (T-3)", $time);
        chk(e_C2 == 8'd0, "C2 err_count cleared on entry to PROTECTED (D-4)");

        wait (m_C2 === 2'd1);
        $display("  [%0t] C2: de-escalated PROTECTED->MONITORED (T-6)", $time);
    end

    initial begin : seq_b
        inj_B = 0;
        wait (rst_n === 1'b1); #1;
        chk(m_B === 2'd2, "B boot mode must be PROTECTED (forced)");

        wait (v_B == INJ1 && ix_B == 0);
        inj_B = 1;
        wait (fr_B); inj_B = 0;
        wait (e_B >= 8'd1);
        @(posedge clk); #1;
        chk(dl_B > 0 && dl_B <= 2, "B parity detection latency must be 1..2 cycles");
        $display("  [%0t] B: parity detection latency = %0d cycles (V-04 <=2)", $time, dl_B);

        inj_B = 1;
        wait (fr_B); inj_B = 0;
        wait (e_B >= 8'd2);
        @(posedge clk); #1;
        $display("  [%0t] B: two parity faults counted, err_count=%0d, mode stays PROTECTED",
                 $time, e_B);
    end

    // ------------------------------ summary --------------------------------
    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1;
        #1 chk(m_A === 2'd0, "A boot mode must be NORMAL");

        wait (chk_A >= N_VEC && chk_B >= N_VEC && chk_C1 >= N_VEC && chk_C2 >= N_VEC);
        repeat (10) @(posedge clk);

        chk(e_A == 0, "A err_count must stay 0");
        chk(e_B == 8'd2, $sformatf("B final err_count=%0d expected 2", e_B));
        chk(e_C1 == 0 && e_C2 == 0,
            $sformatf("C1/C2 final err_count=%0d/%0d expected 0/0", e_C1, e_C2));
        chk(fl_A == 0 && fl_B == 0 && fl_C1 == 0 && fl_C2 == 0, "fault_latched set");
        chk(m_A == 2'd0, "A must end in NORMAL");
        chk(m_B == 2'd2, "B must end in PROTECTED");
        chk(m_C1 == 2'd1 && m_C2 == 2'd1, "C1/C2 must end in MONITORED");
        chk(err_A + err_B + err_C1 + err_C2 == 0,
            $sformatf("golden result/structural errors: A=%0d B=%0d C1=%0d C2=%0d",
                      err_A, err_B, err_C1, err_C2));

        // ------------------------- metric report ---------------------------
        $display("---- METRICS (this run) ----");
        $display("cycles_total            : %0d", cy_A);
        $display("MT-02 protection_active%%: A=%0.2f  B=%0.2f  C1=%0.2f  C2=%0.2f",
                 100.0 * pc_A / cy_A, 100.0 * pc_B / cy_B,
                 100.0 * pc_C1 / cy_C1, 100.0 * pc_C2 / cy_C2);
        $display("MT-06 latency (cycles, avg over vectors):");
        $display("   A normal = %0.1f  (n=%0d)", 1.0*ln_A/(lc_A>0?lc_A:1), lc_A);
        $display("   B protected = %0.1f  (n=%0d)", 1.0*lp_B/(lpB_c>0?lpB_c:1), lpB_c);
        $display("   C1 normal = %0.1f (n=%0d) | C1 protected = %0.1f (n=%0d)",
                 1.0*ln_C1/(lc_C1>0?lc_C1:1), lc_C1,
                 1.0*lp_C1/(lpC1_c>0?lpC1_c:1), lpC1_c);
        $display("   C2 normal = %0.1f (n=%0d) | C2 protected = %0.1f (n=%0d)",
                 1.0*ln_C2/(lc_C2>0?lc_C2:1), lc_C2,
                 1.0*lp_C2/(lpC2_c>0?lpC2_c:1), lpC2_c);
        $display("cycles per variant      : A=%0d B=%0d C1=%0d C2=%0d",
                 cy_A, cy_B, cy_C1, cy_C2);
        $display("checked results         : A=%0d B=%0d C1=%0d C2=%0d",
                 chk_A, chk_B, chk_C1, chk_C2);
        $display("MT-07 throughput (committed/1000 cyc): A=%0.1f B=%0.1f C1=%0.1f C2=%0.1f",
                 1000.0*chk_A/(cy_A>0?cy_A:1), 1000.0*chk_B/(cy_B>0?cy_B:1),
                 1000.0*chk_C1/(cy_C1>0?cy_C1:1), 1000.0*chk_C2/(cy_C2>0?cy_C2:1));

        if (errors == 0) $display("TB_TOP_MODULE: PASS (4 variants, %0d vec each)", N_VEC);
        else             $display("TB_TOP_MODULE: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TB_TOP_MODULE: FAIL (timeout) drvA=%0d drvB=%0d drvC1=%0d drvC2=%0d m=%0d/%0d/%0d/%0d e=%0d/%0d/%0d/%0d chk=%0d/%0d/%0d/%0d",
                 v_A, v_B, v_C1, v_C2, m_A, m_B, m_C1, m_C2,
                 e_A, e_B, e_C1, e_C2, chk_A, chk_B, chk_C1, chk_C2);
        $finish;
    end

endmodule
