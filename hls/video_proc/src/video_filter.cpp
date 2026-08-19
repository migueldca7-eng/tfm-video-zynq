#include "video_filter.hpp"

/*
 * La camara trabaja con un ancho fijo de 640 pixeles. Para alinear el
 * resultado Sobel con el centro de una ventana 3x3 hay que retrasar una
 * linea completa y un pixel adicional.
 */
static const unsigned int SOBEL_FRAME_WIDTH  = 640U;
static const unsigned int SOBEL_FRAME_HEIGHT = 480U;
static const unsigned int SOBEL_DELAY_PIXELS = SOBEL_FRAME_WIDTH + 1U;

/* Estados internos de la ruta Sobel. */
typedef ap_uint<2> sobel_state_t;

enum sobel_state_value_t {
    SOBEL_FILL   = 0,
    SOBEL_STREAM = 1,
    SOBEL_FLUSH  = 2
};

/*
 * Representacion compacta de un paquete AXI4-Stream dentro del buffer.
 * Al almacenarlo como una unica palabra, HLS puede inferir una memoria BRAM
 * ancha en lugar de separar cada campo del paquete en memorias pequenas.
 */
typedef ap_uint<34> packed_axis_pixel_t;

static packed_axis_pixel_t pack_axis_pixel(const axis_pixel_t& packet)
{
#pragma HLS INLINE

    packed_axis_pixel_t packed = 0;

    packed.range(23, 0)  = packet.data;
    packed.range(26, 24) = packet.keep;
    packed.range(29, 27) = packet.strb;
    packed[30]            = packet.user;
    packed[31]            = packet.last;
    packed[32]            = packet.id;
    packed[33]            = packet.dest;

    return packed;
}

static axis_pixel_t unpack_axis_pixel(packed_axis_pixel_t packed)
{
#pragma HLS INLINE

    axis_pixel_t packet;

    packet.data = packed.range(23, 0);
    packet.keep = packed.range(26, 24);
    packet.strb = packed.range(29, 27);
    packet.user = packed[30];
    packet.last = packed[31];
    packet.id   = packed[32];
    packet.dest = packed[33];

    return packet;
}

/*
 * Avanza una posicion dentro del futuro buffer circular de Sobel. La
 * comparacion explicita evita implementar una operacion modulo por 641.
 */
static void advance_buffer_index(ap_uint<10>& buffer_index)
{
    if (buffer_index == (SOBEL_DELAY_PIXELS - 1U)) {
        buffer_index = 0;
    } else {
        buffer_index++;
    }
}

/*
 * Primera etapa registrada del arbol de sumas de luminancia.
 * Mantener esta funcion fuera de linea crea una frontera de planificacion:
 * recibe dos productos y entrega su suma un ciclo despues, admitiendo una
 * operacion nueva en cada ciclo.
 */
static ap_uint<16> add_gray_stage_1(
    ap_uint<16> operand_a,
    ap_uint<16> operand_b
)
{
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
#pragma HLS LATENCY min=1 max=1

    return operand_a + operand_b;
}

/*
 * Segunda etapa registrada del arbol de sumas de luminancia.
 * Se utiliza una funcion distinta para que HLS genere una segunda instancia
 * y no intente compartir el mismo sumador entre dos operaciones por pixel.
 */
static ap_uint<16> add_gray_stage_2(
    ap_uint<16> operand_a,
    ap_uint<16> operand_b
)
{
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1
#pragma HLS LATENCY min=1 max=1

    return operand_a + operand_b;
}

/*
 * Convierte un pixel RGB888 en una intensidad de ocho bits.
 * Los coeficientes aproximan la luminancia mediante una division por 256:
 * gray = (77*R + 150*G + 29*B) / 256.
 *
 * Esta funcion es comun a los modos grayscale y Sobel para mantener una
 * unica implementacion de la conversion RGB a gris en el codigo fuente.
 */
static ap_uint<8> rgb_to_gray(pixel_t pixel_in)
{
#pragma HLS INLINE off
#pragma HLS PIPELINE II=1

    const ap_uint<8> red   = pixel_in.range(23, 16);
    const ap_uint<8> green = pixel_in.range(15, 8);
    const ap_uint<8> blue  = pixel_in.range(7, 0);

    const ap_uint<8> RED_COEFFICIENT   = 77;
    const ap_uint<8> GREEN_COEFFICIENT = 150;
    const ap_uint<8> BLUE_COEFFICIENT  = 29;

    ap_uint<16> weighted_red;
    ap_uint<16> weighted_green;
    ap_uint<16> weighted_blue;
    ap_uint<16> partial_sum;
    ap_uint<16> weighted_sum;

    /* Primera etapa: calcular en paralelo la aportacion de cada canal. */
    weighted_red   = red   * RED_COEFFICIENT;
    weighted_green = green * GREEN_COEFFICIENT;
    weighted_blue  = blue  * BLUE_COEFFICIENT;

    /*
     * Segunda y tercera etapas: registrar cada suma por separado para
     * evitar que HLS fusione una multiplicacion y una suma en el mismo DSP.
     */
    partial_sum  = add_gray_stage_1(weighted_red, weighted_green);
    weighted_sum = add_gray_stage_2(partial_sum, weighted_blue);

    return (ap_uint<8>)(weighted_sum >> 8);
}

/*
 * Calcula la magnitud Sobel aproximada de una ventana de intensidades 3x3.
 * Gx y Gy se mantienen con signo; la saturacion a ocho bits solo se aplica
 * al resultado final para no perder informacion de los gradientes.
 */
static ap_uint<8> calculate_sobel(
    const ap_uint<8> window[3][3]
)
{
#pragma HLS INLINE

    /* Pixeles vecinos expresados con signo para aplicar coeficientes -1 y -2. */
    const ap_int<11> p00 = window[0][0];
    const ap_int<11> p01 = window[0][1];
    const ap_int<11> p02 = window[0][2];

    const ap_int<11> p10 = window[1][0];
    const ap_int<11> p12 = window[1][2];

    const ap_int<11> p20 = window[2][0];
    const ap_int<11> p21 = window[2][1];
    const ap_int<11> p22 = window[2][2];

    const ap_int<11> gx =
        -p00 + p02
        - (p10 << 1) + (p12 << 1)
        - p20 + p22;

    const ap_int<11> gy =
        -p00 - (p01 << 1) - p02
        + p20 + (p21 << 1) + p22;

    /* |Gx| + |Gy| evita implementar una raiz cuadrada en hardware. */
    const ap_uint<11> abs_gx =
        (gx < 0) ? (ap_uint<11>)(-gx) : (ap_uint<11>)gx;

    const ap_uint<11> abs_gy =
        (gy < 0) ? (ap_uint<11>)(-gy) : (ap_uint<11>)gy;

    const ap_uint<11> magnitude = abs_gx + abs_gy;

    /* La salida de video solo puede representar intensidades entre 0 y 255. */
    if (magnitude > 255) {
        return 255;
    }

    return (ap_uint<8>)magnitude;
}

/*
 * Actualiza los buffers de linea y la ventana 3x3 con una nueva intensidad.
 * Devuelve true cuando la ventana representa un pixel interior para el que
 * ya puede calcularse un resultado Sobel valido.
 */
static bool sobel_step(
    ap_uint<8>  current_gray,
    ap_uint<10> input_x,
    ap_uint<9>  input_y,
    ap_uint<8>& sobel_value
)
{
#pragma HLS INLINE

    /*
     * Cada posicion almacena la intensidad correspondiente a una columna.
     * Al ser static, los buffers y la ventana conservan su contenido entre
     * pixeles consecutivos.
     */
    static ap_uint<8> line_buffer_0[SOBEL_FRAME_WIDTH];
    static ap_uint<8> line_buffer_1[SOBEL_FRAME_WIDTH];
    static ap_uint<8> window[3][3];

    /*
     * Las iteraciones consecutivas procesan columnas distintas. Se mantiene
     * el orden de lectura y escritura dentro del mismo pixel, pero se eliminan
     * las falsas dependencias entre pixeles adyacentes.
     */
#pragma HLS DEPENDENCE variable=line_buffer_0 inter false
#pragma HLS DEPENDENCE variable=line_buffer_1 inter false

#pragma HLS ARRAY_PARTITION variable=window complete dim=0

    const unsigned int column = input_x.to_uint();

    ap_uint<8> previous_row;
    ap_uint<8> two_rows_ago;

    /* Recuperar el historial vertical antes de sobrescribir la columna. */
    previous_row = line_buffer_0[column];
    two_rows_ago = line_buffer_1[column];

    /* Actualizar el historial para la siguiente fila. */
    line_buffer_1[column] = previous_row;
    line_buffer_0[column] = current_gray;

    /* Desplazar las tres filas de la ventana una columna a la izquierda. */
    for (int row = 0; row < 3; row++) {
#pragma HLS UNROLL
        window[row][0] = window[row][1];
        window[row][1] = window[row][2];
    }

    /* Insertar por la derecha la nueva columna vertical. */
    window[0][2] = two_rows_ago;
    window[1][2] = previous_row;
    window[2][2] = current_gray;

    /*
     * Las primeras dos filas o columnas todavia no forman una ventana
     * completa. El llamador interpretara false como un pixel de borde.
     */
    if ((input_x < 2) || (input_y < 2)) {
        sobel_value = 0;
        return false;
    }

    sobel_value = calculate_sobel(window);
    return true;
}


/*
 * Aplica al pixel el modo de procesado que ya esta activo para el frame.
 * Esta funcion es auxiliar: video_filter sigue siendo el unico top HLS.
 */
static pixel_t apply_filter(
    pixel_t pixel_in,
    filter_mode_t mode
)
{
    ap_uint<8> gray;
    pixel_t pixel_out;

    switch (mode.to_uint()) {
    case FILTER_GRAYSCALE:
        gray = rgb_to_gray(pixel_in);

        pixel_out.range(23, 16) = gray;
        pixel_out.range(15, 8)  = gray;
        pixel_out.range(7, 0)   = gray;
        break;

    case FILTER_BYPASS:
    default:
        pixel_out = pixel_in;
        break;
    }

    return pixel_out;
}

/*
 * Funcion top sintetizada como un bloque de video AXI4-Stream continuo.
 * El modo solicitado llega como una senal discreta desde el wrapper AXI-Lite.
 */
void video_filter(
    hls::stream<axis_pixel_t>& s_axis_video,
    hls::stream<axis_pixel_t>& m_axis_video,
    filter_mode_t              requested_mode,
    filter_mode_t&             active_mode_status,
    ap_uint<1>&                pending_status
)
{
#pragma HLS INTERFACE axis port=s_axis_video
#pragma HLS INTERFACE axis port=m_axis_video

#pragma HLS INTERFACE ap_none port=requested_mode
#pragma HLS INTERFACE ap_none port=active_mode_status
#pragma HLS INTERFACE ap_none port=pending_status

#pragma HLS INTERFACE ap_ctrl_none port=return
#pragma HLS PIPELINE II=1



    /*
     * Al ser static, este valor se conserva entre pixeles y se sintetiza
     * como un registro dentro del bloque HLS.
     */
    static filter_mode_t active_mode = FILTER_BYPASS;

    /*
     * Estado persistente de la ruta Sobel. El buffer conserva paquetes AXI
     * completos para mantener TUSER, TLAST y el resto de senales alineados
     * con el pixel procesado.
     */
    static sobel_state_t sobel_state = SOBEL_FILL;
    static packed_axis_pixel_t circular_buffer[SOBEL_DELAY_PIXELS];

    /*
     * En STREAM, dos iteraciones consecutivas acceden a posiciones distintas.
     * Se conserva la dependencia interna de leer antes de sobrescribir cada
     * posicion, pero se elimina la falsa dependencia entre pixeles.
     */
#pragma HLS DEPENDENCE variable=circular_buffer inter false

    /*
     * Cursor del buffer circular. No se reinicia entre frames: FILL recorre
     * sus 641 posiciones completas y la correccion depende del orden relativo
     * de lectura/escritura, no de comenzar fisicamente en la posicion cero.
     */
    static ap_uint<10> buffer_index = 0;
    static ap_uint<10> buffered_pixels = 0;
    static ap_uint<10> input_x = 0;
    static ap_uint<9> input_y = 0;

    axis_pixel_t input_packet;
    axis_pixel_t output_packet;

    ap_uint<8> current_gray;
    ap_uint<8> sobel_value;

    bool sobel_valid;
    bool end_of_input_frame;

    /* Mantener salidas conocidas aunque una interfaz este bloqueada. */
    active_mode_status = active_mode;
    pending_status = (requested_mode != active_mode);

    /*
     * Durante FLUSH no se consume la entrada: primero se envian los paquetes
     * que siguen almacenados al final del frame Sobel.
     */
    if ((active_mode == FILTER_SOBEL) &&
        (sobel_state == SOBEL_FLUSH)) {

        output_packet = unpack_axis_pixel(circular_buffer[buffer_index]);
        output_packet.data = 0;

        m_axis_video.write(output_packet);

        advance_buffer_index(buffer_index);
        buffered_pixels--;

        if (buffered_pixels == 0) {
            sobel_state = SOBEL_FILL;
            input_x = 0;
            input_y = 0;
        }

    } else {

        /* Espera hasta recibir una transferencia AXI4-Stream valida. */
        input_packet = s_axis_video.read();

        /*
         * El modo solo cambia al comienzo de un frame. El wrapper AXI-Lite
         * valida previamente requested_mode, por lo que el nucleo HLS recibe
         * exclusivamente valores implementados.
         */
        if (input_packet.user == 1) {
            active_mode = requested_mode;

            /*
             * No es necesario reiniciar aqui el estado Sobel. Tras reset o
             * despues de completar FLUSH, el bloque ya queda en FILL, sin
             * pixeles pendientes y con las coordenadas en el origen.
             */
        }

        if (active_mode == FILTER_SOBEL) {

            /*
             * Los estados FILL y STREAM consumen exactamente un pixel de
             * entrada y, por tanto, actualizan las mismas memorias Sobel.
             * Mantener una unica llamada proporciona a HLS un solo punto de
             * acceso a los buffers de linea y evita duplicar esta logica al
             * desplegar la funcion inline.
             */
            current_gray = rgb_to_gray(input_packet.data);

            sobel_valid = sobel_step(
                current_gray,
                input_x,
                input_y,
                sobel_value
            );

            switch (sobel_state.to_uint()) {

            case SOBEL_FILL:

                /*
                 * Preparar las memorias Sobel mientras se acumulan los 641
                 * paquetes necesarios para alinear la salida.
                 */
                circular_buffer[buffer_index] = pack_axis_pixel(input_packet);
                advance_buffer_index(buffer_index);

                /*
                 * Comparar el valor anterior permite ejecutar en paralelo la
                 * decision de estado y el incremento del contador. Cuando el
                 * valor previo es 640, este paquete completa los 641 del FILL.
                 */
                if (buffered_pixels == (SOBEL_DELAY_PIXELS - 1U)) {
                    sobel_state = SOBEL_STREAM;
                }

                buffered_pixels++;

                if (input_packet.last == 1) {
                    input_x = 0;
                    input_y++;
                } else {
                    input_x++;
                }

                /* FILL consume entrada, pero todavia no genera salida. */
                break;

            case SOBEL_STREAM:

                /* Recuperar el paquete retrasado antes de sobrescribirlo. */
                output_packet = unpack_axis_pixel(circular_buffer[buffer_index]);
                circular_buffer[buffer_index] = pack_axis_pixel(input_packet);

                /*
                 * Replicar la intensidad Sobel en RGB. Los paquetes que no
                 * tienen una ventana completa pertenecen al borde negro.
                 */
                if (sobel_valid) {
                    output_packet.data.range(23, 16) = sobel_value;
                    output_packet.data.range(15, 8)  = sobel_value;
                    output_packet.data.range(7, 0)   = sobel_value;
                } else {
                    output_packet.data = 0;
                }

                end_of_input_frame =
                    (input_packet.last == 1) &&
                    (input_y == (SOBEL_FRAME_HEIGHT - 1U));

                advance_buffer_index(buffer_index);

                if (input_packet.last == 1) {
                    input_x = 0;
                    input_y++;
                } else {
                    input_x++;
                }

                m_axis_video.write(output_packet);

                if (end_of_input_frame) {
                    sobel_state = SOBEL_FLUSH;
                }

                break;

            default:

                /* Recuperacion defensiva ante un estado imposible. */
                sobel_state = SOBEL_FILL;
                buffer_index = 0;
                buffered_pixels = 0;
                input_x = 0;
                input_y = 0;
                break;
            }

        } else {

            /*
             * La ruta ya validada de bypass/grayscale permanece inmediata.
             * Copiar el paquete conserva todas las senales laterales AXI.
             */
            output_packet = input_packet;
            output_packet.data =
                apply_filter(input_packet.data, active_mode);

            m_axis_video.write(output_packet);
        }
    }

    /* Publicar el estado despues de cualquier cambio de modo. */
    active_mode_status = active_mode;

    /* El wrapper garantiza que requested_mode contiene un modo soportado. */
    pending_status = (requested_mode != active_mode);
}
