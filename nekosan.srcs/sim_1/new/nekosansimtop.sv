`timescale 1ns / 1ps

module nekosansimtop( );

logic clk;

// Startup
initial begin
	uart_txd_in = 1'bz;
	clk = 1'b0;
	$display("NekoSan started up");
	#20 uart_txd_in = 1'b0;
end

wire uart_rxd_out;
logic uart_txd_in;

wire ddr3_reset_n;
wire [0:0]   ddr3_cke;
wire [0:0]   ddr3_ck_p; 
wire [0:0]   ddr3_ck_n;
wire [0:0]   ddr3_cs_n;
wire ddr3_ras_n; 
wire ddr3_cas_n;
wire ddr3_we_n;
wire [2:0]   ddr3_ba;
wire [13:0]  ddr3_addr;
wire [0:0]   ddr3_odt;
wire [1:0]   ddr3_dm;
wire [1:0]   ddr3_dqs_p;
wire [1:0]   ddr3_dqs_n;
wire [1:0]   tdqs_n;
wire [15:0]  ddr3_dq;

wire [3:0] DVI_R, DVI_G, DVI_B;
wire DVI_HS, DVI_VS, DVI_DE, DVI_CLK;

wire spi_cs_n, spi_mosi, spi_sck;
logic spi_miso = 1'b1;
wire spi_cd = 1'b1; // High when no card inserted

ddr3_model ddr3simmod(
    .rst_n(ddr3_reset_n),
    .ck(ddr3_ck_p),
    .ck_n(ddr3_ck_n),
    .cke(ddr3_cke),
    .cs_n(ddr3_cs_n),
    .ras_n(ddr3_ras_n),
    .cas_n(ddr3_cas_n),
    .we_n(ddr3_we_n),
    .dm_tdqs(ddr3_dm),
    .ba(ddr3_ba),
    .addr(ddr3_addr),
    .dq(ddr3_dq),
    .dqs(ddr3_dqs_p),
    .dqs_n(ddr3_dqs_n),
    .tdqs_n(tdqs_n), // out - unused, looks like it's always set to Z
    .odt(ddr3_odt) );

// Top module simulation instance
nekosantop simtop(
	.sys_clock(clk)
	// UART
	,.uart_rxd_out(uart_rxd_out)
	,.uart_txd_in(uart_txd_in)
	// DVI on PMOD ports A+B
	,.DVI_R(DVI_R)
	,.DVI_G(DVI_G)
	,.DVI_B(DVI_B)
	,.DVI_HS(DVI_HS)
	,.DVI_VS(DVI_VS)
	,.DVI_DE(DVI_DE)
	,.DVI_CLK(DVI_CLK)
    // DDR3 SDRAM
    ,.ddr3_reset_n(ddr3_reset_n)
    ,.ddr3_cke(ddr3_cke)
    ,.ddr3_ck_p(ddr3_ck_p)
    ,.ddr3_ck_n(ddr3_ck_n)
    ,.ddr3_cs_n(ddr3_cs_n)
    ,.ddr3_ras_n(ddr3_ras_n) 
    ,.ddr3_cas_n(ddr3_cas_n) 
    ,.ddr3_we_n(ddr3_we_n)
    ,.ddr3_ba(ddr3_ba)
    ,.ddr3_addr(ddr3_addr)
    ,.ddr3_odt(ddr3_odt)
    ,.ddr3_dm(ddr3_dm)
    ,.ddr3_dqs_p(ddr3_dqs_p)
    ,.ddr3_dqs_n(ddr3_dqs_n)
    ,.ddr3_dq(ddr3_dq)
    // SPI
	// SD Card PMOD on port C
	,.spi_cs_n(spi_cs_n)
	,.spi_mosi(spi_mosi)
	,.spi_miso(spi_miso)
	,.spi_sck(spi_sck)
	//,.spi_cd(spi_cd)
	// LEDs
	,.led0_b() ,.led0_g() ,.led0_r()
	,.led1_b() ,.led1_g() ,.led1_r()
	,.led2_b() ,.led2_g() ,.led2_r()
	,.led3_b() ,.led3_g() ,.led3_r()
	,.leds()
	// I2S2 audio
    ,.tx_mclk()
    ,.tx_lrck()
    ,.tx_sclk()
    ,.tx_sdout() );

// Feed a 100Mhz external clock to top module
always begin
	#5 clk = ~clk;
end

always begin
	#25 uart_txd_in = ~uart_txd_in;
end

endmodule
