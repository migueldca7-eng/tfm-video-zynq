`timescale 1ns / 1ps

module tb_tpg_core;

    // A 64x64 frame provides:
    // - eight color bars, each eight pixels wide;
    // - four checkerboard cells of 32x32 pixels;
    // - crosshatch lines at coordinates 0 and 32.
    localparam integer TB_WIDTH  = 64;
    localparam integer TB_HEIGHT = 64;
    localparam integer TB_PIXELS = TB_WIDTH * TB_HEIGHT;

    localparam [2:0] PATTERN_BLACK           = 3'd0;
    localparam [2:0] PATTERN_SOLID           = 3'd1;
    localparam [2:0] PATTERN_COLOR_BARS      = 3'd2;
    localparam [2:0] PATTERN_HORIZONTAL_RAMP = 3'd3;
    localparam [2:0] PATTERN_VERTICAL_RAMP   = 3'd4;
    localparam [2:0] PATTERN_CHECKERBOARD    = 3'd5;
    localparam [2:0] PATTERN_CROSSHATCH      = 3'd6;
    localparam [2:0] PATTERN_TEMPORAL_RAMP   = 3'd7;

    reg clk;
    reg rst;
    reg enable;
    reg advance;
    reg start_frame;
    reg [2:0] pattern_select;
    reg [23:0] solid_color;
    reg [7:0] temporal_step;
    reg [15:0] active_width;
    reg [15:0] active_height;

    wire [23:0] pixel_rgb;
    wire        pixel_valid;
    wire        frame_start;
    wire        line_end;
    wire        busy_out;
    wire        frame_done;
    wire [7:0]  frame_phase_out;
    wire [15:0] x_pos;
    wire [15:0] y_pos;

    tpg_core dut (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .advance(advance),
        .start_frame(start_frame),
        .pattern_select(pattern_select),
        .solid_color(solid_color),
        .temporal_step(temporal_step),
        .active_width(active_width),
        .active_height(active_height),
        .pixel_rgb(pixel_rgb),
        .pixel_valid(pixel_valid),
        .frame_start(frame_start),
        .line_end(line_end),
        .busy_out(busy_out),
        .frame_done(frame_done),
        .frame_phase_out(frame_phase_out),
        .x_pos(x_pos),
        .y_pos(y_pos)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    function [23:0] expected_pixel;
        input [2:0]  pattern_value;
        input integer x_value;
        input integer y_value;
        input [7:0]  phase_value;
        input [23:0] solid_value;
        begin
            case (pattern_value)
                PATTERN_BLACK: begin
                    expected_pixel = 24'h000000;
                end

                PATTERN_SOLID: begin
                    expected_pixel = solid_value;
                end

                PATTERN_COLOR_BARS: begin
                    if (x_value < ((active_width * 1) / 8))
                        expected_pixel = 24'hFFFFFF;
                    else if (x_value < ((active_width * 2) / 8))
                        expected_pixel = 24'hFFFF00;
                    else if (x_value < ((active_width * 3) / 8))
                        expected_pixel = 24'h00FFFF;
                    else if (x_value < ((active_width * 4) / 8))
                        expected_pixel = 24'h00FF00;
                    else if (x_value < ((active_width * 5) / 8))
                        expected_pixel = 24'hFF00FF;
                    else if (x_value < ((active_width * 6) / 8))
                        expected_pixel = 24'hFF0000;
                    else if (x_value < ((active_width * 7) / 8))
                        expected_pixel = 24'h0000FF;
                    else
                        expected_pixel = 24'h000000;
                end

                PATTERN_HORIZONTAL_RAMP: begin
                    expected_pixel = {
                        x_value[7:0],
                        x_value[7:0],
                        x_value[7:0]
                    };
                end

                PATTERN_VERTICAL_RAMP: begin
                    expected_pixel = {
                        y_value[7:0],
                        y_value[7:0],
                        y_value[7:0]
                    };
                end

                PATTERN_CHECKERBOARD: begin
                    if (((x_value / 32) % 2) == ((y_value / 32) % 2))
                        expected_pixel = 24'hFFFFFF;
                    else
                        expected_pixel = 24'h000000;
                end

                PATTERN_CROSSHATCH: begin
                    if (((x_value % 32) == 0) ||
                        ((y_value % 32) == 0))
                        expected_pixel = 24'hFFFFFF;
                    else
                        expected_pixel = 24'h000000;
                end

                PATTERN_TEMPORAL_RAMP: begin
                    expected_pixel = {
                        phase_value,
                        phase_value,
                        phase_value
                    };
                end

                default: begin
                    expected_pixel = 24'h000000;
                end
            endcase
        end
    endfunction

    task check_current_pixel;
        input integer expected_x;
        input integer expected_y;
        input [7:0] expected_phase;
        reg [23:0] expected_rgb;
        reg expected_frame_start;
        reg expected_line_end;
        reg expected_frame_done;
        begin
            expected_rgb = expected_pixel(
                pattern_select,
                expected_x,
                expected_y,
                expected_phase,
                solid_color
            );
            expected_frame_start = (expected_x == 0) && (expected_y == 0);
            expected_line_end = (expected_x == active_width - 1);
            expected_frame_done = expected_line_end &&
                                  (expected_y == active_height - 1) &&
                                  advance;

            if ((x_pos !== expected_x) || (y_pos !== expected_y)) begin
                $display(
                    "ERROR: pattern=%0d expected x=%0d y=%0d, got x=%0d y=%0d",
                    pattern_select,
                    expected_x,
                    expected_y,
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if (pixel_valid !== 1'b1) begin
                $display(
                    "ERROR: pattern=%0d pixel_valid is not asserted at x=%0d y=%0d",
                    pattern_select,
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if (busy_out !== 1'b1) begin
                $display(
                    "ERROR: busy_out is not asserted at x=%0d y=%0d",
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if (frame_phase_out !== expected_phase) begin
                $display(
                    "ERROR: expected frame phase %0d, got %0d",
                    expected_phase,
                    frame_phase_out
                );
                $fatal;
            end

            if (pixel_rgb !== expected_rgb) begin
                $display(
                    "ERROR: pattern=%0d mismatch at x=%0d y=%0d: expected %h, got %h",
                    pattern_select,
                    x_pos,
                    y_pos,
                    expected_rgb,
                    pixel_rgb
                );
                $fatal;
            end

            if (frame_start !== expected_frame_start) begin
                $display(
                    "ERROR: pattern=%0d frame_start mismatch at x=%0d y=%0d",
                    pattern_select,
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if (line_end !== expected_line_end) begin
                $display(
                    "ERROR: pattern=%0d line_end mismatch at x=%0d y=%0d",
                    pattern_select,
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if (frame_done !== expected_frame_done) begin
                $display(
                    "ERROR: expected frame_done=%0b, got %0b at x=%0d y=%0d",
                    expected_frame_done,
                    frame_done,
                    x_pos,
                    y_pos
                );
                $fatal;
            end
        end
    endtask

    // Check that the core presents no valid video between frames.
    task check_idle;
        begin
            if (pixel_valid !== 1'b0) begin
                $display("ERROR: pixel_valid should be 0 while the core is idle");
                $fatal;
            end

            if (busy_out !== 1'b0) begin
                $display("ERROR: busy_out should be 0 while the core is idle");
                $fatal;
            end

            if (frame_done !== 1'b0) begin
                $display("ERROR: frame_done should be 0 while the core is idle");
                $fatal;
            end

            if ((x_pos !== 16'd0) || (y_pos !== 16'd0)) begin
                $display(
                    "ERROR: idle coordinates should be (0,0), got (%0d,%0d)",
                    x_pos,
                    y_pos
                );
                $fatal;
            end

            if ((frame_start !== 1'b0) || (line_end !== 1'b0)) begin
                $display("ERROR: video markers should be 0 while the core is idle");
                $fatal;
            end

            if (pixel_rgb !== 24'h000000) begin
                $display("ERROR: pixel_rgb should be black while the core is idle");
                $fatal;
            end
        end
    endtask

    // Request one additional frame while enable remains asserted.
    task request_frame;
        begin
            start_frame = 1'b1;
            tick;
            start_frame = 1'b0;

            if (pixel_valid !== 1'b1) begin
                $display("ERROR: start_frame did not start a new frame");
                $fatal;
            end
        end
    endtask

    task start_pattern;
        input [2:0] selected_pattern;
        begin
            // A low enable leaves the core idle and resets its temporal phase.
            enable = 1'b0;
            advance = 1'b0;
            start_frame = 1'b0;
            tick;

            pattern_select = selected_pattern;
            enable = 1'b1;
            tick;

            if (pixel_valid !== 1'b1) begin
                $display("ERROR: enable rising edge did not start the first frame");
                $fatal;
            end
        end
    endtask

    task run_static_pattern;
        input [2:0] selected_pattern;
        integer pixel_index;
        begin
            start_pattern(selected_pattern);
            advance = 1'b1;

            for (pixel_index = 0;
                 pixel_index < (active_width * active_height);
                 pixel_index = pixel_index + 1) begin
                check_current_pixel(
                    pixel_index % active_width,
                    pixel_index / active_width,
                    8'd0
                );
                tick;
            end

            advance = 1'b0;
            check_idle;

            // The core must not free-run while enable remains high.
            tick;
            check_idle;
            tick;
            check_idle;
        end
    endtask

    task run_temporal_pattern;
        integer pixel_index;
        begin
            // Use a non-default step to verify configurable phase increments.
            temporal_step = 8'd3;
            start_pattern(PATTERN_TEMPORAL_RAMP);
            advance = 1'b1;

            // First temporal frame: phase 0.
            for (pixel_index = 0;
                 pixel_index < TB_PIXELS;
                 pixel_index = pixel_index + 1) begin
                check_current_pixel(
                    pixel_index % TB_WIDTH,
                    pixel_index / TB_WIDTH,
                    8'd0
                );

                if (pixel_index == TB_PIXELS - 1) begin
                    // Stall the final pixel. The position and temporal
                    // phase must remain unchanged until it is accepted.
                    advance = 1'b0;
                    tick;
                    check_current_pixel(
                        TB_WIDTH - 1,
                        TB_HEIGHT - 1,
                        8'd0
                    );

                    tick;
                    check_current_pixel(
                        TB_WIDTH - 1,
                        TB_HEIGHT - 1,
                        8'd0
                    );

                    advance = 1'b1;
                    tick;
                end else begin
                    tick;
                end
            end

            advance = 1'b0;
            check_idle;

            // No second frame may start until start_frame is asserted.
            tick;
            check_idle;

            // Second temporal frame: phase 3.
            request_frame;
            advance = 1'b1;

            for (pixel_index = 0;
                 pixel_index < TB_PIXELS;
                 pixel_index = pixel_index + 1) begin
                check_current_pixel(
                    pixel_index % TB_WIDTH,
                    pixel_index / TB_WIDTH,
                    8'd3
                );
                tick;
            end

            advance = 1'b0;
            check_idle;

            // Start phase 6, then disable the TPG during the frame.
            // The active frame must still be completed.
            request_frame;
            advance = 1'b1;

            for (pixel_index = 0;
                 pixel_index < 8;
                 pixel_index = pixel_index + 1) begin
                check_current_pixel(
                    pixel_index % TB_WIDTH,
                    pixel_index / TB_WIDTH,
                    8'd6
                );
                tick;
            end

            enable = 1'b0;

            if (pixel_valid !== 1'b1) begin
                $display("ERROR: disabling the TPG aborted the active frame");
                $fatal;
            end

            for (pixel_index = 8;
                 pixel_index < TB_PIXELS;
                 pixel_index = pixel_index + 1) begin
                check_current_pixel(
                    pixel_index % TB_WIDTH,
                    pixel_index / TB_WIDTH,
                    8'd6
                );
                tick;
            end

            advance = 1'b0;
            check_idle;

            // One idle disabled cycle resets the temporal phase.
            tick;
            check_idle;

            // A frame pulse must be ignored while enable is low.
            start_frame = 1'b1;
            tick;
            start_frame = 1'b0;
            check_idle;

            // Re-enabling starts again from temporal phase 0.
            enable = 1'b1;
            tick;
            check_current_pixel(0, 0, 8'd0);
            temporal_step = 8'd1;

            // Return the DUT to an idle state before ending the test.
            rst = 1'b1;
            tick;
            rst = 1'b0;
            enable = 1'b0;
            tick;
            check_idle;
        end
    endtask

    initial begin
        rst = 1'b1;
        enable = 1'b0;
        advance = 1'b0;
        start_frame = 1'b0;
        pattern_select = PATTERN_BLACK;
        solid_color = 24'hA5_5A_11;
        temporal_step = 8'd1;
        active_width = TB_WIDTH;
        active_height = TB_HEIGHT;

        tick;
        tick;

        rst = 1'b0;
        tick;

        if (pixel_valid !== 1'b0) begin
            $display("ERROR: pixel_valid should be 0 while disabled");
            $fatal;
        end

        run_static_pattern(PATTERN_BLACK);
        run_static_pattern(PATTERN_SOLID);
        run_static_pattern(PATTERN_COLOR_BARS);
        run_static_pattern(PATTERN_HORIZONTAL_RAMP);
        run_static_pattern(PATTERN_VERTICAL_RAMP);
        run_static_pattern(PATTERN_CHECKERBOARD);
        run_static_pattern(PATTERN_CROSSHATCH);
        run_temporal_pattern;

        // Change the active dimensions while idle and verify that the core
        // adapts its color-bar regions, line endings and final frame pixel.
        active_width = 16'd80;
        active_height = 16'd32;
        run_static_pattern(PATTERN_COLOR_BARS);

        $display(
            "TB PASSED: tpg_core patterns, dynamic size, pacing and enable checks passed"
        );
        $finish;
    end

endmodule
