`timescale 1ns / 1ps

/*
 * Transmisor HDMI/DVI de video sin audio.
 *
 * Este modulo es la capa estructural del transmisor: separa el bus RGB888,
 * codifica los tres canales mediante TMDS, serializa los simbolos de 10 bits
 * y convierte las cuatro senales serie en pares diferenciales fisicos.
 *
 * Correspondencia de canales TMDS:
 *   D2: componente roja;
 *   D1: componente verde;
 *   D0: componente azul y sincronismos durante el intervalo de borrado;
 *   CLK: reloj de pixel reenviado mediante un patron serie fijo.
 */
module hdmi_tx_rtl (
    input  wire        pixel_clk,
    input  wire        serial_clk_5x,
    input  wire        reset,
    input  wire        locked,

    input  wire [23:0] video_data,
    input  wire        video_active,
    input  wire        hsync,
    input  wire        vsync,

    output wire        HDMI_CLK_P,
    output wire        HDMI_CLK_N,
    output wire        HDMI_D2_P,
    output wire        HDMI_D2_N,
    output wire        HDMI_D1_P,
    output wire        HDMI_D1_N,
    output wire        HDMI_D0_P,
    output wire        HDMI_D0_N
);

    /*
     * El transmisor permanece reseteado mientras el reset externo este
     * activo o el Clock Wizard no haya estabilizado sus salidas.
     */
    wire tx_reset;
    assign tx_reset = reset | ~locked;

    /* Separacion del bus RGB888 procedente de AXI4-Stream to Video Out. */
    wire [7:0] red_pixel;
    wire [7:0] green_pixel;
    wire [7:0] blue_pixel;

    assign red_pixel   = video_data[23:16];
    assign green_pixel = video_data[15:8];
    assign blue_pixel  = video_data[7:0];

    /* Simbolos paralelos producidos por los tres codificadores TMDS. */
    wire [9:0] red_tmds_symbol;
    wire [9:0] green_tmds_symbol;
    wire [9:0] blue_tmds_symbol;

    /*
     * Los canales rojo y verde solo transportan datos de color. Durante el
     * borrado emiten el token de control 00. El canal azul transporta tambien
     * HSYNC en C0 y VSYNC en C1, como establece la codificacion TMDS.
     */
    tmds_encoder red_encoder (
        .pixel_clk  (pixel_clk),
        .reset      (tx_reset),
        .pixel_data (red_pixel),
        .data_enable(video_active),
        .control_0  (1'b0),
        .control_1  (1'b0),
        .tmds_symbol(red_tmds_symbol)
    );

    tmds_encoder green_encoder (
        .pixel_clk  (pixel_clk),
        .reset      (tx_reset),
        .pixel_data (green_pixel),
        .data_enable(video_active),
        .control_0  (1'b0),
        .control_1  (1'b0),
        .tmds_symbol(green_tmds_symbol)
    );

    tmds_encoder blue_encoder (
        .pixel_clk  (pixel_clk),
        .reset      (tx_reset),
        .pixel_data (blue_pixel),
        .data_enable(video_active),
        .control_0  (hsync),
        .control_1  (vsync),
        .tmds_symbol(blue_tmds_symbol)
    );

    /* Senales serie internas, anteriores a los buffers diferenciales. */
    wire red_serial;
    wire green_serial;
    wire blue_serial;
    wire clock_serial;

    tmds_serializer red_serializer (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (tx_reset),
        .parallel_data(red_tmds_symbol),
        .serial_data  (red_serial)
    );

    tmds_serializer green_serializer (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (tx_reset),
        .parallel_data(green_tmds_symbol),
        .serial_data  (green_serial)
    );

    tmds_serializer blue_serializer (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (tx_reset),
        .parallel_data(blue_tmds_symbol),
        .serial_data  (blue_serial)
    );

    /*
     * El cuarto serializador genera el reloj TMDS. Al transmitir el patron
     * 1111100000 en orden LSB-first aparecen cinco intervalos bajos seguidos
     * de cinco altos: un periodo completo por cada ciclo de pixel_clk.
     */
    tmds_serializer clock_serializer (
        .pixel_clk    (pixel_clk),
        .serial_clk_5x(serial_clk_5x),
        .reset        (tx_reset),
        .parallel_data(10'b1111100000),
        .serial_data  (clock_serial)
    );

    /*
     * Buffers diferenciales de salida. El estandar electrico TMDS_33 y los
     * pines fisicos se asignan en el fichero XDC del proyecto.
     */
    OBUFDS red_output_buffer (
        .I (red_serial),
        .O (HDMI_D2_P),
        .OB(HDMI_D2_N)
    );

    OBUFDS green_output_buffer (
        .I (green_serial),
        .O (HDMI_D1_P),
        .OB(HDMI_D1_N)
    );

    OBUFDS blue_output_buffer (
        .I (blue_serial),
        .O (HDMI_D0_P),
        .OB(HDMI_D0_N)
    );

    OBUFDS clock_output_buffer (
        .I (clock_serial),
        .O (HDMI_CLK_P),
        .OB(HDMI_CLK_N)
    );

endmodule
