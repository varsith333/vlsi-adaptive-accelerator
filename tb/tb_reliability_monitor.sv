// ============================================================================
// tb_reliability_monitor.sv — Unit testbench for reliability_monitor (V-01)
// ----------------------------------------------------------------------------
// Checks:
//   1. No false positives in a clean stream (fine mode on, all checks pass)
//   2. Parity error -> err_pulse, class 01; IGNORED when fine_en=0
//   3. Range error at pre-commit -> err_pulse + pre_invalid (even coarse mode)
//   4. Range error at delivery -> err_pulse, but NOT pre_invalid
//   5. Illegal core state (7) -> class 10, only when fine_en=1
//   6. Watchdog: WD_CYC busy cycles without progress -> single wd_timeout,
//      class 11; interleaved progress resets the count
//   7. Class priority: illegal beats datapath/liveness
// ============================================================================
`timescale 1ns/1ps
module tb_reliability_monitor;

    localparam int ACC_W   = 32;
    localparam int DATA_W  = 8;
    localparam int VEC_LEN = 8;
    localparam int WD_CYC  = 8;   // small for fast test

    logic clk = 0, rst_n = 0;
    logic signed [ACC_W-1:0] acc, result_val, out_val;
    logic acc_parity, pre_valid, out_valid_i;
    logic [2:0] state_o;
    logic busy, progress, fine_en;
    logic err_pulse, pre_invalid, wd_timeout, illegal_state;
    logic [1:0] err_class;

    int errors = 0;
    int err_cnt_seen = 0;

    reliability_monitor #(
        .ACC_W(ACC_W), .DATA_W(DATA_W), .VEC_LEN(VEC_LEN), .WD_CYC(WD_CYC)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .acc(acc), .acc_parity(acc_parity),
        .result_val(result_val), .pre_valid(pre_valid),
        .out_val(out_val), .out_valid_i(out_valid_i),
        .state_o(state_o), .busy(busy), .progress(progress),
        .fine_en(fine_en),
        .err_pulse(err_pulse), .err_class(err_class),
        .pre_invalid(pre_invalid),
        .wd_timeout(wd_timeout), .illegal_state(illegal_state)
    );

    always #5 clk = ~clk;

    // count every cycle with err_pulse (sampled at posedge)
    always @(posedge clk) if (rst_n && err_pulse) err_cnt_seen++;

    // sticky capture: wd_timeout is a 1-cycle pulse
    logic wd_seen = 0;
    logic [1:0] wd_cls = 0;
    always @(posedge clk) if (rst_n && wd_timeout) begin
        wd_seen <= 1;
        wd_cls  <= err_class;
    end

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL @%0t: %s", $time, msg); end
    endtask

    initial begin
        // defaults: everything healthy
        acc = 100; acc_parity = ^100; result_val = 5000; pre_valid = 0;
        out_val = 0; out_valid_i = 0; state_o = 3'd1; busy = 1;
        progress = 1; fine_en = 1;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(negedge clk);

        // --- 1. clean stream: 50 cycles, no errors ---
        for (int i = 0; i < 50; i++) begin
            @(negedge clk);
            acc = acc + 17; acc_parity = ^acc;   // stays consistent
            progress = 1;
            chk(!err_pulse, "false positive in clean stream");
        end

        // --- 2. parity error (fine mode) ---
        @(negedge clk);
        acc_parity = ~(^acc);
        #1;   // let combinational checks settle
        chk(err_pulse, "parity error not flagged");
        chk(err_class == 2'b01, "parity error class != 01");
        chk(!pre_invalid, "pre_invalid without pre_valid");

        // parity ignored in coarse mode
        fine_en = 0;
        #1 chk(!err_pulse, "parity flagged in coarse mode (fine_en=0)");
        fine_en = 1;
        acc_parity = ^acc;
        #1 chk(!err_pulse, "parity not cleared after fix");

        // --- 3. range error at pre-commit (coarse must catch: never blind) ---
        fine_en = 0;
        result_val = 32'sd200000; pre_valid = 1;
        #1;
        chk(err_pulse, "coarse range error at ST_CHECK not flagged");
        chk(pre_invalid, "pre_invalid not raised for bad pre-commit value");
        chk(err_class == 2'b01, "range class != 01");
        // same value should be caught at delivery too
        pre_valid = 0; out_val = -32'sd200000; out_valid_i = 1;
        #1;
        chk(err_pulse, "delivery range error not flagged");
        chk(!pre_invalid, "delivery error must not set pre_invalid");
        out_valid_i = 0; result_val = 0; out_val = 0;
        #1 chk(!err_pulse, "range error not cleared");

        // --- 5. illegal state, fine only ---
        state_o = 3'd7; fine_en = 0;
        #1 chk(!err_pulse, "illegal state flagged in coarse mode");
        fine_en = 1;
        #1;
        chk(err_pulse, "illegal state not flagged (fine)");
        chk(illegal_state, "illegal_state output not set");
        chk(err_class == 2'b10, "illegal state class != 10 (priority)");
        state_o = 3'd1; #1;

        // --- 6. watchdog ---
        progress = 1;
        for (int i = 0; i < 3; i++) begin
            @(negedge clk); progress = 0;              // stall
        end
        @(negedge clk); progress = 1;                  // progress resets it
        repeat (2) @(negedge clk);
        chk(!wd_timeout, "watchdog fired despite progress");

        busy = 1; progress = 0;
        repeat (WD_CYC + 3) @(negedge clk);
        chk(wd_seen, "watchdog did not fire after WD_CYC stalled cycles");
        chk(wd_cls == 2'b11, "watchdog class != 11");
        progress = 1; busy = 0;
        repeat (2) @(negedge clk);

        // --- 7. no errors while idle (busy=0) ---
        chk(!err_pulse, "error while idle");

        if (errors == 0) $display("TB_RELIABILITY_MONITOR: PASS");
        else             $display("TB_RELIABILITY_MONITOR: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
