`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/08/2021 05:58:02 AM
// Design Name: 
// Module Name: sysclockandreset
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module sysclockandreset(
	input wire sys_clock,
	output wire clk25,
	output wire clk100,
	output wire clk120,
	output wire clk150,
	output wire sys_clk_in,
	output wire ddr3_ref,
	output logic devicereset = 1'b1 );

wire clklocked, ddr3clklocked;

coreclock CentralClockGen(
	.clk_in1(sys_clock),
	.clk25(clk25),
	.clk100(clk100),
	.clk120(clk120),
	.clk150(clk150),
	.locked(clklocked) );

ddr3clock DDR3MemClockGen(
	.clk_in1(sys_clock),
	.sys_clk_in(sys_clk_in),
	.ddr3_ref(ddr3_ref),
	.locked(ddr3clklocked));

// Hold reset until clocks are locked
wire internalreset = ~(clklocked & ddr3clklocked);

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
