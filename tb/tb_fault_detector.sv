// ============================================================================
// tb_fault_detector.sv — Unit testbench for fault_detector (V-01)
// ----------------------------------------------------------------------------
// Checks: severe/detected combination logic, class priority
//         control(10) > liveness(11) > datapath(01).
// ============================================================================
`timescale 1ns/1ps
module tb_fault_detector;

    logic clk = 0, rst_n = 0;
    logic err_pulse;
    logic [1:0] err_class;
    logic dmr_mismatch, temporal_mismatch, wd_timeout, illegal_state, pre_invalid;
    logic detected, severe;
    logic [1:0] class_code;

    int errors = 0;

    fault_detector dut (
        .clk(clk), .rst_n(rst_n),
        .err_pulse(err_pulse), .err_class(err_class),
        .dmr_mismatch(dmr_mismatch), .temporal_mismatch(temporal_mismatch),
        .wd_timeout(wd_timeout), .illegal_state(illegal_state),
        .pre_invalid(pre_invalid),
        .detected(detected), .severe(severe), .class_code(class_code)
    );

    always #5 clk = ~clk;

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin errors++; $display("FAIL @%0t: %s", $time, msg); end
    endtask

    initial begin
        err_pulse = 0; err_class = 0; dmr_mismatch = 0; temporal_mismatch = 0;
        wd_timeout = 0; illegal_state = 0; pre_invalid = 0;
        #1;
        chk(!detected && !severe && class_code == 2'b00, "idle state wrong");

        // quiet datapath error (monitor pulse only, non-severe)
        err_pulse = 1; err_class = 2'b01; #1;
        chk(detected, "monitor error not detected");
        chk(!severe, "non-severe monitor error marked severe");
        chk(class_code == 2'b01, "class != 01");
        err_pulse = 0; err_class = 0; #1;

        // each severe source individually
        dmr_mismatch = 1; #1;
        chk(severe && detected && class_code == 2'b01, "dmr mismatch severe/class");
        dmr_mismatch = 0;
        temporal_mismatch = 1; #1;
        chk(severe && detected, "temporal mismatch not severe");
        temporal_mismatch = 0;
        pre_invalid = 1; #1;
        chk(severe && detected, "pre_invalid not severe");
        pre_invalid = 0;
        wd_timeout = 1; #1;
        chk(severe && detected && class_code == 2'b11, "wd class != 11");
        illegal_state = 1; #1;
        chk(severe && class_code == 2'b10, "control class priority lost");
        wd_timeout = 0; #1;
        chk(class_code == 2'b10, "control should beat liveness");
        illegal_state = 0; #1;
        chk(!detected && !severe, "not cleared");

        if (errors == 0) $display("TB_FAULT_DETECTOR: PASS");
        else             $display("TB_FAULT_DETECTOR: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
