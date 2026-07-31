`timescale 1ns / 1ps

module tb_tpg_axis_wrapper;

    // Small frame to make the simulation easy to inspect:
    // 4 pixels per line, 3 lines per frame.
    localparam integer TB_WIDTH  = 4;
    localparam integer TB_HEIGHT = 3;
    localparam integer TB_PIXELS = TB_WIDTH * TB_HEIGHT;

    reg clk;
    reg rst;
    reg enable;
    reg frame_sync_async;

    reg [2:0]  pattern_select;
    reg [23:0] solid_color;

    wire [23:0] m_axis_video_tdata;
    wire        m_axis_video_tvalid;
    reg         m_axis_video_tready;
    wire        m_axis_video_tuser;
    wire        m_axis_video_tlast;

    wire [15:0] dbg_x_pos;
    wire [15:0] dbg_y_pos;

    integer i;

    tpg_axis_wrapper #(
        .G_WIDTH(TB_WIDTH),
        .G_HEIGHT(TB_HEIGHT)
    ) dut (
        .clk(clk),
        .rst(rst),
        .frame_sync_async(frame_sync_async),
        .enable(enable),
        .pattern_select(pattern_select),
        .solid_color(solid_color),
        .m_axis_video_tdata(m_axis_video_tdata),
        .m_axis_video_tvalid(m_axis_video_tvalid),
        .m_axis_video_tready(m_axis_video_tready),
        .m_axis_video_tuser(m_axis_video_tuser),
        .m_axis_video_tlast(m_axis_video_tlast),
        .dbg_x_pos(dbg_x_pos),
        .dbg_y_pos(dbg_y_pos)
    );

    // 100 MHz clock: period = 10 ns.
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Advance one clock cycle and wait a small delay so registered
    // and combinational outputs are stable before checking them.
    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Check current pixel coordinates exported by the wrapper.
    task check_position;
        input [15:0] expected_x;
        input [15:0] expected_y;
        begin
            if (dbg_x_pos !== expected_x || dbg_y_pos !== expected_y) begin
                $display("ERROR: expected x=%0d y=%0d, got x=%0d y=%0d",
                         expected_x, expected_y, dbg_x_pos, dbg_y_pos);
                $fatal;
            end
        end
    endtask

    // Check AXI sideband signals for the current pixel.
    task check_axis_flags;
        input expected_tuser;
        input expected_tlast;
        begin
            if (m_axis_video_tuser !== expected_tuser) begin
                $display("ERROR: expected TUSER=%0b, got TUSER=%0b at x=%0d y=%0d",
                         expected_tuser, m_axis_video_tuser, dbg_x_pos, dbg_y_pos);
                $fatal;
            end

            if (m_axis_video_tlast !== expected_tlast) begin
                $display("ERROR: expected TLAST=%0b, got TLAST=%0b at x=%0d y=%0d",
                         expected_tlast, m_axis_video_tlast, dbg_x_pos, dbg_y_pos);
                $fatal;
            end
        end
    endtask

    // Check that no AXI4-Stream transfer is offered between frames.
    task check_idle;
        begin
            if (m_axis_video_tvalid !== 1'b0) begin
                $display("ERROR: TVALID should be 0 while the wrapper is idle");
                $fatal;
            end

            if ((m_axis_video_tuser !== 1'b0) ||
                (m_axis_video_tlast !== 1'b0)) begin
                $display("ERROR: TUSER and TLAST should be 0 while idle");
                $fatal;
            end

            check_position(16'd0, 16'd0);
        end
    endtask

    // Hold the asynchronous VTC pulse long enough to cross the synchronizer.
    // The core sees one frame request after the two synchronization stages.
    task pulse_frame_sync;
        begin
            frame_sync_async = 1'b1;
            tick;
            tick;
            frame_sync_async = 1'b0;
            tick;

            if (m_axis_video_tvalid !== 1'b1) begin
                $display("ERROR: synchronized frame pulse did not start a frame");
                $fatal;
            end
        end
    endtask

    initial begin
        rst = 1'b1;
        enable = 1'b0;
        frame_sync_async = 1'b0;
        pattern_select = 3'd1;
        solid_color = 24'hA5_5A_11;
        m_axis_video_tready = 1'b0;

        // Reset phase.
        tick;
        tick;

        rst = 1'b0;
        tick;

        // While disabled, the wrapper must not present valid video.
        if (m_axis_video_tvalid !== 1'b0) begin
            $display("ERROR: TVALID should be 0 while disabled");
            $fatal;
        end

        // Enable the generator, but keep TREADY low.
        // The first pixel becomes valid, but it must not be consumed yet.
        enable = 1'b1;
        m_axis_video_tready = 1'b0;
        tick;

        check_position(16'd0, 16'd0);

        if (m_axis_video_tvalid !== 1'b1) begin
            $display("ERROR: TVALID should be 1 when enabled");
            $fatal;
        end

        if (m_axis_video_tdata !== solid_color) begin
            $display("ERROR: TDATA does not match solid_color pattern");
            $fatal;
        end

        check_axis_flags(1'b1, 1'b0);

        // Backpressure check:
        // TREADY stays low, so no AXI handshake happens.
        // The TPG must keep the same pixel and the same sideband signals.
        tick;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);

        tick;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);

        // Now allow transfers. Each cycle with TVALID=1 and TREADY=1
        // consumes one pixel, so coordinates advance through the frame.
        m_axis_video_tready = 1'b1;

        for (i = 0; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);

            check_axis_flags(
                (i == 0),
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );

            if (m_axis_video_tvalid !== 1'b1) begin
                $display("ERROR: TVALID deasserted during active frame");
                $fatal;
            end

            tick;
        end

        // After one full frame, the wrapper must become idle instead of
        // immediately generating another frame.
        check_idle;
        tick;
        check_idle;
        tick;
        check_idle;

        // A synchronized VTC pulse starts exactly one additional frame.
        m_axis_video_tready = 1'b0;
        pulse_frame_sync;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);

        // Keep the first pixel stalled after synchronization.
        tick;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);

        // Consume the complete synchronized frame.
        m_axis_video_tready = 1'b1;

        for (i = 0; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);
            check_axis_flags(
                (i == 0),
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );

            if (m_axis_video_tvalid !== 1'b1) begin
                $display("ERROR: TVALID deasserted during synchronized frame");
                $fatal;
            end

            tick;
        end

        check_idle;

        // Start another frame and disable the TPG after four accepted pixels.
        // The remaining pixels must still be transferred.
        m_axis_video_tready = 1'b0;
        pulse_frame_sync;
        m_axis_video_tready = 1'b1;

        for (i = 0; i < 4; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);
            check_axis_flags(
                (i == 0),
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );
            tick;
        end

        enable = 1'b0;

        if (m_axis_video_tvalid !== 1'b1) begin
            $display("ERROR: enable low aborted an active AXI frame");
            $fatal;
        end

        for (i = 4; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);
            check_axis_flags(
                1'b0,
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );
            tick;
        end

        check_idle;

        // A synchronized frame pulse must be ignored while enable is low.
        frame_sync_async = 1'b1;
        tick;
        tick;
        frame_sync_async = 1'b0;
        tick;
        tick;
        check_idle;

        $display(
            "TB PASSED: wrapper synchronization, pacing and AXI checks passed"
        );
        $finish;
    end

endmodule
