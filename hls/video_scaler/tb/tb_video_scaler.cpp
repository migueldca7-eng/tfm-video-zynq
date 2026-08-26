#include <cstdio>

#include "../src/video_scaler.hpp"

/* Geometria independiente utilizada por el modelo de referencia. */
static const unsigned int TEST_INPUT_WIDTH  = 640;
static const unsigned int TEST_INPUT_HEIGHT = 480;

static const unsigned int TEST_ASPECT_WIDTH  = 16;
static const unsigned int TEST_ASPECT_HEIGHT = 9;

static const unsigned int TEST_CROP_HEIGHT =
    (TEST_INPUT_WIDTH * TEST_ASPECT_HEIGHT) / TEST_ASPECT_WIDTH;

static const unsigned int TEST_CROP_FIRST_ROW =
    (TEST_INPUT_HEIGHT - TEST_CROP_HEIGHT) / 2;

static const unsigned long TEST_INPUT_PIXELS =
    (unsigned long)TEST_INPUT_WIDTH * TEST_INPUT_HEIGHT;

/* Limita el volumen del log cuando aparece un fallo sistematico. */
static const unsigned int MAX_REPORTED_ERRORS = 20;

static unsigned int error_count = 0;


/* Genera un RGB identificable de forma unica para cada coordenada VGA. */
static pixel_t reference_pixel(
    unsigned int x,
    unsigned int y
) {
    pixel_t pixel = 0;

    pixel.range(9, 0) = x;
    pixel.range(18, 10) = y;
    pixel.range(23, 19) = (x + y) & 0x1F;

    return pixel;
}


/* Construye un paquete AXI4-Stream de entrada para la posicion indicada. */
static axis_pixel_t make_input_packet(
    unsigned int x,
    unsigned int y
) {
    axis_pixel_t packet;

    packet.data = reference_pixel(x, y);
    packet.user = ((x == 0) && (y == 0)) ? 1 : 0;
    packet.last = (x == (TEST_INPUT_WIDTH - 1)) ? 1 : 0;
    packet.keep = 0x7;
    packet.strb = 0x7;
    packet.id = 0;
    packet.dest = 0;

    return packet;
}


/* Introduce un frame VGA completo en el stream del DUT. */
static void enqueue_input_frame(
    hls::stream<axis_pixel_t>& input_stream
) {
    for (unsigned int y = 0; y < TEST_INPUT_HEIGHT; ++y) {
        for (unsigned int x = 0; x < TEST_INPUT_WIDTH; ++x) {
            input_stream.write(make_input_packet(x, y));
        }
    }
}


/*
 * Numero exacto de llamadas necesarias para procesar un frame escalado.
 *
 * Cada pixel de entrada requiere una llamada. Cada pixel de salida requiere
 * otra y las lineas reproducidas necesitan ademas una lectura del buffer por
 * cada pixel original.
 */
static unsigned long scaled_frame_call_count(unsigned int scale_factor)
{
    unsigned long output_pixels =
        (unsigned long)(TEST_INPUT_WIDTH * scale_factor) *
        (TEST_CROP_HEIGHT * scale_factor);

    unsigned long replay_loads =
        (unsigned long)TEST_INPUT_WIDTH *
        TEST_CROP_HEIGHT *
        (scale_factor - 1);

    return TEST_INPUT_PIXELS + output_pixels + replay_loads;
}


/* Ejecuta una cantidad determinada de pasos de la maquina HLS. */
static void run_dut(
    unsigned long call_count,
    hls::stream<axis_pixel_t>& input_stream,
    hls::stream<axis_pixel_t>& output_stream,
    ap_uint<1> requested_scale_enable,
    scaler_resolution_t requested_resolution,
    scaler_aspect_t requested_aspect,
    scaler_interpolation_t requested_interpolation,
    ap_uint<1>& active_scale_enable_status,
    scaler_resolution_t& active_resolution_status,
    scaler_aspect_t& active_aspect_status,
    scaler_interpolation_t& active_interpolation_status,
    ap_uint<1>& pending_status
) {
    for (unsigned long call = 0; call < call_count; ++call) {
        video_scaler(
            input_stream,
            output_stream,
            requested_scale_enable,
            requested_resolution,
            requested_aspect,
            requested_interpolation,
            active_scale_enable_status,
            active_resolution_status,
            active_aspect_status,
            active_interpolation_status,
            pending_status
        );
    }
}


/* Registra un error sin llenar la consola con millones de mensajes. */
static void report_error(
    const char* scenario,
    const char* field,
    unsigned int x,
    unsigned int y,
    unsigned int expected,
    unsigned int actual
) {
    if (error_count < MAX_REPORTED_ERRORS) {
        std::printf(
            "ERROR [%s] (%u,%u) %s: expected=0x%X actual=0x%X\n",
            scenario,
            x,
            y,
            field,
            expected,
            actual
        );
    }

    error_count++;
}


/* Comprueba datos RGB y senales laterales de un paquete de salida. */
static void validate_packet(
    const char* scenario,
    axis_pixel_t actual,
    pixel_t expected_data,
    ap_uint<1> expected_user,
    ap_uint<1> expected_last,
    unsigned int x,
    unsigned int y
) {
    if (actual.data != expected_data) {
        report_error(
            scenario,
            "TDATA",
            x,
            y,
            expected_data.to_uint(),
            actual.data.to_uint()
        );
    }

    if (actual.user != expected_user) {
        report_error(
            scenario,
            "TUSER",
            x,
            y,
            expected_user.to_uint(),
            actual.user.to_uint()
        );
    }

    if (actual.last != expected_last) {
        report_error(
            scenario,
            "TLAST",
            x,
            y,
            expected_last.to_uint(),
            actual.last.to_uint()
        );
    }

    if (actual.keep != 0x7) {
        report_error(
            scenario,
            "TKEEP",
            x,
            y,
            0x7,
            actual.keep.to_uint()
        );
    }

    if (actual.strb != 0x7) {
        report_error(
            scenario,
            "TSTRB",
            x,
            y,
            0x7,
            actual.strb.to_uint()
        );
    }
}


/* Comprueba que el modo bypass conserva un frame VGA completo. */
static void validate_bypass_frame(
    hls::stream<axis_pixel_t>& output_stream
) {
    const char* scenario = "VGA bypass";

    for (unsigned int y = 0; y < TEST_INPUT_HEIGHT; ++y) {
        for (unsigned int x = 0; x < TEST_INPUT_WIDTH; ++x) {
            if (output_stream.empty()) {
                report_error(scenario, "missing packet", x, y, 1, 0);
                return;
            }

            axis_pixel_t actual = output_stream.read();

            validate_packet(
                scenario,
                actual,
                reference_pixel(x, y),
                ((x == 0) && (y == 0)) ? 1 : 0,
                (x == (TEST_INPUT_WIDTH - 1)) ? 1 : 0,
                x,
                y
            );
        }
    }

    if (!output_stream.empty()) {
        report_error(scenario, "extra packet", 0, 0, 0, 1);
    }
}


/*
 * Modelo independiente del recorte centrado y vecino mas proximo.
 * Cada coordenada de salida se transforma en su coordenada VGA de origen.
 */
static void validate_scaled_frame(
    hls::stream<axis_pixel_t>& output_stream,
    unsigned int scale_factor,
    const char* scenario
) {
    unsigned int output_width = TEST_INPUT_WIDTH * scale_factor;
    unsigned int output_height = TEST_CROP_HEIGHT * scale_factor;

    for (unsigned int output_y = 0;
         output_y < output_height;
         ++output_y) {

        unsigned int source_y =
            TEST_CROP_FIRST_ROW + (output_y / scale_factor);

        for (unsigned int output_x = 0;
             output_x < output_width;
             ++output_x) {

            if (output_stream.empty()) {
                report_error(
                    scenario,
                    "missing packet",
                    output_x,
                    output_y,
                    1,
                    0
                );
                return;
            }

            unsigned int source_x = output_x / scale_factor;
            axis_pixel_t actual = output_stream.read();

            validate_packet(
                scenario,
                actual,
                reference_pixel(source_x, source_y),
                ((output_x == 0) && (output_y == 0)) ? 1 : 0,
                (output_x == (output_width - 1)) ? 1 : 0,
                output_x,
                output_y
            );
        }
    }

    if (!output_stream.empty()) {
        report_error(scenario, "extra packet", 0, 0, 0, 1);
    }
}


/* Comprueba las senales discretas de estado del nucleo. */
static void validate_status(
    const char* scenario,
    ap_uint<1> active_scale_enable_status,
    scaler_resolution_t active_resolution_status,
    scaler_aspect_t active_aspect_status,
    scaler_interpolation_t active_interpolation_status,
    ap_uint<1> pending_status,
    ap_uint<1> expected_enable,
    scaler_resolution_t expected_resolution,
    ap_uint<1> expected_pending
) {
    if (active_scale_enable_status != expected_enable) {
        report_error(
            scenario,
            "active enable",
            0,
            0,
            expected_enable.to_uint(),
            active_scale_enable_status.to_uint()
        );
    }

    if (active_resolution_status != expected_resolution) {
        report_error(
            scenario,
            "active resolution",
            0,
            0,
            expected_resolution.to_uint(),
            active_resolution_status.to_uint()
        );
    }

    if (active_aspect_status != SCALER_ASPECT_CROP) {
        report_error(
            scenario,
            "active aspect",
            0,
            0,
            SCALER_ASPECT_CROP.to_uint(),
            active_aspect_status.to_uint()
        );
    }

    if (active_interpolation_status != SCALER_NEAREST) {
        report_error(
            scenario,
            "active interpolation",
            0,
            0,
            SCALER_NEAREST.to_uint(),
            active_interpolation_status.to_uint()
        );
    }

    if (pending_status != expected_pending) {
        report_error(
            scenario,
            "pending",
            0,
            0,
            expected_pending.to_uint(),
            pending_status.to_uint()
        );
    }
}


int main()
{
    hls::stream<axis_pixel_t> input_stream("input_stream");
    hls::stream<axis_pixel_t> output_stream("output_stream");

    ap_uint<1> active_scale_enable_status = 0;
    scaler_resolution_t active_resolution_status = SCALER_RES_VGA;
    scaler_aspect_t active_aspect_status = SCALER_ASPECT_CROP;
    scaler_interpolation_t active_interpolation_status = SCALER_NEAREST;
    ap_uint<1> pending_status = 0;

    /* Caso 1: bypass VGA, incluyendo TUSER y TLAST originales. */
    enqueue_input_frame(input_stream);

    run_dut(
        TEST_INPUT_PIXELS,
        input_stream,
        output_stream,
        0,
        SCALER_RES_VGA,
        SCALER_ASPECT_CROP,
        SCALER_NEAREST,
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status
    );

    validate_bypass_frame(output_stream);

    validate_status(
        "VGA bypass",
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status,
        0,
        SCALER_RES_VGA,
        0
    );

    /*
     * Caso 2: 720p. Durante el frame se solicita 1080p para comprobar que
     * el cambio queda pendiente y no modifica una imagen ya comenzada.
     */
    enqueue_input_frame(input_stream);

    const unsigned long calls_720p = scaled_frame_call_count(2);
    const unsigned long calls_before_change = 10000;

    run_dut(
        calls_before_change,
        input_stream,
        output_stream,
        1,
        SCALER_RES_720P,
        SCALER_ASPECT_CROP,
        SCALER_NEAREST,
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status
    );

    run_dut(
        calls_720p - calls_before_change,
        input_stream,
        output_stream,
        1,
        SCALER_RES_1080P,
        SCALER_ASPECT_CROP,
        SCALER_NEAREST,
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status
    );

    validate_scaled_frame(output_stream, 2, "720p nearest crop");

    validate_status(
        "720p pending 1080p",
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status,
        1,
        SCALER_RES_720P,
        1
    );

    /* Caso 3: el 1080p pendiente se aplica en el siguiente TUSER. */
    enqueue_input_frame(input_stream);

    run_dut(
        scaled_frame_call_count(3),
        input_stream,
        output_stream,
        1,
        SCALER_RES_1080P,
        SCALER_ASPECT_CROP,
        SCALER_NEAREST,
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status
    );

    validate_scaled_frame(output_stream, 3, "1080p nearest crop");

    validate_status(
        "1080p active",
        active_scale_enable_status,
        active_resolution_status,
        active_aspect_status,
        active_interpolation_status,
        pending_status,
        1,
        SCALER_RES_1080P,
        0
    );

    if (error_count == 0) {
        std::printf(
            "PASS: bypass VGA, crop nearest 720p/1080p and "
            "frame-safe configuration.\n"
        );
        return 0;
    }

    std::printf("FAIL: %u errors detected.\n", error_count);
    return 1;
}
