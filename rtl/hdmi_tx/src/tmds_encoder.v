`timescale 1ns / 1ps

/*
 * TMDS encoder for one colour channel.
 *
 * The encoder receives one 8-bit component per pixel clock and produces the
 * corresponding 10-bit TMDS symbol. During blanking, the colour data is
 * ignored and one of the four control tokens is emitted instead.
 *
 * Pipeline:
 *   stage 1: register the input and count its ones;
 *   stage 2: minimise transitions with an XOR/XNOR chain;
 *   stage 3: balance DC, select control/data and register the output.
 */
module tmds_encoder (
    input  wire       pixel_clk,
    input  wire       reset,

    input  wire [7:0] pixel_data,
    input  wire       data_enable,
    input  wire       control_0,
    input  wire       control_1,

    output reg  [9:0] tmds_symbol
);

    /* ---------------------------------------------------------------------
     * Pipeline stage 1: register the native-video inputs.
     * ------------------------------------------------------------------ */

    reg [7:0] data_stage1;
    reg [3:0] ones_stage1;
    reg       data_enable_stage1;
    reg       control_0_stage1;
    reg       control_1_stage1;

    wire [3:0] input_ones_count;

    assign input_ones_count =
        {3'b000, pixel_data[0]} +
        {3'b000, pixel_data[1]} +
        {3'b000, pixel_data[2]} +
        {3'b000, pixel_data[3]} +
        {3'b000, pixel_data[4]} +
        {3'b000, pixel_data[5]} +
        {3'b000, pixel_data[6]} +
        {3'b000, pixel_data[7]};

    always @(posedge pixel_clk) begin
        if (reset) begin
            data_stage1        <= 8'b0;
            ones_stage1        <= 4'b0;
            data_enable_stage1 <= 1'b0;
            control_0_stage1   <= 1'b0;
            control_1_stage1   <= 1'b0;
        end else begin
            data_stage1        <= pixel_data;
            ones_stage1        <= input_ones_count;
            data_enable_stage1 <= data_enable;
            control_0_stage1   <= control_0;
            control_1_stage1   <= control_1;
        end
    end

    /* ---------------------------------------------------------------------
     * Pipeline stage 2: minimise transitions.
     *
     * XOR is selected when the input contains relatively few ones. XNOR is
     * selected when it contains relatively few zeros. q_m[8] records which
     * operation was used so that the receiver can reverse it.
     * ------------------------------------------------------------------ */

    wire use_xnor_stage1;

    assign use_xnor_stage1 =
        (ones_stage1 > 4) ||
        ((ones_stage1 == 4) && (data_stage1[0] == 1'b0));

    reg [8:0] q_m_comb;
    integer bit_index;

    always @* begin
        /* q_m[0] is the starting point of the XOR/XNOR chain. */
        q_m_comb[0] = data_stage1[0];

        if (use_xnor_stage1) begin
            q_m_comb[8] = 1'b0;

            for (bit_index = 1; bit_index < 8; bit_index = bit_index + 1) begin
                q_m_comb[bit_index] =
                    q_m_comb[bit_index - 1] ~^ data_stage1[bit_index];
            end
        end else begin
            q_m_comb[8] = 1'b1;

            for (bit_index = 1; bit_index < 8; bit_index = bit_index + 1) begin
                q_m_comb[bit_index] =
                    q_m_comb[bit_index - 1] ^ data_stage1[bit_index];
            end
        end
    end

    wire [3:0] q_m_ones_count;
    wire [3:0] q_m_zeros_count;

    assign q_m_ones_count =
        {3'b000, q_m_comb[0]} +
        {3'b000, q_m_comb[1]} +
        {3'b000, q_m_comb[2]} +
        {3'b000, q_m_comb[3]} +
        {3'b000, q_m_comb[4]} +
        {3'b000, q_m_comb[5]} +
        {3'b000, q_m_comb[6]} +
        {3'b000, q_m_comb[7]};

    assign q_m_zeros_count = 4'd8 - q_m_ones_count;

    reg [8:0] q_m_stage2;
    reg [3:0] ones_q_m_stage2;
    reg [3:0] zeros_q_m_stage2;
    reg       data_enable_stage2;
    reg       control_0_stage2;
    reg       control_1_stage2;

    always @(posedge pixel_clk) begin
        if (reset) begin
            q_m_stage2         <= 9'b0;
            ones_q_m_stage2    <= 4'b0;
            zeros_q_m_stage2   <= 4'b0;
            data_enable_stage2 <= 1'b0;
            control_0_stage2   <= 1'b0;
            control_1_stage2   <= 1'b0;
        end else begin
            q_m_stage2         <= q_m_comb;
            ones_q_m_stage2    <= q_m_ones_count;
            zeros_q_m_stage2   <= q_m_zeros_count;
            data_enable_stage2 <= data_enable_stage1;
            control_0_stage2   <= control_0_stage1;
            control_1_stage2   <= control_1_stage1;
        end
    end

    /* ---------------------------------------------------------------------
     * Pipeline stage 3: select a control symbol or balance active data.
     *
     * running_disparity is positive after an excess of transmitted ones and
     * negative after an excess of zeros. The lower eight bits are inverted
     * whenever doing so helps compensate the accumulated imbalance.
     * ------------------------------------------------------------------ */

    reg signed [5:0] running_disparity;
    reg        [9:0] tmds_symbol_comb;

    always @* begin
        if (!data_enable_stage2) begin
            case ({control_1_stage2, control_0_stage2})
                2'b00:   tmds_symbol_comb = 10'b1101010100;
                2'b01:   tmds_symbol_comb = 10'b0010101011;
                2'b10:   tmds_symbol_comb = 10'b0101010100;
                2'b11:   tmds_symbol_comb = 10'b1010101011;
                default: tmds_symbol_comb = 10'b1101010100;
            endcase
        end else if (
            (running_disparity == 6'sd0) ||
            (ones_q_m_stage2 == zeros_q_m_stage2)
        ) begin
            if (q_m_stage2[8] == 1'b0) begin
                tmds_symbol_comb = {
                    1'b1,
                    q_m_stage2[8],
                    ~q_m_stage2[7:0]
                };
            end else begin
                tmds_symbol_comb = {
                    1'b0,
                    q_m_stage2[8],
                    q_m_stage2[7:0]
                };
            end
        end else if (
            ((running_disparity > 6'sd0) &&
             (ones_q_m_stage2 > zeros_q_m_stage2)) ||
            ((running_disparity < 6'sd0) &&
             (zeros_q_m_stage2 > ones_q_m_stage2))
        ) begin
            tmds_symbol_comb = {
                1'b1,
                q_m_stage2[8],
                ~q_m_stage2[7:0]
            };
        end else begin
            tmds_symbol_comb = {
                1'b0,
                q_m_stage2[8],
                q_m_stage2[7:0]
            };
        end
    end

    /* Count the actual ones and zeros in the selected 10-bit symbol. */
    wire [4:0] symbol_ones_count;
    wire [4:0] symbol_zeros_count;
    wire signed [5:0] symbol_disparity;

    assign symbol_ones_count =
        {4'b0000, tmds_symbol_comb[0]} +
        {4'b0000, tmds_symbol_comb[1]} +
        {4'b0000, tmds_symbol_comb[2]} +
        {4'b0000, tmds_symbol_comb[3]} +
        {4'b0000, tmds_symbol_comb[4]} +
        {4'b0000, tmds_symbol_comb[5]} +
        {4'b0000, tmds_symbol_comb[6]} +
        {4'b0000, tmds_symbol_comb[7]} +
        {4'b0000, tmds_symbol_comb[8]} +
        {4'b0000, tmds_symbol_comb[9]};

    assign symbol_zeros_count = 5'd10 - symbol_ones_count;

    assign symbol_disparity =
        $signed({1'b0, symbol_ones_count}) -
        $signed({1'b0, symbol_zeros_count});

    always @(posedge pixel_clk) begin
        if (reset) begin
            tmds_symbol       <= 10'b0;
            running_disparity <= 6'sd0;
        end else begin
            tmds_symbol <= tmds_symbol_comb;

            if (!data_enable_stage2) begin
                /* Control periods restart the data-period DC balance. */
                running_disparity <= 6'sd0;
            end else begin
                running_disparity <=
                    running_disparity + symbol_disparity;
            end
        end
    end

endmodule
