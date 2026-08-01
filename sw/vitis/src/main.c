/*
 * Prueba minima de la cadena TPG -> VDMA -> DDR -> HDMI.
 *
 * El programa se construye de forma incremental a partir de CanalVideo.c,
 * eliminando la configuracion de la camara y corrigiendo el manejo de errores.
 */

#include <stdlib.h>
#include <string.h>

#include "xaxivdma.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xstatus.h"

#define VDMA_DEVICE_ID       XPAR_AXIVDMA_0_DEVICE_ID
#define VDMA_RESET_TIMEOUT   100000U

#define FRAME_WIDTH          640U
#define FRAME_HEIGHT         480U
#define BYTES_PER_PIXEL      3U
#define FRAME_STRIDE         (FRAME_WIDTH * BYTES_PER_PIXEL)
#define FRAME_SIZE           (FRAME_STRIDE * FRAME_HEIGHT)
#define FRAME_BUFFER_COUNT   3U

#define UART_COMMAND_SIZE    64U

/*
 * Mapa de registros del wrapper AXI-Lite del TPG. La direccion base coincide
 * con la asignada en el Address Editor de Vivado. Se define aqui porque el
 * TPG es un module reference y el BSP no genera una macro en xparameters.h.
 */
#define TPG_BASEADDR             0x41220000U
#define TPG_ENABLE_OFFSET        0x00U
#define TPG_PATTERN_OFFSET       0x04U
#define TPG_SOLID_COLOR_OFFSET   0x08U
#define TPG_TEMPORAL_STEP_OFFSET 0x0CU
#define TPG_STATUS_OFFSET        0x10U
#define TPG_FRAME_PHASE_OFFSET   0x14U

/*
 * Se conserva la zona de DDR usada por el proyecto de la asignatura:
 * 0x02000000. Tres frames RGB de 640x480 ocupan 2 764 800 bytes.
 */
#define FRAME_BUFFER_BASE    0x02000000U

static XAxiVdma Vdma;

/*
 * Asocia la instancia del driver con el AXI VDMA descrito por el BSP.
 */
static int vdma_init(XAxiVdma *InstancePtr)
{
    XAxiVdma_Config *ConfigPtr;
    int Status;

    ConfigPtr = XAxiVdma_LookupConfig(VDMA_DEVICE_ID);
    if (ConfigPtr == NULL) {
        xil_printf("ERROR: VDMA device %d not found\r\n", VDMA_DEVICE_ID);
        return XST_FAILURE;
    }

    Status = XAxiVdma_CfgInitialize(
        InstancePtr,
        ConfigPtr,
        ConfigPtr->BaseAddress
    );
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: VDMA initialization failed (%d)\r\n", Status);
        return XST_FAILURE;
    }

    if ((InstancePtr->HasS2Mm == 0) || (InstancePtr->HasMm2S == 0)) {
        xil_printf("ERROR: VDMA requires both S2MM and MM2S channels\r\n");
        return XST_FAILURE;
    }

    if (InstancePtr->MaxNumFrames < FRAME_BUFFER_COUNT) {
        xil_printf(
            "ERROR: VDMA supports %d frame stores; %d are required\r\n",
            InstancePtr->MaxNumFrames,
            FRAME_BUFFER_COUNT
        );
        return XST_FAILURE;
    }

    xil_printf("VDMA initialized at 0x%08x\r\n", ConfigPtr->BaseAddress);
    return XST_SUCCESS;
}

/*
 * Reinicia un canal del VDMA y limita la espera para evitar un bloqueo
 * infinito si el hardware no responde.
 */
static int vdma_reset(XAxiVdma *InstancePtr, u16 Direction)
{
    u32 Timeout;
    const char *ChannelName;

    ChannelName = (Direction == XAXIVDMA_READ) ? "MM2S/read" : "S2MM/write";
    xil_printf("Resetting VDMA %s channel...\r\n", ChannelName);

    XAxiVdma_Reset(InstancePtr, Direction);

    Timeout = VDMA_RESET_TIMEOUT;
    while ((XAxiVdma_ResetNotDone(InstancePtr, Direction) != 0) &&
           (Timeout > 0U)) {
        Timeout--;
    }

    if (Timeout == 0U) {
        xil_printf("ERROR: VDMA %s reset timed out\r\n", ChannelName);
        return XST_FAILURE;
    }

    xil_printf("VDMA %s reset complete\r\n", ChannelName);
    return XST_SUCCESS;
}

/*
 * Configura la geometria del frame y las tres direcciones de DDR de un canal.
 * Los dos canales usan los mismos buffers: S2MM escribe y MM2S lee.
 */
static int vdma_configure_channel(XAxiVdma *InstancePtr, u16 Direction)
{
    XAxiVdma_DmaSetup DmaSetup;
    UINTPTR BufferAddress;
    const char *ChannelName;
    u32 Index;
    int Status;

    ChannelName = (Direction == XAXIVDMA_READ) ? "MM2S/read" : "S2MM/write";
    memset(&DmaSetup, 0, sizeof(DmaSetup));

    /*
     * HoriSizeInput y Stride se expresan en bytes, no en pixeles.
     */
    DmaSetup.VertSizeInput = (int)FRAME_HEIGHT;
    DmaSetup.HoriSizeInput = (int)FRAME_STRIDE;
    DmaSetup.Stride = (int)FRAME_STRIDE;
    DmaSetup.FrameDelay = 0;
    DmaSetup.EnableCircularBuf = 1;
    DmaSetup.EnableSync = 1;
    DmaSetup.PointNum = 0;
    DmaSetup.EnableFrameCounter = 0;
    DmaSetup.FixedFrameStoreAddr = 0;
    DmaSetup.GenLockRepeat = 0;
    DmaSetup.EnableVFlip = 0U;

    BufferAddress = (UINTPTR)FRAME_BUFFER_BASE;
    for (Index = 0U; Index < FRAME_BUFFER_COUNT; Index++) {
        DmaSetup.FrameStoreStartAddr[Index] = BufferAddress;
        xil_printf(
            "VDMA %s buffer %d: 0x%08x\r\n",
            ChannelName,
            Index,
            (u32)BufferAddress
        );
        BufferAddress += (UINTPTR)FRAME_SIZE;
    }

    Status = XAxiVdma_DmaConfig(InstancePtr, Direction, &DmaSetup);
    if (Status != XST_SUCCESS) {
        xil_printf(
            "ERROR: VDMA %s configuration failed (%d)\r\n",
            ChannelName,
            Status
        );
        return XST_FAILURE;
    }

    Status = XAxiVdma_DmaSetBufferAddr(
        InstancePtr,
        Direction,
        DmaSetup.FrameStoreStartAddr
    );
    if (Status != XST_SUCCESS) {
        xil_printf(
            "ERROR: VDMA %s buffer setup failed (%d)\r\n",
            ChannelName,
            Status
        );
        return XST_FAILURE;
    }

    xil_printf("VDMA %s configured\r\n", ChannelName);
    return XST_SUCCESS;
}

/*
 * Arranca un canal ya reseteado y configurado.
 */
static int vdma_start(XAxiVdma *InstancePtr, u16 Direction)
{
    const char *ChannelName;
    int Status;

    ChannelName = (Direction == XAXIVDMA_READ) ? "MM2S/read" : "S2MM/write";

    Status = XAxiVdma_DmaStart(InstancePtr, Direction);
    if (Status != XST_SUCCESS) {
        xil_printf(
            "ERROR: VDMA %s start failed (%d)\r\n",
            ChannelName,
            Status
        );
        return XST_FAILURE;
    }

    xil_printf("VDMA %s running\r\n", ChannelName);
    return XST_SUCCESS;
}

/*
 * Recibe por UART un comando completo y lo guarda como una cadena de C.
 *
 * inbyte() entrega un unico caracter cada vez. Por eso Length indica la
 * posicion en la que se almacenara el siguiente caracter recibido. La funcion
 * termina cuando llega Enter y anade '\0', necesario para que las funciones de
 * tratamiento de cadenas sepan donde acaba el comando.
 *
 * Tambien se implementa el eco de los caracteres y el borrado mediante las
 * teclas Backspace o Delete para que la terminal resulte comoda de utilizar.
 */
static unsigned int uart_read_line(char *Buffer, unsigned int BufferSize)
{
    unsigned int Length;
    char ReceivedChar;

    Length = 0U;

    /* Sin espacio disponible no se puede construir ninguna cadena valida. */
    if (BufferSize == 0U) {
        return 0U;
    }

    while (1) {
        /* Espera de forma bloqueante al siguiente caracter recibido. */
        ReceivedChar = inbyte();

        /*
         * Las terminales pueden representar Enter como '\r', '\n' o la
         * pareja "\r\n". Una linea vacia se ignora; esto tambien descarta el
         * segundo caracter de "\r\n" al comenzar la siguiente lectura.
         */
        if ((ReceivedChar == '\r') || (ReceivedChar == '\n')) {
            if (Length == 0U) {
                continue;
            }

            Buffer[Length] = '\0';
            xil_printf("\r\n");
            return Length;
        }

        /*
         * Backspace puede recibirse como 0x08 y Delete como 0x7F. Reducir
         * Length hace que el proximo caracter sobrescriba el que se ha borrado.
         * La secuencia "\b \b" elimina ese caracter tambien en la terminal.
         */
        if ((ReceivedChar == '\b') || (ReceivedChar == 0x7F)) {
            if (Length > 0U) {
                Length--;
                xil_printf("\b \b");
            }

            continue;
        }

        /*
         * Se reserva siempre la ultima posicion del buffer para el '\0'. Si
         * se alcanza el limite, los caracteres adicionales se descartan.
         */
        if (Length < (BufferSize - 1U)) {
            Buffer[Length] = ReceivedChar;
            Length++;

            /* Eco local: muestra por UART el caracter que se acaba de recibir. */
            xil_printf("%c", ReceivedChar);
        }
    }
}

/*
 * Convierte un argumento textual en un entero sin signo.
 *
 * strtoul() deja EndPointer apuntando al primer caracter que no pertenece al
 * numero. La conversion solo se acepta si EndPointer alcanza el '\0'; asi se
 * rechazan argumentos como "12abc". La base cero permite escribir valores en
 * decimal (por ejemplo, 5) o en hexadecimal con prefijo 0x (0xFF0000).
 *
 * La funcion devuelve 1 si la conversion es valida y guarda el resultado en
 * Value. Devuelve 0 si falta el texto o contiene caracteres no numericos.
 */
static int parse_number(const char *Text, unsigned long *Value)
{
    char *EndPointer;

    if ((Text == NULL) || (Value == NULL) || (*Text == '\0')) {
        return 0;
    }

    *Value = strtoul(Text, &EndPointer, 0);

    if (*EndPointer != '\0') {
        return 0;
    }

    return 1;
}

/*
 * Muestra la interfaz de comandos disponible. Mantener esta ayuda junto al
 * parser evita que el usuario tenga que recordar nombres, rangos o formatos.
 */
static void print_tpg_help(void)
{
    xil_printf("Available commands:\r\n");
    xil_printf("  help                 Show this help\r\n");
    xil_printf("  status               Read TPG registers\r\n");
    xil_printf("  enable <0|1>         Disable or enable the TPG\r\n");
    xil_printf("  pattern <0..7>       Select the video pattern\r\n");
    xil_printf("  color <0xRRGGBB>     Set the solid colour\r\n");
    xil_printf("  step <0..255>        Set the temporal-ramp step\r\n");
    xil_printf("Patterns:\r\n");
    xil_printf("  0 black, 1 solid, 2 bars, 3 horizontal ramp\r\n");
    xil_printf("  4 vertical ramp, 5 checkerboard, 6 grid, 7 temporal ramp\r\n");
}

/*
 * Lee los registros AXI-Lite del TPG y presenta su estado por UART.
 *
 * Los registros de patron, color y paso contienen los valores solicitados por
 * software. Si Pending vale 1, el TPG todavia esta terminando el frame actual
 * y esos valores aun no se han transferido a la configuracion activa del core.
 */
static void print_tpg_status(void)
{
    u32 Enable;
    u32 Pattern;
    u32 SolidColor;
    u32 TemporalStep;
    u32 Status;
    u32 FramePhase;

    Enable = Xil_In32(TPG_BASEADDR + TPG_ENABLE_OFFSET);
    Pattern = Xil_In32(TPG_BASEADDR + TPG_PATTERN_OFFSET);
    SolidColor = Xil_In32(TPG_BASEADDR + TPG_SOLID_COLOR_OFFSET);
    TemporalStep = Xil_In32(TPG_BASEADDR + TPG_TEMPORAL_STEP_OFFSET);
    Status = Xil_In32(TPG_BASEADDR + TPG_STATUS_OFFSET);
    FramePhase = Xil_In32(TPG_BASEADDR + TPG_FRAME_PHASE_OFFSET);

    xil_printf("TPG status:\r\n");
    xil_printf("  enable:        %d\r\n", Enable & 0x1U);
    xil_printf("  pattern:       %d\r\n", Pattern & 0x7U);
    xil_printf("  solid color:   0x%06x\r\n", SolidColor & 0xFFFFFFU);
    xil_printf("  temporal step: %d\r\n", TemporalStep & 0xFFU);
    xil_printf("  busy:          %d\r\n", Status & 0x1U);
    xil_printf("  pending:       %d\r\n", (Status >> 1) & 0x1U);
    xil_printf("  frame phase:   %d\r\n", FramePhase & 0xFFU);
}

/*
 * Interpreta una linea recibida por UART y ejecuta la operacion solicitada.
 *
 * strtok() separa el texto usando los espacios como delimitadores. Command
 * guarda la primera palabra, Argument la segunda y ExtraArgument permite
 * detectar que el usuario ha escrito mas parametros de los necesarios.
 *
 * Antes de escribir un registro se comprueba que el argumento existe, que es
 * numerico y que pertenece al rango admitido. Una entrada incorrecta nunca
 * modifica la configuracion del hardware.
 */
static void process_command(char *CommandLine)
{
    char *Command;
    char *Argument;
    char *ExtraArgument;
    unsigned long Value;

    Command = strtok(CommandLine, " ");
    Argument = strtok(NULL, " ");
    ExtraArgument = strtok(NULL, " ");

    if (Command == NULL) {
        return;
    }

    /* Help y status son los unicos comandos que no reciben un argumento. */
    if (strcmp(Command, "help") == 0) {
        if (Argument != NULL) {
            xil_printf("ERROR: help does not accept arguments\r\n");
            return;
        }

        print_tpg_help();
        return;
    }

    if (strcmp(Command, "status") == 0) {
        if (Argument != NULL) {
            xil_printf("ERROR: status does not accept arguments\r\n");
            return;
        }

        print_tpg_status();
        return;
    }

    /*
     * Los comandos siguientes comparten las comprobaciones del argumento.
     * Despues, cada uno valida su propio rango y selecciona su registro AXI.
     */
    if ((strcmp(Command, "enable") == 0) ||
        (strcmp(Command, "pattern") == 0) ||
        (strcmp(Command, "color") == 0) ||
        (strcmp(Command, "step") == 0)) {

        if (Argument == NULL) {
            xil_printf("ERROR: missing argument\r\n");
            return;
        }

        if (ExtraArgument != NULL) {
            xil_printf("ERROR: too many arguments\r\n");
            return;
        }

        if (parse_number(Argument, &Value) == 0) {
            xil_printf("ERROR: invalid numeric argument\r\n");
            return;
        }

        if (strcmp(Command, "enable") == 0) {
            if (Value > 1UL) {
                xil_printf("ERROR: enable must be 0 or 1\r\n");
                return;
            }

            /*
             * El core termina siempre el frame que ya esta enviando. Un cero
             * impide que comience el siguiente; un uno permite nuevos frames.
             */
            Xil_Out32(TPG_BASEADDR + TPG_ENABLE_OFFSET, (u32)Value);
            xil_printf("TPG enable requested: %d\r\n", (u32)Value);
            return;
        }

        if (strcmp(Command, "pattern") == 0) {
            if (Value > 7UL) {
                xil_printf("ERROR: pattern must be between 0 and 7\r\n");
                return;
            }

            /* El wrapper aplicara el patron al terminar el frame actual. */
            Xil_Out32(TPG_BASEADDR + TPG_PATTERN_OFFSET, (u32)Value);
            xil_printf("TPG pattern requested: %d\r\n", (u32)Value);
            return;
        }

        if (strcmp(Command, "color") == 0) {
            if (Value > 0xFFFFFFUL) {
                xil_printf(
                    "ERROR: color must be between 0x000000 and 0xFFFFFF\r\n"
                );
                return;
            }

            /* El formato del registro es RGB888: 8 bits por componente. */
            Xil_Out32(TPG_BASEADDR + TPG_SOLID_COLOR_OFFSET, (u32)Value);
            xil_printf("TPG solid color requested: 0x%06x\r\n", (u32)Value);
            return;
        }

        if (strcmp(Command, "step") == 0) {
            if (Value > 255UL) {
                xil_printf("ERROR: step must be between 0 and 255\r\n");
                return;
            }

            /* El paso se suma a la fase al completar cada frame temporal. */
            Xil_Out32(TPG_BASEADDR + TPG_TEMPORAL_STEP_OFFSET, (u32)Value);
            xil_printf("TPG temporal step requested: %d\r\n", (u32)Value);
            return;
        }
    }

    xil_printf("ERROR: unknown command '%s'\r\n", Command);
}

int main(void)
{
    char CommandLine[UART_COMMAND_SIZE];
    int Status;

    xil_printf("\r\n");
    xil_printf("--- TPG video test ---\r\n");
    xil_printf("Resolution: %d x %d\r\n", FRAME_WIDTH, FRAME_HEIGHT);
    xil_printf("Bytes per pixel: %d\r\n", BYTES_PER_PIXEL);
    xil_printf("Stride: %d bytes\r\n", FRAME_STRIDE);
    xil_printf("Frame size: %d bytes\r\n", FRAME_SIZE);
    xil_printf("VDMA device ID: %d\r\n", VDMA_DEVICE_ID);

    /*
     * Se impide el inicio de nuevos frames mientras se reinicia y configura el
     * VDMA. Si ya habia un frame en curso, el hardware permite que termine.
     */
    Xil_Out32(TPG_BASEADDR + TPG_ENABLE_OFFSET, 0U);

    Status = vdma_init(&Vdma);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_reset(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_reset(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_configure_channel(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_configure_channel(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * Primero se habilita la escritura para que el TPG empiece a llenar DDR.
     * Despues se habilita la lectura hacia la salida HDMI.
     */
    Status = vdma_start(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_start(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        XAxiVdma_DmaStop(&Vdma, XAXIVDMA_WRITE);
        return XST_FAILURE;
    }

    /*
     * El VDMA ya esta preparado para recibir datos. Se cargan unos valores
     * iniciales conocidos y ENABLE se escribe en ultimo lugar para que el TPG
     * no inicie su primer frame antes de que el resto de la cadena este listo.
     */
    Xil_Out32(TPG_BASEADDR + TPG_PATTERN_OFFSET, 2U);
    Xil_Out32(TPG_BASEADDR + TPG_SOLID_COLOR_OFFSET, 0x00FF00U);
    Xil_Out32(TPG_BASEADDR + TPG_TEMPORAL_STEP_OFFSET, 1U);
    Xil_Out32(TPG_BASEADDR + TPG_ENABLE_OFFSET, 1U);

    xil_printf("Video pipeline running\r\n");
    print_tpg_help();

    while (1) {
        /*
         * El procesador puede esperar comandos de forma bloqueante porque el
         * TPG y el VDMA mantienen el video autonomamente en la logica hardware.
         */
        xil_printf("\r\ntpg> ");
        uart_read_line(CommandLine, sizeof(CommandLine));
        process_command(CommandLine);
    }

    return XST_SUCCESS;
}
