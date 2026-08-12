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
#include "xtime_l.h"
#include "xvtc.h"

#define VDMA_DEVICE_ID       XPAR_AXIVDMA_0_DEVICE_ID
#define VDMA_RESET_TIMEOUT   100000U
#define VDMA_STOP_TIMEOUT    1000000U
#define VTC_DEVICE_ID        XPAR_VTC_0_DEVICE_ID

#define CLK_WIZ_BASEADDR           XPAR_CLK_WIZ_0_BASEADDR
#define CLK_WIZ_CONTROL_OFFSET     0x000U
#define CLK_WIZ_STATUS_OFFSET      0x004U
#define CLK_WIZ_FEEDBACK_OFFSET    0x200U
#define CLK_WIZ_HDMI5X_OFFSET      0x208U
#define CLK_WIZ_PIXEL_OFFSET       0x214U
#define CLK_WIZ_CAMERA_OFFSET      0x220U
#define CLK_WIZ_LOAD_OFFSET        0x25CU
#define CLK_WIZ_LOCKED_MASK        0x00000001U
#define CLK_WIZ_LOAD_MASK          0x00000001U
#define CLK_WIZ_LOAD_AXI           0x00000003U
#define CLK_WIZ_SW_RESET           0x0000000AU
#define CLK_WIZ_READY_TIMEOUT_MS   10U

#define BYTES_PER_PIXEL      3U
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
#define TPG_FRAME_SIZE_OFFSET    0x18U
#define TPG_STATUS_BUSY_MASK     0x00000001U
#define TPG_IDLE_TIMEOUT         1000000U

/*
 * Los dos perfiles de reloj seleccionaran posteriormente los valores
 * precalculados correspondientes de los registros del Clock Wizard. En este
 * paso solo se guarda la seleccion; el reloj todavia no se reconfigura.
 */
typedef enum {
    VIDEO_CLOCK_25_MHZ = 0,
    VIDEO_CLOCK_74_25_MHZ
} VideoClockProfile;

/*
 * Descripcion completa de un modo de video. El TPG y el VDMA utilizan el
 * ancho y el alto; los porches, pulsos de sincronizacion y polaridades se
 * usaran posteriormente para configurar el VTC. PixelClockHz documenta la
 * frecuencia nominal y ClockProfile identifica la configuracion del reloj.
 */
typedef struct {
    const char *Name;

    u16 Width;
    u16 Height;

    u16 HFrontPorch;
    u16 HSyncWidth;
    u16 HBackPorch;

    u16 VFrontPorch;
    u16 VSyncWidth;
    u16 VBackPorch;

    u8 HSyncPolarity;
    u8 VSyncPolarity;

    u32 PixelClockHz;
    VideoClockProfile ClockProfile;
} VideoMode;

/*
 * Valores ya codificados para los registros de reconfiguracion dinamica del
 * Clock Wizard. Los perfiles de video pueden compartir esta configuracion;
 * 720p60 y 1080p30, por ejemplo, emplean el mismo reloj de pixel nominal.
 */
typedef struct {
    const char *Name;
    u32 FeedbackConfig;
    u32 Hdmi5xConfig;
    u32 PixelConfig;
    u32 CameraConfig;
} VideoClockConfig;

static const VideoClockConfig VideoClockConfigs[] = {
    {
        .Name = "25 MHz pixel clock",
        .FeedbackConfig = 0x00000501U,
        .Hdmi5xConfig = 0x00000005U,
        .PixelConfig = 0x00000019U,
        .CameraConfig = 0x0000001AU
    },
    {
        .Name = "74.25 MHz pixel clock",
        .FeedbackConfig = 0x05773E07U,
        .Hdmi5xConfig = 0x00000003U,
        .PixelConfig = 0x0000000FU,
        .CameraConfig = 0x0000002EU
    }
};

#define VIDEO_CLOCK_CONFIG_COUNT \
    ((u32)(sizeof(VideoClockConfigs) / sizeof(VideoClockConfigs[0])))

/*
 * Modos de video admitidos. Estas estructuras son recetas constantes: el
 * software selecciona una de ellas, pero nunca modifica sus temporizaciones.
 */
static const VideoMode VideoModes[] = {
    {
        .Name = "640x480p60",
        .Width = 640U,
        .Height = 480U,
        .HFrontPorch = 16U,
        .HSyncWidth = 96U,
        .HBackPorch = 48U,
        .VFrontPorch = 10U,
        .VSyncWidth = 2U,
        .VBackPorch = 33U,
        .HSyncPolarity = 0U,
        .VSyncPolarity = 0U,
        .PixelClockHz = 25000000U,
        .ClockProfile = VIDEO_CLOCK_25_MHZ
    },
    {
        .Name = "1280x720p60",
        .Width = 1280U,
        .Height = 720U,
        .HFrontPorch = 110U,
        .HSyncWidth = 40U,
        .HBackPorch = 220U,
        .VFrontPorch = 5U,
        .VSyncWidth = 5U,
        .VBackPorch = 20U,
        .HSyncPolarity = 1U,
        .VSyncPolarity = 1U,
        .PixelClockHz = 74250000U,
        .ClockProfile = VIDEO_CLOCK_74_25_MHZ
    },
    {
        .Name = "1920x1080p30",
        .Width = 1920U,
        .Height = 1080U,
        .HFrontPorch = 88U,
        .HSyncWidth = 44U,
        .HBackPorch = 148U,
        .VFrontPorch = 4U,
        .VSyncWidth = 5U,
        .VBackPorch = 36U,
        .HSyncPolarity = 1U,
        .VSyncPolarity = 1U,
        .PixelClockHz = 74250000U,
        .ClockProfile = VIDEO_CLOCK_74_25_MHZ
    }
};

#define VIDEO_MODE_COUNT \
    ((u32)(sizeof(VideoModes) / sizeof(VideoModes[0])))

/*
 * Cada frame buffer dispone de un espacio fijo de 6 MiB. Asi, sus tres
 * direcciones de DDR no cambian al seleccionar otra resolucion y cada espacio
 * puede alojar un frame RGB888 de 1920x1080 (6 220 800 bytes).
 */
#define FRAME_BUFFER_BASE        0x02000000U
#define FRAME_BUFFER_SLOT_SIZE   0x00600000U

static XAxiVdma Vdma;
static XVtc Vtc;
static const VideoMode *CurrentVideoMode = NULL;

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
static int vdma_configure_channel(
    XAxiVdma *InstancePtr,
    u16 Direction,
    const VideoMode *Mode
)
{
    XAxiVdma_DmaSetup DmaSetup;
    UINTPTR BufferAddress;
    const char *ChannelName;
    u32 FrameStride;
    u32 FrameSize;
    u32 Index;
    int Status;

    if ((Mode == NULL) || (Mode->Width == 0U) || (Mode->Height == 0U)) {
        xil_printf("ERROR: invalid video mode for VDMA configuration\r\n");
        return XST_FAILURE;
    }

    FrameStride = (u32)Mode->Width * BYTES_PER_PIXEL;
    FrameSize = FrameStride * (u32)Mode->Height;

    if (FrameSize > FRAME_BUFFER_SLOT_SIZE) {
        xil_printf(
            "ERROR: %s frame does not fit in a DDR buffer slot\r\n",
            Mode->Name
        );
        return XST_FAILURE;
    }

    ChannelName = (Direction == XAXIVDMA_READ) ? "MM2S/read" : "S2MM/write";
    memset(&DmaSetup, 0, sizeof(DmaSetup));

    /*
     * HoriSizeInput y Stride se expresan en bytes, no en pixeles.
     */
    DmaSetup.VertSizeInput = (int)Mode->Height;
    DmaSetup.HoriSizeInput = (int)FrameStride;
    DmaSetup.Stride = (int)FrameStride;
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
        BufferAddress += (UINTPTR)FRAME_BUFFER_SLOT_SIZE;
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
 * Solicita la parada de un canal de la VDMA y espera hasta que el hardware
 * confirme que ha quedado inactivo.
 */
static int vdma_stop_and_wait(
    XAxiVdma *InstancePtr,
    u16 Direction
)
{
    u32 Timeout;
    int Busy;

    XAxiVdma_DmaStop(InstancePtr, Direction);

    Timeout = VDMA_STOP_TIMEOUT;

    do {
        Busy = XAxiVdma_IsBusy(InstancePtr, Direction);
        Timeout--;
    } while ((Busy != 0) && (Timeout > 0U));

    if (Busy != 0) {
        xil_printf("ERROR: VDMA channel did not stop\r\n");
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

/*
 * Asocia la instancia del driver con el Video Timing Controller descrito por
 * el BSP. La configuracion temporal concreta se carga posteriormente.
 */
static int vtc_init(XVtc *InstancePtr)
{
    XVtc_Config *ConfigPtr;
    int Status;

    ConfigPtr = XVtc_LookupConfig(VTC_DEVICE_ID);
    if (ConfigPtr == NULL) {
        xil_printf("ERROR: VTC device %d not found\r\n", VTC_DEVICE_ID);
        return XST_FAILURE;
    }

    Status = XVtc_CfgInitialize(
        InstancePtr,
        ConfigPtr,
        ConfigPtr->BaseAddress
    );
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: VTC initialization failed (%d)\r\n", Status);
        return XST_FAILURE;
    }

    xil_printf("VTC initialized at 0x%08x\r\n", ConfigPtr->BaseAddress);
    return XST_SUCCESS;
}

/*
 * Convierte uno de nuestros perfiles de video al formato de temporizacion que
 * espera el driver del VTC. El propio driver transforma los tamanos activos,
 * porches y pulsos en las posiciones absolutas de sus registros internos.
 */
static void vtc_configure(XVtc *InstancePtr, const VideoMode *Mode)
{
    XVtc_Timing Timing;

    memset(&Timing, 0, sizeof(Timing));

    Timing.HActiveVideo = Mode->Width;
    Timing.HFrontPorch = Mode->HFrontPorch;
    Timing.HSyncWidth = Mode->HSyncWidth;
    Timing.HBackPorch = Mode->HBackPorch;
    Timing.HSyncPolarity = Mode->HSyncPolarity;

    Timing.VActiveVideo = Mode->Height;
    Timing.V0FrontPorch = Mode->VFrontPorch;
    Timing.V0SyncWidth = Mode->VSyncWidth;
    Timing.V0BackPorch = Mode->VBackPorch;
    Timing.VSyncPolarity = Mode->VSyncPolarity;

    /* Todos los modos admitidos son progresivos, no entrelazados. */
    Timing.Interlaced = 0U;

    XVtc_SetGeneratorTiming(InstancePtr, &Timing);
    XVtc_RegUpdateEnable(InstancePtr);

    xil_printf("VTC configured for %s\r\n", Mode->Name);
}

/*
 * Espera hasta que el Clock Wizard haya terminado cualquier reconfiguracion:
 * LOAD debe haberse limpiado automaticamente y el MMCM debe recuperar LOCKED.
 * El temporizador global del PS no depende de los relojes que modificamos.
 */
static int clock_wait_until_ready(void)
{
    XTime StartTime;
    XTime CurrentTime;
    XTime TimeoutCounts;
    u32 StatusRegister;
    u32 LoadRegister;

    TimeoutCounts =
        ((XTime)COUNTS_PER_SECOND * CLK_WIZ_READY_TIMEOUT_MS) / 1000U;

    XTime_GetTime(&StartTime);

    do {
        StatusRegister = Xil_In32(
            CLK_WIZ_BASEADDR + CLK_WIZ_STATUS_OFFSET
        );

        LoadRegister = Xil_In32(
            CLK_WIZ_BASEADDR + CLK_WIZ_LOAD_OFFSET
        );

        if (((StatusRegister & CLK_WIZ_LOCKED_MASK) != 0U) &&
            ((LoadRegister & CLK_WIZ_LOAD_MASK) == 0U)) {
            return XST_SUCCESS;
        }

        XTime_GetTime(&CurrentTime);
    } while ((CurrentTime - StartTime) < TimeoutCounts);

    xil_printf(
        "ERROR: Clock Wizard timeout, status=0x%08x load=0x%08x\r\n",
        StatusRegister,
        LoadRegister
    );

    return XST_FAILURE;
}

/*
 * Carga en el estado programable AXI los divisores precalculados del perfil
 * solicitado. Los registros determinan la frecuencia del MMCM y de cada una
 * de sus salidas.
 */
static int clock_configure(VideoClockProfile Profile)
{
    const VideoClockConfig *Config;
    int Status;

    if ((u32)Profile >= VIDEO_CLOCK_CONFIG_COUNT) {
        xil_printf("ERROR: invalid video clock profile\r\n");
        return XST_FAILURE;
    }

    Config = &VideoClockConfigs[(u32)Profile];

    /*
     * El reset software devuelve la logica de reconfiguracion dinamica a un
     * estado conocido. Esto permite realizar varios cambios consecutivos sin
     * tener que reprogramar la FPGA.
     */
    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_CONTROL_OFFSET,
        CLK_WIZ_SW_RESET
    );

    /* Espera a que el MMCM recupere LOCKED despues del reset software. */
    Status = clock_wait_until_ready();
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: Clock Wizard software reset failed\r\n");
        return XST_FAILURE;
    }

    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_FEEDBACK_OFFSET,
        Config->FeedbackConfig
    );
    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_HDMI5X_OFFSET,
        Config->Hdmi5xConfig
    );
    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_PIXEL_OFFSET,
        Config->PixelConfig
    );
    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_CAMERA_OFFSET,
        Config->CameraConfig
    );

    /*
     * LOAD=1 inicia la operacion y SADDR=1 selecciona los valores escritos
     * mediante AXI. El propio Clock Wizard limpia LOAD cuando recupera lock.
     */
    Xil_Out32(
        CLK_WIZ_BASEADDR + CLK_WIZ_LOAD_OFFSET,
        CLK_WIZ_LOAD_AXI
    );

    Status = clock_wait_until_ready();
    if (Status != XST_SUCCESS) {
        xil_printf("ERROR: Clock Wizard reconfiguration failed\r\n");
        return XST_FAILURE;
    }

    xil_printf("Clock Wizard configured: %s\r\n", Config->Name);
    return XST_SUCCESS;
}

/*
 * Solicita al wrapper del TPG las dimensiones activas del modo seleccionado.
 * La altura se coloca en los 16 bits superiores del registro FRAME_SIZE y la
 * anchura en los 16 inferiores. El wrapper mantiene ambos valores estables
 * mientras el core esta generando un frame.
 */
static void tpg_configure_size(const VideoMode *Mode)
{
    u32 PackedSize;

    PackedSize = ((u32)Mode->Height << 16) |
                 (u32)Mode->Width;

    Xil_Out32(
        TPG_BASEADDR + TPG_FRAME_SIZE_OFFSET,
        PackedSize
    );

    xil_printf(
        "TPG frame size requested: %d x %d\r\n",
        Mode->Width,
        Mode->Height
    );
}

/*
 * Impide que el TPG comience un frame nuevo y espera a que termine el que
 * pudiera estar generando. La VDMA debe continuar funcionando durante esta
 * espera para que el AXI4-Stream pueda completar el frame actual.
 */
static int tpg_stop_and_wait_idle(void)
{
    u32 Busy;
    u32 Timeout;

    /*
     * Bajar enable no interrumpe el frame actual. El core termina dicho frame,
     * pero no comienza otro nuevo.
     */
    Xil_Out32(TPG_BASEADDR + TPG_ENABLE_OFFSET, 0U);

    Timeout = TPG_IDLE_TIMEOUT;

    /*
     * Consulta el bit busy del registro STATUS hasta que el TPG quede inactivo
     * o se agote el timeout.
     */
    do {
        Busy = Xil_In32(
            TPG_BASEADDR + TPG_STATUS_OFFSET
        ) & TPG_STATUS_BUSY_MASK;

        Timeout--;
    } while ((Busy != 0U) && (Timeout > 0U));

    if (Busy != 0U) {
        xil_printf("ERROR: TPG did not finish the current frame\r\n");
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

/*
 * Reconfigura de forma ordenada todos los bloques de la cadena de video.
 * El TPG termina siempre el frame actual antes de detener la VDMA.
 *
 * Si ocurre un error, el TPG permanece deshabilitado para evitar que genere
 * datos con una configuracion parcial o incompatible.
 */
static int video_apply_mode(const VideoMode *Mode)
{
    u32 PreviousEnable;
    int Status;

    if (Mode == NULL) {
        xil_printf("ERROR: invalid video mode\r\n");
        return XST_FAILURE;
    }

    /*
     * Se conserva el estado solicitado por el usuario. Al finalizar, el TPG
     * solamente se reactivara si estaba habilitado antes del cambio.
     */
    PreviousEnable = Xil_In32(
        TPG_BASEADDR + TPG_ENABLE_OFFSET
    );

    /*
     * Se impide comenzar otro frame y se espera a que termine completamente
     * el frame que pudiera estar en curso.
     */
    Status = tpg_stop_and_wait_idle();
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * El canal de escritura se detiene primero porque el TPG ya no enviara
     * mas datos. Despues se detiene el canal que lee los frames de DDR.
     */
    Status = vdma_stop_and_wait(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_stop_and_wait(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * Se detiene la generacion de temporizacion antes de modificar el reloj
     * de pixel y los parametros temporales.
     */
    XVtc_Disable(&Vtc);

    Status = clock_configure(Mode->ClockProfile);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * Tras estabilizarse el nuevo reloj se configuran las temporizaciones y
     * se preparan de nuevo los dos canales de la VDMA.
     */
    vtc_configure(&Vtc, Mode);

    Status = vdma_reset(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_reset(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_configure_channel(
        &Vdma,
        XAXIVDMA_WRITE,
        Mode
    );
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_configure_channel(
        &Vdma,
        XAXIVDMA_READ,
        Mode
    );
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * Mientras el TPG sigue deshabilitado se cargan sus nuevas dimensiones.
     */
    tpg_configure_size(Mode);

    /*
     * Los consumidores se ponen en funcionamiento antes de permitir que el
     * TPG vuelva a generar datos.
     */
    Status = vdma_start(&Vdma, XAXIVDMA_WRITE);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_start(&Vdma, XAXIVDMA_READ);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XVtc_Enable(&Vtc);

    Xil_Out32(
        TPG_BASEADDR + TPG_ENABLE_OFFSET,
        PreviousEnable
    );

    CurrentVideoMode = Mode;

    xil_printf("Video mode active: %s\r\n", Mode->Name);
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
    xil_printf("  resolution <0..2>    Select the video resolution\r\n");
    xil_printf("Patterns:\r\n");
    xil_printf("  0 black, 1 solid, 2 bars, 3 horizontal ramp\r\n");
    xil_printf("  4 vertical ramp, 5 checkerboard, 6 grid, 7 temporal ramp\r\n");
    xil_printf("Video modes:\r\n");
    xil_printf("  0 640x480p60, 1 1280x720p60, 2 1920x1080p30\r\n");
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

    if (CurrentVideoMode != NULL) {
        xil_printf("Video mode:\r\n");
        xil_printf("  name:          %s\r\n", CurrentVideoMode->Name);
        xil_printf(
            "  resolution:    %d x %d\r\n",
            CurrentVideoMode->Width,
            CurrentVideoMode->Height
        );
        xil_printf(
            "  pixel clock:   %d Hz\r\n",
            CurrentVideoMode->PixelClockHz
        );
    }

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
        (strcmp(Command, "step") == 0) ||
        (strcmp(Command, "resolution") == 0)) {

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

        if (strcmp(Command, "resolution") == 0) {
            if (Value >= (unsigned long)VIDEO_MODE_COUNT) {
                xil_printf("ERROR: resolution must be between 0 and 2\r\n");
                return;
            }

            if (video_apply_mode(&VideoModes[(u32)Value]) != XST_SUCCESS) {
                xil_printf("ERROR: video mode change failed\r\n");
                return;
            }

            return;
        }
    }

    xil_printf("ERROR: unknown command '%s'\r\n", Command);
}

int main(void)
{
    char CommandLine[UART_COMMAND_SIZE];
    const VideoMode *InitialMode;
    u32 InitialStride;
    u32 InitialFrameSize;
    int Status;

    InitialMode = &VideoModes[0];
    InitialStride = (u32)InitialMode->Width * BYTES_PER_PIXEL;
    InitialFrameSize = InitialStride * (u32)InitialMode->Height;

    xil_printf("\r\n");
    xil_printf("--- TPG video test ---\r\n");
    xil_printf("Video mode: %s\r\n", InitialMode->Name);
    xil_printf(
        "Resolution: %d x %d\r\n",
        InitialMode->Width,
        InitialMode->Height
    );
    xil_printf("Bytes per pixel: %d\r\n", BYTES_PER_PIXEL);
    xil_printf("Stride: %d bytes\r\n", InitialStride);
    xil_printf("Frame size: %d bytes\r\n", InitialFrameSize);
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

    Status = vtc_init(&Vtc);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    /*
     * El bitstream arranca con el reloj mas rapido para que implementacion
     * verifique el peor caso. Antes de iniciar el video, software selecciona
     * el reloj correspondiente al modo inicial.
     */
    Status = clock_configure(InitialMode->ClockProfile);
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

    Status = vdma_configure_channel(&Vdma, XAXIVDMA_WRITE, InitialMode);
    if (Status != XST_SUCCESS) {
        return XST_FAILURE;
    }

    Status = vdma_configure_channel(&Vdma, XAXIVDMA_READ, InitialMode);
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
     * El VTC genera la temporizacion que utiliza la salida de video. Se
     * configura y habilita despues de que ambos canales del VDMA esten listos.
     */
    vtc_configure(&Vtc, InitialMode);
    XVtc_Enable(&Vtc);
    XVtc_EnableGenerator(&Vtc);

    /*
     * El VDMA ya esta preparado para recibir datos. Se cargan unos valores
     * iniciales conocidos y ENABLE se escribe en ultimo lugar para que el TPG
     * no inicie su primer frame antes de que el resto de la cadena este listo.
     */
    Xil_Out32(TPG_BASEADDR + TPG_PATTERN_OFFSET, 2U);
    Xil_Out32(TPG_BASEADDR + TPG_SOLID_COLOR_OFFSET, 0x00FF00U);
    Xil_Out32(TPG_BASEADDR + TPG_TEMPORAL_STEP_OFFSET, 1U);
    tpg_configure_size(InitialMode);
    Xil_Out32(TPG_BASEADDR + TPG_ENABLE_OFFSET, 1U);

    CurrentVideoMode = InitialMode;

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
