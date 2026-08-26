#ifndef VIDEO_SCALER_HPP
#define VIDEO_SCALER_HPP

#include <ap_int.h>
#include <ap_axi_sdata.h>
#include <hls_stream.h>

/* Un pixel RGB: 8 bits por componente. */
typedef ap_uint<24> pixel_t;

/*
 * Paquete AXI4-Stream Video.
 *
 * TDATA transporta el pixel RGB de 24 bits, TUSER identifica el primer
 * pixel del frame y TLAST identifica el ultimo pixel de cada linea.
 * Las senales de handshake TVALID y TREADY son generadas por hls::stream.
 */
typedef ap_axiu<24, 1, 1, 1> axis_pixel_t;

/* Tipos de las senales discretas de configuracion. */
typedef ap_uint<2> scaler_resolution_t;
typedef ap_uint<2> scaler_aspect_t;
typedef ap_uint<1> scaler_interpolation_t;

/* Resoluciones de salida soportadas por la plataforma. */
static const scaler_resolution_t SCALER_RES_VGA   = 0;
static const scaler_resolution_t SCALER_RES_720P  = 1;
static const scaler_resolution_t SCALER_RES_1080P = 2;

/* Politicas disponibles para adaptar la relacion de aspecto. */
static const scaler_aspect_t SCALER_ASPECT_CROP      = 0;
static const scaler_aspect_t SCALER_ASPECT_LETTERBOX = 1;
static const scaler_aspect_t SCALER_ASPECT_STRETCH   = 2;

/* Algoritmos de interpolacion previstos. */
static const scaler_interpolation_t SCALER_NEAREST  = 0;
static const scaler_interpolation_t SCALER_BILINEAR = 1;

/*
 * Nucleo HLS de escalado de video.
 *
 * La configuracion solicitada llega como senales discretas desde el wrapper
 * AXI4-Lite. La configuracion activa solo se actualiza al aceptar el primer
 * pixel de un nuevo frame, evitando cambios dentro de una misma imagen.
 */
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
);

#endif
