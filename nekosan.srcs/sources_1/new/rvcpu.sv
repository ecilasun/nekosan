`timescale 1ns / 1ps

`include "cpuops.vh"

module rvcpu(
	input wire clock,
	input wire wallclock,
	input wire resetn,
	input wire businitialized,
	input wire busbusy,
	output logic [31:0] busaddress = 32'd0,
	inout wire [31:0] busdata,
	output logic [3:0] buswe = 4'h0,
	output logic busre = 1'b0,
	input wire IRQ,
	input wire [2:0] IRQ_BITS);

// -----------------------------------------------------------------------
// Bus logic
// -----------------------------------------------------------------------

logic [31:0] dataout = 32'd0;
assign busdata = (|buswe) ? dataout : 32'dz;

// -----------------------------------------------------------------------
// Internal wires/constants
// -----------------------------------------------------------------------

localparam CPU_IDLE			= 0;
localparam CPU_DECODE		= 1;
localparam CPU_FETCH		= 2;
localparam CPU_EXEC			= 3;
localparam CPU_RETIRE		= 4;
localparam CPU_LOADSTALL	= 5;
localparam CPU_LOAD			= 6;
localparam CPU_UPDATECSR	= 7;
localparam CPU_MSTALL		= 8;
localparam CPU_FSTALL		= 9;
localparam CPU_FMSTALL		= 10;

logic [31:0] PC;
logic [31:0] nextPC;
logic ebreak;
logic illegalinstruction;
logic [10:0] cpustate;
logic [31:0] instruction;

initial begin
	PC = `CPU_RESET_VECTOR;
	nextPC = `CPU_RESET_VECTOR;
	ebreak = 1'b0;
	illegalinstruction = 1'b0;
	cpustate = 11'd0;
	cpustate[CPU_IDLE] = 1'b1; // IDLE state by default to wait for the bus initialization
	instruction = {25'd0, `ADDI}; // NOOP by default (addi x0,x0,0)
end

wire [4:0] opcode;
wire [3:0] aluop;
wire [3:0] bluop;
//wire rwen;
//wire fwen;
wire [2:0] func3;
wire [6:0] func7;
wire [11:0] func12;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] rs3;
wire [4:0] rd;
wire [11:0] csrindex;
wire [31:0] immed;
wire selectimmedasrval2;

// -----------------------------------------------------------------------
// Wide instruction decoder
// -----------------------------------------------------------------------

decoder InstructionDecoder(
	.instruction(instruction),
	.opcode(opcode),
	.aluop(aluop),
	.bluop(bluop),
	//.rwen(rwen),
	//.fwen(fwen),
	.func3(func3),
	.func7(func7),
	.func12(func12),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3),
	.rd(rd),
	.csrindex(csrindex),
	.immed(immed),
	.selectimmedasrval2(selectimmedasrval2) );

// -----------------------------------------------------------------------
// Integer register file
// -----------------------------------------------------------------------

logic regwena = 1'b0;
logic [31:0] regdata = 32'd0;
wire [31:0] rval1, rval2;

registerfile rv32iregisters(
	.clock(clock),
	.rs1(rs1),
	.rs2(rs2),
	.rd(rd),
	.wren(regwena), 
	.datain(regdata),
	.rval1(rval1),
	.rval2(rval2) );
	
// -----------------------------------------------------------------------
// Floating point register file
// -----------------------------------------------------------------------

logic fregwena = 1'b0;
logic [31:0] fregdata = 32'd0;
wire [31:0] frval1, frval2, frval3;

floatregisterfile myfloatregs(
	.clock(clock),
	.rs1(rs1),
	.rs2(rs2),
	.rs3(rs3),
	.rd(rd),
	.wren(fregwena),
	.datain(fregdata),
	.rval1(frval1),
	.rval2(frval2),
	.rval3(frval3) );

// -----------------------------------------------------------------------
// Integer/Branch ALUs
// -----------------------------------------------------------------------

wire [31:0] aluout;
IALU IntegerALU(
	.aluout(aluout),
	.func3(func3),
	.val1(rval1),
	.val2(selectimmedasrval2 ? immed : rval2),
	.aluop(aluop) );

wire branchout;
BALU BranchALU(
	.clock(clock),
	.branchout(branchout),
	.val1(rval1),
	.val2(rval2),
	.bluop(bluop) );

// -----------------------------------------------------------------------
// Mul/div/rem units
// -----------------------------------------------------------------------

wire mulbusy, divbusy, divbusyu;
wire [31:0] product;
wire [31:0] quotient;
wire [31:0] quotientu;
wire [31:0] remainder;
wire [31:0] remainderu;

wire isexecuting = (cpustate[CPU_EXEC]==1'b1) ? 1'b1 : 1'b0;
wire mulstart = isexecuting & (aluop==`ALU_MUL) & (opcode == `OPCODE_OP);
wire divstart = isexecuting & (aluop==`ALU_DIV | aluop==`ALU_REM) & (opcode == `OPCODE_OP);

logic [31:0] dividend = 32'd0;
logic [31:0] divisor = 32'd1;
logic [31:0] multiplicand = 32'd0;
logic [31:0] multiplier = 32'd0;

multiplier themul(
    .clk(clock),
    .reset(~resetn),
    .start(mulstart),
    .busy(mulbusy),           // calculation in progress
    .func3(func3),
    .multiplicand(multiplicand),
    .multiplier(multiplier),
    .product(product) );

DIVU unsigneddivider (
	.clk(clock),
	.reset(~resetn),
	.start(divstart),		// start signal
	.busy(divbusyu),		// calculation in progress
	.dividend(dividend),	// dividend
	.divisor(divisor),		// divisor
	.quotient(quotientu),	// result: quotient
	.remainder(remainderu)	// result: remainer
);

DIV signeddivider (
	.clk(clock),
	.reset(~resetn),
	.start(divstart),		// start signal
	.busy(divbusy),			// calculation in progress
	.dividend(dividend),		// dividend
	.divisor(divisor),		// divisor
	.quotient(quotient),	// result: quotient
	.remainder(remainder)	// result: remainder
);

// Start trigger
wire imathstart = divstart | mulstart;

// Stall status
wire imathbusy = divbusy | divbusyu | mulbusy;

// -----------------------------------------------------------------------
// Floating point math
// -----------------------------------------------------------------------

logic fmaddvalid = 1'b0;
logic fmsubvalid = 1'b0;
logic fnmsubvalid = 1'b0;
logic fnmaddvalid = 1'b0;
logic faddvalid = 1'b0;
logic fsubvalid = 1'b0;
logic fmulvalid = 1'b0;
logic fdivvalid = 1'b0;
logic fi2fvalid = 1'b0;
logic fui2fvalid = 1'b0;
logic ff2ivalid = 1'b0;
logic ff2uivalid = 1'b0;
logic fsqrtvalid = 1'b0;
logic feqvalid = 1'b0;
logic fltvalid = 1'b0;
logic flevalid = 1'b0;

wire fmaddresultvalid;
wire fmsubresultvalid;
wire fnmsubresultvalid; 
wire fnmaddresultvalid;

wire faddresultvalid;
wire fsubresultvalid;
wire fmulresultvalid;
wire fdivresultvalid;
wire fi2fresultvalid;
wire fui2fresultvalid;
wire ff2iresultvalid;
wire ff2uiresultvalid;
wire fsqrtresultvalid;
wire feqresultvalid;
wire fltresultvalid;
wire fleresultvalid;

wire [31:0] fmaddresult;
wire [31:0] fmsubresult;
wire [31:0] fnmsubresult;
wire [31:0] fnmaddresult;
wire [31:0] faddresult;
wire [31:0] fsubresult;
wire [31:0] fmulresult;
wire [31:0] fdivresult;
wire [31:0] fi2fresult;
wire [31:0] fui2fresult;
wire [31:0] ff2iresult;
wire [31:0] ff2uiresult;
wire [31:0] fsqrtresult;
wire [7:0] feqresult;
wire [7:0] fltresult;
wire [7:0] fleresult;

fp_madd floatfmadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmaddresult),
	.m_axis_result_tvalid(fmaddresultvalid) );

fp_msub floatfmsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmsubresult),
	.m_axis_result_tvalid(fmsubresultvalid) );

fp_madd floatfnmsub(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmsubvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmsubresult),
	.m_axis_result_tvalid(fnmsubresultvalid) );

fp_msub floatfnmadd(
	.s_axis_a_tdata({~frval1[31], frval1[30:0]}), // -A
	.s_axis_a_tvalid(fnmaddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fnmaddvalid),
	.s_axis_c_tdata(frval3),
	.s_axis_c_tvalid(fnmaddvalid),
	.aclk(clock),
	.m_axis_result_tdata(fnmaddresult),
	.m_axis_result_tvalid(fnmaddresultvalid) );

fp_add floatadd(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(faddvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(faddvalid),
	.aclk(clock),
	.m_axis_result_tdata(faddresult),
	.m_axis_result_tvalid(faddresultvalid) );
	
fp_sub floatsub(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fsubvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fsubvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsubresult),
	.m_axis_result_tvalid(fsubresultvalid) );


fp_mul floatmul(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fmulvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fmulvalid),
	.aclk(clock),
	.m_axis_result_tdata(fmulresult),
	.m_axis_result_tvalid(fmulresultvalid) );

fp_div floatdiv(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fdivvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fdivvalid),
	.aclk(clock),
	.m_axis_result_tdata(fdivresult),
	.m_axis_result_tvalid(fdivresultvalid) );

fp_i2f floati2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fi2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fi2fresult),
	.m_axis_result_tvalid(fi2fresultvalid) );

fp_ui2f floatui2f(
	.s_axis_a_tdata(rval1), // Integer source
	.s_axis_a_tvalid(fui2fvalid),
	.aclk(clock),
	.m_axis_result_tdata(fui2fresult),
	.m_axis_result_tvalid(fui2fresultvalid) );

fp_f2i floatf2i(
	.s_axis_a_tdata(frval1), // Float source
	.s_axis_a_tvalid(ff2ivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2iresult),
	.m_axis_result_tvalid(ff2iresultvalid) );

// NOTE: Sharing same logic with f2i here, ignoring sign bit instead
fp_f2i floatf2ui(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(ff2uivalid),
	.aclk(clock),
	.m_axis_result_tdata(ff2uiresult),
	.m_axis_result_tvalid(ff2uiresultvalid) );
	
fp_sqrt floatsqrt(
	.s_axis_a_tdata({1'b0,frval1[30:0]}), // abs(A) (float register is source)
	.s_axis_a_tvalid(fsqrtvalid),
	.aclk(clock),
	.m_axis_result_tdata(fsqrtresult),
	.m_axis_result_tvalid(fsqrtresultvalid) );

fp_eq floateq(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(feqvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(feqvalid),
	.aclk(clock),
	.m_axis_result_tdata(feqresult),
	.m_axis_result_tvalid(feqresultvalid) );

fp_lt floatlt(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(fltvalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(fltvalid),
	.aclk(clock),
	.m_axis_result_tdata(fltresult),
	.m_axis_result_tvalid(fltresultvalid) );

fp_le floatle(
	.s_axis_a_tdata(frval1),
	.s_axis_a_tvalid(flevalid),
	.s_axis_b_tdata(frval2),
	.s_axis_b_tvalid(flevalid),
	.aclk(clock),
	.m_axis_result_tdata(fleresult),
	.m_axis_result_tvalid(fleresultvalid) );

// -----------------------------------------------------------------------
// Cycle/Timer/Reti CSRs
// -----------------------------------------------------------------------

logic [4:0] CSRIndextoLinearIndex;
logic [31:0] CSRReg [0:24];

// See https://cv32e40p.readthedocs.io/en/latest/control_status_registers/#cs-registers for defaults
initial begin
	CSRReg[`CSR_UNUSED]		= 32'd0;
	CSRReg[`CSR_FFLAGS]		= 32'd0;
	CSRReg[`CSR_FRM]		= 32'd0;
	CSRReg[`CSR_FCSR]		= 32'd0;
	CSRReg[`CSR_MSTATUS]	= 32'h00001800; // MPP (machine previous priviledge mode 12:11) hardwired to 2'b11 on startup
	CSRReg[`CSR_MISA]		= {2'b01, 4'b0000, 26'b00000000000001000100100000};	// 301 MXL:1, 32 bits, Extensions: I M F;
	CSRReg[`CSR_MIE]		= 32'd0;
	CSRReg[`CSR_MTVEC]		= 32'd0;
	CSRReg[`CSR_MSCRATCH]	= 32'd0;
	CSRReg[`CSR_MEPC]		= 32'd0;
	CSRReg[`CSR_MCAUSE]		= 32'd0;
	CSRReg[`CSR_MTVAL]		= 32'd0;
	CSRReg[`CSR_MIP]		= 32'd0;
	CSRReg[`CSR_DCSR]		= 32'h40000003;
	CSRReg[`CSR_DPC]		= 32'd0;
	CSRReg[`CSR_TIMECMPLO]	= 32'hFFFFFFFF; // timecmp = 0xFFFFFFFFFFFFFFFF
	CSRReg[`CSR_TIMECMPHI]	= 32'hFFFFFFFF;
	CSRReg[`CSR_CYCLELO]	= 32'd0;
	CSRReg[`CSR_CYCLEHI]	= 32'd0;
	CSRReg[`CSR_TIMELO]		= 32'd0;
	CSRReg[`CSR_RETILO]		= 32'd0;
	CSRReg[`CSR_TIMEHI]		= 32'd0;
	CSRReg[`CSR_RETIHI]		= 32'd0;
	CSRReg[`CSR_HARTID]		= 32'd0;
	// TODO: mvendorid: 0x0000_0602
	// TODO: marchid: 0x0000_0004
end

always_comb begin
	case (csrindex)
		12'h001: CSRIndextoLinearIndex = `CSR_FFLAGS;
		12'h002: CSRIndextoLinearIndex = `CSR_FRM;
		12'h003: CSRIndextoLinearIndex = `CSR_FCSR;
		12'h300: CSRIndextoLinearIndex = `CSR_MSTATUS;
		12'h301: CSRIndextoLinearIndex = `CSR_MISA;
		12'h304: CSRIndextoLinearIndex = `CSR_MIE;
		12'h305: CSRIndextoLinearIndex = `CSR_MTVEC;
		12'h340: CSRIndextoLinearIndex = `CSR_MSCRATCH;
		12'h341: CSRIndextoLinearIndex = `CSR_MEPC;
		12'h342: CSRIndextoLinearIndex = `CSR_MCAUSE;
		12'h343: CSRIndextoLinearIndex = `CSR_MTVAL;
		12'h344: CSRIndextoLinearIndex = `CSR_MIP;
		12'h780: CSRIndextoLinearIndex = `CSR_DCSR;
		12'h781: CSRIndextoLinearIndex = `CSR_DPC;
		12'h800: CSRIndextoLinearIndex = `CSR_TIMECMPLO;
		12'h801: CSRIndextoLinearIndex = `CSR_TIMECMPHI;
		12'hB00: CSRIndextoLinearIndex = `CSR_CYCLELO;
		12'hB80: CSRIndextoLinearIndex = `CSR_CYCLEHI;
		12'hC01: CSRIndextoLinearIndex = `CSR_TIMELO;
		12'hC02: CSRIndextoLinearIndex = `CSR_RETILO;
		12'hC81: CSRIndextoLinearIndex = `CSR_TIMEHI;
		12'hC82: CSRIndextoLinearIndex = `CSR_RETIHI;
		12'hF14: CSRIndextoLinearIndex = `CSR_HARTID;
		default: CSRIndextoLinearIndex = `CSR_UNUSED;
	endcase
end

// Other custom CSRs r/w between 0x802-0x8FF

// Advancing cycles is simple since clocks = cycles
logic [63:0] internalcyclecounter = 64'd0;
always @(posedge clock) begin
	internalcyclecounter <= internalcyclecounter + 64'd1;
end

// Time is also simple since we know we have 25M ticks per second
// from which we can derive seconds elapsed
logic [63:0] internalwallclockcounter = 64'd0;
logic [63:0] internalwallclockcounter1 = 64'd0;
logic [63:0] internalwallclockcounter2 = 64'd0;
logic [63:0] internaltimecmp = 64'd0;
always @(posedge wallclock) begin
	internalwallclockcounter <= internalwallclockcounter + 64'd1;
end
// Small adjustment to bring wallclock counter closer to cpu clock domain
always @(posedge clock) begin
	internalwallclockcounter1 <= internalwallclockcounter;
	internalwallclockcounter2 <= internalwallclockcounter1;
end

// Retired instruction counter
logic [63:0] internalretirecounter = 64'd0;
always @(posedge clock) begin
	internalretirecounter <= internalretirecounter + {63'd0, cpustate[CPU_RETIRE]};
end

wire timerinterrupt = CSRReg[`CSR_MIE][7] & (internalwallclockcounter2 >= internaltimecmp);
wire externalinterrupt = (CSRReg[`CSR_MIE][11] & IRQ);

// -----------------------------------------------------------------------
// Core
// -----------------------------------------------------------------------

wire [31:0] immreach = rval1 + immed;
wire [31:0] immpc = PC + immed;
wire [31:0] pc4 = PC + 32'd4;
wire [31:0] branchpc = branchout ? immpc : pc4;

logic [31:0] intreg;

always @(posedge clock, negedge resetn) begin
	if (~resetn) begin
	
		// 

	end else begin

		cpustate <= 11'd0;

		busre <= 1'b0;
		buswe <= 1'b0;

		case (1'b1)
		
			cpustate[CPU_IDLE]: begin
				if (businitialized) begin
					// Bus is initialized, we can now
					// resume r/w from/to DDR3 and other devices
					cpustate[CPU_RETIRE] <= 1'b1;
				end else begin
					// Keep waiting for bus reset
					cpustate[CPU_IDLE] <= 1'b1;
				end
			end

			cpustate[CPU_FETCH]: begin
				if (busbusy) begin
					// Wait for bus to release data
					cpustate[CPU_FETCH] <= 1'b1;
				end else begin
					instruction <= busdata;
					cpustate[CPU_DECODE] <= 1'b1;
				end
			end

			cpustate[CPU_DECODE]: begin
				// Update CSRs with internal counters
				{CSRReg[`CSR_CYCLEHI], CSRReg[`CSR_CYCLELO]} <= internalcyclecounter;
				{CSRReg[`CSR_TIMEHI], CSRReg[`CSR_TIMELO]} <= internalwallclockcounter2;
				{CSRReg[`CSR_RETIHI], CSRReg[`CSR_RETILO]} <= internalretirecounter;

				// Set up math unit inputs
				dividend <= rval1;
				divisor <= rval2;
				multiplicand <= rval1;
				multiplier <= rval2;
				intreg <= immed;

				cpustate[CPU_EXEC] <= 1'b1;
			end

			cpustate[CPU_EXEC]: begin
				//csrde <= 1'b0;
				nextPC <= pc4;
				regwena <= 1'b0;
				fregwena <= 1'b0;
				regdata <= 32'd0;
				ebreak <= 1'b0;
				illegalinstruction <= 1'b0;

				unique case (opcode)
					`OPCODE_AUPC: begin
						regwena <= 1'b1;
						regdata <= immpc;
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_LUI: begin
						regwena <= 1'b1;
						regdata <= intreg;
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_JAL: begin
						regwena <= 1'b1;
						regdata <= pc4;
						nextPC <= immpc;
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_OP, `OPCODE_OP_IMM: begin
						if (imathstart) begin
							regwena <= 1'b0;
							cpustate[CPU_MSTALL] <= 1'b1;
						end else begin
							regwena <= 1'b1;
							regdata <= aluout;
							cpustate[CPU_RETIRE] <= 1'b1;
						end
					end
					`OPCODE_FLOAT_OP: begin

						case (func7)
							`FSGNJ: begin
								fregwena <= 1'b1;
								case(func3)
									3'b000: begin // FSGNJ
										fregdata <= {frval2[31], frval1[30:0]}; 
									end
									3'b001: begin  // FSGNJN
										fregdata <= {~frval2[31], frval1[30:0]};
									end
									3'b010: begin  // FSGNJX
										fregdata <= {frval1[31]^frval2[31], frval1[30:0]};
									end
								endcase
								cpustate[CPU_RETIRE] <= 1'b1;
							end
							`FMVXW: begin
								regwena <= 1'b1;
								if (func3 == 3'b000) //FMVXW
									regdata <= frval1;
								else // FCLASS
									regdata <= 32'd0; // TBD
								cpustate[CPU_RETIRE] <= 1'b1;
							end
							`FMVWX: begin
								fregwena <= 1'b1;
								fregdata <= multiplicand; // rval1; multiplicant already equals to a copy of rval1
								cpustate[CPU_RETIRE] <= 1'b1;
							end
							`FADD: begin
								faddvalid <= 1'b1;
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FSUB: begin
								fsubvalid <= 1'b1;
								cpustate[CPU_FSTALL] <= 1'b1;
							end	
							`FMUL: begin
								fmulvalid <= 1'b1;
								cpustate[CPU_FSTALL] <= 1'b1;
							end	
							`FDIV: begin
								fdivvalid <= 1'b1;
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FCVTSW: begin	
								fi2fvalid <= (rs2==5'b00000) ? 1'b1:1'b0; // Signed
								fui2fvalid <= (rs2==5'b00001) ? 1'b1:1'b0; // Unsigned
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FCVTWS: begin
								ff2ivalid <= (rs2==5'b00000) ? 1'b1:1'b0; // Signed
								ff2uivalid <= (rs2==5'b00001) ? 1'b1:1'b0; // Unsigned
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FSQRT: begin
								fsqrtvalid <= 1'b1;
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FEQ: begin
								feqvalid <= (func3==3'b010) ? 1'b1:1'b0; // FEQ
								fltvalid <= (func3==3'b001) ? 1'b1:1'b0; // FLT
								flevalid <= (func3==3'b000) ? 1'b1:1'b0; // FLE
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							`FMAX: begin
								fltvalid <= 1'b1; // FLT
								cpustate[CPU_FSTALL] <= 1'b1;
							end
							default: begin
								cpustate[CPU_RETIRE] <= 1'b1;
							end
						endcase
					end
					`OPCODE_FLOAT_MADD: begin
						fmaddvalid <= 1'b1;
						cpustate[CPU_FMSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_MSUB: begin
						fmsubvalid <= 1'b1;
						cpustate[CPU_FMSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_NMSUB: begin
						fnmsubvalid <= 1'b1; // is actually MADD!
						cpustate[CPU_FMSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_NMADD: begin
						fnmaddvalid <= 1'b1; // is actually MSUB!
						cpustate[CPU_FMSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_LDW, `OPCODE_LOAD: begin
						cpustate[CPU_LOADSTALL] <= 1'b1;
					end
					`OPCODE_FLOAT_STW, `OPCODE_STORE: begin
						/*if (~busbusy) begin // Need this for multi-CPU
						end else begin*/
						busaddress <= immreach;
						unique case (func3)
							3'b000: begin // BYTE
								dataout <= {rval2[7:0], rval2[7:0], rval2[7:0], rval2[7:0]};
								unique case (immreach[1:0])
									2'b11: begin buswe <= 4'h8; end
									2'b10: begin buswe <= 4'h4; end
									2'b01: begin buswe <= 4'h2; end
									2'b00: begin buswe <= 4'h1; end
								endcase
							end
							3'b001: begin // WORD
								dataout <= {rval2[15:0], rval2[15:0]};
								unique case (immreach[1])
									1'b1: begin buswe <= 4'hC; end
									1'b0: begin buswe <= 4'h3; end
								endcase
							end
							default: begin // DWORD
								dataout <= (opcode == `OPCODE_FLOAT_STW) ? frval2 : rval2;
								buswe <= 4'hF;
							end
						endcase
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_FENCE: begin
						// TODO:
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_SYSTEM: begin
						unique case (func3)
							// ECALL/EBREAK
							3'b000: begin
								unique case (func12)
									12'b000000000000: begin // ECALL
										// TBD:
										// li a7, SBI_SHUTDOWN // also a0/a1/a2, retval in a0
  										// ecall
  									end
									12'b000000000001: begin // EBREAK
										ebreak <= CSRReg[`CSR_MIE][3];
									end
									// privileged instructions
									12'b001100000010: begin // MRET
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd3) CSRReg[`CSR_MIP][3] <= 1'b0;	// Disable machine software interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd7) CSRReg[`CSR_MIP][7] <= 1'b0;	// Disable machine timer interrupt pending
										if (CSRReg[`CSR_MCAUSE][15:0] == 16'd11) CSRReg[`CSR_MIP][11] <= 1'b0;	// Disable machine external interrupt pending
										CSRReg[`CSR_MSTATUS][3] <= CSRReg[`CSR_MSTATUS][7];						// MIE=MPIE - set to previous machine interrupt enable state
										CSRReg[`CSR_MSTATUS][7] <= 1'b0;										// Clear MPIE
										nextPC <= CSRReg[`CSR_MEPC];
									end
								endcase
								cpustate[CPU_RETIRE] <= 1'b1;
							end
							// CSRRW/CSRRS/CSSRRC/CSRRWI/CSRRSI/CSRRCI
							3'b001, 3'b010, 3'b011, 3'b101, 3'b110, 3'b111: begin 
								regwena <= 1'b1;
								regdata <= CSRReg[CSRIndextoLinearIndex];
								cpustate[CPU_UPDATECSR] <= 1'b1;
							end
							// Unknown
							default: begin
								cpustate[CPU_RETIRE] <= 1'b1;
							end
						endcase
					end
					`OPCODE_JALR: begin
						regwena <= 1'b1;
						regdata <= pc4;
						nextPC <= immreach;
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					`OPCODE_BRANCH: begin
						nextPC <= branchpc;
						cpustate[CPU_RETIRE] <= 1'b1;
					end
					default: begin
						// Illegal instruction triggers only when machine
						// software interrupts are enabled
						illegalinstruction <= CSRReg[`CSR_MIE][3];
						cpustate[CPU_RETIRE] <= 1'b1;
					end
				endcase
			end
			
			cpustate[CPU_MSTALL]: begin
				if (imathbusy) begin
					// Keep stalling while M/D/R units are busy
					cpustate[CPU_MSTALL] <= 1'b1;
				end else begin
					// Write result to destination register
					regwena <= 1'b1;
					unique case (aluop)
						`ALU_MUL: begin
							regdata <= product;
						end
						`ALU_DIV: begin
							regdata <= func3==`F3_DIV ? quotient : quotientu;
						end
						`ALU_REM: begin
							regdata <= func3==`F3_REM ? remainder : remainderu;
						end
					endcase
					cpustate[CPU_RETIRE] <= 1'b1;
				end
			end

			cpustate[CPU_FSTALL]: begin
				faddvalid <= 1'b0;
				fsubvalid <= 1'b0;
				fmulvalid <= 1'b0;
				fdivvalid <= 1'b0;
				fi2fvalid <= 1'b0;
				fui2fvalid <= 1'b0;
				ff2ivalid <= 1'b0;
				ff2uivalid <= 1'b0;
				fsqrtvalid <= 1'b0;
				feqvalid <= 1'b0;
				fltvalid <= 1'b0;
				flevalid <= 1'b0;

				if  (fmulresultvalid | fdivresultvalid | fi2fresultvalid | fui2fresultvalid | ff2iresultvalid | ff2uiresultvalid | faddresultvalid | fsubresultvalid | fsqrtresultvalid | feqresultvalid | fltresultvalid | fleresultvalid) begin
					cpustate[CPU_RETIRE] <= 1'b1;
					case (func7)
						`FADD: begin
							fregwena <= 1'b1;
							fregdata <= faddresult;
						end
						`FSUB: begin
							fregwena <= 1'b1;
							fregdata <= fsubresult;
						end
						`FMUL: begin
							fregwena <= 1'b1;
							fregdata <= fmulresult;
						end
						`FDIV: begin
							fregwena <= 1'b1;
							fregdata <= fdivresult;
						end
						`FCVTSW: begin // NOTE: FCVT.S.WU is unsigned version
							fregwena <= 1'b1;
							fregdata <= rs2==5'b00000 ? fi2fresult : fui2fresult; // Result goes to float register (signed int to float)
						end
						`FCVTWS: begin // NOTE: FCVT.WU.S is unsigned version
							regwena <= 1'b1;
							regdata <= rs2==5'b00000 ? ff2iresult : ff2uiresult; // Result goes to integer register (float to signed int)
						end
						`FSQRT: begin
							fregwena <= 1'b1;
							fregdata <= fsqrtresult;
						end
						`FEQ: begin
							regwena <= 1'b1;
							if (func3==3'b010) // FEQ
								regdata <= {31'd0,feqresult[0]};
							else if (func3==3'b001) // FLT
								regdata <= {31'd0,fltresult[0]};
							else //if (func3==3'b000) // FLE
								regdata <= {31'd0,fleresult[0]};
						end
						`FMIN: begin
							fregwena <= 1'b1;
							if (func3==3'b000) // FMIN
								fregdata <= fltresult[0]==1'b0 ? frval2 : frval1;
							else // FMAX
								fregdata <= fltresult[0]==1'b0 ? frval1 : frval2;
						end
					endcase
				end else begin
					cpustate[CPU_FSTALL] <= 1'b1; // Stall further for float op
				end
			end

			cpustate[CPU_FMSTALL]: begin
				fmaddvalid <= 1'b0;
				fmsubvalid <= 1'b0;
				fnmsubvalid <= 1'b0;
				fnmaddvalid <= 1'b0;
				if (fnmsubresultvalid | fnmaddresultvalid | fmsubresultvalid | fmaddresultvalid) begin
					fregwena <= 1'b1;
					cpustate[CPU_RETIRE] <= 1'b1;
					case (opcode)
						`OPCODE_FLOAT_NMSUB: begin
							fregdata <= fnmsubresult;
						end
						`OPCODE_FLOAT_NMADD: begin
							fregdata <= fnmaddresult;
						end
						`OPCODE_FLOAT_MADD: begin
							fregdata <= fmaddresult;
						end
						`OPCODE_FLOAT_MSUB: begin
							fregdata <= fmsubresult;
						end
					endcase
				end else begin
					cpustate[CPU_FMSTALL] <= 1'b1; // Stall further for fused float
				end
			end

			cpustate[CPU_RETIRE]: begin
				// Update internal counters from CSRs
				internaltimecmp <= {CSRReg[`CSR_TIMECMPHI], CSRReg[`CSR_TIMECMPLO]};

				// Stop writes to integer/float register files
				regwena <= 1'b0;
				fregwena <= 1'b0;

				if (~busbusy) begin
					PC <= nextPC;
					busaddress <= nextPC;
					busre <= 1'b1;

					if (CSRReg[`CSR_MSTATUS][3]) begin

						// Common action in case of 'any' interrupt
						if (illegalinstruction | ebreak | timerinterrupt | externalinterrupt) begin
							CSRReg[`CSR_MSTATUS][7] <= CSRReg[`CSR_MSTATUS][3]; // Remember interrupt enable status in pending state (MPIE = MIE)
							CSRReg[`CSR_MSTATUS][3] <= 1'b0; // Clear interrupts during handler
							CSRReg[`CSR_MTVAL] <= illegalinstruction ? PC : 32'd0; // Store interrupt/exception specific data (default=0)
							CSRReg[`CSR_MSCRATCH] <= illegalinstruction ? instruction : 32'd0; // Store the offending instruction for IEX
							CSRReg[`CSR_MEPC] <= ebreak ? PC : nextPC; // Remember where to return (special case; ebreak returns to same PC as breakpoint)
							// Jump to handler
							// Set up non-vectored branch (always assume CSRReg[`CSR_MTVEC][1:0]==2'b00)
							PC <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
							busaddress <= {CSRReg[`CSR_MTVEC][31:2],2'b00};
						end

						// Set interrupt pending bits
						// NOTE: illegal instruction and ebreak both create the same machine software interrupt
						{CSRReg[`CSR_MIP][3], CSRReg[`CSR_MIP][7], CSRReg[`CSR_MIP][11]} <= {illegalinstruction | ebreak, timerinterrupt, externalinterrupt};

						unique case (1'b1)
							illegalinstruction, ebreak: begin
								CSRReg[`CSR_MCAUSE][15:0] <= 16'd3; // Illegal instruction or breakpoint interrupt
								CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 14'd0, illegalinstruction ? 1'b1:1'b0}; // Cause: 0: ebreak 1: illegal instruction
							end
							timerinterrupt: begin // NOTE: Time interrupt stays pending until cleared
								CSRReg[`CSR_MCAUSE][15:0] <= 16'd7; // Timer Interrupt
								CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 15'd0}; // Type of timer interrupt is set to zero
							end
							externalinterrupt: begin
								CSRReg[`CSR_MCAUSE][15:0] <= 16'd11; // Machine External Interrupt
								// Device mask (lower 15 bits of upper word)
								// [11:0]:SWITCHES:SPIRX:UARTRX
								CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 12'd0, IRQ_BITS};
							end
							default: begin
								CSRReg[`CSR_MCAUSE][15:0] <= 16'd0; // No interrupt/exception
								CSRReg[`CSR_MCAUSE][31:16] <= {1'b1, 15'd0};
							end
						endcase
					end
					cpustate[CPU_FETCH] <= 1'b1;
				end else begin
					cpustate[CPU_RETIRE] <= 1'b1;
				end
			end

			cpustate[CPU_UPDATECSR]: begin
				// Stop writes to integer register file
				regwena <= 1'b0;
				
				// Write to r/w CSR
				case(func3)
					3'b001: begin // CSRRW
						CSRReg[CSRIndextoLinearIndex] <= multiplicand;
					end
					3'b101: begin // CSRRWI
						CSRReg[CSRIndextoLinearIndex] <= intreg;
					end
					3'b010: begin // CSRRS
						CSRReg[CSRIndextoLinearIndex] <= regdata | multiplicand;
					end
					3'b110: begin // CSRRSI
						CSRReg[CSRIndextoLinearIndex] <= regdata | intreg;
					end
					3'b011: begin // CSSRRC
						CSRReg[CSRIndextoLinearIndex] <= regdata & (~multiplicand);
					end
					3'b111: begin // CSRRCI
						CSRReg[CSRIndextoLinearIndex] <= regdata & (~intreg);
					end
					default: begin // Unknown
						CSRReg[CSRIndextoLinearIndex] <= regdata;
					end
				endcase
				cpustate[CPU_RETIRE] <= 1'b1;
			end

			cpustate[CPU_LOADSTALL]: begin
				if (~busbusy) begin
					busaddress <= immreach;
					busre <= 1'b1;
					cpustate[CPU_LOAD] <= 1'b1;
				end else begin
					cpustate[CPU_LOADSTALL] <= 1'b1;
				end
			end
			
			cpustate[CPU_LOAD]: begin
				if (busbusy) begin
					cpustate[CPU_LOAD] <= 1'b1;
				end else begin
					if (opcode == `OPCODE_FLOAT_LDW) begin
						fregwena <= 1'b1;
					end else begin
						regwena <= 1'b1;
					end
					unique case (func3)
						3'b000: begin // BYTE with sign extension
							unique case (busaddress[1:0])
								2'b11: begin regdata <= {{24{busdata[31]}}, busdata[31:24]}; end
								2'b10: begin regdata <= {{24{busdata[23]}}, busdata[23:16]}; end
								2'b01: begin regdata <= {{24{busdata[15]}}, busdata[15:8]}; end
								2'b00: begin regdata <= {{24{busdata[7]}},  busdata[7:0]}; end
							endcase
						end
						3'b001: begin // WORD with sign extension
							unique case (busaddress[1])
								1'b1: begin regdata <= {{16{busdata[31]}}, busdata[31:16]}; end
								1'b0: begin regdata <= {{16{busdata[15]}}, busdata[15:0]}; end
							endcase
						end
						3'b010: begin // DWORD
							if (opcode == `OPCODE_FLOAT_LDW)
								fregdata <= busdata[31:0];
							else
								regdata <= busdata[31:0];
						end
						3'b100: begin // BYTE with zero extension
							unique case (busaddress[1:0])
								2'b11: begin regdata <= {24'd0, busdata[31:24]}; end
								2'b10: begin regdata <= {24'd0, busdata[23:16]}; end
								2'b01: begin regdata <= {24'd0, busdata[15:8]}; end
								2'b00: begin regdata <= {24'd0, busdata[7:0]}; end
							endcase
						end
						3'b101: begin // WORD with zero extension
							unique case (busaddress[1])
								1'b1: begin regdata <= {16'd0, busdata[31:16]}; end
								1'b0: begin regdata <= {16'd0, busdata[15:0]}; end
							endcase
						end
					endcase

					cpustate[CPU_RETIRE] <= 1'b1;
				end
			end

		endcase

	end
end

endmodule
