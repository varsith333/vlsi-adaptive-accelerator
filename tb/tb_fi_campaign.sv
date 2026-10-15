// ============================================================================
// tb_fi_campaign.sv - Systematic fault-injection campaign (V-07, MT-01/MT-03)
// ----------------------------------------------------------------------------
// One run = one (cfg, class, seed) combination with NINJ single-fault
// injections. Run parameters arrive through build/fi_args.txt, written by
// run_fi.ps1 before each xsim invocation:
//     "<cfg_code> <cls> <seed> <ninj>"   cfg_code: 0=a 1=b 2=c1 3=c2
//   (xsim's loader splits command-line plusargs at '=', so a file channel is
//    used instead; +CFG/+CLS/+SEED/+NINJ plusargs are kept as a fallback for
//    direct invocations that support them)
//   cls 1..4        fault class (table below)
//   seed 1..5       campaign seed (logged; LFSR seed = SEED*phi|1)
//   ninj >=1000     injections for a full run
//
// Fault classes (requirements_spec.md fault model, mapped to this design):
//   CLS=1 F-01  XOR 1 bit into the lane-A accumulator mid-vector (datapath)
//   CLS=2 F-02  XOR 1 bit into the head entry of the output buffer (register)
//   CLS=3 F-03  XOR 1 bit into stored operand state:
//                 variant A -> input-buffer entry (no checkpoint exists)
//                 variants B/C1/C2 -> checkpoint vector entry
//   CLS=4 F-04  force the core FSM state register to a random code 0..7
//               (7 = illegal code; skipped while the core already sits in
//                the target state, so placement waits for a transition)
//
// Methodology — single fault per reset (standard FI campaign structure):
//   RESET -> WARMUP (100 cyc, >=5 deliveries) -> injector KICK
//   -> LFSR gap (20..120 cyc) -> FIRE -> deposit placed at a negedge
//   -> t0 = placement -> OBSERVATION window
//        settle exit: obs>=80 && deliveries>=4 && quiet>=40
//        liveness: no delivery for 350 cyc => hang
//        hard cap: obs>=600
//   -> log CSV row -> RESET -> next injection.
//   The corruption is never repaired by the TB during the window (permanent
//   for that observation run); the reset defines the run boundary.
//
// Per-injection flags (external observables only):
//   det   : err_count changed, or mode changed (incl. ->RECOVERY), or
//           fault_latched set — any time in the window
//   wrong : a delivered result mismatched the golden FIFO (SDC event)
//   hang  : liveness limit reached before settling
//   f_bw  : flag raised BEFORE the first wrong delivery (MT-01 numerator)
//   rec   : mode entered RECOVERY; rec_lat = flag -> first correct delivery
//           after RECOVERY exits (MT-03)
//
// Outcome: noplace | hang | wrong | detected | detected_wrong | masked
// Output:  build/fi_log.csv (one row per injection) + FI_RUN summary line.
// ============================================================================
`timescale 1ns/1ps
module tb_fi_campaign;

    localparam int WARM_CYC   = 100;   // clean streaming before arming
    localparam int WARM_DELIV = 5;     // ... and at least this many deliveries
    localparam int SETTLE_MIN = 80;    // earliest window exit (cycles after t0)
    localparam int DELIV_MIN  = 4;     // deliveries required before settle
    localparam int QUIET_CYC  = 40;    // quiet cycles required before settle
    localparam int OBS_MAX    = 600;   // hard observation cap
    localparam int LIVELIM    = 350;   // no delivery for this many -> hang
    localparam int PLACE_TO   = 600;   // deposit never found its window
    localparam int RST_CYC    = 10;    // inter-injection reset length

    logic clk = 0;
    always #5 clk = ~clk;

    // ----------------------------- plusargs --------------------------------
    string     cfg_s;
    int        cls, seedp, sel;
    int        ninj_limit;             // +NINJ: injections this run
    int        inj_no;                 // completed injections (counter)
    int        fd;
    int        args_ff, cfg_code;      // fi_args.txt input channel
    logic [31:0] inj_seed;

    initial begin
        cfg_s = "c1"; cls = 1; seedp = 1;
        if (!$value$plusargs("CFG=%s", cfg_s))  cfg_s = "c1";
        if (!$value$plusargs("CLS=%d", cls))    cls   = 1;
        if (!$value$plusargs("SEED=%d", seedp)) seedp = 1;
        if (!$value$plusargs("NINJ=%d", ninj_limit)) ninj_limit = 20;
        // Primary channel: fi_args.txt written by run_fi.ps1 before each run.
        // (xsim's command-line plusarg plumbing splits values at '=', so the
        // runner passes "<cfg_code> <cls> <seed> <ninj>" through a file.)
        // cfg_code: 0=a  1=b  2=c1  3=c2
        args_ff = $fopen("fi_args.txt", "r");
        if (args_ff != 0) begin
            if ($fscanf(args_ff, "%d %d %d %d",
                        cfg_code, cls, seedp, ninj_limit) == 4) begin
                case (cfg_code)
                    0: cfg_s = "a";
                    1: cfg_s = "b";
                    2: cfg_s = "c1";
                    default: cfg_s = "c2";
                endcase
            end
            $fclose(args_ff);
        end
        case (cfg_s)
            "a":  sel = 0;
            "b":  sel = 1;
            "c1": sel = 2;
            default: sel = 3;
        endcase
        if (cls < 1 || cls > 4) cls = 1;
        if (ninj_limit < 1)     ninj_limit = 1;
        // deterministic LFSR seed derived from the logged campaign seed
        inj_seed = (32'(seedp) * 32'h9E37_79B9) | 32'h1;
        fd = $fopen("fi_log.csv", "a");
        $fdisplay(fd, "cfg,cls,seed,inj,t0,bit,idx,stgt,flag,det_lat,wrong_cnt,first_wrong_lat,rec_lat,hang,f_bw,outcome");
        $fflush(fd);
        // overall timeout: generous bound over the worst-case per-injection cost
        #(10.0 * ((ninj_limit * 1100) + 20000));
        $display("FI_CAMPAIGN: FAIL (timeout) inj_no=%0d/%0d", inj_no, ninj_limit);
        $fclose(fd);
        $finish;
    end

    // ------------------- injector (LFSR schedule) --------------------------
    logic        inj_rst_n = 1'b0;
    logic        kick, fire;
    logic [4:0]  bit_f;
    logic [2:0]  idx_f, stgt_f;
    logic [31:0] lfsr_dbg;
    // fields latched when fire pulses; wired to the harness deposit blocks so
    // the free-running LFSR cannot drift between placement and CSV logging
    logic [4:0]  p_bit;
    logic [2:0]  p_idx, p_stgt;

    fault_injector u_inj (
        .clk(clk), .rst_n(inj_rst_n), .seed(inj_seed),
        .kick(kick), .fire(fire),
        .bit_f(bit_f), .idx_f(idx_f), .stgt_f(stgt_f), .lfsr_dbg(lfsr_dbg)
    );
    // release after the first posedge has sampled the reset low (loads seed)
    initial begin #6 inj_rst_n = 1'b1; end

    // --------------------------- variant harnesses -------------------------
    logic        dsgn_rst_n = 1'b0;
    logic        pend_g = 1'b0;
    logic [3:0]  hrst, pend;
    logic [3:0]  placed_arr;
    logic [1:0]  m  [4];
    logic [7:0]  ec [4];
    logic        fl [4], wp [4], dp [4];
    int          ck [4];

    always_comb begin
        for (int i = 0; i < 4; i++) begin
            hrst[i] = dsgn_rst_n && (sel == i);
            pend[i] = pend_g && (sel == i);
        end
    end

    fi_harness #(.VARIANT(0)) h0 (
        .clk(clk), .rst_n(hrst[0]), .pend(pend[0]),
        .cls_i(3'(cls)), .bit_f(p_bit), .idx_f(p_idx), .stgt_f(p_stgt),
        .mode(m[0]), .err_count(ec[0]), .fault_latched(fl[0]),
        .wrong_pulse(wp[0]), .deliv_pulse(dp[0]), .checked(ck[0]),
        .placed(placed_arr[0]));
    fi_harness #(.VARIANT(1)) h1 (
        .clk(clk), .rst_n(hrst[1]), .pend(pend[1]),
        .cls_i(3'(cls)), .bit_f(p_bit), .idx_f(p_idx), .stgt_f(p_stgt),
        .mode(m[1]), .err_count(ec[1]), .fault_latched(fl[1]),
        .wrong_pulse(wp[1]), .deliv_pulse(dp[1]), .checked(ck[1]),
        .placed(placed_arr[1]));
    fi_harness #(.VARIANT(2)) h2 (
        .clk(clk), .rst_n(hrst[2]), .pend(pend[2]),
        .cls_i(3'(cls)), .bit_f(p_bit), .idx_f(p_idx), .stgt_f(p_stgt),
        .mode(m[2]), .err_count(ec[2]), .fault_latched(fl[2]),
        .wrong_pulse(wp[2]), .deliv_pulse(dp[2]), .checked(ck[2]),
        .placed(placed_arr[2]));
    fi_harness #(.VARIANT(3)) h3 (
        .clk(clk), .rst_n(hrst[3]), .pend(pend[3]),
        .cls_i(3'(cls)), .bit_f(p_bit), .idx_f(p_idx), .stgt_f(p_stgt),
        .mode(m[3]), .err_count(ec[3]), .fault_latched(fl[3]),
        .wrong_pulse(wp[3]), .deliv_pulse(dp[3]), .checked(ck[3]),
        .placed(placed_arr[3]));

    // ------------------------ selected-signal mux --------------------------
    logic [1:0] mode_s;
    logic [7:0] err_s;
    logic       flt_s, wr_s, dl_s, placed_s;
    always_comb begin
        case (sel)
            0: begin mode_s=m[0]; err_s=ec[0]; flt_s=fl[0]; wr_s=wp[0]; dl_s=dp[0]; placed_s=placed_arr[0]; end
            1: begin mode_s=m[1]; err_s=ec[1]; flt_s=fl[1]; wr_s=wp[1]; dl_s=dp[1]; placed_s=placed_arr[1]; end
            2: begin mode_s=m[2]; err_s=ec[2]; flt_s=fl[2]; wr_s=wp[2]; dl_s=dp[2]; placed_s=placed_arr[2]; end
            default: begin mode_s=m[3]; err_s=ec[3]; flt_s=fl[3]; wr_s=wp[3]; dl_s=dp[3]; placed_s=placed_arr[3]; end
        endcase
    end

    // --------------------------- campaign FSM ------------------------------
    typedef enum int {S_RST, S_WARM, S_GAP, S_PLACE, S_OBS, S_LOG, S_DONE} state_e;
    state_e cs = S_RST;

    int  rst_cnt, warm, obs, place_cnt, quiet;
    int  deliv_warm, deliv_t0, since_deliv;
    int  t0, flag_cyc, first_wrong_cyc, rec_exit_cyc;
    bit  flag_seen, flag_seen_d, wrong_seen, mode_was_R, rec_done, rec_taken;
    int  wrong_cnt;
    logic [1:0] mode0;
    logic [7:0] err0;
    bit  hang, noplace;
    int  det_lat, rec_lat;

    // aggregate statistics
    int n_det, n_wrong, n_hang, n_masked, n_noplace, n_fbw, n_det_wrong;
    int cnt_rec;
    longint sum_det, sum_rec;

    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    initial begin
        inj_no = 0; n_det = 0; n_wrong = 0; n_hang = 0; n_masked = 0;
        n_noplace = 0; n_fbw = 0; n_det_wrong = 0; cnt_rec = 0;
        sum_det = 0; sum_rec = 0;
        kick = 0; pend_g = 0; dsgn_rst_n = 0;
    end

    always @(posedge clk) begin : fsm
        case (cs)
            // ---------------- reset the design between injections -----------
            S_RST: begin
                kick       <= 0;
                pend_g     <= 0;
                dsgn_rst_n <= 0;
                rst_cnt    <= rst_cnt + 1;
                if (rst_cnt >= RST_CYC) begin
                    dsgn_rst_n <= 1;
                    rst_cnt    <= 0;
                    warm       <= 0;
                    deliv_warm <= 0;
                    cs         <= S_WARM;
                end
            end

            // ------------- clean streaming, then arm the injector -----------
            S_WARM: begin
                warm <= warm + 1;
                if (dl_s) deliv_warm <= deliv_warm + 1;
                if (warm >= WARM_CYC && deliv_warm >= WARM_DELIV) begin
                    kick <= 1;
                    cs   <= S_GAP;
                end
            end

            S_GAP: begin
                kick <= 0;
                if (fire) begin
                    p_bit     <= bit_f;
                    p_idx     <= idx_f;
                    p_stgt    <= stgt_f;
                    pend_g    <= 1;
                    place_cnt <= 0;
                    cs        <= S_PLACE;
                end
            end

            // -------- wait for the target-dependent deposit window ----------
            S_PLACE: begin
                place_cnt <= place_cnt + 1;
                if (placed_s) begin
                    pend_g        <= 0;
                    t0            <= cyc;
                    mode0         <= mode_s;
                    err0          <= err_s;
                    flag_seen     <= 0;  flag_seen_d <= 0;
                    wrong_seen    <= 0;  wrong_cnt   <= 0;
                    mode_was_R    <= (mode_s == 2'd3);
                    rec_done      <= 0;  rec_taken   <= 0;
                    first_wrong_cyc <= -1; flag_cyc <= -1;
                    rec_exit_cyc  <= -1;
                    det_lat       <= -1; rec_lat   <= -1;
                    hang          <= 0;  noplace   <= 0;
                    obs           <= 0;  quiet     <= 0;
                    deliv_t0      <= 0;  since_deliv <= 0;
                    cs            <= S_OBS;
                end else if (place_cnt >= PLACE_TO) begin
                    pend_g          <= 0;
                    noplace         <= 1;
                    flag_seen       <= 0;
                    rec_taken       <= 0;
                    mode_was_R      <= 0;
                    t0              <= -1;
                    flag_cyc        <= -1;
                    first_wrong_cyc <= -1;
                    rec_lat         <= -1;
                    det_lat         <= -1;
                    wrong_cnt       <= 0;
                    hang            <= 0;
                    cs              <= S_LOG;
                end
            end

            // ------------------------ observation ---------------------------
            S_OBS: begin
                obs <= obs + 1;
                if (dl_s) begin
                    deliv_t0    <= deliv_t0 + 1;
                    since_deliv <= 0;
                end else begin
                    since_deliv <= since_deliv + 1;
                end

                // detection flags (external observables only)
                if (!flag_seen &&
                    ((err_s !== err0) || (mode_s !== mode0) || flt_s)) begin
                    flag_seen <= 1;
                    flag_cyc  <= cyc;
                    det_lat   <= cyc - t0;
                end
                flag_seen_d <= flag_seen;
                if (mode_s == 2'd3) mode_was_R <= 1;
                if (mode_was_R && (mode_s != 2'd3) && !rec_done) begin
                    rec_done     <= 1;
                    rec_exit_cyc <= cyc;
                end
                // first correct delivery after recovery exit -> MT-03
                if (rec_done && !rec_taken && dl_s && !wr_s) begin
                    rec_taken <= 1;
                    rec_lat   <= cyc - flag_cyc;
                end

                // silent data corruption events
                if (wr_s) begin
                    wrong_cnt <= wrong_cnt + 1;
                    if (!wrong_seen) first_wrong_cyc <= cyc;
                    wrong_seen <= 1;
                    quiet      <= 0;
                end else if (flag_seen && !flag_seen_d) begin
                    quiet <= 0;
                end else begin
                    quiet <= quiet + 1;
                end

                // window exit: settled, liveness lost, or hard cap
                if ((obs >= SETTLE_MIN && deliv_t0 >= DELIV_MIN && quiet >= QUIET_CYC)
                    || (since_deliv > LIVELIM) || (obs >= OBS_MAX)) begin
                    hang = (since_deliv > LIVELIM);
                    cs  <= S_LOG;
                end
            end

            // --------------------------- log --------------------------------
            S_LOG: begin : logblk
                bit    fbw;
                string outcome;

                fbw = flag_seen &&
                      ((first_wrong_cyc < 0) ||
                       (flag_cyc >= 0 && flag_cyc < first_wrong_cyc));

                if      (noplace)  outcome = "noplace";
                else if (hang)     outcome = "hang";
                else if (wrong_cnt > 0)
                    outcome = flag_seen ? "detected_wrong" : "wrong";
                else if (flag_seen) outcome = "detected";
                else                outcome = "masked";

                // statistics
                if (noplace) n_noplace = n_noplace + 1;
                else begin
                    if (flag_seen)                    n_det  = n_det + 1;
                    if (wrong_cnt > 0)                n_wrong = n_wrong + 1;
                    if (hang)                         n_hang = n_hang + 1;
                    if (fbw)                          n_fbw  = n_fbw + 1;
                    if (flag_seen && wrong_cnt > 0)   n_det_wrong = n_det_wrong + 1;
                    if (!flag_seen && wrong_cnt == 0 && !hang)
                                                      n_masked = n_masked + 1;
                    if (flag_seen && det_lat >= 0)    sum_det = sum_det + det_lat;
                    if (rec_taken && rec_lat >= 0) begin
                        cnt_rec = cnt_rec + 1;
                        sum_rec = sum_rec + rec_lat;
                    end
                end

                $fdisplay(fd,
                    "%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0s",
                    cfg_s, cls, seedp, inj_no, t0,
                    int'(p_bit), int'(p_idx), int'(p_stgt),
                    flag_seen ? 1 : 0, det_lat, wrong_cnt,
                    first_wrong_cyc, rec_lat, hang ? 1 : 0, fbw ? 1 : 0,
                    outcome);
                $fflush(fd);

                inj_no = inj_no + 1;
                if (inj_no >= ninj_limit) cs <= S_DONE;
                else begin
                    rst_cnt <= 0;
                    cs      <= S_RST;
                end
            end

            S_DONE: begin : doneblk
                real mt01, avg_det, avg_rec;
                mt01    = (ninj_limit - n_noplace) > 0
                          ? (100.0 * n_fbw) / (ninj_limit - n_noplace) : 0.0;
                avg_det = (n_det > 0) ? (1.0 * sum_det) / n_det : 0.0;
                avg_rec = (cnt_rec > 0) ? (1.0 * sum_rec) / cnt_rec : 0.0;
                $display("FI_RUN cfg=%s cls=%0d seed=%0d ninj=%0d det=%0d wrong=%0d det_wrong=%0d hang=%0d masked=%0d noplace=%0d MT01=%0.1f avg_det_lat=%0.1f avg_rec_lat=%0.1f",
                         cfg_s, cls, seedp, inj_no, n_det, n_wrong, n_det_wrong,
                         n_hang, n_masked, n_noplace, mt01, avg_det, avg_rec);
                $display("FI_CAMPAIGN: DONE (%0d injections, cfg=%s cls=%0d seed=%0d)",
                         inj_no, cfg_s, cls, seedp);
                $fclose(fd);
                $finish;
            end

            default: cs <= S_RST;
        endcase
    end

endmodule

// ============================================================================
// fi_harness — one variant: driver + golden FIFO + DUT + class-conditional
// deposit block. Deposits live in generate branches so hierarchical target
// paths are statically visible (same pattern as tb_top_module).
// ============================================================================
module fi_harness #(
    parameter int VARIANT = 0
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pend,        // deposit armed for this harness
    input  logic [2:0]  cls_i,       // fault class 1..4
    input  logic [4:0]  bit_f,
    input  logic [2:0]  idx_f,
    input  logic [2:0]  stgt_f,
    output logic [1:0]  mode,
    output logic [7:0]  err_count,
    output logic        fault_latched,
    output logic        wrong_pulse, // delivered result != golden
    output logic        deliv_pulse, // any delivery
    output int          checked,
    output logic        placed       // deposit executed (1-cycle)
);

    localparam int DATA_W  = 8;
    localparam int ACC_W   = 32;
    localparam int VEC_LEN = 8;

    // ---------------- driver + golden model --------------------------------
    logic signed [DATA_W-1:0] drv_a, drv_b;
    logic                     drv_valid;
    int                       op_idx, vec_no, seed_r;
    logic signed [ACC_W-1:0]  mdl, pm, exp_v;

    logic in_ready, out_valid;
    logic signed [ACC_W-1:0] out_result;

    logic signed [ACC_W-1:0] expq[$];   // expected-value FIFO (buffer decoupling)

    assign drv_valid = 1'b1;
    initial placed = 1'b0;              // deposit block takes over from negedge 1

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_r <= 32'hDEAD_BEEF;    // identical stream for every injection
            op_idx <= 0; vec_no <= 0;
            mdl <= '0; drv_a <= '0; drv_b <= '0;
            checked <= 0;
            wrong_pulse <= 1'b0;
            deliv_pulse <= 1'b0;
            expq.delete();
        end else begin
            wrong_pulse <= 1'b0;
            deliv_pulse <= 1'b0;

            if (in_ready && drv_valid) begin
                pm = (op_idx == 0) ? ACC_W'(drv_a) * ACC_W'(drv_b)
                                   : mdl + ACC_W'(drv_a) * ACC_W'(drv_b);
                mdl <= pm;
                if (op_idx == VEC_LEN - 1) begin
                    expq.push_back(pm);
                    op_idx <= 0; vec_no <= vec_no + 1;
                end else begin
                    op_idx <= op_idx + 1;
                end
                drv_a <= $random(seed_r);
                drv_b <= $random(seed_r);
            end

            if (out_valid) begin
                if (expq.size() > 0) begin
                    exp_v = expq.pop_front();
                    if (out_result !== exp_v) wrong_pulse <= 1'b1;
                end
                deliv_pulse <= 1'b1;
                checked     <= checked + 1;
            end
        end
    end

    // ------------------------- deposit block --------------------------------
    // Fires at the first negedge where the class's target condition holds:
    //   F-01: mid-vector RUN with accumulation history (cnt != 0)
    //   F-02: output buffer holds a queued result (head entry drains next cyc)
    //   F-03: A -> input buffer non-empty; others -> core not writing ckpt (RUN)
    //   F-04: core not already sitting in the forced state
    `define FI_DEPOSIT                                                        \
        always @(negedge clk) begin                                           \
            placed <= 1'b0;                                                    \
            if (pend) begin                                                    \
                case (cls_i)                                                   \
                3'd1: if ((u_v.u_top.u_core.state == 3'd1) &&                 \
                          (u_v.u_top.u_core.cnt != 0)) begin                   \
                    u_v.u_top.u_core.u_lane_a.acc =                            \
                        u_v.u_top.u_core.u_lane_a.acc ^ (32'h1 << bit_f);     \
                    placed <= 1'b1;                                            \
                end                                                            \
                3'd2: if (u_v.u_top.u_obuf.count != 0) begin                   \
                    u_v.u_top.u_obuf.mem[u_v.u_top.u_obuf.rptr] =              \
                        u_v.u_top.u_obuf.mem[u_v.u_top.u_obuf.rptr] ^          \
                        (32'h1 << bit_f);                                      \
                    placed <= 1'b1;                                            \
                end                                                            \
                3'd3: begin                                                    \
                    if (VARIANT == 0) begin                                    \
                        if (u_v.u_top.u_ibuf.count != 0) begin                 \
                            u_v.u_top.u_ibuf.mem[u_v.u_top.u_ibuf.rptr] =      \
                                u_v.u_top.u_ibuf.mem[u_v.u_top.u_ibuf.rptr] ^  \
                                (16'h1 << bit_f[3:0]);                         \
                            placed <= 1'b1;                                    \
                        end                                                    \
                    end else if (u_v.u_top.u_core.state != 3'd1) begin         \
                        u_v.u_top.u_core.vec_a[idx_f] =                        \
                            u_v.u_top.u_core.vec_a[idx_f] ^                    \
                            (8'h1 << bit_f[2:0]);                              \
                        placed <= 1'b1;                                        \
                    end                                                        \
                end                                                            \
                3'd4: if (u_v.u_top.u_core.state != stgt_f) begin              \
                    u_v.u_top.u_core.state = stgt_f;                           \
                    placed <= 1'b1;                                            \
                end                                                            \
                endcase                                                        \
            end                                                                \
        end

    // ---------------------------- DUT ---------------------------------------
    generate
        case (VARIANT)
            0: begin : gA
                top_variant_a #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                    .clk(clk), .rst_n(rst_n),
                    .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                    .in_ready(in_ready), .out_ready(1'b1),
                    .out_result(out_result), .out_valid(out_valid),
                    .clear_latched(1'b0),
                    .mode(mode), .err_count(err_count),
                    .fault_latched(fault_latched), .protection_active());
                `FI_DEPOSIT
            end
            1: begin : gB
                top_variant_b #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                    .clk(clk), .rst_n(rst_n),
                    .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                    .in_ready(in_ready), .out_ready(1'b1),
                    .out_result(out_result), .out_valid(out_valid),
                    .clear_latched(1'b0),
                    .mode(mode), .err_count(err_count),
                    .fault_latched(fault_latched), .protection_active());
                `FI_DEPOSIT
            end
            2: begin : gC1
                top_variant_c1 #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                    .clk(clk), .rst_n(rst_n),
                    .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                    .in_ready(in_ready), .out_ready(1'b1),
                    .out_result(out_result), .out_valid(out_valid),
                    .clear_latched(1'b0),
                    .mode(mode), .err_count(err_count),
                    .fault_latched(fault_latched), .protection_active());
                `FI_DEPOSIT
            end
            default: begin : gC2
                top_variant_c2 #(.DATA_W(DATA_W), .ACC_W(ACC_W), .VEC_LEN(VEC_LEN)) u_v (
                    .clk(clk), .rst_n(rst_n),
                    .in_a(drv_a), .in_b(drv_b), .in_valid(drv_valid),
                    .in_ready(in_ready), .out_ready(1'b1),
                    .out_result(out_result), .out_valid(out_valid),
                    .clear_latched(1'b0),
                    .mode(mode), .err_count(err_count),
                    .fault_latched(fault_latched), .protection_active());
                `FI_DEPOSIT
            end
        endcase
    endgenerate

endmodule
