`timescale 1ns / 1ps

// Generates an RGB888 test-pattern stream and its video timing markers.
module tpg_core #(
    parameter integer G_WIDTH  = 640,
    parameter integer G_HEIGHT = 480
)(
    input  wire        clk,
    input  wire        rst,

    // Generator control.
    input  wire        enable,
    input  wire        advance,
    input  wire        start_frame,

    // Pattern configuration.
    input  wire [2:0]  pattern_select,
    input  wire [23:0] solid_color,
    input  wire [7:0]  temporal_step,

    // Generated pixel stream and timing markers.
    output wire [23:0] pixel_rgb,
    output wire        pixel_valid,
    output wire        frame_start,
    output wire        line_end,

    // Internal state exposed to the control wrapper.
    output wire        busy_out,
    output wire        frame_done,
    output wire [7:0]  frame_phase_out,

    // Current pixel coordinates, exposed for debugging.
    output reg  [15:0] x_pos,
    output reg  [15:0] y_pos
);

    // Identifiers for the available test patterns.
    localparam [2:0] PATTERN_BLACK           = 3'd0;
    localparam [2:0] PATTERN_SOLID           = 3'd1;
    localparam [2:0] PATTERN_COLOR_BARS      = 3'd2;
    localparam [2:0] PATTERN_HORIZONTAL_RAMP = 3'd3;
    localparam [2:0] PATTERN_VERTICAL_RAMP   = 3'd4;
    localparam [2:0] PATTERN_CHECKERBOARD    = 3'd5;
    localparam [2:0] PATTERN_CROSSHATCH      = 3'd6;
    localparam [2:0] PATTERN_TEMPORAL_RAMP   = 3'd7;

    // Internal pattern and frame-control state.
    reg [23:0] next_pixel_rgb;
    reg [7:0]  frame_phase;
    reg        enable_previous;
    reg        busy;
    wire       enable_rise;
    wire       start_request;
    wire       last_pixel;

    // Selects the RGB value associated with the current pixel coordinates.
    always @(*) begin
        case (pattern_select)
            PATTERN_BLACK: begin
                next_pixel_rgb = 24'h000000;
            end

            PATTERN_SOLID: begin
                next_pixel_rgb = solid_color;
            end

            // Eight equal-width vertical color bars.
            PATTERN_COLOR_BARS: begin
                if (x_pos < ((G_WIDTH * 1) / 8))
                    next_pixel_rgb = 24'hFFFFFF;
                else if (x_pos < ((G_WIDTH * 2) / 8))
                    next_pixel_rgb = 24'hFFFF00;
                else if (x_pos < ((G_WIDTH * 3) / 8))
                    next_pixel_rgb = 24'h00FFFF;
                else if (x_pos < ((G_WIDTH * 4) / 8))
                    next_pixel_rgb = 24'h00FF00;
                else if (x_pos < ((G_WIDTH * 5) / 8))
                    next_pixel_rgb = 24'hFF00FF;
                else if (x_pos < ((G_WIDTH * 6) / 8))
                    next_pixel_rgb = 24'hFF0000;
                else if (x_pos < ((G_WIDTH * 7) / 8))
                    next_pixel_rgb = 24'h0000FF;
                else
                    next_pixel_rgb = 24'h000000;
            end

            // Grayscale ramps based on the horizontal or vertical coordinate.
            PATTERN_HORIZONTAL_RAMP: begin
                next_pixel_rgb = {
                    x_pos[7:0],
                    x_pos[7:0],
                    x_pos[7:0]
                };
            end

            PATTERN_VERTICAL_RAMP: begin
                next_pixel_rgb = {
                    y_pos[7:0],
                    y_pos[7:0],
                    y_pos[7:0]
                };
            end

            // Alternating 32 x 32-pixel black and white squares.
            PATTERN_CHECKERBOARD: begin
                if (x_pos[5] == y_pos[5])
                    next_pixel_rgb = 24'hFFFFFF;
                else
                    next_pixel_rgb = 24'h000000;
            end

            // White grid lines spaced every 32 pixels.
            PATTERN_CROSSHATCH: begin
                if ((x_pos[4:0] == 5'b00000) ||
                    (y_pos[4:0] == 5'b00000))
                    next_pixel_rgb = 24'hFFFFFF;
                else
                    next_pixel_rgb = 24'h000000;
            end

            // Uniform grayscale level that advances once per completed frame.
            PATTERN_TEMPORAL_RAMP: begin
                next_pixel_rgb = {
                    frame_phase,
                    frame_phase,
                    frame_phase
                };
            end

            default: begin
                next_pixel_rgb = 24'h000000;
            end
        endcase
    end

    // Detects the rising edge of enable to request the first frame.
    always @(posedge clk) begin
        if (rst)
            enable_previous <= 1'b0;
        else
            enable_previous <= enable;
    end

    // A rising enable starts the first frame immediately.
    // Later frames start only after a synchronized VTC frame pulse.
    assign enable_rise   = enable && !enable_previous;
    assign start_request = enable_rise || (enable && start_frame);

    // Identifies the final pixel coordinates of the current frame.
    assign last_pixel = (x_pos == G_WIDTH - 1) &&
                        (y_pos == G_HEIGHT - 1);

    // Exposes the internal generator state to the wrapper.
    assign busy_out        = busy;
    assign frame_phase_out = frame_phase;

    // Pulses for one clock cycle when the final pixel is transferred.
    // Requiring advance guarantees that the downstream block accepted it.
    assign frame_done = busy && advance && last_pixel;

    // The current pixel is valid only while a frame is being generated.
    assign pixel_rgb   = busy ? next_pixel_rgb : 24'h000000;
    assign pixel_valid = busy;

    // AXI4-Stream Video timing markers.
    assign frame_start = busy &&
                         (x_pos == 16'd0) &&
                         (y_pos == 16'd0);
    assign line_end = busy && (x_pos == G_WIDTH - 1);

    // Controls frame generation and advances the pixel coordinates.
    always @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            x_pos       <= 16'd0;
            y_pos       <= 16'd0;
            frame_phase <= 8'd0;
        end else if (!busy) begin
            // Keep the generator at the first pixel while it is idle.
            x_pos <= 16'd0;
            y_pos <= 16'd0;

            // Start a new frame only after an authorized request.
            busy <= start_request;

            // Restart the temporal ramp after software disables the TPG.
            if (!enable)
                frame_phase <= 8'd0;
        end else if (advance) begin
            // While busy, the active frame is completed even if enable falls.
            if (last_pixel) begin
                // The complete frame has been accepted by the downstream block.
                x_pos       <= 16'd0;
                y_pos       <= 16'd0;
                frame_phase <= frame_phase + temporal_step;
                busy        <= 1'b0;
            end else if (x_pos == G_WIDTH - 1) begin
                // End of the current line: return to its first column.
                x_pos <= 16'd0;
                y_pos <= y_pos + 16'd1;
            end else begin
                // Move to the next pixel in the current line.
                x_pos <= x_pos + 16'd1;
            end
        end
    end

endmodule
