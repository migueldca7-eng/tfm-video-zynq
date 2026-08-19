# Procesador de vídeo HLS

Este directorio contiene el acelerador de vídeo desarrollado con Vivado HLS
2019.1 para la Zybo Z7-10. El bloque recibe y entrega vídeo RGB888 mediante
AXI4-Stream y permite cambiar el procesamiento desde el PS sin regenerar el
bitstream.

## Estructura

```text
src/video_filter.hpp                 Tipos, modos e interfaz de la función top
src/video_filter.cpp                 Implementación sintetizable
tb/tb_video_filter.cpp               Testbench funcional en C++
rtl_tb/tb_video_filter_rtl.sv        Testbench del RTL generado por HLS
rtl_tb/run_video_filter_rtl_tb.tcl   Ejecución de la simulación RTL
```

El proyecto generado de Vivado HLS permanece en `work/` y no se versiona. El
IP exportado necesario para reconstruir Vivado se conserva en
`vivado/ip/video_filter_1.0`.

## Interfaz sintetizada

La función top `video_filter` utiliza:

- `s_axis_video`: entrada AXI4-Stream Video RGB888.
- `m_axis_video`: salida AXI4-Stream Video RGB888.
- `requested_mode`: modo solicitado de 2 bits, mediante `ap_none`.
- `active_mode_status`: modo que procesa el frame actual.
- `pending_status`: indica que la petición todavía no se ha aplicado.
- `ap_ctrl_none`: funcionamiento continuo, sin transacción de arranque/parada.

`TUSER` identifica el primer píxel de un frame y `TLAST` el último píxel de
cada línea. El bloque conserva también `TKEEP`, `TSTRB`, `TID` y `TDEST`.

## Modos de procesamiento

| Valor | Nombre | Resultado |
|---:|---|---|
| 0 | `FILTER_BYPASS` | Píxel RGB888 sin modificar |
| 1 | `FILTER_GRAYSCALE` | Intensidad replicada en R, G y B |
| 2 | `FILTER_SOBEL` | Magnitud aproximada del gradiente en escala de grises |

La conversión a gris utiliza coeficientes enteros cuya suma es 256:

```text
gray = (77·R + 150·G + 29·B) >> 8
```

Así se evita la aritmética en coma flotante. Las multiplicaciones y las dos
sumas se separaron en etapas para cumplir el reloj de 150 MHz.

El Sobel calcula los gradientes horizontal y vertical de una ventana 3 × 3 y
emplea la aproximación:

```text
magnitude = min(255, |Gx| + |Gy|)
```

Los bordes de la imagen se generan en negro porque no disponen de los nueve
vecinos necesarios.

## Aplicación segura entre frames

El modo solicitado puede cambiar en cualquier instante, pero `active_mode` se
actualiza únicamente al aceptar un paquete con `TUSER=1`. El primer píxel del
nuevo frame ya se procesa con el modo nuevo. Mientras ambos valores difieren,
`pending_status` permanece activo.

El wrapper RTL situado en `rtl/video_filter/` rechaza el valor 3 antes de que
llegue al acelerador. Esta separación mantiene el datapath HLS dedicado al
procesamiento y concentra la validación y AXI4-Lite en el wrapper.

## Arquitectura del Sobel

El Sobel está dimensionado para la cámara VGA de 640 × 480. Utiliza:

- Dos buffers de línea de 640 intensidades de 8 bits.
- Una ventana 3 × 3 completamente particionada.
- Un buffer circular de 641 paquetes AXI para alinear píxeles y metadatos.
- Tres estados internos: `FILL`, `STREAM` y `FLUSH`.

Durante `FILL` se almacenan los 641 paquetes necesarios para disponer del
vecindario futuro. En `STREAM`, por cada paquete nuevo se procesa y entrega el
paquete retrasado correspondiente. Tras el último píxel de entrada, `FLUSH`
vacía los paquetes que todavía están en el buffer. De esta forma se conserva
el número de píxeles y `TUSER`/`TLAST` siguen asociados a su posición original.

Esta limitación VGA solo afecta al Sobel. Bypass y escala de grises procesan el
stream directamente y no dependen del ancho de la imagen.

## Síntesis

La solución final se sintetizó para `xc7z010-clg400-1` con periodo objetivo de
6,67 ns, correspondiente a 150 MHz.

| Métrica | Resultado estimado |
|---|---:|
| Periodo | 5,469 ns |
| Latencia | 5 ciclos |
| Intervalo de iniciación | 1 ciclo |
| BRAM 18K | 4 |
| DSP48E | 0 |
| Flip-flops | 4 145 |
| LUT | 4 951 |

Un intervalo de iniciación de un ciclo permite aceptar un píxel por ciclo una
vez lleno el pipeline. El periodo estimado es inferior al objetivo, por lo que
la solución cumple la restricción de HLS. El diseño Vivado completo también se
implementó cumpliendo timing.

## Verificación

El testbench C++ comprueba:

- Dos frames consecutivos en bypass.
- Dos frames consecutivos en escala de grises.
- Cambios bypass ↔ escala de grises entre frames.
- Un frame VGA Sobel frente a un modelo software independiente.
- Bordes negros, alineación AXI y salida segura de Sobel hacia bypass.

El testbench SystemVerilog verifica el RTL generado por HLS, incluyendo
backpressure, las fases `FILL`/`STREAM`/`FLUSH` y la conservación de todos los
paquetes AXI. Esta prueba explícita permite observar el comportamiento del IP
libre (`ap_ctrl_none`) ciclo a ciclo.

Finalmente, el IP se integró en la rama de cámara del Block Design y se validó
físicamente por HDMI. Los comandos `filter 0`, `filter 1` y `filter 2`
seleccionaron correctamente bypass, escala de grises y Sobel en tiempo real.

## Integración y control

El flujo integrado es:

```text
OV7670 -> Video In to AXI4-Stream -> video_filter -> selector de fuente
```

El wrapper `video_filter_axi_control` expone dos registros en la dirección base
`0x43C30000`:

| Offset | Registro | Contenido |
|---:|---|---|
| `0x00` | `FILTER_CONTROL` | Bits 1:0: modo solicitado |
| `0x04` | `FILTER_STATUS` | Bits 1:0: modo activo; bit 2: pendiente |

La aplicación bare-metal permite escribir el registro mediante:

```text
filter <0..2>
```
