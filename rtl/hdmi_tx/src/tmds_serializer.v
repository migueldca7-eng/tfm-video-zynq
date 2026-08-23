`timescale 1ns / 1ps

/*
 * Serializador TMDS 10:1 para dispositivos Xilinx de la serie 7.
 *
 * Cada ciclo de pixel_clk carga un simbolo TMDS completo de 10 bits. El
 * reloj serial_clk_5x trabaja a cinco veces esa frecuencia y el OSERDESE2
 * transmite un bit en cada flanco, por lo que aparecen diez bits serie por
 * cada ciclo de pixel.
 *
 * Un OSERDESE2 solo dispone de ocho entradas de datos directas. Para obtener
 * una anchura de 10 bits se utiliza la configuracion en cascada indicada por
 * Xilinx: el bloque MASTER recibe los bits 0 a 7 y genera la salida; el bloque
 * SLAVE recibe los bits 8 y 9 y se los entrega al MASTER mediante las rutas
 * SHIFTOUT/SHIFTIN internas.
 */
module tmds_serializer (
    input  wire       pixel_clk,
    input  wire       serial_clk_5x,
    input  wire       reset,
    input  wire [9:0] parallel_data,
    output wire       serial_data
);

    /*
     * El reset se activa de forma asincrona, pero se libera sincronizado con
     * pixel_clk. De esta manera ambos OSERDESE2 abandonan el reset en una
     * frontera valida de carga de la palabra paralela.
     */
    reg [1:0] reset_sync;

    always @(posedge pixel_clk or posedge reset) begin
        if (reset)
            reset_sync <= 2'b11;
        else
            reset_sync <= {reset_sync[0], 1'b0};
    end

    wire serializer_reset;
    assign serializer_reset = reset_sync[1];

    /*
     * Rutas internas de cascada. No son salidas del serializador: permiten
     * que los dos bits almacenados en el SLAVE completen la palabra del
     * MASTER. Existen dos rutas porque la salida trabaja en DDR.
     */
    wire slave_shift_1;
    wire slave_shift_2;

    /*
     * OSERDESE2 principal. D1 se transmite primero, por lo que los bits del
     * simbolo se conectan en orden ascendente desde parallel_data[0].
     */
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .INIT_OQ       (1'b0),
        .INIT_TQ       (1'b0),
        .SERDES_MODE   ("MASTER"),
        .SRVAL_OQ      (1'b0),
        .SRVAL_TQ      (1'b0),
        .TBYTE_CTL     ("FALSE"),
        .TBYTE_SRC     ("FALSE"),
        .TRISTATE_WIDTH(1)
    ) oserdes_master (
        .OFB      (),
        .OQ       (serial_data),
        .SHIFTOUT1(),
        .SHIFTOUT2(),
        .TBYTEOUT (),
        .TFB      (),
        .TQ       (),

        .CLK      (serial_clk_5x),
        .CLKDIV   (pixel_clk),
        .D1       (parallel_data[0]),
        .D2       (parallel_data[1]),
        .D3       (parallel_data[2]),
        .D4       (parallel_data[3]),
        .D5       (parallel_data[4]),
        .D6       (parallel_data[5]),
        .D7       (parallel_data[6]),
        .D8       (parallel_data[7]),
        .OCE      (1'b1),
        .RST      (serializer_reset),
        .SHIFTIN1 (slave_shift_1),
        .SHIFTIN2 (slave_shift_2),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0),
        .TBYTEIN  (1'b0),
        .TCE      (1'b0)
    );

    /*
     * OSERDESE2 de ampliacion. Para DATA_WIDTH=10, la conexion definida por
     * Xilinx coloca los bits adicionales en D3 y D4 del bloque SLAVE.
     * Su salida OQ no se usa: los datos llegan al MASTER por SHIFTOUT1/2.
     */
    OSERDESE2 #(
        .DATA_RATE_OQ  ("DDR"),
        .DATA_RATE_TQ  ("SDR"),
        .DATA_WIDTH    (10),
        .INIT_OQ       (1'b0),
        .INIT_TQ       (1'b0),
        .SERDES_MODE   ("SLAVE"),
        .SRVAL_OQ      (1'b0),
        .SRVAL_TQ      (1'b0),
        .TBYTE_CTL     ("FALSE"),
        .TBYTE_SRC     ("FALSE"),
        .TRISTATE_WIDTH(1)
    ) oserdes_slave (
        .OFB      (),
        .OQ       (),
        .SHIFTOUT1(slave_shift_1),
        .SHIFTOUT2(slave_shift_2),
        .TBYTEOUT (),
        .TFB      (),
        .TQ       (),

        .CLK      (serial_clk_5x),
        .CLKDIV   (pixel_clk),
        .D1       (1'b0),
        .D2       (1'b0),
        .D3       (parallel_data[8]),
        .D4       (parallel_data[9]),
        .D5       (1'b0),
        .D6       (1'b0),
        .D7       (1'b0),
        .D8       (1'b0),
        .OCE      (1'b1),
        .RST      (serializer_reset),
        .SHIFTIN1 (1'b0),
        .SHIFTIN2 (1'b0),
        .T1       (1'b0),
        .T2       (1'b0),
        .T3       (1'b0),
        .T4       (1'b0),
        .TBYTEIN  (1'b0),
        .TCE      (1'b0)
    );

endmodule
