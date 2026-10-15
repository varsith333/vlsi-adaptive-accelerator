// ============================================================================
// tb_adaptive_controller.sv — Transition coverage T-1..T-9 (requirement V-03)
// ----------------------------------------------------------------------------
// Instantiates adaptive_controller + error_counter + recovery_controller wired
// exactly as in top_module, and emulates the core's replay handshake.
//
// Small parameters chosen for fast exercise (same RTL, parameter sweep):
//   TH_ERR=2, TH_SEV=4, H_CLEAN=3, N_QUIET=4, REC_MAX=2
//
// Covered:
//   T-1  boot state (MONITORED adaptive / PROTECTED forced)
//   T-2  NORMAL + error -> MONITORED
//   T-3  MONITORED + threshold -> PROTECTED (and error counter cleared, D-4)
//   T-4  MONITORED + severe -> RECOVERY
//   T-5  PROTECTED + severe -> RECOVERY
//   T-6  PROTECTED + H_CLEAN clean commits -> MONITORED
//   T-7  MONITORED + N_QUIET clean commits -> NORMAL
//   T-8  RECOVERY + successful replay -> MONITORED (PROTECTED if forced)
//   T-9  RECOVERY + REC_MAX failed verifications -> fault_latched sticky,
//        commit blocked, clear_latched -> MONITORED (+flush pulse)
//   Forced policy: never de-escalates; recovery returns to PROTECTED.
//   Outputs: prot_en, monitor_fine, recovery_req gating, commit_block.
// ============================================================================
`timescale 1ns/1ps
module tb_adaptive_controller;

    localparam int TH_ERR  = 2;
    localparam int TH_SEV  = 4;
    localparam int H_CLEAN = 3;
    localparam int N_QUIET = 4;
    localparam int REC_MAX = 2;

    logic clk = 0, rst_n = 0;
    logic err_pulse, severe, commit_tick, clear_latched;
    logic replay_done, verify_ok;

    // adaptive + error counter (adaptive instance)
    logic [1:0] mode;
    logic prot_en, monitor_fine, recovery_req, fault_latched, err_clear, flush;
    logic [7:0] err_count;
    logic thresh_hit, sev_hit;
    logic monitor_fine_dummy; // unused

    // forced instance
    logic [1:0] mode_f;
    logic prot_en_f, monitor_fine_f, recovery_req_f, fault_latched_f;
    logic err_clear_f, flush_f;
    logic [7:0] err_count_f;
    logic thresh_hit_f, sev_hit_f;

    // recovery controllers (both instances share the core-side emulation
    // signals; only the adaptive one is stimulated for replay traffic)
    logic replay_active, replay_restart, recovery_ok, latch_req, commit_block;
    logic [2:0] attempt;
    logic replay_active_f, replay_restart_f, recovery_ok_f, latch_req_f;
    logic commit_block_f;
    logic [2:0] attempt_f;

    int errors = 0;
    int c;   // shared loop counter for waits

    // ---------------- adaptive (normal policy) instance -------------------
    error_counter #(.TH_ERR(8'(TH_ERR)), .TH_SEV(8'(TH_SEV))) u_errcnt (
        .clk(clk), .rst_n(rst_n), .err_pulse(err_pulse), .clear(err_clear),
        .count(err_count), .thresh_hit(thresh_hit), .sev_hit(sev_hit)
    );

    adaptive_controller #(
        .H_CLEAN(H_CLEAN), .N_QUIET(N_QUIET),
        .FORCE_PROTECTED(1'b0), .MONITOR_EN(1'b1)
    ) u_actrl (
        .clk(clk), .rst_n(rst_n),
        .err_pulse(err_pulse), .thresh_hit(thresh_hit),
        .sev_hit(sev_hit), .severe(severe),
        .commit_tick(commit_tick),
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
        .commit_block(commit_block), .attempt(attempt)
    );

    // ---------------- forced (always-protected) instance ------------------
    error_counter #(.TH_ERR(8'(TH_ERR)), .TH_SEV(8'(TH_SEV))) u_errcnt_f (
        .clk(clk), .rst_n(rst_n), .err_pulse(err_pulse), .clear(err_clear_f),
        .count(err_count_f), .thresh_hit(thresh_hit_f), .sev_hit(sev_hit_f)
    );

    adaptive_controller #(
        .H_CLEAN(H_CLEAN), .N_QUIET(N_QUIET),
        .FORCE_PROTECTED(1'b1), .MONITOR_EN(1'b1)
    ) u_actrl_f (
        .clk(clk), .rst_n(rst_n),
        .err_pulse(err_pulse), .thresh_hit(thresh_hit_f),
        .sev_hit(sev_hit_f), .severe(severe),
        .commit_tick(commit_tick),
        .recovery_ok(recovery_ok_f), .latch_req(latch_req_f),
        .clear_latched(clear_latched),
        .mode(mode_f), .prot_en(prot_en_f), .monitor_fine(monitor_fine_f),
        .recovery_req(recovery_req_f), .fault_latched(fault_latched_f),
        .err_clear(err_clear_f), .flush(flush_f)
    );

    recovery_controller #(.REC_MAX(REC_MAX)) u_rctrl_f (
        .clk(clk), .rst_n(rst_n),
        .recovery_req(recovery_req_f),
        .replay_done(replay_done), .verify_ok(verify_ok),
        .fault_latched(fault_latched_f),
        .replay_active(replay_active_f), .replay_restart(replay_restart_f),
        .recovery_ok(recovery_ok_f), .latch_req(latch_req_f),
        .commit_block(commit_block_f), .attempt(attempt_f)
    );

    always #5 clk = ~clk;

    localparam logic [1:0] M_N = 2'd0, M_M = 2'd1, M_P = 2'd2, M_R = 2'd3;

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $display("FAIL @%0t: %s (mode=%0d mode_f=%0d)", $time, msg, mode, mode_f);
        end
    endtask

    // wait until adaptive mode == exp (bounded)
    task automatic wait_mode(input logic [1:0] exp, input int max_c, input string msg);
        int wc;
        begin
            wc = 0;
            while ((mode !== exp) && (wc < max_c)) begin @(posedge clk); wc++; end
            chk(mode === exp, msg);
        end
    endtask

    task automatic pulse_err();   // one 1-cycle monitor error
        begin
            @(negedge clk); err_pulse = 1;
            @(negedge clk); err_pulse = 0;
        end
    endtask

    task automatic pulse_severe();
        begin
            @(negedge clk); severe = 1;
            @(negedge clk); severe = 0;
        end
    endtask

    task automatic do_commit(int n);   // n clean commits
        for (int i = 0; i < n; i++) begin
            @(negedge clk); commit_tick = 1;
            @(negedge clk); commit_tick = 0;
        end
    endtask

    // emulate the core answering a replay request with the given verdict
    task automatic do_replay(input bit ok);
        begin
            // wait for the recovery controller to start the replay
            while (!replay_active) @(posedge clk);
            repeat (2) @(posedge clk);      // "recompute" time
            @(negedge clk); replay_done = 1; verify_ok = ok;
            @(negedge clk); replay_done = 0;
            if (!ok) begin
                // controller may issue a restart -> next do_replay waits again
            end
        end
    endtask

    initial begin
        err_pulse = 0; severe = 0; commit_tick = 0; clear_latched = 0;
        replay_done = 0; verify_ok = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;

        // ---- T-1 --------------------------------------------------------
        chk(mode === M_M,   "T-1: adaptive boot state not MONITORED");
        chk(mode_f === M_P, "T-1: forced boot state not PROTECTED");
        chk(prot_en_f && monitor_fine_f, "forced outputs at boot");
        chk(!prot_en && monitor_fine, "adaptive prot_en must be 0 at boot");

        // ---- T-3: threshold escalation ----------------------------------
        pulse_err();  // count 1
        pulse_err();  // count 2 = TH_ERR -> PROTECTED
        wait_mode(M_P, 5, "T-3: did not escalate to PROTECTED");
        @(posedge clk); #1;
        chk(err_count == 8'd0, "T-3/D-4: error counter not cleared on entry to PROTECTED");
        chk(prot_en && monitor_fine, "prot_en/monitor_fine not set in PROTECTED");

        // ---- T-6: de-escalation hysteresis -------------------------------
        do_commit(H_CLEAN);
        wait_mode(M_M, 5, "T-6: PROTECTED -> MONITORED after H_CLEAN clean");
        chk(!prot_en, "prot_en must drop in MONITORED");

        // ---- T-7: quiet window -> NORMAL ---------------------------------
        do_commit(N_QUIET);
        wait_mode(M_N, 5, "T-7: MONITORED -> NORMAL after N_QUIET clean");
        chk(!monitor_fine, "monitor_fine must drop in NORMAL");

        // ---- T-2: coarse error in NORMAL ---------------------------------
        pulse_err();
        wait_mode(M_M, 5, "T-2: NORMAL + error -> MONITORED");
        chk(monitor_fine, "monitor_fine must rise in MONITORED");

        // ---- T-4: severe in MONITORED -> RECOVERY ------------------------
        pulse_severe();
        wait_mode(M_R, 5, "T-4: MONITORED + severe -> RECOVERY");
        @(posedge clk); #1;
        chk(recovery_req && !fault_latched, "recovery_req not asserted");
        do_replay(1'b1);   // successful verification
        wait_mode(M_M, 10, "T-8: RECOVERY + ok -> MONITORED");
        chk(!commit_block, "commit_block must clear after recovery");

        // ---- T-3 again then T-5 ------------------------------------------
        pulse_err(); pulse_err();
        wait_mode(M_P, 5, "T-3 (2nd): escalate failed");
        pulse_severe();
        wait_mode(M_R, 5, "T-5: PROTECTED + severe -> RECOVERY");

        // ---- T-9: replay failures -> latch -------------------------------
        do_replay(1'b0);            // attempt 1 fails -> restart
        chk(replay_restart, "no restart after failed verification");
        do_replay(1'b0);            // attempt 2 (=REC_MAX) fails -> latch
        wait_mode(M_R, 5, "T-9: mode must stay RECOVERY after latch");
        // fault_latched needs a cycle to register
        repeat (3) @(posedge clk); #1;
        chk(fault_latched, "T-9: fault_latched not set after REC_MAX failures");
        chk(!recovery_req, "recovery_req must drop when latched");
        chk(commit_block, "commit_block must be held while latched");

        // stuck until external clear
        repeat (10) @(posedge clk);
        chk(fault_latched && mode === M_R, "T-9: latch not sticky");

        @(negedge clk); clear_latched = 1;
        #1 chk(flush, "flush pulse missing on clear_latched");   // comb, pre-edge
        @(posedge clk); #1;
        @(negedge clk); clear_latched = 0;
        wait_mode(M_M, 5, "T-9: clear_latched must return to MONITORED");
        repeat (3) @(posedge clk); #1;
        chk(!fault_latched, "fault_latched not cleared");
        chk(!commit_block, "commit_block not released after clear");

        // ================= forced instance checks ========================
        // boot P (already checked); never leaves P on clean windows
        do_commit(N_QUIET + H_CLEAN + 5);
        repeat (3) @(posedge clk); #1;
        chk(mode_f === M_P, "forced policy de-escalated on clean window");
        chk(prot_en_f, "forced prot_en dropped");

        // forced: severe -> RECOVERY -> PROTECTED (not MONITORED)
        pulse_severe();
        c = 0;
        while ((mode_f !== M_R) && (c < 5)) begin @(posedge clk); c++; end
        chk(mode_f === M_R, "forced: severe -> RECOVERY failed");
        do_replay(1'b1);
        c = 0;
        while ((mode_f !== M_P) && (c < 10)) begin @(posedge clk); c++; end
        chk(mode_f === M_P, "forced: T-8 must return to PROTECTED");

        if (errors == 0) $display("TB_ADAPTIVE_CONTROLLER: PASS (T-1..T-9)");
        else             $display("TB_ADAPTIVE_CONTROLLER: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
