`timescale 1ns / 1ps

module sysclockandreset(
	input wire sys_clock,
	output wire clk25,
	output wire gpuclock,
	output wire clk100,
	output wire clk50,
	output wire cpuclock,
	output wire audiocore,
	output wire sys_clk_in,
	output wire ddr3_ref,
	output logic devicereset = 1'b1 );

wire clkAlocked, clkBlocked, ddr3clklocked;

coreclock CentralClockGen(
	.clk_in1(sys_clock),
	.clk25(clk25),
	.gpuclock(gpuclock),
	.clk100(clk100),
	.clk50(clk50),
	.cpuclock(cpuclock),
	.locked(clkAlocked) );

avclock AudioVideoClockGen(
	.clk_in1(sys_clock),
	.audiocore(audiocore),
	.locked(clkBlocked) );

ddr3clock DDR3MemClockGen(
	.clk_in1(sys_clock),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.locked(ddr3clklocked));

// Hold reset until clocks are locked
wire internalreset = ~(clkAlocked & clkBlocked & ddr3clklocked);

// Delayed reset post-clock-lock
logic [7:0] resetcountdown = 8'hFF;
always @(posedge clk25) begin // Using slowest clock
	if (internalreset) begin
		resetcountdown <= 8'hFF;
		devicereset <= 1'b1;
	end else begin
		if (/*busready &&*/ (resetcountdown == 8'h00))
			devicereset <= 1'b0;
		else
			resetcountdown <= resetcountdown - 8'h01;
	end
end

endmodule
