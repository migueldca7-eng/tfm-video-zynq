`timescale 1ns / 1ps

module tb_tpg_axis_wrapper;

    // Small frame to make the simulation easy to inspect:
    // 4 pixels per line, 3 lines per frame.
    localparam integer TB_WIDTH  = 4;
    localparam integer TB_HEIGHT = 3;
    localparam integer TB_PIXELS = TB_WIDTH * TB_HEIGHT;
    localparam integer TB_NEW_WIDTH  = 8;
    localparam integer TB_NEW_HEIGHT = 2;
    localparam integer TB_NEW_PIXELS = TB_NEW_WIDTH * TB_NEW_HEIGHT;
    localparam [31:0] TB_FRAME_SIZE = (TB_HEIGHT << 16) | TB_WIDTH;
    localparam [31:0] TB_NEW_FRAME_SIZE =
        (TB_NEW_HEIGHT << 16) | TB_NEW_WIDTH;

    // AXI-Lite register offsets.
    localparam [4:0] ADDR_ENABLE        = 5'h00;
    localparam [4:0] ADDR_PATTERN       = 5'h04;
    localparam [4:0] ADDR_SOLID_COLOR   = 5'h08;
    localparam [4:0] ADDR_TEMPORAL_STEP = 5'h0C;
    localparam [4:0] ADDR_STATUS        = 5'h10;
    localparam [4:0] ADDR_FRAME_PHASE   = 5'h14;
    localparam [4:0] ADDR_FRAME_SIZE    = 5'h18;

    reg clk;
    reg rst;
    reg frame_sync_async;

    // AXI4-Lite master signals driven by the testbench.
    reg  [4:0]  s_axi_awaddr;
    reg  [2:0]  s_axi_awprot;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;

    reg  [4:0]  s_axi_araddr;
    reg  [2:0]  s_axi_arprot;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

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

        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),

        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),

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

    // Drive one AXI-Lite write address and hold AWVALID until handshake.
    task automatic send_write_address;
        input [4:0] address;
        input integer delay_cycles;

        begin
            repeat (delay_cycles)
                @(posedge clk);

            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;

            while (s_axi_awready !== 1'b1)
                @(negedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    // Drive one AXI-Lite write data beat and hold WVALID until handshake.
    task automatic send_write_data;
        input [31:0] data;
        input [3:0]  strobe;
        input integer delay_cycles;

        begin
            repeat (delay_cycles)
                @(posedge clk);

            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;

            while (s_axi_wready !== 1'b1)
                @(negedge clk);

            @(negedge clk);
            s_axi_wvalid = 1'b0;
        end
    endtask

    // Accept the AXI-Lite write response after an optional delay.
    task automatic accept_write_response;
        input integer ready_delay;

        reg [1:0] saved_response;

        begin
            while (s_axi_bvalid !== 1'b1)
                @(negedge clk);

            saved_response = s_axi_bresp;

            // Verify that the slave holds its response under backpressure.
            repeat (ready_delay) begin
                @(negedge clk);

                if (s_axi_bvalid !== 1'b1) begin
                    $display("ERROR: BVALID changed before BREADY");
                    $fatal;
                end

                if (s_axi_bresp !== saved_response) begin
                    $display("ERROR: BRESP changed while waiting for BREADY");
                    $fatal;
                end
            end

            if (saved_response !== 2'b00) begin
                $display("ERROR: AXI write response was not OKAY");
                $fatal;
            end

            s_axi_bready = 1'b1;

            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Complete one AXI-Lite write. AW and W run in parallel because
    // their handshakes are independent.
    task automatic axi_write;
        input [4:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        input integer aw_delay;
        input integer w_delay;
        input integer bready_delay;

        begin
            fork
                send_write_address(address, aw_delay);
                send_write_data(data, strobe, w_delay);
            join

            accept_write_response(bready_delay);
        end
    endtask

    // Drive one AXI-Lite read address and hold ARVALID until handshake.
    task automatic send_read_address;
        input [4:0] address;

        begin
            @(negedge clk);
            s_axi_araddr  = address;
            s_axi_arvalid = 1'b1;

            while (s_axi_arready !== 1'b1)
                @(negedge clk);

            @(negedge clk);
            s_axi_arvalid = 1'b0;
        end
    endtask

    // Accept and check one AXI-Lite read response after an optional delay.
    task automatic accept_read_data;
        input [31:0] expected_data;
        input integer ready_delay;

        reg [31:0] saved_data;
        reg [1:0]  saved_response;

        begin
            while (s_axi_rvalid !== 1'b1)
                @(negedge clk);

            saved_data     = s_axi_rdata;
            saved_response = s_axi_rresp;

            // Verify that the slave holds its data under backpressure.
            repeat (ready_delay) begin
                @(negedge clk);

                if (s_axi_rvalid !== 1'b1) begin
                    $display("ERROR: RVALID changed before RREADY");
                    $fatal;
                end

                if (s_axi_rdata !== saved_data) begin
                    $display("ERROR: RDATA changed while waiting for RREADY");
                    $fatal;
                end

                if (s_axi_rresp !== saved_response) begin
                    $display("ERROR: RRESP changed while waiting for RREADY");
                    $fatal;
                end
            end

            if (saved_response !== 2'b00) begin
                $display("ERROR: AXI read response was not OKAY");
                $fatal;
            end

            if (saved_data !== expected_data) begin
                $display(
                    "ERROR: AXI read expected 0x%08h, got 0x%08h",
                    expected_data,
                    saved_data
                );
                $fatal;
            end

            s_axi_rready = 1'b1;

            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    // Complete one AXI-Lite read and compare the returned value.
    task automatic axi_read;
        input [4:0]  address;
        input [31:0] expected_data;
        input integer rready_delay;

        begin
            send_read_address(address);
            accept_read_data(expected_data, rready_delay);
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

    // Check AXI-Stream sideband signals for the current pixel.
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

    // Check the RGB value offered for the current pixel.
    task check_pixel;
        input [23:0] expected_rgb;
        begin
            if (m_axis_video_tdata !== expected_rgb) begin
                $display(
                    "ERROR: expected RGB=0x%06h, got RGB=0x%06h at x=%0d y=%0d",
                    expected_rgb,
                    m_axis_video_tdata,
                    dbg_x_pos,
                    dbg_y_pos
                );
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
        frame_sync_async = 1'b0;
        m_axis_video_tready = 1'b0;

        s_axi_awaddr  = 5'd0;
        s_axi_awprot  = 3'd0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata   = 32'd0;
        s_axi_wstrb   = 4'd0;
        s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;

        s_axi_araddr  = 5'd0;
        s_axi_arprot  = 3'd0;
        s_axi_arvalid = 1'b0;
        s_axi_rready  = 1'b0;

        // Reset phase.
        tick;
        tick;
        rst = 1'b0;
        tick;

        check_idle;

        // Check the software-visible reset values. The delayed read also
        // verifies that RVALID and RDATA remain stable under backpressure.
        axi_read(ADDR_ENABLE,        32'd0,       0);
        axi_read(ADDR_PATTERN,       32'd2,       0);
        axi_read(ADDR_SOLID_COLOR,   32'h0000FF00, 2);
        axi_read(ADDR_TEMPORAL_STEP, 32'd1,       0);
        axi_read(ADDR_STATUS,        32'd0,       0);
        axi_read(ADDR_FRAME_PHASE,   32'd0,       0);
        axi_read(ADDR_FRAME_SIZE,    TB_FRAME_SIZE, 0);

        // Exercise all AW/W arrival orders while the core is idle.
        axi_write(ADDR_PATTERN, 32'd1, 4'b0001, 0, 0, 0);
        axi_read(ADDR_PATTERN, 32'd1, 0);

        // Address arrives before data.
        axi_write(
            ADDR_SOLID_COLOR,
            32'h00A55A11,
            4'b0111,
            0,
            2,
            0
        );
        axi_read(ADDR_SOLID_COLOR, 32'h00A55A11, 0);

        // Data arrives before address. BREADY is also delayed to verify
        // that BVALID and BRESP remain stable.
        axi_write(ADDR_TEMPORAL_STEP, 32'd3, 4'b0001, 2, 0, 2);
        axi_read(ADDR_TEMPORAL_STEP, 32'd3, 0);

        // Enable the TPG. Its first frame starts immediately and is held at
        // the first pixel because AXI-Stream TREADY remains low.
        axi_write(ADDR_ENABLE, 32'd1, 4'b0001, 0, 0, 0);

        if (m_axis_video_tvalid !== 1'b1) begin
            $display("ERROR: enabling the TPG did not start the first frame");
            $fatal;
        end

        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);
        check_pixel(24'hA55A11);
        axi_read(ADDR_STATUS, 32'd1, 0);

        // Stream backpressure must keep the same first pixel stable.
        tick;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);
        check_pixel(24'hA55A11);

        // Request a new pattern while the current frame is active. Software
        // reads back the requested value, but the active frame stays solid.
        axi_write(ADDR_PATTERN, 32'd0, 4'b0001, 0, 0, 1);
        axi_read(ADDR_PATTERN, 32'd0, 0);

        // Request a new frame size while the current frame is active. The
        // register reads back the requested size, but the current frame must
        // retain its original dimensions until its final pixel is accepted.
        axi_write(ADDR_FRAME_SIZE, TB_NEW_FRAME_SIZE, 4'b1111, 0, 0, 0);
        axi_read(ADDR_FRAME_SIZE, TB_NEW_FRAME_SIZE, 0);
        axi_read(ADDR_STATUS, 32'd3, 0);

        check_position(16'd0, 16'd0);
        check_pixel(24'hA55A11);

        // Consume the complete frame and verify that it never changes pattern.
        m_axis_video_tready = 1'b1;

        for (i = 0; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);
            check_axis_flags(
                (i == 0),
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );
            check_pixel(24'hA55A11);

            if (m_axis_video_tvalid !== 1'b1) begin
                $display("ERROR: TVALID deasserted during active frame");
                $fatal;
            end

            tick;
        end

        check_idle;
        axi_read(ADDR_STATUS, 32'd0, 0);
        axi_read(ADDR_FRAME_PHASE, 32'd3, 0);

        // The next synchronized frame must use the requested black pattern.
        m_axis_video_tready = 1'b0;
        pulse_frame_sync;
        check_position(16'd0, 16'd0);
        check_axis_flags(1'b1, 1'b0);
        check_pixel(24'h000000);

        m_axis_video_tready = 1'b1;

        for (i = 0; i < TB_NEW_PIXELS; i = i + 1) begin
            check_position(i % TB_NEW_WIDTH, i / TB_NEW_WIDTH);
            check_axis_flags(
                (i == 0),
                ((i % TB_NEW_WIDTH) == (TB_NEW_WIDTH - 1))
            );
            check_pixel(24'h000000);
            tick;
        end

        check_idle;
        axi_read(ADDR_FRAME_PHASE, 32'd6, 0);

        // Restore the original size while idle; it must apply immediately.
        axi_write(ADDR_FRAME_SIZE, TB_FRAME_SIZE, 4'b1111, 0, 0, 0);
        axi_read(ADDR_FRAME_SIZE, TB_FRAME_SIZE, 0);

        // Partial writes and zero dimensions are invalid and must be ignored.
        axi_write(ADDR_FRAME_SIZE, 32'h0009_0006, 4'b0011, 0, 0, 0);
        axi_read(ADDR_FRAME_SIZE, TB_FRAME_SIZE, 0);
        axi_write(ADDR_FRAME_SIZE, 32'h0000_0008, 4'b1111, 0, 0, 0);
        axi_read(ADDR_FRAME_SIZE, TB_FRAME_SIZE, 0);

        // Restore the solid pattern while idle; it must apply immediately.
        axi_write(ADDR_PATTERN, 32'd1, 4'b0001, 0, 0, 0);

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
            check_pixel(24'hA55A11);
            tick;
        end

        // Stall the video while software disables the generator.
        m_axis_video_tready = 1'b0;
        axi_write(ADDR_ENABLE, 32'd0, 4'b0001, 0, 0, 0);
        axi_read(ADDR_ENABLE, 32'd0, 0);
        axi_read(ADDR_STATUS, 32'd1, 0);

        if (m_axis_video_tvalid !== 1'b1) begin
            $display("ERROR: enable low aborted an active AXI frame");
            $fatal;
        end

        m_axis_video_tready = 1'b1;

        for (i = 4; i < TB_PIXELS; i = i + 1) begin
            check_position(i % TB_WIDTH, i / TB_WIDTH);
            check_axis_flags(
                1'b0,
                ((i % TB_WIDTH) == (TB_WIDTH - 1))
            );
            check_pixel(24'hA55A11);
            tick;
        end

        check_idle;

        // A synchronized frame pulse must be ignored while ENABLE is zero.
        frame_sync_async = 1'b1;
        tick;
        tick;
        frame_sync_async = 1'b0;
        tick;
        tick;
        check_idle;

        axi_read(ADDR_STATUS, 32'd0, 0);
        axi_read(ADDR_FRAME_PHASE, 32'd0, 0);

        $display(
            "TB PASSED: AXI-Lite control, frame-safe updates and video checks passed"
        );
        $finish;
    end

endmodule
