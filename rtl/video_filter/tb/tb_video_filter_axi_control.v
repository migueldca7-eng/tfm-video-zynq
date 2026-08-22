`timescale 1ns / 1ps

// Testbench for the AXI4-Lite control wrapper of the HLS video filter.
//
// The HLS pixel datapath is intentionally not instantiated here. Its three
// discrete control/status signals are driven and observed directly so this
// testbench validates only the AXI4-Lite register interface.
module tb_video_filter_axi_control;

    localparam [3:0] ADDR_FILTER_CONTROL = 4'h0;
    localparam [3:0] ADDR_FILTER_STATUS  = 4'h4;
    localparam [3:0] ADDR_UNDEFINED      = 4'h8;

    localparam [1:0] FILTER_BYPASS    = 2'd0;
    localparam [1:0] FILTER_GRAYSCALE = 2'd1;
    localparam [1:0] FILTER_SOBEL     = 2'd2;

    reg clk;
    reg rst;

    reg  [3:0]  s_axi_awaddr;
    reg  [2:0]  s_axi_awprot;
    reg         s_axi_awvalid;
    wire        s_axi_awready;

    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;

    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;

    reg  [3:0]  s_axi_araddr;
    reg  [2:0]  s_axi_arprot;
    reg         s_axi_arvalid;
    wire        s_axi_arready;

    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    wire [1:0]  requested_mode;
    reg  [1:0]  active_mode;
    reg         pending;

    integer errors;
    reg [31:0] read_data;

    video_filter_axi_control dut (
        .clk                (clk),
        .rst                (rst),

        .s_axi_awaddr       (s_axi_awaddr),
        .s_axi_awprot       (s_axi_awprot),
        .s_axi_awvalid      (s_axi_awvalid),
        .s_axi_awready      (s_axi_awready),

        .s_axi_wdata        (s_axi_wdata),
        .s_axi_wstrb        (s_axi_wstrb),
        .s_axi_wvalid       (s_axi_wvalid),
        .s_axi_wready       (s_axi_wready),

        .s_axi_bresp        (s_axi_bresp),
        .s_axi_bvalid       (s_axi_bvalid),
        .s_axi_bready       (s_axi_bready),

        .s_axi_araddr       (s_axi_araddr),
        .s_axi_arprot       (s_axi_arprot),
        .s_axi_arvalid      (s_axi_arvalid),
        .s_axi_arready      (s_axi_arready),

        .s_axi_rdata        (s_axi_rdata),
        .s_axi_rresp        (s_axi_rresp),
        .s_axi_rvalid       (s_axi_rvalid),
        .s_axi_rready       (s_axi_rready),

        .requested_mode     (requested_mode),
        .active_mode        (active_mode),
        .pending            (pending)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst = 1'b1;

        s_axi_awaddr  = 4'd0;
        s_axi_awprot  = 3'd0;
        s_axi_awvalid = 1'b0;

        s_axi_wdata  = 32'd0;
        s_axi_wstrb  = 4'd0;
        s_axi_wvalid = 1'b0;

        s_axi_bready = 1'b0;

        s_axi_araddr  = 4'd0;
        s_axi_arprot  = 3'd0;
        s_axi_arvalid = 1'b0;

        s_axi_rready = 1'b0;

        active_mode = FILTER_BYPASS;
        pending     = 1'b0;

        repeat (5)
            @(posedge clk);

        @(negedge clk);
        rst = 1'b0;
    end

    // Prevent a broken handshake from leaving the simulation running forever.
    initial begin
        #100000;
        $display("FAIL: global simulation timeout");
        $finish;
    end

    // Sends a write with the AW channel arriving before the W channel.
    task axi_write_aw_first;
        input [3:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        reg   [1:0]  held_bresp;
        begin
            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_awready)
                @(posedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;

            repeat (2)
                @(posedge clk);

            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_wready)
                @(posedge clk);

            @(negedge clk);
            s_axi_wvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_bvalid)
                @(posedge clk);

            held_bresp = s_axi_bresp;

            // Hold BREADY low to verify that the response remains stable.
            repeat (2) begin
                @(posedge clk);
                if (!s_axi_bvalid || s_axi_bresp !== held_bresp) begin
                    $display("ERROR: B response changed while BREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_bresp !== 2'b00) begin
                $display("ERROR: AXI write returned non-OKAY response");
                errors = errors + 1;
            end

            @(negedge clk);
            s_axi_bready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Sends a write with the W channel arriving before the AW channel.
    task axi_write_w_first;
        input [3:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        reg   [1:0]  held_bresp;
        begin
            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_wready)
                @(posedge clk);

            @(negedge clk);
            s_axi_wvalid = 1'b0;

            repeat (2)
                @(posedge clk);

            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_awready)
                @(posedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_bvalid)
                @(posedge clk);

            held_bresp = s_axi_bresp;

            repeat (2) begin
                @(posedge clk);
                if (!s_axi_bvalid || s_axi_bresp !== held_bresp) begin
                    $display("ERROR: B response changed while BREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_bresp !== 2'b00) begin
                $display("ERROR: AXI write returned non-OKAY response");
                errors = errors + 1;
            end

            @(negedge clk);
            s_axi_bready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Sends AW and W together, which is also legal AXI4-Lite behavior.
    task axi_write_simultaneous;
        input [3:0]  address;
        input [31:0] data;
        input [3:0]  strobe;
        reg   [1:0]  held_bresp;
        begin
            @(negedge clk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wstrb   = strobe;
            s_axi_wvalid  = 1'b1;

            @(posedge clk);
            while (!(s_axi_awready && s_axi_wready))
                @(posedge clk);

            @(negedge clk);
            s_axi_awvalid = 1'b0;
            s_axi_wvalid  = 1'b0;

            @(posedge clk);
            while (!s_axi_bvalid)
                @(posedge clk);

            held_bresp = s_axi_bresp;
            if (held_bresp !== 2'b00) begin
                $display("ERROR: simultaneous AXI write returned non-OKAY");
                errors = errors + 1;
            end

            @(negedge clk);
            s_axi_bready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    // Reads one register and delays RREADY to verify response stability.
    task axi_read;
        input  [3:0]  address;
        output [31:0] data;
        reg    [31:0] held_rdata;
        reg    [1:0]  held_rresp;
        begin
            @(negedge clk);
            s_axi_araddr  = address;
            s_axi_arvalid = 1'b1;

            @(posedge clk);
            while (!s_axi_arready)
                @(posedge clk);

            @(negedge clk);
            s_axi_arvalid = 1'b0;

            @(posedge clk);
            while (!s_axi_rvalid)
                @(posedge clk);

            held_rdata = s_axi_rdata;
            held_rresp = s_axi_rresp;

            repeat (2) begin
                @(posedge clk);
                if (!s_axi_rvalid ||
                    s_axi_rdata !== held_rdata ||
                    s_axi_rresp !== held_rresp) begin
                    $display("ERROR: R channel changed while RREADY was low");
                    errors = errors + 1;
                end
            end

            if (held_rresp !== 2'b00) begin
                $display("ERROR: AXI read returned non-OKAY response");
                errors = errors + 1;
            end

            data = held_rdata;

            @(negedge clk);
            s_axi_rready = 1'b1;

            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        read_data = 32'd0;

        wait (rst == 1'b0);

        // Reset must select bypass and expose zeroed status.
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd0 || requested_mode !== FILTER_BYPASS) begin
            $display("ERROR: FILTER_CONTROL reset value is not bypass");
            errors = errors + 1;
        end

        axi_read(ADDR_FILTER_STATUS, read_data);
        if (read_data !== 32'd0) begin
            $display("ERROR: FILTER_STATUS reset value is incorrect");
            errors = errors + 1;
        end

        // AW before W: request grayscale.
        axi_write_aw_first(ADDR_FILTER_CONTROL, 32'd1, 4'b0001);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd1 || requested_mode !== FILTER_GRAYSCALE) begin
            $display("ERROR: AW-first grayscale write failed");
            errors = errors + 1;
        end

        // The status register reflects the HLS discrete inputs directly.
        @(negedge clk);
        active_mode = FILTER_BYPASS;
        pending = 1'b1;
        axi_read(ADDR_FILTER_STATUS, read_data);
        if (read_data !== 32'd4) begin
            $display("ERROR: pending grayscale status is incorrect: %h", read_data);
            errors = errors + 1;
        end

        @(negedge clk);
        active_mode = FILTER_GRAYSCALE;
        pending = 1'b0;
        axi_read(ADDR_FILTER_STATUS, read_data);
        if (read_data !== 32'd1) begin
            $display("ERROR: active grayscale status is incorrect: %h", read_data);
            errors = errors + 1;
        end

        // W before AW: request Sobel.
        axi_write_w_first(ADDR_FILTER_CONTROL, 32'd2, 4'b0001);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd2 || requested_mode !== FILTER_SOBEL) begin
            $display("ERROR: W-first Sobel write failed");
            errors = errors + 1;
        end

        // Mode 3 is invalid and must leave the previous Sobel request intact.
        axi_write_aw_first(ADDR_FILTER_CONTROL, 32'd3, 4'b0001);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd2 || requested_mode !== FILTER_SOBEL) begin
            $display("ERROR: invalid mode modified FILTER_CONTROL");
            errors = errors + 1;
        end

        // Disabling byte zero through WSTRB must also preserve the register.
        axi_write_w_first(ADDR_FILTER_CONTROL, 32'd0, 4'b0010);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd2) begin
            $display("ERROR: FILTER_CONTROL ignored WSTRB[0]");
            errors = errors + 1;
        end

        // FILTER_STATUS is read-only and undefined writes have no effect.
        axi_write_aw_first(ADDR_FILTER_STATUS, 32'd0, 4'b0001);
        axi_write_w_first(ADDR_UNDEFINED, 32'd0, 4'b0001);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd2) begin
            $display("ERROR: non-control write modified requested mode");
            errors = errors + 1;
        end

        // Simultaneous AW/W handshakes: return to bypass.
        axi_write_simultaneous(ADDR_FILTER_CONTROL, 32'd0, 4'b0001);
        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd0 || requested_mode !== FILTER_BYPASS) begin
            $display("ERROR: simultaneous bypass write failed");
            errors = errors + 1;
        end

        // Check the complete STATUS field packing: pending=1, active=Sobel.
        @(negedge clk);
        active_mode = FILTER_SOBEL;
        pending = 1'b1;
        axi_read(ADDR_FILTER_STATUS, read_data);
        if (read_data !== 32'd6) begin
            $display("ERROR: Sobel pending status packing is incorrect: %h", read_data);
            errors = errors + 1;
        end

        axi_read(ADDR_UNDEFINED, read_data);
        if (read_data !== 32'd0) begin
            $display("ERROR: undefined read did not return zero");
            errors = errors + 1;
        end

        // A final reset must restore bypass regardless of the previous request.
        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        axi_read(ADDR_FILTER_CONTROL, read_data);
        if (read_data !== 32'd0 || requested_mode !== FILTER_BYPASS) begin
            $display("ERROR: final reset did not restore bypass");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: video_filter_axi_control completed all tests");
        else
            $display(
                "FAIL: video_filter_axi_control found %0d errors",
                errors
            );

        $finish;
    end

endmodule
