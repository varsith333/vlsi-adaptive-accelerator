// ============================================================================
// tb_mac_unit.sv — Unit testbench for mac_unit (self-checking)
// ----------------------------------------------------------------------------
// Checks (requirement V-01):
//   1. Reset behavior: acc=0, parity=0 after rst_n release
//   2. Directed: acc_clear with first operand starts a fresh accumulation
//   3. Reference model: random vectors vs software-style accumulation
//   4. acc_parity always equals ^acc after every update
// ============================================================================
`timescale 1ns/1ps
module tb_mac_unit;

    localparam int DATA_W = 8;
    localparam int ACC_W  = 32;
    localparam int N_RAND = 500;

    logic clk = 0, rst_n = 0;
    logic signed [DATA_W-1:0] a, b;
    logic in_valid, acc_clear;
    logic signed [ACC_W-1:0] acc;
    logic acc_parity;

    int errors = 0;

    mac_unit #(.DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .acc_clear(acc_clear),
        .a(a), .b(b),
        .acc(acc), .acc_parity(acc_parity)
    );

    always #5 clk = ~clk;   // 100 MHz

    // one cycle: apply operands, wait for the clock edge, check
    task automatic do_cycle(input logic signed [DATA_W-1:0] ta,
                            input logic signed [DATA_W-1:0] tb_v,
                            input logic clr,
                            input logic signed [ACC_W-1:0] expected);
        begin
            @(negedge clk);
            a = ta; b = tb_v; in_valid = 1; acc_clear = clr;
            @(posedge clk);
            #1; // allow NBA update
            if (acc !== expected) begin
                $display("FAIL @%0t: acc=%0d expected=%0d", $time, acc, expected);
                errors++;
            end
            if (acc_parity !== (^acc)) begin
                $display("FAIL @%0t: parity mismatch (^acc=%b, par=%b)",
                         $time, ^acc, acc_parity);
                errors++;
            end
            in_valid = 0; acc_clear = 0;
        end
    endtask

    logic signed [ACC_W-1:0] model;

    initial begin
        a = 0; b = 0; in_valid = 0; acc_clear = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk); #1;

        // 1. reset values
        if (acc !== '0 || acc_parity !== 1'b0) begin
            $display("FAIL: reset values acc=%0d par=%b", acc, acc_parity);
            errors++;
        end

        // 2. directed: first op with clear
        do_cycle(8'sd10, 8'sd7, 1'b1, 32'sd70);
        do_cycle(8'sd3,  8'sd5, 1'b0, 32'sd85);
        do_cycle(-8'sd4, 8'sd6, 1'b0, 32'sd61);

        // 3. new window with clear resets accumulation
        do_cycle(8'sd127, 8'sd127, 1'b1, 32'sd16129);
        do_cycle(-8'sd128, -8'sd128, 1'b0, 32'sd32513); // 16129+16384

        // 4. random vectors vs reference model
        model = 32'sd32513;
        for (int i = 0; i < N_RAND; i++) begin
            logic signed [DATA_W-1:0] ra, rb;
            logic clr;
            ra = $random;
            rb = $random;
            clr = (i % 7 == 0);
            if (clr) model = ACC_W'(ra) * ACC_W'(rb);
            else     model = model + (ACC_W'(ra) * ACC_W'(rb));
            do_cycle(ra, rb, clr, model);
        end

        if (errors == 0) $display("TB_MAC_UNIT: PASS (%0d random + directed)", N_RAND);
        else             $display("TB_MAC_UNIT: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
