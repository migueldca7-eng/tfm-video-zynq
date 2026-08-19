# Software de control de vídeo

Este directorio contiene el software bare-metal ejecutado por el procesador ARM
del Zynq para inicializar la cadena de vídeo, controlar el Test Pattern
Generator, seleccionar entre el TPG y una cámara OV7670 y configurar el
procesador de vídeo HLS mediante AXI4-Lite.

El software se ha desarrollado y probado con Xilinx SDK 2019.1 sobre una
Zybo Z7-10.

## Código fuente

El archivo principal de la aplicación es:

```text
sw/vitis/src/main.c
```

El workspace completo de SDK no se versiona. Únicamente se conserva el código
fuente necesario para reconstruir la aplicación.

## Cadena de vídeo controlada

```text
TPG RTL ---------------------------------\
                                         -> Selector AXI4-Stream
OV7670 -> Video In to AXI4S -> Filtro HLS/
  -> AXI VDMA S2MM
  -> DDR
  -> AXI VDMA MM2S
  -> AXI4-Stream Video Out
  -> HDMI
```

La cadena y la conmutación entre el TPG y la cámara están validadas físicamente
a 640 × 480. El software también incluye tres perfiles de resolución
seleccionables, cuya validación física completa queda pendiente:

- Modo 0: 640 × 480p60, reloj de píxel nominal de 25 MHz.
- Modo 1: 1280 × 720p60, reloj de píxel nominal de 74,25 MHz.
- Modo 2: 1920 × 1080p30, reloj de píxel nominal de 74,25 MHz.
- Formato de píxel: RGB888 de 24 bits.
- Tamaño de píxel: 3 bytes.
- Tres framebuffers en DDR.
- Funcionamiento circular del VDMA.
- Sincronización interna entre los canales S2MM y MM2S.

## Funcionamiento de la aplicación

Durante el arranque, el programa:

1. Deshabilita temporalmente el inicio de nuevos frames del TPG.
2. Localiza el AXI VDMA mediante los parámetros generados por el BSP.
3. Inicializa los drivers `XAxiVdma` y `XVtc`.
4. Comprueba que existen los canales S2MM y MM2S.
5. Selecciona el perfil inicial de 25 MHz en el Clock Wizard.
6. Reinicia ambos canales de la VDMA con timeout.
7. Configura resolución, stride y direcciones de los framebuffers.
8. Arranca S2MM y MM2S.
9. Configura y habilita el VTC para el modo inicial.
10. Configura el TPG para 640 × 480 y carga sus parámetros iniciales.
11. Habilita el generador.
12. Selecciona el TPG como fuente inicial.
13. Entra en un bucle de recepción de comandos por UART.

El wrapper AXI4-Lite del filtro y el core HLS se reinician en modo bypass. La
aplicación no necesita realizar una escritura inicial para obtener la imagen
original de la cámara.

La cámara se inicializa bajo demanda la primera vez que se ejecuta `source 1`.
De esta forma, el arranque normal con el TPG no depende de que el sensor esté
conectado.

Los valores iniciales configurados por la aplicación son:

```text
enable = 1
pattern = 2
solid color = 0x00FF00
temporal step = 1
```

## Distribución de los framebuffers

Los framebuffers comienzan en la dirección física `0x02000000`. Cada uno
dispone de un espacio fijo de 6 MiB para que sus direcciones no cambien entre
modos y pueda alojar un frame RGB888 de 1920 × 1080.

| Buffer | Dirección |
|---|---:|
| 0 | `0x02000000` |
| 1 | `0x02600000` |
| 2 | `0x02C00000` |

El stride y el tamaño útil se calculan para el perfil seleccionado:

| Modo | Stride | Tamaño útil del frame |
|---|---:|---:|
| 640 × 480 | 1 920 bytes | 921 600 bytes |
| 1280 × 720 | 3 840 bytes | 2 764 800 bytes |
| 1920 × 1080 | 5 760 bytes | 6 220 800 bytes |

El mayor frame cabe en los 6 291 456 bytes reservados para cada buffer.

## Interfaz AXI4-Lite del TPG

El TPG está conectado al espacio de direcciones del PS mediante el puerto
`M_AXI_GP0` y un AXI Interconnect.

La dirección base utilizada actualmente es:

```text
TPG_BASEADDR = 0x41220000
```

### Mapa de registros

| Offset | Nombre | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `ENABLE` | R/W | Bit 0: habilitación del TPG |
| `0x04` | `PATTERN` | R/W | Bits 2:0: patrón solicitado |
| `0x08` | `SOLID_COLOR` | R/W | Bits 23:0: color RGB888 |
| `0x0C` | `TEMPORAL_STEP` | R/W | Bits 7:0: paso temporal |
| `0x10` | `STATUS` | R | Bit 0: `busy`; bit 1: `pending` |
| `0x14` | `FRAME_PHASE` | R | Bits 7:0: fase temporal actual |
| `0x18` | `FRAME_SIZE` | R/W | Alto en bits 31:16; ancho en bits 15:0 |

Los registros `PATTERN`, `SOLID_COLOR` y `TEMPORAL_STEP` devuelven los valores
solicitados por software.

Si se escribe una nueva configuración mientras el TPG está generando un frame,
el bit `pending` se activa. Los valores se aplican al core cuando termina el
frame actual y entonces `pending` vuelve a cero.

`busy` indica que el core está generando un frame.

`FRAME_PHASE` permite observar el nivel utilizado por la rampa temporal.

### Dirección local en el software

El TPG está integrado en Vivado como una referencia a módulo RTL y no como un
IP empaquetado con driver propio. Por ello, el BSP no genera automáticamente
una macro de dirección específica para este bloque.

La aplicación define `TPG_BASEADDR` en `main.c`. Si se modifica la asignación
del Address Editor o el script Tcl, esta constante debe actualizarse para que
coincida con la nueva dirección.

## Interfaz AXI4-Lite del selector de fuente

El selector está conectado al mismo AXI Interconnect que el resto de
periféricos de control. Su dirección base, generada por el BSP, es:

```text
SOURCE_SELECTOR_BASEADDR = 0x43C20000
```

| Offset | Nombre | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `SOURCE_CONTROL` | R/W | Bit 0: fuente solicitada; 0 = TPG, 1 = cámara |
| `0x04` | `SOURCE_STATUS` | R | Bit 0: fuente activa; bit 1: cambio pendiente |

La escritura del registro de control solo solicita el cambio. El selector
mantiene la fuente anterior hasta alcanzar un límite seguro de frame y espera
el `TUSER` de la nueva fuente antes de hacerla activa.

## Control de la cámara OV7670

El PS configura el sensor mediante el controlador I2C/SCCB y gobierna su reset
hardware mediante GPIO. Tras liberar el reset, la aplicación espera 10 ms
antes de la primera transacción para evitar accesos mientras el sensor todavía
está arrancando.

La cámara se configura en VGA RGB888. Al dejar de ser la fuente activa, el
software activa su modo de reposo mediante el registro `COM2`; al volver a
seleccionarla, la reactiva y espera a que entregue vídeo estable.

## Interfaz AXI4-Lite del filtro HLS

El wrapper de control convierte las transacciones AXI4-Lite del PS en señales
discretas para el core HLS. La dirección base generada por el BSP es:

```text
VIDEO_FILTER_BASEADDR = 0x43C30000
```

| Offset | Nombre | Acceso | Contenido |
|---:|---|:---:|---|
| `0x00` | `FILTER_CONTROL` | R/W | Bits 1:0: modo solicitado |
| `0x04` | `FILTER_STATUS` | R | Bits 1:0: modo activo; bit 2: cambio pendiente |

Los modos válidos son 0 para bypass, 1 para escala de grises y 2 para Sobel.
El valor 3 es rechazado por el wrapper y deja intacta la configuración. El
core aplica una petición válida al aceptar el `TUSER` del frame siguiente.

El filtro está situado únicamente en la rama de cámara, antes del selector de
fuente. Por ello, el comando no modifica los patrones procedentes del TPG. El
modo Sobel está dimensionado para la imagen VGA de 640 × 480 de la OV7670.

## Consola UART

La aplicación ofrece una consola interactiva mediante UART.

Configuración de la terminal:

```text
115200 baudios
8 bits de datos
sin paridad
1 bit de parada
sin control de flujo
```

Al terminar la inicialización aparece el prompt:

```text
tpg>
```

## Comandos disponibles

### Mostrar ayuda

```text
help
```

### Leer el estado

```text
status
```

Muestra:

- Habilitación.
- Patrón solicitado.
- Color sólido.
- Paso temporal.
- Estado `busy`.
- Estado `pending`.
- Fase temporal.
- Nombre del modo activo.
- Resolución activa.
- Reloj de píxel nominal.
- Fuente solicitada y fuente activa.
- Estado pendiente del selector.
- Estado de inicialización y habilitación de la cámara.

### Habilitar o deshabilitar el TPG

```text
enable 1
enable 0
```

Cuando se escribe `enable 0`, el core termina el frame que ya estaba generando
y no inicia uno nuevo.

La imagen permanece visible porque la VDMA MM2S continúa leyendo de la DDR el
último frame almacenado.

Al volver a escribir `enable 1`, la generación comienza de nuevo. La fase de la
rampa temporal se reinicia.

### Seleccionar el patrón

```text
pattern <0..7>
```

| Valor | Patrón |
|---:|---|
| 0 | Negro |
| 1 | Color sólido |
| 2 | Barras de color |
| 3 | Rampa horizontal periódica |
| 4 | Rampa vertical periódica |
| 5 | Tablero de ajedrez |
| 6 | Rejilla |
| 7 | Rampa temporal |

Ejemplo:

```text
pattern 5
```

### Configurar el color sólido

```text
color <0xRRGGBB>
```

Ejemplos:

```text
color 0xFF0000
color 0x00FF00
color 0x0000FF
```

El registro se utiliza cuando está seleccionado el patrón 1.

### Configurar el paso temporal

```text
step <0..255>
```

Ejemplo:

```text
step 16
```

Este valor se suma a la fase después de cada frame del patrón 7.

La aritmética es de 8 bits, por lo que la fase vuelve a cero al superar 255.
Con `step 1` se recorren los 256 niveles, mientras que con pasos mayores la
rampa evoluciona más rápidamente.

### Cambiar la resolución

```text
resolution <0..2>
```

| Valor | Modo |
|---:|---|
| 0 | 640 × 480p60 |
| 1 | 1280 × 720p60 |
| 2 | 1920 × 1080p30 |

El software conserva el estado anterior de `enable`. Primero impide que el TPG
comience otro frame y espera a que termine el actual. Después detiene ambos
canales de la VDMA, deshabilita el VTC, reconfigura el Clock Wizard y carga las
nuevas temporizaciones y dimensiones. Finalmente arranca la cadena y restaura
el valor anterior de `enable`.

Todas las esperas por polling tienen timeout. Si falla una operación, el modo
activo no se actualiza y el TPG permanece deshabilitado para evitar una cadena
parcialmente configurada.

### Seleccionar la fuente de vídeo

```text
source <0|1>
```

| Valor | Fuente |
|---:|---|
| 0 | TPG |
| 1 | Cámara OV7670 |

Para pasar a la cámara, el software fuerza primero el modo VGA, inicializa o
reactiva el sensor y solicita el cambio al selector. El TPG continúa hasta que
el selector confirma que la cámara ha comenzado por un `TUSER`; solo entonces
se deshabilita el TPG.

Para volver al TPG, se habilita primero el generador, se espera la confirmación
del selector y después se pone la cámara en reposo. Así nunca se apaga la
fuente anterior antes de disponer de un frame completo de la nueva.

### Seleccionar el filtro de vídeo

```text
filter <0..2>
```

| Valor | Modo |
|---:|---|
| 0 | Bypass: imagen RGB888 original |
| 1 | Escala de grises |
| 2 | Detección de bordes Sobel |

Ejemplo:

```text
source 1
filter 2
```

La aplicación valida el argumento y escribe el modo solicitado en
`FILTER_CONTROL`. El cambio se completa al comenzar el siguiente frame, por lo
que la pantalla no contiene regiones procesadas con filtros diferentes. Para
observar el resultado debe estar seleccionada la cámara mediante `source 1`.

## Validación de comandos

Antes de escribir cualquier registro, la aplicación comprueba:

- Que el comando existe.
- Que contiene el número correcto de argumentos.
- Que el argumento es numérico.
- Que el valor pertenece al rango permitido.
- Que el color no supera `0xFFFFFF`.

Una entrada incorrecta muestra un mensaje de error y no modifica el hardware.

Se han probado correctamente, entre otros, los siguientes casos inválidos:

```text
pattern 8
enable 2
color 0x1000000
step 256
resolution 3
source 2
filter 3
pattern hola
status extra
```

## Creación del proyecto en Xilinx SDK

1. Generar el bitstream en Vivado.
2. Exportar el hardware activando `Include bitstream`.
3. Abrir Xilinx SDK 2019.1 con el workspace correspondiente.
4. Crear o actualizar la plataforma hardware.
5. Crear un BSP para `ps7_cortexa9_0` con sistema operativo `standalone`.
6. Crear una aplicación C vacía asociada al BSP.
7. Copiar `sw/vitis/src/main.c` al directorio `src` de la aplicación.
8. Regenerar el BSP si la especificación hardware ha cambiado.
9. Compilar la aplicación.

Debe utilizarse siempre el HDF generado por la versión más reciente del
hardware.

Si SDK indica que el HDF ya está abierto o no puede regenerar el BSP, debe
cerrarse la especificación hardware abierta y, si es necesario, reiniciar SDK
antes de volver a generar las fuentes del BSP.

## Ejecución en la placa

1. Conectar la Zybo al PC mediante USB/JTAG.
2. Conectar la salida HDMI a un monitor.
3. Abrir una terminal serie con la configuración indicada.
4. Programar la FPGA con el bitstream exportado.
5. Ejecutar la aplicación mediante `Launch on Hardware`.
6. Esperar a que aparezca el prompt `tpg>`.
7. Utilizar `help` para consultar los comandos.

Una inicialización correcta muestra mensajes equivalentes a:

```text
VDMA S2MM/write running
VDMA MM2S/read running
Video pipeline running
```

Después puede utilizarse `status`, cambiar el patrón, solicitar otro perfil
mediante `resolution`, seleccionar la fuente mediante `source` o procesar la
cámara mediante `filter`.

## Pruebas realizadas

La aplicación y la interfaz AXI4-Lite se han validado físicamente comprobando:

- Lectura correcta de todos los registros.
- Selección de los ocho patrones.
- Cambio del color sólido en rojo, verde y azul.
- Cambio del paso de la rampa temporal.
- Actualización completa entre frames.
- Funcionamiento de `busy` y `pending`.
- Deshabilitación al finalizar el frame activo.
- Reinicio de la rampa temporal tras volver a habilitar el TPG.
- Rechazo de comandos y valores incorrectos.
- Inicialización de la OV7670 mediante I2C/SCCB.
- Entrada y salida del modo de reposo de la cámara.
- Lectura de la fuente solicitada, activa y pendiente.
- Conmutaciones `source 0` y `source 1` en límites de frame.
- Imagen correcta de ambas fuentes en un monitor HDMI.
- Selección de los modos bypass, escala de grises y Sobel mediante UART.
- Aplicación completa del nuevo filtro entre frames.
- Recuperación de la imagen RGB original al volver a `filter 0`.

Todas las pruebas se han superado correctamente.

El cambio coordinado de resolución está implementado, el software compila sin
avisos y el bitstream cumple timing. Falta realizar la validación física con un
monitor HDMI mediante esta secuencia mínima:

1. Comprobar el arranque en el modo 0 y ejecutar `status`.
2. Probar las transiciones `0 → 1 → 2 → 0` con `enable 1`.
3. Repetir los cambios con `enable 0` y comprobar que el TPG permanece parado.
4. Mostrar los ocho patrones en cada modo.
5. Probar `resolution 3`, argumentos no numéricos y argumentos adicionales.

## Funcionalidades pendientes

Esta versión todavía no incluye:

- Validación física del cambio dinámico de resolución.
- Interfaz gráfica de control.
- Periférico HDMI propio desarrollado específicamente para el TFM.

## Archivos generados

Los workspaces de SDK, BSP, plataformas hardware, bitstreams y ejecutables ELF
son artefactos generados y permanecen dentro de `work/`.

El repositorio conserva únicamente el código fuente y la documentación
necesarios para reconstruir la aplicación.
