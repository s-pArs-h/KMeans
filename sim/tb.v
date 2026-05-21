`timescale 1ns / 1ps

module tb_kmeans();

    reg clk;
    reg rst_n;
    reg start;
    reg [15:0] num_points;

    reg load_cent_en;
    reg [1:0] cent_idx;
    reg signed [15:0] cent_x;
    reg signed [15:0] cent_y;

    wire [15:0] point_addr;
    wire signed [15:0] point_x;
    wire signed [15:0] point_y;
    reg point_valid;

    wire [1:0] cluster_id;
    wire out_valid;
    wire done;

    reg signed [15:0] mem_x [0:19];     
    reg signed [15:0] mem_y [0:19];     
    reg [7:0]         exp_mem [0:19];   

    reg signed [15:0] test_cent_x [0:3];
    reg signed [15:0] test_cent_y [0:3];

    assign point_x = mem_x[point_addr];
    assign point_y = mem_y[point_addr];

    kmeans_core uut (
        .clk(clk), .rst_n(rst_n), .start(start), .num_points(num_points),
        .load_cent_en(load_cent_en), .cent_idx(cent_idx), .cent_x(cent_x), .cent_y(cent_y),
        .point_addr(point_addr), .point_x(point_x), .point_y(point_y), .point_valid(point_valid),
        .cluster_id(cluster_id), .out_valid(out_valid), .done(done)
    );

    // clk gen
    always #5 clk = ~clk;

    integer i, c;
    integer dx, dy, dist_sq, min_dist, best_cluster;

    // generate random points and compute software golden model
    initial begin
        test_cent_x[0] = 10;  test_cent_y[0] = 10;
        test_cent_x[1] = -10; test_cent_y[1] = 10;
        test_cent_x[2] = -10; test_cent_y[2] = -10;
        test_cent_x[3] = 10;  test_cent_y[3] = -10;
        
        for (i = 0; i < 20; i = i + 1) begin
            mem_x[i] = $random % 51; 
            mem_y[i] = $random % 51;

            min_dist = 2147483647; 
            best_cluster = 0;

            for (c = 0; c < 4; c = c + 1) begin
                dx = mem_x[i] - test_cent_x[c];
                dy = mem_y[i] - test_cent_y[c];
                dist_sq = (dx * dx) + (dy * dy);

                if (dist_sq < min_dist) begin
                    min_dist = dist_sq;
                    best_cluster = c;
                end
            end
            exp_mem[i] = best_cluster;
        end
    end

    // drive hardware inputs
    initial begin
        clk = 0; rst_n = 0; start = 0; num_points = 20; point_valid = 0;
        load_cent_en = 0; cent_idx = 0; cent_x = 0; cent_y = 0;

        #20 rst_n = 1;
        #10;

        // load centroids sequentially
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            load_cent_en = 1;
            cent_idx = i;
            cent_x = test_cent_x[i];
            cent_y = test_cent_y[i];
            @(posedge clk);
            load_cent_en = 0;
        end

        // trigger processing
        @(posedge clk);
        start = 1;
        point_valid = 1;
        @(posedge clk);
        start = 0;

        wait(done == 1);
        point_valid = 0;
        
        #50;
        $display("========================================");
        $display("SIMULATION COMPLETE: ALL TESTS PASSED!");
        $display("========================================");
        $finish;
    end

    // self-checking output monitor
    integer out_count = 0;
    always @(posedge clk) begin
        if (out_valid && out_count < num_points) begin
            if (cluster_id !== exp_mem[out_count][1:0]) begin
                $display("ERROR at point %d: Expected Cluster %d, Got %d", out_count, exp_mem[out_count][1:0], cluster_id);
                $stop;
            end else begin
                $display("Point %d: Hardware matched Expected -> Cluster %d", out_count, cluster_id);
            end
            out_count = out_count + 1;
        end
    end

endmodule