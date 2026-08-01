# Reconstrucción del proyecto Vivado

Este directorio contiene el script Tcl necesario para reconstruir el proyecto
Vivado de la plataforma de vídeo sin versionar el proyecto generado completo.

El diseño ha sido reconstruido, sintetizado, implementado y validado sobre una
Zybo Z7-10 utilizando Vivado 2019.1.

## Arquitectura reconstruida

La cadena de vídeo es:

```text
TPG propio
  -> AXI4-Stream
  -> AXI VDMA S2MM
  -> DDR del Zynq
  -> AXI VDMA MM2S
  -> AXI4-Stream to Video Out
  -> HDMI TX
  -> Monitor
```

La configuración del TPG sigue el camino:

```text
PS M_AXI_GP0
  -> AXI Interconnect
  -> AXI4-Lite del TPG
```

El TPG recibe además la señal `fsync_out` del Video Timing Controller. Esta
señal se sincroniza internamente antes de utilizarse como referencia para
comenzar un nuevo frame.

## Configuración actual

- Dispositivo: `xc7z010clg400-1`.
- Resolución: 640 × 480.
- Formato de vídeo: RGB888.
- Reloj AXI, VDMA y TPG: FCLK0 del PS.
- Reloj de píxel: 25 MHz.
- Tres frame stores en el AXI VDMA.
- Puerto HP0 del PS para acceder a la DDR.
- Puerto GP0 del PS para controlar los periféricos AXI4-Lite.
- Dirección AXI4-Lite del TPG: `0x41220000`.
- Tamaño del segmento AXI del TPG: `0x00010000`.

## Requisitos

Para reconstruir el hardware se necesita:

- Xilinx Vivado 2019.1.
- Soporte para dispositivos Zynq-7000.
- Una copia completa del repositorio.
- Espacio disponible para generar el proyecto dentro de `work/`.

El núcleo HDMI utilizado por el diseño está incluido en:

```text
vivado/ip/hdmi_tx_1.0/
```

Por tanto, no es necesario añadir manualmente otro repositorio de IP para ese
bloque.

Para ejecutar posteriormente el software también se necesita:

- Xilinx SDK 2019.1.
- Controladores JTAG de Xilinx/Digilent.
- Una Zybo Z7-10.
- Un cable USB.
- Un monitor conectado a la salida HDMI.
- Una terminal serie.

## Fuentes versionadas utilizadas

El script utiliza los siguientes elementos del repositorio:

```text
vivado/scripts/create_project.tcl
vivado/constraints/zybo_z7_10_video.xdc
vivado/ip/hdmi_tx_1.0/
rtl/tpg/src/tpg_core.v
rtl/tpg/src/tpg_axis_wrapper.v
```

No utiliza los archivos del proyecto original almacenados en `work/`.

## Reconstrucción desde PowerShell

Abrir PowerShell, situarse en la raíz del repositorio y ejecutar:

```powershell
cd C:\ruta\al\repositorio\tfm-video-zynq
vivado -mode batch -source vivado/scripts/create_project.tcl
```

Si Vivado no se encuentra en `PATH`, puede utilizarse su ruta completa:

```powershell
& "C:\Xilinx\Vivado\2019.1\bin\vivado.bat" -mode batch -source vivado/scripts/create_project.tcl
```

El proyecto se genera en:

```text
work/proyecto_base/proyecto_base.xpr
```

Para crear una reconstrucción de prueba con otro nombre:

```powershell
vivado -mode batch -source vivado/scripts/create_project.tcl -tclargs --project_name proyecto_base_rebuild
```

El resultado se genera en:

```text
work/proyecto_base_rebuild/proyecto_base_rebuild.xpr
```

El nombre indicado no debe coincidir con un proyecto que ya exista.

## Reconstrucción desde CMD

En el símbolo del sistema no debe utilizarse el operador `&` de PowerShell:

```bat
cd C:\ruta\al\repositorio\tfm-video-zynq
"C:\Xilinx\Vivado\2019.1\bin\vivado.bat" -mode batch -source vivado/scripts/create_project.tcl -tclargs --project_name proyecto_base_rebuild
```

## Reconstrucción desde la consola Tcl de Vivado

Si Vivado ya está abierto, debe ejecutarse únicamente el comando Tcl:

```tcl
source {C:/ruta/al/repositorio/tfm-video-zynq/vivado/scripts/create_project.tcl}
```

No debe pegarse `vivado -mode batch ...` dentro de la consola Tcl, ya que ese
es un comando del sistema operativo y no un comando Tcl.

## Comprobaciones después de reconstruir

Una vez generado el proyecto:

1. Abrir el archivo `.xpr`.
2. Comprobar que aparece el Block Design `design_1`.
3. Ejecutar `Validate Design`.
4. Comprobar que el TPG está conectado a `S_AXIS_S2MM`.
5. Comprobar que `M03_AXI` del interconnect llega al puerto AXI4-Lite del TPG.
6. Comprobar que `fsync_out` del VTC llega a `frame_sync_async`.
7. Abrir el Address Editor.
8. Verificar que el TPG está situado en `0x41220000`.
9. Comprobar que no existen IP bloqueadas ni referencias a módulos ausentes.

## Simulación del TPG

Los testbenches se encuentran en:

```text
rtl/tpg/tb/tb_tpg_core.v
rtl/tpg/tb/tb_tpg_axis_wrapper.v
```

Desde una consola configurada para Vivado pueden ejecutarse de forma
independiente.

### Core

```powershell
xvlog rtl/tpg/src/tpg_core.v rtl/tpg/tb/tb_tpg_core.v
xelab tb_tpg_core -s tb_tpg_core_sim
xsim tb_tpg_core_sim -runall
```

El resultado correcto termina con:

```text
TB PASSED: tpg_core patterns, pacing, backpressure and enable checks passed
```

### Wrapper AXI4-Stream y AXI4-Lite

```powershell
xvlog rtl/tpg/src/tpg_core.v rtl/tpg/src/tpg_axis_wrapper.v rtl/tpg/tb/tb_tpg_axis_wrapper.v
xelab tb_tpg_axis_wrapper -s tb_tpg_axis_wrapper_sim
xsim tb_tpg_axis_wrapper_sim -runall
```

El resultado correcto termina con:

```text
TB PASSED: AXI-Lite control, frame-safe updates and video checks passed
```

## Generación del bitstream

Una vez abierto y comprobado el proyecto:

1. Seleccionar `Generate Bitstream`.
2. Esperar a que terminen síntesis e implementación.
3. Revisar el timing.
4. Revisar los DRC y sus advertencias.
5. Confirmar que el bitstream se genera correctamente.

Los resultados se almacenan dentro del directorio del proyecto bajo `work/`.

## Exportación del hardware

Después de generar el bitstream:

1. Seleccionar `File -> Export -> Export Hardware`.
2. Activar `Include bitstream`.
3. Exportar el hardware al workspace de SDK.
4. Abrir o actualizar la plataforma hardware en Xilinx SDK.
5. Aceptar la sincronización de la nueva especificación.
6. Regenerar el BSP cuando sea necesario.
7. Compilar la aplicación disponible en:

```text
sw/vitis/src/main.c
```

La creación y ejecución de la aplicación se explica en:

```text
sw/vitis/README.md
```

## Resultado esperado

Después de programar la FPGA y ejecutar la aplicación:

- La VDMA debe escribir los frames del TPG en la DDR.
- La VDMA debe leerlos y enviarlos hacia la salida HDMI.
- El monitor debe mostrar inicialmente las barras de color.
- La terminal UART debe mostrar el prompt `tpg>`.
- Los patrones deben poder cambiarse mediante comandos.
- Los cambios deben aplicarse sin dividir el frame visible.
- El comando `status` debe mostrar los registros del TPG.

Este comportamiento confirma el funcionamiento conjunto del TPG, AXI4-Stream,
AXI4-Lite, AXI VDMA, DDR, PS, software, Video Timing Controller y salida HDMI.

## Archivos generados

Los proyectos, bitstreams, exportaciones hardware, logs, journals, resultados
de simulación y demás artefactos generados por Vivado o SDK permanecen en
`work/` o en directorios ignorados.

Solo se versionan las fuentes necesarias para reconstruir el diseño.
