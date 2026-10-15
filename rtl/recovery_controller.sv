`timescale 1ns/1ps
// ============================================================================
// recovery_controller.sv — Checkpoint replay sequencer (RECOVERY mode engine)
// ----------------------------------------------------------------------------
// Handshake with the core:
//   recovery_req (from adaptive controller, level)  -> start replay
//   replay_active (level)                          -> core computes from ckpt
//   replay_done + verify_ok (pulses from core)     -> result trustworthy?
//     ok    : recovery_ok pulse -> controller exits RECOVERY, commit unblocks
//     fail  : retry up to REC_MAX total attempts (replay_restart pulse each
//             time); after the REC_MAX-th failed verification -> latch_req,
//             which makes the adaptive controller sticky-fault and blocks all
//             future commits until clear_latched (then flush aborts the txn).
//
// commit_block = replay_active || fault_latched — gates output commits.
// ============================================================================
module recovery_controller #(
    parameter int REC_MAX = 3
)(
    input  logic       clk,
    input  logic       rst_n,
    input  logic       recovery_req,     // adaptive controller: mode==RECOVERY
    input  logic       replay_done,      // core pulse: pass finished
    input  logic       verify_ok,        // core: verification result (w/ done)
    input  logic       fault_latched,    // from adaptive controller
    output logic       replay_active,
    output logic       replay_restart,   // 1-cycle: retry the replay
    output logic       recovery_ok,      // 1-cycle: recovery succeeded
    output logic       latch_req,        // 1-cycle: attempts exhausted
    output logic       commit_block,
    output logic [2:0] attempt           // observable (debug / reporting)
);

    localparam int AW = $clog2(REC_MAX + 1);

    localparam logic [1:0] R_IDLE   = 2'd0,
                           R_REPLAY = 2'd1,
                           R_LATCH  = 2'd2;

    logic [1:0]    rs;
    logic [AW-1:0] attempt_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs            <= R_IDLE;
            attempt_q     <= '0;
            replay_active <= 1'b0;
            replay_restart<= 1'b0;
            recovery_ok   <= 1'b0;
            latch_req     <= 1'b0;
        end else begin
            replay_restart <= 1'b0;          // default: deassert pulses
            recovery_ok    <= 1'b0;
            latch_req      <= 1'b0;

            case (rs)
                R_IDLE: begin
                    if (recovery_req) begin
                        rs            <= R_REPLAY;
                        replay_active <= 1'b1;
                        attempt_q     <= AW'(1);
                    end
                end

                R_REPLAY: begin
                    if (replay_done) begin
                        if (verify_ok) begin
                            recovery_ok   <= 1'b1;
                            replay_active <= 1'b0;
                            attempt_q     <= '0;
                            rs            <= R_IDLE;
                        end else if (attempt_q < AW'(REC_MAX)) begin
                            attempt_q      <= attempt_q + 1'b1;
                            replay_restart <= 1'b1;    // one more try
                        end else begin
                            latch_req     <= 1'b1;     // T-9: give up
                            replay_active <= 1'b0;
                            rs            <= R_LATCH;
                        end
                    end
                end

                R_LATCH: begin
                    // stay quiet until the adaptive controller drops
                    // recovery_req (fault_latched cleared by external input)
                    if (!recovery_req) begin
                        rs        <= R_IDLE;
                        attempt_q <= '0;
                    end
                end

                default: rs <= R_IDLE;
            endcase
        end
    end

    assign attempt      = 3'(attempt_q);
    assign commit_block = replay_active || fault_latched;

endmodule
