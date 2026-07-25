module tpg_core #(
    parameter integer G_WIDTH  = 640,
    parameter integer G_HEIGHT = 480
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        enable,
    input  wire        advance,

    input  wire [2:0]  pattern_select,
    input  wire [23:0] solid_color,

    output reg  [23:0] pixel_rgb,
    output reg         pixel_valid,
    output reg         frame_start,
    output reg         line_end,

    output reg  [15:0] x_pos,
    output reg  [15:0] y_pos
);

    localparam [2:0] PATTERN_BLACK          = 3'd0;
    localparam [2:0] PATTERN_SOLID          = 3'd1;
    localparam [2:0] PATTERN_VERTICAL_BARS  = 3'd2;
    localparam [2:0] PATTERN_HORIZONTAL_GRAD = 3'd3;

    reg [23:0] next_pixel_rgb;

    always @(*) begin
        case (pattern_select)
            PATTERN_BLACK: begin
                next_pixel_rgb = 24'h000000;
            end

            PATTERN_SOLID: begin
                next_pixel_rgb = solid_color;
            end

            PATTERN_VERTICAL_BARS: begin
                if (x_pos < (G_WIDTH / 4))
                    next_pixel_rgb = 24'hFF0000; // rojo
                else if (x_pos < (G_WIDTH / 2))
                    next_pixel_rgb = 24'h00FF00; // verde
                else if (x_pos < ((G_WIDTH * 3) / 4))
                    next_pixel_rgb = 24'h0000FF; // azul
                else
                    next_pixel_rgb = 24'hFFFFFF; // blanco
            end

            PATTERN_HORIZONTAL_GRAD: begin
                next_pixel_rgb = {
                    x_pos[7:0],
                    x_pos[7:0],
                    x_pos[7:0]
                };
            end

            default: begin
                next_pixel_rgb = 24'h000000;
            end
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            x_pos       <= 16'd0;
            y_pos       <= 16'd0;
            pixel_rgb   <= 24'h000000;
            pixel_valid <= 1'b0;
            frame_start <= 1'b0;
            line_end    <= 1'b0;
        end else begin
            if (!enable) begin
                x_pos       <= 16'd0;
                y_pos       <= 16'd0;
                pixel_rgb   <= 24'h000000;
                pixel_valid <= 1'b0;
                frame_start <= 1'b0;
                line_end    <= 1'b0;
            end else begin
                pixel_valid <= 1'b1;
                pixel_rgb   <= next_pixel_rgb;
                frame_start <= (x_pos == 0) && (y_pos == 0);
                line_end    <= (x_pos == G_WIDTH - 1);

                if (advance) begin
                    if (x_pos == G_WIDTH - 1) begin
                        x_pos <= 16'd0;

                        if (y_pos == G_HEIGHT - 1)
                            y_pos <= 16'd0;
                        else
                            y_pos <= y_pos + 16'd1;
                    end else begin
                        x_pos <= x_pos + 16'd1;
                    end
                end
            end
        end
    end

endmodule