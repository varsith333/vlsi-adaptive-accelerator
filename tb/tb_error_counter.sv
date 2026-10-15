// ============================================================================
// tb_error_counter.sv — Unit testbench for error_counter (V-01)
// ----------------------------------------------------------------------------
// Checks: counting, saturating flags at TH_ERR/TH_SEV, clear behavior,
//         saturation at 0xFF (no silent wrap, requirement N-07).
// ============================================================================
`timescale 1ns/1ps
module tb_error_counter;

    localparam logic [7:0] TH_ERR = 8'd2;
    localparam logic [7:0] TH_SEV = 8'd4;

    logic clk = 0, rst_n = 0;
    logic err_pulse, clear;
    logic [7:0] count;
    logic thresh_hit, sev_hit;

    int errors = 0;

    error_counter #(.TH_ERR(TH_ERR), .TH_SEV(TH_SEV)) dut (
        .clk(clk), .rst_n(rst_n), .err_pulse(err_pulse), .clear(clear),
        .count(count), .thresh_hit(thresh_hit), .sev_hit(sev_hit)
    );

    always #5 clk = ~clk;

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL @%0t: %s", $time, msg); end
    endtask

    task automatic pulse_err();
        begin
            @(negedge clk); err_pulse = 1;
            @(negedge clk); err_pulse = 0;
        end
    endtask

    initial begin
        err_pulse = 0; clear = 0;
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(negedge clk);

        chk(count == 0 && !thresh_hit && !sev_hit, "reset state wrong");

        pulse_err();  // count = 1
        chk(count == 8'd1, "count after 1 error != 1");
        chk(!thresh_hit, "thresh_hit too early");

        pulse_err();  // count = 2 -> TH_ERR
        chk(count == 8'd2 && thresh_hit, "TH_ERR not reached after 2 errors");
        chk(!sev_hit, "sev_hit too early");

        pulse_err(); pulse_err();  // count = 4 -> TH_SEV
        chk(count == 8'd4 && sev_hit, "TH_SEV not reached after 4 errors");

        // clear
        @(negedge clk); clear = 1;
        @(negedge clk); clear = 0;
        chk(count == 0 && !thresh_hit && !sev_hit, "clear failed");

        // saturate: 300 errors -> must stop at 0xFF (no wrap)
        for (int i = 0; i < 300; i++) pulse_err();
        chk(count == 8'hFF, "counter did not saturate at 0xFF");

        if (errors == 0) $display("TB_ERROR_COUNTER: PASS");
        else             $display("TB_ERROR_COUNTER: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
