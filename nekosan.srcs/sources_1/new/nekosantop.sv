`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// NekoSan
// (c) 2021 Engin Cilasun
// ----------------------------------------------------------------------------

module nekosantop(
	// Input clock @100MHz
	input sys_clock,
	// UART device pins
	output wire uart_rxd_out,
	input wire uart_txd_in,
    // DDR3 SDRAM device pins
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
    inout   [15:0]  ddr3_dq );

// ----------------------------------------------------------------------------
// Clock and reset logic
// ----------------------------------------------------------------------------

wire devicereset;
wire clk25, clk100, clk120, clk150;

sysclockandreset SystemClockAndResetGen(
	.sys_clock(sys_clock),
	.clk25(clk25),
	.clk100(clk100),
	.clk150(clk150),
	.clk120(clk120),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.devicereset(devicereset));

wire deviceresetn = ~devicereset;

// ----------------------------------------------------------------------------
// System bus
// ----------------------------------------------------------------------------

wire busbusy;
wire [31:0] busaddress;
wire [31:0] busdata;
wire [3:0] buswe;
wire busre;
wire cachemode;
wire [1:0] IRQ_BITS;

sysbus SystemBus(
	.clock(clk100),
	.clk25(clk25),
	.resetn(deviceresetn),
	// Bus / cache control
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre),
	.cachemode(cachemode),
	// Interrupts
	.IRQ_BITS(IRQ_BITS),
	// UART
	.uart_rxd_out(uart_rxd_out),
	.uart_txd_in(uart_txd_in),
	// DDR3
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
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
    .ddr3_dq(ddr3_dq) );

// ----------------------------------------------------------------------------
// CPU
// ----------------------------------------------------------------------------

rvcpu CPU0(
	.clock(clk100),
	.wallclock(clk25),
	.resetn(deviceresetn),
	// Bus / cache control
	.busbusy(busbusy),
	.busaddress(busaddress),
	.busdata(busdata),
	.buswe(buswe),
	.busre(busre),
	.cachemode(cachemode),
	// Interrupts
	.IRQ((|IRQ_BITS)),
	.IRQ_TYPE(IRQ_BITS) );

endmodule