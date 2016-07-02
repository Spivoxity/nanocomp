all: nanoboot.hex

check: code
	diff master code

code: rom assem
	tclsh rom >code

bootcode.c: clock assem
	tclsh clock >$@

MCU = attiny85
CGFLAGS = -fno-exceptions -ffunction-sections -fdata-sections
DEFINES = -DF_CPU=8000000L
CFLAGS = -g -Os -Wall -mmcu=$(MCU) $(CGFLAGS) $(DEFINES) $(INCLUDES)

nanoboot.elf: nanoboot.o bootcode.o
	avr-gcc -Os -Wl,--gc-sections -mmcu=$(MCU) -o $@ $^ -lm
	avr-size --format=avr --mcu=$(MCU) $@

%.o: %.c
	avr-gcc $(CFLAGS) -c $< -o $@

%.hex: %.elf
	avr-objcopy -O ihex -R .eeprom $< $@

upload: nanoboot.hex force
	avrdude -p$(MCU) -cusbtiny -Uflash:w:$<:i

force:
