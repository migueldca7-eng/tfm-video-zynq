`timescale 1ns / 1ps

// Selects one of two AXI4-Stream Video sources.
//
// The requested source can change at any time, but the output only changes
// between complete video frames. TUSER marks the first pixel of a frame and
// TLAST marks the final pixel of each line.
//
// Source encoding:
//   0 = TPG
//   1 = camera
module source_selector_core #(
    parameter integer DATA_WIDTH = 24
)(
    input  wire                  clk,
    input  wire                  rst,

    // Source requested by the software-facing wrapper.
    input  wire                  requested_source,

    // AXI4-Stream Video input from the TPG.
    input  wire [DATA_WIDTH-1:0] s_axis_tpg_tdata,
    input  wire                  s_axis_tpg_tvalid,
    output reg                   s_axis_tpg_tready,
    input  wire                  s_axis_tpg_tuser,
    input  wire                  s_axis_tpg_tlast,

    // AXI4-Stream Video input from the camera.
    input  wire [DATA_WIDTH-1:0] s_axis_camera_tdata,
    input  wire                  s_axis_camera_tvalid,
    output reg                   s_axis_camera_tready,
    input  wire                  s_axis_camera_tuser,
    input  wire                  s_axis_camera_tlast,

    // Selected AXI4-Stream Video output toward the VDMA.
    output reg  [DATA_WIDTH-1:0] m_axis_video_tdata,
    output reg                   m_axis_video_tvalid,
    input  wire                  m_axis_video_tready,
    output reg                   m_axis_video_tuser,
    output reg                   m_axis_video_tlast,

    // Selector status returned to the software-facing wrapper.
    output reg                   active_source,
    output wire                  switch_pending
);

    localparam SOURCE_TPG    = 1'b0;
    localparam SOURCE_CAMERA = 1'b1;

    // The waiting states create a clean separation between the last complete
    // frame from the old source and the first complete frame from the new one.
    localparam [1:0] STATE_ACTIVE_TPG      = 2'd0;
    localparam [1:0] STATE_WAIT_CAMERA_SOF = 2'd1;
    localparam [1:0] STATE_ACTIVE_CAMERA   = 2'd2;
    localparam [1:0] STATE_WAIT_TPG_SOF    = 2'd3;

    reg [1:0] state;
    reg [1:0] next_state;

    // A switch is pending as soon as software requests a different source.
    // It remains pending while the selector searches for a clean SOF.
    assign switch_pending =
        (requested_source != active_source) ||
        (state == STATE_WAIT_CAMERA_SOF)    ||
        (state == STATE_WAIT_TPG_SOF);

    // State and active-source registers.
    always @(posedge clk) begin
        if (rst) begin
            state         <= STATE_ACTIVE_TPG;
            active_source <= SOURCE_TPG;
        end else begin
            state <= next_state;

            // active_source changes only when the first pixel of the new
            // source is already being held at its TUSER boundary.
            if ((state == STATE_WAIT_CAMERA_SOF) &&
                (next_state == STATE_ACTIVE_CAMERA)) begin
                active_source <= SOURCE_CAMERA;
            end else if ((state == STATE_WAIT_TPG_SOF) &&
                         (next_state == STATE_ACTIVE_TPG)) begin
                active_source <= SOURCE_TPG;
            end
        end
    end

    // State-transition logic.
    always @(*) begin
        next_state = state;

        case (state)
            STATE_ACTIVE_TPG: begin
                // TUSER belongs to the next TPG frame. If a camera switch is
                // pending, that pixel is not forwarded and we begin searching
                // for a camera SOF.
                if ((requested_source == SOURCE_CAMERA) &&
                    s_axis_tpg_tvalid &&
                    s_axis_tpg_tuser) begin
                    next_state = STATE_WAIT_CAMERA_SOF;
                end
            end

            STATE_WAIT_CAMERA_SOF: begin
                // The camera SOF is held with TREADY=0. On the following
                // cycle the complete camera frame can be forwarded.
                if (s_axis_camera_tvalid &&
                    s_axis_camera_tuser) begin
                    next_state = STATE_ACTIVE_CAMERA;
                end
            end

            STATE_ACTIVE_CAMERA: begin
                // The first pixel of the following camera frame marks the
                // safe point at which forwarding the camera can stop.
                if ((requested_source == SOURCE_TPG) &&
                    s_axis_camera_tvalid &&
                    s_axis_camera_tuser) begin
                    next_state = STATE_WAIT_TPG_SOF;
                end
            end

            STATE_WAIT_TPG_SOF: begin
                // Hold the next TPG SOF until the TPG becomes active.
                if (s_axis_tpg_tvalid &&
                    s_axis_tpg_tuser) begin
                    next_state = STATE_ACTIVE_TPG;
                end
            end

            default: begin
                next_state = STATE_ACTIVE_TPG;
            end
        endcase
    end

    // AXI4-Stream routing and discard logic.
    always @(*) begin
        // Safe default output: no video beat is presented to the VDMA.
        m_axis_video_tdata  = {DATA_WIDTH{1'b0}};
        m_axis_video_tvalid = 1'b0;
        m_axis_video_tuser  = 1'b0;
        m_axis_video_tlast  = 1'b0;

        // By default neither input is consumed.
        s_axis_tpg_tready    = 1'b0;
        s_axis_camera_tready = 1'b0;

        case (state)
            STATE_ACTIVE_TPG: begin
                // The unselected camera is consumed and discarded. When the
                // camera is in soft sleep, TVALID will simply remain low.
                s_axis_camera_tready = 1'b1;

                if ((requested_source == SOURCE_CAMERA) &&
                    s_axis_tpg_tvalid &&
                    s_axis_tpg_tuser) begin
                    // Do not forward the first pixel of the following TPG
                    // frame. It will be discarded after entering the wait
                    // state.
                    s_axis_tpg_tready = 1'b0;
                end else begin
                    // Transparent AXI4-Stream connection from TPG to VDMA.
                    m_axis_video_tdata  = s_axis_tpg_tdata;
                    m_axis_video_tvalid = s_axis_tpg_tvalid;
                    m_axis_video_tuser  = s_axis_tpg_tuser;
                    m_axis_video_tlast  = s_axis_tpg_tlast;
                    s_axis_tpg_tready   = m_axis_video_tready;
                end
            end

            STATE_WAIT_CAMERA_SOF: begin
                // The old TPG stream is consumed and discarded so that it
                // cannot remain permanently blocked in the middle of a frame.
                s_axis_tpg_tready = 1'b1;

                if (s_axis_camera_tvalid &&
                    s_axis_camera_tuser) begin
                    // Hold the first camera pixel until the state changes.
                    s_axis_camera_tready = 1'b0;
                end else begin
                    // Discard incomplete camera data preceding its next SOF.
                    s_axis_camera_tready = 1'b1;
                end
            end

            STATE_ACTIVE_CAMERA: begin
                // The TPG should normally be disabled by software. If it is
                // still finishing a frame, its remaining data is discarded.
                s_axis_tpg_tready = 1'b1;

                if ((requested_source == SOURCE_TPG) &&
                    s_axis_camera_tvalid &&
                    s_axis_camera_tuser) begin
                    // Do not forward the first pixel of another camera frame.
                    s_axis_camera_tready = 1'b0;
                end else begin
                    // Transparent AXI4-Stream connection from camera to VDMA.
                    m_axis_video_tdata   = s_axis_camera_tdata;
                    m_axis_video_tvalid  = s_axis_camera_tvalid;
                    m_axis_video_tuser   = s_axis_camera_tuser;
                    m_axis_video_tlast   = s_axis_camera_tlast;
                    s_axis_camera_tready = m_axis_video_tready;
                end
            end

            STATE_WAIT_TPG_SOF: begin
                // Consume and discard camera pixels while looking for a clean
                // TPG frame boundary.
                s_axis_camera_tready = 1'b1;

                if (s_axis_tpg_tvalid &&
                    s_axis_tpg_tuser) begin
                    // Hold the first TPG pixel until the state changes.
                    s_axis_tpg_tready = 1'b0;
                end else begin
                    // Discard any partial TPG frame preceding its next SOF.
                    s_axis_tpg_tready = 1'b1;
                end
            end

            default: begin
                // Safe outputs already assigned above.
            end
        endcase
    end

endmodule
