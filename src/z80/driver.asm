; ============================================================
; genmddj Z80 sound driver - M6  (SCB executor: PSG + YM2612)
;
; The 68k engine composes a per-tick Sound Control Block and pushes
; it into Z80 RAM via BUSREQ; the Z80 executes it.
;
; SCB mailbox (Z80 RAM):
;   $1F00  seq     - bumped by the 68k when a new SCB is present
;   $1F01  psgcnt  - number of raw SN76489 bytes that follow
;   $1F02+ psg     - PSG bytes (up to 30)
;   $1F20  ymcnt   - number of YM2612 writes that follow
;   $1F21+ ym      - YM writes, 3 bytes each: part(0/1), reg, value
; ============================================================

.MEMORYMAP
DEFAULTSLOT 0
SLOT 0 $0000 $2000
.ENDME
.ROMBANKMAP
BANKSTOTAL 1
BANKSIZE $0200
BANKS 1
.ENDRO

.DEFINE PSG       $7F11
.DEFINE YM_A0     $4000     ; part 1 address (ch1-3)
.DEFINE YM_D0     $4001     ; part 1 data
.DEFINE YM_A1     $4002     ; part 2 address (ch4-6)
.DEFINE YM_D1     $4003     ; part 2 data
.DEFINE SCB_SEQ   $1F00
.DEFINE SCB_CNT   $1F01
.DEFINE SCB_DATA  $1F02
.DEFINE SCB_YMCNT $1F20
.DEFINE SCB_YMDAT $1F21

.BANK 0 SLOT 0
.ORG 0
.SECTION "driver" FORCE

start:
    di
    im   1
    ld   sp, $2000

    xor  a
    ld   (SCB_SEQ), a           ; seq = 0
    ld   b, a                   ; b = last seq processed

    ld   a, $9F                 ; silence all 4 PSG channels
    ld   (PSG), a
    ld   a, $BF
    ld   (PSG), a
    ld   a, $DF
    ld   (PSG), a
    ld   a, $FF
    ld   (PSG), a

main:
    ld   a, (SCB_SEQ)           ; new SCB?
    cp   b
    jr   z, main
    ld   b, a

    ; --- PSG bytes ---
    ld   a, (SCB_CNT)
    or   a
    jr   z, do_ym
    ld   c, a
    ld   hl, SCB_DATA
psg_wr:
    ld   a, (hl)
    ld   (PSG), a
    inc  hl
    dec  c
    jr   nz, psg_wr

do_ym:
    ld   a, (SCB_YMCNT)
    or   a
    jr   z, main
    ld   c, a
    ld   hl, SCB_YMDAT
ym_wr:
    ld   a, (hl)                ; part select
    inc  hl
    or   a
    jr   nz, ym_p2
    ld   a, (hl)               ; part 1: addr then data
    inc  hl
    ld   (YM_A0), a
    call ym_wait
    ld   a, (hl)
    inc  hl
    ld   (YM_D0), a
    call ym_wait
    jr   ym_dec
ym_p2:
    ld   a, (hl)               ; part 2
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
    jr   main

; fixed settle delay after a YM2612 register write (busy flag is
; unreliable on YM2612; a conservative delay is safer)
ym_wait:
    push bc
    ld   b, $08
ym_w1:
    djnz ym_w1
    pop  bc
    ret

.ENDS
