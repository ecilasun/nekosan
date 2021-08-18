`timescale 1ns / 1ps

module sysbus(
	input wire clock,
	input wire audiocore,
	input wire clk25,
	input wire clk50,
	input wire gpuclock,
	input wire resetn,
	// Control
	output wire busbusy,
	input [31:0] busaddress,
	inout wire [31:0] busdata,
	input wire [3:0] buswe,
	input wire busre,
	input wire cachemode, // 0:D$, 1:I$
	// Interrupts
	output logic [2:0] IRQ_BITS = 3'b000,
	// UART
	output wire uart_rxd_out,
	input wire uart_txd_in,
	// DDR3
	input wire sys_clk_in,
	input wire ddr3_ref,
    output          ddr3_reset_n,
    output  [0:0]   ddr3_cke,
    output  [0:0]   ddr3_ck_p, 
    output  [0:0]   ddr3_ck_n,
    output  [0:0]   ddr3_cs_n,
    output          ddr3_ras_n, 
    output          ddr3_cas_n, 
    output          ddr3_we_n,
    output  [2:0]   ddr3_ba,
    output  [13:0]  ddr3_addr,
    output  [0:0]   ddr3_odt,
    output  [1:0]   ddr3_dm,
    inout   [1:0]   ddr3_dqs_p,
    inout   [1:0]   ddr3_dqs_n,
    inout   [15:0]  ddr3_dq,
    // SPI
	output spi_cs_n,
	output spi_mosi,
	input spi_miso,
	output spi_sck,
	input spi_cd,
	// Switches/buttons
	input [4:0] switches,
	input [3:0] buttons,
	output logic [15:0] leds = 32'd0,
	// I2S2 audio
    output tx_mclk,
    output tx_lrck,
    output tx_sclk,
    output tx_sdout,
	// DVI
	output  [3:0]	DVI_R,
	output  [3:0]	DVI_G,
	output  [3:0]	DVI_B,
	output			DVI_HS,
	output			DVI_VS,
	output			DVI_DE,
	output			DVI_CLK );

// ----------------------------------------------------------------------------
// Data select
// ----------------------------------------------------------------------------

logic [31:0] dataout = 32'd0;
assign busdata = (|buswe) ? 32'dz : dataout;

// Direct access device data
logic [15:0] leddata = 16'd0;

// ----------------------------------------------------------------------------
// Device ID
// ----------------------------------------------------------------------------
localparam DEV_LEDRW			= 10;
localparam DEV_AUDIOSTREAMOUT	= 9;
localparam DEV_SWITCHCOUNT		= 8;
localparam DEV_SWITCHES			= 7;
localparam DEV_SPIRW			= 6;
localparam DEV_UARTRW			= 5;
localparam DEV_UARTCOUNT		= 4;
localparam DEV_GPUFIFO			= 3;
localparam DEV_ARAM				= 2;
localparam DEV_GRAM				= 1;
localparam DEV_DDR3				= 0;

wire [10:0] deviceSelect = {
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0111 ? 1'b1 : 1'b0,	// 0A: 0x8xxxxx1C LED read/write port				+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0110 ? 1'b1 : 1'b0,	// 09: 0x8xxxxx18 Raw audio output port				+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0101 ? 1'b1 : 1'b0,	// 08: 0x8xxxxx14 Switch incoming queue byte ready	+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0100 ? 1'b1 : 1'b0,	// 07: 0x8xxxxx10 Device switch states				+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0011 ? 1'b1 : 1'b0,	// 06: 0x8xxxxx0C SPI read/write port				+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0010 ? 1'b1 : 1'b0,	// 05: 0x8xxxxx08 UART read/write port				+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0001 ? 1'b1 : 1'b0,	// 04: 0x8xxxxx04 UART incoming queue byte ready	+
	{busaddress[31:28], busaddress[5:2]} == 8'b1000_0000 ? 1'b1 : 1'b0,	// 03: 0x8xxxxx00 GPU command queue					+
	(busaddress[31:28]==4'b0010) ? 1'b1 : 1'b0,							// 02: 0x20000000 - 0x2FFFFFFF - ARAM				+
	(busaddress[31:28]==4'b0001) ? 1'b1 : 1'b0,							// 01: 0x10000000 - 0x1FFFFFFF - GRAM				+
	(busaddress[31:28]==4'b0000) ? 1'b1 : 1'b0							// 00: 0x00000000 - 0x0FFFFFFF (DDR3 - 256Mbytes)	+
};

// ----------------------------------------------------------------------------
// Color palette
// ----------------------------------------------------------------------------

wire palettewe;
wire [7:0] paletteaddress;
wire [7:0] palettereadaddress;
wire [23:0] palettedata;

logic [23:0] paletteentries[0:255];

// Set up with VGA color palette on startup
initial begin
	$readmemh("colorpalette.mem", paletteentries);
end

always @(posedge gpuclock) begin // Tied to GPU clock
	if (palettewe)
		paletteentries[paletteaddress] <= palettedata;
end

wire [23:0] paletteout;
assign paletteout = paletteentries[palettereadaddress];

// ----------------------------------------------------------------------------
// Video units and DVI scan-out
// ----------------------------------------------------------------------------

// Ties to the GPU below, for GPU driven writes
wire [14:0] gpuwriteaddress;
wire [3:0] gpuwriteenable;
wire [31:0] gpuwriteword;

wire [11:0] video_x;
wire [11:0] video_y;

wire videopage;
wire [7:0] PALETTEINDEX_ONE;
wire [7:0] PALETTEINDEX_TWO;

wire dataEnableA, dataEnableB;
wire inDisplayWindowA, inDisplayWindowB;

VideoControllerGen VideoUnitA(
	.gpuclock(gpuclock),
	.vgaclock(clk25),
	.writesenabled(videopage),
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpuwriteaddress),
	.mem_writeena(gpuwriteenable),
	.writeword(gpuwriteword),
	.lanemask(gpulanewritemask),
	// Video output
	.paletteindex(PALETTEINDEX_ONE),
	.dataEnable(dataEnableA),
	.inDisplayWindow(inDisplayWindowA) );

VideoControllerGen VideoUnitB(
	.gpuclock(gpuclock),
	.vgaclock(clk25),
	.writesenabled(~videopage),
	.video_x(video_x),
	.video_y(video_y),
	// Wire input
	.memaddress(gpuwriteaddress),
	.mem_writeena(gpuwriteenable),
	.writeword(gpuwriteword),
	.lanemask(gpulanewritemask),
	// Video output
	.paletteindex(PALETTEINDEX_TWO),
	.dataEnable(dataEnableB),
	.inDisplayWindow(inDisplayWindowB) );

wire vsync_we;
wire [31:0] vsynccounter;
logic [31:0] vsync_signal = 32'd0;

wire dataEnable = videopage == 1'b0 ? dataEnableA : dataEnableB;
wire inDisplayWindow = videopage == 1'b0 ? inDisplayWindowA : inDisplayWindowB;
assign DVI_DE = dataEnable;
assign palettereadaddress = (videopage == 1'b0) ? PALETTEINDEX_ONE : PALETTEINDEX_TWO;
// TODO: Depending on video more, use palette out or the byte (PALETTEINDEX_ONE/PALETTEINDEX_TWO) as RGB color
// May also want to introduce a secondary palette?
wire [3:0] VIDEO_B = paletteout[7:4];
wire [3:0] VIDEO_R = paletteout[15:12];
wire [3:0] VIDEO_G = paletteout[23:20];

// TODO: Border color
assign DVI_R = inDisplayWindow ? (dataEnable ? VIDEO_R : 4'b0010) : 4'h0;
assign DVI_G = inDisplayWindow ? (dataEnable ? VIDEO_G : 4'b0010) : 4'h0;
assign DVI_B = inDisplayWindow ? (dataEnable ? VIDEO_B : 4'b0010) : 4'h0;
assign DVI_CLK = clk25;

videosignalgen VideoScanOut(
	.rst_i(~resetn),
	.clk_i(clk25),					// Video clock input for 640x480 image
	.hsync_o(DVI_HS),				// DVI horizontal sync
	.vsync_o(DVI_VS),				// DVI vertical sync
	.counter_x(video_x),			// Video X position (in actual pixel units)
	.counter_y(video_y),			// Video Y position
	.vsynctrigger_o(vsync_we),		// High when we're OK to queue a VSYNC in FIFO
	.vsynccounter(vsynccounter) );	// Each vsync has a unique marker so that we can wait for them by name

// ----------------------------------------------------------------------------
// GPU command FIFO
// ----------------------------------------------------------------------------

logic gfifowe = 1'b0;
logic [31:0] gfifodin = 32'd0;
wire gpu_fifowrfull;

wire gpu_fifordempty;
wire [31:0] gpu_fifodataout;
wire gpu_fifodatavalid;
wire gpu_fifore;

gpufifo GPUCommands(
	// Write - CPU
	.full(gpu_fifowrfull),
	.din(gfifodin),
	.wr_en(gfifowe),
	// Read - GPU
	.empty(gpu_fifordempty),
	.dout(gpu_fifodataout),
	.rd_en(gpu_fifore),
	.valid(gpu_fifodatavalid),
	// Control
	.wr_clk(clock),		// CPU
	.rd_clk(gpuclock),	// GPU
	.rst(~resetn) );

// ----------------------------------------------------------------------------
// GPU
// ----------------------------------------------------------------------------

// Write control to G-RAM
wire [31:0] gramdmawriteaddress;
wire [31:0] gramdmawriteword;
wire [3:0] gramdmawriteenable;
wire [31:0] gramdmadataout;

gpu GraphicsProcessor(
	.clock(gpuclock),
	.reset(devicereset),
	.vsync(vsync_signal),
	.videopage(videopage),
	// GPU command FIFO control wires
	.fifoempty(gpu_fifordempty),
	.fifodout(gpu_fifodataout),
	.fiford_en(gpu_fifore),
	.fifdoutvalid(gpu_fifodatavalid),
	// VU0/1 direct writes
	.vramaddress(gpuwriteaddress),
	.vramwe(gpuwriteenable),
	.vramwriteword(gpuwriteword),
	//output logic [12:0] lanemask = 70'd0, // We need to pick tiles for simultaneous writes
	// GRAM DMA channel
	.dmaaddress(gramdmawriteaddress),
	.dmawriteword(gramdmawriteword),
	.dmawe(gramdmawriteenable),
	.dma_data(gramdmadataout),
	// Palette write
	.palettewe(palettewe),
	.paletteaddress(paletteaddress),
	.palettedata(palettedata) );

// ----------------------------------------------------------------------------
// Domain crossing vsync
// ----------------------------------------------------------------------------

/*wire [31:0] vsync_fastdomain;
wire vsyncfifoempty;
wire vsyncfifovalid;

logic vsync_re;
DomainCrossSignalFifo GPUVGAVSyncQueue(
	.full(),
	.din(vsynccounter),
	.wr_en(vsync_we),
	.empty(vsyncfifoempty),
	.dout(vsync_fastdomain),
	.rd_en(vsync_re),
	.wr_clk(vgaclock),
	.rd_clk(gpuclock),
	.rst(reset_p),
	.valid(vsyncfifovalid) );

// Drain the vsync fifo and set vsync signal for the GPU every time we find one
always @(posedge gpuclock) begin
	vsync_re <= 1'b0;
	if (~vsyncfifoempty) begin
		vsync_re <= 1'b1;
	end
	if (vsyncfifovalid) begin
		vsync_signal <= vsync_fastdomain;
	end
end*/

// ----------------------------------------------------------------------------
// Audio output FIFO
// ----------------------------------------------------------------------------

wire abfull, abempty, abvalid;
logic [31:0] abdin = 32'd0;
logic abwe = 1'b0;
wire abre;
wire [31:0] abdout;

audiofifo AudioBuffer(
	.wr_clk(clock),
	.full(abfull),
	.din(abdin),
	.wr_en(abwe),
	.rd_clk(audiocore),
	.empty(abempty),
	.dout(abdout),
	.rd_en(abre),
	.valid(abvalid),
	.rst(~resetn) );

i2s2audio soundoutput(
	.cpuclock(clock),
    .audioclock(audiocore),

	.abempty(abempty),
	.abvalid(abvalid),
	.audiore(abre),
    .leftrightchannels(abdout),	// Joint stereo DWORD input

    .tx_mclk(tx_mclk),
    .tx_lrck(tx_lrck),
    .tx_sclk(tx_sclk),
    .tx_sdout(tx_sdout) );

// ----------------------------------------------------------------------------
// Switches + Buttons
// ----------------------------------------------------------------------------

wire switchfull, switchempty;
logic [8:0] switchdatain;
wire [8:0] switchdataout;
wire switchvalid;
logic switchwe=1'b0;
logic switchre=1'b0;

switchfifo DeviceSwitchStates(
	// In
	.full(switchfull),
	.din(switchdatain),
	.wr_en(switchwe),
	.wr_clk(clk25),
	// Out
	.empty(switchempty),
	.dout(switchdataout),
	.rd_en(switchre),
	.rd_clk(clock),
	.valid(switchvalid),
	// Ctl
	.rst(~resetn) );

logic [8:0] prevswitchstate = 9'h00;
logic [8:0] interswitchstate = 9'h00;
logic [8:0] newswitchstate = 9'h00;
wire [8:0] currentswitchstate = {buttons, switches};

always @(posedge clk25) begin
	if (~resetn) begin

		prevswitchstate <= currentswitchstate;

	end else begin

		switchwe <= 1'b0;

		// Pipelined action
		interswitchstate <= currentswitchstate;
		newswitchstate <= interswitchstate;

		// Check if switch states have changed 
		if ((newswitchstate != prevswitchstate) & (~switchfull)) begin
			// Save previous state, and push switch state onto stack
			prevswitchstate <= newswitchstate;
			// Stash switch states into fifo
			switchwe <= 1'b1;
			switchdatain <= newswitchstate;
		end
	end
end

// ----------------------------------------------------------------------------
// SD Card Controller
// ----------------------------------------------------------------------------

// SD Card Write FIFO
wire spiwfull, spiwempty, spiwvalid;
wire [7:0] spiwdout;
wire sddataoutready;
logic spiwre=1'b0;
logic spiwwe=1'b0;
logic [7:0] spiwdin;
SPIfifo SDCardWriteFifo(
	// In
	.full(spiwfull),
	.din(spiwdin),
	.wr_en(spiwwe),
	.clk(clock),
	// Out
	.empty(spiwempty),
	.dout(spiwdout),
	.rd_en(spiwre),
	.valid(spiwvalid),
	// Ctl
	.srst(~resetn) );

// Pull from write queue and send through SD controller
logic sddatawe = 1'b0;
logic [7:0] sddataout = 8'd0;
logic [1:0] sdqwritestate = 2'b00;
always @(posedge clock) begin

	spiwre <= 1'b0;
	sddatawe <= 1'b0;

	unique case (sdqwritestate)
		2'b00: begin
			if ((~spiwempty) & sddataoutready) begin
				spiwre <= 1'b1;
				sdqwritestate <= 2'b01;
			end
		end
		2'b01: begin
			if (spiwvalid) begin
				sddatawe <= 1'b1;
				sddataout <= spiwdout;
				sdqwritestate <= 2'b10;
			end
		end
		2'b10: begin
			// One clock delay to catch with sddataoutready properly
			sdqwritestate <= 2'b00;
		end
	endcase

end

// SD Card Read FIFO
wire spirempty, spirfull, spirvalid;
wire [7:0] spirdout;
logic [7:0] spirdin = 8'd0;
logic spirwe = 1'b0, spirre = 1'b0;
SPIfifo SDCardReadFifo(
	// In
	.full(spirfull),
	.din(spirdin),
	.wr_en(spirwe),
	// Out
	.empty(spirempty),
	.dout(spirdout),
	.rd_en(spirre),
	.valid(spirvalid),
	.clk(clock),
	// Ctl
	.srst(~resetn) );

// Push incoming data from SD controller to read queue
wire [7:0] sddatain;
wire sddatainready;
always @(posedge clock) begin
	spirwe <= 1'b0;
	if (sddatainready) begin
		spirwe <= 1'b1;
		spirdin <= sddatain;
	end
end

SPI_MASTER SDCardController(
        .CLK(clock),
        .RST(~resetn),
        // SPI MASTER INTERFACE
        .SCLK(spi_sck),
        .CS_N(spi_cs_n),
        .MOSI(spi_mosi),
        .MISO(spi_miso),
        // INPUT USER INTERFACE
        .DIN(sddataout),
        //.DIN_ADDR(1'b0), // this range is [-1:0] since we have only one client to pick, therefure unused
        .DIN_LAST(1'b0),
        .DIN_VLD(sddatawe),
        .DIN_RDY(sddataoutready),
        // OUTPUT USER INTERFACE
        .DOUT(sddatain),
        .DOUT_VLD(sddatainready) );

// ----------------------------------------------------------------------------
// DDR3
// ----------------------------------------------------------------------------

wire calib_done;
wire [11:0] device_temp;

logic calib_done1=1'b0, calib_done2=1'b0;

logic [27:0] app_addr = 28'd0;
logic [2:0]  app_cmd = 3'd0;
logic app_en = 1'b0;
wire app_rdy;

logic [127:0] app_wdf_data = 128'd0;
logic app_wdf_wren = 1'b0;
wire app_wdf_rdy;

wire [127:0] app_rd_data;
wire app_rd_data_end;
wire app_rd_data_valid;

wire app_sr_req = 0;
wire app_ref_req = 0;
wire app_zq_req = 0;
wire app_sr_active;
wire app_ref_ack;
wire app_zq_ack;

wire ddr3cmdfull, ddr3cmdempty, ddr3cmdvalid;
logic ddr3cmdre = 1'b0, ddr3cmdwe = 1'b0;
logic [152:0] ddr3cmdin = 153'd0;
wire [152:0] ddr3cmdout;

wire ddr3readfull, ddr3readempty, ddr3readvalid;
logic ddr3readwe = 1'b0, ddr3readre = 1'b0;
logic [127:0] ddr3readin = 128'd0;

wire ui_clk;
wire ui_clk_sync_rst;

MIG7GEN ddr3memoryinterface (
	// Physical device pins
   .ddr3_addr   (ddr3_addr),
   .ddr3_ba     (ddr3_ba),
   .ddr3_cas_n  (ddr3_cas_n),
   .ddr3_ck_n   (ddr3_ck_n),
   .ddr3_ck_p   (ddr3_ck_p),
   .ddr3_cke    (ddr3_cke),
   .ddr3_ras_n  (ddr3_ras_n),
   .ddr3_reset_n(ddr3_reset_n),
   .ddr3_we_n   (ddr3_we_n),
   .ddr3_dq     (ddr3_dq),
   .ddr3_dqs_n  (ddr3_dqs_n),
   .ddr3_dqs_p  (ddr3_dqs_p),
   .ddr3_cs_n   (ddr3_cs_n),
   .ddr3_dm     (ddr3_dm),
   .ddr3_odt    (ddr3_odt),

	// Device status
   .init_calib_complete (calib_done),
   .device_temp(device_temp),

   // User interface ports
   .app_addr 			(app_addr),
   .app_cmd 			(app_cmd),
   .app_en 				(app_en),
   .app_wdf_data		(app_wdf_data),
   .app_wdf_end			(app_wdf_wren),
   .app_wdf_wren		(app_wdf_wren),
   .app_rd_data			(app_rd_data),
   .app_rd_data_end 	(app_rd_data_end),
   .app_rd_data_valid	(app_rd_data_valid),
   .app_rdy 			(app_rdy),
   .app_wdf_rdy 		(app_wdf_rdy),
   .app_sr_req			(app_sr_req),
   .app_ref_req 		(app_ref_req),
   .app_zq_req 			(app_zq_req),
   .app_sr_active		(app_sr_active),
   .app_ref_ack 		(app_ref_ack),
   .app_zq_ack 			(app_zq_ack),
   .ui_clk				(ui_clk),
   .ui_clk_sync_rst 	(ui_clk_sync_rst),
   .app_wdf_mask		(16'h0000), // WARNING: Active low, and always set to write all DWORDs

   // Clock and Reset input ports
   .sys_clk_i 			(sys_clk_in),
   .clk_ref_i			(ddr3_ref),
   .sys_rst				(resetn) );

localparam INIT = 3'd0;
localparam IDLE = 3'd1;
localparam DECODECMD = 3'd2;
localparam WRITE = 3'd3;
localparam WRITE_DONE = 3'd4;
localparam READ = 3'd5;
localparam READ_DONE = 3'd6;

logic [2:0] ddr3uistate = INIT;

localparam CMD_WRITE = 3'b000;
localparam CMD_READ = 3'b001;

always @ (posedge ui_clk) begin
	calib_done1 <= calib_done;
	calib_done2 <= calib_done1;
end

// ddr3 driver
always @ (posedge ui_clk) begin
	if (ui_clk_sync_rst) begin
		ddr3uistate <= INIT;
		app_en <= 0;
		app_wdf_wren <= 0;
	end else begin

		case (ddr3uistate)
			INIT: begin
				if (calib_done2) begin
					ddr3uistate <= IDLE;
				end
			end

			IDLE: begin
				ddr3readwe <= 1'b0;
				if (~ddr3cmdempty) begin
					ddr3cmdre <= 1'b1;
					ddr3uistate <= DECODECMD;
				end
			end

			DECODECMD: begin
				ddr3cmdre <= 1'b0;
				if (ddr3cmdvalid) begin
					if (ddr3cmdout[152]==1'b1) // Write request?
						ddr3uistate <= WRITE;
					else
						ddr3uistate <= READ;
				end
			end

			WRITE: begin
				if (app_rdy & app_wdf_rdy) begin
					app_en <= 1;
					app_wdf_wren <= 1;
					app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
					app_cmd <= CMD_WRITE;
					app_wdf_data <= ddr3cmdout[127:0]; // 128bit value to write to memory from cache
					ddr3uistate <= WRITE_DONE;
				end
			end

			WRITE_DONE: begin
				if (app_rdy & app_en) begin
					app_en <= 0;
				end
			
				if (app_wdf_rdy & app_wdf_wren) begin
					app_wdf_wren <= 0;
				end
			
				if (~app_en & ~app_wdf_wren) begin
					ddr3uistate <= IDLE;
				end
			end

			READ: begin
				if (app_rdy) begin
					app_en <= 1;
					app_addr <= {1'b0, ddr3cmdout[151:128], 3'b000}; // Addresses are in multiples of 16 bits x8 == 128 bits, top bit is supposed to stay zero
					app_cmd <= CMD_READ;
					ddr3uistate <= READ_DONE;
				end
			end

			READ_DONE: begin
				if (app_rdy & app_en) begin
					app_en <= 0;
				end

				if (app_rd_data_valid) begin
					// After this step, full 128bit value will be available on the
					// ddr3readre when read is asserted and ddr3readvalid is high
					ddr3readwe <= 1'b1;
					ddr3readin <= app_rd_data;
					ddr3uistate <= IDLE;
				end
			end
			
			default: begin
				ddr3uistate <= INIT;
			end
		endcase
	end
end

// command fifo
wire cmd_wr_rst_busy, cmd_rd_rst_busy;
ddr3cmdfifo DDR3Cmd(
	.full(ddr3cmdfull),
	.din(ddr3cmdin),
	.wr_en(ddr3cmdwe),
	.wr_clk(clock),
	.empty(ddr3cmdempty),
	.dout(ddr3cmdout),
	.rd_en(ddr3cmdre),
	.valid(ddr3cmdvalid),
	.rd_clk(ui_clk),
	.rst(~resetn), // Driven from bus logic, need to use same reset or we destroy contents
	.wr_rst_busy(cmd_wr_rst_busy),
	.rd_rst_busy(cmd_rd_rst_busy) );

// read done queue
wire [127:0] ddr3readout;
wire done_wr_rst_busy, done_rd_rst_busy;
ddr3readdonequeue DDR3ReadDone(
	.full(ddr3readfull),
	.din(ddr3readin),
	.wr_en(ddr3readwe),
	.wr_clk(ui_clk),
	.empty(ddr3readempty),
	.dout(ddr3readout),
	.rd_en(ddr3readre),
	.valid(ddr3readvalid),
	.rd_clk(clock),
	.rst(ui_clk_sync_rst), // Since it's driven by DDR3 logic, can reset there
	.wr_rst_busy(done_wr_rst_busy),
	.rd_rst_busy(done_rd_rst_busy) );

// ----------------------------------------------------------------------------
// A-RAM
// ----------------------------------------------------------------------------

logic [13:0] aramaddr = 14'd0;
logic [31:0] aramdin = 32'd0;
logic [3:0] aramwe = 4'h0;
logic aramre = 1'b0;
wire [31:0] aramdout;
scratchpadmemory AudioAndBootMemory(
	.addra(aramaddr),
	.clka(clock),
	.dina(aramdin),
	.douta(aramdout),
	.ena((resetn) & (aramre | (|aramwe))),
	.wea(aramwe) );
	
// ----------------------------------------------------------------------------
// G-RAM
// ----------------------------------------------------------------------------

logic [13:0] gramaddr = 14'd0;
logic [31:0] gramdin = 32'd0;
wire [31:0] gramdout;
logic [3:0] gramwe = 4'h0;
logic gramre = 1'b0;

GRAM GraphicsMemory(
	// Port A - CPU access via CPU bus
	.addra(gramaddr),	// 0x10000000-0x1FFFFFFFF (DWORD aligned, lower 2 bits dropped) - 64K usable
	.clka(clock),
	.dina(gramdin),
	.douta(gramdout),
	.ena(deviceSelect[DEV_GRAM] & (gramre | (|gramwe))), // Enable only when Device ID == GRAM ID
	.wea(gramwe),
	// Port B - GPU DMA access
	.addrb(gramdmawriteaddress[15:2]), // 13:0
	.clkb(gpuclock),
	.dinb(gramdmawriteword),
	.doutb(gramdmadataout),
	.enb(1'b1), // Always enabled for GPU access
	.web(gramdmawriteenable) );

// ----------------------------------------------------------------------------
// UART Transmitter
// ----------------------------------------------------------------------------

logic transmitbyte = 1'b0;
logic [7:0] datatotransmit = 8'h00;
wire uarttxbusy;

async_transmitter UART_transmit(
	.clk(clk25),
	.TxD_start(transmitbyte),
	.TxD_data(datatotransmit),
	.TxD(uart_rxd_out),
	.TxD_busy(uarttxbusy) );
	
logic [7:0] uartsenddin = 8'd0;
wire [7:0] uartsenddout;
logic uartsendwe = 1'b0, uartre = 1'b0;
wire uartsendfull, uartsendempty, uartsendvalid;

uartsendfifo UARTDataOutFIFO(
	.full(uartsendfull),
	.din(uartsenddin),
	.wr_en(uartsendwe),
	.wr_clk(clock), // Write using bus clock
	.empty(uartsendempty),
	.valid(uartsendvalid),
	.dout(uartsenddout),
	.rd_en(uartre),
	.rd_clk(clk25), // Read using UART base clock
	.rst(~resetn) );

logic [1:0] uartwritemode = 2'b00;
always @(posedge clk25) begin

	uartre <= 1'b0;
	transmitbyte <= 1'b0;

	case(uartwritemode)
		2'b00: begin // IDLE
			if (~uartsendempty & (~uarttxbusy)) begin
				uartre <= 1'b1;
				uartwritemode <= 2'b01; // WRITE
			end
		end
		2'b01: begin // WRITE
			if (uartsendvalid) begin
				transmitbyte <= 1'b1;
				datatotransmit <= uartsenddout;
				uartwritemode <= 2'b10; // FINALIZE
			end
		end
		2'b10: begin // FINALIZE
			// Need to give UARTTX one clock to
			// kick 'busy' for any adjacent
			// requests which didn't set busy yet
			uartwritemode <= 2'b00; // IDLE
		end
	endcase

end

// ----------------------------------------------------------------------------
// UART Receiver
// ----------------------------------------------------------------------------

wire uartbyteavailable;
wire [7:0] uartbytein;

async_receiver UART_receive(
	.clk(clk25),
	.RxD(uart_txd_in),
	.RxD_data_ready(uartbyteavailable),
	.RxD_data(uartbytein),
	.RxD_idle(),
	.RxD_endofpacket() );

wire uartrcvfull, uartrcvempty, uartrcvvalid;
logic [7:0] uartrcvdin;
wire [7:0] uartrcvdout;
logic uartrcvre = 1'b0, uartrcvwe = 1'b0;
uartrcvfifo UARTDataInFIFO(
	.full(uartrcvfull),
	.din(uartrcvdin),
	.wr_en(uartrcvwe),
	.wr_clk(clk25),
	.empty(uartrcvempty),
	.dout(uartrcvdout),
	.rd_en(uartrcvre),
	.valid(uartrcvvalid),
	.rd_clk(clock),
	.rst(~resetn) );

always @(posedge clk25) begin
	uartrcvwe <= 1'b0;
	if (uartbyteavailable) begin // And if the FIFO is full, disaster... Perhaps use interrupts to guarantee reads?
		uartrcvwe <= 1'b1;
		uartrcvdin <= uartbytein;
	end
end

// ----------------------------------------------------------------------------
// IRQ bit field
// ----------------------------------------------------------------------------

always @(posedge clock) begin
	// Keeps forcing interrupts until the FIFOs are empty
	// Handler should try to drain the fifo at least up to FIFO size items
	// but doesn't need to over-drain as it will re-trigger next chance
	// as long as the fifo has entries
	IRQ_BITS[0] <= ~uartrcvempty;	// UARTRX
	IRQ_BITS[1] <= ~spirempty;		// SPIRX
	IRQ_BITS[2] <= ~switchempty;	// SWITCHES/SLIDERS
end

// ----------------------------------------------------------------------------
// Cache wiring
// ----------------------------------------------------------------------------

// The division of address into cache, device and byte index data is as follows
// device  tag                 line       offset  byteindex
// 0000    000 0000 0000 0000  0000 0000  000     00

logic [14:0] ctag		= 15'd0;	// Ignore 4 highest bits since only r/w for DDR3 are routed here
logic [7:0] cline		= 8'd0;		// $:0..255
logic [2:0] coffset		= 3'd0;		// 8xDWORD (256bits) aligned
logic [31:0] cwidemask	= 32'd0;	// Wide mask generate from write mask
logic [15:0] oldtag		= 16'd0;	// Previous ctag + dirty bit

logic [15:0] cachetags[0:255];
logic [255:0] cache[0:255];

initial begin
	integer i;
	// All pages are 'clean', all tags are invalid and cache is zeroed out by default
	for (int i=0;i<256;i=i+1) begin
		cachetags[i] = 16'h7FFF; // Top bit zero
		cache[i] = 256'd0;
	end
end

logic loadindex = 1'b0;
logic [255:0] currentcacheline;

// ----------------------------------------------------------------------------
// Bus Logic
// ----------------------------------------------------------------------------

localparam BUS_INIT					= 0;
localparam BUS_IDLE					= 1;
localparam BUS_READ					= 2;
localparam BUS_WRITE				= 3;
localparam BUS_ARAMRETIRE			= 4;
localparam BUS_DDR3CACHESTOREHI		= 5;
localparam BUS_DDR3CACHELOADHI		= 6;
localparam BUS_DDR3CACHELOADLO		= 7;
localparam BUS_DDR3CACHEWAIT		= 8;
localparam BUS_DDR3UPDATECACHELINE	= 9;
localparam BUS_UPDATEFINALIZE		= 10;
localparam BUS_UARTRETIRE			= 11;
localparam BUS_SPIRETIRE			= 12;
localparam BUS_SWITCHRETIRE			= 13;
localparam BUS_GRAMRETIRE			= 14;

logic [3:0] busmode = BUS_INIT;
logic [31:0] ddr3wdat = 32'd0;
logic ddr3rw = 1'b0;

// Cross
logic calib_done3=1'b0, calib_done4=1'b0;
always @(posedge clock) begin
	calib_done3 <= calib_done;
	calib_done4 <= calib_done3;
end

wire busactive = busmode != BUS_IDLE;
// Any read/write activity and non-mode-0 is considered 'busy'
assign busbusy = busactive | busre | (|buswe);

always @(posedge clock) begin
	if (~resetn) begin

		//

	end else begin

		aramwe <= 4'h0;
		aramre <= 1'b0;
		gramwe <= 4'h0;
		gramre <= 1'b0;

		case (busmode)

			BUS_INIT: begin
				if (calib_done4) begin
					busmode <= BUS_IDLE;
				end
			end

			BUS_IDLE: begin

				// End pending UART/SPI/AUDIO/GPU FIFO writes
				uartsendwe <= 1'b0;
				spiwwe <= 1'b0;
				abwe <= 1'b0;
				gfifowe <= 1'b0;

				if (deviceSelect[DEV_DDR3] & (busre | (|buswe))) begin
					currentcacheline <= cache[busaddress[12:5]];
					oldtag <= cachetags[busaddress[12:5]];
					cline <= busaddress[12:5];
					ctag <= busaddress[27:13];
					coffset <= busaddress[4:2];
					cwidemask = {{8{buswe[3]}}, {8{buswe[2]}}, {8{buswe[1]}}, {8{buswe[0]}}};
				end else begin
					currentcacheline <= 256'd0;
					oldtag <= 16'd0;
					cline <= 8'd0;
					ctag <= 15'd0;
					coffset <= 3'd0;
					cwidemask <= 32'd0;
				end

				if (|buswe) begin
					case (1'b1)
						deviceSelect[DEV_DDR3]: begin
							ddr3wdat <= busdata;
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_ARAM]: begin
							aramaddr <= busaddress[15:2];
							aramwe <= buswe;
							aramdin <= busdata;
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_GRAM]: begin
							gramaddr <= busaddress[15:2];
							gramwe <= buswe;
							gramdin <= busdata;
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_UARTRW]: begin
							uartsenddin <= busdata[7:0];
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_SPIRW]: begin
							spiwdin <= busdata[7:0];
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_LEDRW]: begin
							leddata <= busdata[15:0];
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_AUDIOSTREAMOUT]: begin
							abdin <= busdata;
							busmode <= BUS_WRITE;
						end
						deviceSelect[DEV_GPUFIFO]: begin
							gfifodin <= busdata;
							busmode <= BUS_WRITE;
						end
					endcase
				end

				if (busre) begin
					case (1'b1)
						deviceSelect[DEV_DDR3]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_ARAM]: begin
							aramaddr <= busaddress[15:2];
							aramre <= busre;
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_GRAM]: begin
							gramaddr <= busaddress[15:2];
							gramre <= busre;
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_UARTRW]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_SPIRW]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_SWITCHES]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_UARTCOUNT]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_SWITCHCOUNT]: begin
							busmode <= BUS_READ;
						end
						deviceSelect[DEV_LEDRW]: begin
							busmode <= BUS_READ;
						end
					endcase
				end
			end

			BUS_READ: begin
				busmode <= BUS_IDLE; // Unknown/default device read, back to idle (keep existing data out)
				case(1'b1)
					deviceSelect[DEV_DDR3]: begin
						if (oldtag[14:0] == ctag) begin
							case (coffset)
								3'b000: dataout <= currentcacheline[31:0];
								3'b001: dataout <= currentcacheline[63:32];
								3'b010: dataout <= currentcacheline[95:64];
								3'b011: dataout <= currentcacheline[127:96];
								3'b100: dataout <= currentcacheline[159:128];
								3'b101: dataout <= currentcacheline[191:160];
								3'b110: dataout <= currentcacheline[223:192];
								3'b111: dataout <= currentcacheline[255:224];
							endcase
							busmode <= BUS_IDLE;
						end else begin
							ddr3rw <= 1'b0;
							// Do we need to flush then populate?
							if (oldtag[15]) begin
								// Write back old cache line contents to old address
								ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b0, currentcacheline[127:0]};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHESTOREHI;
							end else begin
								// Load contents to new address, discarding current cache line (either evicted or discarded)
								ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHELOADHI;
							end
						end
					end
					deviceSelect[DEV_ARAM]: begin
						busmode <= BUS_ARAMRETIRE;
					end
					deviceSelect[DEV_GRAM]: begin
						busmode <= BUS_GRAMRETIRE;
					end
					deviceSelect[DEV_UARTRW]: begin
						if(~uartrcvempty) begin
							uartrcvre <= 1'b1;
							busmode <= BUS_UARTRETIRE;
						end else begin
							// Block when no data available
							// NOTE: If UART hasn't received data, there's nothing to read
							busmode <= BUS_READ;
						end
					end
					deviceSelect[DEV_SPIRW]: begin
						if(~spirempty) begin
							spirre <= 1'b1;
							busmode <= BUS_SPIRETIRE;
						end else begin
							// Block when no data available
							// NOTE: SPI can't read without sending a data stream first
							busmode <= BUS_READ;
						end
					end
					deviceSelect[DEV_SWITCHES]: begin
						if(~switchempty) begin
							switchre <= 1'b1;
							busmode <= BUS_SWITCHRETIRE;
						end else begin
							dataout <= {23'd0, newswitchstate};
							busmode <= BUS_IDLE;
						end
					end
					deviceSelect[DEV_UARTCOUNT]: begin
						// Suffices to pass out zero or one, actual count doesn't matter
						dataout <= {31'd0, ~uartrcvempty};
						busmode <= BUS_IDLE;
					end
					deviceSelect[DEV_SWITCHCOUNT]: begin
						dataout <= {31'd0, ~switchempty};
						busmode <= BUS_IDLE;
					end
					deviceSelect[DEV_LEDRW]: begin
						dataout <= {16'd0, leds};
						busmode <= BUS_IDLE;
					end
				endcase
			end

			BUS_WRITE: begin
				busmode <= BUS_IDLE; // Unknown/default device write, back to idle
				case(1'b1)
					deviceSelect[DEV_DDR3]: begin
						if (oldtag[14:0] == ctag) begin
							case (coffset)
								3'b000: cache[cline][31:0] <= ((~cwidemask)&currentcacheline[31:0]) | (cwidemask&ddr3wdat);
								3'b001: cache[cline][63:32] <= ((~cwidemask)&currentcacheline[63:32]) | (cwidemask&ddr3wdat);
								3'b010: cache[cline][95:64] <= ((~cwidemask)&currentcacheline[95:64]) | (cwidemask&ddr3wdat);
								3'b011: cache[cline][127:96] <= ((~cwidemask)&currentcacheline[127:96]) | (cwidemask&ddr3wdat);
								3'b100: cache[cline][159:128] <= ((~cwidemask)&currentcacheline[159:128]) | (cwidemask&ddr3wdat);
								3'b101: cache[cline][191:160] <= ((~cwidemask)&currentcacheline[191:160]) | (cwidemask&ddr3wdat);
								3'b110: cache[cline][223:192] <= ((~cwidemask)&currentcacheline[223:192]) | (cwidemask&ddr3wdat);
								3'b111: cache[cline][255:224] <= ((~cwidemask)&currentcacheline[255:224]) | (cwidemask&ddr3wdat);
							endcase
							// This cache line is now dirty
							cachetags[cline][15] <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							ddr3rw <= 1'b1;
							// Do we need to flush then populate?
							if (oldtag[15]) begin
								// Write back old cache line contents to old address
								ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b0, currentcacheline[127:0]};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHESTOREHI;
							end else begin
								// Load contents to new address, discarding current cache line (either evicted or discarded)
								ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0};
								ddr3cmdwe <= 1'b1;
								busmode <= BUS_DDR3CACHELOADHI;
							end
						end
					end
					deviceSelect[DEV_UARTRW]: begin
						if (~uartsendfull) begin
							uartsendwe <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							busmode <= BUS_WRITE; // Stall until UART fifo's empty
						end
					end
					deviceSelect[DEV_SPIRW]: begin
						if (~spiwfull) begin
							spiwwe <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							busmode <= BUS_WRITE; // Stall until SPI fifo's empty
						end
					end
					deviceSelect[DEV_LEDRW]: begin
						leds <= leddata;
						busmode <= BUS_IDLE;
					end
					deviceSelect[DEV_AUDIOSTREAMOUT]: begin
						if (~abfull) begin
							abwe <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							busmode <= BUS_WRITE; // Stall until audio fifo's empty
						end
					end
					deviceSelect[DEV_GPUFIFO]: begin
						if (~gpu_fifowrfull) begin
							gfifowe <= 1'b1;
							busmode <= BUS_IDLE;
						end else begin
							busmode <= BUS_WRITE; // Stall until audio fifo's empty
						end
					end
				endcase
			end

			BUS_UARTRETIRE: begin
				uartrcvre <= 1'b0;
				if (uartrcvvalid) begin
					// NOTE: Replicate byte to all parts since the address
					// we map this device might be byte aligned in the future
					dataout <= {uartrcvdout, uartrcvdout, uartrcvdout, uartrcvdout};
					busmode <= BUS_IDLE;
				end else begin
					// Stay in this mode until input byte is ready
					// This should not be a problem ordinarily
					// since we only kick retire if fifo wasn't empty
					busmode <= BUS_UARTRETIRE;
				end
			end

			BUS_SPIRETIRE: begin
				spirre <= 1'b0;
				if (spirvalid) begin
					dataout <= {spirdout, spirdout, spirdout, spirdout};
					busmode <= BUS_IDLE;
				end else begin
					busmode <= BUS_SPIRETIRE;
				end
			end

			BUS_SWITCHRETIRE: begin
				switchre <= 1'b0;
				if (switchvalid) begin
					dataout <= {23'd0, switchdataout};
					busmode <= BUS_IDLE;
				end else begin
					busmode <= BUS_SWITCHRETIRE;
				end
			end

			BUS_ARAMRETIRE: begin
				dataout <= aramdout;
				busmode <= BUS_IDLE;
			end

			BUS_GRAMRETIRE: begin
				dataout <= gramdout;
				busmode <= BUS_IDLE;
			end

			BUS_DDR3CACHESTOREHI: begin
				ddr3cmdin <= {1'b1, oldtag[14:0], cline, 1'b1, currentcacheline[255:128]}; // STOREHI
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADLO;
			end

			BUS_DDR3CACHELOADLO: begin
				ddr3cmdin <= {1'b0, ctag, cline, 1'b0, 128'd0}; // LOADLO
				ddr3cmdwe <= 1'b1;
				busmode <= BUS_DDR3CACHELOADHI;
			end

			BUS_DDR3CACHELOADHI: begin
				ddr3cmdin <= {1'b0, ctag, cline, 1'b1, 128'd0}; // LOADHI
				ddr3cmdwe <= 1'b1;
				loadindex <= 1'b0;
				busmode <= BUS_DDR3CACHEWAIT;
			end

			BUS_DDR3CACHEWAIT: begin
				ddr3cmdwe <= 1'b0;
				if (~ddr3readempty) begin
					// Read result available for this cache line
					// Request to read it
					ddr3readre <= 1'b1;
					busmode <= BUS_DDR3UPDATECACHELINE;
				end else begin
					busmode <= BUS_DDR3CACHEWAIT;
				end
			end

			BUS_DDR3UPDATECACHELINE: begin
				// Stop result read request
				ddr3readre <= 1'b0;
				// New cache line read and ready
				if (ddr3readvalid) begin
					case (loadindex)
						1'b0: begin
							currentcacheline[127:0] <= ddr3readout;
							loadindex <= 1'b1;
							// Read one more
							busmode <= BUS_DDR3CACHEWAIT;
						end
						1'b1: begin
							currentcacheline[255:128] <= ddr3readout;
							busmode <= BUS_UPDATEFINALIZE;
						end
					endcase
				end else begin
					busmode <= BUS_DDR3UPDATECACHELINE;
				end
			end

			BUS_UPDATEFINALIZE: begin
				cache[cline] <= currentcacheline;
				cachetags[cline] <= {1'b0, ctag};
				oldtag <= {1'b0, ctag};
				if (ddr3rw == 1'b0) begin
					busmode <= BUS_READ; // Back to read
				end else begin
					busmode <= BUS_WRITE; // Back to write
				end
			end

		endcase
	end
end

endmodule
