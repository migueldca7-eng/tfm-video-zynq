`timescale 1ns / 1ps

/*
 * Testbench autocorrectivo de la capa superior del transmisor HDMI/DVI.
 *
 * Las pruebas unitarias de tmds_encoder y tmds_serializer verifican sus
 * algoritmos internos. Este testbench se centra en su integracion: mapa RGB,
 * control de reset, correspondencia de canales, reloj TMDS y conversion a
 * pares diferenciales.
 */
module tb_hdmi_tx_rtl;

    localparam [9:0] CLOCK_PATTERN = 10'b1111100000;
    localparam [9:0] CONTROL_00    = 10'b1101010100;

    reg         pixel_clk;
    reg         serial_clk_5x;
    reg         reset;
    reg         locked;
    reg  [23:0] video_data;
    reg         video_active;
    reg         hsync;
    reg         vsync;

    wire HDMI_CLK_P;
    wire HDMI_CLK_N;
    wire HDMI_D2_P;
    wire HDMI_D2_N;
    wire HDMI_D1_P;
    wire HDMI_D1_N;
    wire HDMI_D0_P;
    wire HDMI_D0_N;

    reg [9:0] clock_window;
    reg [9:0] red_window;
    reg [9:0] green_window;
    reg [9:0] blue_window;

    reg [9:0] reconstructed_clock;
    reg [9:0] reconstructed_red;
    reg [9:0] reconstructed_green;
    reg [9:0] reconstructed_blue;
    reg [9:0] expected_blue_control;

    integer sample_count;
    integer matching_clock_patterns;
    integer words_checked;
    integer checks_requested;
    integer differential_checks;
    integer error_count;
    reg     aligned;
    reg     checking_enabled;

    hdmi_tx_rtl dut (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (reset),
        .locked       (locked),
        .video_data   (video_data),
        .video_active (video_active),
        .hsync        (hsync),
        .vsync        (vsync),
        .HDMI_CLK_P   (HDMI_CLK_P),
        .HDMI_CLK_N   (HDMI_CLK_N),
        .HDMI_D2_P    (HDMI_D2_P),
        .HDMI_D2_N    (HDMI_D2_N),
        .HDMI_D1_P    (HDMI_D1_P),
        .HDMI_D1_N    (HDMI_D1_N),
        .HDMI_D0_P    (HDMI_D0_P),
        .HDMI_D0_N    (HDMI_D0_N)
    );

    /* Reloj de pixel: periodo de 10 ns. */
    initial begin
        pixel_clk = 1'b0;
        forever #5 pixel_clk = ~pixel_clk;
    end

    /* Reloj de serializacion: periodo de 2 ns, cinco veces mas rapido. */
    initial begin
        serial_clk_5x = 1'b0;
        forever #1 serial_clk_5x = ~serial_clk_5x;
    end

    /*
     * Los cuatro OBUFDS deben producir pares complementarios. Solo se realiza
     * la comprobacion cuando la salida positiva ya contiene un valor conocido.
     */
    task check_differential_pair;
        input positive_output;
        input negative_output;
        input [8*12-1:0] pair_name;

        begin
            if ((positive_output === 1'b0) ||
                (positive_output === 1'b1)) begin
                differential_checks = differential_checks + 1;

                if (negative_output !== ~positive_output) begin
                    error_count = error_count + 1;
                    $display(
                        "ERROR time=%0t differential pair %0s is not complementary",
                        $time,
                        pair_name
                    );
                end
            end
        end
    endtask

    /*
     * Captura DDR de los cuatro canales. El patron fijo del reloj permite
     * localizar automaticamente la frontera entre palabras de diez bits.
     */
    always @(serial_clk_5x) begin
        if (!dut.tx_reset &&
            !dut.clock_serializer.serializer_reset) begin
            #0.01;

            check_differential_pair(HDMI_CLK_P, HDMI_CLK_N, "HDMI_CLK");
            check_differential_pair(HDMI_D2_P,  HDMI_D2_N,  "HDMI_D2");
            check_differential_pair(HDMI_D1_P,  HDMI_D1_N,  "HDMI_D1");
            check_differential_pair(HDMI_D0_P,  HDMI_D0_N,  "HDMI_D0");

            clock_window = {HDMI_CLK_P, clock_window[9:1]};
            red_window   = {HDMI_D2_P,  red_window[9:1]};
            green_window = {HDMI_D1_P,  green_window[9:1]};
            blue_window  = {HDMI_D0_P,  blue_window[9:1]};

            if (!aligned) begin
                /* Dos coincidencias evitan aceptar una frontera accidental. */
                if (clock_window == CLOCK_PATTERN) begin
                    matching_clock_patterns = matching_clock_patterns + 1;

                    if (matching_clock_patterns == 2) begin
                        aligned = 1'b1;
                        sample_count = 0;
                    end
                end
            end else begin
                sample_count = sample_count + 1;

                if (sample_count == 10) begin
                    reconstructed_clock = clock_window;
                    reconstructed_red   = red_window;
                    reconstructed_green = green_window;
                    reconstructed_blue  = blue_window;
                    sample_count = 0;

                    if (reconstructed_clock !== CLOCK_PATTERN) begin
                        error_count = error_count + 1;
                        $display(
                            "ERROR time=%0t clock expected=%010b received=%010b",
                            $time,
                            CLOCK_PATTERN,
                            reconstructed_clock
                        );
                    end

                    if (checking_enabled) begin
                        words_checked = words_checked + 1;

                        if (reconstructed_red !== CONTROL_00) begin
                            error_count = error_count + 1;
                            $display(
                                "ERROR time=%0t red control expected=%010b received=%010b",
                                $time,
                                CONTROL_00,
                                reconstructed_red
                            );
                        end

                        if (reconstructed_green !== CONTROL_00) begin
                            error_count = error_count + 1;
                            $display(
                                "ERROR time=%0t green control expected=%010b received=%010b",
                                $time,
                                CONTROL_00,
                                reconstructed_green
                            );
                        end

                        if (reconstructed_blue !== expected_blue_control) begin
                            error_count = error_count + 1;
                            $display(
                                "ERROR time=%0t blue control expected=%010b received=%010b",
                                $time,
                                expected_blue_control,
                                reconstructed_blue
                            );
                        end

                        if (checks_requested > 0)
                            checks_requested = checks_requested - 1;
                    end
                end
            end
        end
    end

    /*
     * Aplica una combinacion de HSYNC/VSYNC durante el borrado. Se dejan pasar
     * los registros del codificador y del OSERDESE2 antes de comprobar dos
     * simbolos completos estables.
     */
    task drive_and_check_control;
        input control_0_value;
        input control_1_value;
        input [9:0] expected_token;

        begin
            checking_enabled = 1'b0;

            @(negedge pixel_clk);
            video_active = 1'b0;
            hsync = control_0_value;
            vsync = control_1_value;

            repeat (7) @(posedge pixel_clk);

            expected_blue_control = expected_token;
            checks_requested = 2;
            checking_enabled = 1'b1;

            wait (checks_requested == 0);
            checking_enabled = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        locked = 1'b0;
        video_data = 24'h123456;
        video_active = 1'b0;
        hsync = 1'b0;
        vsync = 1'b0;

        clock_window = 10'b0;
        red_window = 10'b0;
        green_window = 10'b0;
        blue_window = 10'b0;
        reconstructed_clock = 10'b0;
        reconstructed_red = 10'b0;
        reconstructed_green = 10'b0;
        reconstructed_blue = 10'b0;
        expected_blue_control = CONTROL_00;

        sample_count = 0;
        matching_clock_patterns = 0;
        words_checked = 0;
        checks_requested = 0;
        differential_checks = 0;
        error_count = 0;
        aligned = 1'b0;
        checking_enabled = 1'b0;

        /* locked=0 debe mantener activo el reset interno. */
        #1;
        if (dut.tx_reset !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: tx_reset must be active while locked=0");
        end

        repeat (3) @(posedge pixel_clk);
        @(negedge pixel_clk);
        reset = 1'b0;

        #0.1;
        if (dut.tx_reset !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR: locked=0 did not hold tx_reset active");
        end

        locked = 1'b1;
        #0.1;
        if (dut.tx_reset !== 1'b0) begin
            error_count = error_count + 1;
            $display("ERROR: tx_reset did not clear after clock lock");
        end

        /* Comprobar el reparto directo del bus RGB888. */
        if ((dut.red_pixel   !== 8'h12) ||
            (dut.green_pixel !== 8'h34) ||
            (dut.blue_pixel  !== 8'h56)) begin
            error_count = error_count + 1;
            $display("ERROR: RGB888 channel mapping is incorrect");
        end

        /* Esperar la liberacion sincronizada de los serializadores. */
        wait (dut.clock_serializer.serializer_reset == 1'b0);
        wait (aligned == 1'b1);

        /* Probar los cuatro tokens de control definidos por DVI/HDMI. */
        drive_and_check_control(1'b0, 1'b0, 10'b1101010100);
        drive_and_check_control(1'b1, 1'b0, 10'b0010101011);
        drive_and_check_control(1'b0, 1'b1, 10'b0101010100);
        drive_and_check_control(1'b1, 1'b1, 10'b1010101011);

        if ((error_count == 0) &&
            (words_checked == 8) &&
            (differential_checks > 0)) begin
            $display(
                "PASS: hdmi_tx_rtl verified, %0d control words checked",
                words_checked
            );
        end else begin
            $display(
                "FAIL: hdmi_tx_rtl errors=%0d words=%0d differential_checks=%0d",
                error_count,
                words_checked,
                differential_checks
            );
        end

        $finish;
    end

    /* Evita que un error de alineamiento o de relojes bloquee la prueba. */
    initial begin
        #5000;
        $display("FAIL: hdmi_tx_rtl testbench timeout");
        $finish;
    end

endmodule
