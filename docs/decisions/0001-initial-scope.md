\# 0001 - Initial Scope



\## Estado



Aceptada.



\## Contexto



El TFM tiene una arquitectura objetivo amplia: TPG propio, camara OV7670, posible HDMI IN, seleccion de fuente, procesado HLS, AXI VDMA, salida HDMI y control desde Vitis.



Intentar implementar todo desde el inicio mezclaria demasiados riesgos:



\- Errores de protocolo de video.

\- Problemas de integracion Vivado.

\- Dificultades de control desde software.

\- Complejidad de HLS antes de tener una fuente de video validada.

\- Ruido generado por archivos temporales de herramientas.



\## Decision



La fase inicial se limita a preparar el repositorio y documentar la direccion tecnica del proyecto.



En esta fase se crean:



\- Estructura de carpetas del repositorio.

\- `.gitignore` adaptado a Vivado, Vitis y HLS.

\- `README.md` como portada del proyecto.

\- Documentacion inicial de arquitectura.

\- Registro de decisiones tecnicas.



No se implementa todavia:



\- Codigo VHDL.

\- Testbench RTL.

\- Codigo HLS.

\- Software Vitis.

\- Proyecto Vivado completo.

\- HDMI IN.



\## Consecuencias



\- El repositorio empieza limpio y comprensible.

\- Se evita versionar archivos generados por herramientas.

\- El primer commit queda centrado en infraestructura y documentacion.

\- La primera fase tecnica posterior queda claramente definida: TPG RTL AXI4-Stream Video con testbench.

\- HDMI IN queda como ampliacion futura y no bloquea el minimo viable.



\## Siguiente paso tecnico



El siguiente hito sera definir e implementar un TPG RTL con interfaz AXI4-Stream Video, validado primero mediante simulacion.

