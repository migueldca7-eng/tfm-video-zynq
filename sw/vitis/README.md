# Software de control de vídeo

Este directorio contiene el software bare-metal ejecutado por el procesador ARM
del Zynq para inicializar la cadena de vídeo basada en AXI VDMA.

El software se ha desarrollado y probado con Xilinx SDK 2019.1 sobre una
Zybo Z7-10.

## Cadena de vídeo validada

```text
TPG RTL
  -> AXI4-Stream S2MM
  -> AXI VDMA
  -> DDR
  -> AXI VDMA MM2S
  -> AXI4-Stream Video Out
  -> HDMI
```

La primera versión validada utiliza:

- Resolución: 640 x 480.
- Formato de píxel: RGB de 24 bits.
- Tamaño de píxel: 3 bytes.
- Stride: 1920 bytes.
- Tres framebuffers en DDR.
- Funcionamiento circular del VDMA.
- Sincronización interna entre los canales S2MM y MM2S.
- Patrón de prueba: cuatro barras verticales roja, verde, azul y blanca.

## Código fuente

El archivo principal es:

```text
src/main.c
```

El programa realiza las siguientes operaciones:

1. Localiza el AXI VDMA mediante los parámetros generados por el BSP.
2. Inicializa el driver `XAxiVdma`.
3. Comprueba que existen los canales S2MM y MM2S.
4. Reinicia ambos canales con timeout.
5. Configura la resolución, el stride y los tres framebuffers.
6. Arranca primero S2MM para escribir los frames del TPG en DDR.
7. Arranca MM2S para leer los frames y enviarlos a la salida HDMI.
8. Informa del proceso mediante la UART.

El TPG funciona de forma autónoma en la lógica programable y no necesita un
driver software ni una interfaz AXI4-Lite en esta versión.

## Distribución de los framebuffers

Los framebuffers comienzan en la dirección física `0x02000000`.

| Buffer | Dirección |
|---|---:|
| 0 | `0x02000000` |
| 1 | `0x020E1000` |
| 2 | `0x021C2000` |

Cada frame ocupa:

```text
640 x 480 x 3 = 921600 bytes = 0x000E1000 bytes
```

Los tres buffers terminan antes de `0x022A3000`.

## Requisitos del hardware

El Block Design de Vivado debe incluir:

- Zynq-7000 Processing System.
- AXI VDMA con canales S2MM y MM2S.
- Tres frame stores.
- AXI4-Stream de vídeo de 24 bits.
- Acceso del VDMA a la DDR del Processing System.
- TPG RTL conectado a `S_AXIS_S2MM`.
- `M_AXIS_MM2S` conectado al subsistema de salida de vídeo.
- Video Timing Controller y salida HDMI configurados para 640 x 480.

El software utiliza los identificadores y direcciones generados por el BSP.
No deben copiarse manualmente las direcciones AXI de otro diseño.

## Creación del proyecto en Xilinx SDK

1. Generar el bitstream en Vivado.
2. Exportar el hardware incluyendo el bitstream.
3. Abrir Xilinx SDK con el hardware exportado.
4. Crear un BSP para `ps7_cortexa9_0` con sistema operativo `standalone`.
5. Crear una aplicación C vacía asociada al BSP.
6. Añadir `src/main.c` al proyecto de aplicación.
7. Compilar la aplicación.

El nombre de la plataforma de hardware puede variar entre workspaces. Debe
seleccionarse siempre la plataforma creada a partir del HDF más reciente.

## Ejecución en la placa

1. Conectar la Zybo al PC mediante USB/JTAG.
2. Conectar la salida HDMI a un monitor.
3. Abrir una terminal serie a 115200 baudios, 8N1 y sin control de flujo.
4. Programar la FPGA con el bitstream exportado.
5. Ejecutar la aplicación mediante `Launch on Hardware`.

Una ejecución correcta termina mostrando por UART:

```text
VDMA S2MM/write running
VDMA MM2S/read running
Video pipeline running
```

El monitor debe mostrar cuatro barras verticales: roja, verde, azul y blanca.

## Elementos no incluidos en esta versión

Esta primera versión no utiliza:

- Cámara OV7670.
- Configuración I2C.
- GPIO de reset de cámara.
- Filtro HLS.
- Interrupciones del VDMA.
- Cambio dinámico de resolución.

Estos elementos se incorporarán únicamente después de consolidar la cadena
básica TPG-VDMA-HDMI.

## Archivos generados

Los workspaces de SDK, BSP, plataformas hardware, bitstreams y ejecutables ELF
son artefactos generados y no se versionan.

El repositorio conserva únicamente el código fuente y la documentación
necesarios para reconstruir la aplicación.
