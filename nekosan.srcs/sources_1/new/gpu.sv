`timescale 1ns / 1ps

`include "cpuops.vh"
`include "gpuops.vh"


// ==============================================================
// GPU register file
// ==============================================================

module gpuregisterfile(
	input wire reset,
	input wire clock,
	input wire [3:0] rs,
	input wire [3:0] rd,
	input wire wren, 
	input wire [31:0] datain,
	output wire [31:0] rval,
	output wire [31:0] rdval );

// Register file: G0..G15
logic [31:0] registers[0:15];

initial begin
	int i;
	for (int i=0;i<16;i=i+1)
		registers[i] <= 32'h00000000;
end

always @(posedge clock) begin
	if (wren)
		registers[rd] <= datain;
end

assign rval = registers[rs];
assign rdval = registers[rd];

endmodule

// ==============================================================
// GPU main
// ==============================================================

module gpu (
	input wire clock,
	input wire reset,
	// Control lines
	input wire [31:0] vsync,
	output logic videopage = 1'b0,
	// GPU FIFO
	input wire fifoempty,
	input wire [31:0] fifodout,
	input wire fifdoutvalid,
	output logic fiford_en = 1'b0,
	// VRAM
	output logic [14:0] vramaddress,
	output logic [31:0] vramwriteword,
	output logic [3:0] vramwe = 4'b0000,
	//output logic [12:0] lanemask = 70'd0, // We need to pick tiles for simultaneous writes
	// GRAM DMA channel
	output logic [31:0] dmaaddress,
	output logic [31:0] dmawriteword,
	output logic [3:0] dmawe = 4'b0000,
	input wire [31:0] dma_data,
	// Palette write
	output logic palettewe = 1'b0,
	output logic [7:0] paletteaddress,
	output logic [23:0] palettedata );

logic [`GPUSTATEBITS-1:0] gpustate = `GPUSTATEIDLE_MASK;

logic [31:0] rdatain;
wire [31:0] rval, rdval;
logic rwren = 1'b0;
logic [3:0] rs;
logic [3:0] rd;
logic [2:0] cmd;
logic modifier;
logic [14:0] dmacount;
logic [19:0] imm20;
logic [23:0] imm24;
gpuregisterfile gpuregs(
	.reset(reset),
	.clock(clock),
	.rs(rs),
	.rd(rd),
	.wren(rwren),
	.datain(rdatain),
	.rval(rval),
	.rdval(rdval));

// ==============================================================
// Main state machine
// ==============================================================

//logic [31:0] vsyncrequestpoint = 32'd0;

always_ff @(posedge clock) begin
	if (reset) begin

		gpustate <= `GPUSTATEIDLE_MASK;

	end else begin
	
		gpustate <= `GPUSTATENONE_MASK;
	
		unique case (1'b1)
		
			gpustate[`GPUSTATEIDLE]: begin
				// Stop writes to memory, registers and palette
				vramwe <= 4'b0000;
				rwren <= 1'b0;
				dmawe <= 4'b0000;
				palettewe <= 1'b0;
				//lanemask <= 13'd0;

				// See if there's something on the fifo
				if (~fifoempty) begin
					fiford_en <= 1'b1;
					gpustate[`GPUSTATELATCHCOMMAND] <= 1'b1;
				end else begin
					gpustate[`GPUSTATEIDLE] <= 1'b1;
				end
			end

			gpustate[`GPUSTATELATCHCOMMAND]: begin
				// Turn off fifo read request on the next clock
				fiford_en <= 1'b0;
				if (fifdoutvalid) begin
					// Data is available, latch and jump to execute
					cmd <= fifodout[2:0];		// command code
					modifier <= fifodout[3];	// modifier bit
					rd <= fifodout[7:4];		// destination register
					rs <= fifodout[11:8];		// source register
					imm20 <= fifodout[31:12];	// 20 bit immediate
					imm24 <= fifodout[31:8];	// 24 bit immediate
					//vsyncrequestpoint <= vsync;
					gpustate[`GPUSTATEEXEC] <= 1'b1;
				end else begin
					// Data is not available yet, spin
					gpustate[`GPUSTATELATCHCOMMAND] <= 1'b1;
				end
			end
			
			// Command execute statepaletteaddress
			gpustate[`GPUSTATEEXEC]: begin
				unique case (cmd)
					`GPUCMD_UNUSED0: begin
						// IIII IIII IIII IIII IIII SSSS DDDD MCCC
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
					`GPUCMD_SETREG: begin
						rwren <= 1'b1;
						// Set high 24 bits
						if (modifier==1'b1) begin
							// IIII IIII IIII IIII IIII IIII DDDD 1CCC
							rdatain <= {imm24, rdval[7:0]};
						end else begin // Set low 8 bits
							// ---- ---- ---- ---- IIII IIII DDDD 0CCC
							rdatain <= {rdval[31:8], imm24[7:0]};
						end
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
					`GPUCMD_SETPALENT: begin
						// ---- ---- ---- ---- IIII IIII DDDD MCCC
						paletteaddress <= rdval;
						palettedata <= rval[23:0];
						palettewe <= 1'b1;
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
					`GPUCMD_UNUSED3: begin
						// IIII IIII IIII IIII IIII SSSS DDDD MCCC
						gpustate[`GPUSTATECLEAR] <= 1'b1;
					end
					`GPUCMD_SYSDMA: begin
						// IIII IIII IIII IIII IIII SSSS DDDD MCCC
						dmaaddress <= rval; // rs: source
						dmacount <= 15'd0;
						dmawe <= 4'b0000; // Reading from SYSRAM
						gpustate[`GPUSTATEDMAKICK] <= 1'b1;
					end
					`GPUCMD_VMEMOUT: begin
						// ---- ---- ---- ---- WWWW SSSS DDDD MCCC
						vramaddress <= rdval[14:0];	// value of RD before write
						vramwriteword <= rval;		// value of RS
						vramwe <= imm20[3:0];		// write mask
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
					`GPUCMD_GMEMOUT: begin
						// ---- ---- ---- ---- WWWW SSSS DDDD MCCC
						dmaaddress <= rdval;	// value of RD before write
						dmawriteword <= rval;	// value of RS
						dmawe <= imm20[3:0];	// write mask
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
					`GPUCMD_SETVPAGE: begin
						videopage <= rval;
						gpustate[`GPUSTATEIDLE] <= 1'b1;
					end
				endcase
			end

			gpustate[`GPUSTATEDMAKICK]: begin
				// Delay for first read
				dmaaddress <= dmaaddress + 32'd4;
				gpustate[`GPUSTATEDMA] <= 1'b1;
			end

			gpustate[`GPUSTATEDMA]: begin // SYSDMA
				if (dmacount == imm20[14:0]) begin // lower 15 bits: DMA count
					// DMA done
					vramwe <= 4'b0000;
					gpustate[`GPUSTATEIDLE] <= 1'b1;
				end else begin
					// Write the previous DWORD to absolute address
					vramaddress <= rdval[14:0] + dmacount;
					vramwriteword <= dma_data;
					
					if (imm20[15]==1'b1) begin // 16th bit : mask flag
						// Zero-masked DMA
						vramwe <= {|dma_data[31:24], |dma_data[23:16], |dma_data[15:8], |dma_data[7:0]};
					end else begin
						// Unmasked DM
						vramwe <= 4'b1111;
					end

					// Step to next DWORD to read
					dmaaddress <= dmaaddress + 32'd4;
					dmacount <= dmacount + 15'd1;
					gpustate[`GPUSTATEDMA] <= 1'b1;
				end
			end

		endcase
	end
end
	
endmodule
