# Reconstrucción del proyecto Vivado

Este directorio contiene el script necesario para reconstruir el proyecto
Vivado de la plataforma de vídeo sin versionar el proyecto generado completo.

El diseño corresponde a la versión validada en la Zybo Z7-10, mostrando
cuatro barras verticales mediante la cadena:

```text
TPG propio -> AXI4-Stream -> AXI VDMA -> DDR -> AXI VDMA
           -> AXI4-Stream to Video Out -> HDMI TX -> Monitor
```

## Requisitos

Para reconstruir el hardware se necesita:

- Xilinx Vivado 2019.1.
- El soporte para dispositivos Zynq-7000 instalado en Vivado.
- Una copia completa de este repositorio.

El núcleo HDMI de Digilent utilizado por el diseño ya está incluido en:

```text
vivado/ip/hdmi_tx_1.0/
```

Por tanto, no es necesario añadir manualmente el antiguo repositorio de IP.

Para ejecutar posteriormente el software en la placa también se necesita:

- Xilinx SDK 2019.1.
- Los controladores JTAG de Xilinx/Digilent.
- Una Zybo Z7-10.
- Un cable USB para programación y comunicación serie.
- Un monitor conectado a la salida HDMI.

## Archivos utilizados

El script reconstruye el proyecto utilizando únicamente archivos
versionados en el repositorio:

```text
vivado/scripts/create_project.tcl
vivado/constraints/zybo_z7_10_video.xdc
vivado/ip/hdmi_tx_1.0/
rtl/tpg/src/tpg_core.v
rtl/tpg/src/tpg_axis_wrapper.v
```

No utiliza archivos del proyecto Vivado original almacenado en `work/`.

## Reconstrucción desde la línea de comandos

Abrir una consola configurada para Vivado 2019.1 y situarse en la raíz
del repositorio:

```powershell
cd C:\ruta\al\repositorio\tfm-video-zynq
```

Para crear el proyecto con su nombre predeterminado:

```powershell
vivado -mode batch -source vivado/scripts/create_project.tcl
```

El proyecto se generará en:

```text
work/proyecto_base/
```

También se puede indicar otro nombre para realizar una reconstrucción de
prueba sin interferir con un proyecto existente:

```powershell
vivado -mode batch -source vivado/scripts/create_project.tcl `
    -tclargs --project_name proyecto_base_rebuild
```

En ese caso se generará:

```text
work/proyecto_base_rebuild/proyecto_base_rebuild.xpr
```

El script no debe ejecutarse usando el nombre de un proyecto que ya exista.
Si `work/proyecto_base/` ya contiene el proyecto de trabajo, se recomienda
utilizar otro nombre, como `proyecto_base_rebuild`.

## Reconstrucción desde la interfaz de Vivado

También se puede abrir Vivado 2019.1 y ejecutar desde la consola Tcl:

```tcl
source {C:/ruta/al/repositorio/tfm-video-zynq/vivado/scripts/create_project.tcl}
```

Al terminar, se puede abrir el archivo `.xpr` generado dentro de `work/`.

## Generación del bitstream

Una vez abierto el proyecto reconstruido:

1. Comprobar que el Block Design `design_1` aparece correctamente.
2. Comprobar que no existen IP bloqueadas ni referencias ausentes.
3. Seleccionar `Generate Bitstream` en Vivado.
4. Esperar a que terminen la síntesis y la implementación.

El bitstream se generará dentro del directorio de ejecución de implementación
del proyecto, bajo `work/`.

## Exportación del hardware

Después de generar correctamente el bitstream:

1. Seleccionar `File -> Export -> Export Hardware`.
2. Activar `Include bitstream`.
3. Exportar el hardware.
4. Abrir Xilinx SDK 2019.1.
5. Crear o actualizar la plataforma hardware y su BSP.
6. Crear la aplicación utilizando el código disponible en:

```text
sw/vitis/src/main.c
```

La creación y ejecución del proyecto software se explica con más detalle en:

```text
sw/vitis/README.md
```

## Resultado esperado

Al programar la FPGA y ejecutar la aplicación software, la VDMA utiliza la
DDR del Zynq como memoria de vídeo.

El monitor HDMI debe mostrar cuatro barras verticales:

```text
rojo | verde | azul | blanco
```

Este resultado confirma el funcionamiento conjunto del TPG, la interfaz
AXI4-Stream, la VDMA, la DDR, el subsistema de salida de vídeo y el
transmisor HDMI.

## Archivos generados

Los proyectos, bitstreams, exportaciones de hardware, logs y demás resultados
generados por Vivado o SDK deben permanecer en `work/`.

El directorio `work/` está ignorado por Git. Solo deben versionarse las
fuentes necesarias para reconstruir el diseño.
