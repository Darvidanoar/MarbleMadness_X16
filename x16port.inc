; ----------------------------------------------------------------------------
; Marble Madness for the Commander X16 - shared definitions
; ----------------------------------------------------------------------------

.ifndef X16PORT_INC
X16PORT_INC = 1

.setcpu "65C02"

; NES zero-page variable names (same addresses as on the NES)
.include "zeropage.inc"

; ---------------------------------------------------------------- X16 hardware
RAM_BANK        = $00
ROM_BANK        = $01

VERA_ADDR_L     = $9F20
VERA_ADDR_M     = $9F21
VERA_ADDR_H     = $9F22
VERA_DATA0      = $9F23
VERA_DATA1      = $9F24
VERA_CTRL       = $9F25
VERA_IEN        = $9F26
VERA_ISR        = $9F27
VERA_IRQLINE_L  = $9F28
VERA_DC_VIDEO   = $9F29     ; DCSEL=0
VERA_DC_HSCALE  = $9F2A
VERA_DC_VSCALE  = $9F2B
VERA_DC_BORDER  = $9F2C
VERA_DC_HSTART  = $9F29     ; DCSEL=1
VERA_DC_HSTOP   = $9F2A
VERA_DC_VSTART  = $9F2B
VERA_DC_VSTOP   = $9F2C
VERA_L0_CONFIG  = $9F2D
VERA_L1_CONFIG  = $9F34
VERA_L1_MAPBASE = $9F35
VERA_L1_TILEBASE = $9F36
VERA_L1_HSCROLL_L = $9F37
VERA_L1_HSCROLL_H = $9F38
VERA_L1_VSCROLL_L = $9F39
VERA_L1_VSCROLL_H = $9F3A

; KERNAL API
KERNAL_SETLFS   = $FFBA
KERNAL_SETNAM   = $FFBD
KERNAL_LOAD     = $FFD5
KERNAL_CHROUT   = $FFD2
KERNAL_KBDSCAN  = $FF9F
KERNAL_JOYSCAN  = $FF53
KERNAL_JOYGET   = $FF56
KERNAL_SCRMODE  = $FF5F
KERNAL_MOUSECFG = $FF68
KERNAL_EXTAPI   = $FEAB     ; R47+: A = 9 is ps2data_raw
KERNAL_VERSION  = $FF80     ; ROM version (negative = prerelease)
CINV            = $0314

; ---------------------------------------------------------------- memory map
; NES work RAM $0200-$07FF lives at NESRAM ($0000-$01FF stay where they are).
NESRAM          = $9900
.define RAM(addr)  NESRAM - $0200 + (addr)

; NES PRG bank b is stored in X16 RAM banks 1+8b .. 8+8b as eight 8KB windows
; at a 4KB stride: window w holds NES $8000+w*$1000 .. +$1FFF.
.define WIN(addr)  $A000 | ((addr) & $0FFF)

; VRAM layout
VRAM_MAP0       = $00000    ; nametable page 0: 32x64 entries (rows 30-59 repeat 0-29)
VRAM_MAP1       = $01000    ; nametable page 1
VRAM_BGT        = $02000    ; NES pattern tables as 2bpp tiles: $0000 -> tiles 0-255, $1000 -> 256-511
VRAM_SPT        = $04000    ; NES pattern tables as 4bpp sprite tiles (2 x 8KB)
VRAM_PSG        = $1F9C0
VRAM_PALETTE    = $1FA00
VRAM_SPRATTR    = $1FC00

CHR_SHADOW_BANK = 33        ; RAM bank holding a copy of the 8KB NES CHR-RAM

; Marble top speed on the ground, per axis: the NES caps it at $0100 (fall speed
; is capped at $017F).  The port allows $0100 + SPEED_EXTRA (0 = NES, max $7F).
.ifndef SPEED_EXTRA
SPEED_EXTRA     = $30
.endif

; ---------------------------------------------------------------- zero page
; Bytes the NES game never uses.
x16_tptr        = $24       ; [2] translated pointer for (zp),y accesses
x16_t0          = $2B
x16_t1          = $2C
x16_t2          = $7E
x16_t3          = $7F

.endif
