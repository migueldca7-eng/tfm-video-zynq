`timescale 1ns / 1ps

module tpg_axis_wrapper #(
    parameter integer G_WIDTH  = 640,
    parameter integer G_HEIGHT = 480
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        enable,
    input  wire [2:0]  pattern_select,
    input  wire [23:0] solid_color,

    output wire [23:0] m_axis_video_tdata,
    output wire        m_axis_video_tvalid,
    input  wire        m_axis_video_tready,
    output wire        m_axis_video_tuser,
    output wire        m_axis_video_tlast,

    output wire [15:0] dbg_x_pos,
    output wire [15:0] dbg_y_pos
);

    wire [23:0] pixel_rgb;
    wire        pixel_valid;
    wire        frame_start;
    wire        line_end;
    wire        advance;

    // AXI4-Stream handshake:
    // a pixel is consumed only when TVALID and TREADY are both high.
    assign advance = m_axis_video_tvalid && m_axis_video_tready;

    tpg_core #(
        .G_WIDTH(G_WIDTH),
        .G_HEIGHT(G_HEIGHT)
    ) u_tpg_core (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .advance(advance),
        .pattern_select(pattern_select),
        .solid_color(solid_color),
        .pixel_rgb(pixel_rgb),
        .pixel_valid(pixel_valid),
        .frame_start(frame_start),
        .line_end(line_end),
        .x_pos(dbg_x_pos),
        .y_pos(dbg_y_pos)
    );

    // AXI4-Stream Video mapping:
    // TDATA carries RGB888.
    // TVALID marks that the current pixel is valid.
    // TUSER marks Start Of Frame, only at pixel (0,0).
    // TLAST marks End Of Line, only at x = G_WIDTH-1.
    assign m_axis_video_tdata  = pixel_rgb;
    assign m_axis_video_tvalid = pixel_valid;
    assign m_axis_video_tuser  = frame_start;
    assign m_axis_video_tlast  = line_end;

endmodule