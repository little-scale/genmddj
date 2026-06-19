; ============================================================
; genmddj Z80 sound driver - M9  (SCB executor: PSG + YM2612 + DAC)
;
; The 68k engine composes a per-tick Sound Control Block and pushes
; it into Z80 RAM via BUSREQ; the Z80 executes it and, when armed,
; streams 8-bit PCM from ROM (via the bank window) to the YM2612 DAC.
;
; SCB mailbox (Z80 RAM):
;   $1F00  seq     - bumped by the 68k when a new SCB is present
;   $1F01  psgcnt  - number of raw SN76489 bytes that follow
;   $1F02+ psg     - PSG bytes (up to ~30)
;   $1F20  ymcnt   - number of YM2612 writes that follow
;   $1F21+ ym      - YM writes, 3 bytes each: part(0/1), reg, value
;   $1FB0  dactrig - bumped by the 68k to start a new sample
;   $1FB1  dbank   - starting bank (9-bit, little-endian word)
;   $1FB3  dptr    - starting window read pointer ($8000.. , little-endian)
;   $1FB5  dlen    - sample length in bytes (little-endian word)
;
; The DAC byte cadence (~17.7 kHz) is set by the main-loop period; one
; PCM byte is fed per pass while a sample plays.
; ============================================================

.MEMORYMAP
DEFAULTSLOT 0
SLOT 0 $0000 $2000
.ENDME
.ROMBANKMAP
BANKSTOTAL 1
BANKSIZE $1000
BANKS 1
.ENDRO

.DEFINE PSG       $7F11
.DEFINE YM_A0     $4000     ; part 1 address (ch1-3) + status read
.DEFINE YM_D0     $4001     ; part 1 data
.DEFINE YM_A1     $4002     ; part 2 address (ch4-6)
.DEFINE YM_D1     $4003     ; part 2 data
.DEFINE BANKREG   $6000     ; Z80 -> 68k window bank latch (9 bits, LSB first)

.DEFINE SCB_SEQ   $1F00
.DEFINE SCB_CNT   $1F01
.DEFINE SCB_DATA  $1F02
.DEFINE SCB_YMCNT $1F20
.DEFINE SCB_YMDAT $1F21
.DEFINE SCB_DAC   $1FB0     ; dac trigger seq
.DEFINE SCB_DBANK $1FB1     ; starting bank (LE word)
.DEFINE SCB_DPTR  $1FB3     ; starting window pointer (LE word)
.DEFINE SCB_DLEN  $1FB5     ; length (LE word)
.DEFINE D_PLAY    $1FC0     ; 1 = a sample is streaming
.DEFINE D_PTR     $1FC1     ; current window read pointer
.DEFINE D_REM     $1FC3     ; bytes remaining
.DEFINE D_BANK    $1FC5     ; current window bank

.BANK 0 SLOT 0
.ORG 0
.SECTION "driver" FORCE

start:
    di
    im   1
    ld   sp, $1F00              ; stack below the mailbox

    xor  a
    ld   (SCB_SEQ), a
    ld   (SCB_DAC), a
    ld   (D_PLAY), a
    ld   b, a                   ; b = last SCB seq processed
    ld   d, a                   ; d = last dac trigger

    ld   a, $9F                 ; silence all 4 PSG channels
    ld   (PSG), a
    ld   a, $BF
    ld   (PSG), a
    ld   a, $DF
    ld   (PSG), a
    ld   a, $FF
    ld   (PSG), a

main:
    ld   a, (SCB_DAC)           ; new sample to start?
    cp   d
    jr   z, +
    ld   d, a
    call dac_arm
+:
    ld   a, (D_PLAY)            ; stream a byte if playing
    or   a
    call nz, dac_feed

    ld   a, (SCB_SEQ)           ; new SCB write list?
    cp   b
    jr   z, main
    ld   b, a
    call scb_exec
    jr   main

; ---- arm a new sample from the DAC command ----
dac_arm:
    ld   a, $2B                 ; enable ch6 DAC ($2B bit7)
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
    ld   hl, (SCB_DBANK)
    ld   (D_BANK), hl
    call set_bank
    ld   hl, (SCB_DPTR)
    ld   (D_PTR), hl
    ld   hl, (SCB_DLEN)
    ld   (D_REM), hl
    ld   a, 1
    ld   (D_PLAY), a
    ret

; ---- feed one PCM byte to the DAC, advance, re-bank, stop at end ----
dac_feed:
    ld   hl, (D_PTR)
    ld   a, $2A                 ; ch6 DAC data register
    ld   (YM_A0), a
    ld   a, (hl)               ; PCM byte from the ROM window
    ld   (YM_D0), a
    inc  hl
    bit  7, h                   ; still inside $8000-$FFFF window?
    jr   nz, +
    ld   hl, (D_BANK)           ; crossed 32 KB -> next window bank
    inc  hl
    ld   (D_BANK), hl
    call set_bank
    ld   hl, $8000
+:
    ld   (D_PTR), hl
    ld   hl, (D_REM)
    dec  hl
    ld   (D_REM), hl
    ld   a, h
    or   l
    jr   nz, +
    xor  a
    ld   (D_PLAY), a            ; sample finished
+:
    ld   a, 6                   ; pad the pass toward the ~17.7 kHz cadence
-:
    dec  a
    jr   nz, -
    ret

; ---- set the 9-bit window bank from hl (LSB first) ----
set_bank:
    push hl
    ld   b, 9
-:
    ld   a, l
    and  1
    ld   (BANKREG), a
    srl  h
    rr   l
    djnz -
    pop  hl
    ret

; ---- execute the PSG + YM write lists in the SCB ----
scb_exec:
    ld   a, (SCB_CNT)
    or   a
    jr   z, scb_ym
    ld   c, a
    ld   hl, SCB_DATA
-:
    ld   a, (hl)
    ld   (PSG), a
    inc  hl
    dec  c
    jr   nz, -
scb_ym:
    ld   a, (SCB_YMCNT)
    or   a
    ret  z
    ld   c, a
    ld   hl, SCB_YMDAT
ym_wr:
    ld   a, (hl)               ; part select
    inc  hl
    or   a
    jr   nz, ym_p2
    ld   a, (hl)
    inc  hl
    ld   (YM_A0), a
    call ym_wait
    ld   a, (hl)
    inc  hl
    ld   (YM_D0), a
    call ym_wait
    jr   ym_dec
ym_p2:
    ld   a, (hl)
    inc  hl
    ld   (YM_A1), a
    call ym_wait
    ld   a, (hl)
    inc  hl
    ld   (YM_D1), a
    call ym_wait
ym_dec:
    dec  c
    jr   nz, ym_wr
    ret

ym_wait:
    push bc
    ld   b, $08
-:
    djnz -
    pop  bc
    ret

.ENDS
