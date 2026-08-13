`timescale 1ns / 1ps

// Adapts the TPG core signals to an AXI4-Stream Video interface.
module tpg_axis_wrapper #(
    parameter integer G_WIDTH  = 640,
    parameter integer G_HEIGHT = 480
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_sync_async,

    // AXI4-Lite slave write-address channel.
    input  wire [4:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    // AXI4-Lite slave write-data channel.
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    // AXI4-Lite slave write-response channel.
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Lite slave read-address channel.
    input  wire [4:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // AXI4-Lite slave read-data channel.
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire [23:0] m_axis_video_tdata,
    output wire        m_axis_video_tvalid,
    input  wire        m_axis_video_tready,
    output wire        m_axis_video_tuser,
    output wire        m_axis_video_tlast,

    output wire [15:0] dbg_x_pos,
    output wire [15:0] dbg_y_pos
);

    // AXI-Lite register offsets.
    localparam [4:0] ADDR_ENABLE        = 5'h00;
    localparam [4:0] ADDR_PATTERN       = 5'h04;
    localparam [4:0] ADDR_SOLID_COLOR   = 5'h08;
    localparam [4:0] ADDR_TEMPORAL_STEP = 5'h0C;
    localparam [4:0] ADDR_STATUS        = 5'h10;
    localparam [4:0] ADDR_FRAME_PHASE   = 5'h14;
    localparam [4:0] ADDR_FRAME_SIZE    = 5'h18;

    // Internal connection between the TPG core and the AXI output.
    wire [23:0] pixel_rgb;
    wire        pixel_valid;
    wire        frame_start;
    wire        line_end;
    wire        advance;
    wire        core_busy;
    wire        frame_done;
    wire [7:0]  core_frame_phase;

    // Independently captured AXI-Lite write address and data.
    reg [4:0]  awaddr_reg;
    reg [31:0] wdata_reg;
    reg [3:0]  wstrb_reg;
    reg        aw_captured;
    reg        w_captured;

    // ENABLE acts directly, while the remaining configuration is double
    // buffered so it cannot change in the middle of an active video frame.
    reg        enable_reg;
    reg [2:0]  requested_pattern;
    reg [23:0] requested_solid_color;
    reg [7:0]  requested_temporal_step;
    reg [15:0] requested_width;
    reg [15:0] requested_height;
    reg [2:0]  active_pattern;
    reg [23:0] active_solid_color;
    reg [7:0]  active_temporal_step;
    reg [15:0] active_width;
    reg [15:0] active_height;
    reg        config_pending;

    // Two-stage synchronizer for the asynchronous VTC frame-sync signal.
    (* ASYNC_REG = "TRUE" *) reg frame_sync_ff1;
    (* ASYNC_REG = "TRUE" *) reg frame_sync_ff2;
    reg  frame_sync_previous;
    wire frame_tick;

    always @(posedge clk) begin
        if (rst) begin
            frame_sync_ff1      <= 1'b0;
            frame_sync_ff2      <= 1'b0;
            frame_sync_previous <= 1'b0;
        end else begin
            frame_sync_ff1      <= frame_sync_async;
            frame_sync_ff2      <= frame_sync_ff1;
            frame_sync_previous <= frame_sync_ff2;
        end
    end

    // Converts the synchronized frame-sync rising edge into a one-cycle pulse.
    assign frame_tick = frame_sync_ff2 && !frame_sync_previous;

    // AXI4-Stream handshake:
    // a pixel is consumed only when TVALID and TREADY are both high.
    assign advance = m_axis_video_tvalid && m_axis_video_tready;

    // AXI-Lite write transaction control. The address and data channels are
    // captured independently because their handshakes may occur separately.
    always @(posedge clk) begin
        if (rst) begin
            s_axi_awready <= 1'b1;
            s_axi_wready  <= 1'b1;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;

            awaddr_reg  <= 5'd0;
            wdata_reg   <= 32'd0;
            wstrb_reg   <= 4'd0;
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;
        end else begin
            // Capture the write address independently.
            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_reg    <= s_axi_awaddr;
                aw_captured   <= 1'b1;
                s_axi_awready <= 1'b0;
            end

            // Capture the write data independently.
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_reg    <= s_axi_wdata;
                wstrb_reg    <= s_axi_wstrb;
                w_captured   <= 1'b1;
                s_axi_wready <= 1'b0;
            end

            // Once both pieces have arrived, commit the write and return OKAY.
            if (aw_captured && w_captured) begin
                aw_captured  <= 1'b0;
                w_captured   <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end

            // Rearm both request channels after the response is accepted.
            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid  <= 1'b0;
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
            end
        end
    end

    // TPG configuration registers. Software writes requested values
    // immediately, but the core only receives them at a safe frame boundary.
    always @(posedge clk) begin
        if (rst) begin
            enable_reg              <= 1'b0;
            requested_pattern       <= 3'd2;
            requested_solid_color   <= 24'h00FF00;
            requested_temporal_step <= 8'd1;
            requested_width         <= G_WIDTH;
            requested_height        <= G_HEIGHT;
            active_pattern          <= 3'd2;
            active_solid_color      <= 24'h00FF00;
            active_temporal_step    <= 8'd1;
            active_width            <= G_WIDTH;
            active_height           <= G_HEIGHT;
            config_pending          <= 1'b0;
        end else begin
            // Apply any pending configuration between frames. The idle check
            // also covers a write made exactly on the frame_done clock edge.
            if (frame_done || (!core_busy && config_pending)) begin
                active_pattern       <= requested_pattern;
                active_solid_color   <= requested_solid_color;
                active_temporal_step <= requested_temporal_step;
                active_width         <= requested_width;
                active_height        <= requested_height;
                config_pending       <= 1'b0;
            end

            // Both halves of the AXI-Lite write have been captured.
            if (aw_captured && w_captured) begin
                case (awaddr_reg)
                    ADDR_ENABLE: begin
                        // Disabling prevents new frames, while the core itself
                        // guarantees that the current frame is completed.
                        if (wstrb_reg[0])
                            enable_reg <= wdata_reg[0];
                    end

                    ADDR_PATTERN: begin
                        if (wstrb_reg[0]) begin
                            requested_pattern <= wdata_reg[2:0];

                            if (core_busy)
                                config_pending <= 1'b1;
                            else
                                active_pattern <= wdata_reg[2:0];
                        end
                    end

                    ADDR_SOLID_COLOR: begin
                        // Each WSTRB bit enables its corresponding data byte.
                        if (wstrb_reg[0]) begin
                            requested_solid_color[7:0] <= wdata_reg[7:0];

                            if (!core_busy)
                                active_solid_color[7:0] <= wdata_reg[7:0];
                        end

                        if (wstrb_reg[1]) begin
                            requested_solid_color[15:8] <= wdata_reg[15:8];

                            if (!core_busy)
                                active_solid_color[15:8] <= wdata_reg[15:8];
                        end

                        if (wstrb_reg[2]) begin
                            requested_solid_color[23:16] <= wdata_reg[23:16];

                            if (!core_busy)
                                active_solid_color[23:16] <= wdata_reg[23:16];
                        end

                        if (core_busy && |wstrb_reg[2:0])
                            config_pending <= 1'b1;
                    end

                    ADDR_TEMPORAL_STEP: begin
                        if (wstrb_reg[0]) begin
                            requested_temporal_step <= wdata_reg[7:0];

                            if (core_busy)
                                config_pending <= 1'b1;
                            else
                                active_temporal_step <= wdata_reg[7:0];
                        end
                    end

                    ADDR_FRAME_SIZE: begin
                        // Width and height form one configuration value, so
                        // software must write all four bytes together. Zero
                        // dimensions are ignored to avoid counter underflow.
                        if ((wstrb_reg == 4'b1111) &&
                            (wdata_reg[15:0]  != 16'd0) &&
                            (wdata_reg[31:16] != 16'd0)) begin
                            requested_width  <= wdata_reg[15:0];
                            requested_height <= wdata_reg[31:16];

                            if (core_busy) begin
                                config_pending <= 1'b1;
                            end else begin
                                active_width  <= wdata_reg[15:0];
                                active_height <= wdata_reg[31:16];
                            end
                        end
                    end

                    default: begin
                        // Writes to read-only or undefined addresses are ignored.
                    end
                endcase
            end
        end
    end

    // AXI-Lite read transaction control. The selected register value is held
    // stable until the master accepts it through the R-channel handshake.
    always @(posedge clk) begin
        if (rst) begin
            s_axi_arready <= 1'b1;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1'b0;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                case (s_axi_araddr)
                    ADDR_ENABLE:
                        s_axi_rdata <= {31'd0, enable_reg};

                    ADDR_PATTERN:
                        s_axi_rdata <= {29'd0, requested_pattern};

                    ADDR_SOLID_COLOR:
                        s_axi_rdata <= {8'd0, requested_solid_color};

                    ADDR_TEMPORAL_STEP:
                        s_axi_rdata <= {24'd0, requested_temporal_step};

                    ADDR_STATUS:
                        s_axi_rdata <= {30'd0, config_pending, core_busy};

                    ADDR_FRAME_PHASE:
                        s_axi_rdata <= {24'd0, core_frame_phase};

                    ADDR_FRAME_SIZE:
                        s_axi_rdata <= {requested_height, requested_width};

                    default:
                        s_axi_rdata <= 32'd0;
                endcase
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid  <= 1'b0;
                s_axi_arready <= 1'b1;
            end
        end
    end

    // Test-pattern generator core.
    tpg_core u_tpg_core (
        .clk(clk),
        .rst(rst),
        .enable(enable_reg),
        .advance(advance),
        .start_frame(frame_tick),
        .pattern_select(active_pattern),
        .solid_color(active_solid_color),
        .temporal_step(active_temporal_step),
        .active_width(active_width),
        .active_height(active_height),
        .pixel_rgb(pixel_rgb),
        .pixel_valid(pixel_valid),
        .frame_start(frame_start),
        .line_end(line_end),
        .busy_out(core_busy),
        .frame_done(frame_done),
        .frame_phase_out(core_frame_phase),
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
