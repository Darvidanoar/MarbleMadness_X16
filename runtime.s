; ----------------------------------------------------------------------------
; Marble Madness for the Commander X16 - runtime
;
; The NES game code (bank*.s) runs natively.  This file provides:
;   - start-up: loads the NES bank images into banked RAM, sets up VERA
;   - the VSYNC interrupt, which plays the role of the NES NMI
;   - PPU emulation on top of VERA (nametables, CHR-RAM, palette, sprites)
;   - APU emulation on top of the VERA PSG
;   - controller emulation using the KERNAL joystick API
;   - the NES mapper / far-call / banked data helpers
; ----------------------------------------------------------------------------

.include "x16port.inc"

.import NMIMain, ResetMain, sub_A5AC
.import fartab_b1, fartab_b2, fartab_b3

.export x16_farcall, x16_idle, x16_split, x16_box, x16_mapper_w
.export x16_ppu_w0, x16_ppu_w1, x16_ppu_w2, x16_ppu_w3, x16_ppu_w4, x16_ppu_w5, x16_ppu_w6, x16_ppu_w7
.export x16_ppu_wx0, x16_ppu_wx6, x16_ppu_wx7, x16_ppu_wy6, x16_ppu_wy7
.export x16_ppu_r2, x16_ppu_r7
.export x16_io_write, x16_io_read
.export nes_mapper, nes_ppuctrl
.export x16_zp_mirror, x16_zp_mirror_buf
.export x16_mouse_take, mouse_e, mouse_d, x16_name_mouse
.export x16_title_esc, x16_exit, esc_hit

; ============================================================================
; Variables (X16 "golden RAM" $0400-$07FF)
; ============================================================================
.segment "GOLDEN"

nes_mapper:     .res 1      ; NES ZP $00 (mapper_shadow)
nes_ppuctrl:    .res 1      ; NES ZP $01 (ppuctrl_shadow)
zpsave:         .res 256    ; KERNAL's zero page while the game runs

; PPU state
ppu_ctrl:       .res 1
ppu_mask:       .res 1
ppu_vbl:        .res 1      ; $80 after VSYNC until PPUSTATUS is read
ppu_w:          .res 1      ; address/scroll write toggle
ppu_t:          .res 2      ; NES "t" register (scroll / address latch)
ppu_fx:         .res 1      ; fine X scroll
ppu_v:          .res 2      ; current VRAM address
ppu_inc:        .res 1      ; 1 or 32
ppu_wvec:       .res 2      ; PPUDATA write handler for the current region
ppu_count:      .res 1      ; nametable writes left before the attribute area
ppu_readbuf:    .res 1
nes_page:       .res 1      ; one-screen nametable page (mapper bit 4)
pal_shadow:     .res 32
attr_shadow:    .res 128    ; 64 attribute bytes per page

; display latch (state the next frame is shown with)
lat_ctrl:       .res 1
lat_mask:       .res 1
lat_t:          .res 2
lat_fx:         .res 1
lat_page:       .res 1
lat_split:      .res 1      ; 0 = none, else last visible NES line + 1
lat_box:        .res 1      ; message-box pattern-table effect

frame_done:     .res 1      ; a NES frame finished since the last VSYNC
split_req:      .res 1      ; sprite-0 split reached this frame
box_req:        .res 1      ; box effect requested this frame

; message box currently applied to the tile map
bx_on:          .res 2      ; per box: applied to the tile map?
bx_page:        .res 2
bx_r0:          .res 2
bx_r1:          .res 2

; controllers
pad_state:      .res 2      ; NES button bytes (A B Sel St U D L R)
pad_shift:      .res 2
pad_strobe:     .res 1
ps2fetch:       .res 2      ; KERNAL ps2data_fetch (taken from the default IRQ)

; APU
apu_regs:       .res 24
apu_len:        .res 4      ; length counters (sq1, sq2, tri, noise)
apu_env_vol:    .res 4      ; envelope decay level
apu_env_div:    .res 4
apu_env_start:  .res 4
apu_sweep_div:  .res 2
apu_sweep_reload: .res 2
apu_period_lo:  .res 3      ; current timer period (squares, triangle)
apu_period_hi:  .res 3
apu_lin:        .res 1      ; triangle linear counter
apu_lin_reload: .res 1
apu_enable:     .res 1      ; $4015

oam_copy:       .res 256
oam_dirty:      .res 1

; misc
dbg_frames:     .res 2
game_frames:    .res 2              ; NES frames run (NMIs with game_state >= 0)
dbg_input_pos:  .res 1
dbg_input_cur:  .res 1
farcall_vec:    .res 2
vera_saved:     .res 7
old_cinv:       .res 2
div_num:        .res 3
div_den:        .res 2
div_q:          .res 2

; mouse (player 1 steering, like the Amiga version)
mouse_ok:       .res 1      ; KERNAL can deliver raw mouse packets
mouse_dx:       .res 1      ; movement since the last game frame (signed,
mouse_dy:       .res 1      ;   screen right / down are positive)
mouse_btn:      .res 1      ; NES buttons from the mouse buttons (L = A, R = B)
mouse_e:        .res 1      ; acceleration for this frame along the marble's
mouse_d:        .res 1      ;   E (down-left) and D (down-right) axes

; quitting to BASIC (Esc on the title screen)
esc_hit:        .res 1      ; Esc was typed since the title screen was drawn
saved_bank:     .res 1      ; RAM bank at start-up
saved_dc:       .res 8      ; VERA DC registers at start-up (DCSEL 0, then DCSEL 1)
saved_l1:       .res 7      ; VERA layer 1 registers at start-up

; ============================================================================
; Low RAM above the program
; ============================================================================
.segment "BSS"

saved_pal:      .res 512    ; VERA palette at start-up

; ============================================================================
; BASIC stub
; ============================================================================
.segment "LOADADDR"
        .word   $0801

.segment "EXEHDR"
        .word   @next, 10
        .byte   $9E, "2061", 0
@next:  .word   0

; ============================================================================
; Start-up
; ============================================================================
.segment "CODE"

start:
        stz     ROM_BANK                ; KERNAL ROM
        lda     RAM_BANK
        pha
        ldx     #0
:       lda     msg_loading,x
        beq     :+
        jsr     KERNAL_CHROUT
        inx
        bne     :-
:
        ; load the NES bank images (256KB) into RAM banks 1-32 at $A000
        lda     #1
        sta     RAM_BANK
        lda     #fname_end - fname
        ldx     #<fname
        ldy     #>fname
        jsr     KERNAL_SETNAM
        lda     #1
        ldx     #8
        ldy     #2                      ; headerless load
        jsr     KERNAL_SETLFS
        lda     #0
        ldx     #<$A000
        ldy     #>$A000
        jsr     KERNAL_LOAD
        bcc     @loaded
        ldx     #0
:       lda     msg_error,x
        beq     :+
        jsr     KERNAL_CHROUT
        inx
        bne     :-
:       pla
        sta     RAM_BANK
        rts
@loaded:
        sei
        jsr     init_vars
        pla
        sta     saved_bank
        ; title screen: PRESS START (messages 6 and 7) one row up, clear of ESC TO EXIT
        lda     #20                     ; NES bank 2 $B000-$CFFF
        sta     RAM_BANK
        lda     #$EB                    ; was $230B
        sta     WIN($B812)+6
        sta     WIN($B812)+7
        lda     #$22
        sta     WIN($B847)+6
        sta     WIN($B847)+7
        jsr     mouse_init
        ; remember the KERNAL's zero page and IRQ handler
        ldx     #2
:       lda     $00,x
        sta     zpsave,x
        inx
        bne     :-
        lda     CINV
        sta     old_cinv
        lda     CINV+1
        sta     old_cinv+1
        ; the default handler starts with jsr ps2data_fetch: borrow it for the keyboard
        stz     ps2fetch+1
        lda     old_cinv
        sta     x16_tptr
        lda     old_cinv+1
        sta     x16_tptr+1
        lda     (x16_tptr)
        cmp     #$20                    ; jsr?
        bne     :+
        ldy     #1
        lda     (x16_tptr),y
        sta     ps2fetch
        iny
        lda     (x16_tptr),y
        sta     ps2fetch+1
:
        jsr     init_vera
        ; clear NES RAM $0200-$07FF
        lda     #<NESRAM
        sta     x16_tptr
        lda     #>NESRAM
        sta     x16_tptr+1
        ldx     #6
        ldy     #0
        lda     #0
:       sta     (x16_tptr),y
        iny
        bne     :-
        inc     x16_tptr+1
        dex
        bne     :-
        ; the NES starts with (our choice of) zeroed zero page
        ldx     #2
:       stz     $00,x
        inx
        bne     :-
        ; take over the IRQ
        lda     #<x16_irq
        sta     CINV
        lda     #>x16_irq
        sta     CINV+1
        lda     #$01                    ; VSYNC only
        sta     VERA_IEN
        cli
        jmp     ResetMain

fname:  .byte   "MMDATA.BIN"
fname_end:
msg_loading:
        .byte   $93, "MARBLE MADNESS - LOADING...", 13, 0
msg_error:
        .byte   "CANNOT LOAD MMDATA.BIN", 13, 0

init_vars:
        ldx     #0                      ; clear golden RAM $0400-$07FF
:       stz     $0400,x
        stz     $0500,x
        stz     $0600,x
        stz     $0700,x
        inx
        bne     :-
        lda     #1
        sta     ppu_inc
        lda     #<ppu_w_chr
        sta     ppu_wvec
        lda     #>ppu_w_chr
        sta     ppu_wvec+1
        lda     #$FF
        sta     pad_shift
        sta     pad_shift+1
        rts

; ----------------------------------------------------------------------------
init_vera:
        ; remember the display set-up, palette included, for quitting to BASIC
        stz     VERA_CTRL
        ldx     #0
:       lda     VERA_DC_VIDEO,x
        sta     saved_dc,x
        inx
        cpx     #4
        bne     :-
        lda     #$02                    ; DCSEL=1
        sta     VERA_CTRL
        ldx     #0
:       lda     VERA_DC_HSTART,x
        sta     saved_dc+4,x
        inx
        cpx     #4
        bne     :-
        stz     VERA_CTRL
        ldx     #0
:       lda     VERA_L1_CONFIG,x
        sta     saved_l1,x
        inx
        cpx     #7
        bne     :-
        stz     VERA_ADDR_L
        lda     #>VRAM_PALETTE
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        ldx     #0
:       lda     VERA_DATA0
        sta     saved_pal,x
        inx
        bne     :-
:       lda     VERA_DATA0
        sta     saved_pal+256,x
        inx
        bne     :-
        lda     VERA_DC_VIDEO
        and     #$0F                    ; keep output mode, all layers/sprites off
        sta     VERA_DC_VIDEO
        lda     #64
        sta     VERA_DC_HSCALE          ; 2x: 320x240
        sta     VERA_DC_VSCALE
        stz     VERA_DC_BORDER          ; border = NES backdrop colour
        lda     #$02                    ; DCSEL=1
        sta     VERA_CTRL
        lda     #16                     ; 256 pixels centred in 320
        sta     VERA_DC_HSTART
        lda     #144
        sta     VERA_DC_HSTOP
        stz     VERA_DC_VSTART
        lda     #240
        sta     VERA_DC_VSTOP
        stz     VERA_CTRL
        ; layer 1: 32x64 map, 2bpp tiles, 8x8
        lda     #$41
        sta     VERA_L1_CONFIG
        stz     VERA_L1_MAPBASE
        lda     #(VRAM_BGT >> 11) << 2
        sta     VERA_L1_TILEBASE
        stz     VERA_L1_HSCROLL_L
        stz     VERA_L1_HSCROLL_H
        stz     VERA_L1_VSCROLL_L
        stz     VERA_L1_VSCROLL_H
        ; clear VRAM $00000-$0FFFF (maps and tiles)
        stz     VERA_ADDR_L
        stz     VERA_ADDR_M
        lda     #$10
        sta     VERA_ADDR_H
        ldy     #0
        ldx     #0
:       stz     VERA_DATA0
        inx
        bne     :-
        iny
        bne     :-
        ; palette, sprite attributes: $1FA00-$1FFFF
        stz     VERA_ADDR_L
        lda     #$FA
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        ldx     #6
        ldy     #0
:       stz     VERA_DATA0
        iny
        bne     :-
        dex
        bne     :-
        ; PSG: silence
        lda     #<VRAM_PSG
        sta     VERA_ADDR_L
        lda     #>VRAM_PSG
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        ldx     #64
:       stz     VERA_DATA0
        dex
        bne     :-
        rts

; ============================================================================
; Interrupts: VSYNC acts as the NES NMI
; ============================================================================
x16_irq:
        lda     VERA_ISR
        and     #$01
        bne     @vsync
        lda     VERA_ISR                ; acknowledge anything else
        sta     VERA_ISR
        jmp     irq_exit
@vsync:
        sta     VERA_ISR
        inc     dbg_frames
        bne     :+
        inc     dbg_frames+1
:
        lda     #$80
        sta     ppu_vbl
        lda     RAM_BANK
        pha
        jsr     vera_save
        jsr     input_scan
        jsr     display_update
        lda     ppu_ctrl
        bpl     @done                   ; NMI disabled
        lda     game_state
        bmi     @sound
        ; ---- run one NES frame (NMIMain resets the stack; returns via x16_idle)
        inc     game_frames
        bne     :+
        inc     game_frames+1
:
.ifdef DEBUG_POKE_FRAME
        ; debug builds: poke DEBUG_POKE_VAL into DEBUG_POKE_ADDR before game frame N
        lda     game_frames
        cmp     #<DEBUG_POKE_FRAME
        bne     :+
        lda     game_frames+1
        cmp     #>DEBUG_POKE_FRAME
        bne     :+
        lda     #DEBUG_POKE_VAL
        sta     DEBUG_POKE_ADDR
:
.endif
.ifdef DEBUG_TRACE_FRAME
        ; debug builds: call dbg_trace_start at game frame N (use x16emu -trace <its address>)
        lda     game_frames
        cmp     #<DEBUG_TRACE_FRAME
        bne     :+
        lda     game_frames+1
        cmp     #>DEBUG_TRACE_FRAME
        bne     :+
        jsr     dbg_trace_start
:
.endif
.ifdef DEBUG_DUMP_FRAME
        ; debug builds: dump emulator state (x16emu -dump) before game frame N and exit
        lda     game_frames
        cmp     #<DEBUG_DUMP_FRAME
        bne     :+
        lda     game_frames+1
        cmp     #>DEBUG_DUMP_FRAME
        bne     :+
        lda     #$42
        sta     $9FB9                   ; console: "User debug 1: $42"
        lda     #1
        sta     $9FB4                   ; save-on-exit
        jmp     $FFFF
:
.endif
        stz     split_req
        stz     box_req
        lda     #$00                    ; the NES NMI stub selects bank 0 / nametable page 0
        jsr     x16_mapper_w
        jmp     NMIMain
@sound:
        ; game_state < 0: the NES NMI only runs the sound driver (bank 3)
        jsr     sub_A5AC
        jsr     apu_update
        lda     nes_mapper              ; the NES stub restores the mapper from $00
        jsr     x16_mapper_w
@done:
        jsr     vera_restore
        pla
        sta     RAM_BANK
irq_exit:
        ply
        plx
        pla
        rti

.ifdef DEBUG_TRACE_FRAME
dbg_trace_start:
        nop
        rts
.endif

; End of a NES frame (the game's "jmp *" wait for the next NMI).
x16_idle:
        sei
        lda     split_req
        bne     :+                      ; top-of-screen state was latched at the split
        jsr     latch_display
        stz     lat_split
:
        lda     box_req
        sta     lat_box
        lda     #1
        sta     frame_done
        stz     mouse_dx                ; movement the game did not use is dropped
        stz     mouse_dy
        jsr     apu_update
        cli
@wait:  .byte   $CB                     ; wai
        bra     @wait

; Sprite-0 hit: the playfield ends here.  Latch the display state now and
; blank everything below the line sprite 0 sits on.
x16_split:
        php
        pha
        jsr     latch_display
        lda     NESRAM                  ; NES OAM[0].y
        clc
        adc     #1
        sta     lat_split
        lda     #1
        sta     split_req
        pla
        plp
        rts

; Message box drawn with the second pattern table (mid-scanline PPUCTRL writes on NES).
x16_box:
        lda     #$88                    ; the NES loop leaves PPUCTRL = $88
        jsr     x16_ppu_w0
        stz     tmp0                    ; ... and tmp0 = 0
        lda     msg_id
        cmp     #4
        beq     @two
        lda     #1                      ; box 0
        sta     box_req
        lda     msg_id                  ; registers as the NES routine leaves them
        ldx     #1
        ldy     #1
        rts
@two:   lda     #3                      ; message 4 also uses the second band
        sta     box_req
        lda     #$88
        ldx     #0
        ldy     #0
        rts

latch_display:
        lda     ppu_ctrl
        sta     lat_ctrl
        lda     ppu_mask
        sta     lat_mask
        lda     ppu_t
        sta     lat_t
        lda     ppu_t+1
        sta     lat_t+1
        lda     ppu_fx
        sta     lat_fx
        lda     nes_page
        sta     lat_page
        rts

; Apply the latched NES display state to VERA (called at VSYNC).
display_update:
        lda     frame_done
        bne     @latched
        lda     game_state
        bpl     @keep                   ; a frame is pending: keep the old picture
        jsr     latch_display           ; no NES frame: show the live state
        stz     lat_split
        stz     lat_box
        bra     @apply
@keep:  rts
@latched:
        stz     frame_done
@apply:
        stz     VERA_CTRL
        ; layer 1 / sprite enables
        ldx     lat_mask
        txa
        and     #$08
        beq     :+
        lda     #$20
:       sta     x16_t0
        txa
        and     #$10
        beq     :+
        lda     #$40
:       ora     x16_t0
        sta     x16_t0
        lda     VERA_DC_VIDEO
        and     #$0F
        ora     x16_t0
        sta     VERA_DC_VIDEO
        ; nametable page and BG pattern table
        lda     lat_page
        beq     :+
        lda     #VRAM_MAP1 >> 9
:       sta     VERA_L1_MAPBASE
        lda     lat_ctrl
        and     #$10
        beq     :+
        lda     #((VRAM_BGT + $1000) >> 11) << 2
        bra     :++
:       lda     #(VRAM_BGT >> 11) << 2
:       sta     VERA_L1_TILEBASE
        ; scroll from t: X = coarse X * 8 + fine x, Y = coarse Y * 8 + fine Y
        lda     lat_t
        and     #$1F
        asl     a
        asl     a
        asl     a
        ora     lat_fx
        sta     VERA_L1_HSCROLL_L
        stz     VERA_L1_HSCROLL_H
        lda     lat_t                   ; coarse Y = t bits 9-5
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        sta     x16_t0
        lda     lat_t+1
        and     #$03
        asl     a
        asl     a
        asl     a
        ora     x16_t0                  ; coarse Y (0-31)
        asl     a
        asl     a
        asl     a                       ; * 8
        sta     x16_t0
        lda     lat_t+1
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$07                    ; fine Y
        ora     x16_t0
        sta     VERA_L1_VSCROLL_L
        stz     VERA_L1_VSCROLL_H
        ; split: end the display after the playfield
        lda     #$02
        sta     VERA_CTRL
        lda     lat_split
        bne     :+
        lda     #240
:       sta     VERA_DC_VSTOP
        stz     VERA_CTRL
        lda     oam_dirty
        beq     :+
        stz     oam_dirty
        jsr     oam_convert
:       jmp     box_update

; ----------------------------------------------------------------------------
vera_save:
        lda     VERA_CTRL
        sta     vera_saved
        stz     VERA_CTRL
        lda     VERA_ADDR_L
        sta     vera_saved+1
        lda     VERA_ADDR_M
        sta     vera_saved+2
        lda     VERA_ADDR_H
        sta     vera_saved+3
        lda     #1
        sta     VERA_CTRL
        lda     VERA_ADDR_L
        sta     vera_saved+4
        lda     VERA_ADDR_M
        sta     vera_saved+5
        lda     VERA_ADDR_H
        sta     vera_saved+6
        stz     VERA_CTRL
        rts

vera_restore:
        lda     #1
        sta     VERA_CTRL
        lda     vera_saved+4
        sta     VERA_ADDR_L
        lda     vera_saved+5
        sta     VERA_ADDR_M
        lda     vera_saved+6
        sta     VERA_ADDR_H
        stz     VERA_CTRL
        lda     vera_saved+1
        sta     VERA_ADDR_L
        lda     vera_saved+2
        sta     VERA_ADDR_M
        lda     vera_saved+3
        sta     VERA_ADDR_H
        lda     vera_saved
        sta     VERA_CTRL
        rts

; ============================================================================
; Controllers (KERNAL keyboard joystick 0 and SNES pads 1-2)
; ============================================================================
input_scan:
        ; swap the game's zero page with the KERNAL's
        jsr     zp_swap
        lda     RAM_BANK
        pha
        stz     RAM_BANK
        lda     ps2fetch+1
        beq     :+
        jsr     @ps2
:       jsr     KERNAL_KBDSCAN
@key:   jsr     KERNAL_GETIN            ; empty the keyboard buffer, looking for Esc
        tax
        beq     @keydone
        cmp     #$1B                    ; Esc
        beq     :+
        cmp     #$03                    ; Esc on the X16 keymaps (STOP)
        bne     @key
:       lda     #1
        sta     esc_hit
        bra     @key
@keydone:
        jsr     KERNAL_JOYSCAN
        lda     #0
        jsr     KERNAL_JOYGET
        jsr     snes_to_nes
        sta     x16_t2
        lda     #1
        jsr     KERNAL_JOYGET
        jsr     snes_to_nes
        ora     x16_t2
        sta     x16_t2
        lda     #2
        jsr     KERNAL_JOYGET
        jsr     snes_to_nes
        sta     x16_t3
        jsr     mouse_read
.ifdef DEBUG_MOUSE_FRAME
        ; debug builds: fake mouse movement of DEBUG_MOUSE_DX/DY per frame from game frame N
        lda     game_frames             ; the frame about to run is game_frames + 1
        cmp     #<(DEBUG_MOUSE_FRAME-1)
        lda     game_frames+1
        sbc     #>(DEBUG_MOUSE_FRAME-1)
        bcc     :+
        lda     #<DEBUG_MOUSE_DX
        sta     mouse_dx
        lda     #<DEBUG_MOUSE_DY
        sta     mouse_dy
:
.endif
        lda     x16_t2
        ora     mouse_btn
        sta     x16_t2
        pla
        sta     RAM_BANK
        ; results live in zero page temps that are swapped back below: copy out
        lda     x16_t2
        sta     pad_state
        lda     x16_t3
        sta     pad_state+1
.ifdef DEBUG_INPUT
        ; debug builds: scripted controller 1 input (debug_input.inc)
        ldx     dbg_input_pos
@dbg:   lda     dbg_input_tab+1,x       ; frame high
        cmp     game_frames+1
        bcc     @take
        bne     @dbgdone
        lda     dbg_input_tab,x
        cmp     game_frames
        beq     @take
        bcs     @dbgdone
@take:  lda     dbg_input_tab+2,x
        sta     dbg_input_cur
        inx
        inx
        inx
        stx     dbg_input_pos
        bra     @dbg
@dbgdone:
        lda     dbg_input_cur
        sta     pad_state
.endif
        jmp     zp_swap
@ps2:   jmp     (ps2fetch)

; ----------------------------------------------------------------------------
; Title screen: "ESC TO EXIT" under PRESS START (bank 0 $843E, rendering is off).
x16_title_esc:
        stz     esc_hit                 ; only Esc typed on the title screen counts
        lda     #$23                    ; PRESS START's palette on rows 22-23 (moved up at start-up)
        jsr     x16_ppu_w6
        lda     #$EA
        jsr     x16_ppu_w6
        lda     #$F5
        jsr     x16_ppu_w7
        lda     #$F0
        jsr     x16_ppu_w7
        jsr     x16_ppu_w7
        jsr     x16_ppu_w7
        lda     #$23                    ; row 25, column 11: shares PRESS START's palette
        jsr     x16_ppu_w6
        lda     #$2B
        jsr     x16_ppu_w6
        ldy     #0
@char:  lda     msg_esc,y
        beq     @done
        cmp     #' '
        beq     :+
        sec
        sbc     #$40                    ; letters are tiles 1-26
        bra     :++
:       lda     #0
:       jsr     x16_ppu_w7
        iny
        bra     @char
@done:  rts

msg_esc:
        .byte   "ESC TO EXIT", 0

; Esc on the title screen: undo the start-up and warm-start BASIC.  Called from
; the game's frame (inside the VSYNC interrupt), so it never returns.
x16_exit:
        sei
        ; silence the PSG
        stz     VERA_CTRL
        lda     #<VRAM_PSG
        sta     VERA_ADDR_L
        lda     #>VRAM_PSG
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        ldx     #64
:       stz     VERA_DATA0
        dex
        bne     :-
        ; the display as it was at start-up
        stz     VERA_ADDR_L
        lda     #>VRAM_PALETTE
        sta     VERA_ADDR_M
        ldx     #0
:       lda     saved_pal,x
        sta     VERA_DATA0
        inx
        bne     :-
:       lda     saved_pal+256,x
        sta     VERA_DATA0
        inx
        bne     :-
        ldx     #0
:       lda     saved_dc,x
        sta     VERA_DC_VIDEO,x
        inx
        cpx     #4
        bne     :-
        lda     #$02                    ; DCSEL=1
        sta     VERA_CTRL
        ldx     #0
:       lda     saved_dc+4,x
        sta     VERA_DC_HSTART,x
        inx
        cpx     #4
        bne     :-
        stz     VERA_CTRL
        ldx     #0
:       lda     saved_l1,x
        sta     VERA_L1_CONFIG,x
        inx
        cpx     #7
        bne     :-
        ; the KERNAL's zero page, IRQ handler and banks
        ldx     #2
:       lda     zpsave,x
        sta     $00,x
        inx
        bne     :-
        lda     old_cinv
        sta     CINV
        lda     old_cinv+1
        sta     CINV+1
        stz     ROM_BANK
        lda     saved_bank
        sta     RAM_BANK
        ldx     #$FF
        txs
        lda     mouse_ok
        beq     :+
        sec
        jsr     KERNAL_SCRMODE          ; X, Y = screen size
        lda     #0                      ; mouse off
        jsr     KERNAL_MOUSECFG
:       lda     #$93                    ; clear the screen
        jsr     KERNAL_CHROUT
        cli
        clc                             ; warm start
        jmp     KERNAL_ENTER_BASIC

; ----------------------------------------------------------------------------
; Mouse.  The KERNAL's ps2data_fetch (called above through ps2fetch) also polls
; the mouse once mouse_config has enabled it; ps2data_raw (R47+) then returns
; the raw PS/2 packet, i.e. the movement since the previous packet.  The
; pointer sprite is never shown: mouse_scan is not called.

; Start-up (KERNAL zero page, interrupts off).
mouse_init:
        lda     KERNAL_VERSION
        bpl     :+
        eor     #$FF                    ; prerelease -N: N
        inc     a
:       cmp     #47
        bcc     :+
        sec
        jsr     KERNAL_SCRMODE          ; X, Y = screen size in 8px units
        lda     #$FF                    ; enable the mouse, keep the pointer shape
        jsr     KERNAL_MOUSECFG
        lda     #1
        sta     mouse_ok
:       rts

; Every VSYNC, KERNAL zero page: add the latest packet to mouse_dx/dy.
mouse_read:
        lda     mouse_ok
        beq     @done
        lda     #9                      ; ps2data_raw
        jsr     KERNAL_EXTAPI
.ifdef DEBUG_MOUSE_PACKET
        ; debug builds: a fixed packet (DEBUG_MOUSE_P0-P2) every VSYNC
        lda     #DEBUG_MOUSE_P0
        sta     $02
        lda     #DEBUG_MOUSE_P1
        sta     $03
        lda     #DEBUG_MOUSE_P2
        sta     $04
        ldx     #3
.endif
        cpx     #3
        bcc     @done
        ; r0L = Yovf Xovf Ysign Xsign 1 M R L, r0H = X movement, r1L = Y movement (up)
        lda     $02
        and     #$03
        lsr     a                       ; C = left
        ror     a                       ; bit 7 = left (NES A), bit 0 = right
        bcc     :+
        ora     #$40                    ; right = NES B
:       and     #$C0
        sta     mouse_btn
        lda     $02
        and     #$10                    ; X sign
        ldx     $03
        jsr     @clamp
        ldx     mouse_dx
        jsr     @add
        sta     mouse_dx
        lda     $02
        and     #$20                    ; Y sign
        ldx     $04
        jsr     @clamp
        eor     #$FF                    ; up -> down
        inc     a
        ldx     mouse_dy
        jsr     @add
        sta     mouse_dy
@done:  rts
; 9-bit movement (A = sign bit, X = low byte) -> A in -127..127
@clamp: cmp     #1                      ; C = negative
        txa
        bcs     @neg
        bpl     :+
        lda     #$7F
:       rts
@neg:   bmi     :+
        lda     #$81
:       cmp     #$81
        bcs     :+
        lda     #$81
:       rts
; A = X + A, saturated to -127..127
@add:   stx     x16_t0
        clc
        adc     x16_t0
        bvc     :+
        lda     #$7F                    ; overflow: the sum has the sign of the operands
        bit     x16_t0
        bpl     :+
        lda     #$81
:       cmp     #$80
        bne     :+
        lda     #$81
:       rts

; Called by the game (bank 0 $C1AF, player 1 controllable): turn the movement
; since the last frame into accelerations mouse_e = dy - dx, mouse_d = dy + dx,
; each limited to +-MOUSE_MAX (the d-pad gives 9 per axis).  Returns Z set if
; both are zero.  Preserves X.
MOUSE_MAX = 32
x16_mouse_take:
        phx
        lda     mouse_dx
        eor     #$FF                    ; -dx
        inc     a
        jsr     @axis
        sta     mouse_e
        lda     mouse_dx
        jsr     @axis
        sta     mouse_d
        stz     mouse_dx
        stz     mouse_dy
        plx
        lda     mouse_e
        ora     mouse_d
        rts
; A = clamp(mouse_dy + A); both operands in -127..127
@axis:  ldx     #0
        cmp     #$80
        bcc     :+
        dex                             ; X = sign extension of A
:       clc
        adc     mouse_dy
        tay                             ; low byte of the sum
        txa
        ldx     mouse_dy
        bpl     :+
        dec     a                       ; sign extension of mouse_dy
:       adc     #0                      ; A = high byte of the sum
        bmi     @negsum
        bne     @max                    ; >= 256
        cpy     #MOUSE_MAX+1
        bcs     @max
        tya
        rts
@max:   lda     #MOUSE_MAX
        rts
@negsum:
        cmp     #$FF
        bne     @min                    ; < -256
        cpy     #<-MOUSE_MAX
        bcc     @min
        tya
        rts
@min:   lda     #<-MOUSE_MAX
        rts

; Called by the game's name-entry screen (bank 0 $90D2, before it looks up the
; letter under the cursor marble): the mouse moves the marble freely over the
; letter grid (cells $18 apart, 0-$90 across, 0-$48 down) and stops any glide.
; A marble the mouse left between letters snaps to the nearest one when A or
; the d-pad is used (even while the mouse moves), so the game then acts on
; that letter.  Without mouse
; movement this does nothing: the d-pad only rests the marble on a letter.
; Game zero page; A, X, Y free.
NAME_CURSOR_X   = $2E
NAME_CURSOR_Y   = $2F
NAME_JOY_HELD   = $0B
NAME_JOY_PRESS  = $0C
x16_name_mouse:
        lda     mouse_dx
        ora     mouse_dy
        beq     @still
        lda     NAME_CURSOR_X
        ldx     mouse_dx
        ldy     #$90
        jsr     @move
        sta     NAME_CURSOR_X
        lda     NAME_CURSOR_Y
        ldx     mouse_dy
        ldy     #$48
        jsr     @move
        sta     NAME_CURSOR_Y
        stz     mouse_dx
        stz     mouse_dy
        stz     RAM($0410)              ; cursor velocity
        stz     RAM($0418)
@still: lda     RAM($0410)
        ora     RAM($0418)
        bne     @done                   ; gliding (d-pad): leave it to the game
        lda     NAME_JOY_PRESS
        bmi     @snap                   ; A
        lda     NAME_JOY_HELD
        and     #$0F
        beq     @done                   ; no d-pad
@snap:  lda     NAME_CURSOR_X
        jsr     @near
        sta     NAME_CURSOR_X
        lda     NAME_CURSOR_Y
        jsr     @near
        sta     NAME_CURSOR_Y
@done:  rts
; A = clamp(A + X, 0, Y); A unsigned, X signed
@move:  stx     x16_t0
        cpx     #$80
        bcs     @neg
        clc
        adc     x16_t0
        bcs     @top
        sty     x16_t0
        cmp     x16_t0
        bcc     @ok
@top:   tya
@ok:    rts
@neg:   clc
        adc     x16_t0
        bcs     @ok                     ; no borrow: still >= 0
        lda     #0
        rts
; A = nearest multiple of $18
@near:  clc
        adc     #$0C
        stz     x16_t1
:       cmp     #$18
        bcc     :+
        sbc     #$18                    ; C = 1 from cmp
        tax
        lda     x16_t1
        adc     #$17                    ; C = 1 (no borrow): +$18
        sta     x16_t1
        txa
        bra     :-
:       lda     x16_t1
        rts

zp_swap:
        ldx     #2
:       lda     $00,x
        ldy     zpsave,x
        sta     zpsave,x
        sty     $00,x
        inx
        bne     :-
        rts

; KERNAL joystick_get: A = B Y Sel St U D L R, X = A X L R 1 1 1 1 (active low),
; Y = $FF if not present.  NES order is A B Sel St U D L R.
; NES A = SNES A or X, NES B = SNES B or Y (keyboard: X/Ctrl = A, Z/Alt = B,
; Enter = Start, Left Shift = Select, cursor keys = d-pad).
snes_to_nes:
        cpy     #$00
        bne     @none
        eor     #$FF
        sta     x16_t0
        and     #$3F                    ; Sel St U D L R
        sta     x16_t1
        lda     x16_t0
        and     #$C0                    ; SNES B or Y -> NES B
        beq     :+
        lda     #$40
        tsb     x16_t1
:       txa
        eor     #$FF
        and     #$C0                    ; SNES A or X -> NES A
        beq     :+
        lda     #$80
        tsb     x16_t1
:       lda     x16_t1
        rts
@none:  lda     #0
        rts

; ============================================================================
; Zero-page reads through a pointer (the game reads past the end of some
; course data with a null pointer).  X16 $00/$01 are the bank registers, so
; such reads go through a copy holding the NES values.  Preserves X, Y.
x16_zp_mirror:
        phx
        lda     nes_mapper
        sta     x16_zp_mirror_buf
        lda     nes_ppuctrl
        sta     x16_zp_mirror_buf+1
        ldx     #2
:       lda     $00,x
        sta     x16_zp_mirror_buf,x
        inx
        cpx     #$40                    ; enough for every use in the game
        bne     :-
        plx
        rts

.segment "BSS"
.align 256
x16_zp_mirror_buf:
        .res    256
.segment "CODE"

; ============================================================================
; Hardware I/O ($4000-$4017)
; ============================================================================
; X = register ($00-$17), A = value
x16_io_write:
        cpx     #$14
        beq     oam_dma
        cpx     #$16
        beq     @joy
        cpx     #$18
        bcs     @rts
        jmp     apu_write
@joy:   lsr     a                       ; strobe: latch on the falling edge
        bcs     :+
        lda     pad_strobe
        beq     :+
        lda     pad_state
        sta     pad_shift
        lda     pad_state+1
        sta     pad_shift+1
        lda     #0
:       rol     a
        sta     pad_strobe
@rts:   rts

; X = register, returns A
x16_io_read:
        cpx     #$16
        beq     @joy1
        cpx     #$17
        beq     @joy2
        lda     #0
        rts
@joy1:  asl     pad_shift
        lda     #0
        rol     a
        ora     #$40
        rts
@joy2:  asl     pad_shift+1
        lda     #0
        rol     a
        ora     #$40
        rts

; ----------------------------------------------------------------------------
; OAM DMA: snapshot the NES OAM page (NES $0200).  It is converted to VERA
; sprite attributes at the next VSYNC, with the frame's final PPUCTRL.
oam_dma:
        ldx     #0
:       lda     NESRAM,x
        sta     oam_copy,x
        inx
        bne     :-
        lda     #1
        sta     oam_dirty
        rts

oam_convert:
        lda     #<VRAM_SPRATTR
        sta     VERA_ADDR_L
        lda     #>VRAM_SPRATTR
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        lda     lat_ctrl
        and     #$08                    ; sprite pattern table
        lsr     a
        lsr     a
        lsr     a
        ora     #VRAM_SPT >> 13
        sta     x16_t1                  ; address bits 16-13
        ldx     #0
@spr:   lda     oam_copy+1,x            ; tile
        sta     VERA_DATA0
        lda     x16_t1
        sta     VERA_DATA0
        lda     oam_copy+3,x            ; x
        sta     VERA_DATA0
        stz     VERA_DATA0
        lda     oam_copy,x              ; y
        cmp     #$EF
        bcs     @hide
        inc     a
        sta     VERA_DATA0
        stz     VERA_DATA0
        lda     oam_copy+2,x            ; attributes: VHP...pp
        tay
        and     #$20                    ; behind background?
        beq     :+
        lda     #$04                    ; z = 1
        bra     :++
:       lda     #$0C                    ; z = 3
:       sta     x16_t0
        tya
        asl     a                       ; C = vflip
        lda     x16_t0
        bcc     :+
        ora     #$02
:       sta     x16_t0
        tya
        and     #$40                    ; hflip
        beq     :+
        lda     #$01
:       ora     x16_t0
        sta     VERA_DATA0
        tya
        and     #$03
        ora     #$04                    ; palettes 4-7
        sta     VERA_DATA0
        bra     @next
@hide:  stz     VERA_DATA0
        stz     VERA_DATA0
        stz     VERA_DATA0              ; z = 0: disabled
        stz     VERA_DATA0
@next:  inx
        inx
        inx
        inx
        bne     @spr
        rts

; ============================================================================
; NES mapper and far calls
; ============================================================================
; A = value written to $8000 (bits 0-2 bank: irrelevant here, bit 4 nametable page)
x16_mapper_w:
        php
        pha
        and     #$10
        beq     :+
        lda     #1
:       cmp     nes_page
        beq     :+
        sta     nes_page
        phx
        phy
        jsr     ppu_setup
        ply
        plx
:       pla
        plp
        rts

; NES FarCall ($FF69): A = offset into bank Y's JMP table at $8000.
x16_farcall:
        sta     farcall_ptr             ; keep the NES variable up to date
        lda     nes_mapper
        pha
        and     #$10
        sta     nes_mapper
        tya
        ora     nes_mapper
        sta     nes_mapper
        lda     farcall_ptr
        clc
        adc     fartab_lo,y
        sta     farcall_vec
        lda     fartab_hi,y
        adc     #0
        sta     farcall_vec+1
        lda     nes_mapper
        jsr     @go
        pla
        sta     nes_mapper
        rts
@go:    jmp     (farcall_vec)

fartab_lo:
        .byte   0, <fartab_b1, <fartab_b2, <fartab_b3
fartab_hi:
        .byte   0, >fartab_b1, >fartab_b2, >fartab_b3

; x16_bank_N: map window N (NES bank data) at $A000.  Preserves A, X, Y, C, V.
.repeat 32, I
        .export .ident(.sprintf("x16_bank_%d", I + 1))
.ident(.sprintf("x16_bank_%d", I + 1)):
        pha
        lda     #I + 1
        sta     RAM_BANK
        pla
        rts
.endrep

; ============================================================================
; PPU registers
; ============================================================================
; Register writes preserve A, X, Y and flags (they replace sta/stx/sty).

x16_ppu_wx0:
        php
        pha
        txa
        jsr     x16_ppu_w0
        pla
        plp
        rts

x16_ppu_wx6:
        php
        pha
        txa
        jsr     x16_ppu_w6
        pla
        plp
        rts

x16_ppu_wy6:
        php
        pha
        tya
        jsr     x16_ppu_w6
        pla
        plp
        rts

x16_ppu_wx7:
        php
        pha
        txa
        jsr     x16_ppu_w7
        pla
        plp
        rts

x16_ppu_wy7:
        php
        pha
        tya
        jsr     x16_ppu_w7
        pla
        plp
        rts

; PPUCTRL
x16_ppu_w0:
        php
        pha
        sta     ppu_ctrl
        and     #$03                    ; t: nametable select bits 10-11
        asl     a
        asl     a
        sta     x16_t0
        lda     ppu_t+1
        and     #$F3
        ora     x16_t0
        sta     ppu_t+1
        lda     ppu_ctrl
        and     #$04
        beq     :+
        lda     #31
:       inc     a                       ; 1 or 32
        cmp     ppu_inc
        beq     :+
        sta     ppu_inc
        phx
        phy
        jsr     ppu_setup
        ply
        plx
:       pla
        plp
        rts

; PPUMASK
x16_ppu_w1:
        sta     ppu_mask
x16_ppu_w2:
x16_ppu_w3:
x16_ppu_w4:
        rts

; PPUSCROLL
x16_ppu_w5:
        php
        pha
        phx
        ldx     ppu_w
        bne     @y
        tax
        and     #$07
        sta     ppu_fx
        txa
        lsr     a
        lsr     a
        lsr     a
        sta     x16_t0
        lda     ppu_t
        and     #$E0
        ora     x16_t0
        sta     ppu_t
        inc     ppu_w
        bra     @out
@y:     stz     ppu_w
        tax
        ; t = (t & $8C1F) | (v & 7) << 12 | (v & $F8) << 2
        and     #$07
        asl     a
        asl     a
        asl     a
        asl     a
        sta     x16_t0                  ; fine Y in bits 4-6 of the high byte
        txa
        and     #$C0
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        lsr     a                       ; coarse Y bits 3-4 -> t bits 8-9
        ora     x16_t0
        sta     x16_t0
        lda     ppu_t+1
        and     #$0C
        ora     x16_t0
        sta     ppu_t+1
        txa
        and     #$38                    ; coarse Y bits 0-2 -> t bits 5-7
        asl     a
        asl     a
        sta     x16_t0
        lda     ppu_t
        and     #$1F
        ora     x16_t0
        sta     ppu_t
@out:   plx
        pla
        plp
        rts

; PPUADDR
x16_ppu_w6:
        php
        pha
        phx
        phy
        ldx     ppu_w
        bne     @lo
        and     #$3F
        sta     ppu_t+1
        inc     ppu_w
        bra     @out
@lo:    stz     ppu_w
        sta     ppu_t
        sta     ppu_v
        lda     ppu_t+1
        sta     ppu_v+1
        jsr     ppu_setup
@out:   ply
        plx
        pla
        plp
        rts

; PPUSTATUS (returns A with N/Z like lda; preserves X, Y, C, V)
x16_ppu_r2:
        php
        stz     ppu_w
        ; With IRQs masked (the game is inside its NMI handler with NMI turned off,
        ; polling for vblank) the VSYNC interrupt cannot run: take it here instead.
        pla
        pha
        and     #$04
        beq     @flag
        lda     VERA_ISR
        and     #$01
        beq     @flag
        sta     VERA_ISR
        lda     #$80
        sta     ppu_vbl
        phx
        phy
        lda     RAM_BANK
        pha
        jsr     vera_save
        jsr     display_update
        jsr     vera_restore
        pla
        sta     RAM_BANK
        ply
        plx
@flag:  lda     ppu_vbl
        stz     ppu_vbl
        ora     #$40                    ; sprite 0 hit: always reported
        plp
        ora     #0
        rts

; PPUDATA write: dispatch on the address region set up by ppu_setup
x16_ppu_w7:
        jmp     (ppu_wvec)

; ----------------------------------------------------------------------------
; Work out where PPUDATA writes at ppu_v go.  Clobbers A, X, Y.
ppu_setup:
        lda     ppu_v+1
        and     #$3F
        cmp     #$20
        bcc     @chr
        cmp     #$3F
        bcs     @pal
        and     #$03
        sta     x16_t1                  ; offset in the nametable: t1:t0 ($000-$3FF)
        lda     ppu_v
        sta     x16_t0
        lda     x16_t1
        cmp     #$03
        bcc     @nt
        lda     x16_t0
        cmp     #$C0
        bcc     @nt
        lda     #<ppu_w_attr
        ldx     #>ppu_w_attr
        bra     @vec
@chr:   lda     #<ppu_w_chr
        ldx     #>ppu_w_chr
        bra     @vec
@pal:   lda     #<ppu_w_pal
        ldx     #>ppu_w_pal
@vec:   sta     ppu_wvec
        stx     ppu_wvec+1
        rts
@nt:    ; VRAM address of the map entry: page * $1000 + offset * 2
        lda     x16_t0
        asl     a
        sta     x16_t2
        lda     x16_t1
        rol     a
        ldx     nes_page
        beq     :+
        ora     #>VRAM_MAP1
:       sta     x16_t3
        ldy     #$20                    ; increment 2 (NES +1)
        lda     ppu_inc
        cmp     #1
        beq     :+
        ldy     #$70                    ; increment 64 (NES +32)
:
        stz     VERA_CTRL
        lda     x16_t2
        sta     VERA_ADDR_L
        lda     x16_t3
        sta     VERA_ADDR_M
        sty     VERA_ADDR_H
        ; second port: the duplicate row 30 rows further down (+30*64 bytes)
        lda     #1
        sta     VERA_CTRL
        lda     x16_t2
        clc
        adc     #<(30*64)
        sta     VERA_ADDR_L
        lda     x16_t3
        adc     #>(30*64)
        sta     VERA_ADDR_M
        sty     VERA_ADDR_H
        stz     VERA_CTRL
        ; writes left before the attribute area ($3C0 - offset, or rows for +32)
        sec
        lda     #<$3C0
        sbc     x16_t0
        sta     x16_t2
        lda     #>$3C0
        sbc     x16_t1
        sta     x16_t3
        lda     ppu_inc
        cmp     #1
        beq     @cnt1
        lda     x16_t2                  ; rows: (n + 31) / 32
        clc
        adc     #31
        sta     x16_t2
        lda     x16_t3
        adc     #0
        lsr     a
        ror     x16_t2
        lsr     a
        ror     x16_t2
        lsr     a
        ror     x16_t2
        lsr     a
        ror     x16_t2
        lsr     a
        ror     x16_t2
        lda     x16_t2
        bra     @cnt
@cnt1:  lda     x16_t3
        beq     :+
        lda     #$FF                    ; more than 255: re-setup after 255 writes
        bra     @cnt
:       lda     x16_t2
@cnt:   sta     ppu_count
        lda     #<ppu_w_nt
        ldx     #>ppu_w_nt
        jmp     @vec

; advance ppu_v by the increment (keeps flags / registers except A)
.macro PPU_ADVANCE
        lda     ppu_v
        clc
        adc     ppu_inc
        sta     ppu_v
        bcc     :+
        inc     ppu_v+1
:
.endmacro

; --- nametable byte
ppu_w_nt:
        sta     VERA_DATA0
        sta     VERA_DATA1
        php
        pha
        PPU_ADVANCE
        dec     ppu_count
        bne     :+
        phx
        phy
        jsr     ppu_setup
        ply
        plx
:       pla
        plp
        rts

; --- pattern table byte (CHR-RAM)
ppu_w_chr:
        php
        pha
        phx
        phy
        sta     x16_t2                  ; value
        ; x16_tptr may hold the game's translated source pointer: loops like
        ; bank 1 $DD4E do lda (ptr),y / sta PPUDATA several times per mapping
        lda     x16_tptr
        pha
        lda     x16_tptr+1
        pha
        lda     RAM_BANK
        pha
        lda     #CHR_SHADOW_BANK
        sta     RAM_BANK
        ; shadow copy at $A000 + (v & $1FFF)
        lda     ppu_v
        sta     x16_tptr
        lda     ppu_v+1
        and     #$1F
        ora     #$A0
        sta     x16_tptr+1
        lda     x16_t2
        sta     (x16_tptr)
        ; the two plane bytes of this row
        lda     ppu_v
        and     #$F7
        sta     x16_tptr
        lda     (x16_tptr)
        tax                             ; plane 0
        ldy     #8
        lda     (x16_tptr),y
        tay                             ; plane 1
        pla
        sta     RAM_BANK
        pla
        sta     x16_tptr+1
        pla
        sta     x16_tptr
        ; 2bpp: VRAM_BGT + (v & $1FF0) + row * 2
        stz     VERA_CTRL
        lda     ppu_v
        and     #$07
        asl     a
        sta     x16_t0
        lda     ppu_v
        and     #$F0
        ora     x16_t0
        sta     VERA_ADDR_L
        lda     ppu_v+1
        and     #$1F
        clc
        adc     #>VRAM_BGT
        sta     VERA_ADDR_M
        lda     #$10                    ; increment 1, bank 0
        sta     VERA_ADDR_H
        lda     chr_h0,x
        ora     chr_h1,y
        sta     VERA_DATA0
        sta     x16_t2                  ; 2bpp left half
        lda     chr_l0,x
        ora     chr_l1,y
        sta     VERA_DATA0
        sta     x16_t3                  ; 2bpp right half
        ; 4bpp: VRAM_SPT + (v & $1FF0) * 2 + row * 4
        lda     ppu_v
        and     #$07
        asl     a
        asl     a
        sta     x16_t0
        lda     ppu_v
        and     #$F0
        asl     a
        ora     x16_t0
        sta     VERA_ADDR_L
        lda     ppu_v+1
        and     #$1F
        rol     a
        clc
        adc     #>VRAM_SPT
        sta     VERA_ADDR_M
        ldx     x16_t2
        lda     chr_4a,x
        sta     VERA_DATA0
        lda     chr_4b,x
        sta     VERA_DATA0
        ldx     x16_t3
        lda     chr_4a,x
        sta     VERA_DATA0
        lda     chr_4b,x
        sta     VERA_DATA0
        PPU_ADVANCE
        lda     ppu_v+1
        and     #$3F
        cmp     #$20
        bcc     :+
        jsr     ppu_setup               ; left the pattern tables
:       ply
        plx
        pla
        plp
        rts

; --- attribute byte
ppu_w_attr:
        php
        pha
        phx
        phy
        sta     x16_t2                  ; value
        lda     ppu_v
        and     #$3F
        sta     x16_t3                  ; attribute index
        ldx     nes_page
        beq     :+
        ora     #$40
:       tax
        lda     x16_t2
        sta     attr_shadow,x
        ldx     nes_page
        lda     x16_t3
        jsr     apply_attr
        PPU_ADVANCE
        lda     ppu_v
        and     #$C0
        cmp     #$C0
        beq     :+
        jsr     ppu_setup               ; wrapped into the next nametable
:       ply
        plx
        pla
        plp
        rts

; --- palette byte
ppu_w_pal:
        php
        pha
        phx
        phy
        and     #$3F
        tay                             ; NES colour
        lda     ppu_v
        and     #$1F
        tax
        lda     ppu_v
        and     #$03
        bne     :+
        txa
        and     #$0F
        bne     @shadow                 ; $3F04/08/0C: not displayed
        ldx     #0                      ; $3F00 / $3F10: backdrop
:       tya
        sta     pal_shadow,x
        ; VERA index: BG palette p -> 16p + c, sprite palette p -> 64 + 16p + c
        txa
        and     #$03
        sta     x16_t0
        txa
        and     #$1C
        asl     a
        asl     a                       ; (index >> 2) * 16
        ora     x16_t0
        asl     a                       ; * 2 bytes
        stz     VERA_CTRL
        sta     VERA_ADDR_L
        lda     #>VRAM_PALETTE
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        lda     nes_pal_gb,y
        sta     VERA_DATA0
        lda     nes_pal_r,y
        sta     VERA_DATA0
        bra     @adv
@shadow:
        tya
        sta     pal_shadow,x
@adv:   PPU_ADVANCE
        ply
        plx
        pla
        plp
        rts

; PPUDATA read (buffered like the NES).  Returns A with N/Z; preserves X, Y, C, V.
x16_ppu_r7:
        php
        phx
        phy
        lda     ppu_readbuf
        pha
        lda     ppu_v+1
        and     #$3F
        cmp     #$20
        bcc     @chr
        cmp     #$3F
        bcs     @pal
        ; nametable / attribute
        lda     ppu_v+1
        and     #$03
        cmp     #$03
        bcc     @nt
        lda     ppu_v
        cmp     #$C0
        bcc     @nt
        and     #$3F
        ldx     nes_page
        beq     :+
        ora     #$40
:       tax
        lda     attr_shadow,x
        bra     @store
@nt:    lda     ppu_v
        asl     a
        stz     VERA_CTRL
        sta     VERA_ADDR_L
        lda     ppu_v+1
        and     #$03
        rol     a
        ldx     nes_page
        beq     :+
        ora     #>VRAM_MAP1
:       sta     VERA_ADDR_M
        stz     VERA_ADDR_H
        lda     VERA_DATA0
        bra     @store
@pal:   lda     ppu_v
        and     #$1F
        tax
        lda     pal_shadow,x
        bra     @store
@chr:   lda     x16_tptr                ; may be the game's live pointer (see ppu_w_chr)
        pha
        lda     x16_tptr+1
        pha
        lda     RAM_BANK
        pha
        lda     #CHR_SHADOW_BANK
        sta     RAM_BANK
        lda     ppu_v
        sta     x16_tptr
        lda     ppu_v+1
        and     #$1F
        ora     #$A0
        sta     x16_tptr+1
        lda     (x16_tptr)
        tax
        pla
        sta     RAM_BANK
        pla
        sta     x16_tptr+1
        pla
        sta     x16_tptr
        txa
@store: sta     ppu_readbuf
        PPU_ADVANCE
        jsr     ppu_setup
        pla
        ply
        plx
        plp
        ora     #0
        rts

; ----------------------------------------------------------------------------
; Rewrite the palette bits (map entry byte 1) of the 4x4 tiles covered by
; attribute byte A of nametable page X.  Byte 1 = palette << 4 | box bit.
apply_attr:
        sta     x16_t3                  ; attribute index
        stx     attr_page
        tay
        txa
        beq     :+
        tya
        ora     #$40
        tay
:       lda     attr_shadow,y
        sta     attr_val
        ; first tile row / column
        lda     x16_t3
        and     #$38
        lsr     a                       ; (idx >> 3) * 4
        sta     attr_row
        lda     x16_t3
        and     #$07
        asl     a
        asl     a
        sta     attr_col
        ldy     #0                      ; row within the 4x4 block
@row:   tya
        clc
        adc     attr_row
        cmp     #30
        bcc     :+
        jmp     @done
:
        sta     attr_r
        ; VRAM address of (r, col) byte 1: page*$1000 + (r*32 + col)*2 + 1
        lsr     a                       ; r * 64: high byte r >> 2, low byte (r & 3) << 6
        lsr     a
        sta     attr_hi
        lda     attr_r
        and     #$03
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        sta     attr_lo
        lda     attr_col
        asl     a
        ora     #1
        ora     attr_lo
        sta     attr_lo
        lda     attr_page
        beq     :+
        lda     attr_hi
        ora     #>VRAM_MAP1
        sta     attr_hi
:       stz     VERA_CTRL
        lda     attr_lo
        sta     VERA_ADDR_L
        lda     attr_hi
        sta     VERA_ADDR_M
        lda     #$20                    ; increment 2
        sta     VERA_ADDR_H
        lda     #1
        sta     VERA_CTRL
        lda     attr_lo
        clc
        adc     #<(30*64)
        sta     VERA_ADDR_L
        lda     attr_hi
        adc     #>(30*64)
        sta     VERA_ADDR_M
        lda     #$20
        sta     VERA_ADDR_H
        stz     VERA_CTRL
        ; palette for the left / right halves of this row
        lda     attr_val
        cpy     #2
        bcc     :+
        lsr     a
        lsr     a
        lsr     a
        lsr     a
:       sta     attr_q                  ; bits 1-0 left, 3-2 right
        jsr     box_row_range           ; row_c0..row_c1: columns using the $1000 table
        ldx     #0                      ; column within the block
@col:   lda     attr_q
        cpx     #2
        bcc     :+
        lsr     a
        lsr     a
:       and     #$03
        asl     a
        asl     a
        asl     a
        asl     a
        sta     x16_t0
        ; box bit
        txa
        clc
        adc     attr_col
        cmp     row_c0
        bcc     @nobox
        cmp     row_c1
        beq     :+
        bcs     @nobox
:       lda     x16_t0
        ora     #1
        sta     x16_t0
@nobox: lda     x16_t0
        sta     VERA_DATA0
        sta     VERA_DATA1
        inx
        cpx     #4
        bne     @col
        iny
        cpy     #4
        beq     :+
        jmp     @row
:
@done:  rts

.segment "GOLDEN"
attr_page:      .res 1
attr_val:       .res 1
attr_row:       .res 1
attr_col:       .res 1
attr_r:         .res 1
attr_lo:        .res 1
attr_hi:        .res 1
attr_q:         .res 1
row_c0:         .res 1
row_c1:         .res 1
.segment "CODE"

; ----------------------------------------------------------------------------
; Message boxes.  On the NES the game switches the background pattern table
; to $1000 and back in the middle of scanlines (cycle-timed PPUCTRL writes) so
; that the message text comes from the second pattern table.  Here the tiles
; inside the box get tile-index bit 8 instead (tiles 256-511 = NES $1000).
;   box 0: lines 53-78, columns 3-28 (all messages 0-5)
;   box 1: lines 117-134, all columns (message 4 only; position estimated
;          from the game's delay loops)
BOXES = 2
box_c0_tab:     .byte   3, 0
box_c1_tab:     .byte   28, 31
box_l0_tab:     .byte   53, 117
box_l1_tab:     .byte   78, 134

box_update:
        ldx     #0
:       phx
        jsr     box_update_one
        plx
        inx
        cpx     #BOXES
        bne     :-
        rts

; X = box.  Rows with at least half their lines inside the box's band.
box_update_one:
        lda     lat_box
        and     bitmask,x
        beq     @want_off
        lda     box_l0_tab,x
        clc
        adc     #4
        jsr     line_to_row
        sta     x16_t2
        lda     box_l1_tab,x
        sec
        sbc     #3
        jsr     line_to_row
        sta     x16_t3
        lda     bx_on,x
        beq     @set
        lda     bx_page,x
        cmp     lat_page
        bne     @change
        lda     bx_r0,x
        cmp     x16_t2
        bne     @change
        lda     bx_r1,x
        cmp     x16_t3
        beq     @rts
@change:
        jsr     box_clear
@set:   lda     lat_page
        sta     bx_page,x
        lda     x16_t2
        sta     bx_r0,x
        lda     x16_t3
        sta     bx_r1,x
        lda     #1
        sta     bx_on,x
        jmp     box_redraw
@want_off:
        lda     bx_on,x
        beq     @rts
        jmp     box_clear
@rts:   rts

; A = screen line -> NES nametable row shown there (with the current scroll)
line_to_row:
        clc
        adc     VERA_L1_VSCROLL_L
        sta     x16_t0
        lda     #0
        adc     #0
        lsr     a                       ; C = bit 8 of the sum
        lda     x16_t0
        ror     a
        lsr     a
        lsr     a                       ; sum / 8
:       cmp     #30
        bcc     :+
        sbc     #30
        bra     :-
:       rts

; X = box: take it off the tile map / put it on (re-apply its attribute rows)
box_clear:
        stz     bx_on,x
box_redraw:
        lda     bx_r0,x
        and     #$FC
        asl     a                       ; first attribute index of that row
        sta     box_attr
        lda     bx_r1,x
        and     #$FC
        asl     a
        clc
        adc     #8
        sta     box_attr_end
        lda     bx_page,x
        sta     box_pg
@loop:  phx
        lda     box_attr
        ldx     box_pg
        jsr     apply_attr
        plx
        inc     box_attr
        lda     box_attr
        cmp     box_attr_end
        bcc     @loop
        rts

; For tile row attr_r of attr_page: row_c0..row_c1 = columns inside a box
; (row_c0 = $FF if none).  Preserves X, Y.
box_row_range:
        phx
        lda     #$FF
        sta     row_c0
        stz     row_c1
        ldx     #BOXES - 1
@box:   lda     bx_on,x
        beq     @next
        lda     bx_page,x
        cmp     attr_page
        bne     @next
        lda     attr_r
        cmp     bx_r0,x
        bcc     @next
        cmp     bx_r1,x
        beq     :+
        bcs     @next
:       lda     box_c0_tab,x
        cmp     row_c0
        bcs     :+
        sta     row_c0
:       lda     box_c1_tab,x
        cmp     row_c1
        bcc     @next
        sta     row_c1
@next:  dex
        bpl     @box
        plx
        rts

.segment "GOLDEN"
box_attr:       .res 1
box_attr_end:   .res 1
box_pg:         .res 1
.segment "CODE"


; ============================================================================
; APU -> VERA PSG
; ============================================================================
; X = register ($00-$17), A = value
apu_write:
        sta     apu_regs,x
        cpx     #$03
        beq     @sq_hi
        cpx     #$07
        beq     @sq_hi
        cpx     #$01
        beq     @sweep
        cpx     #$05
        beq     @sweep
        cpx     #$0B
        beq     @tri_hi
        cpx     #$0F
        beq     @noise_hi
        cpx     #$15
        beq     @enable
        rts
@sweep: txa
        lsr     a
        lsr     a
        tax
        lda     #1
        sta     apu_sweep_reload,x
        rts
@sq_hi: txa
        lsr     a
        lsr     a
        tax                             ; channel 0/1
        bra     @len
@tri_hi:
        lda     #1
        sta     apu_lin_reload
        ldx     #2
        bra     @len
@noise_hi:
        ldx     #3
@len:   lda     apu_enable
        and     bitmask,x
        beq     :+
        lda     apu_regs_hi,x
        tay
        lda     apu_regs,y
        lsr     a
        lsr     a
        lsr     a
        tay
        lda     length_table,y
        sta     apu_len,x
:       lda     #1
        sta     apu_env_start,x
        rts
@enable:
        sta     apu_enable
        ldx     #3
:       lda     apu_enable
        and     bitmask,x
        bne     :+
        stz     apu_len,x
:       dex
        bpl     :--
        rts

bitmask:        .byte   $01, $02, $04, $08
apu_regs_hi:    .byte   $03, $07, $0B, $0F

length_table:
        .byte   10,254, 20,  2, 40,  4, 80,  6,160,  8, 60, 10, 14, 12, 26, 14
        .byte   12, 16, 24, 18, 48, 20, 96, 22,192, 24, 72, 26, 16, 28, 32, 30

; Called once per frame: clock envelopes / counters, then program the PSG.
apu_update:
        ; four quarter-frame clocks (envelopes, linear counter), two half-frame
        ; clocks (length counters, sweeps)
        jsr     apu_quarter
        jsr     apu_quarter
        jsr     apu_half
        jsr     apu_quarter
        jsr     apu_quarter
        jsr     apu_half
        ; program the PSG through data port 1
        lda     #1
        sta     VERA_CTRL
        lda     #<VRAM_PSG
        sta     VERA_ADDR_L
        lda     #>VRAM_PSG
        sta     VERA_ADDR_M
        lda     #$11
        sta     VERA_ADDR_H
        ldx     #0
        jsr     psg_square
        ldx     #1
        jsr     psg_square
        jsr     psg_triangle
        jsr     psg_noise
        stz     VERA_CTRL
        rts

apu_quarter:
        ldx     #3
@env:   cpx     #2
        beq     @next                   ; triangle has no envelope
        lda     apu_env_start,x
        beq     @clk
        stz     apu_env_start,x
        lda     #15
        sta     apu_env_vol,x
        bra     @reload
@clk:   dec     apu_env_div,x
        bpl     @next
        lda     apu_env_vol,x
        beq     @loop
        dec     apu_env_vol,x
        bra     @reload
@loop:  ldy     apu_regs_lo,x
        lda     apu_regs,y
        and     #$20
        beq     @reload
        lda     #15
        sta     apu_env_vol,x
@reload:
        ldy     apu_regs_lo,x
        lda     apu_regs,y
        and     #$0F
        sta     apu_env_div,x
@next:  dex
        bpl     @env
        ; triangle linear counter
        lda     apu_lin_reload
        beq     :+
        lda     apu_regs+8
        and     #$7F
        sta     apu_lin
        bra     :++
:       lda     apu_lin
        beq     :+
        dec     apu_lin
:       lda     apu_regs+8
        bmi     :+
        stz     apu_lin_reload
:       rts

apu_regs_lo:    .byte   $00, $04, $08, $0C

apu_half:
        ; length counters (halted by bit 5 of reg 0, bit 7 for the triangle)
        ldx     #3
@len:   lda     apu_len,x
        beq     @n
        ldy     apu_regs_lo,x
        lda     apu_regs,y
        and     halt_mask,x
        bne     @n
        dec     apu_len,x
@n:     dex
        bpl     @len
        ; sweeps
        ldx     #1
@sw:    lda     apu_sweep_reload,x
        beq     :+
        stz     apu_sweep_reload,x
        bra     @swreload
:       dec     apu_sweep_div,x
        bpl     @swnext
        ; sweep clock: if enabled and shift > 0, adjust the period
        ldy     apu_regs_sw,x
        lda     apu_regs,y
        bpl     @swreload
        and     #$07
        beq     @swreload
        jsr     sweep_apply
@swreload:
        ldy     apu_regs_sw,x
        lda     apu_regs,y
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        and     #$07
        sta     apu_sweep_div,x
@swnext:
        dex
        bpl     @sw
        rts

halt_mask:      .byte   $20, $20, $80, $20
apu_regs_sw:    .byte   $01, $05

; X = square channel: period +/- (period >> shift), stored back in the registers
sweep_apply:
        phx
        tay                             ; shift count
        lda     apu_regs_t_lo,x
        tax
        lda     apu_regs,x
        sta     x16_t0
        lda     apu_regs+1,x
        and     #$07
        sta     x16_t1
        sta     x16_t3
        lda     x16_t0
        sta     x16_t2
:       lsr     x16_t3
        ror     x16_t2
        dey
        bne     :-
        plx
        phx
        ldy     apu_regs_sw,x
        lda     apu_regs,y
        and     #$08                    ; negate?
        bne     @neg
        lda     x16_t0
        clc
        adc     x16_t2
        sta     x16_t0
        lda     x16_t1
        adc     x16_t3
        sta     x16_t1
        cmp     #$08
        bcs     @out                    ; overflow: muted, period unchanged
        bra     @store
@neg:   lda     x16_t0
        sec
        sbc     x16_t2
        sta     x16_t0
        lda     x16_t1
        sbc     x16_t3
        sta     x16_t1
        bcc     @out
        txa                             ; square 1 subtracts one more
        bne     @store
        lda     x16_t0
        bne     :+
        dec     x16_t1
:       dec     x16_t0
@store: plx
        phx
        lda     apu_regs_t_lo,x
        tax
        lda     x16_t0
        sta     apu_regs,x
        lda     apu_regs+1,x
        and     #$F8
        ora     x16_t1
        sta     apu_regs+1,x
@out:   plx
        rts

apu_regs_t_lo:  .byte   $02, $06

; --- square channel X -> PSG voice X (VERA data port 1 points at the voice)
psg_square:
        lda     apu_len,x
        beq     @mute
        lda     apu_enable
        and     bitmask,x
        beq     @mute
        ; period
        lda     apu_regs_t_lo,x
        tay
        lda     apu_regs,y
        sta     div_den
        lda     apu_regs+1,y
        and     #$07
        sta     div_den+1
        ; period < 8 mutes the channel on the NES
        bne     :+
        lda     div_den
        cmp     #8
        bcc     @mute
:       ; frequency word = 300274 / (t + 1)
        inc     div_den
        bne     :+
        inc     div_den+1
:       lda     #<300274
        sta     div_num
        lda     #>300274
        sta     div_num+1
        lda     #^300274
        sta     div_num+2
        phx
        jsr     divide
        plx
        lda     div_q
        sta     VERA_DATA1
        lda     div_q+1
        sta     VERA_DATA1
        ; volume: constant or envelope, 0-15 -> 0-60
        ldy     apu_regs_lo,x
        lda     apu_regs,y
        and     #$10
        beq     :+
        lda     apu_regs,y
        and     #$0F
        bra     :++
:       lda     apu_env_vol,x
:       asl     a
        asl     a
        ora     #$C0                    ; both channels
        sta     VERA_DATA1
        ; duty -> pulse width
        lda     apu_regs,y
        rol     a
        rol     a
        rol     a
        and     #$03
        tay
        lda     duty_pw,y
        sta     VERA_DATA1
        rts
@mute:  stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        rts

duty_pw:        .byte   15, 31, 63, 31

psg_triangle:
        lda     apu_len+2
        beq     @mute
        lda     apu_lin
        beq     @mute
        lda     apu_enable
        and     #$04
        beq     @mute
        lda     apu_regs+$0A
        sta     div_den
        lda     apu_regs+$0B
        and     #$07
        sta     div_den+1
        bne     :+
        lda     div_den
        cmp     #2
        bcc     @mute
:       inc     div_den
        bne     :+
        inc     div_den+1
:       lda     #<150137
        sta     div_num
        lda     #>150137
        sta     div_num+1
        lda     #^150137
        sta     div_num+2
        jsr     divide
        lda     div_q
        sta     VERA_DATA1
        lda     div_q+1
        sta     VERA_DATA1
        lda     #$C0 | 44
        sta     VERA_DATA1
        lda     #$80                    ; triangle
        sta     VERA_DATA1
        rts
@mute:  stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        rts

psg_noise:
        lda     apu_len+3
        beq     @mute
        lda     apu_enable
        and     #$08
        beq     @mute
        lda     apu_regs+$0E
        and     #$0F
        tay
        lda     noise_lo,y
        sta     VERA_DATA1
        lda     noise_hi,y
        sta     VERA_DATA1
        lda     apu_regs+$0C
        and     #$10
        beq     :+
        lda     apu_regs+$0C
        and     #$0F
        bra     :++
:       lda     apu_env_vol+3
:       asl     a
        asl     a
        ora     #$C0
        sta     VERA_DATA1
        lda     #$C0                    ; noise
        sta     VERA_DATA1
        rts
@mute:  stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        stz     VERA_DATA1
        rts

noise_lo:
        .byte   <65535, <65535, <65535, <65535, <65535, <50040, <37530, <30025
        .byte   <23782, <18913, <12643, <9457, <6305, <4730, <2362, <1181
noise_hi:
        .byte   >65535, >65535, >65535, >65535, >65535, >50040, >37530, >30025
        .byte   >23782, >18913, >12643, >9457, >6305, >4730, >2362, >1181

; div_q = div_num (24 bit) / div_den (16 bit), saturating at $FFFF
divide:
        stz     div_q
        stz     div_q+1
        lda     #0
        sta     x16_t0                  ; remainder (16 bit + carry)
        sta     x16_t1
        ldx     #24
@loop:  asl     div_num
        rol     div_num+1
        rol     div_num+2
        rol     x16_t0
        rol     x16_t1
        lda     x16_t0
        sec
        sbc     div_den
        tay
        lda     x16_t1
        sbc     div_den+1
        bcc     :+
        sta     x16_t1
        sty     x16_t0
:       rol     div_q
        rol     div_q+1
        bcs     @sat
        dex
        bne     @loop
        rts
@sat:   lda     #$FF
        sta     div_q
        sta     div_q+1
        rts

.include "tables.inc"
.ifdef DEBUG_INPUT
.segment "RODATA"
dbg_input_tab:
.include "debug_input.inc"
        .word   $FFFF
        .byte   0
.endif
