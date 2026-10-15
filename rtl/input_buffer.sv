`timescale 1ns/1ps
// ============================================================================
// input_buffer.sv — Synchronous FIFO for operand pairs {a,b}
// ----------------------------------------------------------------------------
// Depth is deliberately small (16): the datapath streams operands; this buffer
// decouples the input source from the core FSM, and provides backpressure via
// `full`. Read side uses classic valid/ready: transfer when rd_valid && rd_pop.
// ============================================================================
module input_buffer #(
    parameter int DATA_W = 8,
    parameter int DEPTH  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    // write side
    input  logic [2*DATA_W-1:0]     wr_data,
    input  logic                    wr_valid,
    output logic                    full,
    // read side
    output logic [2*DATA_W-1:0]     rd_data,
    output logic                    rd_valid,
    input  logic                    rd_pop
);

    localparam int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [2*DATA_W-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]       wptr, rptr;
    logic [AW:0]         count;

    wire wr_en = wr_valid && !full;
    wire rd_en = rd_valid && rd_pop;

    assign full     = (count == (DEPTH[AW:0]));
    assign rd_valid = (count != '0);
    assign rd_data  = mem[rptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= '0;
            rptr  <= '0;
            count <= '0;
        end else begin
            if (wr_en) begin
                mem[wptr] <= wr_data;
                wptr      <= (wptr == AW'(DEPTH-1)) ? '0 : (wptr + 1'b1);
            end
            if (rd_en) begin
                rptr <= (rptr == AW'(DEPTH-1)) ? '0 : (rptr + 1'b1);
            end
            case ({wr_en, rd_en})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;   // hold (no change or simultaneous)
            endcase
        end
    end

endmodule
