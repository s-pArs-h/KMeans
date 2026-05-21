`timescale 1ns / 1ps

module distance_calc_2d (
    input  wire clk,
    input  wire rst_n,
    input  wire valid_in,
    input  wire signed [15:0] p_x,
    input  wire signed [15:0] p_y,
    input  wire signed [15:0] c_x,
    input  wire signed [15:0] c_y,
    
    output reg  valid_out,
    output reg  signed [31:0] distance_sq
);

    // stage 1: diff (17-bit to avoid overflow)
    reg signed [16:0] diff_x_s1;
    reg signed [16:0] diff_y_s1;
    reg valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_x_s1 <= 0;
            diff_y_s1 <= 0;
            valid_s1  <= 0;
        end else begin
            diff_x_s1 <= p_x - c_x;
            diff_y_s1 <= p_y - c_y;
            valid_s1  <= valid_in;
        end
    end

    // stage 2: square (max 34-bit result)
    reg signed [33:0] sq_x_s2;
    reg signed [33:0] sq_y_s2;
    reg valid_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sq_x_s2  <= 0;
            sq_y_s2  <= 0;
            valid_s2 <= 0;
        end else begin
            sq_x_s2  <= diff_x_s1 * diff_x_s1;
            sq_y_s2  <= diff_y_s1 * diff_y_s1;
            valid_s2 <= valid_s1;
        end
    end

    // stage 3: add and truncate back to standard 32-bit width
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            distance_sq <= 0;
            valid_out   <= 0;
        end else begin
            distance_sq <= sq_x_s2[31:0] + sq_y_s2[31:0];
            valid_out   <= valid_s2;
        end
    end

endmodule