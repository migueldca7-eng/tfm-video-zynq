`timescale 1ns / 1ps

module tb_tpg_core;

    localparam integer TB_WIDTH  = 4;
    localparam integer TB_HEIGHT = 3;
    localparam integer TB_PIXELS = TB_WIDTH * TB_HEIGHT;

    reg clk;
    reg rst;
    reg enable;
    reg advance;
    reg [2:0] pattern_select;
    reg [23:0] solid_color;

    wire [23:0] pixel_rgb;
    wire        pixel_valid;
    wire        frame_start;
    wire        line_end;
    wire [15:0] x_pos;
    wire [15:0] y_pos;

    integer i;

    tpg_core #(
        .G_WIDTH(TB_WIDTH),
        .G_HEIGHT(TB_HEIGHT)
    ) dut (
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

    task check_position;
        input [15:0] expected_x;
        input [15:0] expected_y;
        begin
            if (x_pos !== expected_x || y_pos !== expected_y) begin
                $display("ERROR: expected x=%0d y=%0d, got x=%0d y=%0d",
                         expected_x, expected_y, x_pos, y_pos);
                $fatal;
            end
        end
    endtask

    initial begin
        rst = 1'b1;
        enable = 1'b0;
        advance = 1'b0;
        pattern_select = 3'd1;
        solid_color = 24'h123456;

        tick;
        tick;

        rst = 1'b0;
        tick;

        if (pixel_valid !== 1'b0) begin
            $display("ERROR: pixel_valid should be 0 while disabled");
            $fatal;
        end

        enable = 1'b1;
        advance = 1'b0;
        tick;

        check_position(16'd0, 16'd0);

        if (pixel_valid !== 1'b1) begin
            $display("ERROR: pixel_valid should be 1 when enabled");
            $fatal;
        end

        if (frame_start !== 1'b1) begin
            $display("ERROR: frame_start should be 1 at first pixel");
            $fatal;
        end

        if (line_end !== 1'b0) begin
            $display("ERROR: line_end should be 0 at x=0");
            $fatal;
        end

        if (pixel_rgb !== 24'h123456) begin
            $display("ERROR: solid color pattern mismatch");
            $fatal;
        end

        advance = 1'b1;

        for (i = 0; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);

            if ((i == 0) && (frame_start !== 1'b1)) begin
                $display("ERROR: frame_start missing at first pixel");
                $fatal;
            end

            if ((i != 0) && (frame_start !== 1'b0)) begin
                $display("ERROR: frame_start asserted outside first pixel");
                $fatal;
            end

            if (((i % TB_WIDTH) == (TB_WIDTH - 1)) && (line_end !== 1'b1)) begin
                $display("ERROR: line_end missing at end of line, i=%0d", i);
                $fatal;
            end

            if (((i % TB_WIDTH) != (TB_WIDTH - 1)) && (line_end !== 1'b0)) begin
                $display("ERROR: line_end asserted before end of line, i=%0d", i);
                $fatal;
            end

            tick;
        end

        check_position(16'd0, 16'd0);

        advance = 1'b0;
        tick;
        check_position(16'd0, 16'd0);

        tick;
        check_position(16'd0, 16'd0);

        advance = 1'b1;
        tick;
        check_position(16'd1, 16'd0);

        $display("TB PASSED: tpg_core basic timing checks passed");
        $finish;
    end

endmodule