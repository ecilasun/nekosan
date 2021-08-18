# nekosan

NekoSan is the third generation of the Neko SoC series

This version implements the following:
- DDR3 controler with a single cache (256 lines, 256bits per line, direct mapping)
- 256Mbytes of DDR3 (D-RAM) @0x00000000
- 32Kbytes of boot ROM/RAM (A-RAM) @0x20000000
- 64Kbytes of graphics memory (G-RAM) @0x10000000
- Memory mapped device IO starting @0x80000000
- ELF binaries get loaded into DDR3 space to avoid overlap
  - This way, user programs will be able to refer to ROM functions via ECALL to ARAM space
- UART TX/RX at 115200 bauds (use riscvtool to upload ELF binaries)
- Implements the minimal RV32IZicsr set of RISC-V architecture
  - Machine Software/Timer/External interrupt support
  - Cycle/Wallclock and some other utility CSRs (machine interrupt control/pending etc) implemented
- SDCard support
  - Via SPI interface
- On-board switch / LED I/O
  - Using memory mapped I/O mechanism
- Audio output support
  - Same i2s device as before via self-timing FIFO
- Video output support
  - A minimal GPU implementation (DMA+mem writes)
  - Add DMA access to G-RAM from GPU side (true dual port)
  - DVI unit + 2xframebuffer devices + scanout buffer

## TODO
- Programs should be able to return back to the ROM code (loader)
- Add vsync back to the GPU
- Add bus arbiter to support more than one bus master
  - An extra RISCV core perhaps?
- A more advanced boot ROM image
  - Current ROM image supports only illegal instruction exception traps and UART program loading
  - Might want to extend it to support timer driven interrupts and thread support by default (via ECALL from ELF?)
  - A graphical user interface like before: show SDCard contents & load selection
