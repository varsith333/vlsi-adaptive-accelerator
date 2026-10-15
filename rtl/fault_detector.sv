`timescale 1ns/1ps
// ============================================================================
// fault_detector.sv — Combines all detection sources, classifies severity
// ----------------------------------------------------------------------------
// Inputs come from the reliability monitor (err_pulse/err_class) and from the
// core's redundancy comparators (dmr_mismatch, temporal_mismatch).
//
// SEVERE sources force an immediate transition to RECOVERY (rule unified for
// all modes, design decision D-7): any pre-commit invalidation, any redundancy
// mismatch, a watchdog timeout, or an illegal FSM state. Non-severe monitor
// errors (e.g. parity seen outside ST_CHECK, range error at delivery) only
// increment the error counter and escalate through the thresholds.
//
// class_code priority: control (10) > liveness (11) > datapath (01).
// All outputs are combinational; the adaptive controller registers decisions.
// ============================================================================
module fault_detector (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       err_pulse,
    input  logic [1:0] err_class,
    input  logic       dmr_mismatch,
    input  logic       temporal_mismatch,
    input  logic       wd_timeout,
    input  logic       illegal_state,
    input  logic       pre_invalid,
    output logic       detected,
    output logic       severe,
    output logic [1:0] class_code
);

    always_comb begin
        severe   = dmr_mismatch | temporal_mismatch | wd_timeout |
                   illegal_state | pre_invalid;
        detected = err_pulse | severe;

        if (!detected)                            class_code = 2'b00;
        else if (illegal_state || (err_class == 2'b10)) class_code = 2'b10;
        else if (wd_timeout   || (err_class == 2'b11))  class_code = 2'b11;
        else                                      class_code = 2'b01;
    end

endmodule
