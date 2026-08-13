`timescale 1ns / 1ps

module tb_source_selector_core;

    localparam integer DATA_WIDTH   = 24;
    localparam integer FRAME_WIDTH  = 4;
    localparam integer FRAME_HEIGHT = 3;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

    localparam SOURCE_TPG    = 1'b0;
    localparam SOURCE_CAMERA = 1'b1;

    reg clk;
    reg rst;
    reg requested_source;

    // TPG AXI4-Stream input.
    reg  [DATA_WIDTH-1:0] s_axis_tpg_tdata;
    reg                   s_axis_tpg_tvalid;
    wire                  s_axis_tpg_tready;
    reg                   s_axis_tpg_tuser;
    reg                   s_axis_tpg_tlast;

    // Camera AXI4-Stream input.
    reg  [DATA_WIDTH-1:0] s_axis_camera_tdata;
    reg                   s_axis_camera_tvalid;
    wire                  s_axis_camera_tready;
    reg                   s_axis_camera_tuser;
    reg                   s_axis_camera_tlast;

    // Selected output.
    wire [DATA_WIDTH-1:0] m_axis_video_tdata;
    wire                  m_axis_video_tvalid;
    reg                   m_axis_video_tready;
    wire                  m_axis_video_tuser;
    wire                  m_axis_video_tlast;

    wire active_source;
    wire switch_pending;

    wire output_transfer;

    integer errors;
    integer output_transfers;
    integer frame_pixel_count;

    reg frame_seen;
    reg expected_source;
    reg check_first_pixel;

    // Variables used to check that a stalled AXI beat remains stable.
    reg                  stalled_previous;
    reg [DATA_WIDTH-1:0] held_data;
    reg                  held_user;
    reg                  held_last;
    reg                  observed_output_stall;

    assign output_transfer =
        m_axis_video_tvalid &&
        m_axis_video_tready;

    source_selector_core #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .requested_source       (requested_source),

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
        .m_axis_video_tlast     (m_axis_video_tlast),

        .active_source          (active_source),
        .switch_pending         (switch_pending)
    );

    // 100 MHz simulation clock.
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Reset and initial input values.
    initial begin
        rst = 1'b1;
        requested_source = SOURCE_TPG;
        m_axis_video_tready = 1'b1;

        s_axis_tpg_tdata  = 24'd0;
        s_axis_tpg_tvalid = 1'b0;
        s_axis_tpg_tuser  = 1'b0;
        s_axis_tpg_tlast  = 1'b0;

        s_axis_camera_tdata  = 24'd0;
        s_axis_camera_tvalid = 1'b0;
        s_axis_camera_tuser  = 1'b0;
        s_axis_camera_tlast  = 1'b0;

        repeat (5)
            @(posedge clk);

        @(negedge clk);
        rst = 1'b0;
    end

    // Sends one AXI4-Stream beat from the TPG.
    // All signals remain stable until the selector asserts TREADY.
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

    // Sends one AXI4-Stream beat from the camera.
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

    // Generates a complete 4x3 TPG frame.
    // TPG pixels are identified by the most significant byte 0x10.
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

    // Generates a complete 4x3 camera frame.
    // Camera pixels are identified by the most significant byte 0xCA.
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

    // Waits until the requested source becomes active and arms the monitor
    // before the first output beat of the new source can be accepted.
    task wait_for_source;
        input source;
        begin
            while (active_source !== source)
                @(negedge clk);

            expected_source   = source;
            check_first_pixel = 1'b1;

            #1;
            if (switch_pending !== 1'b0) begin
                $display("ERROR: switch_pending remained active");
                errors = errors + 1;
            end
        end
    endtask

    // Automatic output monitor.
    always @(posedge clk) begin
        if (rst) begin
            output_transfers      = 0;
            frame_pixel_count     = 0;
            frame_seen            = 1'b0;
            stalled_previous      = 1'b0;
            observed_output_stall = 1'b0;
        end else begin
            // If the previous cycle was stalled, every AXI signal must remain
            // stable until the downstream slave accepts the beat.
            if (stalled_previous) begin
                if (!m_axis_video_tvalid ||
                    m_axis_video_tdata !== held_data ||
                    m_axis_video_tuser !== held_user ||
                    m_axis_video_tlast !== held_last) begin
                    $display("ERROR: output changed during backpressure");
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

                // Check that data belongs to the active source.
                if ((active_source == SOURCE_TPG) &&
                    (m_axis_video_tdata[23:16] !== 8'h10)) begin
                    $display("ERROR: camera data received while TPG is active");
                    errors = errors + 1;
                end

                if ((active_source == SOURCE_CAMERA) &&
                    (m_axis_video_tdata[23:16] !== 8'hCA)) begin
                    $display("ERROR: TPG data received while camera is active");
                    errors = errors + 1;
                end

                // The first accepted pixel after a source change must be the
                // first pixel of a complete frame from the requested source.
                if (check_first_pixel) begin
                    if (active_source !== expected_source) begin
                        $display("ERROR: unexpected source after switch");
                        errors = errors + 1;
                    end

                    if (m_axis_video_tuser !== 1'b1) begin
                        $display("ERROR: new source did not start with TUSER");
                        errors = errors + 1;
                    end

                    if (m_axis_video_tdata[7:0] !== 8'd0) begin
                        $display("ERROR: new source started at a partial frame");
                        errors = errors + 1;
                    end

                    check_first_pixel = 1'b0;
                end

                // A new TUSER is legal only after exactly one complete frame.
                if (m_axis_video_tuser) begin
                    if (frame_seen &&
                        frame_pixel_count != FRAME_PIXELS) begin
                        $display(
                            "ERROR: previous frame had %0d pixels",
                            frame_pixel_count
                        );
                        errors = errors + 1;
                    end

                    frame_seen        = 1'b1;
                    frame_pixel_count = 0;
                end else if (!frame_seen) begin
                    $display("ERROR: output started without TUSER");
                    errors = errors + 1;
                end

                // TLAST must appear at positions 3, 7 and 11.
                if (m_axis_video_tlast !==
                    ((frame_pixel_count % FRAME_WIDTH) ==
                     (FRAME_WIDTH - 1))) begin
                    $display(
                        "ERROR: incorrect TLAST at frame pixel %0d",
                        frame_pixel_count
                    );
                    errors = errors + 1;
                end

                frame_pixel_count = frame_pixel_count + 1;

                if (frame_pixel_count > FRAME_PIXELS) begin
                    $display("ERROR: frame exceeded expected size");
                    errors = errors + 1;
                end
            end
        end
    end

    // Requests both source changes and introduces output backpressure.
    task run_control_sequence;
        begin
            wait (rst == 1'b0);
            @(negedge clk);

            if (active_source !== SOURCE_TPG ||
                switch_pending !== 1'b0) begin
                $display("ERROR: incorrect state after reset");
                errors = errors + 1;
            end

            // Allow several initial TPG pixels to pass.
            while (output_transfers < 4)
                @(negedge clk);

            // Stall the output for three cycles.
            @(negedge clk);
            m_axis_video_tready = 1'b0;

            repeat (3)
                @(posedge clk);

            @(negedge clk);
            m_axis_video_tready = 1'b1;

            // Request camera while a TPG frame is in progress.
            while (!(output_transfer &&
                     active_source == SOURCE_TPG &&
                     !m_axis_video_tuser))
                @(posedge clk);

            @(negedge clk);
            requested_source = SOURCE_CAMERA;

            #1;
            if (switch_pending !== 1'b1) begin
                $display("ERROR: camera request did not become pending");
                errors = errors + 1;
            end

            wait_for_source(SOURCE_CAMERA);

            // Wait until the first complete camera-frame pixel is checked.
            while (check_first_pixel)
                @(negedge clk);

            // Request the TPG while a camera frame is in progress.
            while (!(output_transfer &&
                     active_source == SOURCE_CAMERA &&
                     !m_axis_video_tuser))
                @(posedge clk);

            @(negedge clk);
            requested_source = SOURCE_TPG;

            #1;
            if (switch_pending !== 1'b1) begin
                $display("ERROR: TPG request did not become pending");
                errors = errors + 1;
            end

            wait_for_source(SOURCE_TPG);

            while (check_first_pixel)
                @(negedge clk);
        end
    endtask

    // Run both video sources in parallel with the control sequence.
    initial begin
        errors            = 0;
        expected_source   = SOURCE_TPG;
        check_first_pixel = 1'b0;

        wait (rst == 1'b0);

        fork
            begin : tpg_generator
                integer frame_id;

                frame_id = 0;
                repeat (20) begin
                    send_tpg_frame(frame_id[7:0]);
                    frame_id = frame_id + 1;
                end
            end

            begin : camera_generator
                integer frame_id;

                frame_id = 0;
                repeat (20) begin
                    send_camera_frame(frame_id[7:0]);
                    frame_id = frame_id + 1;
                end
            end

            begin : controller
                run_control_sequence;
            end
        join

        repeat (2)
            @(posedge clk);

        if (!observed_output_stall) begin
            $display("ERROR: backpressure test was not exercised");
            errors = errors + 1;
        end

        if (check_first_pixel) begin
            $display("ERROR: final source SOF was never received");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: source_selector_core completed all tests");
        else
            $display(
                "FAIL: source_selector_core found %0d errors",
                errors
            );

        $finish;
    end

endmodule
