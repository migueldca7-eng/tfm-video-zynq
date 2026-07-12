\# TFM Video Zynq



Repositorio del TFM sobre una plataforma SoC de video reconfigurable en Zybo Z7 / Zynq-7000.



\## Objetivo



Construir una plataforma de video en tiempo real sobre Zynq, combinando logica programable en la PL y software de control en el PS.



El nucleo inicial del trabajo sera un Test Pattern Generator propio en RTL/VHDL, validado primero de forma aislada y posteriormente integrado en una plataforma de video con salida HDMI.



\## Plataforma



\- Placa: Zybo Z7.

\- SoC: Zynq-7000.

\- Herramientas: Vivado, Vitis y Vitis HLS.

\- Lenguaje RTL principal: VHDL.

\- Control software: C/C++ en Vitis.

\- Procesado acelerado: HLS en fases posteriores.



\## Arquitectura objetivo



Flujo de video previsto:



```text

TPG propio / Camara OV7670 / HDMI IN opcional

&#x20; -> Selector de fuente de video

&#x20; -> Selector HLS / bypass

&#x20; -> Procesado HLS o bypass

&#x20; -> AXI VDMA

&#x20; -> HDMI OUT

&#x20; -> Monitor

```



Flujo de control previsto:



```text

Software Vitis en PS

&#x20; -> AXI4-Lite / registros

&#x20; -> TPG, selector de fuente, selector HLS/bypass y bloque HLS

```



La entrada HDMI se considera una ampliacion futura y no bloquea el objetivo minimo viable.



\## Alcance inicial



La primera fase del proyecto se centra en preparar una base limpia y reproducible:



\- Crear la estructura del repositorio.

\- Documentar la arquitectura inicial.

\- Definir reglas de versionado con Git.

\- Preparar un `.gitignore` adecuado para Vivado, Vitis y HLS.

\- Dejar preparada la organizacion para RTL, HLS, software y scripts.



No se implementa todavia codigo VHDL ni se crea un proyecto Vivado completo.



\## Estructura del repositorio



```text

tfm-video-zynq/

|-- README.md

|-- AGENTS.md

|-- .gitignore

|-- docs/

|   |-- architecture/

|   |-- decisions/

|   `-- planning/

|-- rtl/

|   |-- common/

|   |   |-- src/

|   |   `-- tb/

|   `-- tpg/

|       |-- src/

|       `-- tb/

|-- hls/

|   `-- video\_proc/

|       |-- src/

|       |-- tb/

|       `-- scripts/

|-- sw/

|   `-- vitis/

|       |-- src/

|       `-- include/

|-- vivado/

|   |-- constraints/

|   |-- scripts/

|   `-- bd/

|-- tools/

`-- work/

```



\## Criterio de versionado



El repositorio debe contener los archivos fuente y los elementos necesarios para reconstruir el proyecto.



Se versionaran:



\- Codigo VHDL/RTL.

\- Testbenches.

\- Codigo HLS.

\- Codigo C/C++ para Vitis.

\- Constraints `.xdc`.

\- Scripts Tcl propios.

\- Documentacion tecnica.

\- Decisiones de arquitectura.



No se versionaran por defecto:



\- Proyectos generados completos de Vivado/Vitis/HLS.

\- Directorios `.runs`, `.cache`, `.hw`, `.sim`, `.ip\_user\_files`.

\- Logs, journals y temporales.

\- Bitstreams y exportaciones generadas como `.bit`, `.hwh`, `.xsa`.



La carpeta `work/` se reserva para proyectos y salidas generadas por herramientas y estara ignorada por Git.



\## Flujo de trabajo previsto



Ramas recomendadas:



```text

main                  version estable

dev                   integracion de trabajo

feature/tpg           desarrollo del TPG

feature/hls           desarrollo del procesado HLS

feature/sw            desarrollo del software Vitis

feature/vivado        integracion con Vivado

```



Commits recomendados:



```text

chore: add repository structure and gitignore

docs: add initial architecture summary

feat(rtl): add initial AXI Stream TPG

test(rtl): add TPG frame timing testbench

docs: record initial implementation scope

```



\## Hitos previstos



\- `v0.1-base`: repositorio inicial, documentacion y estructura.

\- `v0.2-tpg-sim-ok`: TPG validado por simulacion.

\- `v0.3-tpg-hdmi-ok`: TPG integrado con salida HDMI.

\- `v0.4-sw-control-ok`: control basico desde Vitis.

\- `v0.5-hls-ok`: primer bloque HLS integrado.



\## Estado actual



Repositorio en fase inicial.



Todavia no hay implementacion RTL, HLS ni software. La prioridad es construir una base ordenada antes de empezar con el codigo.

