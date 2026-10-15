`timescale 1ns/1ps
// ============================================================================
// output_buffer.sv — Small FIFO for committed dot-product results
// ----------------------------------------------------------------------------
// The core pushes a result only when NOT stalled (this buffer not full AND the
// recovery controller is not asserting commit_block — stall logic lives in
// top_module). `push_ack` is a 1-cycle acknowledgment of an accepted push and
// serves as the COMMIT event used by the adaptive controller for hysteresis
// counting and by the testbench for delivery/reference checking.
// ============================================================================
module output_buffer #(
    parameter int ACC_W  = 32,
    parameter int DEPTH  = 4
)(
    input  logic                clk,
    input  logic                rst_n,
    // push side (from core)
    input  logic [ACC_W-1:0]    wr_data,
    input  logic                wr_valid,
    output logic                full,
    output logic                push_ack,   // 1-cycle: push accepted
    // pop side (external consumer)
    output logic [ACC_W-1:0]    rd_data,
    output logic                rd_valid,
    input  logic                rd_pop
);

    localparam int AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [ACC_W-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]    wptr, rptr;
    logic [AW:0]      count;

    wire wr_en = wr_valid && !full;
    wire rd_en = rd_valid && rd_pop;

    assign full     = (count == (DEPTH[AW:0]));
    assign rd_valid = (count != '0);
    assign rd_data  = mem[rptr];
    assign push_ack = wr_en;

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
                default: count <= count;
            endcase
        end
    end

endmodule
