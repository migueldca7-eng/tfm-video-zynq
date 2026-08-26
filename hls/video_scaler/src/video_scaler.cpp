#include "video_scaler.hpp"

/* Geometria fija de la entrada actual. */
static const int INPUT_WIDTH  = 640;
static const int INPUT_HEIGHT = 480;

/* Relacion de aspecto de los modos 720p y 1080p. */
static const int TARGET_ASPECT_WIDTH  = 16;
static const int TARGET_ASPECT_HEIGHT = 9;

/* Recorte vertical centrado calculado a partir de la geometria. */
static const int CROP_HEIGHT =
    (INPUT_WIDTH * TARGET_ASPECT_HEIGHT) / TARGET_ASPECT_WIDTH;

static const int CROP_FIRST_ROW =
    (INPUT_HEIGHT - CROP_HEIGHT) / 2;

static const int CROP_END_ROW =
    CROP_FIRST_ROW + CROP_HEIGHT;

static const int LAST_INPUT_COLUMN =
    INPUT_WIDTH - 1;

/* Factores de escalado disponibles. */
static const ap_uint<2> SCALE_FACTOR_BYPASS = 1;
static const ap_uint<2> SCALE_FACTOR_720P   = 2;
static const ap_uint<2> SCALE_FACTOR_1080P  = 3;

/*
 * Coordenadas de hasta 4095 posiciones. Doce bits cubren las resoluciones
 * actuales y permiten parametrizar posteriormente entradas de hasta 4K sin
 * sobredimensionar los sumadores y multiplexores del camino de control.
 */
typedef ap_uint<12> coordinate_t;

/*
 * Valores simbolicos de la maquina de estados.
 *
 * Se declaran como enum para que Vivado HLS 2019.1 pueda utilizarlos como
 * etiquetas constantes dentro del switch. El registro que almacena el estado
 * sigue siendo un ap_uint<2>, por lo que esta adaptacion no aumenta su ancho.
 */
enum scaler_state_value_t {
    SCALER_READ_INPUT = 0,
    SCALER_OUTPUT_LIVE_PIXEL = 1,
    SCALER_LOAD_REPLAY_PIXEL = 2,
    SCALER_OUTPUT_REPLAY_PIXEL = 3
};

typedef ap_uint<2> scaler_state_t;
typedef ap_uint<2> repeat_count_t;

/* Prototipos de las funciones auxiliares definidas tras la funcion top. */
static bool scaling_is_active(
    ap_uint<1> scale_enable,
    scaler_resolution_t resolution
);

static repeat_count_t get_scale_factor(
    scaler_resolution_t resolution
);

static axis_pixel_t make_scaled_packet(
    pixel_t pixel,
    ap_uint<1> start_of_frame,
    ap_uint<1> end_of_line
);

static void advance_input_position(
    ap_uint<1> end_of_line,
    coordinate_t& input_x,
    coordinate_t& input_y
);


void video_scaler(
    hls::stream<axis_pixel_t>& s_axis_video,
    hls::stream<axis_pixel_t>& m_axis_video,

    ap_uint<1>                 requested_scale_enable,
    scaler_resolution_t        requested_resolution,
    scaler_aspect_t            requested_aspect,
    scaler_interpolation_t     requested_interpolation,

    ap_uint<1>&                active_scale_enable_status,
    scaler_resolution_t&       active_resolution_status,
    scaler_aspect_t&           active_aspect_status,
    scaler_interpolation_t&    active_interpolation_status,
    ap_uint<1>&                pending_status
) {
#pragma HLS INTERFACE axis port=s_axis_video
#pragma HLS INTERFACE axis port=m_axis_video

#pragma HLS INTERFACE ap_none port=requested_scale_enable
#pragma HLS INTERFACE ap_none port=requested_resolution
#pragma HLS INTERFACE ap_none port=requested_aspect
#pragma HLS INTERFACE ap_none port=requested_interpolation

#pragma HLS INTERFACE ap_none port=active_scale_enable_status
#pragma HLS INTERFACE ap_none port=active_resolution_status
#pragma HLS INTERFACE ap_none port=active_aspect_status
#pragma HLS INTERFACE ap_none port=active_interpolation_status
#pragma HLS INTERFACE ap_none port=pending_status

#pragma HLS INTERFACE ap_ctrl_none port=return
#pragma HLS PIPELINE II=1

    /* Configuracion utilizada realmente por el datapath. */
    static ap_uint<1> active_scale_enable = 0;
    static scaler_resolution_t active_resolution = SCALER_RES_VGA;
    static scaler_aspect_t active_aspect = SCALER_ASPECT_CROP;
    static scaler_interpolation_t active_interpolation = SCALER_NEAREST;

    /* Estado actual de la maquina. */
    static scaler_state_t scaler_state = SCALER_READ_INPUT;

    /*
     * Buffer de una linea. Se llena mientras se genera su primera copia y
     * se reutiliza para producir las copias verticales restantes.
     */
    static pixel_t line_buffer[INPUT_WIDTH];

    /* Coordenadas del stream de entrada. */
    static coordinate_t input_x = 0;
    static coordinate_t input_y = 0;

    /* Informacion del pixel que se esta repitiendo horizontalmente. */
    static pixel_t current_pixel = 0;
    static ap_uint<1> current_input_last = 0;

    /* Contadores de repeticion y direccion de lectura del buffer. */
    static repeat_count_t horizontal_repeat = 0;
    static repeat_count_t remaining_vertical_repeats = 0;
    static coordinate_t replay_index = 0;

    /*
     * El TUSER original se encuentra en una fila descartada. Esta bandera
     * permanece activa hasta enviar el primer pixel conservado.
     */
    static ap_uint<1> first_scaled_output_pending = 0;

    axis_pixel_t input_packet;
    axis_pixel_t output_packet;

    repeat_count_t scale_factor;
    ap_uint<1> last_horizontal_copy;
    ap_uint<1> output_end_of_line;

    /* Mantener salidas conocidas aunque una interfaz este bloqueada. */
    active_scale_enable_status = active_scale_enable;
    active_resolution_status = active_resolution;
    active_aspect_status = active_aspect;
    active_interpolation_status = active_interpolation;

    pending_status =
        (requested_scale_enable != active_scale_enable) ||
        (requested_resolution != active_resolution) ||
        (requested_aspect != active_aspect) ||
        (requested_interpolation != active_interpolation);

    switch (scaler_state.to_uint()) {

    case SCALER_READ_INPUT:
        /* Este es el unico estado que acepta nuevos pixeles. */
        input_packet = s_axis_video.read();

        /*
         * TUSER inicia un frame. Toda la configuracion solicitada se
         * registra conjuntamente para no cambiarla dentro de una imagen.
         */
        if (input_packet.user == 1) {
            input_x = 0;
            input_y = 0;

            active_scale_enable = requested_scale_enable;
            active_resolution = requested_resolution;
            active_aspect = requested_aspect;
            active_interpolation = requested_interpolation;

            first_scaled_output_pending = scaling_is_active(
                requested_scale_enable,
                requested_resolution
            );
        }

        /*
         * En bypass se conserva el paquete completo, incluidas sus senales
         * laterales originales.
         */
        if (!scaling_is_active(
                active_scale_enable,
                active_resolution
            )) {

            m_axis_video.write(input_packet);

        /* Las filas exteriores al recorte se consumen y se descartan. */
        } else if (
            (input_y < CROP_FIRST_ROW) ||
            (input_y >= CROP_END_ROW)
        ) {
            /* El paquete se descarta, pero sus coordenadas deben avanzar. */

        } else {
            /*
             * Primera copia vertical: guardar el pixel para futuros
             * recorridos y prepararlo para su repeticion horizontal.
             */
            current_pixel = input_packet.data;
            current_input_last = input_packet.last;
            line_buffer[input_x] = input_packet.data;

            horizontal_repeat = 0;
            scaler_state = SCALER_OUTPUT_LIVE_PIXEL;
        }

        /*
         * Las coordenadas describen la entrada y avanzan exactamente una vez
         * por cada paquete consumido. Los ciclos de repeticion posteriores no
         * aceptan nuevos paquetes y, por tanto, no deben modificarlas.
         */
        advance_input_position(
            input_packet.last,
            input_x,
            input_y
        );

        break;


    case SCALER_OUTPUT_LIVE_PIXEL:
        /* Repeticion horizontal del ultimo pixel aceptado. */
        scale_factor = get_scale_factor(active_resolution);

        last_horizontal_copy =
            (horizontal_repeat == (scale_factor - 1));

        /* TLAST solo acompana a la ultima copia del ultimo pixel. */
        output_end_of_line =
            current_input_last && last_horizontal_copy;

        output_packet = make_scaled_packet(
            current_pixel,
            first_scaled_output_pending,
            output_end_of_line
        );

        /* write() espera si el receptor mantiene TREADY a cero. */
        m_axis_video.write(output_packet);

        if (first_scaled_output_pending == 1) {
            first_scaled_output_pending = 0;
        }

        if (!last_horizontal_copy) {
            horizontal_repeat++;

        } else {
            horizontal_repeat = 0;

            if (current_input_last == 1) {
                /*
                 * La primera copia de la linea ha terminado y el buffer ya
                 * contiene todos sus pixeles.
                 */
                remaining_vertical_repeats = scale_factor - 1;
                replay_index = 0;
                scaler_state = SCALER_LOAD_REPLAY_PIXEL;

            } else {
                scaler_state = SCALER_READ_INPUT;
            }
        }

        break;


    case SCALER_LOAD_REPLAY_PIXEL:
        /*
         * Separar la lectura permite a HLS implementar line_buffer mediante
         * una memoria sincrona con latencia de lectura.
         */
        current_pixel = line_buffer[replay_index];
        horizontal_repeat = 0;
        scaler_state = SCALER_OUTPUT_REPLAY_PIXEL;

        break;


    case SCALER_OUTPUT_REPLAY_PIXEL:
        /*
         * Cada recorrido completo del buffer crea una copia vertical,
         * manteniendo tambien la repeticion horizontal.
         */
        scale_factor = get_scale_factor(active_resolution);

        last_horizontal_copy =
            (horizontal_repeat == (scale_factor - 1));

        output_end_of_line =
            (replay_index == LAST_INPUT_COLUMN) &&
            last_horizontal_copy;

        output_packet = make_scaled_packet(
            current_pixel,
            0,
            output_end_of_line
        );

        m_axis_video.write(output_packet);

        if (!last_horizontal_copy) {
            horizontal_repeat++;

        } else {
            horizontal_repeat = 0;

            if (replay_index == LAST_INPUT_COLUMN) {
                /* Se ha generado una linea vertical completa. */
                replay_index = 0;

                if (remaining_vertical_repeats == 1) {
                    remaining_vertical_repeats = 0;
                    scaler_state = SCALER_READ_INPUT;

                } else {
                    remaining_vertical_repeats--;
                    scaler_state = SCALER_LOAD_REPLAY_PIXEL;
                }

            } else {
                replay_index++;
                scaler_state = SCALER_LOAD_REPLAY_PIXEL;
            }
        }

        break;


    default:
        /* Recuperacion defensiva frente a un estado interno invalido. */
        scaler_state = SCALER_READ_INPUT;
        input_x = 0;
        input_y = 0;
        horizontal_repeat = 0;
        remaining_vertical_repeats = 0;
        replay_index = 0;
        first_scaled_output_pending = 0;

        break;
    }

    /* Publicar cualquier cambio aplicado al recibir TUSER. */
    active_scale_enable_status = active_scale_enable;
    active_resolution_status = active_resolution;
    active_aspect_status = active_aspect;
    active_interpolation_status = active_interpolation;

    pending_status =
        (requested_scale_enable != active_scale_enable) ||
        (requested_resolution != active_resolution) ||
        (requested_aspect != active_aspect) ||
        (requested_interpolation != active_interpolation);
}


/* Determina si el frame debe atravesar el camino de escalado. */
static bool scaling_is_active(
    ap_uint<1> scale_enable,
    scaler_resolution_t resolution
) {
#pragma HLS INLINE

    return
        (scale_enable == 1) &&
        (
            (resolution == SCALER_RES_720P) ||
            (resolution == SCALER_RES_1080P)
        );
}


/* Traduce el modo de resolucion a su factor entero de repeticion. */
static repeat_count_t get_scale_factor(
    scaler_resolution_t resolution
) {
#pragma HLS INLINE

    if (resolution == SCALER_RES_720P) {
        return SCALE_FACTOR_720P;
    }

    if (resolution == SCALER_RES_1080P) {
        return SCALE_FACTOR_1080P;
    }

    return SCALE_FACTOR_BYPASS;
}


/* Construye un paquete AXI4-Stream con TUSER y TLAST regenerados. */
static axis_pixel_t make_scaled_packet(
    pixel_t pixel,
    ap_uint<1> start_of_frame,
    ap_uint<1> end_of_line
) {
#pragma HLS INLINE

    axis_pixel_t output_packet;

    output_packet.data = pixel;
    output_packet.keep = -1;
    output_packet.strb = -1;
    output_packet.user = start_of_frame;
    output_packet.last = end_of_line;
    output_packet.id = 0;
    output_packet.dest = 0;

    return output_packet;
}


/*
 * Actualiza las coordenadas de entrada utilizando TLAST como referencia.
 * El comienzo del siguiente frame, indicado por TUSER, reinicia ambas
 * coordenadas en la funcion top; por eso aqui no hace falta comparar la fila
 * actual con la altura total ni reiniciar input_y al terminar el frame.
 */
static void advance_input_position(
    ap_uint<1> end_of_line,
    coordinate_t& input_x,
    coordinate_t& input_y
) {
#pragma HLS INLINE

    if (end_of_line == 1) {
        input_x = 0;
        input_y++;

    } else {
        input_x++;
    }
}
