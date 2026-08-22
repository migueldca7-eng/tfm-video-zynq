#include <cstdio>

#include "../src/video_filter.hpp"

/* Tamano reducido de los frames empleados en la simulacion C. */
static const unsigned int FRAME_WIDTH  = 4;
static const unsigned int FRAME_HEIGHT = 3;
static const unsigned int FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

/* La ruta Sobel del DUT esta dimensionada para la camara VGA. */
static const unsigned int SOBEL_TEST_WIDTH  = 640;
static const unsigned int SOBEL_TEST_HEIGHT = 480;
static const unsigned int SOBEL_TEST_PIXELS =
    SOBEL_TEST_WIDTH * SOBEL_TEST_HEIGHT;
static const unsigned int SOBEL_TEST_DELAY = SOBEL_TEST_WIDTH + 1;

/* Evita llenar el log con miles de mensajes si aparece un fallo sistematico. */
static const unsigned int MAX_REPORTED_SOBEL_ERRORS = 20;

/*
 * Construye el valor RGB del pixel indicado.
 *
 * En el primer frame, multiplier recorre 1..12.
 * En el segundo frame, multiplier recorre 12..1 para comprobar tambien que
 * el filtro conserva el orden de los datos.
 */
static pixel_t make_rgb_pixel(
    unsigned int pixel_index,
    bool descending
)
{
    unsigned int multiplier;

    if (descending) {
        multiplier = FRAME_PIXELS - pixel_index;
    } else {
        multiplier = pixel_index + 1;
    }

    ap_uint<8> red   = 4  * multiplier;
    ap_uint<8> green = 8  * multiplier;
    ap_uint<8> blue  = 16 * multiplier;

    pixel_t pixel = 0;

    pixel.range(23, 16) = red;
    pixel.range(15, 8)  = green;
    pixel.range(7, 0)   = blue;

    return pixel;
}

/*
 * Genera un paquete AXI4-Stream para una posicion del frame.
 * TUSER marca el primer pixel y TLAST el ultimo pixel de cada linea.
 */
static axis_pixel_t make_axis_packet(
    unsigned int pixel_index,
    bool descending
)
{
    unsigned int column = pixel_index % FRAME_WIDTH;

    axis_pixel_t packet;

    packet.data = make_rgb_pixel(pixel_index, descending);
    packet.user = (pixel_index == 0) ? 1 : 0;
    packet.last = (column == (FRAME_WIDTH - 1)) ? 1 : 0;

    /* Los tres bytes de RGB888 contienen datos validos. */
    packet.keep = 0x7;
    packet.strb = 0x7;

    /* TID y TDEST no se utilizan en este sistema. */
    packet.id   = 0;
    packet.dest = 0;

    return packet;
}

/*
 * Imagen de prueba Sobel dividida en cuatro regiones de color:
 *   negro | rojo
 *   ------+-----
 *   verde | azul
 *
 * Los cambios horizontal y vertical ejercitan Gx y Gy. Los tres colores
 * primarios comprueban tambien la conversion RGB a intensidad.
 */
static pixel_t make_sobel_rgb_pixel(
    unsigned int x,
    unsigned int y
)
{
    pixel_t pixel = 0;

    bool right_half = x >= (SOBEL_TEST_WIDTH / 2);
    bool bottom_half = y >= (SOBEL_TEST_HEIGHT / 2);

    if (!right_half && !bottom_half) {
        /* Cuadrante superior izquierdo: negro. */
        pixel = 0;
    } else if (right_half && !bottom_half) {
        /* Cuadrante superior derecho: rojo. */
        pixel.range(23, 16) = 255;
    } else if (!right_half && bottom_half) {
        /* Cuadrante inferior izquierdo: verde. */
        pixel.range(15, 8) = 255;
    } else {
        /* Cuadrante inferior derecho: azul. */
        pixel.range(7, 0) = 255;
    }

    return pixel;
}

/* Genera el paquete AXI correspondiente a la imagen VGA de prueba. */
static axis_pixel_t make_sobel_axis_packet(unsigned int pixel_index)
{
    unsigned int x = pixel_index % SOBEL_TEST_WIDTH;
    unsigned int y = pixel_index / SOBEL_TEST_WIDTH;

    axis_pixel_t packet;

    packet.data = make_sobel_rgb_pixel(x, y);
    packet.user = (pixel_index == 0) ? 1 : 0;
    packet.last = (x == (SOBEL_TEST_WIDTH - 1)) ? 1 : 0;
    packet.keep = 0x7;
    packet.strb = 0x7;
    packet.id   = 0;
    packet.dest = 0;

    return packet;
}

/* Modelo C++ independiente de la conversion RGB a intensidad. */
static unsigned int reference_gray_at(
    unsigned int x,
    unsigned int y
)
{
    pixel_t pixel = make_sobel_rgb_pixel(x, y);

    unsigned int red   = pixel.range(23, 16).to_uint();
    unsigned int green = pixel.range(15, 8).to_uint();
    unsigned int blue  = pixel.range(7, 0).to_uint();

    return ((77 * red) + (150 * green) + (29 * blue)) >> 8;
}

/*
 * Referencia software del Sobel. No llama a ninguna funcion interna del DUT,
 * por lo que puede detectar errores en sus buffers o en sus operaciones.
 */
static pixel_t reference_sobel_pixel(
    unsigned int x,
    unsigned int y
)
{
    pixel_t output = 0;

    /* Politica elegida para el DUT: borde exterior negro. */
    if ((x == 0) || (x == (SOBEL_TEST_WIDTH - 1)) ||
        (y == 0) || (y == (SOBEL_TEST_HEIGHT - 1))) {
        return output;
    }

    int p00 = (int)reference_gray_at(x - 1, y - 1);
    int p01 = (int)reference_gray_at(x,     y - 1);
    int p02 = (int)reference_gray_at(x + 1, y - 1);

    int p10 = (int)reference_gray_at(x - 1, y);
    int p12 = (int)reference_gray_at(x + 1, y);

    int p20 = (int)reference_gray_at(x - 1, y + 1);
    int p21 = (int)reference_gray_at(x,     y + 1);
    int p22 = (int)reference_gray_at(x + 1, y + 1);

    int gx =
        -p00 + p02
        - (2 * p10) + (2 * p12)
        - p20 + p22;

    int gy =
        -p00 - (2 * p01) - p02
        + p20 + (2 * p21) + p22;

    unsigned int abs_gx = (gx < 0) ? (unsigned int)(-gx) : (unsigned int)gx;
    unsigned int abs_gy = (gy < 0) ? (unsigned int)(-gy) : (unsigned int)gy;
    unsigned int magnitude = abs_gx + abs_gy;

    if (magnitude > 255) {
        magnitude = 255;
    }

    output.range(23, 16) = magnitude;
    output.range(15, 8)  = magnitude;
    output.range(7, 0)   = magnitude;

    return output;
}

/*
 * Modelo software independiente del resultado esperado.
 * Emplea enteros C++ normales para no reutilizar la funcion interna del DUT.
 */
static pixel_t reference_filter(
    pixel_t pixel_in,
    filter_mode_t mode
)
{
    if (mode != FILTER_GRAYSCALE) {
        return pixel_in;
    }

    unsigned int red   = pixel_in.range(23, 16).to_uint();
    unsigned int green = pixel_in.range(15, 8).to_uint();
    unsigned int blue  = pixel_in.range(7, 0).to_uint();

    unsigned int gray =
        ((77 * red) + (150 * green) + (29 * blue)) >> 8;

    pixel_t pixel_out = 0;

    pixel_out.range(23, 16) = gray;
    pixel_out.range(15, 8)  = gray;
    pixel_out.range(7, 0)   = gray;

    return pixel_out;
}

/*
 * Compara un paquete de salida con el dato de referencia y con todas las
 * senales laterales del paquete de entrada.
 */
static int check_output(
    const char *test_name,
    unsigned int frame_index,
    unsigned int pixel_index,
    const axis_pixel_t& input_packet,
    const axis_pixel_t& output_packet,
    pixel_t expected_data,
    filter_mode_t active_mode_status,
    ap_uint<1> pending_status,
    filter_mode_t expected_active_mode,
    ap_uint<1> expected_pending
)
{
    bool packet_error =
        (output_packet.data != expected_data)       ||
        (output_packet.user != input_packet.user)   ||
        (output_packet.last != input_packet.last)   ||
        (output_packet.keep != input_packet.keep)   ||
        (output_packet.strb != input_packet.strb)   ||
        (output_packet.id   != input_packet.id)     ||
        (output_packet.dest != input_packet.dest);

    bool status_error =
        (active_mode_status != expected_active_mode) ||
        (pending_status != expected_pending);

    if (!packet_error && !status_error) {
        return 0;
    }

    std::printf(
        "FAIL: %s frame=%u pixel=%u "
        "data expected=0x%06X actual=0x%06X "
        "active expected=%u actual=%u "
        "pending expected=%u actual=%u\n",
        test_name,
        frame_index + 1,
        pixel_index + 1,
        expected_data.to_uint(),
        output_packet.data.to_uint(),
        expected_active_mode.to_uint(),
        active_mode_status.to_uint(),
        expected_pending.to_uint(),
        pending_status.to_uint()
    );

    if (packet_error) {
        std::printf(
            "      sidebands input:  user=%u last=%u keep=0x%X "
            "strb=0x%X id=%u dest=%u\n",
            input_packet.user.to_uint(),
            input_packet.last.to_uint(),
            input_packet.keep.to_uint(),
            input_packet.strb.to_uint(),
            input_packet.id.to_uint(),
            input_packet.dest.to_uint()
        );
        std::printf(
            "      sidebands output: user=%u last=%u keep=0x%X "
            "strb=0x%X id=%u dest=%u\n",
            output_packet.user.to_uint(),
            output_packet.last.to_uint(),
            output_packet.keep.to_uint(),
            output_packet.strb.to_uint(),
            output_packet.id.to_uint(),
            output_packet.dest.to_uint()
        );
    }

    return 1;
}

/*
 * Ejecuta un escenario formado por dos frames consecutivos.
 *
 * El primer frame usa datos ascendentes y el segundo descendentes. Cuando
 * los modos son diferentes, el segundo modo se solicita despues de procesar
 * el tercer pixel del primer frame. El DUT debe conservar el primer modo
 * hasta recibir el TUSER del segundo frame.
 */
static int run_scenario(
    const char *test_name,
    filter_mode_t first_frame_mode,
    filter_mode_t second_frame_mode
)
{
    hls::stream<axis_pixel_t> input_stream;
    hls::stream<axis_pixel_t> output_stream;

    filter_mode_t requested_mode = first_frame_mode;
    filter_mode_t expected_active_mode = first_frame_mode;

    filter_mode_t active_mode_status = FILTER_BYPASS;
    ap_uint<1> pending_status = 0;

    int errors = 0;

    for (unsigned int frame_index = 0; frame_index < 2; ++frame_index) {
        bool descending = (frame_index == 1);

        for (unsigned int pixel_index = 0;
             pixel_index < FRAME_PIXELS;
             ++pixel_index) {

            /*
             * Cambiar antes de procesar el cuarto pixel equivale a haber
             * solicitado el nuevo modo despues de completar el tercero.
             */
            if ((frame_index == 0) &&
                (pixel_index == 3) &&
                (first_frame_mode != second_frame_mode)) {
                requested_mode = second_frame_mode;
            }

            axis_pixel_t input_packet =
                make_axis_packet(pixel_index, descending);

            input_stream.write(input_packet);

            video_filter(
                input_stream,
                output_stream,
                requested_mode,
                active_mode_status,
                pending_status
            );

            axis_pixel_t output_packet = output_stream.read();

            /* El modo activo solo cambia al aceptar el inicio de un frame. */
            if (input_packet.user == 1) {
                expected_active_mode = requested_mode;
            }

            ap_uint<1> expected_pending =
                (requested_mode != expected_active_mode);

            pixel_t expected_data = reference_filter(
                input_packet.data,
                expected_active_mode
            );

            errors += check_output(
                test_name,
                frame_index,
                pixel_index,
                input_packet,
                output_packet,
                expected_data,
                active_mode_status,
                pending_status,
                expected_active_mode,
                expected_pending
            );
        }
    }

    if (errors == 0) {
        std::printf("PASS: %s\n", test_name);
    }

    return errors;
}

/* Compara un paquete Sobel con el modelo software y el paquete original. */
static int check_sobel_output(
    unsigned int pixel_index,
    const axis_pixel_t& output_packet,
    unsigned int& reported_errors
)
{
    unsigned int x = pixel_index % SOBEL_TEST_WIDTH;
    unsigned int y = pixel_index / SOBEL_TEST_WIDTH;

    axis_pixel_t expected_packet = make_sobel_axis_packet(pixel_index);
    pixel_t expected_data = reference_sobel_pixel(x, y);

    bool error =
        (output_packet.data != expected_data)             ||
        (output_packet.user != expected_packet.user)      ||
        (output_packet.last != expected_packet.last)      ||
        (output_packet.keep != expected_packet.keep)      ||
        (output_packet.strb != expected_packet.strb)      ||
        (output_packet.id   != expected_packet.id)        ||
        (output_packet.dest != expected_packet.dest);

    if (!error) {
        return 0;
    }

    if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
        std::printf(
            "FAIL: Sobel output pixel=%u x=%u y=%u "
            "data expected=0x%06X actual=0x%06X "
            "user expected=%u actual=%u last expected=%u actual=%u\n",
            pixel_index + 1,
            x,
            y,
            expected_data.to_uint(),
            output_packet.data.to_uint(),
            expected_packet.user.to_uint(),
            output_packet.user.to_uint(),
            expected_packet.last.to_uint(),
            output_packet.last.to_uint()
        );
    }

    reported_errors++;
    return 1;
}

/* Comprueba las senales de estado independientemente del flujo de salida. */
static int check_sobel_status(
    const char *stage,
    unsigned int iteration,
    filter_mode_t active_mode_status,
    ap_uint<1> pending_status,
    filter_mode_t expected_active,
    ap_uint<1> expected_pending,
    unsigned int& reported_errors
)
{
    if ((active_mode_status == expected_active) &&
        (pending_status == expected_pending)) {
        return 0;
    }

    if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
        std::printf(
            "FAIL: Sobel status stage=%s iteration=%u "
            "active expected=%u actual=%u "
            "pending expected=%u actual=%u\n",
            stage,
            iteration,
            expected_active.to_uint(),
            active_mode_status.to_uint(),
            expected_pending.to_uint(),
            pending_status.to_uint()
        );
    }

    reported_errors++;
    return 1;
}

/*
 * Valida un frame Sobel VGA completo y las tres fases de su datapath:
 *   FILL   -> 641 entradas sin salida;
 *   STREAM -> una entrada y una salida por llamada;
 *   FLUSH  -> 641 salidas sin consumir un nuevo frame.
 *
 * A mitad del frame se solicita bypass. El cambio debe permanecer pendiente
 * hasta terminar STREAM y FLUSH, y aplicarse en el TUSER siguiente.
 */
static int run_sobel_scenario()
{
    hls::stream<axis_pixel_t> input_stream;
    hls::stream<axis_pixel_t> output_stream;

    filter_mode_t requested_mode = FILTER_SOBEL;
    filter_mode_t active_mode_status = FILTER_BYPASS;
    ap_uint<1> pending_status = 0;

    const unsigned int request_change_pixel = SOBEL_TEST_PIXELS / 2;

    unsigned int output_index = 0;
    unsigned int reported_errors = 0;
    int errors = 0;

    for (unsigned int input_index = 0;
         input_index < SOBEL_TEST_PIXELS;
         ++input_index) {

        if (input_index == request_change_pixel) {
            requested_mode = FILTER_BYPASS;
        }

        axis_pixel_t input_packet =
            make_sobel_axis_packet(input_index);

        input_stream.write(input_packet);

        video_filter(
            input_stream,
            output_stream,
            requested_mode,
            active_mode_status,
            pending_status
        );

        ap_uint<1> expected_pending =
            (input_index >= request_change_pixel) ? 1 : 0;

        errors += check_sobel_status(
            "input",
            input_index,
            active_mode_status,
            pending_status,
            FILTER_SOBEL,
            expected_pending,
            reported_errors
        );

        if (input_index < SOBEL_TEST_DELAY) {
            /* FILL no debe producir ningun paquete. */
            if (!output_stream.empty()) {
                if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
                    std::printf(
                        "FAIL: Sobel produced output during FILL "
                        "at input pixel=%u\n",
                        input_index + 1
                    );
                }
                reported_errors++;
                errors++;
                output_stream.read();
            }
        } else {
            /* STREAM debe producir exactamente un paquete por nueva entrada. */
            if (output_stream.empty()) {
                if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
                    std::printf(
                        "FAIL: Sobel missing STREAM output "
                        "at input pixel=%u\n",
                        input_index + 1
                    );
                }
                reported_errors++;
                errors++;
            } else {
                axis_pixel_t output_packet = output_stream.read();

                errors += check_sobel_output(
                    output_index,
                    output_packet,
                    reported_errors
                );

                output_index++;
            }
        }
    }

    /*
     * El DUT debe encontrarse en FLUSH: estas llamadas se realizan con la
     * entrada vacia y cada una debe producir un borde negro pendiente.
     */
    for (unsigned int flush_index = 0;
         flush_index < SOBEL_TEST_DELAY;
         ++flush_index) {

        video_filter(
            input_stream,
            output_stream,
            requested_mode,
            active_mode_status,
            pending_status
        );

        errors += check_sobel_status(
            "flush",
            flush_index,
            active_mode_status,
            pending_status,
            FILTER_SOBEL,
            1,
            reported_errors
        );

        if (output_stream.empty()) {
            if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
                std::printf(
                    "FAIL: Sobel missing FLUSH output iteration=%u\n",
                    flush_index + 1
                );
            }
            reported_errors++;
            errors++;
        } else {
            axis_pixel_t output_packet = output_stream.read();

            errors += check_sobel_output(
                output_index,
                output_packet,
                reported_errors
            );

            output_index++;
        }
    }

    if (output_index != SOBEL_TEST_PIXELS) {
        if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
            std::printf(
                "FAIL: Sobel output count expected=%u actual=%u\n",
                SOBEL_TEST_PIXELS,
                output_index
            );
        }
        reported_errors++;
        errors++;
    }

    /*
     * El siguiente TUSER debe aplicar el bypass solicitado durante Sobel.
     * Solo necesitamos el primer paquete para validar la transicion.
     */
    axis_pixel_t next_frame_packet = make_sobel_axis_packet(0);
    input_stream.write(next_frame_packet);

    video_filter(
        input_stream,
        output_stream,
        requested_mode,
        active_mode_status,
        pending_status
    );

    if (output_stream.empty()) {
        if (reported_errors < MAX_REPORTED_SOBEL_ERRORS) {
            std::printf(
                "FAIL: no output after frame-safe Sobel to bypass change\n"
            );
        }
        reported_errors++;
        errors++;
    } else {
        axis_pixel_t output_packet = output_stream.read();

        errors += check_output(
            "frame-safe Sobel to bypass",
            1,
            0,
            next_frame_packet,
            output_packet,
            next_frame_packet.data,
            active_mode_status,
            pending_status,
            FILTER_BYPASS,
            0
        );
    }

    if (reported_errors > MAX_REPORTED_SOBEL_ERRORS) {
        std::printf(
            "Sobel test omitted %u additional error messages.\n",
            reported_errors - MAX_REPORTED_SOBEL_ERRORS
        );
    }

    if (errors == 0) {
        std::printf(
            "PASS: VGA Sobel, AXI alignment, borders and frame-safe exit\n"
        );
    }

    return errors;
}

int main()
{
    int errors = 0;

    errors += run_scenario(
        "two consecutive bypass frames",
        FILTER_BYPASS,
        FILTER_BYPASS
    );

    errors += run_scenario(
        "two consecutive grayscale frames",
        FILTER_GRAYSCALE,
        FILTER_GRAYSCALE
    );

    errors += run_scenario(
        "frame-safe bypass to grayscale",
        FILTER_BYPASS,
        FILTER_GRAYSCALE
    );

    errors += run_scenario(
        "frame-safe grayscale to bypass",
        FILTER_GRAYSCALE,
        FILTER_BYPASS
    );

    errors += run_sobel_scenario();

    if (errors == 0) {
        std::printf("All AXI4-Stream C simulation tests passed.\n");
        return 0;
    }

    std::printf("C simulation failed with %d errors.\n", errors);
    return 1;
}
