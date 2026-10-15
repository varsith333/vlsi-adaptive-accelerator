`timescale 1ns/1ps
// ============================================================================
// mac_unit.sv — Registered INT8 multiply-accumulate lane
// ----------------------------------------------------------------------------
// One operand pair (a,b) is accepted when in_valid=1:
//   acc <= acc_clear ? (a*b) : acc + (a*b)
// acc_clear is intended to coincide with the FIRST accepted operand of a new
// accumulation window (no wasted clear cycle).
//
// acc_parity is a fault-detection metadata bit: it stores ^acc (XOR reduction)
// updated together with acc. If a fault flips a bit of acc between updates,
// (^acc != acc_parity) is detectable by the reliability monitor. If acc itself
// is updated normally, parity re-syncs — no false positives.
// ============================================================================
module mac_unit #(
    parameter int DATA_W = 8,
    parameter int ACC_W  = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    in_valid,     // accept operand this cycle
    input  logic                    acc_clear,    // start a fresh accumulation
    input  logic signed [DATA_W-1:0] a,
    input  logic signed [DATA_W-1:0] b,
    output logic signed [ACC_W-1:0]  acc,
    output logic                    acc_parity
);

    logic signed [2*DATA_W-1:0] prod;
    logic signed [ACC_W-1:0]    prod_ext;   // sign-extended product
    logic signed [ACC_W-1:0]    acc_next;

    assign prod    = a * b;
    assign prod_ext = prod;                // implicit sign extension to ACC_W

    always_comb begin
        if (acc_clear) acc_next = prod_ext;
        else           acc_next = acc + prod_ext;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc        <= '0;
            acc_parity <= 1'b0;
        end else if (in_valid) begin
            acc        <= acc_next;
            acc_parity <= ^acc_next;       // parity tracks every acc update
        end
    end

endmodule
