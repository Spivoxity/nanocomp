# README #

Files:

* `assem.tcl` -- M6800 assembler (written in TCL)
* `clock.m68` -- Code for 24-hour clock
* `Makefile` -- Makefile that builds `clock.hex` for programming the bootstrap loader.
* `master` -- Typed-in listing of contents of Nanocomp ROM
* `nanoboot.c` -- Bootstrap loader that runs on an Atmel ATtiny85 and emulates the Nanocomp cassette interface.
* `rom.m68` -- My hand-written disassembly of the Nanocomp ROM