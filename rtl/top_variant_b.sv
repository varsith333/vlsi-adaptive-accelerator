`timescale 1ns/1ps
// ============================================================================
// top_variant_b.sv — Baseline B: ALWAYS-PROTECTED (forced PROTECTED mode)
// ----------------------------------------------------------------------------
// Same RTL as C1 with FORCE_PROTECTED=1: DMR lane + comparator + fine monitor
// permanently active; only RECOVERY can be left (it returns to PROTECTED).
// protection-active time == 100% by construction (PROTECTED or RECOVERY).
// ============================================================================
module top_variant_b #(
    parameter int DATA_W  = 8,
    parameter int ACC_W   = 32,
    parameter int VEC_LEN = 8
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic signed [DATA_W-1:0] in_a,
    input  logic signed [DATA_W-1:0] in_b,
    input  logic                     in_valid,
    output logic                     in_ready,
    input  logic                     out_ready,
    output logic signed [ACC_W-1:0]  out_result,
    output logic                     out_valid,
    input  logic                     clear_latched,
    output logic [1:0]               mode,
    output logic [7:0]               err_count,
    output logic                     fault_latched,
    output logic                     protection_active
);
    top_module #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN),
        .MONITOR_EN(1'b1), .FORCE_PROTECTED(1'b1),
        .HAS_DMR(1'b1), .HAS_TEMPORAL(1'b0)
    ) u_top (
        .clk(clk), .rst_n(rst_n),
        .in_a(in_a), .in_b(in_b), .in_valid(in_valid), .in_ready(in_ready),
        .out_ready(out_ready), .out_result(out_result), .out_valid(out_valid),
        .clear_latched(clear_latched),
        .mode(mode), .err_count(err_count),
        .fault_latched(fault_latched), .protection_active(protection_active)
    );
endmodule
