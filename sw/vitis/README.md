# Aplicación de control para Xilinx SDK 2019.1

Este directorio conserva la aplicación bare-metal que se ejecuta en el ARM
Cortex-A9 del Zynq. Inicializa la cadena de vídeo y permite controlar por UART
el TPG, la cámara, el filtro HLS, el escalador y los perfiles de salida.

El workspace generado de SDK no se versiona. La fuente que debe importarse es:

```text
sw/vitis/src/main.c
```

El nombre `sw/vitis` se mantiene por compatibilidad histórica con el
repositorio. La herramienta empleada en este proyecto es **Xilinx SDK 2019.1**.

## Arquitectura controlada

```text
TPG RTL --------------------------------------\
                                               -> selector -> VDMA S2MM -> DDR
OV7670 -> captura -> filtro HLS ---------------/                           |
                                                                            v
VDMA MM2S -> escalador HLS -> Video Out -> HDMI/TMDS RTL propio -> monitor
```

La cámara siempre se captura y almacena como 640 × 480 RGB888. Si se solicita
720p o 1080p, el escalador recorta la imagen a 640 × 360 y aplica vecino más
próximo ×2 o ×3 después de MM2S. El TPG genera cada resolución de forma nativa,
por lo que usa el escalador en bypass.

## Arranque de la aplicación

Al iniciar, el software:

1. Inicializa drivers de VDMA, VTC, GPIO e I2C/SCCB.
2. Configura el Clock Wizard y el VTC para VGA.
3. Resetea y configura S2MM/MM2S y los tres framebuffers.
4. Configura el TPG con barras de color en 640 × 480.
5. Deja filtro y escalador en bypass.
6. Selecciona el TPG y habilita la cadena.
7. Entra en el intérprete de comandos UART.

La OV7670 se inicializa bajo demanda al ejecutar `source 1`. Cuando deja de ser
la fuente activa se introduce en soft sleep.

## Memoria de vídeo

| Buffer | Dirección | Reserva |
|---:|---:|---:|
| 0 | `0x02000000` | 6 MiB |
| 1 | `0x02600000` | 6 MiB |
| 2 | `0x02C00000` | 6 MiB |

Para TPG, la VDMA usa el tamaño del perfil activo. Para cámara, ambos canales
se mantienen en VGA incluso cuando la salida se reescala. Esta separación evita
escribir en DDR píxeles duplicados artificialmente.

## Mapa AXI4-Lite

### TPG — `0x41220000`

| Offset | Registro | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `ENABLE` | R/W | bit 0: habilitación |
| `0x04` | `PATTERN` | R/W | bits [2:0]: patrón 0…7 |
| `0x08` | `SOLID_COLOR` | R/W | bits [23:0]: RGB888 |
| `0x0C` | `TEMPORAL_STEP` | R/W | bits [7:0]: paso por frame |
| `0x10` | `STATUS` | R | `busy`, `pending` y estado activo |
| `0x14` | `FRAME_PHASE` | R | fase de la rampa temporal |
| `0x18` | `FRAME_SIZE` | R/W | alto [31:16], ancho [15:0] |

### Selector — `0x43C20000`

| Offset | Registro | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `SOURCE_CONTROL` | R/W | bit 0: 0 TPG, 1 cámara |
| `0x04` | `SOURCE_STATUS` | R | bit 0 activo; bit 1 `pending` |

### Filtro HLS — `0x43C30000`

| Offset | Registro | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `FILTER_CONTROL` | R/W | bits [1:0]: 0 bypass, 1 gris, 2 Sobel |
| `0x04` | `FILTER_STATUS` | R | bits [1:0] activos; bit 2 `pending` |

### Escalador HLS — `0x43C40000`

| Offset | Registro | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `SCALER_CONTROL` | R/W | bit 0 enable; [2:1] resolución; [4:3] aspecto; bit 5 interpolación |
| `0x04` | `SCALER_STATUS` | R | configuración activa; bit 6 `pending` |

El wrapper solo acepta las combinaciones implementadas: bypass VGA o crop con
vecino más próximo para 720p/1080p. Los cores aplican la configuración al
comienzo de un frame.

## Consola UART

```text
115200 baudios, 8 bits, sin paridad, 1 bit de parada, sin control de flujo
```

Tras la inicialización aparece `tpg>`.

| Comando | Efecto |
|---|---|
| `help` | Muestra la ayuda |
| `status` | Lee TPG, fuente, filtro, escalador y resolución |
| `enable 0\|1` | Deshabilita/habilita el TPG terminando el frame actual |
| `pattern 0..7` | Selecciona el patrón |
| `color 0xRRGGBB` | Configura el color sólido |
| `step 0..255` | Configura el paso de la rampa temporal |
| `resolution 0..2` | Selecciona VGA, 720p o 1080p |
| `source 0\|1` | Selecciona TPG o cámara |
| `filter 0..2` | Selecciona bypass, gris o Sobel |

### Semántica de `resolution`

| Valor | Salida | Fuente TPG | Fuente cámara |
|---:|---|---|---|
| 0 | 640 × 480p60 | TPG VGA | Escalador bypass |
| 1 | 1280 × 720p60 | TPG 720p | Crop 640 × 360 + ×2 |
| 2 | 1920 × 1080p30 | TPG 1080p | Crop 640 × 360 + ×3 |

Con TPG, la función de cambio detiene la cadena y reconfigura TPG, VDMA, VTC y
Clock Wizard. Con cámara, la VDMA permanece VGA; se cambia el escalador y la
temporización de salida. Al conmutar de fuente se pasa temporalmente por VGA
para aplicar la política correcta antes del primer frame nuevo.

Todas las esperas por polling tienen timeout. Si falla una transición, el
software no declara activo un perfil incompleto.

## Crear el proyecto desde cero en Xilinx SDK

### 1. Exportar el hardware desde Vivado

1. Generar el bitstream del proyecto.
2. Seleccionar `File > Export > Export Hardware`.
3. Marcar `Include bitstream`.
4. Elegir una ubicación local al proyecto para el HDF.
5. Seleccionar `File > Launch SDK` y elegir el workspace.

### 2. Crear el Application Project

1. En SDK, seleccionar `File > New > Application Project`.
2. Usar `tpg_video_app` como nombre.
3. Seleccionar la hardware platform creada desde el HDF reciente.
4. Seleccionar el procesador `ps7_cortexa9_0`.
5. Seleccionar el sistema operativo `standalone`.
6. Crear o asociar un BSP para ese procesador.
7. Elegir la plantilla `Empty Application` y finalizar el asistente.

Si el asistente aparece vacío, pulsar `Back` y volver a avanzar, o cerrar la
especificación hardware abierta antes de repetirlo.

### 3. Importar `main.c`

Puede copiarse el archivo con el explorador o usar:

1. Clic derecho sobre `tpg_video_app/src`.
2. `Import > General > File System`.
3. Seleccionar `sw/vitis/src/main.c`.
4. Marcar el archivo y confirmar.

El resultado debe ser:

```text
tpg_video_app/
`-- src/
    `-- main.c
```

### 4. Regenerar y compilar

1. Clic derecho sobre el BSP y `Re-generate BSP Sources`.
2. Ejecutar `Project > Clean`.
3. Compilar primero el BSP y después `tpg_video_app`.
4. Comprobar que se genera `Debug/tpg_video_app.elf`.

Si `xparameters.h` no contiene `XPAR_VIDEO_SCALER_AXI_CON_0_BASEADDR`, la
plataforma o el BSP todavía usan un HDF antiguo. Debe actualizarse la hardware
platform antes de recompilar.

## Ejecutar en la placa

1. Conectar USB/JTAG, UART, HDMI y, para cámara, el adaptador a los PMOD usados
   por el proyecto docente.
2. Abrir la terminal a 115200 8N1.
3. En SDK, seleccionar `Xilinx Tools > Program FPGA` y usar el bitstream de la
   hardware platform actual.
4. Clic derecho sobre la aplicación: `Run As > Launch on Hardware (System
   Debugger)`.
5. Esperar al prompt `tpg>` y ejecutar `status`.

Secuencia rápida de validación:

```text
source 0
pattern 5
resolution 1
source 1
filter 1
resolution 2
filter 2
resolution 0
source 0
status
```

El modo 1080p30 no es aceptado por todos los monitores; se validó con una
televisión compatible.

## Pruebas superadas

- Ocho patrones y colores RGB.
- `busy`, `pending`, enable y rampa temporal.
- Comandos inválidos sin escrituras laterales.
- Cámara, soft sleep y conmutación bidireccional.
- Bypass, gris y Sobel.
- TPG y cámara en VGA, 720p y 1080p.
- Escalador frame-safe y estado activo/pendiente.
- Salida física mediante el HDMI/TMDS RTL propio.

## Artefactos generados

Workspaces, hardware platforms, BSP, HDF, bitstream y ELF se mantienen en
`work/` y no forman parte de las fuentes versionadas.
