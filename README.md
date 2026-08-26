# TFM Video Zynq

Plataforma SoC de vídeo reconfigurable desarrollada sobre una Zybo Z7-10 con
Zynq-7000. El sistema combina lógica programable, software bare-metal y memoria
DDR para generar o capturar vídeo, procesarlo, cambiar su formato y mostrarlo
por HDMI con un único bitstream.

## Estado del proyecto

La plataforma final está implementada y validada sobre la placa. Incluye:

- TPG propio en Verilog con ocho patrones y salida AXI4-Stream Video.
- Cámara OV7670 en RGB888 y resolución nativa de 640 × 480.
- Selector AXI4-Stream entre TPG y cámara, con conmutación en frontera de frame.
- Filtro HLS de cámara con bypass, escala de grises y Sobel.
- AXI VDMA con triple buffering en DDR.
- Tres perfiles de salida: 640 × 480p60, 1280 × 720p60 y 1920 × 1080p30.
- Escalador HLS de cámara: VGA en bypass y recorte central 16:9 con vecino más
  próximo ×2/×3 para 720p y 1080p.
- Transmisor HDMI/TMDS propio en RTL, con codificación, serialización 10:1 DDR y
  salida diferencial.
- Wrappers AXI4-Lite propios para TPG, selector, filtro y escalador.
- Aplicación para Xilinx SDK 2019.1 con intérprete de comandos UART.
- Configuración solicitada/activa y cambios seguros entre frames.
- Script Tcl canónico para reconstruir el proyecto Vivado.

Se han probado físicamente los patrones, la cámara, los tres filtros, la
conmutación de fuente, el HDMI propio y las tres resoluciones tanto con TPG
como con cámara. El diseño final genera bitstream y cumple timing.

## Plataforma

- Placa: Digilent Zybo Z7-10.
- Dispositivo: `xc7z010clg400-1`.
- Herramientas: Vivado, Xilinx SDK y Vivado HLS 2019.1.
- Formato de píxel: RGB888, un píxel por beat AXI4-Stream.
- Control: AXI4-Lite desde el PS y consola UART a 115200 8N1.

## Arquitectura final

```text
TPG RTL --------------------------------------\
                                               -> Selector AXI4-Stream -> VDMA S2MM
OV7670 -> captura -> filtro HLS ---------------/                          |
                                                                           v
                                                                      DDR (3 frames)
                                                                           |
                                                                           v
VDMA MM2S -> escalador HLS -> AXI4-Stream to Video Out -> HDMI/TMDS RTL -> monitor
                               ^
                               |
                       VTC + reloj de píxel

UART -> aplicación bare-metal -> AXI4-Lite -> TPG / selector / filtro / escalador
                                    `-------> VDMA / VTC / Clock Wizard / cámara
```

El filtro está únicamente en la rama de cámara. El escalador se sitúa después
de MM2S: la cámara siempre se captura y almacena como VGA y se adapta al tamaño
de salida al leerla. Con TPG, el escalador permanece en bypass porque el TPG ya
genera el perfil solicitado.

## Funcionalidades configurables

### TPG

| ID | Patrón |
|---:|---|
| 0 | Negro |
| 1 | Color sólido configurable |
| 2 | Barras de color |
| 3 | Rampa horizontal periódica |
| 4 | Rampa vertical periódica |
| 5 | Damero de 32 × 32 píxeles |
| 6 | Rejilla cada 32 píxeles |
| 7 | Rampa temporal |

### Filtro HLS

| ID | Modo |
|---:|---|
| 0 | Bypass RGB888 |
| 1 | Escala de grises |
| 2 | Detección de bordes Sobel 3 × 3 |

El Sobel usa dos buffers de línea y está dimensionado para la cámara VGA. Los
bordes sin nueve vecinos se generan en negro.

### Resolución y reescalado

| ID | Salida | TPG | Cámara |
|---:|---|---|---|
| 0 | 640 × 480p60 | Generación nativa | VGA en bypass |
| 1 | 1280 × 720p60 | Generación nativa | Crop 640 × 360 + nearest ×2 |
| 2 | 1920 × 1080p30 | Generación nativa | Crop 640 × 360 + nearest ×3 |

El recorte elimina 60 líneas superiores y 60 inferiores para convertir 4:3 en
16:9 sin deformar la imagen. Los modos se aplican al comienzo de un frame.

### HDMI/TMDS propio

El transmisor se divide en tres capas:

- `tmds_encoder.v`: convierte cada canal de 8 bits en símbolos TMDS de 10 bits
  y mantiene la disparidad acumulada.
- `tmds_serializer.v`: usa OSERDESE2 maestro/esclavo para serializar 10:1 en
  DDR con un reloj cinco veces superior al reloj de píxel.
- `hdmi_tx_rtl.v`: instancia tres canales de datos, el canal de reloj y OBUFDS
  para los cuatro pares diferenciales.

Durante blanking, HSync/VSync se codifican como palabras de control TMDS. No se
implementan audio, InfoFrames, HDCP, EDID/DDC ni hot-plug.

## Mapas de control

| Bloque | Dirección base |
|---|---:|
| TPG | `0x41220000` |
| Selector de fuente | `0x43C20000` |
| Filtro HLS | `0x43C30000` |
| Escalador HLS | `0x43C40000` |

Los mapas detallados y el flujo de la aplicación están documentados en
[`sw/vitis/README.md`](sw/vitis/README.md). El nombre de esa carpeta se
mantiene por compatibilidad histórica; la herramienta utilizada es Xilinx SDK
2019.1.

## Verificación

Las fuentes incluyen testbenches RTL y C para:

- TPG y wrapper AXI4-Lite.
- Selector de fuente y cambio en SOF.
- Filtro HLS y wrapper de control.
- Codificador TMDS, serializador y top HDMI.
- Escalador HLS, marcas `TUSER`/`TLAST`, bypass y factores ×2/×3.
- Backpressure y estabilidad de los paquetes AXI4-Stream.

Además se validó una reconstrucción limpia con
`vivado/scripts/create_project.tcl`, el Block Design y el bitstream integrado.
La salida 1080p30 fue aceptada por una televisión; un monitor de PC concreto no
admitió ese modo, aunque sí mostró VGA y 720p.

## Estructura del repositorio

```text
tfm-video-zynq/
|-- docs/decisions/           memoria técnica y decisiones
|-- hls/
|   |-- video_proc/           filtro bypass/gris/Sobel
|   `-- video_scaler/         recorte y escalado de cámara
|-- rtl/
|   |-- hdmi_tx/              transmisor HDMI/TMDS propio
|   |-- source_selector/      selector de fuente
|   |-- tpg/                  generador de patrones
|   |-- video_filter/         wrapper AXI-Lite del filtro
|   `-- video_scaler/         wrapper AXI-Lite del escalador
|-- sw/vitis/                 fuentes para Xilinx SDK 2019.1
|-- vivado/
|   |-- constraints/
|   |-- ip/                   IP HLS exportados
|   `-- scripts/              Tcl de reconstrucción
`-- work/                     artefactos generados, no versionados
```

## Reconstrucción

El proyecto Vivado se reconstruye con:

```text
vivado -mode batch -source vivado/scripts/create_project.tcl
```

También puede ejecutarse desde la Tcl Console de Vivado:

```tcl
source vivado/scripts/create_project.tcl
```

Después se valida el Block Design, se generan los output products y el
bitstream, y se exporta el hardware marcando `Include bitstream`. Las
instrucciones completas son:

- [`vivado/scripts/README.md`](vivado/scripts/README.md)
- [`sw/vitis/README.md`](sw/vitis/README.md)

## Criterio de versionado

Se versionan fuentes RTL/HLS/C, testbenches, constraints, IP exportados,
scripts Tcl y documentación. No se versionan proyectos completos de Vivado o
SDK, bitstreams, HDF, ELF, cachés, journals ni resultados de implementación.

```text
main       hitos estables validados
develop    integración de funcionalidades
feature/*  desarrollo aislado
```

## Ampliaciones posibles

- Interpolación bilineal, letterbox o stretch en el escalador.
- Interfaz gráfica de control por puerto serie.
- Lectura EDID/DDC, audio o entrada HDMI.
- Comparación de recursos con IP equivalentes de AMD.
