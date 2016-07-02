/* This program runs on an Arduino and produces on an I/O pin the signal
   needed to bootstrap Nanocomp via its cassette interface */

#include <avr/io.h>
#include <avr/pgmspace.h>
#include <util/delay.h>

typedef uint8_t byte;

#define DDR DDRB
#define PORT PORTB
#define BIT 3
#define LED 4

#define sbi(reg, bit) reg |= _BV(bit)
#define cbi(reg, bit) reg &= ~_BV(bit)

#define out_high() sbi(PORT, BIT)
#define out_low() cbi(PORT, BIT)

#define delay_ms _delay_ms

#define delay_short() delay_ms(0.25)
#define delay_long() delay_ms(1.0)

void sendbit(byte x) {
     if (x) {
          out_high();
          delay_short();
          out_low();
          delay_short();
     } else {
          out_high();
          delay_long();
          out_low();
          delay_long();
     }
}

byte check;

void sendbyte(byte x) {
     int i = 8;

     check += x;

     sendbit(0);                // Start bit
     while (i-- > 0) {
          sendbit(x & 0x01);
          x >>= 1;
     }
     sendbit(1);
}

     
void sendblock(int addr, byte *data, int len) {
     sendbyte(0x53);
     sendbyte(0x31);
     
     check = 0;
     sendbyte(len+2);
     sendbyte((addr >> 8) & 0xff);
     sendbyte(addr & 0xff);
     while (len-- > 0)
          sendbyte(pgm_read_byte(data++));
     sendbyte(-check);
}

void bootstrap(byte *data, int len) {
     int addr = 0x1000;
     int block;

     sendbyte(0xff);
     sendbyte(0xff);

     while (len > 0) {
          block = ((addr+16) & ~0xf) - addr;
          if (block > len) block = len;
          sendblock(addr, data, block);
          addr += block; data += block; len -= block;
     }

     sendbyte(0x53);
     sendbyte(0x4a);
}

extern int codelen;
extern byte code[];

int main() {
     DDR = _BV(BIT) | _BV(LED);
     sbi(PORT, LED);
     bootstrap(code, codelen);
     cbi(PORT, LED);
     while (1) { }
     return 0;
}
