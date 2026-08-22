#ifndef VIDEO_FILTER_HPP
#define VIDEO_FILTER_HPP

#include "ap_int.h"
#include "ap_axi_sdata.h"
#include "hls_stream.h"

/* Pixel RGB888: 8 bits por componente. */
typedef ap_uint<24> pixel_t;

/* Senal fisica de dos bits para seleccionar hasta cuatro modos. */
typedef ap_uint<2> filter_mode_t;

/*
 * Paquete de video AXI4-Stream:
 *   24 bits de TDATA;
 *   1 bit de TUSER;
 *   1 bit de TID;
 *   1 bit de TDEST.
 *
 * TLAST, TKEEP y TSTRB tambien forman parte del tipo.
 */
typedef ap_axiu<24, 1, 1, 1> axis_pixel_t;

/*
 * Los valores simbolicos se definen mediante un enum, pero el puerto fisico
 * sigue utilizando filter_mode_t para garantizar que tenga dos bits.
 */
enum filter_mode_value_t {
    FILTER_BYPASS    = 0,
    FILTER_GRAYSCALE = 1,
    FILTER_SOBEL     = 2
};

const filter_mode_t FILTER_LAST_IMPLEMENTED = FILTER_SOBEL;
/* Funcion top sintetizada como IP. */
void video_filter(
    hls::stream<axis_pixel_t>& s_axis_video,
    hls::stream<axis_pixel_t>& m_axis_video,
    filter_mode_t              requested_mode,
    filter_mode_t&             active_mode_status,
    ap_uint<1>&                pending_status
);

#endif
