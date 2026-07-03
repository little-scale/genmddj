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
;   $1000+ ym      - YM writes (free RAM, 256-triple room), 3 bytes each: part(0/1), reg, value
;   $1FB0  dactrig - bumped by the 68k to start a new sample
;   $1FB1  dbank   - starting bank (9-bit, little-endian word)
;   $1FB3  dptr    - starting window read pointer ($8000.. , little-endian)
;   $1FB5  dlen    - sample length in bytes (little-endian word)
;
; The DAC cadence is YM2612 Timer A (TA_24/TA_25 below); while a sample plays
; a tight loop paces one PCM byte per overflow, interleaving one bounded unit of
; SCB/mailbox work per pass (see 'tight'). The sample state lives in the shadow
; register set; D_PTR/D_REM/D_STEP/D_HALF RAM cells below are vestigial.
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
.DEFINE SCB_YMDAT $1000     ; YM buffer in free RAM ($1000-$12FF, 256 triples) -- byte count can't overrun
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
; In the SCB mailbox region (the 68k reliably writes here). The YM-write area now lives in
; free RAM at $1000, so the mailbox DAC/wave control bytes can never be clobbered by it.
.DEFINE WV_TRIG   $1FCB     ; wave trigger seq (68k bumps it)
.DEFINE WV_INC    $1FCC     ; phase increment, 8.8 fixed (LE word)
.DEFINE WV_BUF    $1FD0     ; 32-byte baked wave buffer ($1FD0-$1FEF)
.DEFINE WV_PHASE  $1FF0     ; phase accumulator, 8.8 fixed (LE word)
.DEFINE D_WMODE   $1FF2     ; 1 = wave-loop mode (else ROM PCM)
.DEFINE WV_LAST   $1FF3     ; last wave trigger processed
.DEFINE WV_OFF    $1FF4     ; 68k bumps this to stop the wave (park DAC, leave wave mode)
.DEFINE WV_OLAST  $1FF5     ; last wave-off processed
.DEFINE CH3_SPC   $1FF6     ; PERC: 1 = CH3 special mode (68k sets; Z80 ORs bit6 into $27)
.DEFINE DAC_FM    $1FCE     ; 68k bumps to switch F6 DAC->FM: park + DISABLE $2B (the ONLY $2B-off path)
.DEFINE DAC_FMLAST $1FCF    ; last DAC_FM processed
; --- sliced SCB executor state (Z80-local; the 68k never writes $1F70-$1F7F) ---
.DEFINE SL_PSGN   $1F70     ; PSG bytes still to drain from the current SCB
.DEFINE SL_PSGP   $1F71     ; -> next PSG byte (word)
.DEFINE SL_YMN    $1F73     ; YM triples still to drain
.DEFINE SL_YMP    $1F74     ; -> next YM triple (word)
.DEFINE T27VAL    $1F76     ; precomputed Timer-A reset value ($15, or $55 with CH3 special)
.DEFINE MB_ROT    $1F77     ; tight-loop rotating mailbox index (0-4)
.DEFINE CT_PSG    $1F78     ; diag: total PSG bytes written (byte, wraps)
.DEFINE CT_YM     $1F79     ; diag: total YM triples written (byte, wraps)
.DEFINE CT_FEED   $1F7A     ; diag: total DAC bytes fed (word, wraps) -- the feed-rate probe
; Timer A: rate = 53267/(1024-TA) Hz NTSC. 1024-TA=5 -> 10653 Hz ($24=$FE $25=$03).
; (Was 1024-TA=10 = 5327: the ceiling of the old polled feed; the tight loop paces higher.)
.DEFINE TA_24     $FE
.DEFINE TA_25     $03

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
    ld   (WV_PHASE), a          ; phase accumulator starts at step 0
    ld   (WV_PHASE+1), a
    ld   (WV_OFF), a
    ld   (WV_OLAST), a
    ld   (CH3_SPC), a           ; CH3 special mode off at boot
    ld   (DAC_FM), a            ; no DAC->FM (disable) request pending
    ld   (DAC_FMLAST), a
    ld   (SL_PSGN), a           ; sliced SCB executor idle
    ld   (SL_YMN), a
    ld   (MB_ROT), a
    ld   (CT_PSG), a
    ld   (CT_YM), a
    ld   (CT_FEED), a
    ld   b, a                   ; b = last SCB seq processed
    ld   c, a                   ; c = tight-loop mailbox rotation index
    ld   d, a                   ; d = last dac trigger
    ld   a, $15
    ld   (T27VAL), a            ; Timer-A reset value (CH3 special folded in at each SCB arm)
    ld   e, a                   ; e = T27VAL cached (the tight loop's quick flag-clear)

    ld   a, $9F                 ; silence all 4 PSG channels
    ld   (PSG), a
    ld   a, $BF
    ld   (PSG), a
    ld   a, $DF
    ld   (PSG), a
    ld   a, $FF
    ld   (PSG), a

    ld   a, $2A                 ; pre-park ch6 DAC at centre ($80) so the first $2B-enable starts
    ld   (YM_A0), a             ; from centre, not the undefined reset value (no boot click)
    ld   a, $80
    ld   (YM_D0), a
    ld   a, $2B                 ; explicitly DISABLE ch6 DAC at boot -> ch6 = FM mode from power-on
    ld   (YM_A0), a             ; (YM reset doesn't guarantee $2B=0, so don't rely on it -> artifacts)
    xor  a
    ld   (YM_D0), a

    ld   a, $24                 ; YM2612 Timer A = DAC clock (rate set by TA_24/TA_25 above)
    ld   (YM_A0), a
    ld   a, TA_24
    ld   (YM_D0), a
    ld   a, $25
    ld   (YM_A0), a
    ld   a, TA_25
    ld   (YM_D0), a
    ld   a, $27                 ; load + enable Timer A
    ld   (YM_A0), a
    ld   a, $05
    ld   (YM_D0), a
    ld   a, $27                 ; park the YM address at $27: the tight loop's flag-clear is a
    ld   (YM_A0), a             ;   SINGLE data write (minimises the read->clear race window)

; ==== relaxed loop (no sample playing): mailbox checks + a blocking SCB drain ====
main:
    ld   a, (SCB_DAC)           ; new sample to start?
    cp   d
    jr   z, mn_wtrig
    ld   d, a
    call dac_arm
mn_wtrig:
    ld   a, (WV_TRIG)           ; new wave note (or per-tick re-arm)?
    ld   hl, WV_LAST
    cp   (hl)
    jr   z, mn_woff
    ld   (hl), a
    call wave_arm
mn_woff:
    ld   a, (WV_OFF)            ; sample/wave stop requested? (park only -- DAC stays enabled)
    ld   hl, WV_OLAST
    cp   (hl)
    jr   z, mn_dfm
    ld   (hl), a
    call wave_off
mn_dfm:
    ld   a, (DAC_FM)           ; F6 DAC->FM switch? (the ONLY path that disables $2B)
    ld   hl, DAC_FMLAST
    cp   (hl)
    jr   z, mn_scb
    ld   (hl), a
    call dac_to_fm
mn_scb:
    ld   a, (SCB_SEQ)           ; new SCB write list?
    cp   b
    jr   z, mn_play
    ld   b, a
    call scb_arm
mn_drain:
    call scb_unit               ; not playing -> drain the whole list now (as the old scb_exec)
    jr   nz, mn_drain
mn_play:
    ld   a, (D_PLAY)            ; a sample/wave started -> switch to the paced tight loop
    or   a
    jr   z, main
    ld   a, $27                 ; park the YM address for the tight loop's quick clear
    ld   (YM_A0), a
    ; fall through

; ==== tight loop (sample playing): Timer-A-paced feed + ONE bounded work unit per pass.
; The worst-case gap between Timer-A status reads stays under one sample period, so
; overflows are never merged (= the old feed's dropped-sample pitch-down). A pass that
; feeds does NO other work; SCB writes and mailbox checks ride the passes in between. ====
tight:
    ld   a, (YM_A0)             ; status: bit 0 = Timer A overflow
    bit  0, a
    jr   z, tt_unit
    ld   a, e                   ; feed pass: clear the flag NOW -- the address is parked at $27,
    ld   (YM_D0), a             ;   so this lands ~30 cycles after the read. Any wider gap races a
                                ;   following overflow into the clear and silently drops a sample.
    ld   a, (D_WMODE)           ; ...then push one PCM/wave byte. The sample state lives in the
    or   a                      ;    SHADOW registers (hl'=ptr de'=rem c'=step b'=half) -- the
    jr   nz, tt_wave            ;    jitter-critical path owns them (DESIGN.md invariant).
    exx                         ; --- PCM byte from the ROM window ---
    ld   a, $2A
    ld   (YM_A0), a
    ld   a, (hl)
    ld   (YM_D0), a
    ld   a, b                   ; half-rate (KIT 0.5x): advance only every other feed
    or   a
    jr   z, tf_adv
    xor  2                      ; flip the phase bit (b: 1 <-> 3)
    ld   b, a
    and  2
    jr   z, tf_done             ; skip pass: no advance, no consume
tf_adv:
    ld   a, l                   ; ptr += step
    add  a, c
    ld   l, a
    jr   nc, +
    inc  h
+:
    bit  7, h                   ; left the $8000-$FFFF window? -> next 32 KB bank
    jr   nz, +
    set  7, h
    call bank_next
+:
    ld   a, e                   ; remaining -= step
    sub  c
    ld   e, a
    jr   nc, +
    dec  d
+:
    ld   a, d                   ; ended? (d wraps negative, or d|e == 0)
    or   e
    jr   z, tf_end
    bit  7, d
    jr   z, tf_done
tf_end:
    xor  a                      ; finished -> park at centre, LEAVE the DAC enabled (no $2B
    ld   (D_PLAY), a            ;   toggle => no click); F6->FM disables $2B via dac_to_fm
    ld   a, $2A
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
tf_done:
    exx
    ld   a, $27                 ; re-park the YM address for the next quick clear
    ld   (YM_A0), a
    ld   hl, CT_FEED            ; diag: count every fed byte (one byte; probes use mod-256 diffs)
    inc  (hl)
    jp   tt_next
tt_wave:
    exx                         ; --- wave byte: WV_BUF[(phase>>8) & 31], phase += inc ---
    ld   a, $2A                 ;    (hl'=phase, de'=increment; b'/c' scratch in wave mode)
    ld   (YM_A0), a
    ld   a, h
    and  31
    add  a, $D0                 ; WV_BUF = $1FD0: $D0+31 stays inside page $1F
    ld   c, a
    ld   b, $1F
    ld   a, (bc)
    ld   (YM_D0), a
    add  hl, de
    jr   tf_done
tt_unit:
    ld   a, (SL_PSGN)           ; one queued SCB write (PSG byte or YM triple), dispatched inline
    or   a
    jr   z, +
    call su_psg
    jr   tt_next
+:
    ld   a, (SL_YMN)
    or   a
    jr   z, ++
    call su_tri
    jr   tt_next
++:
    ld   a, c                   ; ...or, drained: ONE mailbox check, rotating 0-4 (c-resident)
    inc  a
    cp   5
    jr   c, +
    xor  a
+:
    ld   c, a
    or   a
    jr   z, tt_ck_dac
    dec  a
    jr   z, tt_ck_wv
    dec  a
    jr   z, tt_ck_woff
    dec  a
    jr   z, tt_ck_dfm
    ld   a, (SCB_SEQ)           ; 4: new SCB? (only when the previous is fully drained)
    cp   b
    jr   z, tt_next
    ld   b, a
    call scb_arm
    jr   tt_next
tt_ck_dac:
    ld   a, (SCB_DAC)           ; retrigger / new sample mid-play
    cp   d
    jr   z, tt_next
    ld   d, a
    call dac_arm
    jr   tt_next
tt_ck_wv:
    ld   a, (WV_TRIG)
    ld   hl, WV_LAST
    cp   (hl)
    jr   z, tt_next
    ld   (hl), a
    call wave_arm
    jr   tt_next
tt_ck_woff:
    ld   a, (WV_OFF)
    ld   hl, WV_OLAST
    cp   (hl)
    jr   z, tt_next
    ld   (hl), a
    call wave_off
    jr   tt_next
tt_ck_dfm:
    ld   a, (DAC_FM)
    ld   hl, DAC_FMLAST
    cp   (hl)
    jr   z, tt_next
    ld   (hl), a
    call dac_to_fm
tt_next:
    ld   a, (D_PLAY)            ; sample ended / stopped -> back to the relaxed loop
    or   a
    jp   nz, tight
    jp   main

; ---- arm the sliced executor on a new SCB: snapshot counts + pointers, fold CH3 into $27 ----
scb_arm:
    ld   a, (SCB_CNT)
    ld   (SL_PSGN), a
    ld   hl, SCB_DATA
    ld   (SL_PSGP), hl
    ld   a, (SCB_YMCNT)
    ld   (SL_YMN), a
    ld   hl, SCB_YMDAT
    ld   (SL_YMP), hl
    ld   a, $15                 ; precompute the Timer-A reset value once per SCB
    ld   hl, CH3_SPC            ; (CH3 special only changes via an SCB push)
    bit  0, (hl)
    jr   z, +
    or   $40
+:
    ld   (T27VAL), a
    ld   e, a                   ; refresh the cached copy (the tight loop clears from e)
    ret

; ---- execute ONE pending SCB write. Returns NZ if it did work, Z when the list is empty.
;      Preserves b/d (the main/tight seq registers). YM spacing: the caller's loop overhead
;      (>=~120 cycles between calls) replaces the old blanket ym_wait. ----
scb_unit:
    ld   a, (SL_PSGN)
    or   a
    jr   z, su_ym
    call su_psg
    or   1                      ; NZ = did work
    ret
su_ym:
    ld   a, (SL_YMN)
    or   a
    ret  z                      ; Z = nothing pending
    call su_tri
    or   1                      ; NZ = did work
    ret
su_psg:                         ; write one PSG byte (a = SL_PSGN, nonzero)
    dec  a
    ld   (SL_PSGN), a
    ld   hl, (SL_PSGP)
    ld   a, (hl)
    ld   (PSG), a
    inc  hl
    ld   (SL_PSGP), hl
    ld   hl, CT_PSG
    inc  (hl)
    ret
su_tri:                         ; write one YM triple (a = SL_YMN, nonzero)
    dec  a
    ld   (SL_YMN), a
    ld   hl, (SL_YMP)
    ld   a, (hl)
    inc  hl
    or   a
    jr   nz, su_p2
    ld   a, (hl)
    inc  hl
    ld   (YM_A0), a
    nop                         ; address -> data settle (>=17 cycles with the fetches)
    nop
    ld   a, (hl)
    inc  hl
    ld   (YM_D0), a
    jr   su_fin
su_p2:
    ld   a, (hl)
    inc  hl
    ld   (YM_A1), a
    nop
    nop
    ld   a, (hl)
    inc  hl
    ld   (YM_D1), a
su_fin:
    ld   a, $27                 ; re-park the YM address (the tight loop's quick clear relies on it)
    ld   (YM_A0), a
    ld   (SL_YMP), hl
    ld   hl, CT_YM
    inc  (hl)
    or   1                      ; NZ = did work (a = a YM data byte, never matters)
    ret

; ---- arm a new sample from the DAC command: bank the window, load the SHADOW set
;      (hl'=ptr, de'=remaining, c'=step, b'=half flags). Preserves primary b/d. ----
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
    exx
    ld   hl, (SCB_DPTR)
    ld   de, (SCB_DLEN)
    ld   a, (SCB_DSTEP)
    ld   c, a
    ld   a, (SCB_DHALF)
    or   a
    jr   z, +
    ld   a, 1                   ; half-rate on: b' = 1 (phase bit clear)
+:
    ld   b, a
    exx
    ld   a, 1
    ld   (D_PLAY), a
    ld   a, $27                 ; re-park for the tight loop's quick clear
    ld   (YM_A0), a
    ret

; ---- arm wave-loop mode: enable the DAC, mark wave mode. The phase (hl') persists across
;      the per-tick re-arm (the engine re-bakes the wave every frame); the increment (de')
;      reloads each arm (vibrato/pitch changes it). A fresh wave start zeroes the phase. ----
wave_arm:
    ld   a, $2B
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
    ld   a, (D_WMODE)
    exx
    or   a
    jr   nz, +                  ; already in wave mode -> keep the phase
    ld   hl, 0                  ; fresh wave note -> phase 0
+:
    ld   de, (WV_INC)
    exx
    ld   a, 1
    ld   (D_WMODE), a
    ld   (D_PLAY), a
    ld   a, $27                 ; re-park for the tight loop's quick clear
    ld   (YM_A0), a
    ret

; ---- stop a sample/wave but LEAVE the DAC enabled, parked at centre ($80). No $2B toggle => no
;      click. $80 is silence (its DC offset is inaudible / AC-coupled). Used for every sample stop,
;      retrigger and natural end, so drum hits never pop. Only dac_to_fm ever disables $2B. ----
wave_off:
    xor  a
    ld   (D_PLAY), a
    ld   (D_WMODE), a
    ld   a, $2A                 ; park ch6 DAC at centre -- DAC stays ENABLED (no $2B write)
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
    ret

; ---- F6 needs FM: park the DAC, then DISABLE ch6 DAC ($2B) so the FM voice sounds. The one and
;      only $2B-off path -- one click, only on a sample->FM switch on F6, never per drum hit. ----
dac_to_fm:
    xor  a
    ld   (D_PLAY), a
    ld   (D_WMODE), a
    ld   a, $2A                 ; park ch6 DAC at centre, then drop ch6 out of DAC mode
    ld   (YM_A0), a
    ld   a, $80
    ld   (YM_D0), a
    ld   a, $2B                 ; disable ch6 DAC -> FM (so F6 can play FM)
    ld   (YM_A0), a
    xor  a
    ld   (YM_D0), a
    ret

; ---- (rare) PCM crossed the window edge: advance D_BANK + re-latch. Called with the
;      SHADOW set active; set_bank's push/pop protects the shadow b/c (half/step). ----
bank_next:
    push hl
    ld   hl, (D_BANK)
    inc  hl
    ld   (D_BANK), hl
    call set_bank
    pop  hl
    ret

; ---- set the 9-bit window bank from hl (LSB first). Preserves bc: b/d are the loop seq
;      registers and dac_arm / the feed's bank wrap call this from both loops. ----
set_bank:
    push hl
    push bc
    ld   b, 9
-:
    ld   a, l
    and  1
    ld   (BANKREG), a
    srl  h
    rr   l
    djnz -
    pop  bc
    pop  hl
    ret

.ENDS
