# Plataforma de vídeo reconfigurable sobre Zybo Z7-10

## 1. Descripción

Este proyecto amplía el sistema **CanalVideo** proporcionado como punto de
partida en la asignatura. El diseño original permitía capturar vídeo de una
cámara OV7670, almacenarlo en la DDR mediante una AXI VDMA y visualizarlo por
HDMI con una configuración fija de 640 × 480 píxeles.

Sobre esa base se ha desarrollado una plataforma de vídeo reconfigurable en
tiempo de ejecución. La fuente, la resolución, los patrones y el procesado de
imagen pueden modificarse desde el procesador mediante comandos UART, sin
tener que generar ni cargar un nuevo bitstream.

## 2. Funcionalidad añadida al proyecto base

Las principales aportaciones realizadas son:

- **Generador de patrones de vídeo propio (TPG)** desarrollado en RTL y con
  salida AXI4-Stream Video. Incluye ocho patrones: negro, color sólido, barras
  de color, rampa horizontal, rampa vertical, damero, rejilla y rampa
  temporal.
- **Periférico AXI4-Lite propio para el TPG**, que permite configurar desde el
  PS el patrón, el color sólido, el paso de la rampa temporal y la habilitación
  del generador, además de consultar su estado.
- **Cambio dinámico de resolución** entre tres perfiles validados físicamente:
  640 × 480p60, 1280 × 720p60 y 1920 × 1080p30. El software coordina la
  reconfiguración del TPG, la AXI VDMA, el VTC y el Clock Wizard.
- **Selector de fuente AXI4-Stream propio** para elegir durante la ejecución
  entre el TPG y la cámara. La conmutación se realiza en un límite de frame
  para evitar mezclar píxeles de dos fuentes en una misma imagen.
- **Gestión de la cámara OV7670 desde software**. La cámara se inicializa
  cuando se solicita y se utiliza su modo de reposo cuando deja de ser la
  fuente activa.
- **Acelerador de procesado desarrollado con Vivado HLS**, situado en la rama
  de la cámara y con tres modos: bypass, escala de grises y detección de bordes
  Sobel. El modo solicitado se aplica al comenzar un nuevo frame.
- **Periférico AXI4-Lite propio para el filtro HLS**, utilizado para seleccionar
  el modo de procesado desde el PS y consultar su estado.
- **Reescalador de cámara desarrollado con HLS**, situado tras la VDMA. Mantiene
  VGA en bypass y convierte la región central 640 × 360 a 720p o 1080p mediante
  vecino más próximo ×2/×3.
- **Periférico AXI4-Lite propio para el escalador**, con configuración
  solicitada/activa y aplicación en el comienzo de un frame.
- **Transmisor HDMI/TMDS propio en RTL**, compuesto por codificadores de 8 a 10
  bits, serializadores OSERDESE2 10:1 DDR y buffers diferenciales OBUFDS.
- **Aplicación bare-metal con intérprete de comandos UART**, desde la que se
  controla la plataforma completa en tiempo real.
- **Verificación mediante testbenches y pruebas sobre la Zybo Z7-10** de los
  módulos RTL, las interfaces AXI4-Lite, el selector de fuente, el procesador
  HLS y la cadena de vídeo integrada.

La arquitectura resultante es:

```text
TPG propio ----------------------------------\
                                               -> Selector de fuente
OV7670 -> AXI4-Stream -> Procesador HLS ------/
     -> AXI VDMA S2MM -> DDR -> AXI VDMA MM2S
     -> Escalador HLS -> Video Out -> HDMI/TMDS RTL propio

PS / aplicación UART -> AXI4-Lite -> TPG / selector / filtro / escalador
```

## 3. Conexiones necesarias para la demostración

- Conectar **HDMI OUT** de la Zybo Z7-10 a un monitor.
- Conectar el puerto **USB-UART** de la placa al ordenador.
- Con la placa apagada, conectar la cámara OV7670 mediante su adaptador a los
  conectores **PMOD JC y JD simultáneamente**. El módulo de la cámara queda
  orientado hacia el exterior del borde inferior de la placa, como se muestra
  en la fotografía `conexion_ov7670.jpeg` incluida con la entrega.
- Abrir una terminal serie con la siguiente configuración:
  - 115200 baudios.
  - 8 bits de datos.
  - 1 bit de parada.
  - Sin paridad.
  - Sin control de flujo.

![Conexión de la cámara OV7670 a los PMOD JC y JD](conexion_ov7670.jpeg)

Al iniciar el sistema aparece el prompt `tpg>` y se muestran las barras de
color generadas por el TPG.

## 4. Secuencia recomendada de validación

### 4.1. Consultar el estado y la ayuda

```text
help
status
```

`help` muestra todos los comandos disponibles. `status` permite comprobar la
resolución, la configuración del TPG, la fuente activa y el estado de la
cámara y del selector.

### 4.2. Comprobar los patrones del TPG

Seleccionar el TPG y mostrar el patrón de damero:

```text
source 0
pattern 5
```

Comprobar el modo de color sólido utilizando verde:

```text
pattern 1
color 0x00FF00
```

Comprobar la rampa temporal y modificar su velocidad:

```text
pattern 7
step 4
```

Los cambios se aplican entre frames completos, por lo que nunca se presenta
una imagen compuesta por dos configuraciones distintas.

### 4.3. Comprobar el cambio de resolución

Con el TPG seleccionado, ejecutar sucesivamente:

```text
resolution 0
resolution 1
resolution 2
resolution 0
```

Los valores corresponden a:

| Valor | Modo de vídeo |
|---:|:---|
| `0` | 640 × 480p60 |
| `1` | 1280 × 720p60 |
| `2` | 1920 × 1080p30 |

El cambio se realiza durante la ejecución y no requiere volver a programar la
FPGA. Con TPG se cambia la resolución nativa de toda la cadena. Con cámara, la
captura y la DDR permanecen en 640 × 480, mientras el escalador genera la
salida solicitada.

### 4.4. Comprobar la cámara y el procesado HLS

Seleccionar la cámara:

```text
source 1
```

El software configura automáticamente el modo VGA, inicializa o despierta la
cámara y solicita al selector que realice la conmutación al comenzar un frame
válido de la nueva fuente.

Con la imagen de la cámara visible, comprobar los tres modos de procesado:

```text
filter 0
filter 1
filter 2
```

| Valor | Resultado esperado |
|---:|:---|
| `0` | Imagen original en modo bypass |
| `1` | Imagen en escala de grises |
| `2` | Detección de bordes mediante Sobel |

Comprobar también el reescalado de la cámara:

```text
resolution 0
resolution 1
resolution 2
```

En 720p y 1080p se recortan 60 líneas arriba y abajo para obtener una imagen
16:9 y se repiten los píxeles ×2/×3. El contenido visible pierde parte del
encuadre vertical, pero no se deforma.

Finalmente, regresar al TPG y consultar el estado final:

```text
source 0
status
```

Al abandonar la cámara, el selector termina la conmutación de forma segura y
el software coloca la OV7670 en modo de reposo.

## 5. Referencia rápida de comandos

| Comando | Función |
|:---|:---|
| `help` | Muestra la ayuda de la consola |
| `status` | Muestra el estado de la plataforma |
| `enable 0\|1` | Deshabilita o habilita el TPG |
| `pattern 0..7` | Selecciona el patrón del TPG |
| `color 0xRRGGBB` | Configura el color sólido RGB888 |
| `step 0..255` | Configura el paso de la rampa temporal |
| `resolution 0..2` | Selecciona el perfil de resolución |
| `source 0\|1` | Selecciona TPG o cámara |
| `filter 0..2` | Selecciona bypass, escala de grises o Sobel |

## 6. Reconstrucción de la aplicación en Xilinx SDK 2019.1

1. En Vivado, generar el bitstream y seleccionar `File > Export > Export
   Hardware` con `Include bitstream` activado.
2. Abrir `File > Launch SDK` y seleccionar un workspace local al proyecto.
3. En SDK, usar `File > New > Application Project` y crear
   `tpg_video_app` sobre la hardware platform exportada.
4. Seleccionar `ps7_cortexa9_0`, sistema operativo `standalone` y crear o
   asociar su BSP.
5. Elegir la plantilla `Empty Application`.
6. Importar `sw/vitis/src/main.c` dentro de `tpg_video_app/src` mediante
   `Import > General > File System`.
7. Ejecutar `Re-generate BSP Sources`, limpiar y compilar el BSP y la
   aplicación.
8. Programar la FPGA y lanzar `tpg_video_app.elf` sobre
   `ps7_cortexa9_0`.

La ruta `sw/vitis` es un nombre histórico del repositorio; la herramienta de
la versión 2019.1 es Xilinx SDK. La guía completa se encuentra en
`sw/vitis/README.md`.
