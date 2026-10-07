`default_nettype none

// Full-width formal proof of the arg-min tree (k-induction, unbounded).
// With every stage enabled, the outputs must be the minimum of the leaf
// distances presented LVLS cycles earlier, and the index of the FIRST
// (lowest-index) leaf holding that minimum.
module min_tree_formal #(
    parameter K      = 4,
    parameter DIST_W = 33
) (
    input wire                clk,
    input wire [K*DIST_W-1:0] leaf_dist
);
    localparam IDX_W = $clog2(K);
    localparam LVLS  = $clog2(K);

    wire [DIST_W-1:0] min_dist;
    wire [IDX_W-1:0]  min_idx;
    min_tree #(.K(K), .DIST_W(DIST_W)) dut (
        .clk(clk), .en({LVLS{1'b1}}), .leaf_dist(leaf_dist),
        .min_dist(min_dist), .min_idx(min_idx)
    );

    // leaves delayed by the tree latency
    reg [K*DIST_W-1:0] hist [0:LVLS-1];
    reg [7:0] f_age = 8'd0;
    integer i;
    always @(posedge clk) begin
        hist[0] <= leaf_dist;
        for (i = 1; i < LVLS; i = i + 1) hist[i] <= hist[i-1];
        if (f_age != LVLS) f_age <= f_age + 1'b1;
    end

    // reference: linear scan, first minimum wins
    integer k;
    reg [DIST_W-1:0] ref_d;
    reg [IDX_W-1:0]  ref_i;
    always @(*) begin
        ref_d = hist[LVLS-1][0 +: DIST_W];
        ref_i = '0;
        for (k = 1; k < K; k = k + 1)
            if (hist[LVLS-1][k*DIST_W +: DIST_W] < ref_d) begin
                ref_d = hist[LVLS-1][k*DIST_W +: DIST_W];
                ref_i = k[IDX_W-1:0];
            end
    end

    always @(posedge clk)
        if (f_age == LVLS) begin
            assert(min_dist == ref_d);
            assert(min_idx  == ref_i);
        end

endmodule

`default_nettype wire
