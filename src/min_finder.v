`timescale 1ns / 1ps

module min_finder_4 (
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    
    input  wire [31:0] dist0,
    input  wire [31:0] dist1,
    input  wire [31:0] dist2,
    input  wire [31:0] dist3,
    
    output reg  [1:0]  min_index,
    output reg         valid_out
);

    // stage 1: pairwise comparison
    reg [31:0] min_val_01;
    reg [1:0]  idx_01;
    
    reg [31:0] min_val_23;
    reg [1:0]  idx_23;
    
    reg valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min_val_01 <= 0;
            idx_01     <= 2'd0;
            min_val_23 <= 0;
            idx_23     <= 2'd0;
            valid_s1   <= 0;
        end else begin
            if (dist0 <= dist1) begin
                min_val_01 <= dist0;
                idx_01     <= 2'd0;
            end else begin
                min_val_01 <= dist1;
                idx_01     <= 2'd1;
            end
            
            if (dist2 <= dist3) begin
                min_val_23 <= dist2;
                idx_23     <= 2'd2;
            end else begin
                min_val_23 <= dist3;
                idx_23     <= 2'd3;
            end
            
            valid_s1 <= valid_in;
        end
    end

    // stage 2: final winner
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min_index <= 2'd0;
            valid_out <= 0;
        end else begin
            if (min_val_01 <= min_val_23) begin
                min_index <= idx_01;
            end else begin
                min_index <= idx_23;
            end
            
            valid_out <= valid_s1;
        end
    end

endmodule