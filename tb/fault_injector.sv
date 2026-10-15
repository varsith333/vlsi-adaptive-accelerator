// ============================================================================
// fault_injector.sv — LFSR-based injection schedule generator (V-05/V-07)
// ----------------------------------------------------------------------------
// SIMULATION-ONLY (lives in tb/, never instantiated by rtl/ — requirement V-05).
//
// A free-running 32-bit Galois LFSR (seed derived from the +SEED plusarg and
// logged) provides the pseudo-random injection schedule and target fields:
//   bit_f[4:0]   bit position to flip (32-bit targets: accumulator, obuf)
//   idx_f[2:0]   storage index (checkpoint entry / buffer entry)
//   stgt_f[2:0]  FSM state code to force for class F-04 (7 = illegal code)
//   gap          20..120 cycles — the injection lands on a pseudo-random cycle
//                inside an active (post-reset, streaming) window
//
// Handshake:
//   campaign pulses kick  -> LFSR gap loaded and counted down
//   fire (1 cycle)        -> campaign latches fields, asserts pend
//   placed (from harness) -> the deposit condition was met and the fault is in
//   campaign clears pend, observes the outcome window, resets the DUT, repeats
// ============================================================================
`timescale 1ns/1ps
module fault_injector (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] seed,
    input  logic        kick,        // 1-cycle: arm the next scheduled injection
    output logic        fire,        // 1-cycle: schedule event (latch fields here)
    output logic [4:0]  bit_f,
    output logic [2:0]  idx_f,
    output logic [2:0]  stgt_f,
    output logic [31:0] lfsr_dbg     // logged for reproducibility
);
    logic [31:0] lfsr;
    logic [7:0]  gap_cnt;

    assign bit_f    = lfsr[4:0];
    assign idx_f    = lfsr[7:5];
    assign stgt_f   = lfsr[10:8];
    assign lfsr_dbg = lfsr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // seed|1 guarantees a non-zero state (Galois LFSR never locks up)
            lfsr    <= seed | 32'h1;
            gap_cnt <= '0;
            fire    <= 1'b0;
        end else begin
            // 32-bit Galois LFSR: x^32 + x^22 + x^2 + x + 1 (taps 32'h80200003)
            lfsr <= lfsr[0] ? ((lfsr >> 1) ^ 32'h8020_0003) : (lfsr >> 1);
            fire <= 1'b0;
            if (kick && (gap_cnt == '0))
                gap_cnt <= 8'(20 + (lfsr[15:8] % 8'd101));   // gap = 20..120
            else if (gap_cnt > 8'd1)
                gap_cnt <= gap_cnt - 8'd1;
            else if (gap_cnt == 8'd1) begin
                gap_cnt <= '0;
                fire    <= 1'b1;
            end
        end
    end
endmodule
