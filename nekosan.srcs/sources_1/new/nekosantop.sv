`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// NekoSan
// (c) 2021 Engin Cilasun
// ----------------------------------------------------------------------------

module nekosantop(
	// Input clock @100MHz
	input sys_clock,
	// UART device pins - ONBOARD
	output wire uart_rxd_out,
	input wire uart_txd_in,
    // DDR3 SDRAM device - ONBOARD
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
    // SPI - SDCard - PMOD C
	output spi_cs_n,
	output spi_mosi,
	input spi_miso,
	output spi_sck,
	//input spi_cd,
	// Switches/buttons - ONBOARD
	input [3:0] switches,
	input [3:0] buttons,
	// LEDs - ONBOARD
	output led0_b, output led0_g, output led0_r,
	output led1_b, output led1_g, output led1_r,
	output led2_b, output led2_g, output led2_r,
	output led3_b, output led3_g, output led3_r,
	output [3:0] leds,
	// I2S2 audio - PMOD D
    output tx_mclk,
    output tx_lrck,
    output tx_sclk,
    output tx_sdout,
	// DVI - PMOD A+B
	output  [3:0]	DVI_R,
	output  [3:0]	DVI_G,
	output  [3:0]	DVI_B,
	output			DVI_HS,
	output			DVI_VS,
	output			DVI_DE,
	output			DVI_CLK );

// ----------------------------------------------------------------------------
// Clock and reset logic
// ----------------------------------------------------------------------------

wire devicereset;
wire clk25, gpuclock, clk100, clk50;
wire sys_clk_in, clk200, cpuclock, audiocore;

sysclockandreset SystemClockAndResetGen(
	.sys_clock(sys_clock),
	.clk25(clk25),
	.gpuclock(gpuclock),
	.clk100(clk100),
	.clk50(clk50),
	.cpuclock(cpuclock),
	.audiocore(audiocore),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(clk200),
	.devicereset(devicereset));

wire resetn = ~devicereset;

// ----------------------------------------------------------------------------
// System bus
// ----------------------------------------------------------------------------

wire busbusy;
wire [31:0] busaddress;
wire [31:0] busdata;
wire [3:0] buswe;
wire busre;
wire [2:0] IRQ_BITS;

wire businitialized;

sysbus SystemBus(
	.clock(cpuclock),
	.audiocore(audiocore),
	.clk25(clk25),
	.clk50(clk50),
	.clk100(clk100),
	.gpuclock(gpuclock),
	.resetn(resetn),
	.businitialized(businitialized),
	// Bus / cache control
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre),
	// Interrupts
	.IRQ_BITS(IRQ_BITS),
	// UART
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in),
	// DDR3
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(clk200),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_cke(ddr3_cke),
    .ddr3_ck_p(ddr3_ck_p), 
    .ddr3_ck_n(ddr3_ck_n),
    .ddr3_cs_n(ddr3_cs_n),
    .ddr3_ras_n(ddr3_ras_n), 
    .ddr3_cas_n(ddr3_cas_n), 
    .ddr3_we_n(ddr3_we_n),
    .ddr3_ba(ddr3_ba),
    .ddr3_addr(ddr3_addr),
    .ddr3_odt(ddr3_odt),
    .ddr3_dm(ddr3_dm),
    .ddr3_dqs_p(ddr3_dqs_p),
    .ddr3_dqs_n(ddr3_dqs_n),
    .ddr3_dq(ddr3_dq),
    // SPI
	.spi_cs_n(spi_cs_n),
	.spi_mosi(spi_mosi),
	.spi_miso(spi_miso),
	.spi_sck(spi_sck),
	// Switches/buttons
	.switches(switches),
	.buttons(buttons),
	// LEDs
	.leds({led0_b, led0_g, led0_r, led1_b, led1_g, led1_r, led2_b, led2_g, led2_r, led3_b, led3_g, led3_r, leds}),
	// Audio
    .tx_mclk(tx_mclk),
    .tx_lrck(tx_lrck),
    .tx_sclk(tx_sclk),
    .tx_sdout(tx_sdout),
    // DVI
	.DVI_R(DVI_R),
	.DVI_G(DVI_G),
	.DVI_B(DVI_B),
	.DVI_HS(DVI_HS),
	.DVI_VS(DVI_VS),
	.DVI_DE(DVI_DE),
	.DVI_CLK(DVI_CLK) );

// ----------------------------------------------------------------------------
// TODO: Bus arbiter
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// CPU #0
// ----------------------------------------------------------------------------

rvcpu CPU0(
	.clock(cpuclock),
	.wallclock(clk25),
	.resetn(resetn),
	.businitialized(businitialized),
	// Bus / cache control
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre),
	// Interrupts
	.IRQ((|IRQ_BITS)),
	.IRQ_BITS(IRQ_BITS) );

endmodule
