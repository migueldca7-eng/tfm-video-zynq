\# Architecture Summary



\## Proposito



Este documento recoge la arquitectura tecnica actual del TFM. El README funciona como portada del repositorio; este archivo se usara como documento vivo para detallar el sistema conforme avance el desarrollo.



\## Plataforma



\- Placa: Zybo Z7.

\- SoC: Zynq-7000.

\- Herramientas: Vivado, Vitis y Vitis HLS.

\- Lenguaje RTL principal: VHDL.

\- Control software: C/C++ sobre Vitis.

\- Flujo de video principal: AXI4-Stream Video.

\- Memoria de frames: DDR externa mediante AXI VDMA.



\## Arquitectura objetivo



El sistema objetivo combina fuentes de video, procesado opcional y salida HDMI.



```text

TPG propio / Camara OV7670 / HDMI IN opcional

&#x20; -> Selector de fuente de video

&#x20; -> Selector HLS / bypass

&#x20; -> Procesado HLS o bypass

&#x20; -> AXI VDMA

&#x20; -> HDMI OUT

&#x20; -> Monitor

