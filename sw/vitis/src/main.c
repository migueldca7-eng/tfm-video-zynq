/*
 * Prueba minima de la cadena TPG -> VDMA -> DDR -> HDMI.
 *
 * El programa se construye de forma incremental a partir de CanalVideo.c,
 * eliminando la configuracion de la camara y corrigiendo el manejo de errores.
 */

#include <string.h>

#include "xaxivdma.h"
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

int main(void)
{
    int Status;

    xil_printf("\r\n");
    xil_printf("--- TPG video test ---\r\n");
    xil_printf("Resolution: %d x %d\r\n", FRAME_WIDTH, FRAME_HEIGHT);
    xil_printf("Bytes per pixel: %d\r\n", BYTES_PER_PIXEL);
    xil_printf("Stride: %d bytes\r\n", FRAME_STRIDE);
    xil_printf("Frame size: %d bytes\r\n", FRAME_SIZE);
    xil_printf("VDMA device ID: %d\r\n", VDMA_DEVICE_ID);

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

    xil_printf("Video pipeline running\r\n");

    while (1) {
        /* El hardware mantiene la transferencia de forma autonoma. */
    }

    return XST_SUCCESS;
}
