`timescale 1ns / 1ps

/*
 * Testbench RTL del filtro de video generado por Vivado HLS.
 *
 * A diferencia del testbench C, esta prueba no asocia una salida a cada
 * llamada de funcion. Los pixeles solo se consideran transferidos cuando se
 * completa el handshake AXI4-Stream correspondiente:
 *
 *     entrada: s_axis_video_TVALID && s_axis_video_TREADY
 *     salida:  m_axis_video_TVALID && m_axis_video_TREADY
 *
 * De esta forma, la comprobacion es independiente de la latencia interna del
 * pipeline y tambien funciona durante las fases FILL y FLUSH de Sobel.
 */
module tb_video_filter_rtl;

    localparam integer CLK_PERIOD_NS     = 7;
    localparam integer VGA_WIDTH         = 640;
    localparam integer VGA_HEIGHT        = 480;
    localparam integer MAX_EXPECTED      = (VGA_WIDTH * VGA_HEIGHT) + 64;
    localparam integer DEFAULT_TIMEOUT   = 2000000;
    localparam integer SHORT_DRAIN_LIMIT = 32;

    localparam [1:0] FILTER_BYPASS       = 2'd0;
    localparam [1:0] FILTER_GRAYSCALE    = 2'd1;
    localparam [1:0] FILTER_SOBEL        = 2'd2;

    reg         ap_clk;
    reg         ap_rst_n;

    reg  [23:0] s_axis_video_TDATA;
    reg         s_axis_video_TVALID;
    wire        s_axis_video_TREADY;
    reg  [2:0]  s_axis_video_TKEEP;
    reg  [2:0]  s_axis_video_TSTRB;
    reg         s_axis_video_TUSER;
    reg         s_axis_video_TLAST;
    reg         s_axis_video_TID;
    reg         s_axis_video_TDEST;

    wire [23:0] m_axis_video_TDATA;
    wire        m_axis_video_TVALID;
    reg         m_axis_video_TREADY;
    wire [2:0]  m_axis_video_TKEEP;
    wire [2:0]  m_axis_video_TSTRB;
    wire        m_axis_video_TUSER;
    wire        m_axis_video_TLAST;
    wire        m_axis_video_TID;
    wire        m_axis_video_TDEST;

    reg  [1:0]  requested_mode_V;
    wire [1:0]  active_mode_status_V;
    wire        pending_status_V;

    integer errors;
    integer checks;
    integer expected_write_index;
    integer expected_read_index;
    integer scenario_output_count;

    /*
     * Cada entrada guarda un paquete AXI completo:
     * [23:0]  TDATA, [26:24] TKEEP, [29:27] TSTRB,
     * [30] TUSER, [31] TLAST, [32] TID y [33] TDEST.
     */
    reg [33:0] expected_packets [0:MAX_EXPECTED-1];

    video_filter dut (
        .ap_clk                    (ap_clk),
        .ap_rst_n                  (ap_rst_n),

        .s_axis_video_TDATA        (s_axis_video_TDATA),
        .s_axis_video_TVALID       (s_axis_video_TVALID),
        .s_axis_video_TREADY       (s_axis_video_TREADY),
        .s_axis_video_TKEEP        (s_axis_video_TKEEP),
        .s_axis_video_TSTRB        (s_axis_video_TSTRB),
        .s_axis_video_TUSER        (s_axis_video_TUSER),
        .s_axis_video_TLAST        (s_axis_video_TLAST),
        .s_axis_video_TID          (s_axis_video_TID),
        .s_axis_video_TDEST        (s_axis_video_TDEST),

        .m_axis_video_TDATA        (m_axis_video_TDATA),
        .m_axis_video_TVALID       (m_axis_video_TVALID),
        .m_axis_video_TREADY       (m_axis_video_TREADY),
        .m_axis_video_TKEEP        (m_axis_video_TKEEP),
        .m_axis_video_TSTRB        (m_axis_video_TSTRB),
        .m_axis_video_TUSER        (m_axis_video_TUSER),
        .m_axis_video_TLAST        (m_axis_video_TLAST),
        .m_axis_video_TID          (m_axis_video_TID),
        .m_axis_video_TDEST        (m_axis_video_TDEST),

        .requested_mode_V          (requested_mode_V),
        .active_mode_status_V      (active_mode_status_V),
        .pending_status_V          (pending_status_V)
    );

    initial begin
        ap_clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2.0) ap_clk = ~ap_clk;
    end

    function [33:0] pack_axis_packet;
        input [23:0] data;
        input        user_value;
        input        last_value;
        begin
            pack_axis_packet = {
                1'b0,          // TDEST
                1'b0,          // TID
                last_value,
                user_value,
                3'b111,        // TSTRB: los tres bytes son validos
                3'b111,        // TKEEP: conservar los tres bytes
                data
            };
        end
    endfunction

    function [23:0] grayscale_pixel;
        input [23:0] rgb;
        reg [7:0] red;
        reg [7:0] green;
        reg [7:0] blue;
        reg [15:0] weighted_sum;
        reg [7:0] gray;
        begin
            red   = rgb[23:16];
            green = rgb[15:8];
            blue  = rgb[7:0];

            /* Misma aproximacion entera utilizada por el nucleo HLS. */
            weighted_sum = (red * 77) + (green * 150) + (blue * 29);
            gray = weighted_sum >> 8;
            grayscale_pixel = {gray, gray, gray};
        end
    endfunction

    function [23:0] small_test_pixel;
        input integer x;
        input integer y;
        input integer descending;
        integer position;
        reg [7:0] red;
        reg [7:0] green;
        reg [7:0] blue;
        begin
            position = (y * 4) + x + 1;
            if (descending != 0)
                position = 13 - position;

            red   = position * 4;
            green = position * 8;
            blue  = position * 16;
            small_test_pixel = {red, green, blue};
        end
    endfunction

    function [23:0] sobel_input_pixel;
        input integer x;
        begin
            /* Imagen con una transicion vertical limpia en el centro. */
            if (x < (VGA_WIDTH / 2))
                sobel_input_pixel = 24'h000000;
            else
                sobel_input_pixel = 24'hFFFFFF;
        end
    endfunction

    function [23:0] sobel_expected_pixel;
        input integer x;
        input integer y;
        begin
            /*
             * El contorno exterior se define negro. Una transicion 0/255
             * produce saturacion Sobel en las dos columnas adyacentes.
             */
            if ((x == 0) || (x == (VGA_WIDTH - 1)) ||
                (y == 0) || (y == (VGA_HEIGHT - 1)))
                sobel_expected_pixel = 24'h000000;
            else if ((x == ((VGA_WIDTH / 2) - 1)) ||
                     (x == (VGA_WIDTH / 2)))
                sobel_expected_pixel = 24'hFFFFFF;
            else
                sobel_expected_pixel = 24'h000000;
        end
    endfunction

    task clear_expected_packets;
        begin
            expected_write_index = 0;
            expected_read_index = 0;
            scenario_output_count = 0;
        end
    endtask

    task append_expected_packet;
        input [23:0] data;
        input        user_value;
        input        last_value;
        begin
            if (expected_write_index >= MAX_EXPECTED) begin
                $display("ERROR: expected packet memory overflow");
                errors = errors + 1;
            end else begin
                expected_packets[expected_write_index] =
                    pack_axis_packet(data, user_value, last_value);
                expected_write_index = expected_write_index + 1;
            end
        end
    endtask

    task reset_dut;
        begin
            s_axis_video_TDATA  = 24'd0;
            s_axis_video_TVALID = 1'b0;
            s_axis_video_TKEEP  = 3'b111;
            s_axis_video_TSTRB  = 3'b111;
            s_axis_video_TUSER  = 1'b0;
            s_axis_video_TLAST  = 1'b0;
            s_axis_video_TID    = 1'b0;
            s_axis_video_TDEST  = 1'b0;
            m_axis_video_TREADY = 1'b1;
            requested_mode_V    = FILTER_BYPASS;

            ap_rst_n = 1'b0;
            repeat (8) @(posedge ap_clk);
            @(negedge ap_clk);
            ap_rst_n = 1'b1;
            repeat (4) @(posedge ap_clk);
        end
    endtask

    /*
     * Mantiene TVALID y todos los campos estables hasta que el DUT acepte el
     * paquete. Que TREADY tarde varios ciclos no altera el contenido enviado.
     */
    task send_axis_packet;
        input [23:0] data;
        input        user_value;
        input        last_value;
        begin
            @(negedge ap_clk);
            s_axis_video_TDATA  = data;
            s_axis_video_TKEEP  = 3'b111;
            s_axis_video_TSTRB  = 3'b111;
            s_axis_video_TUSER  = user_value;
            s_axis_video_TLAST  = last_value;
            s_axis_video_TID    = 1'b0;
            s_axis_video_TDEST  = 1'b0;
            s_axis_video_TVALID = 1'b1;

            do begin
                @(posedge ap_clk);
            end while (s_axis_video_TREADY !== 1'b1);
        end
    endtask

    task end_input_stream;
        begin
            @(negedge ap_clk);
            s_axis_video_TVALID = 1'b0;
            s_axis_video_TUSER  = 1'b0;
            s_axis_video_TLAST  = 1'b0;
        end
    endtask

    task append_small_frame_expected;
        input [1:0] mode;
        input integer descending;
        integer x;
        integer y;
        reg [23:0] source_pixel;
        reg [23:0] expected_pixel;
        begin
            for (y = 0; y < 3; y = y + 1) begin
                for (x = 0; x < 4; x = x + 1) begin
                    source_pixel = small_test_pixel(x, y, descending);
                    if (mode == FILTER_GRAYSCALE)
                        expected_pixel = grayscale_pixel(source_pixel);
                    else
                        expected_pixel = source_pixel;

                    append_expected_packet(
                        expected_pixel,
                        (x == 0) && (y == 0),
                        (x == 3)
                    );
                end
            end
        end
    endtask

    task drive_small_frame;
        input integer descending;
        input integer change_after_third_pixel;
        input [1:0] new_requested_mode;
        integer x;
        integer y;
        integer pixel_number;
        begin
            pixel_number = 0;
            for (y = 0; y < 3; y = y + 1) begin
                for (x = 0; x < 4; x = x + 1) begin
                    send_axis_packet(
                        small_test_pixel(x, y, descending),
                        (x == 0) && (y == 0),
                        (x == 3)
                    );

                    pixel_number = pixel_number + 1;
                    if ((change_after_third_pixel != 0) &&
                        (pixel_number == 3))
                        requested_mode_V = new_requested_mode;
                end
            end
            end_input_stream();
        end
    endtask

    task append_sobel_frame_expected;
        integer x;
        integer y;
        begin
            for (y = 0; y < VGA_HEIGHT; y = y + 1) begin
                for (x = 0; x < VGA_WIDTH; x = x + 1) begin
                    append_expected_packet(
                        sobel_expected_pixel(x, y),
                        (x == 0) && (y == 0),
                        (x == (VGA_WIDTH - 1))
                    );
                end
            end
        end
    endtask

    task drive_sobel_frame_and_request_bypass;
        integer x;
        integer y;
        integer pixel_number;
        begin
            pixel_number = 0;
            for (y = 0; y < VGA_HEIGHT; y = y + 1) begin
                for (x = 0; x < VGA_WIDTH; x = x + 1) begin
                    send_axis_packet(
                        sobel_input_pixel(x),
                        (x == 0) && (y == 0),
                        (x == (VGA_WIDTH - 1))
                    );

                    pixel_number = pixel_number + 1;
                    if (pixel_number == 100)
                        requested_mode_V = FILTER_BYPASS;
                end
            end
            end_input_stream();
        end
    endtask

    task wait_for_all_expected;
        input integer timeout_cycles;
        integer elapsed_cycles;
        begin
            elapsed_cycles = 0;
            while ((expected_read_index < expected_write_index) &&
                   (elapsed_cycles < timeout_cycles)) begin
                @(posedge ap_clk);
                elapsed_cycles = elapsed_cycles + 1;
            end

            if (expected_read_index != expected_write_index) begin
                $display(
                    "ERROR: timeout waiting for outputs (%0d/%0d received)",
                    expected_read_index,
                    expected_write_index
                );
                errors = errors + 1;
            end

            /* Detectar tambien una posible salida adicional inesperada. */
            repeat (12) @(posedge ap_clk);
        end
    endtask

    /*
     * El bloque ap_ctrl_none representa un flujo continuo: al retirar TVALID,
     * las ultimas operaciones de una prueba corta pueden permanecer dentro de
     * la tuberia hasta que entren nuevos tokens. Se introducen paquetes de
     * relleno solo para hacer avanzar esos resultados. En cuanto se han
     * comprobado todos los paquetes reales, se aplica reset para descartar el
     * relleno que aun quede dentro del DUT.
     */
    task drain_short_test_with_padding;
        integer padding_packets;
        begin
            padding_packets = 0;

            while ((expected_read_index < expected_write_index) &&
                   (padding_packets < SHORT_DRAIN_LIMIT)) begin
                send_axis_packet(24'h000000, 1'b0, 1'b0);

                /* Esperar al flanco opuesto evita una carrera con el monitor. */
                @(negedge ap_clk);
                s_axis_video_TVALID = 1'b0;
                padding_packets = padding_packets + 1;
            end

            if (expected_read_index != expected_write_index) begin
                $display(
                    "ERROR: short pipeline did not drain (%0d/%0d received)",
                    expected_read_index,
                    expected_write_index
                );
                errors = errors + 1;
            end

            /* El reset elimina exclusivamente los tokens de relleno. */
            ap_rst_n = 1'b0;
            repeat (3) @(posedge ap_clk);
        end
    endtask

    task run_two_equal_frames;
        input [1:0] mode;
        begin
            clear_expected_packets();
            requested_mode_V = mode;
            append_small_frame_expected(mode, 0);
            append_small_frame_expected(mode, 1);
            drive_small_frame(0, 0, mode);
            drive_small_frame(1, 0, mode);
            drain_short_test_with_padding();
        end
    endtask

    task run_frame_safe_change;
        input [1:0] first_mode;
        input [1:0] second_mode;
        begin
            clear_expected_packets();
            requested_mode_V = first_mode;
            append_small_frame_expected(first_mode, 0);
            append_small_frame_expected(second_mode, 1);
            drive_small_frame(0, 1, second_mode);
            drive_small_frame(1, 0, second_mode);
            drain_short_test_with_padding();
        end
    endtask

    /*
     * Scoreboard: solo compara cuando la salida completa un handshake. La
     * latencia del DUT puede cambiar sin obligar a modificar esta comprobacion.
     */
    always @(posedge ap_clk) begin
        if (ap_rst_n && m_axis_video_TVALID && m_axis_video_TREADY) begin
            if (expected_read_index >= expected_write_index) begin
                $display(
                    "ERROR: unexpected output packet data=0x%06h user=%0b last=%0b",
                    m_axis_video_TDATA,
                    m_axis_video_TUSER,
                    m_axis_video_TLAST
                );
                errors = errors + 1;
            end else begin
                if ({m_axis_video_TDEST,
                     m_axis_video_TID,
                     m_axis_video_TLAST,
                     m_axis_video_TUSER,
                     m_axis_video_TSTRB,
                     m_axis_video_TKEEP,
                     m_axis_video_TDATA} !==
                    expected_packets[expected_read_index]) begin

                    if (errors < 20) begin
                        $display(
                            "ERROR: output %0d expected=0x%09h actual=0x%09h",
                            scenario_output_count,
                            expected_packets[expected_read_index],
                            {m_axis_video_TDEST,
                             m_axis_video_TID,
                             m_axis_video_TLAST,
                             m_axis_video_TUSER,
                             m_axis_video_TSTRB,
                             m_axis_video_TKEEP,
                             m_axis_video_TDATA}
                        );
                    end
                    errors = errors + 1;
                end

                expected_read_index = expected_read_index + 1;
                scenario_output_count = scenario_output_count + 1;
                checks = checks + 1;
            end
        end
    end

    initial begin
        errors = 0;
        checks = 0;
        clear_expected_packets();
        ap_rst_n = 1'b0;

        $display("[1/6] Two consecutive bypass frames");
        reset_dut();
        run_two_equal_frames(FILTER_BYPASS);

        $display("[2/6] Two consecutive grayscale frames");
        reset_dut();
        run_two_equal_frames(FILTER_GRAYSCALE);

        $display("[3/6] Frame-safe bypass to grayscale change");
        reset_dut();
        run_frame_safe_change(FILTER_BYPASS, FILTER_GRAYSCALE);

        $display("[4/6] Frame-safe grayscale to bypass change");
        reset_dut();
        run_frame_safe_change(FILTER_GRAYSCALE, FILTER_BYPASS);

        $display("[5/6] Output backpressure in bypass mode");
        reset_dut();
        clear_expected_packets();
        requested_mode_V = FILTER_BYPASS;
        append_small_frame_expected(FILTER_BYPASS, 0);
        fork
            begin
                drive_small_frame(0, 0, FILTER_BYPASS);
            end
            begin
                repeat (5) @(posedge ap_clk);
                @(negedge ap_clk);
                m_axis_video_TREADY = 1'b0;
                repeat (6) @(posedge ap_clk);
                @(negedge ap_clk);
                m_axis_video_TREADY = 1'b1;
            end
        join
        drain_short_test_with_padding();

        $display("[6/6] VGA Sobel frame followed by frame-safe bypass");
        reset_dut();
        clear_expected_packets();
        requested_mode_V = FILTER_SOBEL;
        append_sobel_frame_expected();
        append_small_frame_expected(FILTER_BYPASS, 0);
        drive_sobel_frame_and_request_bypass();

        /*
         * El primer TVALID queda esperando mientras Sobel completa FLUSH.
         * Cuando se acepta su TUSER, se aplica el bypass solicitado y, al
         * mismo tiempo, avanzan las ultimas etapas del pipeline Sobel.
         */
        drive_small_frame(0, 0, FILTER_BYPASS);
        drain_short_test_with_padding();

        if (errors == 0) begin
            $display("RTL TEST PASSED: %0d AXI packets checked", checks);
            $finish;
        end else begin
            $fatal(1, "RTL TEST FAILED: %0d errors after %0d checks", errors, checks);
        end
    end

endmodule
