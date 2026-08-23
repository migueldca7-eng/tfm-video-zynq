`timescale 1ns / 1ps

/*
 * Testbench autocorrectivo de tmds_serializer.
 *
 * La prueba usa las primitivas UNISIM reales de Xilinx. Primero mantiene una
 * palabra de preambulo hasta localizar automaticamente su frontera serie.
 * A partir de esa frontera agrupa la salida en bloques de diez flancos DDR y
 * compara las palabras reconstruidas con varios valores conocidos.
 */
module tb_tmds_serializer;

    localparam [9:0] PREAMBLE = 10'b1011001010;

    reg        pixel_clk;
    reg        serial_clk_5x;
    reg        reset;
    reg  [9:0] parallel_data;
    wire       serial_data;

    reg  [9:0] sample_window;
    reg  [9:0] reconstructed_word;
    reg  [9:0] expected_word;
    integer    sample_count;
    integer    words_checked;
    integer    error_count;
    integer    matching_preambles;
    integer    checks_requested;
    reg        aligned;
    reg        checking_enabled;

    tmds_serializer dut (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (reset),
        .parallel_data(parallel_data),
        .serial_data  (serial_data)
    );

    /* Reloj de pixel: periodo de 10 ns. */
    initial begin
        pixel_clk = 1'b0;
        forever #5 pixel_clk = ~pixel_clk;
    end

    /* Reloj serie: periodo de 2 ns, exactamente cinco veces mas rapido. */
    initial begin
        serial_clk_5x = 1'b0;
        forever #1 serial_clk_5x = ~serial_clk_5x;
    end

    /*
     * Captura DDR: este bloque se ejecuta en cada cambio del reloj serie, es
     * decir, tanto en el flanco de subida como en el de bajada. El nuevo bit
     * entra por la izquierda; despues de diez muestras, bit0 queda situado en
     * sample_window[0] y bit9 en sample_window[9].
     */
    always @(serial_clk_5x) begin
        if (!reset && !dut.serializer_reset) begin
            #0.01;
            sample_window = {serial_data, sample_window[9:1]};

            if (!aligned) begin
                /*
                 * Dos preambulos consecutivos evitan aceptar como frontera
                 * una coincidencia casual dentro de la secuencia periodica.
                 */
                if (sample_window == PREAMBLE) begin
                    matching_preambles = matching_preambles + 1;

                    if (matching_preambles == 2) begin
                        aligned = 1'b1;
                        sample_count = 0;
                    end
                end
            end else begin
                sample_count = sample_count + 1;

                if (sample_count == 10) begin
                    reconstructed_word = sample_window;
                    sample_count = 0;

                    if (checking_enabled) begin
                        words_checked = words_checked + 1;

                        if (reconstructed_word !== expected_word) begin
                            error_count = error_count + 1;
                            $display(
                                "ERROR time=%0t expected=%010b received=%010b",
                                $time,
                                expected_word,
                                reconstructed_word
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
     * Cambia la entrada, deja pasar la latencia interna del OSERDESE2 y
     * comprueba dos palabras completas mientras el valor permanece estable.
     */
    task drive_and_check_word;
        input [9:0] word_value;

        begin
            checking_enabled = 1'b0;

            @(negedge pixel_clk);
            parallel_data = word_value;

            /* Dos ciclos permiten que la nueva palabra alcance la salida. */
            repeat (2) @(posedge pixel_clk);

            expected_word = word_value;
            checks_requested = 2;
            checking_enabled = 1'b1;

            wait (checks_requested == 0);
            checking_enabled = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        parallel_data = PREAMBLE;
        sample_window = 10'b0;
        reconstructed_word = 10'b0;
        expected_word = PREAMBLE;
        sample_count = 0;
        words_checked = 0;
        error_count = 0;
        matching_preambles = 0;
        checks_requested = 0;
        aligned = 1'b0;
        checking_enabled = 1'b0;

        /* Mantener el reset durante varios ciclos de ambos relojes. */
        repeat (4) @(posedge pixel_clk);
        @(negedge pixel_clk);
        reset = 1'b0;

        /* Esperar a que el preambulo permita encontrar la frontera de palabra. */
        wait (aligned == 1'b1);

        drive_and_check_word(10'b0000000000);
        drive_and_check_word(10'b1111111111);
        drive_and_check_word(10'b0000011111);
        drive_and_check_word(10'b1111100000);
        drive_and_check_word(10'b0101010101);
        drive_and_check_word(10'b1010101010);
        drive_and_check_word(10'b1100100110);

        if (error_count == 0) begin
            $display(
                "PASS: tmds_serializer verified, %0d words checked",
                words_checked
            );
        end else begin
            $display(
                "FAIL: tmds_serializer produced %0d errors",
                error_count
            );
        end

        $finish;
    end

    /* Evita que un problema de relojes o alineamiento bloquee la simulacion. */
    initial begin
        #2000;
        $display("FAIL: tmds_serializer testbench timeout");
        $finish;
    end

endmodule
