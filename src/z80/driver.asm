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
.DEFINE SCB_DSTEP $1FB8     ; window advance per feed (1/2/4 = 1x/2x/4x)
.DEFINE SCB_DHALF $1FB9     ; 1 = 0.5x (feed each byte twice)
.DEFINE D_STEP    $1FC8
.DEFINE D_HALF    $1FC9
.DEFINE D_HFLIP   $1FCA     ; half-rate toggle
; --- wavetable mode (32-byte wave looped from local RAM via a phase accumulator) ---
; Kept at $0C00, well BELOW the SCB mailbox ($1F00+): the SCB's YM-write list can run
; up past $1FB0 and would clobber these if they sat in the mailbox region.
.DEFINE WV_TRIG   $0C00     ; wave trigger seq (68k bumps it)
.DEFINE WV_INC    $0C01     ; phase increment, 8.8 fixed (LE word)
.DEFINE WV_BUF    $0C10     ; 32-byte baked wave buffer ($0C10-$0C2F)
.DEFINE WV_PHASE  $0C30     ; phase accumulator, 8.8 fixed (LE word)
.DEFINE D_WMODE   $0C32     ; 1 = wave-loop mode (else ROM PCM)
.DEFINE WV_LAST   $0C33     ; last wave trigger processed

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
    ld   (D_WMODE), a           ; not in wave mode
    ld   (WV_TRIG), a
    ld   (WV_LAST), a
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

    ld   a, $24                 ; YM2612 Timer A = DAC clock; 1024-TA=7 -> 7610 Hz
    ld   (YM_A0), a             ; (highest step the Z80 paces cleanly; 6->8878 over-runs)
    ld   a, $FE                 ; TA=$3F9 -> $24=$FE (bits 9-2), $25=$01 (bits 1-0)
    ld   (YM_D0), a
    ld   a, $25
    ld   (YM_A0), a
    ld   a, $01
    ld   (YM_D0), a
    ld   a, $27                 ; load + enable Timer A
    ld   (YM_A0), a
    ld   a, $05
    ld   (YM_D0), a

main:
    ld   a, (SCB_DAC)           ; new sample to start?
    cp   d
    jr   z, mn_wtrig
    ld   d, a
    call dac_arm
mn_wtrig:
    ld   a, (WV_TRIG)           ; new wave note to start?
    ld   hl, WV_LAST
    cp   (hl)
    jr   z, mn_dac
    ld   (hl), a
    call wave_arm
mn_dac:
    ld   a, (YM_A0)             ; Timer A overflow -> time to feed one DAC sample
    bit  0, a
    jr   z, mn_scb
    ld   a, $27                 ; reset Timer A flag (keep it loaded + enabled)
    ld   (YM_A0), a
    ld   a, $15
    ld   (YM_D0), a
    ld   a, (D_PLAY)
    or   a
    call nz, dac_feed
mn_scb:
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
    xor  a
    ld   (D_WMODE), a           ; PCM sample -> leave wave mode
    ld   hl, (SCB_DBANK)
    ld   (D_BANK), hl
    call set_bank
    ld   hl, (SCB_DPTR)
    ld   (D_PTR), hl
    ld   hl, (SCB_DLEN)
    ld   (D_REM), hl
    ld   a, (SCB_DSTEP)
    ld   (D_STEP), a
    ld   a, (SCB_DHALF)
    ld   (D_HALF), a
    xor  a
    ld   (D_HFLIP), a
    inc  a
    ld   (D_PLAY), a
    ret

; ---- arm wave-loop mode: enable the DAC, reset the phase, mark wave mode ----
wave_arm:
    ld   a, $2B
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
    xor  a
    ld   (WV_PHASE), a          ; phase = 0 (start at step 0)
    ld   (WV_PHASE+1), a
    inc  a
    ld   (D_WMODE), a
    ld   (D_PLAY), a
    ret

; ---- feed one PCM byte (gained), advance by the rate step, re-bank, stop at end ----
dac_feed:
    ld   a, (D_WMODE)
    or   a
    jp   nz, wave_feed
    ld   hl, (D_PTR)
    ld   a, $2A                 ; ch6 DAC data register
    ld   (YM_A0), a
    ld   a, (hl)               ; PCM byte from the ROM window
    ld   (YM_D0), a
    ld   a, (D_HALF)           ; advance amount c: D_STEP, or 0 on a half-rate skip
    or   a
    jr   z, df_full
    ld   a, (D_HFLIP)
    xor  1
    ld   (D_HFLIP), a
    jr   nz, df_full
    ld   c, 0
    jr   df_adv
df_full:
    ld   a, (D_STEP)
    ld   c, a
df_adv:
    ld   a, l
    add  a, c
    ld   l, a
    jr   nc, df_noc
    inc  h
df_noc:
    bit  7, h                   ; still inside the $8000-$FFFF window?
    jr   nz, df_nob
    set  7, h                   ; wrapped -> next 32 KB bank, keep the overshoot
    push hl
    ld   hl, (D_BANK)
    inc  hl
    ld   (D_BANK), hl
    call set_bank
    pop  hl
df_nob:
    ld   (D_PTR), hl
    ld   hl, (D_REM)           ; D_REM -= c
    ld   a, l
    sub  c
    ld   l, a
    jr   nc, df_rem
    dec  h
df_rem:
    ld   (D_REM), hl
    ld   a, h
    or   a
    jp   m, df_end             ; underflowed past 0
    or   l
    jr   nz, df_pace
df_end:
    xor  a
    ld   (D_PLAY), a           ; finished -> park the DAC at centre, leave it enabled
    ld   a, $2A                 ; (disabling ch6 would step to the FM idle level = a click)
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
df_pace:
    ret                        ; Timer A paces the feed now; no busy-wait needed

; ---- wavetable feed: WV_BUF[(phase>>8) & 31] -> DAC, then phase += inc ----
; MUST preserve bc/de: the main loop keeps the last SCB_SEQ in b and last SCB_DAC in d.
wave_feed:
    push bc
    push de
    ld   hl, (WV_PHASE)
    ld   a, h                   ; integer part of the 8.8 phase
    and  31                     ; -> step 0..31 (the wave loops every 32)
    ld   c, a
    ld   b, 0
    ld   hl, WV_BUF
    add  hl, bc
    ld   c, (hl)                ; wave sample
    ld   a, $2A                 ; ch6 DAC data register
    ld   (YM_A0), a
    ld   a, c
    ld   (YM_D0), a
    ld   hl, (WV_PHASE)         ; phase += increment
    ld   a, (WV_INC)
    ld   e, a
    ld   a, (WV_INC+1)
    ld   d, a
    add  hl, de
    ld   (WV_PHASE), hl
    pop  de
    pop  bc
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
