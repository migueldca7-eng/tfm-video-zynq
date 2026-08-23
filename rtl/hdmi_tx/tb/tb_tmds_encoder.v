`timescale 1ns / 1ps

/*
 * Self-checking testbench for tmds_encoder.
 *
 * An independent behavioural model computes the expected TMDS symbol. A
 * two-position queue accounts for the three registered stages of the DUT:
 * an input captured at one rising edge appears after the third rising edge.
 */
module tb_tmds_encoder;

    reg        pixel_clk;
    reg        reset;
    reg  [7:0] pixel_data;
    reg        data_enable;
    reg        control_0;
    reg        control_1;
    wire [9:0] tmds_symbol;

    integer error_count;
    integer checked_count;
    integer reference_disparity;

    reg [9:0] expected_delay_0;
    reg [9:0] expected_delay_1;
    reg       expected_valid_0;
    reg       expected_valid_1;

    tmds_encoder dut (
        .pixel_clk  (pixel_clk),
        .reset      (reset),
        .pixel_data (pixel_data),
        .data_enable(data_enable),
        .control_0  (control_0),
        .control_1  (control_1),
        .tmds_symbol(tmds_symbol)
    );

    initial begin
        pixel_clk = 1'b0;
        forever #5 pixel_clk = ~pixel_clk;
    end

    /*
     * Behavioural TMDS reference model.
     *
     * This task follows the DVI 1.0 decision tree, but it is kept separate
     * from the DUT pipeline so that the registered latency is also checked.
     */
    task calculate_expected_symbol;
        input  [7:0] data_value;
        input        de_value;
        input        c0_value;
        input        c1_value;
        output [9:0] expected_symbol;

        integer index;
        integer data_ones;
        integer q_m_ones;
        integer q_m_zeros;
        integer symbol_ones;
        reg [8:0] q_m;
        reg [9:0] symbol_value;

        begin
            if (!de_value) begin
                case ({c1_value, c0_value})
                    2'b00:   symbol_value = 10'b1101010100;
                    2'b01:   symbol_value = 10'b0010101011;
                    2'b10:   symbol_value = 10'b0101010100;
                    2'b11:   symbol_value = 10'b1010101011;
                    default: symbol_value = 10'b1101010100;
                endcase

                reference_disparity = 0;
            end else begin
                data_ones = 0;
                for (index = 0; index < 8; index = index + 1)
                    data_ones = data_ones + data_value[index];

                q_m[0] = data_value[0];

                if ((data_ones > 4) ||
                    ((data_ones == 4) && (data_value[0] == 1'b0))) begin
                    q_m[8] = 1'b0;
                    for (index = 1; index < 8; index = index + 1)
                        q_m[index] = q_m[index - 1] ~^ data_value[index];
                end else begin
                    q_m[8] = 1'b1;
                    for (index = 1; index < 8; index = index + 1)
                        q_m[index] = q_m[index - 1] ^ data_value[index];
                end

                q_m_ones = 0;
                for (index = 0; index < 8; index = index + 1)
                    q_m_ones = q_m_ones + q_m[index];

                q_m_zeros = 8 - q_m_ones;

                if ((reference_disparity == 0) ||
                    (q_m_ones == q_m_zeros)) begin
                    if (q_m[8] == 1'b0)
                        symbol_value = {1'b1, q_m[8], ~q_m[7:0]};
                    else
                        symbol_value = {1'b0, q_m[8], q_m[7:0]};
                end else if (
                    ((reference_disparity > 0) &&
                     (q_m_ones > q_m_zeros)) ||
                    ((reference_disparity < 0) &&
                     (q_m_zeros > q_m_ones))
                ) begin
                    symbol_value = {1'b1, q_m[8], ~q_m[7:0]};
                end else begin
                    symbol_value = {1'b0, q_m[8], q_m[7:0]};
                end

                symbol_ones = 0;
                for (index = 0; index < 10; index = index + 1)
                    symbol_ones = symbol_ones + symbol_value[index];

                reference_disparity =
                    reference_disparity + symbol_ones - (10 - symbol_ones);
            end

            expected_symbol = symbol_value;
        end
    endtask

    /* Apply one native-video cycle and check the symbol leaving the pipeline. */
    task apply_and_check;
        input [7:0] data_value;
        input       de_value;
        input       c0_value;
        input       c1_value;

        reg [9:0] expected_current;

        begin
            @(negedge pixel_clk);
            pixel_data = data_value;
            data_enable = de_value;
            control_0 = c0_value;
            control_1 = c1_value;

            calculate_expected_symbol(
                data_value,
                de_value,
                c0_value,
                c1_value,
                expected_current
            );

            @(posedge pixel_clk);
            #1;

            if (expected_valid_1) begin
                checked_count = checked_count + 1;

                if (tmds_symbol !== expected_delay_1) begin
                    error_count = error_count + 1;
                    $display(
                        "ERROR cycle=%0t expected=%010b received=%010b",
                        $time,
                        expected_delay_1,
                        tmds_symbol
                    );
                end
            end

            expected_delay_1 = expected_delay_0;
            expected_valid_1 = expected_valid_0;
            expected_delay_0 = expected_current;
            expected_valid_0 = 1'b1;
        end
    endtask

    initial begin
        reset = 1'b1;
        pixel_data = 8'b0;
        data_enable = 1'b0;
        control_0 = 1'b0;
        control_1 = 1'b0;

        error_count = 0;
        checked_count = 0;
        reference_disparity = 0;
        expected_delay_0 = 10'b0;
        expected_delay_1 = 10'b0;
        expected_valid_0 = 1'b0;
        expected_valid_1 = 1'b0;

        /* Verify that reset clears the registered output. */
        repeat (4) @(posedge pixel_clk);
        #1;
        if (tmds_symbol !== 10'b0) begin
            error_count = error_count + 1;
            $display("ERROR reset output=%010b", tmds_symbol);
        end

        @(negedge pixel_clk);
        reset = 1'b0;

        /* All four control tokens. Each one also resets DC disparity. */
        apply_and_check(8'h00, 1'b0, 1'b0, 1'b0);
        apply_and_check(8'h00, 1'b0, 1'b1, 1'b0);
        apply_and_check(8'h00, 1'b0, 1'b0, 1'b1);
        apply_and_check(8'h00, 1'b0, 1'b1, 1'b1);

        /* Active-data patterns covering XOR, XNOR and both tie cases. */
        apply_and_check(8'h00, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'hFF, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h0F, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'hF0, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h55, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'hAA, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h81, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h7E, 1'b1, 1'b0, 1'b0);

        /* Repeated values exercise both signs of running disparity. */
        apply_and_check(8'hFF, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'hFF, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h00, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'h00, 1'b1, 1'b0, 1'b0);

        /* A blanking symbol resets disparity before a second data sequence. */
        apply_and_check(8'hA5, 1'b0, 1'b0, 1'b0);
        apply_and_check(8'h33, 1'b1, 1'b0, 1'b0);
        apply_and_check(8'hCC, 1'b1, 1'b0, 1'b0);

        /* Two extra cycles flush the last expected symbols from the pipeline. */
        apply_and_check(8'h00, 1'b0, 1'b0, 1'b0);
        apply_and_check(8'h00, 1'b0, 1'b0, 1'b0);

        if (error_count == 0) begin
            $display(
                "PASS: tmds_encoder verified, %0d symbols checked",
                checked_count
            );
        end else begin
            $display(
                "FAIL: tmds_encoder produced %0d errors",
                error_count
            );
        end

        $finish;
    end

endmodule
