# TFM Video Zynq

Plataforma SoC de vídeo reconfigurable desarrollada sobre una Zybo Z7-10 con
Zynq-7000.

El proyecto combina lógica programable en la PL, software bare-metal ejecutado
en el PS y memoria DDR compartida para construir una cadena de vídeo
configurable con salida HDMI.

## Estado actual

Actualmente está implementada y validada físicamente una primera versión
estable de la plataforma con:

- Resolución fija de 640 × 480 píxeles.
- Formato RGB888 de 24 bits por píxel.
- Test Pattern Generator propio escrito en Verilog.
- Ocho patrones de vídeo seleccionables.
- Salida AXI4-Stream Video con `TUSER`, `TLAST`, `TVALID` y `TREADY`.
- AXI VDMA con tres framebuffers almacenados en la DDR.
- Salida HDMI hacia un monitor.
- Interfaz AXI4-Lite para configurar el TPG desde el procesador.
- Aplicación bare-metal con consola de comandos por UART.
- Actualización de la configuración entre frames completos.

La implementación ha sido comprobada mediante testbenches y mediante pruebas
sobre la Zybo Z7-10.

## Plataforma utilizada

- Placa: Zybo Z7-10.
- Dispositivo: XC7Z010-1CLG400C.
- SoC: Zynq-7000.
- Vivado: 2019.1.
- Xilinx SDK: 2019.1.
- RTL del TPG: Verilog.
- Software: C bare-metal.
- Interfaz de vídeo: AXI4-Stream Video.
- Interfaz de control: AXI4-Lite.
- Salida: HDMI.

## Arquitectura actual

La cadena de vídeo validada es:

```text
TPG propio
  -> AXI4-Stream Video
  -> AXI VDMA S2MM
  -> DDR
  -> AXI VDMA MM2S
  -> AXI4-Stream to Video Out
  -> HDMI TX
  -> Monitor
```

El Video Timing Controller genera la temporización de salida y proporciona una
referencia de inicio de frame al TPG. De esta forma, el generador produce un
nuevo frame cuando la cadena de salida está preparada para mostrarlo.

El flujo de control es:

```text
Terminal serie
  -> Aplicación bare-metal en el PS
  -> AXI4-Lite
  -> Registros del TPG
```

El TPG respeta el backpressure AXI4-Stream y solo avanza al siguiente píxel
cuando se produce el handshake entre `TVALID` y `TREADY`.

## Patrones implementados

| Identificador | Patrón |
|---:|---|
| 0 | Negro |
| 1 | Color sólido configurable |
| 2 | Barras de color |
| 3 | Rampa horizontal periódica |
| 4 | Rampa vertical periódica |
| 5 | Tablero de ajedrez de bloques de 32 × 32 píxeles |
| 6 | Rejilla con separación de 32 píxeles |
| 7 | Rampa temporal uniforme |

El color sólido se configura en formato RGB888. La rampa temporal incrementa
su nivel al completar cada frame mediante un paso configurable de 8 bits.

## Configuración dinámica

Los siguientes parámetros pueden modificarse desde software:

- Habilitación del TPG.
- Patrón seleccionado.
- Color sólido.
- Paso de la rampa temporal.

El patrón, el color y el paso temporal se guardan primero como configuración
solicitada. Si hay un frame en curso, el wrapper espera a que termine antes de
aplicar los nuevos valores.

Al deshabilitar el TPG, el frame activo termina correctamente y no se inicia
uno nuevo. La imagen permanece visible porque el último frame continúa
almacenado en la DDR y la VDMA sigue enviándolo hacia la salida HDMI.

La dirección base AXI4-Lite asignada actualmente al TPG es:

```text
0x41220000
```

La aplicación y el mapa de registros se documentan en
[`sw/vitis/README.md`](sw/vitis/README.md).

## Verificación

Se utilizan dos testbenches autocontenibles:

- `rtl/tpg/tb/tb_tpg_core.v`
- `rtl/tpg/tb/tb_tpg_axis_wrapper.v`

Las simulaciones comprueban:

- Los ocho patrones de vídeo.
- Las coordenadas de los píxeles.
- El inicio de frame mediante `TUSER`.
- El final de línea mediante `TLAST`.
- El comportamiento ante backpressure.
- La sincronización de comienzo de frame.
- La habilitación y detención del generador.
- Las transacciones de lectura y escritura AXI4-Lite.
- La aplicación segura de configuración entre frames.
- Los registros de estado.

También se han realizado pruebas físicas sobre la placa para verificar:

- Todos los patrones.
- Los componentes rojo, verde y azul del color sólido.
- Diferentes pasos de la rampa temporal.
- Cambios de configuración durante la ejecución.
- Deshabilitación y reactivación del TPG.
- Lectura de registros mediante el comando `status`.
- Rechazo de comandos UART incorrectos.

Todas estas pruebas se han superado correctamente.

## Estructura del repositorio

```text
tfm-video-zynq/
|-- README.md
|-- AGENTS_tfm_video_zynq.md
|-- docs/
|   |-- architecture/
|   |-- decisions/
|   `-- planning/
|-- rtl/
|   |-- common/
|   `-- tpg/
|       |-- src/
|       `-- tb/
|-- hls/
|   `-- video_proc/
|-- sw/
|   `-- vitis/
|       |-- src/
|       `-- include/
|-- vivado/
|   |-- constraints/
|   |-- ip/
|   |-- scripts/
|   `-- bd/
|-- tools/
`-- work/
```

La carpeta `work/` contiene los proyectos y resultados generados por Vivado y
SDK. No forma parte de las fuentes versionadas.

## Reconstrucción del proyecto

El proyecto Vivado puede reconstruirse mediante:

```text
vivado/scripts/create_project.tcl
```

Las instrucciones y requisitos se encuentran en:

- [`vivado/scripts/README.md`](vivado/scripts/README.md)
- [`sw/vitis/README.md`](sw/vitis/README.md)

## Criterio de versionado

Se versionan:

- Código RTL.
- Testbenches.
- Código C de la aplicación.
- Código HLS cuando se implemente.
- Constraints.
- IP propio necesario para reconstruir el hardware.
- Scripts Tcl.
- Documentación técnica.

No se versionan:

- Proyectos generados completos de Vivado o SDK.
- Directorios de síntesis, implementación y simulación.
- Bitstreams y exportaciones hardware.
- Ejecutables ELF.
- Logs, journals, cachés y archivos temporales.

El flujo de ramas utilizado es:

```text
main       versiones estables validadas
develop    integración de funcionalidades
feature/*  desarrollo aislado de cada funcionalidad
```

## Próximas fases

El desarrollo previsto continúa con:

1. Cambio coordinado de resolución de la cadena de vídeo.
2. Selector de fuente entre el TPG y la entrada de cámara.
3. Bloque de procesado HLS con selección de bypass.
4. Pruebas integrales y documentación final.

Como ampliaciones opcionales se consideran:

- Desarrollo de un periférico HDMI propio, preferiblemente de salida.
- Interfaz gráfica en el PC comunicada por puerto serie.
- Entrada HDMI adicional.

El cambio de resolución no se considera únicamente una modificación del TPG:
debe coordinarse con la VDMA, los framebuffers, el Video Timing Controller, el
subsistema de salida y el software del PS.
