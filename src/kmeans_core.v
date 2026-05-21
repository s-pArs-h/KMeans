`timescale 1ns / 1ps

module kmeans_core (
    input  wire clk,
    input  wire rst_n,
    input  wire start,                  
    input  wire [15:0] num_points,      

    // centroid config
    input  wire load_cent_en,
    input  wire [1:0] cent_idx,
    input  wire signed [15:0] cent_x,
    input  wire signed [15:0] cent_y,

    // memory interface
    output reg  [15:0] point_addr,
    input  wire signed [15:0] point_x,
    input  wire signed [15:0] point_y,
    input  wire point_valid,            

    output wire [1:0] cluster_id,
    output wire out_valid,
    output reg  done
);

    reg signed [15:0] c_x [0:3];
    reg signed [15:0] c_y [0:3];

    // load initial centroids
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_x[0] <= 0; c_y[0] <= 0;
            c_x[1] <= 0; c_y[1] <= 0;
            c_x[2] <= 0; c_y[2] <= 0;
            c_x[3] <= 0; c_y[3] <= 0;
        end else if (load_cent_en) begin
            c_x[cent_idx] <= cent_x;
            c_y[cent_idx] <= cent_y;
        end
    end

    localparam IDLE   = 2'd0;
    localparam STREAM = 2'd1;
    localparam DRAIN  = 2'd2;
    localparam DONE   = 2'd3;

    reg [1:0] state, next_state;
    reg [2:0] drain_counter; 

    // gate input validity with FSM state to prevent pipeline garbage
    wire internal_valid = (state == STREAM) && point_valid;
    wire [31:0] dist0, dist1, dist2, dist3;
    wire pe_valid; 

    distance_calc_2d pe0 (
        .clk(clk), .rst_n(rst_n), .valid_in(internal_valid),
        .p_x(point_x), .p_y(point_y), .c_x(c_x[0]), .c_y(c_y[0]),
        .valid_out(pe_valid), .distance_sq(dist0)
    );

    distance_calc_2d pe1 (
        .clk(clk), .rst_n(rst_n), .valid_in(internal_valid),
        .p_x(point_x), .p_y(point_y), .c_x(c_x[1]), .c_y(c_y[1]),
        .valid_out(), .distance_sq(dist1) 
    );

    distance_calc_2d pe2 (
        .clk(clk), .rst_n(rst_n), .valid_in(internal_valid),
        .p_x(point_x), .p_y(point_y), .c_x(c_x[2]), .c_y(c_y[2]),
        .valid_out(), .distance_sq(dist2)
    );

    distance_calc_2d pe3 (
        .clk(clk), .rst_n(rst_n), .valid_in(internal_valid),
        .p_x(point_x), .p_y(point_y), .c_x(c_x[3]), .c_y(c_y[3]),
        .valid_out(), .distance_sq(dist3)
    );

    min_finder_4 min_tree (
        .clk(clk), .rst_n(rst_n), .valid_in(pe_valid),
        .dist0(dist0), .dist1(dist1), .dist2(dist2), .dist3(dist3),
        .min_index(cluster_id), .valid_out(out_valid)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:   if (start) next_state = STREAM;
            STREAM: if (point_addr == num_points - 1) next_state = DRAIN;
            DRAIN:  if (drain_counter == 5) next_state = DONE; 
            DONE:   next_state = IDLE;
        endcase
    end

    // datapath and FSM outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            point_addr    <= 0;
            drain_counter <= 0;
            done          <= 0;
        end else begin
            case (state)
                IDLE: begin
                    point_addr    <= 0;
                    drain_counter <= 0;
                    done          <= 0;
                end
                STREAM: begin
                    point_addr <= point_addr + 1; 
                end
                DRAIN: begin
                    drain_counter <= drain_counter + 1; // wait for pipeline flush
                end
                DONE: begin
                    done <= 1;
                end
            endcase
        end
    end

endmodule