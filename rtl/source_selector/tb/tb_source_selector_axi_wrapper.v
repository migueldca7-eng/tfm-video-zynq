`timescale 1ns / 1ps

module tb_source_selector_axi_wrapper;

    localparam integer DATA_WIDTH   = 24;
    localparam integer FRAME_WIDTH  = 4;
    localparam integer FRAME_HEIGHT = 3;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

    localparam [3:0] ADDR_SOURCE_CONTROL = 4'h0;
    localparam [3:0] ADDR_SOURCE_STATUS  = 4'h4;

    localparam SOURCE_TPG    = 1'b0;
    localparam SOURCE_CAMERA = 1'b1;

    reg clk;
    reg rst;

    // AXI4-Lite write channels.
    reg  [3:0]  s_axi_awaddr;
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

    // AXI4-Lite read channels.
    reg  [3:0]  s_axi_araddr;
    reg  [2:0]  s_axi_arprot;
    reg         s_axi_arvalid;
    wire        s_axi_arready;

    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // TPG stream.
    reg  [DATA_WIDTH-1:0] s_axis_tpg_tdata;
    reg                   s_axis_tpg_tvalid;
    wire                  s_axis_tpg_tready;
    reg                   s_axis_tpg_tuser;
    reg                   s_axis_tpg_tlast;

    // Camera stream.
    reg  [DATA_WIDTH-1:0] s_axis_camera_tdata;
    reg                   s_axis_camera_tvalid;
    wire                  s_axis_camera_tready;
    reg                   s_axis_camera_tuser;
    reg                   s_axis_camera_tlast;

    // Selected stream.
    wire [DATA_WIDTH-1:0] m_axis_video_tdata;
    wire                  m_axis_video_tvalid;
    reg                   m_axis_video_tready;
    wire                  m_axis_video_tuser;
    wire                  m_axis_video_tlast;

    wire output_transfer;

    integer errors;
    integer output_transfers;
    integer frame_pixel_count;

    reg frame_seen;
    reg previous_active_source;
    reg source_change_pending_check;
    reg observed_output_stall;
    reg stalled_previous;
    reg [DATA_WIDTH-1:0] held_data;
    reg held_user;
    reg held_last;

    reg [31:0] read_data;
    integer polling_timeout;

    assign output_transfer =
        m_axis_video_tvalid && m_axis_video_tready;

    source_selector_axi_wrapper #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),

        .s_axi_awaddr           (s_axi_awaddr),
        .s_axi_awprot           (s_axi_awprot),
        .s_axi_awvalid          (s_axi_awvalid),
        .s_axi_awready          (s_axi_awready),
        .s_axi_wdata            (s_axi_wdata),
        .s_axi_wstrb            (s_axi_wstrb),
        .s_axi_wvalid           (s_axi_wvalid),
        .s_axi_wready           (s_axi_wready),
        .s_axi_bresp            (s_axi_bresp),
        .s_axi_bvalid           (s_axi_bvalid),
        .s_axi_bready           (s_axi_bready),
        .s_axi_araddr           (s_axi_araddr),
        .s_axi_arprot           (s_axi_arprot),
        .s_axi_arvalid          (s_axi_arvalid),
        .s_axi_arready          (s_axi_arready),
        .s_axi_rdata            (s_axi_rdata),
        .s_axi_rresp            (s_axi_rresp),
        .s_axi_rvalid           (s_axi_rvalid),
        .s_axi_rready           (s_axi_rready),

        .s_axis_tpg_tdata       (s_axis_tpg_tdata),
        .s_axis_tpg_tvalid      (s_axis_tpg_tvalid),
        .s_axis_tpg_tready      (s_axis_tpg_tready),
        .s_axis_tpg_tuser       (s_axis_tpg_tuser),
        .s_axis_tpg_tlast       (s_axis_tpg_tlast),

        .s_axis_camera_tdata    (s_axis_camera_tdata),
        .s_axis_camera_tvalid   (s_axis_camera_tvalid),
        .s_axis_camera_tready   (s_axis_camera_tready),
        .s_axis_camera_tuser    (s_axis_camera_tuser),
        .s_axis_camera_tlast    (s_axis_camera_tlast),

        .m_axis_video_tdata     (m_axis_video_tdata),
        .m_axis_video_tvalid    (m_axis_video_tvalid),
        .m_axis_video_tready    (m_axis_video_tready),
        .m_axis_video_tuser     (m_axis_video_tuser),
        .m_axis_video_tlast     (m_axis_video_tlast)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1'b1;

        s_axi_awaddr  = 4'd0;
        s_axi_awprot  = 3'd0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata   = 32'd0;
        s_axi_wstrb   = 4'd0;
        s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_araddr  = 4'd0;
        s_axi_arprot  = 3'd0;
        s_axi_arvalid = 1'b0;
        s_axi_rready  = 1'b0;

        s_axis_tpg_tdata  = 24'd0;
        s_axis_tpg_tvalid = 1'b0;
        s_axis_tpg_tuser  = 1'b0;
        s_axis_tpg_tlast  = 1'b0;

        s_axis_camera_tdata  = 24'd0;
        s_axis_camera_tvalid = 1'b0;
        s_axis_camera_tuser  = 1'b0;
        s_axis_camera_tlast  = 1'b0;

        m_axis_video_tready = 1'b1;

        repeat (5)
            @(posedge clk);

        @(negedge clk);
        rst = 1'b0;
    end

    // Sends an AXI4-Lite write with AW arriving before W.
    task axi_write_aw_first;
        input [3:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        reg   [1:0]  held_bresp;
        begin
            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_awready)
                @(posedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;

            repeat (2)
                @(posedge clk);

            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_wready)
                @(posedge clk);

            @(negedge clk);
            s_axi_wvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_bvalid)
                @(posedge clk);

            held_bresp = s_axi_bresp;

            repeat (2) begin
                @(posedge clk);
                if (!s_axi_bvalid || s_axi_bresp !== held_bresp) begin
                    $display("ERROR: B response changed while BREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_bresp !== 2'b00) begin
                $display("ERROR: AXI write returned non-OKAY response");
                errors = errors + 1;
            end

            @(negedge clk);
            s_axi_bready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Sends an AXI4-Lite write with W arriving before AW.
    task axi_write_w_first;
        input [3:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        reg   [1:0]  held_bresp;
        begin
            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_wready)
                @(posedge clk);

            @(negedge clk);
            s_axi_wvalid = 1'b0;

            repeat (2)
                @(posedge clk);

            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_awready)
                @(posedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_bvalid)
                @(posedge clk);

            held_bresp = s_axi_bresp;

            repeat (2) begin
                @(posedge clk);
                if (!s_axi_bvalid || s_axi_bresp !== held_bresp) begin
                    $display("ERROR: B response changed while BREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_bresp !== 2'b00) begin
                $display("ERROR: AXI write returned non-OKAY response");
                errors = errors + 1;
            end

            @(negedge clk);
            s_axi_bready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Reads one AXI4-Lite register and deliberately delays RREADY to check
    // that RDATA, RRESP and RVALID remain stable under backpressure.
    task axi_read;
        input  [3:0]  address;
        output [31:0] data;
        reg    [31:0] held_rdata;
        reg    [1:0]  held_rresp;
        begin
            @(negedge clk);
            s_axi_araddr  = address;
            s_axi_arvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_arready)
                @(posedge clk);

            @(negedge clk);
            s_axi_arvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_rvalid)
                @(posedge clk);

            held_rdata = s_axi_rdata;
            held_rresp = s_axi_rresp;

            repeat (2) begin
                @(posedge clk);
                if (!s_axi_rvalid ||
                    s_axi_rdata !== held_rdata ||
                    s_axi_rresp !== held_rresp) begin
                    $display("ERROR: R channel changed while RREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_rresp !== 2'b00) begin
                $display("ERROR: AXI read returned non-OKAY response");
                errors = errors + 1;
            end

            data = held_rdata;

            @(negedge clk);
            s_axi_rready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    task send_tpg_pixel;
        input [DATA_WIDTH-1:0] data;
        input                  user;
        input                  last;
        begin
            @(negedge clk);
            s_axis_tpg_tdata  = data;
            s_axis_tpg_tuser  = user;
            s_axis_tpg_tlast  = last;
            s_axis_tpg_tvalid = 1'b1;

            @(posedge clk);
            while (!s_axis_tpg_tready)
                @(posedge clk);

            @(negedge clk);
            s_axis_tpg_tvalid = 1'b0;
            s_axis_tpg_tuser  = 1'b0;
            s_axis_tpg_tlast  = 1'b0;
        end
    endtask

    task send_camera_pixel;
        input [DATA_WIDTH-1:0] data;
        input                  user;
        input                  last;
        begin
            @(negedge clk);
            s_axis_camera_tdata  = data;
            s_axis_camera_tuser  = user;
            s_axis_camera_tlast  = last;
            s_axis_camera_tvalid = 1'b1;

            @(posedge clk);
            while (!s_axis_camera_tready)
                @(posedge clk);

            @(negedge clk);
            s_axis_camera_tvalid = 1'b0;
            s_axis_camera_tuser  = 1'b0;
            s_axis_camera_tlast  = 1'b0;
        end
    endtask

    task send_tpg_frame;
        input [7:0] frame_id;
        integer x;
        integer y;
        integer pixel_index;
        begin
            pixel_index = 0;
            for (y = 0; y < FRAME_HEIGHT; y = y + 1) begin
                for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                    send_tpg_pixel(
                        {8'h10, frame_id, pixel_index[7:0]},
                        (x == 0) && (y == 0),
                        (x == FRAME_WIDTH - 1)
                    );
                    pixel_index = pixel_index + 1;
                end
            end
        end
    endtask

    task send_camera_frame;
        input [7:0] frame_id;
        integer x;
        integer y;
        integer pixel_index;
        begin
            pixel_index = 0;
            for (y = 0; y < FRAME_HEIGHT; y = y + 1) begin
                for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                    send_camera_pixel(
                        {8'hCA, frame_id, pixel_index[7:0]},
                        (x == 0) && (y == 0),
                        (x == FRAME_WIDTH - 1)
                    );
                    pixel_index = pixel_index + 1;
                end
            end
        end
    endtask

    // Monitor video framing, source identity and output backpressure.
    always @(posedge clk) begin
        if (rst) begin
            output_transfers           = 0;
            frame_pixel_count          = 0;
            frame_seen                 = 1'b0;
            previous_active_source     = SOURCE_TPG;
            source_change_pending_check = 1'b0;
            observed_output_stall      = 1'b0;
            stalled_previous           = 1'b0;
        end else begin
            if (dut.active_source != previous_active_source) begin
                previous_active_source      = dut.active_source;
                source_change_pending_check = 1'b1;
            end

            if (stalled_previous) begin
                if (!m_axis_video_tvalid ||
                    m_axis_video_tdata !== held_data ||
                    m_axis_video_tuser !== held_user ||
                    m_axis_video_tlast !== held_last) begin
                    $display("ERROR: video output changed during backpressure");
                    errors = errors + 1;
                end
            end

            if (m_axis_video_tvalid && !m_axis_video_tready) begin
                held_data  = m_axis_video_tdata;
                held_user  = m_axis_video_tuser;
                held_last  = m_axis_video_tlast;
                stalled_previous      = 1'b1;
                observed_output_stall = 1'b1;
            end else begin
                stalled_previous = 1'b0;
            end

            if (output_transfer) begin
                output_transfers = output_transfers + 1;

                if ((dut.active_source == SOURCE_TPG) &&
                    (m_axis_video_tdata[23:16] !== 8'h10)) begin
                    $display("ERROR: camera data received while TPG is active");
                    errors = errors + 1;
                end

                if ((dut.active_source == SOURCE_CAMERA) &&
                    (m_axis_video_tdata[23:16] !== 8'hCA)) begin
                    $display("ERROR: TPG data received while camera is active");
                    errors = errors + 1;
                end

                if (source_change_pending_check) begin
                    if (!m_axis_video_tuser ||
                        m_axis_video_tdata[7:0] !== 8'd0) begin
                        $display("ERROR: source change did not start at SOF");
                        errors = errors + 1;
                    end
                    source_change_pending_check = 1'b0;
                end

                if (m_axis_video_tuser) begin
                    if (frame_seen &&
                        frame_pixel_count != FRAME_PIXELS) begin
                        $display(
                            "ERROR: previous output frame had %0d pixels",
                            frame_pixel_count
                        );
                        errors = errors + 1;
                    end
                    frame_seen        = 1'b1;
                    frame_pixel_count = 0;
                end else if (!frame_seen) begin
                    $display("ERROR: output began without TUSER");
                    errors = errors + 1;
                end

                if (m_axis_video_tlast !==
                    ((frame_pixel_count % FRAME_WIDTH) ==
                     (FRAME_WIDTH - 1))) begin
                    $display("ERROR: incorrect TLAST position");
                    errors = errors + 1;
                end

                frame_pixel_count = frame_pixel_count + 1;
            end
        end
    end

    // Performs the two software-controlled source changes.
    task run_switch_sequence;
        begin
            while (output_transfers < 4)
                @(negedge clk);

            // Freeze the active TPG frame so STATUS must report pending.
            @(negedge clk);
            m_axis_video_tready = 1'b0;

            while (!(m_axis_video_tvalid && !m_axis_video_tready))
                @(posedge clk);

            axi_write_aw_first(
                ADDR_SOURCE_CONTROL,
                32'd1,
                4'b0001
            );

            axi_read(ADDR_SOURCE_CONTROL, read_data);
            if (read_data !== 32'd1) begin
                $display("ERROR: CONTROL did not store camera request");
                errors = errors + 1;
            end

            axi_read(ADDR_SOURCE_STATUS, read_data);
            if (read_data[1:0] !== 2'b10) begin
                $display("ERROR: expected pending camera status, got %h", read_data);
                errors = errors + 1;
            end

            @(negedge clk);
            m_axis_video_tready = 1'b1;

            // Poll exactly as software will do until camera is active.
            polling_timeout = 64;
            read_data = 32'd0;
            while ((read_data[1:0] !== 2'b01) &&
                   (polling_timeout > 0)) begin
                axi_read(ADDR_SOURCE_STATUS, read_data);
                polling_timeout = polling_timeout - 1;
            end

            if (polling_timeout == 0) begin
                $display("ERROR: timeout waiting for camera source");
                errors = errors + 1;
            end

            // Wait for a camera pixel and freeze that frame before requesting
            // the TPG. W is deliberately sent before AW this time.
            while (!(output_transfer &&
                     dut.active_source == SOURCE_CAMERA &&
                     !m_axis_video_tuser))
                @(posedge clk);

            @(negedge clk);
            m_axis_video_tready = 1'b0;

            while (!(m_axis_video_tvalid && !m_axis_video_tready))
                @(posedge clk);

            axi_write_w_first(
                ADDR_SOURCE_CONTROL,
                32'd0,
                4'b0001
            );

            axi_read(ADDR_SOURCE_STATUS, read_data);
            if (read_data[1:0] !== 2'b11) begin
                $display("ERROR: expected pending TPG status, got %h", read_data);
                errors = errors + 1;
            end

            @(negedge clk);
            m_axis_video_tready = 1'b1;

            polling_timeout = 64;
            read_data = 32'hFFFFFFFF;
            while ((read_data[1:0] !== 2'b00) &&
                   (polling_timeout > 0)) begin
                axi_read(ADDR_SOURCE_STATUS, read_data);
                polling_timeout = polling_timeout - 1;
            end

            if (polling_timeout == 0) begin
                $display("ERROR: timeout waiting for TPG source");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        read_data = 32'd0;
        polling_timeout = 0;

        wait (rst == 1'b0);

        // Verify reset values through the actual AXI4-Lite read interface.
        axi_read(ADDR_SOURCE_CONTROL, read_data);
        if (read_data !== 32'd0) begin
            $display("ERROR: CONTROL reset value is not TPG");
            errors = errors + 1;
        end

        axi_read(ADDR_SOURCE_STATUS, read_data);
        if (read_data[1:0] !== 2'b00) begin
            $display("ERROR: STATUS reset value is incorrect");
            errors = errors + 1;
        end

        // A write with WSTRB[0]=0 must not modify requested_source.
        axi_write_aw_first(
            ADDR_SOURCE_CONTROL,
            32'd1,
            4'b0000
        );

        axi_read(ADDR_SOURCE_CONTROL, read_data);
        if (read_data !== 32'd0) begin
            $display("ERROR: CONTROL ignored WSTRB");
            errors = errors + 1;
        end

        fork
            begin : tpg_generator
                integer frame_id;
                frame_id = 0;
                repeat (40) begin
                    send_tpg_frame(frame_id[7:0]);
                    frame_id = frame_id + 1;
                end
            end

            begin : camera_generator
                integer frame_id;
                frame_id = 0;
                repeat (40) begin
                    send_camera_frame(frame_id[7:0]);
                    frame_id = frame_id + 1;
                end
            end

            begin : controller
                run_switch_sequence;
            end
        join

        repeat (2)
            @(posedge clk);

        if (!observed_output_stall) begin
            $display("ERROR: video backpressure was not exercised");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: source_selector_axi_wrapper completed all tests");
        else
            $display(
                "FAIL: source_selector_axi_wrapper found %0d errors",
                errors
            );

        $finish;
    end

endmodule
