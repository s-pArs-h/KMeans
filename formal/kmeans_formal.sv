`default_nettype none

// Formal harness for kmeans_core (SymbiYosys, see kmeans.sby).
//
// The core's inputs are left completely free, except:
//   * reset is asserted in the first cycle only
//   * software programs every centroid before the first start
//
// Checked properties
//   P1  results never outnumber accepted points, and at most DEPTH are in flight
//   P2  s_ready only while running and points remain; no output while idle
//   P3  done implies exactly num_points were accepted and returned
//   P4  a stalled output (m_valid && !m_ready) holds its value
//   P5  data integrity: for an arbitrary point index chosen by the solver,
//       the returned cluster and distance equal a reference computed with
//       its own exact-width arithmetic. Proving multiplier equivalence is
//       hard for SAT solvers, so P5 runs at a small DATA_W where every
//       input value is covered; the width formulas are the same at 16 bits.
//       P1-P4 also run at the real DATA_W = 16.
module kmeans_formal #(
    parameter DATA_W     = 4,
    parameter K          = 4,
    parameter CNT_W      = 3,
    parameter CHECK_DATA = 1,    // P5 needs multiplier equivalence: only at small DATA_W
    parameter SCOREBOARD = 1     // harness counters (P1, P3, P5); off for the k-induction
                                 // task, where the core's own invariants cover P1 and P3
) (
    input wire                          clk,
    input wire                          rst_n,
    input wire                          cfg_we,
    input wire [$clog2(K)-1:0]          cfg_idx,
    input wire signed [DATA_W-1:0]      cfg_cx,
    input wire signed [DATA_W-1:0]      cfg_cy,
    input wire                          start,
    input wire [CNT_W-1:0]              num_points,
    input wire                          s_valid,
    input wire signed [DATA_W-1:0]      s_x,
    input wire signed [DATA_W-1:0]      s_y,
    input wire                          m_ready,
    input wire [$clog2(K)-1:0]          acc_idx
);
    localparam IDX_W  = $clog2(K);
    localparam DIST_W = 2*DATA_W + 1;
    localparam SUM_W  = DATA_W + CNT_W;
    localparam SSE_W  = DIST_W + CNT_W;
    localparam DEPTH  = 3 + $clog2(K);

    wire                     s_ready, m_valid, busy, done;
    wire [IDX_W-1:0]         m_cluster;
    wire [DIST_W-1:0]        m_dist;
    wire signed [SUM_W-1:0]  acc_sum_x, acc_sum_y;
    wire [CNT_W-1:0]         acc_count;
    wire [SSE_W-1:0]         sse;

    kmeans_core #(.DATA_W(DATA_W), .K(K), .CNT_W(CNT_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_idx(cfg_idx), .cfg_cx(cfg_cx), .cfg_cy(cfg_cy),
        .start(start), .num_points(num_points), .busy(busy), .done(done),
        .s_valid(s_valid), .s_ready(s_ready), .s_x(s_x), .s_y(s_y),
        .m_valid(m_valid), .m_ready(m_ready), .m_cluster(m_cluster), .m_dist(m_dist),
        .acc_idx(acc_idx), .acc_sum_x(acc_sum_x), .acc_sum_y(acc_sum_y),
        .acc_count(acc_count), .sse(sse)
    );

    // ------------------------------------------------------------------
    // Environment
    // ------------------------------------------------------------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    always @(*) assume(rst_n == f_past_valid);

    reg [K-1:0] f_cfg_done = '0;
    always @(posedge clk)
        if (cfg_we && !busy) f_cfg_done[cfg_idx] <= 1'b1;
    always @(*)
        if (start && !busy) assume(&f_cfg_done);

    // ------------------------------------------------------------------
    // Reference state
    // ------------------------------------------------------------------
    reg signed [DATA_W-1:0] ref_cx [0:K-1];
    reg signed [DATA_W-1:0] ref_cy [0:K-1];
    always @(posedge clk)
        if (cfg_we && !busy) begin
            ref_cx[cfg_idx] <= cfg_cx;
            ref_cy[cfg_idx] <= cfg_cy;
        end

    wire in_fire  = s_valid && s_ready;
    wire out_fire = m_valid && m_ready;
    wire launch   = start && !busy;

    reg [CNT_W:0]   f_in, f_out;
    reg [CNT_W-1:0] f_n;
    always @(posedge clk) begin
        if (!rst_n) begin
            f_in  <= '0;
            f_out <= '0;
            f_n   <= '0;
        end else if (launch) begin
            f_in  <= '0;
            f_out <= '0;
            f_n   <= num_points;
        end else begin
            if (in_fire)  f_in  <= f_in + 1'b1;
            if (out_fire) f_out <= f_out + 1'b1;
        end
    end

    // Data-integrity token: the solver picks any point index
    (* anyconst *) reg [CNT_W-1:0] f_tok;
    reg                     tok_seen;
    reg signed [DATA_W-1:0] tok_x, tok_y;
    always @(posedge clk) begin
        if (!rst_n || launch)
            tok_seen <= 1'b0;
        else if (in_fire && f_in == {1'b0, f_tok}) begin
            tok_seen <= 1'b1;
            tok_x    <= s_x;
            tok_y    <= s_y;
        end
    end

    // Reference arg-min with exact (never truncating) widths of its own:
    // difference DATA_W+1 bits, square 2*DATA_W+2 bits, sum REF_W bits.
    localparam REF_W = 2*DATA_W + 3;
    integer k;
    reg signed [DATA_W:0]     dx, dy;
    reg signed [2*DATA_W+1:0] sqx, sqy;
    reg        [REF_W-1:0]    dk, exp_d;
    reg        [IDX_W-1:0]    exp_idx;
    always @(*) begin
        exp_idx = '0;
        exp_d   = '0;
        for (k = 0; k < K; k = k + 1) begin
            dx  = tok_x - ref_cx[k];
            dy  = tok_y - ref_cy[k];
            sqx = dx * dx;
            sqy = dy * dy;
            dk  = sqx + sqy;
            if (k == 0 || dk < exp_d) begin
                exp_d   = dk;
                exp_idx = k[IDX_W-1:0];
            end
        end
    end

    // ------------------------------------------------------------------
    // Properties
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n) begin
            // P1
            if (SCOREBOARD) begin
                assert(f_out <= f_in);
                assert(f_in - f_out <= DEPTH);
            end
            // P2
            if (s_ready) assert(busy);
            if (SCOREBOARD && s_ready) assert(f_in < {1'b0, f_n});
            if (m_valid) assert(busy);
            // P3
            if (SCOREBOARD && done) assert(f_in == {1'b0, f_n} && f_out == {1'b0, f_n});
            // P4
            if ($past(rst_n) && $past(m_valid && !m_ready)) begin
                assert(m_valid);
                assert($stable(m_cluster));
                assert($stable(m_dist));
            end
            // P5
            if (SCOREBOARD && CHECK_DATA && out_fire && f_out == {1'b0, f_tok}) begin
                assert(tok_seen);
                assert(m_cluster == exp_idx);
                assert({{(REF_W-DIST_W){1'b0}}, m_dist} == exp_d);
            end
        end
    end

    // ------------------------------------------------------------------
    // Cover: show the interesting behaviours are reachable
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (f_past_valid && rst_n) begin
            cover(done && f_n == 3);
            cover(m_valid && !m_ready && f_in - f_out == DEPTH);
            cover(out_fire && f_out == {1'b0, f_tok} && f_tok == 2 && m_cluster == K - 1);
        end
    end

endmodule

`default_nettype wire
