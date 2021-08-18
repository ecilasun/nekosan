// ======================== GPU States ==========================
`define GPUSTATEBITS 6

`define GPUSTATEIDLE			0
`define GPUSTATELATCHCOMMAND	1
`define GPUSTATEEXEC			2
`define GPUSTATECLEAR			3
`define GPUSTATEDMAKICK			4
`define GPUSTATEDMA				5

`define GPUSTATENONE_MASK			0

`define GPUSTATEIDLE_MASK			1
`define GPUSTATELATCHCOMMAND_MASK	2
`define GPUSTATEEXEC_MASK			4
`define GPUSTATECLEAR_MASK			8
`define GPUSTATEDMAKICK_MASK		16
`define GPUSTATEDMA_MASK			32
// ==============================================================

// =================== GPU Commands =============================

`define GPUCMD_UNUSED0		3'b000
`define GPUCMD_SETREG		3'b001
`define GPUCMD_SETPALENT	3'b010
`define GPUCMD_UNUSED3		3'b011
`define GPUCMD_SYSDMA		3'b100
`define GPUCMD_VMEMOUT		3'b101
`define GPUCMD_GMEMOUT		3'b110
`define GPUCMD_SETVPAGE		3'b111

// ==============================================================
