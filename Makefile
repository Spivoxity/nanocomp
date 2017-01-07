all: clock.hex

# AVR executable file in hex format
%.hex: %.elf
	avr-objcopy -O ihex -R .eeprom $< $@

# AVR executable file in ELF format
%.elf: %-code.o nanoboot.o 
	avr-gcc -Os -Wl,--gc-sections -mmcu=$(MCU) -o $@ $^ -lm
	avr-size --format=avr --mcu=$(MCU) $@

# AVR object file
%.o: %.c
	avr-gcc $(CFLAGS) -c $< -o $@

# M6800 code embedded in C
%-code.c: %.m68 assem.tcl
	tclsh $< >$@

MCU = attiny85
CGFLAGS = -fno-exceptions -ffunction-sections -fdata-sections
DEFINES = -DF_CPU=8000000L
CFLAGS = -g -Os -Wall -mmcu=$(MCU) $(CGFLAGS) $(DEFINES) $(INCLUDES)

check: code
	diff master code

code: rom.m68 assem.tcl
	tclsh rom.m68 >code

upload: clock.hex force
	avrdude -p$(MCU) -cusbtiny -Uflash:w:$<:i

clean: force
	rm -f *.o clock-code.c clock.elf clock.hex

force:
