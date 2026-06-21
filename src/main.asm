; ============================================================
; genmddj - M5-A: multi-voice PSG engine
;
; The engine is now an array of channel structs (3 PSG squares),
; each playing its own phrase from a phrases pool, sharing a global
; groove. Per tick: global groove -> each channel advances its row
; + triggers -> per-channel AHD envelope -> compose one SCB with all
; channels' changed PSG writes -> push to the Z80. The PHRASE editor
; (M4) edits phrase 0, played live on channel 0.
; ============================================================

ROM_SIZE   equ $200000           ; 2 MB ROM -> ~2 MB pool = ~270 s of 7610 Hz PCM
VDP_DATA   equ $C00000
VDP_CTRL   equ $C00004
Z80_RAM    equ $A00000
Z80_BUSREQ equ $A11100
Z80_RESET  equ $A11200
TMSS_REG   equ $A14000
VERSION    equ $A10001
IO_DATA1   equ $A10003
IO_CTRL1   equ $A10009

    include "build/splash.i"       ; SPLASH_W / SPLASH_H / SPLASH_NTILES
    include "build/algos.i"        ; ALGO_W / ALGO_H / ALGO_NTILES / ALGO_MAPSZ

; ---- channel struct ----
NCH        equ 10                  ; F1-F6 (FM) + T1-T3 (square) + NO (noise)
CHSIZE     equ 40                  ; even (keeps the long c_phrase word-aligned)
ch_state   equ $00FFE000           ; NCH * CHSIZE = 400 bytes ($FFE000-$FFE190)
c_note     equ 0
c_period   equ 2                    ; word
c_vol      equ 4
c_estate   equ 5
c_ectr     equ 6
c_row      equ 7                    ; phrase row 0-15
c_shadowp  equ 8                    ; word
c_shadowa  equ 10
c_psgt     equ 11                   ; PSG tone-latch base ($80/$A0/$C0)
c_psgv     equ 12                   ; PSG volume base ($90/$B0/$D0)
c_tvol     equ 13                   ; live table VOL override ($FF = none -> use the envelope c_vol)
c_tcrow    equ 14                   ; last table row the CMD column ran for ($FF = none -> run on entry)
c_ttsp     equ 15                   ; live table TSP for this tick (signed; FM reads it in fm_freq_send)
c_phrase   equ 16                   ; long: current phrase ptr (cached from chain)
c_chain    equ 20                   ; current chain (from song[songpos][track])
c_cstep    equ 21                   ; chain step 0-15 ($FF = pre-start)
c_transp   equ 22                   ; transpose of current chain step (signed)
c_track    equ 23                   ; song column for this channel (0..NCH-1)
c_songpos  equ 24                   ; current song row for this channel
c_type     equ 25                   ; 0 = PSG square, 1 = FM, 2 = PSG noise
c_ympart   equ 26                   ; FM: YM port part (0 = $4000/1, 1 = $4002/3)
c_ymchreg  equ 27                   ; FM: channel reg offset 0-2 (for $A0/$A4/$B0...)
c_ymkey    equ 28                   ; FM: $28 channel-select nibble (0-2, 4-6)
c_trig     equ 29                   ; FM: 1 = retrigger (key-off, freq, key-on) this tick
c_keyon    equ 30                   ; FM: desired key state
c_kshadow  equ 31                   ; FM: last key state sent to the chip
c_hold     equ 32                   ; gate countdown: $FF = held, else ticks until key-off
c_instr    equ 33                   ; instrument this channel is playing (from the phrase IN col)
c_modph    equ 34                   ; PSG vibrato LFO phase
c_modph2   equ 35                   ; PSG tremolo LFO phase
c_tbl      equ 36                   ; active macro table ($FF = none)
c_trow     equ 37                   ; macro table row 0-15
c_tctr     equ 38                   ; macro table tick counter (advances at TBS speed)
c_lfosync  equ 39                   ; FM LFO resync flags this tick: bit0 note-on, bit1 phrase-start

; ---- globals / cursor / scb ---- (relocated above the 10-channel array)
g_gctr     equ $00FFE200
g_seq      equ $00FFE201
cur_row    equ $00FFE202
cur_col    equ $00FFE203
key_prev   equ $00FFE204
key_rpt    equ $00FFE205
dpad_prev  equ $00FFE206
last_note  equ $00FFE207
e_audnote  equ $00FFE208
cur_phrase equ $00FFE209
playing    equ $00FFE20A           ; 0 = stopped, 1 = playing
cur_screen equ $00FFE20B           ; screen ID (see SCR_*); nav uses scr_order/scr_pos
cur_chain  equ $00FFE20C           ; chain shown/edited on the CHAIN screen
need_clear equ $00FFE20D           ; 1 = clear grid + redraw header next frame
play_row   equ $00FFE20E           ; playhead row for the current screen ($FF = none)
cur_instr  equ $00FFE20F           ; instrument shown/edited on the INSTRUMENT screen
cur_chan   equ $00FFE210           ; editing context: current channel (0..NCH-1)
cur_songrow equ $00FFE211          ; editing context: song row drilled from
g_ticks    equ $00FFE212           ; VBlank tick counter (word) for the top-right readout
play_mode  equ $00FFE214           ; 0 = full song, 1 = chain-solo, 2 = phrase-solo
play_from  equ $00FFE215           ; song row to start from (full-song mode)
in_splash  equ $00FFE216           ; 1 = showing the power-up splash
splash_ctr equ $00FFE218           ; splash countdown (word)
vdirty     equ $00FFE21A           ; 1 = input changed the grid; redraw needed
eng_adv    equ $00FFE21B           ; 1 = engine advanced a step; redraw the playhead
splash_row equ $00FFE21C           ; splash incremental-draw progress (0..SPLASH_H+1)
g_lfo      equ $00FFE21D           ; global FM LFO: 0 = off, 1-8 = on at rate 0-7
env_dirty  equ $00FFE21E           ; 1 = envelope needs rasterising (UI changed)
env_ready  equ $00FFE21F           ; 1 = env_canvas rasterised, upload in progress
last_cmd   equ $00FFE3A0           ; PHRASE C-column memory: last command entered (B-tap repeats it)
scr_row    equ $00FFE3A1           ; saved cursor row per screen (4 bytes, indexed by SCR_*)
scr_col    equ $00FFE3A5           ; saved cursor col per screen (4 bytes)
cur_table  equ $00FFE3A9           ; macro table shown/edited on the TABLE screen
last_instr equ $00FFE3AA           ; PHRASE I-column memory: last instrument placed (new notes inherit it)
last_chain equ $00FFE3AB           ; SONG insert memory: last chain# placed (single B-tap repeats it)
last_phrase equ $00FFE3AC          ; CHAIN insert memory: last phrase# placed (single B-tap repeats it)
btap_frame equ $00FFE3AE           ; g_ticks at the last B-tap (word) -- double-tap window
btap_addr  equ $00FFE3B0           ; field address of the last B-tap (long) -- double-tap = same cell
DBLTAP_FRAMES equ 16               ; max frames between B-taps to count as a double-tap
pshadow    equ $00FFE3B4           ; per-channel (c_track 0-9) last FM instrument patched ($FF=none)
patch_done equ $00FFE3BE           ; 1 = an FM operator patch was emitted this tick (budget 1/tick)
PATCH_CAP  equ 16                  ; max ym_count before emitting a ~30-write patch (SCB headroom)
YM_CAP     equ 43                  ; max ym_count before emitting a note's freq/key
lq_b0      equ $00FFE190           ; Q command: per-channel (c_track 0-9) live $B0 value (FB<<3|ALGO)
lq_dirty   equ $00FFE19A           ; Q command: per-channel flag -> emit lq_b0 for this channel
lx_vol     equ $00FFE1A4           ; X command: per-channel live carrier volume 0-15
lx_dirty   equ $00FFE1AE           ; X command: per-channel flag -> recompute carrier $40 (TL)
lo_b4      equ $00FFE1B8           ; O command: per-channel live $B4 value ((pan<<6)|(AMS<<4)|FMS)
lo_dirty   equ $00FFE1C2           ; O command: per-channel flag -> emit lo_b4 for this channel
lu_off     equ $00FFE1CC           ; U command: per-channel modulator TL offset 0-127
lu_dirty   equ $00FFE1D6           ; U command: per-channel flag -> recompute modulator $40 (TL)
c_pfine    equ $00FFE1E0           ; F command: per-channel signed fine pitch (period/F-num delta)
c_chord    equ $00FFE1EA           ; C command: per-channel chord offsets (x<<4)|y semitones, 0=off
c_cphase   equ $00FFE1F4           ; C command: per-channel arp phase 0-2 (0,+x,+y)
c_bend     equ $00FFE400           ; P command: per-channel signed pitch-bend rate (added to c_pfine/tick)
c_rtper    equ $00FFE40A           ; R command: per-channel retrigger period (ticks, 0=off)
c_rtctr    equ $00FFE414           ; R command: per-channel retrigger countdown
g_lfo_dirty equ $00FFE41E          ; 1 = re-emit $22 (global LFO) on the next SCB push (boot + edits)
; $00FFE41F-$00FFE427 free (was c_ypatch, removed when Y became AMS/FMS)
g_wait     equ $00FFE428           ; W command: this-row frame-count override (0 = use 1250/proj_tmpo)
cmd_tsp    equ $00FFE429           ; J command: this-row repeat-gated transpose (signed; 0 each row)
hop_ctr    equ $00FFE42A           ; H command: hops taken this advance (runaway guard; 0 each advance)
k_set      equ $00FFE42B           ; K command: 1 if K set the gate this row (note-on must not override)
c_set      equ $00FFE42C           ; C command: 1 if C set the chord this row (note-on keeps it, else clears)
f_set      equ $00FFE42D           ; F command: 1 if F set the finetune this row (note-on keeps c_pfine)
p_set      equ $00FFE42E           ; P command: 1 if P set the bend this row (note-on keeps c_bend)
repatch    equ $00FFE3C3           ; 1 = re-push F1's patch on the next SCB push (Q/X cmds, edits)
live_algo  equ $00FFE3C4           ; transient ALGO override from a Q command ($FF = none)
live_vol   equ $00FFE3C5           ; transient VOL override from an X command ($FF = none)
eff_algo   equ $00FFE3C6           ; ym_setup scratch: effective ALGO (override or stored)
eff_vol    equ $00FFE3C7           ; ym_setup scratch: effective VOL
live_fb    equ $00FFE3C8           ; transient FB override from a Q command ($FF = none)
eff_fb     equ $00FFE3C9           ; ym_setup scratch: effective FB
env_ntdone equ $00FFE3CA           ; 0 = canvas nametable still needs writing this upload
env_slot   equ $00FFE3CB           ; envelope rasteriser: operator slot 0..3 being drawn
env_upos   equ $00FFE3CC           ; (word) upload cursor: next canvas tile to push
env_prevy  equ $00FFE3CE           ; envelope rasteriser: last plotted y (connector)
env_pts    equ $00FFE3D0           ; envelope breakpoints: 5 x (word) , a (word) pairs
env_canvas equ $00FFC000           ; envelope bitmap (ENV_TILES tiles, MD 4bpp); 4 KB
opt_vid    equ $00FFE3E4           ; OPTIONS: video region 0=NTSC 1=PAL 2=AUTO
opt_sync   equ $00FFE3E5           ; OPTIONS: DE-9 sync 0=OFF 1=IN 2=OUT
opt_pal    equ $00FFE3E6           ; OPTIONS: UI palette 0..3
proj_tmpo  equ $00FFE3E7           ; PROJECT: tempo (BPM)
proj_tsp   equ $00FFE3E8           ; PROJECT: master transpose (signed)
proj_mode  equ $00FFE3E9           ; PROJECT: play mode 0=SONG 1=CHAIN 2=PHRASE
proj_slot  equ $00FFE3EA           ; PROJECT: save slot 1..8
cur_wave   equ $00FFE3EC           ; WAVE screen: which wave (0-15)
cur_wstep  equ $00FFE3ED           ; WAVE screen: step cursor (0-31)
wave_pidx  equ $00FFE3EE           ; WAVE: B+C preset cycle index (0-7)
wave_rng   equ $00FFE3F0           ; WAVE: random-preset xorshift state (4 bytes)
wave_on    equ $00FFE3F4           ; engine: 1 = a wave note is sounding (per-frame re-bake)
wave_ch    equ $00FFE3F6           ; engine: ch_state ptr of the sounding wave channel (long)
wave_ram   equ $00FFD000           ; 16 user waves x 32 steps x 8-bit (512 B); $D000-$D200 free
wave_rowbuf equ $00FFD200          ; WAVE render: one row's 32-char string + terminator
wave_bake  equ $00FFD240           ; engine: 32-byte shaped wave (bake chain output -> Z80)
prev_ch    equ $00FFD260           ; INSTR WAVE preview: scratch "channel" (c_vol forced full)
wlfo_phase equ $00FFD268           ; 5 global wave LFO phases (vol/warp/fold/drive/crush, 1 wave)
wbake_in   equ $00FFD270           ; 5 bake inputs the shaper reads (vol/warp/fold/drive/crush)
; FM LFO bank: 6 global LFOs, each routed to (channel, FM param). lfo_cfg saved with the song.
lfo_cfg    equ $00FFD280           ; NLFO * LF_SIZE config bytes (flags/chan/param/rate/depth/poff)
lfo_phase  equ $00FFD2E0           ; NLFO 16-bit phases (past lfo_cfg's 16*6 = 96 bytes)
phrase_plays equ $00FFD300         ; per-phrase play counters (NPHRASES bytes) for the I command
lfo_amp    equ $00FFD310           ; NLFO current-amplitude bytes (0-7) for the live AMP bar
PEN_STEP   equ 4                   ; WAVE pen: level change per B+Up/Down (with key-repeat)
PREV_TOP   equ 20                  ; INSTR WAVE preview scope: top row (32x8 under the fields)
PREV_COL   equ 4                   ; INSTR WAVE preview scope: left column (centres 32 cols)

; screen IDs (kept stable so every dispatch site is unchanged); the map order
; (left..right SONG CHAIN PHRASE INSTR) is expressed by scr_order/scr_pos tables.
SCR_PHRASE equ 0
SCR_CHAIN  equ 1
SCR_SONG   equ 2
SCR_INSTR  equ 3
SCR_FM     equ 4                    ; (vestigial: the FM editor now lives inside INSTR)
SCR_TABLE  equ 5                    ; macro table editor (right of INSTR)
; placeholder screens (>= SCR_ECHO have no editable grid) -- the map satellites
SCR_ECHO   equ 6                    ; below TABLE
SCR_OPTS   equ 7                    ; above SONG
SCR_PROJ   equ 8                    ; above CHAIN
SCR_WAVE   equ 9                    ; above INSTR
SCR_GROOVE equ 10                   ; below CHAIN
SCR_LFO    equ 11                   ; below INSTR -- FM LFO bank editor
NSCR       equ 12
SCR_MAXPOS equ 4                    ; rightmost horizontal map position
scb_count  equ $00FFE220           ; PSG byte count + buffer
scb_data   equ $00FFE221
ym_count   equ $00FFE260           ; YM write count + buffer (triples)
ym_data    equ $00FFE261

phrases    equ $00FFF000            ; phrases pool (PHRASE_SIZE each)
PHRASE_SIZE equ 64
NPHRASES   equ 16                   ; ($FFF400 chains - $FFF000 phrases) / 64
chains     equ $00FFF400            ; chains pool (CHAIN_SIZE each)
CHAIN_SIZE equ 32                   ; 16 steps x (phrase#, transpose)
NCHAINS    equ 16                   ; ($FFF600 song - $FFF400 chains) / 32
song       equ $00FFF600            ; song matrix: NSONGROWS x NCH chain#s ($FF empty)
NSONGROWS  equ 16
instrum    equ $00FFB000            ; instrument pool (INSTR_SIZE each); BELOW env_canvas
                                    ; ($FFC000) so a canvas overrun can't reach it, clear of the stack
INSTR_SIZE equ 64                   ; type + algo/fb/pan + 4 ops x 10 + i_tbl/i_tbs + reserved
                                    ; (power of 2; 50-63 reserved headroom while the save format is soft)
tbl_ram    equ $00FFE800            ; editable macro tables (boot-copied from psg_tables)
NTABLE     equ 32
TBL_ROWS   equ 16
TROW       equ 4                    ; bytes per table row
t_vol      equ 0                    ; volume column ($FF = no change)
t_tsp      equ 1                    ; transposition, signed semitones
t_cmd      equ 2                    ; command
t_prm      equ 3                    ; command parameter
NINSTR     equ 32
i_type     equ 0                    ; instrument type: 0 FM, 1 KIT, 2 WAVE, 3 TONE, 4 NOISE
i_algo     equ 1                    ; FM algorithm 0-7
i_fb       equ 2                    ; FM feedback 0-7
i_pan      equ 3                    ; FM stereo pan: 0 off, 1 R, 2 L, 3 L+R
i_ams      equ 4                    ; LFO amplitude-mod sensitivity 0-3
i_fms      equ 5                    ; LFO freq-mod (vibrato) sensitivity 0-7
i_hld      equ 6                    ; gate time: note-off after HLD*2 ticks; $F = hold
i_vol      equ 7                    ; instrument volume 0-15 (attenuates carriers); $F = full
i_op       equ 8                    ; 4 ops x 10: MUL DT TL RS AR AM D1 D2 RR SL
FM_NPARM   equ 10
; PSG (TONE/NOISE) fields overlay the FM-op bytes (an instrument is FM or PSG, never both)
ip_vol     equ 8                    ; PSG peak/hold volume 0-F
ip_atk     equ 9                    ; attack: ticks per volume step up (0 = instant)
ip_hld     equ 10                   ; hold at VOL: 0 none, 1-E nibble*2 ticks, F = inf
ip_dcy     equ 11                   ; decay: ticks per volume step down
ip_tsp     equ 12                   ; transpose, signed semitones
ip_swp     equ 13                   ; pitch sweep (packed)
ip_vib     equ 14                   ; vibrato (packed)
ip_trm     equ 15                   ; tremolo (packed)
ip_mode    equ 18                   ; NOISE: 0 white, 1 periodic  (offsets 16/17 unused now)
ip_rate    equ 19                   ; NOISE: 0-2 = clk/512,1024,2048; 3 = pitched (T3)
; WAVE instrument fields (i_type 2) overlay the PSG SWP/VIB/TRM bytes + 16/17 (one type per instr)
iw_wave    equ 13                   ; which base wave (0-15)
iw_warp    equ 14                   ; phase skew 0-F
iw_drive   equ 15                   ; tanh drive 0-F
iw_fold    equ 16                   ; wavefolder 0-F
iw_crush   equ 17                   ; bit crush 0-F
; WAVE per-parameter LFOs (RATE/DEPTH; OFFSET is the static field above). 5 rows x (rate,depth)
; in the grid order VOLUME/WARP/FOLD/DRIVE/CRUSH. Free for WAVE (= NOISE/FM bytes, one type/instr).
iwl_vr     equ 18                   ; VOLUME LFO rate (0=off); VOLUME offset = ip_vol (env peak)
iwl_vd     equ 19                   ; VOLUME LFO depth (tremolo inside the AHD envelope)
iwl_wr     equ 20                   ; WARP rate / depth ...
iwl_wd     equ 21
iwl_fr     equ 22
iwl_fd     equ 23
iwl_dr     equ 24
iwl_dd     equ 25
iwl_cr     equ 26
iwl_cd     equ 27
iw_pitch   equ 28                   ; PITCH detune: 8 = in tune, <8 flat, >8 sharp (LFO -> vibrato)
iwl_pr     equ 29                   ; PITCH LFO rate / depth
iwl_pd     equ 30
; FM LFO bank record (6 of them in lfo_cfg). flags: bit0 ON, bits1-2 resync (NOTE/PHRASE/FREE).
NLFO       equ 16
LF_SIZE    equ 6
LF_FLAGS   equ 0                    ; bit0 = on; bits 1-2 = resync mode
LF_CHAN    equ 1                    ; target channel 0..NCH-1
LF_PARM    equ 2                    ; target FM parameter (see fmlfo param table)
LF_RATE    equ 3
LF_DEPTH   equ 4
LF_POFF    equ 5                    ; coarse phase offset 0-F: resync restarts phase at offset*16
LFRS_NOTE  equ 0                    ; resync: reset phase on each note-on of the target channel
LFRS_PHRASE equ 1                   ; reset phase when the target channel enters a new phrase
LFRS_FREE  equ 2                    ; never reset (free-running)
i_tbl      equ 48                   ; macro table # ($FF = none) -- shared FM+PSG, at record tail
i_tbs      equ 49                   ; table speed (ticks per row)
i_kit      equ 50                   ; KIT instrument: which sample kit (0..7)
i_gain     equ 51                   ; reserved (real-time gain deferred; use kitpatch build-time gain)
i_rate     equ 52                   ; KIT rate: 0=1x 1=2x 2=4x 3=0.5x (0 = default)
i_tsp      equ 53                   ; FM per-instrument transpose, signed semitones (channel item)
NITYPE     equ 5
NPHRASE_ED equ 7                    ; highest editable phrase (C+Up/Down)
NCHAIN_ED  equ 7                    ; highest editable chain
NINSTR_ED  equ 31                   ; highest editable instrument

I_VOL      equ $F
I_HLD      equ $FF
I_DCY      equ 2
GROOVE     equ 10
GRID_TOP   equ 6

    org $000000

; ---- vectors ----
    dc.l $00FFFE00
    dc.l Start
    dcb.l 22, Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l Exception
    dc.l VBlankInt
    dc.l Exception
    dcb.l 32, Exception

; ---- header ----
    dc.b "SEGA MEGA DRIVE "
    dcb.b $110-*, ' '
    dc.b "(C)GENMDDJ 2026 "
    dcb.b $120-*, ' '
    dc.b "GENMDDJ - MEGA DRIVE TRACKER"
    dcb.b $150-*, ' '
    dc.b "GENMDDJ - MEGA DRIVE TRACKER"
    dcb.b $180-*, ' '
    dc.b "GM GENMDDJ-00"
    dcb.b $18E-*, ' '
    dc.w $0000
    dc.b "J"
    dcb.b $1A0-*, ' '
    dc.l $00000000
    dc.l ROM_END-1
    dc.l $00FF0000
    dc.l $00FFFFFF
    dc.b "RA", $F8, $20             ; $1B0 SRAM present (odd bytes, $A130F1-gated; Q1 layout)
    dc.l $00200001                  ; $1B4 SRAM start (odd-byte addressing)
    dc.l $0020FFFF                  ; $1B8 SRAM end (32 KB of odd bytes)
    dcb.b $1F0-*, ' '
    dc.b "JUE"
    dcb.b $200-*, ' '

; ============================================================
Start:
    move    #$2700, sr
    move.b  VERSION, d0
    andi.b  #$0F, d0
    beq.s   .nt
    move.l  #'SEGA', TMSS_REG
.nt:
    lea     VDP_CTRL, a0

    lea     vdp_regs, a1
    move.w  #$8000, d0
    moveq   #vdp_regs_end-vdp_regs-1, d1
.reg:
    move.b  (a1)+, d0
    move.w  d0, (a0)
    add.w   #$0100, d0
    dbra    d1, .reg

    move.l  #$40000000, (a0)            ; clear VRAM
    move.w  #($10000/2)-1, d0
.vc:
    move.w  #0, VDP_DATA
    dbra    d0, .vc

    move.l  #$44000000, (a0)            ; normal font -> VRAM $0400
    lea     font_data, a1
    move.w  #(3072/2)-1, d0
.fc:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fc
    move.l  #$50000000, (a0)            ; inverse font -> VRAM $1000
    move.w  #(3072/2)-1, d0
.fc2:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fc2
    move.l  #$5C000000, (a0)            ; WAVE tiles (centre line + box border) -> tile $E0
    lea     wave_tiles, a1
    move.w  #(9*16)-1, d0
.wtl:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .wtl
    move.l  #$5D200000, (a0)            ; AMP bar tiles -> tile $E9 (VRAM $1D20)
    lea     bar_tiles, a1
    move.w  #(8*16)-1, d0
.btl:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .btl
    move.l  #$43E00000, (a0)            ; playhead triangle -> tile $1F
    lea     tri_tile, a1
    moveq   #16-1, d0
.ft:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .ft
    move.l  #$60000000, (a0)            ; splash logo tiles -> VRAM $2000 (tile $100)
    lea     splash_tiles, a1
    move.w  #(SPLASH_NTILES*16)-1, d0
.fs:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fs
    move.l  #$6C000000, (a0)            ; FM algorithm tiles -> VRAM $2C00 (tile $160)
    lea     algo_tiles, a1
    move.w  #(ALGO_NTILES*16)-1, d0
.fa:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .fa

    move.l  #$C0000000, (a0)            ; palette 0
    move.w  #$0E40, VDP_DATA            ; c0 sky blue (backdrop)
    move.w  #$00EE, VDP_DATA            ; c1 star yellow (text/cursor block)
    move.w  #$0E40, VDP_DATA            ; c2 sky blue (cursor glyph)

    move.b  #$40, IO_CTRL1

    bsr     z80_load

    bsr     load_demo                     ; phrases -> rests + copy demo phrases/chains/song
    ; clear instrument pool (all type 0 = FM)
    lea     instrum, a2
    move.w  #(NINSTR*INSTR_SIZE)-1, d0
.ci:
    move.b  #0, (a2)+
    dbra    d0, .ci
    lea     instrum, a2                   ; all instruments start as the default FM patch
    moveq   #NINSTR-1, d2
.cdfn:
    lea     default_fm, a1
    moveq   #INSTR_SIZE-1, d0
.cdf:
    move.b  (a1)+, (a2)+
    dbra    d0, .cdf
    dbra    d2, .cdfn
    lea     instrum+INSTR_SIZE, a2        ; instrument 1 = a default TONE voice (demo PSG tracks)
    lea     default_tone, a1
    moveq   #INSTR_SIZE-1, d0
.cdt:
    move.b  (a1)+, (a2)+
    dbra    d0, .cdt
    lea     tbl_ram, a2                   ; copy the ROM default macro tables into RAM
    lea     psg_tables, a1
    move.w  #(NTABLE*TBL_ROWS*TROW)-1, d0
.cdtb:
    move.b  (a1)+, (a2)+
    dbra    d0, .cdtb

    bsr     engine_init
    bsr     ym_setup                     ; build YM ch0's patch from instrument 0
    move.b  #0, cur_row
    move.b  #0, cur_col
    move.b  #0, key_prev
    move.b  #0, key_rpt
    move.b  #0, dpad_prev
    move.b  #48, last_note
    move.b  #0, last_cmd
    move.b  #0, last_instr
    move.b  #0, last_chain
    move.b  #0, last_phrase
    move.l  #0, btap_addr
    move.b  #$FF, e_audnote
    move.b  #0, cur_phrase
    move.b  #0, playing                  ; boot stopped
    move.b  #SCR_SONG, cur_screen
    move.b  #0, cur_chain
    move.b  #0, cur_instr
    move.b  #0, cur_table
    move.b  #0, cur_chan
    move.b  #0, cur_songrow
    lea     scr_row, a0                   ; per-screen saved cursors -> 0
    moveq   #7, d0
.clrscur:
    clr.b   (a0)+
    dbra    d0, .clrscur
    move.w  #0, g_ticks
    move.b  #0, play_mode
    move.b  #0, play_from
    move.b  #0, g_lfo                     ; FM LFO off by default
    move.b  #$FF, live_algo               ; no transient Q/X command overrides yet
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #0, repatch
    move.b  #2, opt_vid                   ; OPTIONS defaults: region AUTO
    move.b  #0, opt_sync                  ;   sync OFF
    move.b  #0, opt_pal                   ;   UI palette 0
    bsr     load_config                   ; SRAM overrides the OPTIONS defaults if a config exists
    bsr     apply_palette                 ; reflect the (possibly restored) palette in CRAM
    move.b  #125, proj_tmpo               ; PROJECT defaults: 125 BPM
    move.b  #0, proj_tsp                  ;   no master transpose
    move.b  #0, proj_mode                 ;   SONG mode
    move.b  #1, proj_slot                 ;   save slot 1
    move.b  #0, cur_wave                  ; WAVE screen: wave 0, step 0
    move.b  #0, cur_wstep
    lea     wave_ram, a2                  ; init waves: wave 0 = a sawtooth, 1-15 = flat centre
    moveq   #0, d0
.winit0:
    move.b  d0, d1
    lsl.b   #3, d1                        ; V = step*8 (0,8,..,248)
    move.b  d1, (a2)+
    addq.b  #1, d0
    cmpi.b  #32, d0
    bne.s   .winit0
    move.w  #(15*32)-1, d0
.winitf:
    move.b  #$80, (a2)+                   ; flat at centre ($80)
    dbra    d0, .winitf
    move.b  #0, wave_pidx                 ; preset cycle starts at sine
    move.b  #0, wave_on                   ; no wave note sounding yet
    lea     lfo_cfg, a2                   ; clear the FM LFO bank (no stray LFOs at boot)
    moveq   #(lfo_phase+NLFO*2-lfo_cfg-1), d0 ; through lfo_cfg records + the phase array
.linit:
    clr.b   (a2)+
    dbra    d0, .linit
    move.l  #$13571357, wave_rng          ; non-zero xorshift seed
    move.b  #0, playing                  ; boot stopped
    move.b  #1, g_lfo_dirty              ; emit $22 (global LFO) on the first SCB push
    move.b  #1, need_clear               ; draw header/name on first frame

    move.b  #1, in_splash
    move.b  #0, splash_row
    move.w  #150, splash_ctr
    move    #$2000, sr
.forever:                                  ; idle loop does the heavy envelope raster
    tst.b   env_dirty                     ; (kept OUT of VBlank -- see env_rasterize)
    beq.s   .forever
    move.b  #0, env_dirty
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .forever
    lea     instrum, a1                   ; only FM instruments have envelope diagrams
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    tst.b   (i_type,a1,d0.w)
    beq.s   .erfm
    move.b  #0, env_ready                 ; PSG/KIT/WAVE: cancel any pending FM-env upload
    bra.s   .forever
.erfm:
    bsr     env_rasterize
    clr.w   env_upos                      ; (re)start the chunked upload from tile 0
    clr.b   env_ntdone                    ; nametable first, then tile chunks
    move.b  #1, env_ready                 ; VBlank pushes it a chunk at a time
    bra.s   .forever

; ============================================================
VBlankInt:
    movem.l d0-d7/a0-a6, -(sp)
    tst.w   VDP_CTRL
    tst.b   in_splash                     ; power-up splash holds the screen
    beq.s   .run
    lea     VDP_CTRL, a0
    bsr     splash_tick
    bra     .vbend
.run:
    bsr     input_tick
    bsr     engine_tick
    lea     VDP_CTRL, a0
    ; redraw the grid only on change (per-frame VRAM writes during active H40
    ; display corrupt the picture); d7 = render-needed
    moveq   #0, d7
    tst.b   vdirty
    beq.s   .nv
    move.b  #0, vdirty
    moveq   #1, d7
.nv:
    tst.b   eng_adv
    beq.s   .nev
    move.b  #0, eng_adv
    moveq   #1, d7
.nev:
    tst.b   need_clear
    beq.s   .nc
    bsr     clear_grid
    moveq   #3, d3                        ; header at row3 col1
    cmpi.b  #SCR_TABLE, cur_screen        ; TABLE: header at row 5 (TBL selector row 3, blank row 4)
    bne.s   .hdr_r
    moveq   #5, d3
.hdr_r:
    moveq   #1, d4
    bsr     screen_ptr                     ; a1 = hdr table entry
    move.l  (a1), a1
    bsr     print_at
    move.l  #$40820003, (a0)              ; clear the name area (cols 1-11) first -- a longer
    moveq   #11-1, d0                      ; previous name (e.g. WAVEFORM) bleeds under a shorter
.cnm:                                       ; one since clear_grid leaves rows 0-2 untouched
    move.w  #' ', VDP_DATA
    dbra    d0, .cnm
    moveq   #1, d3                        ; screen name at row1 col1 (left-aligned, SMSGGDJ-style)
    moveq   #1, d4
    bsr     screen_ptr
    move.l  4(a1), a1
    bsr     print_at
    move.b  #0, need_clear
    move.b  #1, vdirty                    ; re-render next frame (header self-heals)
    move.b  #1, env_dirty
    moveq   #1, d7
.nc:
    bsr     get_playrow                   ; playhead position for this screen
    move.b  d0, play_row
    tst.b   d7
    beq     .gd                           ; unchanged -> skip the grid redraw
    move.b  cur_screen, d0                ; render active grid
    beq     .gph
    cmpi.b  #SCR_CHAIN, d0
    beq     .gch
    cmpi.b  #SCR_SONG, d0
    beq     .gsg
    cmpi.b  #SCR_TABLE, d0
    beq.s   .gtbl
    cmpi.b  #SCR_OPTS, d0                  ; OPTIONS / PROJECT / WAVEFORM placeholders have bodies
    beq     .gopts
    cmpi.b  #SCR_PROJ, d0
    beq     .gproj
    cmpi.b  #SCR_WAVE, d0
    beq     .gwavescr
    cmpi.b  #SCR_LFO, d0                   ; FM LFO bank editor
    beq     .glfo
    cmpi.b  #SCR_ECHO, d0                  ; other placeholder screens: header only, no grid body
    bhs     .gd
    lea     instrum, a1                   ; INSTR: dispatch by instrument type
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    tst.b   (i_type,a1,d0.w)
    bne.s   .gpsg
    bsr     render_fm                     ; FM = the FM editor
    bra.s   .gd
.gtbl:
    bsr     render_table
    bra.s   .gd
.gopts:
    bsr     render_opts
    bra     .gd
.gproj:
    bsr     render_proj
    bra     .gd
.gwavescr:
    bsr     render_wave
    bra     .gd
.glfo:
    bsr     render_lfo
    bra     .gd
.gpsg:
    move.b  (i_type,a1,d0.w), d1          ; a1/d0 still = instrum / cur_instr*48
    cmpi.b  #3, d1
    beq.s   .gtone
    cmpi.b  #4, d1
    beq.s   .gnoise
    cmpi.b  #1, d1
    bne.s   .gwave
    bsr     render_kit                    ; KIT
    bra.s   .gd
.gwave:
    bsr     render_wave_inst              ; WAVE instrument page
    bra.s   .gd
.gtone:
    bsr     render_tone
    bra.s   .gd
.gnoise:
    bsr     render_noise
    bra.s   .gd
.gch:
    bsr     render_chain
    bsr     render_track_playing
    bra.s   .gd
.gsg:
    bsr     render_song
    bsr     render_song_playing
    bra.s   .gd
.gph:
    bsr     render_phrase
    bsr     render_track_playing
.gd:
    addq.w  #1, g_ticks                  ; tick counter (4 hex) at row0 col35
    move.l  #$40460003, (a0)
    move.w  g_ticks, d2
    lea     hexd, a1
    moveq   #3, d3
.tk:
    rol.w   #4, d2                        ; next nibble, MSB first
    move.w  d2, d0
    andi.w  #$000F, d0
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d3, .tk
    move.l  #$40900003, (a0)             ; screen number (2 hex digits) at row1 col8
    cmpi.b  #SCR_ECHO, cur_screen          ; placeholder screens carry no number
    blo.s   .pnnum
    move.w  #' ', VDP_DATA
    move.w  #' ', VDP_DATA
    bra     .pntrack
.pnnum:
    moveq   #0, d0
    move.b  cur_screen, d1
    beq.s   .pnph
    cmpi.b  #SCR_CHAIN, d1
    beq.s   .pnch
    cmpi.b  #SCR_INSTR, d1
    beq.s   .pninst
    cmpi.b  #SCR_TABLE, d1
    beq.s   .pntb
    cmpi.b  #SCR_FM, d1
    bne.s   .pn                           ; SONG -> 0
.pninst:
    move.b  cur_instr, d0                 ; INSTR/FM -> instrument number
    bra.s   .pn
.pntb:
    move.b  cur_table, d0                 ; TABLE -> table number
    bra.s   .pn
.pnch:
    move.b  cur_chain, d0
    bra.s   .pn
.pnph:
    move.b  cur_phrase, d0
.pn:
    lea     hexd, a1
    move.w  d0, d1                        ; high nibble
    lsr.w   #4, d1
    andi.w  #$000F, d1
    move.b  (a1,d1.w), d1
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    andi.w  #$000F, d0                    ; low nibble
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
.pntrack:
    move.b  cur_screen, d0                ; current track name
    beq.s   .tnshow                        ; PHRASE
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .tnshow                        ; CHAIN
    move.l  #$40980003, (a0)              ; other screens: blank it
    move.w  #' ', VDP_DATA
    move.w  #' ', VDP_DATA
    bra.s   .tndone
.tnshow:
    move.l  #$40980003, (a0)             ; track name at row1 col12
    moveq   #0, d0
    move.b  cur_chan, d0
    add.w   d0, d0
    lea     track_names, a1
    move.b  (a1,d0.w), d1
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    move.b  (1,a1,d0.w), d1
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
.tndone:
    lea     str_stop, a1                 ; transport at row3 col36
    tst.b   playing
    beq.s   .ps
    lea     str_play, a1
.ps:
    moveq   #3, d3
    moveq   #35, d4
    bsr     print_at
    bsr     draw_map                      ; map at row5 col35
    bsr     amp_refresh                   ; smooth per-frame AMP bars (LFO screen + playing)
    cmpi.b  #SCR_TABLE, cur_screen        ; animate the TABLE playhead each frame while playing
    bne.s   .ntblph
    tst.b   playing
    beq.s   .ntblph
    bsr     render_table_playhead
.ntblph:
    tst.b   env_ready                     ; push an envelope chunk every frame (budget OK)
    beq.s   .vbend
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .vbend
    move.b  #0, env_ready
    bsr     env_upload
.vbend:
    movem.l (sp)+, d0-d7/a0-a6
    rte

; ---- power-up splash ----
SPLASH_TILEBASE equ $0100                 ; VRAM $2000 / $20
SPLASH_COL  equ (40-SPLASH_W)/2
SPLASH_ROW  equ 8

splash_tick:                              ; a0 = VDP_CTRL; incremental draw + countdown
    move.b  splash_row, d5                ; one logo row per frame (fits the VBlank, so no
    cmpi.b  #SPLASH_H, d5                  ; display blanking is needed)
    bhs.s   .text
    ext.w   d5
    bsr     draw_splash_row
    addq.b  #1, splash_row
    bra.s   .cd
.text:
    bne.s   .cd                           ; past the text frame -> nothing to draw
    bsr     draw_splash_text
    addq.b  #1, splash_row
.cd:
    bsr     pad_read
    btst    #7, d0                        ; Start -> skip the splash
    bne.s   .end
    subq.w  #1, splash_ctr
    bne.s   .ret
.end:
    moveq   #8, d2                        ; clear only the logo's right edge (rows 8-13,
.ce:                                       ; cols 34-39); clear_grid wipes cols 0-33 and
    moveq   #0, d0                          ; clear high word first (swap below needs it 0,
    move.w  d2, d0                          ; else garbage corrupts the VDP command's 2nd word)
    lsl.w   #6, d0                          ; clear_splash's full-plane write burst
    addi.w  #34, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    move.w  #0, VDP_DATA
    addq.w  #1, d2
    cmpi.w  #14, d2
    bne.s   .ce
    moveq   #0, d3                        ; restore GENMDDJ title at row0 col1
    moveq   #1, d4
    lea     str_title, a1
    bsr     print_at
    move.w  #0, g_ticks                   ; tick count starts when the UI loads
    move.b  #0, in_splash
    move.b  #1, need_clear                ; redraw the UI next frame
.ret:
    rts

draw_splash_row:                          ; a0 = VDP_CTRL; d5 = logo tile row to draw
    moveq   #0, d0                        ; clear high word (swap below needs it 0)
    move.w  d5, d0
    addi.w  #SPLASH_ROW, d0
    lsl.w   #6, d0                        ; * 64
    addi.w  #SPLASH_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     splash_map, a2                ; a2 = splash_map + row*SPLASH_W
    move.w  d5, d1
    mulu.w  #SPLASH_W, d1
    adda.w  d1, a2
    moveq   #SPLASH_W-1, d6
.sc:
    moveq   #0, d1
    move.b  (a2)+, d1                     ; local tile index
    addi.w  #SPLASH_TILEBASE, d1
    move.w  d1, VDP_DATA
    dbra    d6, .sc
    rts

draw_splash_text:                         ; a0 = VDP_CTRL; inverted version strip + git stamp
    moveq   #SPLASH_ROW+SPLASH_H+1, d0    ; full-width inverse band at the version row
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #40-1, d6
.sb:
    move.w  #$80, VDP_DATA                 ; inverse space = solid band (text colour)
    dbra    d6, .sb
    moveq   #SPLASH_ROW+SPLASH_H+1, d0    ; version text inverted (chars + $60), at col 17
    lsl.w   #6, d0
    addi.w  #17, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     ver_str, a1
.vt:
    move.b  (a1)+, d1
    beq.s   .vd
    andi.w  #$00FF, d1
    addi.w  #$60, d1                        ; -> inverse tile (bg colour glyph on the band)
    move.w  d1, VDP_DATA
    bra.s   .vt
.vd:
    moveq   #SPLASH_ROW+SPLASH_H+2, d3     ; git stamp below, normal
    moveq   #16, d4
    lea     git_hash_str, a1
    bsr     print_at
    rts

clear_splash:                             ; a0 = VDP_CTRL; blank the visible plane
    moveq   #0, d2
.r:
    move.w  d2, d0
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #40-1, d3
.c:
    move.w  #0, VDP_DATA
    dbra    d3, .c
    addq.w   #1, d2
    cmpi.w  #28, d2
    bne.s   .r
    rts

; screen map widget: the screens in map order with the current one highlighted
draw_map:                                 ; a0 = VDP_CTRL; 3x5 nav cross at rows 5-7, cols 35-39
    lea     scr_grid, a1
    lea     scr_letter, a2
    moveq   #0, d2                          ; cell index 0..14
.dm_loop:
    moveq   #0, d0
    move.b  (a1,d2.w), d0                  ; screen at this cell ($FF = empty)
    cmpi.b  #$FF, d0
    beq.s   .dm_next
    moveq   #0, d3                          ; vrow = idx/5, hcol = idx%5
    move.w  d2, d3
    divu.w  #5, d3
    move.l  d3, d4
    swap    d4
    andi.w  #$000F, d4                      ; hcol
    andi.w  #$000F, d3                      ; vrow
    addi.w  #5, d3                          ; row = 5 + vrow
    lsl.w   #6, d3
    addi.w  #34, d4                         ; col = 34 + hcol (cross sits one col in from the edge)
    add.w   d4, d3
    add.w   d3, d3
    swap    d3
    ori.l   #$40000003, d3
    move.l  d3, (a0)
    moveq   #0, d4
    move.b  (a2,d0.w), d4                  ; scr_letter[screen] (ASCII)
    cmp.b   cur_screen, d0
    bne.s   .dm_draw
    addi.w  #$60, d4                        ; highlight the current screen (inverse tile)
.dm_draw:
    move.w  d4, VDP_DATA
.dm_next:
    addq.w  #1, d2
    cmpi.w  #15, d2
    bne.s   .dm_loop
    rts

; a1 -> {header_str, name_str} pair for the current screen
screen_ptr:
    lea     scr_tabs, a1
    moveq   #0, d0
    move.b  cur_screen, d0
    lsl.w   #3, d0                          ; 2 longs (8 bytes) per entry
    adda.w  d0, a1
    rts

; ============================================================
; input
; ============================================================
input_tick:
    bsr     pad_read
    move.b  d0, d3
    move.b  key_prev, d4
    move.b  d3, key_prev
    not.b   d4
    and.b   d3, d4                       ; button edges
    btst    #7, d4                        ; Start -> toggle transport
    beq.s   .nstart
    bsr     toggle_play
.nstart:
    bsr     dpad_fire                     ; d5 = d-pad bits to act (once)
    move.b  d1, d5
    move.b  d4, d0                        ; any edge or d-pad action -> redraw grid
    or.b    d5, d0
    beq.s   .ndirty
    move.b  #1, vdirty
.ndirty:
    btst    #5, d4                        ; B tap (edge)
    beq.s   .ni
    btst    #6, d3                        ; C held + B tap -> context playback
    beq.s   .doins
    bsr     play_context
    rts
.doins:
    bsr     do_insert                     ; B tap alone -> insert/audition
.ni:
    btst    #5, d3                        ; B held -> edit modifier
    bne.s   .bheld
    btst    #6, d3                        ; else C held -> project modifier
    bne     .cheld
    btst    #4, d3                        ; else A held -> channel switch
    bne     .aheld
    cmpi.b  #SCR_WAVE, cur_screen          ; WAVE: plain Left/Right moves the step cursor
    beq.s   .wavecur
    tst.b   d5                            ; neither: d-pad moves cursor
    beq     .done
    move.b  d5, d2
    bsr     move_cursor
    rts
.wavecur:
    btst    #2, d5                          ; Left -> step--
    beq.s   .wvcr
    tst.b   cur_wstep
    beq.s   .wvcr
    subq.b  #1, cur_wstep
    move.b  #1, vdirty
.wvcr:
    btst    #3, d5                          ; Right -> step++
    beq.s   .wvcdone
    cmpi.b  #31, cur_wstep
    bhs.s   .wvcdone
    addq.b  #1, cur_wstep
    move.b  #1, vdirty
.wvcdone:
    rts
.bheld:
    cmpi.b  #SCR_WAVE, cur_screen          ; WAVE: own pen/draw/preset gestures
    bne.s   .nwb
    jmp     wave_bheld
.nwb:
    btst    #6, d4                        ; B + C tap -> cut (clear cell)
    beq.s   .nbc
    bsr     do_cut
.nbc:
    tst.b   d5                            ; B + d-pad -> edit value
    beq     .done
    move.b  d5, d2
    bsr     edit_value
    cmpi.b  #SCR_FM, cur_screen           ; INSTR/FM edit -> re-apply patch (heard next note)
    beq.s   .reapply
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .ne
.reapply:
    lea     instrum, a1                    ; only FM instruments re-push the YM patch
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    tst.b   (i_type,a1,d0.w)
    bne.s   .ne                            ; TONE/NOISE/KIT/WAVE: no FM patch
    bsr     ym_setup
    cmpi.b  #NVOICE+2, cur_row            ; only an operator edit changes an envelope
    blo.s   .ne
    move.b  #1, env_dirty
.ne:
    rts
.cheld:                                   ; C = 2D map navigation
    btst    #0, d5                         ; C+Up -> up a column on the map
    beq.s   .ncu
    bsr     grid_up
.ncu:
    btst    #1, d5                         ; C+Down -> down a column
    beq.s   .ncd
    bsr     grid_down
.ncd:
    cmpi.b  #SCR_WAVE, cur_screen          ; WAVE: C+Left/Right select the wave 0-15 (the map
    bne.s   .ncdmap                         ; blocks horizontal nav anyway), not screen nav
    btst    #2, d5                          ; C+Left -> wave--
    beq.s   .wvr
    move.b  cur_wave, d0
    beq.s   .wvr
    subq.b  #1, d0
    move.b  d0, cur_wave
    move.b  #1, vdirty
.wvr:
    btst    #3, d5                          ; C+Right -> wave++
    beq.s   .done
    move.b  cur_wave, d0
    cmpi.b  #15, d0
    bhs.s   .done
    addq.b  #1, d0
    move.b  d0, cur_wave
    move.b  #1, vdirty
    bra     .done
.ncdmap:
    btst    #2, d5                         ; C+Left
    beq.s   .ncl
    cmpi.b  #SCR_ECHO, cur_screen          ; main row drills/steps; satellites just step
    bhs.s   .clsat
    bsr     screen_left
    bra.s   .ncl
.clsat:
    bsr     grid_left
.ncl:
    btst    #3, d5                         ; C+Right
    beq.s   .nsr
    cmpi.b  #SCR_ECHO, cur_screen
    bhs.s   .crsat
    bsr     screen_right
    bra.s   .nsr
.crsat:
    bsr     grid_right
.nsr:
    bsr     clamp_col
.done:
    rts

.aheld:                                   ; A + Left/Right -> switch channel (CHAIN/PHRASE only;
    move.b  cur_screen, d0                 ;   INSTR uses the INST field to pick the instrument)
    cmpi.b  #SCR_CHAIN, d0
    beq.s   .ado
    cmpi.b  #SCR_PHRASE, d0
    beq.s   .ado
    rts
.ado:
    btst    #2, d5                         ; A+Left -> previous channel
    beq.s   .arl
    move.b  cur_chan, d0
    beq.s   .arl
    subq.b  #1, d0
    move.b  d0, cur_chan
    bsr     load_chan
.arl:
    btst    #3, d5                         ; A+Right -> next channel
    beq.s   .adone
    move.b  cur_chan, d0
    cmpi.b  #NCH-1, d0
    beq.s   .adone
    addq.b  #1, d0
    move.b  d0, cur_chan
    bsr     load_chan
.adone:
    rts

; cur_chain/cur_phrase <- the chain/phrase channel cur_chan plays at cur_songrow
load_chan:
    lea     song, a1
    moveq   #0, d0
    move.b  cur_songrow, d0
    mulu.w  #NCH, d0                        ; songrow * NCH
    moveq   #0, d1
    move.b  cur_chan, d1
    add.w   d1, d0
    move.b  (a1,d0.w), d0                  ; chain# at song[songrow][chan]
    move.b  #1, need_clear
    cmpi.b  #$FF, d0
    beq.s   .lc_done                       ; empty cell -> keep current chain
    move.b  d0, cur_chain
    lea     chains, a1                     ; cur_phrase <- chain step 0 phrase#
    moveq   #0, d1
    move.b  cur_chain, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    move.b  (a1), d1
    cmpi.b  #$FF, d1
    beq.s   .lc_done
    move.b  d1, cur_phrase
.lc_done:
    rts

; 2D grid move: step in one direction on scr_grid, skipping empty cells, wrapping.
; entry deltas set the axis; preserves d5 (caller's d-pad bits).
grid_up:
    moveq   #-1, d1
    moveq   #0, d2
    bra.s   grid_nav
grid_down:
    moveq   #1, d1
    moveq   #0, d2
    bra.s   grid_nav
grid_left:
    moveq   #0, d1
    moveq   #-1, d2
    bra.s   grid_nav
grid_right:
    moveq   #0, d1
    moveq   #1, d2
grid_nav:                                 ; d1 = vrow delta, d2 = hcol delta
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_vrow, a1
    moveq   #0, d3
    move.b  (a1,d0.w), d3                  ; current vrow (0-2)
    lea     scr_hcol, a1
    moveq   #0, d4
    move.b  (a1,d0.w), d4                  ; current hcol (0-4)
    moveq   #6, d7                         ; step bound (safety)
.gn_step:
    add.w   d1, d3                         ; step vrow, wrap [0,2]
    bge.s   .gn_v1
    moveq   #2, d3
.gn_v1:
    cmpi.w  #2, d3
    ble.s   .gn_v2
    moveq   #0, d3
.gn_v2:
    add.w   d2, d4                         ; step hcol, wrap [0,4]
    bge.s   .gn_h1
    moveq   #4, d4
.gn_h1:
    cmpi.w  #4, d4
    ble.s   .gn_h2
    moveq   #0, d4
.gn_h2:
    move.w  d3, d6                         ; cell = scr_grid[vrow*5 + hcol]
    mulu.w  #5, d6
    add.w   d4, d6
    lea     scr_grid, a1
    move.b  (a1,d6.w), d0
    cmpi.b  #$FF, d0
    beq     .gn_ret                        ; empty cell (a gap) -> no move; don't hop to the next screen
    cmp.b   cur_screen, d0
    beq     .gn_ret                        ; wrapped back to self -> no move
    moveq   #0, d1                          ; target cursor row (0 = top of the new screen)
    cmpi.b  #SCR_LFO, cur_screen           ; LFO -> INSTR on an FM instrument: land on OP1 MUL
    bne.s   .gn_notlfo
    cmpi.b  #SCR_INSTR, d0
    bne.s   .gn_notlfo
    lea     instrum, a1
    moveq   #0, d2
    move.b  cur_instr, d2
    mulu.w  #INSTR_SIZE, d2
    tst.b   (i_type,a1,d2.w)
    bne.s   .gn_notlfo
    moveq   #NVOICE+2, d1                   ; first operator row
.gn_notlfo:
    cmpi.b  #SCR_PHRASE, cur_screen        ; PHRASE -> INSTR: land on the instrument under the cursor row
    bne.s   .gn_set
    cmpi.b  #SCR_INSTR, d0
    bne.s   .gn_set
    movem.l d0/d1, -(sp)
    bsr     cur_phrase_addr                ; a1 = current phrase base
    moveq   #0, d1
    move.b  cur_row, d1
    lsl.w   #2, d1                          ; row * 4 (note,instr,cmd,prm)
    addq.w  #1, d1                          ; +1 = the instr byte
    move.b  (a1,d1.w), cur_instr
    movem.l (sp)+, d0/d1
.gn_set:
    move.b  d0, cur_screen
    move.b  #1, need_clear
    move.b  d1, cur_row
    move.b  #0, cur_col
    rts
.gn_skip:
    dbra    d7, .gn_step
.gn_ret:
    rts

; --- screen map navigation (positions: 0 SONG, 1 CHAIN, 2 PHRASE, 3 INSTR) ---
screen_left:
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0                  ; current map position
    bne.s   .l_step
    rts                                    ; leftmost -> stay put (map no longer wraps)
.l_step:
    subq.b  #1, d0
    lea     scr_order, a1
    move.b  (a1,d0.w), cur_screen
    move.b  #1, need_clear
    moveq   #0, d1                          ; restore the parent screen's cursor (where we
    move.b  cur_screen, d1                  ;   drilled down from) instead of jumping to 0,0
    lea     scr_row, a1
    move.b  (a1,d1.w), cur_row
    lea     scr_col, a1
    move.b  (a1,d1.w), cur_col
.l_done:
    rts

screen_right:
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0
    cmpi.b  #SCR_MAXPOS, d0
    bhs.s   .r_done                        ; rightmost -> stay put (map no longer wraps)
    bsr     drill_down                     ; load the item under the cursor
    moveq   #0, d1                          ; remember this screen's cursor so screen_left
    move.b  cur_screen, d1                  ;   can bring us back to exactly this cell
    lea     scr_row, a1
    move.b  cur_row, (a1,d1.w)
    lea     scr_col, a1
    move.b  cur_col, (a1,d1.w)
    moveq   #0, d0
    move.b  cur_screen, d0
    lea     scr_pos, a1
    move.b  (a1,d0.w), d0
    addq.b  #1, d0
    lea     scr_order, a1
    move.b  (a1,d0.w), cur_screen
    move.b  #1, need_clear
    move.b  #0, cur_row                    ; descending resets cursor to top
    move.b  #0, cur_col
.r_done:
    rts
.r_wrap:
    move.b  #SCR_SONG, cur_screen          ; rightmost -> back to the top of the map
    move.b  #1, need_clear
    move.b  #0, cur_row
    move.b  #0, cur_col
    rts

drill_down:                               ; set the next screen's target from the cursor cell
    move.b  cur_screen, d0
    cmpi.b  #SCR_SONG, d0
    bne.s   .d1
    move.b  cur_col, cur_chan              ; SONG: establish the editing context
    move.b  cur_row, cur_songrow
    bsr     get_field_addr                 ; SONG cell -> chain
    move.b  (a1), d1
    cmpi.b  #$FF, d1
    beq     .d_done
    move.b  d1, cur_chain
    rts
.d1:
    cmpi.b  #SCR_CHAIN, d0
    bne.s   .d2
    lea     chains, a1                     ; CHAIN step PH -> phrase
    moveq   #0, d1
    move.b  cur_chain, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    moveq   #0, d1
    move.b  cur_row, d1
    add.w   d1, d1
    move.b  (a1,d1.w), d1
    cmpi.b  #$FF, d1
    beq     .d_done
    move.b  d1, cur_phrase
    rts
.d2:
    cmpi.b  #SCR_PHRASE, d0
    bne.s   .d3
    bsr     cur_phrase_addr                ; PHRASE row's instrument (offset 1)
    moveq   #0, d1
    move.b  cur_row, d1
    lsl.w   #2, d1
    addq.w  #1, d1
    move.b  (a1,d1.w), cur_instr
    rts
.d3:
    cmpi.b  #SCR_INSTR, d0                 ; INSTR -> TABLE: cur_table = the instrument's TBL
    bne.s   .d_done
    lea     instrum, a1
    moveq   #0, d1
    move.b  cur_instr, d1
    mulu.w  #INSTR_SIZE, d1
    move.b  (i_tbl,a1,d1.w), d1
    cmpi.b  #NTABLE, d1
    bhs.s   .d_done                        ; $FF/out of range -> keep cur_table
    move.b  d1, cur_table
.d_done:
    rts

dpad_fire:
    move.b  d3, d0
    andi.b  #$0F, d0
    move.b  dpad_prev, d1
    move.b  d0, dpad_prev
    not.b   d1
    and.b   d0, d1
    beq.s   .held
    move.b  #16, key_rpt
    rts
.held:
    tst.b   d0
    beq.s   .none
    subq.b  #1, key_rpt
    bne.s   .none
    move.b  #4, key_rpt
    move.b  d0, d1
    rts
.none:
    moveq   #0, d1
    rts

move_cursor:                              ; d-pad moves the cursor; edges WRAP (all screens)
    bsr     row_max                       ; d1 = highest row for this screen/type
    btst    #0, d2                         ; Up
    beq.s   .nu
    move.b  cur_row, d0
    subq.b  #1, d0
    bpl.s   .nuw
    move.b  d1, d0                          ; off the top -> bottom
.nuw:
    move.b  d0, cur_row
.nu:
    btst    #1, d2                          ; Down
    beq.s   .nd
    move.b  cur_row, d0
    addq.b  #1, d0
    cmp.b   d1, d0
    bls.s   .ndw
    moveq   #0, d0                          ; off the bottom -> top
.ndw:
    move.b  d0, cur_row
.nd:
    bsr     col_max                       ; d1 = max col for the (now current) row
    btst    #2, d2                          ; Left
    beq.s   .nl
    move.b  cur_col, d0
    subq.b  #1, d0
    bpl.s   .nlw
    move.b  d1, d0                          ; off the left -> rightmost
.nlw:
    move.b  d0, cur_col
.nl:
    btst    #3, d2                          ; Right
    beq.s   .nr
    move.b  cur_col, d0
    addq.b   #1, d0
    cmp.b   d1, d0
    bls.s   .nrw
    moveq   #0, d0                          ; off the right -> leftmost
.nrw:
    move.b  d0, cur_col
.nr:
    move.b  cur_col, d0                    ; a row change may have shrunk the col range
    cmp.b   d1, d0
    bls.s   .mcdone
    move.b  d1, cur_col
.mcdone:
    rts

row_max:                                  ; -> d1 = highest row index for cur_screen/type
    move.b  cur_screen, d0
    cmpi.b  #SCR_OPTS, d0
    beq.s   .rmopts
    cmpi.b  #SCR_PROJ, d0
    beq.s   .rmproj
    cmpi.b  #SCR_LFO, d0
    beq.s   .rmlfo                           ; FM LFO bank: 6 rows
    cmpi.b  #SCR_ECHO, d0
    bhs.s   .zero                            ; other placeholder screens: cursor locked at row 0
    cmpi.b  #SCR_FM, d0
    beq.s   .fm
    cmpi.b  #SCR_INSTR, d0
    beq.s   .fm
    cmpi.b  #SCR_TABLE, d0
    bne.s   .rmg15
    moveq   #16, d1                          ; TABLE: row 0 = TBL selector, rows 1-16 = the 16 rows
    rts
.rmg15:
    moveq   #15, d1                          ; grid screens (PHRASE/CHAIN/SONG): 16 rows
    rts
.zero:
    moveq   #0, d1
    rts
.rmopts:
    moveq   #2, d1                          ; VID SYNC PAL
    rts
.rmproj:
    moveq   #8, d1                          ; TMPO TSP MODE NEW DEMO SLOT SAVE LOAD LFO
    rts
.rmlfo:
    moveq   #NLFO-1, d1                     ; 6 LFO rows
    rts
.fm:
    lea     instrum, a1                   ; max cursor row depends on instrument type
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    move.b  (i_type,a1,d0.w), d0
    beq.s   .crfm                          ; FM
    moveq   #9, d1                          ; WAVE: INST + TYPE + 8 grid rows (rows 2..9)
    cmpi.b  #1, d0
    bne.s   .crkit
    moveq   #4, d1                          ; KIT: + kit-selector, rate, TSP rows
.crkit:
    cmpi.b  #3, d0
    bne.s   .crk1
    moveq   #11, d1                         ; TONE: 1 + 10 fields
.crk1:
    cmpi.b  #4, d0
    bne.s   .crd
    moveq   #13, d1                         ; NOISE: 1 + 12 fields
.crd:
    rts
.crfm:
    moveq   #NVOICE+5, d1                   ; FM: TYPE + voice + ops
    rts

clamp_row:                                ; clamp cur_row into [0, row_max]
    bsr     row_max
    move.b  cur_row, d0
    cmp.b   d1, d0
    bls.s   .crdone
    move.b  d1, cur_row
.crdone:
    rts

col_max:                                  ; -> d1 = highest column index for cur_screen
    move.b  cur_screen, d1
    cmpi.b  #SCR_LFO, d1
    beq.s   .clfo                            ; FM LFO bank: 6 columns ON/CH/PM/RT/DP/SY
    cmpi.b  #SCR_ECHO, d1
    bhs.s   .czero                           ; placeholder screens: cursor locked at col 0
    tst.b   d1
    beq.s   .ph
    cmpi.b  #SCR_SONG, d1
    beq.s   .sg
    cmpi.b  #SCR_INSTR, d1
    beq.s   .instr
    cmpi.b  #SCR_FM, d1
    beq.s   .fm
    cmpi.b  #SCR_TABLE, d1
    bne.s   .cmch
    moveq   #3, d1                        ; TABLE: 4 columns (VOL TSP CMD PRM)
    rts
.cmch:
    moveq   #1, d1                        ; CHAIN: PH,TR
    rts
.clfo:
    moveq   #7, d1                        ; 8 LFO columns (ON CH PARAM RATE MOD SYNC PO DIR)
    rts
.czero:
    moveq   #0, d1
    rts
.instr:                                   ; INSTR page: WAVE uses its grid's per-row col count
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    move.b  (i_type,a1,d0.w), d0
    cmpi.b  #2, d0                        ; WAVE?
    bne.s   .fm                            ; else PSG/KIT/TONE/NOISE = single column
    moveq   #0, d0
    move.b  cur_row, d0
    subq.w  #2, d0                         ; grid rows start at cur_row 2
    bmi.s   .izero                         ; INST/TYPE rows: single column
    lea     wgrid_cc, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    subq.b  #1, d1                         ; colcount - 1
    rts
.izero:
    moveq   #0, d1
    rts
.fm:
    cmpi.b  #NVOICE+2, cur_row            ; TYPE/voice/LFO rows have one value; ops have 10
    bhs.s   .fmop
    moveq   #0, d1
    rts
.fmop:
    moveq   #FM_NPARM-1, d1
    rts
.ph:
    moveq   #3, d1                        ; PHRASE: NOT,IN,C,PR
    rts
.sg:
    moveq   #NCH-1, d1                    ; SONG: F1-F6 T1-T3 NO (10 tracks)
    rts
.in:
    moveq   #0, d1                        ; INSTR: single value column
    rts

clamp_col:                                ; clamp cur_col into the current screen
    bsr     col_max
    move.b  cur_col, d0
    cmp.b   d1, d0
    bls.s   .ok
    move.b  d1, cur_col
.ok:
    rts

; a1 = address of the current (cur_phrase) phrase
cur_phrase_addr:
    lea     phrases, a1
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0                         ; * PHRASE_SIZE (64)
    adda.w  d0, a1
    rts

do_cut:                                   ; clear field under cursor
    cmpi.b  #SCR_ECHO, cur_screen          ; placeholder screens have no fields
    blo.s   .dc_go
    rts
.dc_go:
    bsr     get_field_addr
    move.b  cur_screen, d0
    cmpi.b  #SCR_INSTR, d0                  ; INSTR field -> 0
    beq.s   .hex
    cmpi.b  #SCR_SONG, d0                   ; SONG: any cell -> $FF (empty)
    beq.s   .ff
    move.b  cur_col, d0
    bne.s   .hex
.ff:
    move.b  #$FF, (a1)                     ; note / phrase# / chain# -> empty
    rts
.hex:
    move.b  #0, (a1)                       ; instr/cmd/param/transpose/type -> 0
    rts

get_field_addr:                           ; -> a1 = cursor field byte
    move.b  cur_screen, d0
    beq     .phrase
    cmpi.b  #SCR_SONG, d0
    beq     .song
    cmpi.b  #SCR_INSTR, d0
    beq     .instr
    cmpi.b  #SCR_TABLE, d0
    beq     .table_fa                      ; TABLE: tbl_ram[cur_table] + row*TROW + col
    lea     chains, a1                     ; CHAIN: chains[cur_chain] + row*2 + col
    moveq   #0, d0
    move.b  cur_chain, d0
    lsl.w   #5, d0
    adda.w  d0, a1
    moveq   #0, d0
    move.b  cur_row, d0
    add.w   d0, d0
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.song:                                    ; song + row*NCH + col
    lea     song, a1
    moveq   #0, d0
    move.b  cur_row, d0
    mulu.w  #NCH, d0                        ; row * NCH
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.table_fa:                                ; tbl_ram[cur_table]*64 + row*TROW + col
    lea     tbl_ram, a1
    moveq   #0, d0
    move.b  cur_table, d0
    lsl.w   #6, d0                          ; table * 64 (TBL_ROWS*TROW)
    moveq   #0, d1
    move.b  cur_row, d1
    subq.b  #1, d1                          ; cur_row 1-16 -> table row 0-15 (row 0 = selector -> floor 0)
    bpl.s   .tfa_r
    moveq   #0, d1
.tfa_r:
    lsl.w   #2, d1                          ; row * TROW
    add.w   d1, d0
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.phrase:
    bsr     cur_phrase_addr
    moveq   #0, d0
    move.b  cur_row, d0
    lsl.w   #2, d0
    moveq   #0, d1
    move.b  cur_col, d1
    lea     field_boff, a2
    move.b  (a2,d1.w), d1
    andi.w  #$00FF, d1
    add.w   d1, d0
    adda.w  d0, a1
    rts
.instr:                                   ; instrum[cur_instr] + field(cur_row)
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a1
    moveq   #0, d0
    move.b  cur_row, d0
    adda.w  d0, a1
    rts

; shared field adjust: a1=field addr, d2=dpad bits, d3=max, d4=coarse step.
; L/R = +-1 (fine), U/D = +-step (coarse); result WRAPS to [0,max] (top<->bottom).
adj_field:
    moveq   #0, d0
    move.b  (a1), d0
    btst    #2, d2                          ; Left -1
    beq.s   .af1
    subq.w  #1, d0
.af1:
    btst    #3, d2                          ; Right +1
    beq.s   .af2
    addq.w  #1, d0
.af2:
    btst    #0, d2                          ; Up +step
    beq.s   .af3
    add.w   d4, d0
.af3:
    btst    #1, d2                          ; Down -step
    beq.s   .af4
    sub.w   d4, d0
.af4:
    cmpi.b  #$FF, d3                        ; max FF = a signed-byte field (TSP): wrap $00<->$FF so
    bne.s   .af_clamp                       ;   dialling down from 0 gives FF (-1), not a clamp at 0
    andi.w  #$00FF, d0                       ;   (low byte test: works whether d3 came from moveq or move.b)
    bra.s   .afwr
.af_clamp:
    tst.w   d0                              ; else clamp to [0,max] (hold to slam to min/max)
    bpl.s   .afnlo
    moveq   #0, d0
.afnlo:
    cmp.w   d3, d0
    bls.s   .afwr
    move.w  d3, d0
.afwr:
    move.b  d0, (a1)
    rts

; TBL field: a1 = field addr, d2 = dpad. Cycles [-- ($FF), 0 .. NTABLE-1] with wrap; -- = no table.
edit_tbl_field:
    move.b  (a1), d0
    btst    #3, d2                          ; Right / Up = forward
    bne.s   .etf_fwd
    btst    #0, d2
    bne.s   .etf_fwd
    btst    #2, d2                          ; Left / Down = back
    bne.s   .etf_bwd
    btst    #1, d2
    bne.s   .etf_bwd
    rts
.etf_fwd:
    cmpi.b  #$FF, d0                        ; -- -> 0
    bne.s   .etf_finc
    moveq   #0, d0
    bra.s   .etf_w
.etf_finc:
    addq.b  #1, d0
    cmpi.b  #NTABLE, d0                     ; past the last table -> --
    blo.s   .etf_w
    move.b  #$FF, d0
    bra.s   .etf_w
.etf_bwd:
    cmpi.b  #$FF, d0                        ; -- -> last table
    bne.s   .etf_bdec
    move.b  #NTABLE-1, d0
    bra.s   .etf_w
.etf_bdec:
    tst.b   d0                              ; 0 -> --
    bne.s   .etf_b2
    move.b  #$FF, d0
    bra.s   .etf_w
.etf_b2:
    subq.b  #1, d0
.etf_w:
    move.b  d0, (a1)
    rts

; FM cell edit: d2 = dpad bits; L/R = +-1, U/D = +-step, wrapping
edit_fm:
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    tst.b   cur_row
    beq     .instedit                      ; row 0 = INST selector
    cmpi.b  #1, cur_row
    beq.s   .typeedit                      ; row 1 = instrument TYPE
    cmpi.b  #NVOICE+2, cur_row
    bhs.s   .opedit
    moveq   #0, d0                         ; voice param (rows 2..NVOICE+1)
    move.b  cur_row, d0
    subq.b  #2, d0
    lea     voice_off, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    lea     0(a3,d1.w), a1
    lea     voice_max, a2
    moveq   #0, d3
    move.b  (a2,d0.w), d3
    lea     voice_step, a2
    moveq   #0, d4
    move.b  (a2,d0.w), d4
    bra.s   .adj
.typeedit:
    bra     edit_psg                       ; TYPE cycles + wraps both ways (shared with the PSG editor)
.instedit:                                ; row 0: select which instrument to edit (wraps)
    move.b  cur_instr, d0
    btst    #2, d2                          ; Left -> previous
    beq.s   .ie_r
    tst.b   d0
    bne.s   .ie_dec
    move.b  #NINSTR_ED, d0
    bra.s   .ie_r
.ie_dec:
    subq.b  #1, d0
.ie_r:
    btst    #3, d2                          ; Right -> next
    beq.s   .ie_w
    cmpi.b  #NINSTR_ED, d0
    blo.s   .ie_inc
    moveq   #0, d0
    bra.s   .ie_w
.ie_inc:
    addq.b  #1, d0
.ie_w:
    move.b  d0, cur_instr
    move.b  #1, need_clear                  ; re-render the whole instrument page
    move.b  #1, env_dirty                   ; new instrument -> re-rasterise envelopes
    rts
.opedit:
    moveq   #0, d0                         ; op grid: i_op + (row-(NVOICE+2))*10 + col
    move.b  cur_row, d0
    subi.w  #NVOICE+2, d0
    mulu.w  #FM_NPARM, d0
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0
    addi.w  #i_op, d0
    lea     0(a3,d0.w), a1
    lea     fm_pmax, a2
    moveq   #0, d3
    move.b  (a2,d1.w), d3
    lea     fm_pstep, a2
    moveq   #0, d4
    move.b  (a2,d1.w), d4
.adj:
    bsr     adj_field                      ; a1=field d2=buttons d3=max d4=step -> wrap-adjust
    ; an FM patch field changed -> invalidate the shadow ONLY for channels currently playing this
    ; instrument, so they re-patch on their next note-on (live edit on any track, no stray writes)
    lea     ch_state, a6
    lea     pshadow, a0
    move.b  cur_instr, d1
    moveq   #NCH-1, d0
.fed:
    cmp.b   c_instr(a6), d1
    bne.s   .fed_n
    move.b  #$FF, (a0)                      ; this channel is on the edited instrument -> re-patch
.fed_n:
    addq.l  #1, a0
    lea     CHSIZE(a6), a6
    dbra    d0, .fed
    rts

; TONE/NOISE/KIT/WAVE editor: INST (row 0), TYPE (row 1), PSG fields (row 2+)
edit_psg:
    tst.b   cur_row
    bne.s   .ep_t
    move.b  cur_instr, d0                  ; row 0 = INST selector (wraps)
    btst    #2, d2                          ; Left
    beq.s   .ep_ir
    tst.b   d0
    bne.s   .ep_idec
    move.b  #NINSTR_ED, d0
    bra.s   .ep_ir
.ep_idec:
    subq.b  #1, d0
.ep_ir:
    btst    #3, d2                          ; Right
    beq.s   .ep_iw
    cmpi.b  #NINSTR_ED, d0
    blo.s   .ep_iinc
    moveq   #0, d0
    bra.s   .ep_iw
.ep_iinc:
    addq.b  #1, d0
.ep_iw:
    move.b  d0, cur_instr
    move.b  #1, need_clear
    rts
.ep_t:
    cmpi.b  #1, cur_row
    bne.s   .ep_field
    lea     instrum, a3                    ; row 1 = TYPE
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    move.b  (i_type,a3), d0
    btst    #3, d2
    beq.s   .ep_tl
    addq.b  #1, d0
    cmpi.b  #NITYPE, d0
    blo.s   .ep_tw
    moveq   #0, d0
    bra.s   .ep_tw
.ep_tl:
    btst    #2, d2
    beq.s   .ep_tw
    tst.b   d0
    bne.s   .ep_td
    moveq   #NITYPE-1, d0
    bra.s   .ep_tw
.ep_td:
    subq.b  #1, d0
.ep_tw:
    move.b  d0, (i_type,a3)
    cmpi.b  #2, d0                          ; switched to WAVE -> install clean defaults so the
    bne.s   .ep_twd                          ; old type's bytes don't read as random LFO/detune
    lea     8(a3), a1                        ; clear the WAVE field block (offsets 8..30)
    moveq   #23-1, d1
.ep_twc:
    clr.b   (a1)+
    dbra    d1, .ep_twc
    move.b  #15, (ip_vol,a3)               ; VOL peak = full
    move.b  #15, (ip_hld,a3)               ; ENV: infinite hold (sustain)
    move.b  #3, (ip_dcy,a3)                ; ENV: gentle release
    move.b  #8, (iw_pitch,a3)              ; PITCH centred (in tune)
.ep_twd:
    move.b  #1, need_clear
    rts
.ep_field:
    lea     instrum, a3                    ; row 2+ = PSG field
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    cmpi.b  #1, (i_type,a3)                ; KIT instrument: row 2 = kit, row 3 = rate, row 4 = TSP
    bne.s   .ep_nkit
    cmpi.b  #4, cur_row
    bne.s   .ep_krate
    lea     (i_tsp,a3), a1                ; row 4 = TSP (signed byte, wraps 00<->FF)
    moveq   #255, d3
    moveq   #12, d4
    bra     adj_field
.ep_krate:
    cmpi.b  #3, cur_row
    bne.s   .ep_ksel
    lea     (i_rate,a3), a1                ; row 3 = RATE (0..3 -> .5x/1x/2x/4x)
    moveq   #3, d3
    moveq   #1, d4
    bra     adj_field
.ep_ksel:
    lea     (i_kit,a3), a1
    moveq   #15, d3                         ; 16 kits (0..15)
    moveq   #1, d4
    bra     adj_field
.ep_nkit:
    cmpi.b  #2, (i_type,a3)                ; WAVE -> the WAVE field set
    beq.s   .ep_wavef
.ep_psgf:
    moveq   #0, d0
    move.b  cur_row, d0
    subq.b  #2, d0                          ; field index
    lea     psg_off, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    lea     0(a3,d1.w), a1                  ; field address
    cmpi.b  #8, d0                          ; TBL field (idx 8) -> wrap-cycle [-- , 0..NTABLE-1]
    beq     edit_tbl_field
    lea     psg_max, a2
    moveq   #0, d3
    move.b  (a2,d0.w), d3                   ; field max
    lea     psg_step, a2                   ; coarse step (B+Up/Down); TSP = 12 (octave)
    moveq   #0, d4
    move.b  (a2,d0.w), d4
    bra     adj_field
.ep_wavef:
    moveq   #0, d0                          ; grid cell = wgrid_off[(cur_row-2)*3 + cur_col]
    move.b  cur_row, d0
    subq.w  #2, d0                          ; rows 0/1 are INST/TYPE; grid starts at row 2
    move.w  d0, d1
    add.w   d0, d0
    add.w   d1, d0                          ; row * 3
    moveq   #0, d1
    move.b  cur_col, d1
    add.w   d1, d0                          ; + col
    lea     wgrid_off, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    cmpi.b  #$FF, d1
    beq.s   .ep_wnop                        ; empty cell (e.g. WAVE row cols 1-2) -> no edit
    lea     0(a3,d1.w), a1                  ; field address (a3 = instrument)
    moveq   #15, d3                          ; every grid cell is 0-15
    moveq   #1, d4                           ; step 1 (L/R = U/D = +-1)
    bra     adj_field
.ep_wnop:
    rts

edit_table:                               ; left/right = +-1, up/down = +-$10 on the cursor cell
    tst.b   cur_row                         ; row 0 = the TBL selector field (pick which table)
    beq     .et_tblsel
    lea     tbl_ram, a1
    moveq   #0, d0
    move.b  cur_table, d0
    lsl.w   #6, d0
    moveq   #0, d1
    move.b  cur_row, d1
    subq.b  #1, d1                          ; cur_row 1-16 -> table row 0-15
    lsl.w   #2, d1
    add.w   d1, d0
    adda.w  d0, a1
    moveq   #0, d0                          ; + the column under the cursor (VOL/TSP/CMD/PRM)
    move.b  cur_col, d0
    adda.w  d0, a1
    cmpi.b  #t_cmd, d0                       ; CMD column cycles commands (0-26, wrap)
    beq     .et_cmd
    cmpi.b  #t_vol, d0                       ; VOL = 4-bit: +-1 (L/R), +-4 (U/D), masked 0-15
    beq     .et_vol
    moveq   #$10, d4                         ; coarse step = high nibble...
    cmpi.b  #t_tsp, d0                       ; ...TSP = transpose -> octave
    bne.s   .ets
    moveq   #12, d4
.ets:
    move.b  (a1), d0                         ; TSP/PRM: +-1 (L/R), +-step (U/D)
    btst    #2, d2
    beq.s   .et1
    subq.b  #1, d0
.et1:
    btst    #3, d2
    beq.s   .et2
    addq.b  #1, d0
.et2:
    btst    #0, d2
    beq.s   .et3
    add.b   d4, d0
.et3:
    btst    #1, d2
    beq.s   .et4
    sub.b   d4, d0
.et4:
    move.b  d0, (a1)
    rts
.et_vol:                                      ; VOL column: 4-bit volume, like the instrument VOL field
    move.b  (a1), d0
    andi.w  #$0F, d0                          ; $FF (no change) -> 0-15
    btst    #2, d2                            ; Left -1
    beq.s   .ev1
    subq.b  #1, d0
.ev1:
    btst    #3, d2                            ; Right +1
    beq.s   .ev2
    addq.b  #1, d0
.ev2:
    btst    #0, d2                            ; Up +4
    beq.s   .ev3
    addq.b  #4, d0
.ev3:
    btst    #1, d2                            ; Down -4
    beq.s   .ev4
    subq.b  #4, d0
.ev4:
    tst.b   d0                                ; clamp 0-15 (no wrap -> min/max reachable)
    bpl.s   .ev_lo
    moveq   #0, d0
.ev_lo:
    cmpi.b  #15, d0
    bls.s   .ev_hi
    moveq   #15, d0
.ev_hi:
    move.b  d0, (a1)
    rts
.et_tblsel:                                   ; TBL selector (cur_row 0): L/R/U/D cycle cur_table (wrap)
    move.b  cur_table, d0
    btst    #3, d2                            ; Right +1
    bne.s   .ets_up
    btst    #0, d2                            ; Up +1
    bne.s   .ets_up
    btst    #2, d2                            ; Left -1
    bne.s   .ets_dn
    btst    #1, d2                            ; Down -1
    bne.s   .ets_dn
    rts
.ets_up:
    addq.b  #1, d0
    cmpi.b  #NTABLE, d0
    blo.s   .ets_w
    moveq   #0, d0
    bra.s   .ets_w
.ets_dn:
    tst.b   d0
    bne.s   .ets_dd
    move.b  #NTABLE-1, d0
    bra.s   .ets_w
.ets_dd:
    subq.b  #1, d0
.ets_w:
    move.b  d0, cur_table
    move.b  #1, vdirty
    rts
.et_cmd:
    move.b  (a1), d0
    btst    #3, d2                           ; Right -> next command (skip A/I/J, wrap 0-26)
    beq.s   .etcl
.et_up:
    addq.b  #1, d0
    cmpi.b  #27, d0
    blo.s   .et_uc
    moveq   #0, d0
.et_uc:
    bsr     tbl_cmd_excl                     ; A/I/J don't apply in tables -> step past them
    beq.s   .et_up
    bra.s   .etcw
.etcl:
    btst    #2, d2                           ; Left -> previous command (skip A/I/J, wrap 26-0)
    beq.s   .etcw
.et_dn:
    tst.b   d0
    bne.s   .et_dc
    moveq   #27, d0
.et_dc:
    subq.b  #1, d0
    bsr     tbl_cmd_excl
    beq.s   .et_dn
.etcw:
    move.b  d0, (a1)
    rts

tbl_cmd_excl:                               ; Z=1 if d0 is table-excluded: A=1 G=7 I=9 J=10 T=20 W=23
    cmpi.b  #1, d0                           ; A (table nesting)
    beq.s   .tce_done
    cmpi.b  #7, d0                           ; G (groove -- global timing)
    beq.s   .tce_done
    cmpi.b  #9, d0                           ; I (iteration -- phrase repeats)
    beq.s   .tce_done
    cmpi.b  #10, d0                          ; J (repeat transpose)
    beq.s   .tce_done
    cmpi.b  #20, d0                          ; T (tempo -- global)
    beq.s   .tce_done
    cmpi.b  #23, d0                          ; W (wait -- per-row frame override)
.tce_done:
    rts

edit_value:
    cmpi.b  #SCR_OPTS, cur_screen
    beq     edit_opts
    cmpi.b  #SCR_PROJ, cur_screen
    beq     edit_proj
    cmpi.b  #SCR_LFO, cur_screen           ; FM LFO bank editor
    beq     edit_lfo
    cmpi.b  #SCR_ECHO, cur_screen          ; other placeholder screens have no fields
    blo.s   .ev_go
    rts
.ev_go:
    cmpi.b  #SCR_TABLE, cur_screen        ; TABLE: edit the cursor cell
    beq     edit_table
    cmpi.b  #SCR_FM, cur_screen           ; INSTR/FM editor: dispatch by instrument type
    beq.s   .instr
    cmpi.b  #SCR_INSTR, cur_screen
    bne.s   .notinstr
.instr:
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    tst.b   (i_type,a1,d0.w)
    beq     edit_fm                        ; FM -> the FM editor
    bra     edit_psg                       ; TONE/NOISE/KIT/WAVE -> the PSG editor
.notinstr:
    tst.b   cur_screen                    ; CHAIN/SONG: both cols are byte +-1/+-$10
    bne.s   .hexfield
    move.b  cur_col, d0
    beq     .note
    cmpi.b  #2, d0
    beq     .cmd
.hexfield:
    bsr     get_field_addr
    moveq   #$10, d4                        ; coarse step = high nibble...
    cmpi.b  #SCR_CHAIN, cur_screen
    bne.s   .hxstep
    cmpi.b  #1, cur_col                     ; ...but CHAIN col 1 = TSP transpose -> octave
    bne.s   .hxstep
    moveq   #12, d4
.hxstep:
    move.b  (a1), d0
    btst    #2, d2
    beq.s   .h1
    subq.b  #1, d0
.h1:
    btst    #3, d2
    beq.s   .h2
    addq.b  #1, d0
.h2:
    btst    #0, d2
    beq.s   .h3
    add.b   d4, d0
.h3:
    btst    #1, d2
    beq.s   .h4
    sub.b   d4, d0
.h4:
    move.b  d0, (a1)
    cmpi.b  #SCR_SONG, cur_screen           ; remember the last value placed (single B-tap repeats)
    beq.s   .h4_chain
    cmpi.b  #SCR_CHAIN, cur_screen
    beq.s   .h4_phrase
    tst.b   cur_screen                     ; PHRASE instr column (col 1) -> last_instr
    bne.s   .h4r
    cmpi.b  #1, cur_col
    bne.s   .h4r
    move.b  d0, last_instr
.h4r:
    rts
.h4_chain:
    cmpi.b  #NCHAINS, d0                    ; only remember a valid chain#
    bhs.s   .h4r
    move.b  d0, last_chain
    rts
.h4_phrase:
    tst.b   cur_col                          ; CHAIN col 0 = phrase#
    bne.s   .h4_ctsp                          ; col 1 = transpose -> push it live to a playing channel
    cmpi.b  #NPHRASES, d0
    bhs.s   .h4r
    move.b  d0, last_phrase
    rts
.h4_ctsp:                                     ; edited a chain step's transpose: update any channel
    lea     ch_state, a6                       ;   currently on this chain+step, so it's heard now and
    move.b  cur_chain, d1                      ;   not only when the chain next loops back to the step
    move.b  cur_row, d2
    moveq   #NCH-1, d3
.hct:
    cmp.b   c_chain(a6), d1
    bne.s   .hct_n
    cmp.b   c_cstep(a6), d2
    bne.s   .hct_n
    move.b  d0, c_transp(a6)
.hct_n:
    lea     CHSIZE(a6), a6
    dbra    d3, .hct
    rts
.cmd:
    bsr     get_field_addr
    move.b  (a1), d0
    btst    #3, d2
    beq.s   .cl
    addq.b  #1, d0
    cmpi.b  #27, d0
    blo.s   .cl
    moveq   #0, d0
.cl:
    btst    #2, d2
    beq.s   .cw
    tst.b   d0
    bne.s   .cdec
    moveq   #26, d0
    bra.s   .cw
.cdec:
    subq.b  #1, d0
.cw:
    move.b  d0, (a1)
    tst.b   d0                             ; remember the last real command for B-tap repeat
    beq.s   .cwr
    move.b  d0, last_cmd
.cwr:
    rts
.note:
    bsr     get_field_addr
    moveq   #0, d0
    move.b  (a1), d0
    cmpi.b  #$FF, d0
    bne.s   .nn
    moveq   #48, d0
.nn:
    btst    #2, d2
    beq.s   .n1
    subq.w  #1, d0
.n1:
    btst    #3, d2
    beq.s   .n2
    addq.w  #1, d0
.n2:
    btst    #0, d2
    beq.s   .n3
    addi.w  #12, d0
.n3:
    btst    #1, d2
    beq.s   .n4
    subi.w  #12, d0
.n4:
    tst.w   d0                              ; clamp to [0,95]
    bpl.s   .nlo
    moveq   #0, d0
.nlo:
    cmpi.w  #95, d0
    ble.s   .nhi
    move.w  #95, d0
.nhi:
    move.b  d0, (a1)
    move.b  d0, last_note
    rts

; INSTRUMENT: L/R cycles the field's value (type 0..NITYPE-1)
edit_instr:
    bsr     get_field_addr
    move.b  (a1), d0
    btst    #3, d2                         ; Right -> next
    beq.s   .ei1
    addq.b  #1, d0
    cmpi.b  #NITYPE, d0
    blo.s   .ei1
    moveq   #0, d0
.ei1:
    btst    #2, d2                         ; Left -> previous
    beq.s   .ei2
    tst.b   d0
    bne.s   .eidec
    moveq   #NITYPE-1, d0
    bra.s   .ei2
.eidec:
    subq.b  #1, d0
.ei2:
    move.b  d0, (a1)
    rts

do_insert:
    cmpi.b  #SCR_PROJ, cur_screen          ; PROJECT: B-tap triggers NEW/DEMO/SAVE/LOAD
    beq     proj_action
    cmpi.b  #SCR_ECHO, cur_screen          ; other placeholder screens have no fields
    blo.s   .di_go
    rts
.di_go:
    bsr     get_field_addr
    cmpi.b  #SCR_SONG, cur_screen           ; SONG B-tap -> allocate a new (empty) chain
    beq.s   .song_ins
    cmpi.b  #SCR_CHAIN, cur_screen           ; CHAIN B-tap -> allocate a new (empty) phrase
    beq.s   .chain_ins
    move.b  cur_col, d0
    beq.s   .ins_note                      ; col 0 = NOT -> insert/audition note
    cmpi.b  #2, d0                          ; col 2 = C (PHRASE command column)
    bne.s   .ret
    tst.b   cur_screen                      ; PHRASE only
    bne.s   .ret
    tst.b   (a1)                            ; only drop into an empty command cell
    bne.s   .ret
    move.b  last_cmd, (a1)                  ; B-tap repeats the last command entered
.ret:
    rts
.song_ins:
    bsr     chk_dbltap                       ; double B-tap -> allocate a new (unused) chain
    tst.b   d2
    bne.s   .song_new
    cmpi.b  #$FF, (a1)                      ; single B-tap -> repeat last_chain on an empty cell
    bne     .ret
    move.b  last_chain, (a1)
    rts
.song_new:
    bsr     find_free_chain
    cmpi.b  #NCHAINS, d0
    bhs     .ret                            ; no free chain
    move.b  d0, (a1)
    move.b  d0, last_chain
    rts
.chain_ins:
    tst.b   cur_col                          ; col 0 = phrase# (col 1 = transpose)
    bne     .ret
    bsr     chk_dbltap                       ; double B-tap -> allocate a new (unused) phrase
    tst.b   d2
    bne.s   .chain_new
    cmpi.b  #$FF, (a1)                      ; single B-tap -> repeat last_phrase on an empty cell
    bne     .ret
    move.b  last_phrase, (a1)
    move.b  #0, 1(a1)                        ; fresh chain step -> transpose 0 (not the $FF fill)
    rts
.chain_new:
    bsr     find_free_phrase
    cmpi.b  #NPHRASES, d0
    bhs     .ret
    move.b  d0, (a1)
    move.b  #0, 1(a1)                        ; fresh chain step -> transpose 0 (not the $FF fill)
    move.b  d0, last_phrase
    rts
.ins_note:
    move.b  (a1), d0
    cmpi.b  #$FF, d0
    bne.s   .audit
    move.b  last_note, d0
    move.b  d0, (a1)
    tst.b   cur_screen                      ; PHRASE -> new note inherits the last instrument
    bne.s   .audit
    move.b  last_instr, 1(a1)
.audit:
    rts

find_free_chain:                          ; d0.b = lowest EMPTY chain (no placed phrases); NCHAINS if none
    moveq   #0, d0
.ffc_cand:
    lea     chains, a2
    move.w  d0, d1
    mulu.w  #CHAIN_SIZE, d1
    adda.w  d1, a2                          ; a2 = chain d0
    moveq   #15, d1                         ; 16 steps (phrase#, transpose)
.ffc_scan:
    cmpi.b  #$FF, (a2)                      ; a placed phrase -> chain has content, not free
    bne.s   .ffc_next
    addq.l  #2, a2
    dbra    d1, .ffc_scan
    rts                                     ; all 16 steps empty -> d0 is free
.ffc_next:
    addq.b  #1, d0
    cmpi.b  #NCHAINS, d0
    blo.s   .ffc_cand
    rts

find_free_phrase:                         ; d0.b = lowest EMPTY phrase (no notes/commands); NPHRASES if none
    moveq   #0, d0
.ffp_cand:
    lea     phrases, a2
    move.w  d0, d1
    lsl.w   #6, d1                          ; * PHRASE_SIZE (64)
    adda.w  d1, a2                          ; a2 = phrase d0
    moveq   #15, d1                         ; 16 rows (note, instr, cmd, prm)
.ffp_scan:
    cmpi.b  #$FF, (a2)                      ; a note present -> not empty
    bne.s   .ffp_next
    tst.b   (2,a2)                          ; a command present -> not empty
    bne.s   .ffp_next
    addq.l  #4, a2
    dbra    d1, .ffp_scan
    rts                                     ; all 16 rows empty -> d0 is free
.ffp_next:
    addq.b  #1, d0
    cmpi.b  #NPHRASES, d0
    blo.s   .ffp_cand
    rts

chk_dbltap:                               ; a1 = field addr -> d2.b = 1 if this is a 2nd B-tap on the
    moveq   #0, d2                         ; same cell within DBLTAP_FRAMES, else 0. Records this tap.
    move.l  a1, d0
    cmp.l   btap_addr, d0
    bne.s   .ct_rec
    move.w  g_ticks, d0
    sub.w   btap_frame, d0
    cmpi.w  #DBLTAP_FRAMES, d0
    bhi.s   .ct_rec
    moveq   #1, d2
.ct_rec:
    move.l  a1, btap_addr
    move.w  g_ticks, btap_frame
    rts


; Read pad 1 -> d0.b = St C B A R L D U (active high). The first TH phase returns
; the standard buttons on BOTH 3- and 6-button pads (a 6-button pad starts each
; idle-reset read at phase 0), so this reads every button genmddj uses on either
; pad. The X/Y/Z/Mode extras (6-button only) are not read yet (no feature uses them;
; the extended-sequence read needs hardware verification - see Q3 / pad6_ex notes).
pad_read:
    move.b  #$40, IO_DATA1               ; TH=1
    nop
    nop
    move.b  IO_DATA1, d1                 ; U D L R B C
    move.b  #$00, IO_DATA1               ; TH=0
    nop
    nop
    move.b  IO_DATA1, d2                 ; . . . . A St
    move.b  #$40, IO_DATA1               ; leave TH high (idle resets a 6-button pad)
    not.b   d1
    not.b   d2
    moveq   #0, d0
    move.b  d1, d0
    andi.b  #$0F, d0                     ; U D L R
    btst    #4, d1                        ; B -> bit5
    beq.s   .b
    bset    #5, d0
.b:
    btst    #5, d1                        ; C -> bit6
    beq.s   .c
    bset    #6, d0
.c:
    btst    #4, d2                        ; A -> bit4
    beq.s   .a
    bset    #4, d0
.a:
    btst    #5, d2                        ; Start -> bit7
    beq.s   .s
    bset    #7, d0
.s:
    rts

; ============================================================
; render TABLE grid: 16 rows of cur_table's signed arp offset
; ============================================================
render_table:                             ; V(vol) TSP(transpose) CMD(cmd+prm), SMSGGDJ-style
    moveq   #3, d3                          ; TBL selector field (cur_row 0): "TBL ##" at row 3
    moveq   #1, d4
    lea     str_tbl, a1
    bsr     print_at
    move.l  #$418A0003, (a0)               ; table # at row 3 col 5
    move.b  cur_table, d3
    moveq   #0, d4
    tst.b   cur_row                         ; cur_row 0 -> highlight the TBL selector
    bne.s   .rt_nsel
    moveq   #$60, d4
.rt_nsel:
    bsr     draw_hex2
    moveq   #0, d6                         ; table rows 0-15 (cursor rows 1-16)
.tr:
    bsr     draw_rowhdr                    ; row number + playhead at the left
    moveq   #0, d5                         ; column 0-3 (vol, arp, cmd, prm)
.tc:
    lea     table_scol, a1                 ; VDP addr at (GRID_TOP+row, table_scol[col])
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     tbl_ram, a1                    ; a1 -> the row's 4 bytes (vol,arp,cmd,prm)
    moveq   #0, d0
    move.b  cur_table, d0
    lsl.w   #6, d0
    move.w  d6, d1
    lsl.w   #2, d1
    add.w   d1, d0
    adda.w  d0, a1
    moveq   #0, d4                         ; highlight if cursor on this cell
    move.b  cur_row, d0
    subq.b  #1, d0                          ; cur_row 1-16 -> table rows 0-15 (row 0 = TBL selector)
    cmp.b   d6, d0
    bne.s   .tnh
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .tnh
    moveq   #$60, d4
.tnh:
    move.b  d5, d0
    beq.s   .tvol                          ; col 0 = volume (1 char, "-" = no change)
    cmpi.b  #t_tsp, d0
    beq.s   .tpit                          ; col 1 = TSP (2 hex)
    cmpi.b  #t_cmd, d0
    beq.s   .tcmd                          ; col 2 = command letter
    tst.b   (t_cmd,a1)                     ; col 3 = PRM: dashes when no command
    beq.s   .tdash2
    move.b  (t_prm,a1), d3
    bsr     draw_hex2
    bra.s   .tadv
.tvol:
    move.b  (t_vol,a1), d3
    cmpi.b  #$FF, d3
    beq.s   .tdash1                        ; $FF = no change -> "-"
    andi.w  #$000F, d3
    lea     hexd, a2
    move.b  (a2,d3.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    bra.s   .tadv
.tpit:
    move.b  (t_tsp,a1), d3
    bsr     draw_hex2
    bra.s   .tadv
.tcmd:
    move.b  (t_cmd,a1), d3
    bsr     draw_cmd
    bra.s   .tadv
.tdash2:
    move.w  #'-', d0                       ; PRM: 2 dashes
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    bra.s   .tadv
.tdash1:
    move.w  #'-', d0                       ; V: 1 dash
    add.w   d4, d0
    move.w  d0, VDP_DATA
.tadv:
    addq.w  #1, d5
    cmpi.w  #4, d5
    bne     .tc
    addq.w  #1, d6
    cmpi.w  #TBL_ROWS, d6
    bne     .tr
    rts

; ============================================================
; render PHRASE grid (phrase 0)
; ============================================================
render_phrase:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_field
    addq.b  #1, d5
    cmpi.b  #4, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

render_field:
    movem.l d5-d6/a1-a2, -(sp)
    lea     field_scol, a1
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     phrases, a2                   ; a2 -> cur_phrase's row (note,instr,cmd,prm)
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    adda.w  d0, a2
    move.w  d6, d2
    lsl.w   #2, d2
    adda.w  d2, a2
    move.b  d5, d0
    beq.s   .note
    cmpi.b  #1, d0
    beq.s   .instr
    cmpi.b  #2, d0
    beq.s   .cmd
    tst.b   (2,a2)                         ; PRM: dashes when there's no command
    beq.s   .dash2
    move.b  (3,a2), d3
    bsr     draw_hex2
    bra.s   .done
.instr:
    cmpi.b  #$FF, (a2)                     ; IN: dashes on a rest row (no note)
    beq.s   .dash2
    move.b  (1,a2), d3
    bsr     draw_hex2
    bra.s   .done
.note:
    move.b  (a2), d3
    bsr     draw_note
    bra.s   .done
.cmd:
    move.b  (2,a2), d3
    bsr     draw_cmd
    bra.s   .done
.dash2:
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
.done:
    movem.l (sp)+, d5-d6/a1-a2
    rts

; ============================================================
; render CHAIN grid: 16 steps x (phrase#, transpose) of cur_chain
; ============================================================
render_chain:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_cfield
    addq.b  #1, d5
    cmpi.b  #2, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

render_cfield:                            ; d5=field(0=PH,1=TR), d6=row, d4=cursor off
    movem.l d4-d6/a1-a2, -(sp)
    lea     chain_scol, a1
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     chains, a2                     ; chains[cur_chain] + row*2
    moveq   #0, d0
    move.b  cur_chain, d0
    lsl.w   #5, d0
    adda.w  d0, a2
    move.w  d6, d2
    add.w   d2, d2
    move.b  (a2,d2.w), d0                  ; step's phrase# (empty if $FF)
    cmpi.b  #$FF, d0
    beq.s   .empty                         ; empty step -> both fields "--"
    moveq   #0, d1
    move.b  d5, d1
    add.w   d1, d2
    move.b  (a2,d2.w), d3
    bsr     draw_hex2
    bra.s   .done
.empty:
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
.done:
    movem.l (sp)+, d4-d6/a1-a2
    rts

clear_grid:                               ; a0=VDP_CTRL; blank header + grid + envelope (3..24)
    moveq   #0, d2
.row:
    moveq   #0, d0
    move.w  d2, d0
    addi.w  #3, d0                         ; from row 3 (header)
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #40-1, d3                      ; cols 0-39 (full width: also wipes the splash band in the
.col:                                          ;   status column 34-39; the status panel redraws it)
    move.w  #' ', VDP_DATA
    dbra    d3, .col
    addq.w   #1, d2
    cmpi.w  #24, d2                        ; rows 3..26 (canvas + OP labels)
    bne.s   .row
    rts

; draw a row's left edge: col1 = row# hex, col2 = space, col3 = playhead triangle
; (col3 sits directly left of the first data column at col4)
draw_rowhdr:                              ; d6 = row; a0 = VDP_CTRL
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0                        ; col1
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0                        ; col1 row# hex
    lea     hexd, a1
    andi.w  #$000F, d0
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    move.w  #' ', VDP_DATA                ; col2 space
    move.w  #$20, d1                      ; col3 playhead (triangle or space)
    move.b  play_row, d0
    cmp.b   d6, d0
    bne.s   .nm
    move.w  #$1F, d1
.nm:
    move.w  d1, VDP_DATA
    rts

; TABLE playhead: redraw just the 16 row-header playhead cells (col 3) each frame so it tracks
; c_trow as the table arps (the full table only re-renders on eng_adv -- too slow). a0 = VDP_CTRL.
render_table_playhead:
    bsr     get_playrow
    move.b  d0, play_row
    moveq   #0, d6
.rtp:
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addi.w  #3, d0                          ; col 3 (the playhead column)
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #$20, d1                        ; space
    move.b  play_row, d0
    cmp.b   d6, d0
    bne.s   .rtpn
    move.w  #$1F, d1                        ; playhead triangle
.rtpn:
    move.w  d1, VDP_DATA
    addq.w  #1, d6
    cmpi.w  #16, d6
    bne.s   .rtp
    rts

; compute the playhead row for the current screen -> d0 ($FF if not shown)
get_playrow:                              ; shared single playhead (PHRASE/CHAIN only)
    tst.b   playing
    beq     .none
    move.b  cur_screen, d1
    beq     .phrase
    cmpi.b  #SCR_CHAIN, d1
    beq     .chain
    cmpi.b  #SCR_TABLE, d1                 ; TABLE: the playing table's current row (c_trow)
    beq     .table
    bra     .none                          ; SONG uses per-track markers; others none
.phrase:                                  ; row of a channel playing cur_phrase
    moveq   #0, d2
    move.b  cur_phrase, d2
    lsl.w   #6, d2
    lea     phrases, a1
    adda.w  d2, a1
    lea     ch_state, a6
    moveq   #NCH-1, d2
.pl:
    cmpi.b  #$FF, c_chain(a6)             ; skip inactive channels (parked on phrase 0, row 15)
    beq.s   .pnext
    movea.l c_phrase(a6), a2
    cmpa.l  a1, a2
    beq.s   .pf
.pnext:
    lea     CHSIZE(a6), a6
    dbra    d2, .pl
    bra     .none
.pf:
    move.b  c_row(a6), d0
    rts
.chain:                                   ; step of a channel playing cur_chain
    move.b  cur_chain, d3
    lea     ch_state, a6
    moveq   #NCH-1, d2
.cl:
    move.b  c_chain(a6), d0
    cmp.b   d3, d0
    beq.s   .cf
    lea     CHSIZE(a6), a6
    dbra    d2, .cl
    bra     .none
.cf:
    move.b  c_cstep(a6), d0
    rts
.table:                                   ; row of a channel currently playing cur_table
    move.b  cur_table, d3
    lea     ch_state, a6
    moveq   #NCH-1, d2
.tbl_l:
    cmpi.b  #$FF, c_chain(a6)             ; skip inactive channels
    beq.s   .tbl_n
    move.b  c_tbl(a6), d0
    cmp.b   d3, d0
    beq.s   .tbl_f
.tbl_n:
    lea     CHSIZE(a6), a6
    dbra    d2, .tbl_l
    bra     .none
.tbl_f:
    move.b  c_trow(a6), d0
    rts
.none:
    moveq   #-1, d0                       ; $FF -> no row matches
    rts

; ============================================================
; render SONG grid: 16 rows x NCH track columns of chain#s
; ============================================================
render_song:
    moveq   #0, d6
.rl:
    bsr     draw_rowhdr
    moveq   #0, d5
.cl:
    moveq   #0, d4
    move.b  cur_row, d0
    cmp.b   d6, d0
    bne.s   .np
    move.b  cur_col, d0
    cmp.b   d5, d0
    bne.s   .np
    move.w  #$60, d4
.np:
    bsr     render_sfield
    addq.b  #1, d5
    cmpi.b  #NCH, d5
    bne.s   .cl
    addq.b  #1, d6
    cmpi.b  #16, d6
    bne.s   .rl
    rts

; live "now playing" note readout under each SONG track (row 23). a0 = VDP_CTRL.
render_song_playing:
    movem.l d3-d7/a1-a2, -(sp)
    moveq   #0, d5                          ; track 0-9
.spl:
    lea     song_scol, a1                  ; VDP addr -> (row 23, song_scol[track])
    move.b  (a1,d5.w), d7
    moveq   #0, d0
    move.w  #23, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d5, d1                          ; channel = ch_state + track*CHSIZE
    mulu.w  #CHSIZE, d1
    lea     ch_state, a2
    adda.w  d1, a2
    bsr     draw_play_slot
    addq.b  #1, d5
    cmpi.b  #NCH, d5
    bne.s   .spl
    movem.l (sp)+, d3-d7/a1-a2
    rts

; draw the compact now-playing note for channel a2 at the VDP write pos (3 chars),
; or "-- " when stopped / idle / no current note.
draw_play_slot:
    tst.b   playing
    beq.s   .psdash
    cmpi.b  #$FF, c_chain(a2)
    beq.s   .psdash
    move.b  c_note(a2), d3
    cmpi.b  #$FF, d3
    beq.s   .psdash
    bra     draw_note_compact               ; tail-call: emits 3 chars + rts
.psdash:
    move.w  #'-', d0                        ; "-- " (no note playing on this track)
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    move.w  #' ', d0
    move.w  d0, VDP_DATA
    rts

; single now-playing note for the current track (cur_chan) -- PHRASE/CHAIN, row 23 col 4.
render_track_playing:
    movem.l d3/a1-a2, -(sp)
    moveq   #0, d0                          ; VDP addr -> (row 23, col 4)
    move.w  #23, d0
    lsl.w   #6, d0
    addq.w  #4, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #0, d1
    move.b  cur_chan, d1
    mulu.w  #CHSIZE, d1
    lea     ch_state, a2
    adda.w  d1, a2
    bsr     draw_play_slot
    movem.l (sp)+, d3/a1-a2
    rts

render_sfield:                            ; d5=track col, d6=row, d4=cursor off
    movem.l d4-d6/a1-a2, -(sp)
    lea     song_scol, a1
    move.b  (a1,d5.w), d7
    subq.b  #1, d7                          ; marker column (one left of the chain#)
    moveq   #0, d0
    move.w  d6, d0
    addi.w  #GRID_TOP, d0
    lsl.w   #6, d0
    andi.w  #$00FF, d7
    add.w   d7, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #$20, d0                       ; per-track playhead marker (this column)
    tst.b   playing
    beq.s   .nomark
    move.w  d5, d1                          ; channel = ch_state + col*CHSIZE
    mulu.w  #CHSIZE, d1
    lea     ch_state, a2
    adda.w  d1, a2
    cmpi.b  #$FF, c_chain(a2)              ; inactive channel -> no marker
    beq.s   .nomark
    move.b  c_songpos(a2), d1
    cmp.b   d6, d1                          ; row == this channel's song position?
    bne.s   .nomark
    move.w  #$1F, d0                        ; triangle
.nomark:
    move.w  d0, VDP_DATA
    lea     song, a2                       ; chain# at song[row*NCH + col]
    move.w  d6, d2
    mulu.w  #NCH, d2
    moveq   #0, d1
    move.b  d5, d1
    add.w   d1, d2
    move.b  (a2,d2.w), d3
    cmpi.b  #$FF, d3                        ; empty cell -> "--"
    beq.s   .empty
    bsr     draw_hex2
    bra.s   .done
.empty:
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
.done:
    movem.l (sp)+, d4-d6/a1-a2
    rts

; ============================================================
; render INSTRUMENT screen: field list for cur_instr (TYPE for now)
; ============================================================
render_instr:
    moveq   #0, d0                        ; "TYPE" label at (GRID_TOP, col1)
    move.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     str_type, a1
.ll:
    move.b  (a1)+, d1
    beq.s   .ld
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    bra.s   .ll
.ld:
    moveq   #0, d4                        ; cursor highlight on field 0
    tst.b   cur_row
    bne.s   .nc
    tst.b   cur_col
    bne.s   .nc
    move.w  #$60, d4
.nc:
    moveq   #0, d0                        ; type value at (GRID_TOP, col6)
    move.w  #GRID_TOP, d0
    lsl.w   #6, d0
    addi.w  #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     instrum, a1
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    move.b  (a1,d0.w), d1                 ; type
    andi.w  #$0003, d1
    add.w   d1, d1
    lea     type_names, a1
    move.b  (a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.b  (1,a1,d1.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

FM_VHDR equ 6                             ; (unused; the VOICE: label was removed)
FM_VTOP equ 6                             ; voice params start here (no VOICE: label now)
FM_OHDR equ 16                            ; operator grid header (INST + gaps, no LFO row)
FM_OTOP equ 17                            ; operator grid
ALGO_TILEBASE equ $0160                   ; algorithm tiles -> VRAM $2C00 / $20
ALGO_DIAG_ROW equ 10                      ; algorithm diagram (1x, half size)
ALGO_DIAG_COL equ 13
ENV_TW  equ 32                            ; envelope canvas: 4 ops x 8 tiles wide, 4 tall
ENV_TH  equ 4
ENV_TILES equ ENV_TW*ENV_TH
ENV_W   equ ENV_TW*8                      ; canvas px (256 x 32), each op = 64px sub-column
ENV_H   equ ENV_TH*8
ENV_VRAM equ $3600                        ; canvas tiles -> VRAM (clears the 76 algo tiles: $2C00..$357F)
ENV_TILEBASE equ ENV_VRAM/$20
ENV_ROW equ 22                            ; canvas nametable position (below the op grid)
ENV_COL equ 2
ENV_LBLROW equ ENV_ROW+ENV_TH              ; OP labels centered below the boxes
ENV_CHUNK equ 16                          ; canvas tiles uploaded per frame (~256 words)
ENV_SUBW equ 64                           ; per-operator lane width (px)
ENV_BOXT equ 1                            ; box top edge (1px margin from lane edge)
ENV_BOXB equ ENV_H-2                       ; box bottom edge
ENV_TOP equ ENV_BOXT+1                     ; curve/guide top: 1px INSIDE the box
ENV_BOT equ ENV_BOXB-1                     ; curve/guide baseline: 1px inside the box
ENV_AMAX equ ENV_BOT-ENV_TOP               ; max amplitude in px (curve clears the borders)

; FM editor: VOICE section (one param per row) then the 4-operator grid
; shared INST + TYPE header for every instrument page; returns a3 = instrum[cur_instr]
render_inst_hdr:
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    moveq   #3, d3                         ; INST selector (cur_row 0)
    moveq   #1, d4
    lea     str_inst, a1
    bsr     print_at
    move.l  #$41900003, (a0)              ; instrument number at row 3, col 8
    move.b  cur_instr, d3
    moveq   #0, d4
    tst.b   cur_row                        ; highlight when cur_row == 0
    bne.s   .inh
    moveq   #$60, d4
.inh:
    bsr     draw_hex2
    moveq   #4, d3                         ; TYPE field (cur_row 1)
    moveq   #1, d4
    lea     str_type, a1
    bsr     print_at
    moveq   #0, d1                          ; full type name at row 4, col 8
    move.b  (i_type,a3), d1
    andi.w  #$0007, d1
    lsl.w   #2, d1
    lea     type_lbl, a1
    move.l  (a1,d1.w), a1
    moveq   #0, d2                          ; highlight offset
    cmpi.b  #1, cur_row
    bne.s   .tnh
    moveq   #$60, d2
.tnh:
    moveq   #4, d3
    moveq   #8, d4
    bsr     print_hl
    rts

; placeholder for KIT until its editor lands
render_psg_stub:
    bsr     render_inst_hdr
    moveq   #7, d3
    moveq   #1, d4
    lea     str_wip, a1
    bsr     print_at
    rts

; FM LFO bank editor (SCR_LFO): 6 LFO rows x 6 columns ON/CH/PM/RT/DP/SY. Cursor = (cur_row
; 0..5, cur_col 0..5). Reads the lfo_cfg records; ON and SY share the flags byte.
render_lfo:                                ; a0 = VDP_CTRL
    moveq   #4, d3                          ; column header at row 4, col 3
    moveq   #3, d4
    lea     str_lfo_hdr, a1
    bsr     print_at
    moveq   #0, d6                          ; LFO row r = 0..5
.lfr:
    move.w  d6, d5                          ; screen row = 6 + r
    addi.w  #6, d5
    moveq   #0, d3                          ; row label: the LFO number (r+1) at col 1
    move.w  d5, d3
    lsl.w   #6, d3
    addi.w  #1, d3
    add.w   d3, d3
    swap    d3
    ori.l   #$40000003, d3
    move.l  d3, (a0)
    move.b  d6, d3                          ; row label = LFO index 0..F (hex)
    moveq   #0, d4
    bsr     draw_hex1
    move.w  d6, d0                          ; a3 = lfo_cfg + r * LF_SIZE
    mulu.w  #LF_SIZE, d0
    lea     lfo_cfg, a3
    adda.w  d0, a3
    lea     lf_col, a2
    moveq   #0, d7                          ; column c = 0..5
.lfc:
    move.w  d7, d0
    add.w   d0, d0
    move.b  (a2,d0.w), d1                  ; field offset within the record
    moveq   #0, d2
    move.b  (a3,d1.w), d2                  ; raw byte
    move.b  (1,a2,d0.w), d1               ; kind: 0 hex, 1 ON bit, 2 SY bits
    beq.s   .lfk0
    cmpi.b  #1, d1
    bne.s   .lfk2
    andi.w  #1, d2                          ; ON = bit0
    bra.s   .lfk0
.lfk2:
    cmpi.b  #2, d1
    bne.s   .lfk3
    lsr.w   #1, d2                          ; SY = bits 1-2
    andi.w  #3, d2
    bra.s   .lfk0
.lfk3:
    lsr.w   #3, d2                          ; DIR = bits 3-4
    andi.w  #3, d2
.lfk0:
    moveq   #0, d1                          ; highlight the cursor cell
    cmp.b   cur_row, d6
    bne.s   .lfnh
    cmp.b   cur_col, d7
    bne.s   .lfnh
    moveq   #$60, d1
.lfnh:
    lea     lf_colx, a4                     ; cell screen column from the layout table
    moveq   #0, d4
    move.b  (a4,d7.w), d4
    moveq   #0, d3
    move.w  d5, d3
    lsl.w   #6, d3
    add.w   d4, d3
    add.w   d3, d3
    swap    d3
    ori.l   #$40000003, d3
    move.l  d3, (a0)
    tst.w   d7                              ; col 0 ON -> box tile
    beq     .lfon
    cmpi.w  #2, d7                          ; col 2 PARAM -> 4-char param name
    beq     .lfprm
    cmpi.w  #5, d7                          ; col 5 SYNC -> 5-char resync name
    beq     .lfsyn
    cmpi.w  #3, d7                          ; col 3 RATE -> 2 hex digits (full byte)
    beq     .lfrate
    cmpi.w  #7, d7                          ; col 7 DIR -> arrow tile
    beq     .lfdir
    cmpi.w  #8, d7                          ; col 8 AMP -> live bar tile
    beq     .lfamp
    move.b  d2, d3                          ; else a single hex digit
    move.b  d1, d4
    bsr     draw_hex1
    bra     .lfcn
.lfon:
    move.w  d2, d3                          ; 0/1 -> $7B off-box / $7D on-box
    add.w   d3, d3
    addi.w  #$7B, d3
    add.w   d1, d3                          ; + highlight (inverse-tile offset)
    move.w  d3, VDP_DATA
    bra     .lfcn
.lfdir:
    lea     dir_glyph, a1                   ; DIR 0/1/2 -> arrow tile
    moveq   #0, d3
    move.b  (a1,d2.w), d3
    add.w   d1, d3
    move.w  d3, VDP_DATA
    bra     .lfcn
.lfamp:
    move.w  #$20, d3                        ; AMP: blank unless playing and this LFO is on
    tst.b   playing
    beq.s   .lfaw
    btst    #0, (LF_FLAGS,a3)
    beq.s   .lfaw
    lea     lfo_amp, a1                     ; amplitude 0-7 -> bar tile $E9..$F0
    moveq   #0, d3
    move.b  (a1,d6.w), d3
    addi.w  #$E9, d3
.lfaw:
    move.w  d3, VDP_DATA
    bra     .lfcn
.lfrate:
    move.b  d2, d3                          ; RATE high nibble (VDP auto-advances)
    lsr.b   #4, d3
    move.b  d1, d4
    bsr     draw_hex1
    move.b  d2, d3                          ; RATE low nibble
    move.b  d1, d4
    bsr     draw_hex1
    bra     .lfcn
.lfprm:
    lea     lf_pnames, a1                   ; a1 += value * 4
    lsl.w   #2, d2
    adda.w  d2, a1
    moveq   #4-1, d3
    bra.s   .lf3
.lfsyn:
    lea     lf_snames, a1                   ; a1 += value * 5
    move.w  d2, d0
    add.w   d0, d0
    add.w   d0, d0
    add.w   d2, d0
    adda.w  d0, a1
    moveq   #5-1, d3
.lf3:
    moveq   #0, d0
    move.b  (a1)+, d0
    add.w   d1, d0                          ; + highlight (inverse-tile offset)
    move.w  d0, VDP_DATA
    dbra    d3, .lf3
.lfcn:
    addq.w  #1, d7
    cmpi.w  #9, d7
    bne     .lfc
    addq.w  #1, d6
    cmpi.w  #NLFO, d6
    bne     .lfr
    rts

; ---- per-frame smooth AMP-column update (called from the vblank tail). Writes just the 16
; AMP cells (col 30), so it fits the vblank budget unlike a full-grid redraw. No-op off the
; LFO screen / when stopped (the gated redraw already left those cells blank). ----
amp_refresh:
    cmpi.b  #SCR_LFO, cur_screen
    bne.s   .arret
    tst.b   playing
    beq.s   .arret
    lea     VDP_CTRL, a0
    lea     lfo_cfg, a2
    lea     lfo_amp, a3
    moveq   #0, d6
.arl:
    moveq   #0, d0                           ; VRAM addr at (row 6+i, col 30)
    move.w  d6, d0
    addi.w  #6, d0
    lsl.w   #6, d0
    addi.w  #30, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  #$20, d3                         ; blank, or bar $E9+amp if this LFO is on
    btst    #0, (a2)
    beq.s   .arw
    moveq   #0, d3
    move.b  (a3,d6.w), d3
    addi.w  #$E9, d3
.arw:
    move.w  d3, VDP_DATA
    lea     LF_SIZE(a2), a2
    addq.w  #1, d6
    cmpi.w  #NLFO, d6
    bne.s   .arl
.arret:
    rts
lf_col:                                     ; per column: lfo_cfg field offset, kind
    dc.b LF_FLAGS, 1                        ; ON  (bit 0)
    dc.b LF_CHAN,  0                        ; CH  target channel
    dc.b LF_PARM,  0                        ; PM  target FM parameter
    dc.b LF_RATE,  0                        ; RT
    dc.b LF_DEPTH, 0                        ; DP
    dc.b LF_FLAGS, 2                        ; SY  resync (bits 1-2)
    dc.b LF_POFF,  0                        ; PO  phase offset
    dc.b LF_FLAGS, 3                        ; DIR  shape (bits 3-4)
    dc.b LF_FLAGS, 0                        ; AMP  display-only live bar (value ignored)
    even
lf_colx: dc.b 3, 6, 9, 15, 18, 20, 26, 28, 30 ; 9 cols: ON CH PARAM R % SYNC PO DIR AMP
    even
dir_glyph: dc.b $7F, $7E, $7C              ; DIR 0 BOTH=updown, 1 UP, 2 DOWN -> arrow tiles
    even
lf_pnames:                                  ; 34 FM-param names (4 chars), in fmlfo_ptab order
    dc.b "TL1 TL3 TL2 TL4 DT1 DT3 DT2 DT4 MUL1MUL3MUL2MUL4FB  ALGO"
    dc.b "AR1 AR3 AR2 AR4 D1R1D1R3D1R2D1R4D2R1D2R3D2R2D2R4"
    dc.b "RR1 RR3 RR2 RR4 SL1 SL3 SL2 SL4 "
    even
lf_snames: dc.b "NOTE PHRSEFREE "           ; resync modes (5 chars): NOTE / PHRASE / FREE
    even
str_lfo_hdr: dc.b "ON CH PARAM R  % SYNC  ` ",$7F," A",0
    even

; ---- edit the FM LFO cell at (cur_row, cur_col). d2 = d-pad mask. a3 = the LFO record. ----
edit_lfo:
    moveq   #0, d0
    move.b  cur_row, d0
    mulu.w  #LF_SIZE, d0
    lea     lfo_cfg, a3
    adda.w  d0, a3
    moveq   #0, d0
    move.b  cur_col, d0
    bne.s   .el_nc0
    btst    #2, d2                          ; col 0 ON: Left/Down off, Right/Up on
    bne.s   .el_off
    btst    #1, d2
    bne.s   .el_off
    bset    #0, (LF_FLAGS,a3)
    rts
.el_off:
    bclr    #0, (LF_FLAGS,a3)
    rts
.el_nc0:
    cmpi.b  #5, d0
    beq.s   .el_cyc1                        ; col 5 SYNC -> 2-bit field at bit 1
    cmpi.b  #7, d0
    bne.s   .el_field
    moveq   #3, d0                          ; col 7 DIR -> 2-bit field at bit 3
    bra.s   .el_cyc
.el_cyc1:
    moveq   #1, d0
.el_cyc:
    move.b  (LF_FLAGS,a3), d3               ; cycle the 2-bit field (shift d0) over 0..2
    move.b  d3, d1
    lsr.b   d0, d1
    andi.b  #3, d1
    btst    #2, d2
    bne.s   .el_sdec
    btst    #1, d2
    bne.s   .el_sdec
    addq.b  #1, d1
    cmpi.b  #3, d1
    blo.s   .el_sset
    moveq   #0, d1
    bra.s   .el_sset
.el_sdec:
    subq.b  #1, d1
    bpl.s   .el_sset
    moveq   #2, d1
.el_sset:
    moveq   #3, d4                          ; clear the field (3 << shift), then insert
    lsl.b   d0, d4
    not.b   d4
    and.b   d4, d3
    lsl.b   d0, d1
    or.b    d1, d3
    move.b  d3, (LF_FLAGS,a3)
    rts
.el_field:
    lea     lf_emax, a1                     ; cols 1-4 + 6 via adj_field
    moveq   #0, d3
    move.b  (a1,d0.w), d3                   ; column max
    moveq   #1, d4                           ; U/D step: RATE (full byte) jumps 16, others 1
    cmpi.b  #3, d0
    bne.s   .elf1
    moveq   #16, d4
.elf1:
    add.w   d0, d0
    lea     lf_col, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1                   ; field offset
    lea     0(a3,d1.w), a1
    bra     adj_field
lf_emax: dc.b 0, 5, FMLFO_NPARM-1, 255, 15, 0, 15, 0  ; max per col (CH=FM 0-5; RATE byte; PO 0-15; DIR special)
    even

; WAVE instrument page: a row x col grid. Rows WAVE / ENV / VOL / FOLD / DRIVE /
; CRUSH / PITCH; the 6 LFO rows have OFFSET/RATE/DEPTH columns (WAVE = wave#, ENV = the
; AHD ATK/HLD/DCY). Cursor = (cur_row 0..7, cur_col 0..2). Plus the live shape preview.
render_wave_inst:                          ; a0 = VDP_CTRL
    bsr     render_inst_hdr               ; a3 = instrum[cur_instr]
    moveq   #8, d3                          ; "OFF RAT DEP" header (row 8; col 8 aligns INST/WAVE)
    moveq   #8, d4
    lea     str_grid_hdr, a1
    bsr     print_at
    moveq   #0, d6                          ; grid row r = 0..7
.wgr:
    lea     wgrid_srow, a1                 ; screen row for this grid row
    moveq   #0, d5
    move.b  (a1,d6.w), d5
    move.w  d5, d3                          ; row label at (srow, col1)
    moveq   #1, d4
    move.w  d6, d0
    lsl.w   #2, d0
    lea     wgrid_lbl, a1
    move.l  (a1,d0.w), a1
    bsr     print_at
    moveq   #0, d7                          ; col c = 0..2
.wgc:
    move.w  d6, d0                          ; field = wgrid_off[r*3 + c]
    add.w   d0, d0
    add.w   d6, d0
    add.w   d7, d0
    lea     wgrid_off, a1
    moveq   #0, d1
    move.b  (a1,d0.w), d1
    cmpi.b  #$FF, d1
    beq.s   .wgcn                           ; empty cell
    move.b  (a3,d1.w), d1                  ; value at instrument + field offset
    moveq   #0, d2                          ; highlight the cursor cell (cur_row-2 = grid row)
    move.b  cur_row, d0
    subq.b  #2, d0
    cmp.b   d6, d0
    bne.s   .wgnh
    move.b  cur_col, d0
    cmp.b   d7, d0
    bne.s   .wgnh
    moveq   #$60, d2
.wgnh:
    move.w  d7, d4                          ; cell column = 8 + c*4 (aligns with INST/WAVE at col 8)
    lsl.w   #2, d4
    addi.w  #8, d4
    moveq   #0, d3                          ; VDP addr at (srow, cellcol), clear hi word first
    move.w  d5, d3
    lsl.w   #6, d3
    add.w   d4, d3
    add.w   d3, d3
    swap    d3
    ori.l   #$40000003, d3
    move.l  d3, (a0)
    move.b  d1, d3                          ; value
    move.b  d2, d4                          ; highlight offset
    bsr     draw_hex1
.wgcn:
    addq.w  #1, d7
    cmpi.w  #3, d7
    bne.s   .wgc
    addq.w  #1, d6
    cmpi.w  #8, d6
    bne     .wgr
    ; --- waveform-operations preview (shape only, full scale) under the fields ---
    movea.l a3, a1                          ; a1 = current instrument (a3 held through the loop)
    moveq   #0, d0
    move.b  (iw_wave,a1), d0
    andi.w  #15, d0
    lsl.w   #5, d0
    lea     wave_ram, a5
    adda.w  d0, a5                          ; a5 = base wave
    move.b  #15, wbake_in                  ; preview = static offsets, full scale (no LFO/env)
    move.b  (iw_warp,a1), wbake_in+1
    move.b  (iw_fold,a1), wbake_in+2
    move.b  (iw_drive,a1), wbake_in+3
    move.b  (iw_crush,a1), wbake_in+4
    bsr     bake_wave                       ; WAVE# -> WARP -> DRIVE -> FOLD -> CRUSH -> wave_bake
    bsr     plot_wave_preview
    rts

; ---- plot wave_bake (32 samples) as a 32-col x 8-row bar scope, top-left = (PREV_TOP,
; PREV_COL). Shows the shaped wave only. Clobbers d0-d5/d7/a1-a3 (a0 = VDP_CTRL kept). ----
plot_wave_preview:
    lea     wave_bake, a3
    moveq   #0, d7                          ; scope row R = 0..7 (centre between 3 and 4)
.ppr:
    lea     wave_rowbuf, a2
    moveq   #0, d5                          ; sample 0..31
.pps:
    moveq   #0, d1
    move.b  (a3,d5.w), d1
    subi.w  #128, d1                       ; deviation -128..127
    asr.w   #5, d1                          ; n = -4..3 (8 rows tall)
    moveq   #$20, d2                        ; blank cell
    cmpi.w  #4, d7
    bhs.s   .ppdn
    tst.w   d1                              ; upper rows 0..3: fill iff n>0 and R >= 4-n
    ble.s   .ppc
    moveq   #4, d3
    sub.w   d1, d3
    cmp.w   d7, d3
    bgt.s   .ppc
    moveq   #$80, d2
    bra.s   .ppc
.ppdn:
    tst.w   d1                              ; lower rows 4..7: fill iff n<0 and (R-4) < -n
    bge.s   .ppc
    neg.w   d1
    move.w  d7, d3
    subi.w  #4, d3
    cmp.w   d1, d3
    bge.s   .ppc
    moveq   #$80, d2
.ppc:
    cmpi.w  #3, d7                          ; centre line through blank cells just above centre
    bne.s   .ppw
    cmpi.b  #$20, d2
    bne.s   .ppw
    move.b  #$E0, d2
.ppw:
    move.b  d2, (a2)+
    addq.w  #1, d5
    cmpi.w  #32, d5
    bne.s   .pps
    clr.b   (a2)
    move.w  d7, d3                          ; print this row
    addi.w  #PREV_TOP, d3
    moveq   #PREV_COL, d4
    lea     wave_rowbuf, a1
    bsr     print_at
    addq.w  #1, d7
    cmpi.w  #8, d7
    bne     .ppr
    rts

; WAVE B-held gestures (entered by branch from the input dispatch, so it must rts):
; B+Up/Down pens the current step's level; B+Left/Right draws the current value to the
; neighbour and moves there (sweep to paint); B+C cycles a preset.
wave_bheld:
    btst    #6, d4                          ; B + C tap -> cycle preset
    beq.s   .wbdp
    bsr     wave_preset
    rts
.wbdp:
    lea     wave_ram, a1                    ; a1+d0 = current step's byte
    moveq   #0, d0
    move.b  cur_wave, d0
    lsl.w   #5, d0
    moveq   #0, d1
    move.b  cur_wstep, d1
    add.w   d1, d0
    btst    #0, d5                          ; Up -> level += PEN_STEP (clamp $FF)
    beq.s   .wbnu
    moveq   #0, d2
    move.b  (a1,d0.w), d2
    addi.w  #PEN_STEP, d2
    cmpi.w  #255, d2
    bls.s   .wbu1
    move.w  #255, d2
.wbu1:
    move.b  d2, (a1,d0.w)
    move.b  #1, vdirty
.wbnu:
    btst    #1, d5                          ; Down -> level -= PEN_STEP (clamp 0)
    beq.s   .wbnd
    moveq   #0, d2
    move.b  (a1,d0.w), d2
    subi.w  #PEN_STEP, d2
    bpl.s   .wbd1
    moveq   #0, d2
.wbd1:
    move.b  d2, (a1,d0.w)
    move.b  #1, vdirty
.wbnd:
    btst    #3, d5                          ; Right -> draw value to step+1, move there
    beq.s   .wbnr
    cmpi.b  #31, cur_wstep
    bhs.s   .wbnr
    move.b  (a1,d0.w), d2
    move.b  d2, 1(a1,d0.w)
    addq.b  #1, cur_wstep
    move.b  #1, vdirty
.wbnr:
    btst    #2, d5                          ; Left -> draw value to step-1, move there
    beq.s   .wbdone
    tst.b   cur_wstep
    beq.s   .wbdone
    move.b  (a1,d0.w), d2
    move.b  d2, -1(a1,d0.w)
    subq.b  #1, cur_wstep
    move.b  #1, vdirty
.wbdone:
    rts

; B+C: stamp the next preset onto the current wave, cycling through the set.
wave_preset:
    lea     wave_ram, a2
    moveq   #0, d0
    move.b  cur_wave, d0
    lsl.w   #5, d0
    adda.w  d0, a2                          ; a2 = current wave (32 bytes)
    moveq   #0, d1
    move.b  wave_pidx, d1                   ; preset to apply
    move.b  d1, d0
    addq.b  #1, d0                          ; advance + wrap for next press
    andi.b  #7, d0
    move.b  d0, wave_pidx
    move.b  #1, vdirty
    lsl.w   #2, d1                          ; *4 (long jump-table entries)
    lea     .jtab(pc), a1
    move.l  (a1,d1.w), a1
    jmp     (a1)
.jtab:
    dc.l    wp_sine, wp_tri, wp_saw, wp_square
    dc.l    wp_p25, wp_p125, wp_organ, wp_random

wp_sine:
    lea     wave_sintab, a1
    moveq   #32-1, d0
.s:
    move.b  (a1)+, (a2)+
    dbra    d0, .s
    rts
wp_organ:                                   ; 2nd harmonic of the sine (2 cycles)
    lea     wave_sintab, a1
    moveq   #0, d0
.o:
    move.w  d0, d1
    add.w   d1, d1
    andi.w  #31, d1
    move.b  (a1,d1.w), (a2)+
    addq.w  #1, d0
    cmpi.w  #32, d0
    bne.s   .o
    rts
wp_saw:
    moveq   #0, d0
.s:
    move.b  d0, d1
    lsl.b   #3, d1                          ; step*8
    move.b  d1, (a2)+
    addq.b  #1, d0
    cmpi.b  #32, d0
    bne.s   .s
    rts
wp_tri:
    moveq   #0, d0
.t:
    move.w  d0, d1
    cmpi.w  #16, d1
    blo.s   .up
    moveq   #31, d2
    sub.w   d1, d2                          ; 31-s on the falling half
    move.w  d2, d1
.up:
    lsl.w   #4, d1                          ; *16
    cmpi.w  #255, d1
    bls.s   .ok
    move.w  #255, d1
.ok:
    move.b  d1, (a2)+
    addq.w  #1, d0
    cmpi.w  #32, d0
    bne.s   .t
    rts
wp_square:                                  ; 50% duty
    moveq   #16, d2
    bra.s   wp_pulse
wp_p25:                                     ; 25% duty
    moveq   #8, d2
    bra.s   wp_pulse
wp_p125:                                    ; 12.5% duty
    moveq   #4, d2
wp_pulse:
    moveq   #0, d0
.p:
    cmp.b   d2, d0
    bhs.s   .lo
    move.b  #$FF, (a2)+
    bra.s   .pn
.lo:
    clr.b   (a2)+
.pn:
    addq.b  #1, d0
    cmpi.b  #32, d0
    bne.s   .p
    rts
wp_random:
    move.l  wave_rng, d0
    move.w  g_ticks, d1                     ; mix in the tick so it differs each press
    add.l   d1, d0
    moveq   #32-1, d1
.r:
    move.l  d0, d2                          ; xorshift32
    lsl.l   #7, d2
    eor.l   d2, d0
    move.l  d0, d2
    lsr.l   #5, d2
    eor.l   d2, d0
    move.l  d0, d2
    lsl.l   #3, d2
    eor.l   d2, d0
    move.l  d0, d2
    swap    d2
    move.b  d2, (a2)+
    dbra    d1, .r
    move.l  d0, wave_rng
    rts

wave_sintab:                                ; $80 +/- 127*sin, 32 steps
    dc.b    $80,$99,$B1,$C7,$DA,$EA,$F5,$FD,$FF,$FD,$F5,$EA,$DA,$C7,$B1,$99
    dc.b    $80,$67,$4F,$39,$26,$16,$0B,$03,$01,$03,$0B,$16,$26,$39,$4F,$67
    even

; WAVE screen: 32 centred bars (one column per step, cols 2-33, canvas rows 6-21).
; Centre line between R=7 (row13) and R=8 (row14); value $80 = centre. Each row is
; built as a 32-char string in wave_rowbuf and drawn with print_at (the proven path).
render_wave:
    lea     wave_ram, a3                  ; a3 = current wave
    moveq   #0, d0
    move.b  cur_wave, d0
    lsl.w   #5, d0                         ; cur_wave * 32
    adda.w  d0, a3
    moveq   #0, d7                         ; canvas row R = 0..15 (screen row 8+R)
    lea     wave_rowbuf, a2               ; top border (row 7): TL + 32x top-edge + TR
    move.b  #$E5, (a2)+
    moveq   #32-1, d5
.wtop:
    move.b  #$E1, (a2)+
    dbra    d5, .wtop
    move.b  #$E6, (a2)+
    clr.b   (a2)
    moveq   #7, d3
    moveq   #0, d4
    lea     wave_rowbuf, a1
    bsr     print_at
.wr:
    lea     wave_rowbuf, a2               ; build this row's string ($E3 = left border edge)
    move.b  #$E3, (a2)+
    moveq   #0, d5                         ; step S = 0..31
.ws:
    moveq   #0, d1
    move.b  (a3,d5.w), d1                  ; value 0..255
    subi.w  #128, d1                       ; deviation -128..127
    asr.w   #4, d1                         ; n = rows, -8..7 (signed)
    moveq   #$20, d2                       ; default cell = blank (space)
    cmpi.w  #8, d7
    bhs.s   .wdn
    tst.w   d1                             ; up region (R 0..7): fill iff n>0 and R >= 8-n
    ble.s   .wput
    moveq   #8, d3
    sub.w   d1, d3
    cmp.w   d7, d3
    bgt.s   .wput
    moveq   #$80, d2                       ; solid block (inverse space)
    bra.s   .wput
.wdn:
    tst.w   d1                             ; down region (R 8..15): fill iff n<0 and (R-8) < -n
    bge.s   .wput
    neg.w   d1
    move.w  d7, d3
    subi.w  #8, d3
    cmp.w   d1, d3
    bge.s   .wput
    moveq   #$80, d2
.wput:
    cmpi.w  #7, d7                          ; centre line: line tile through blank cells at R=7
    bne.s   .wputw
    cmpi.b  #$20, d2
    bne.s   .wputw
    move.b  #$E0, d2                        ; centre-line tile (1px lower than the old '_')
.wputw:
    move.b  d2, (a2)+                      ; append cell to the row string
    addq.w  #1, d5
    cmpi.w  #32, d5
    bne.s   .ws
    move.b  #$E4, (a2)+                     ; right border edge (col 33)
    clr.b   (a2)                            ; NUL-terminate
    move.w  d7, d3                          ; print row at (screen row 8+R, col 0)
    addi.w  #8, d3
    moveq   #0, d4
    lea     wave_rowbuf, a1
    bsr     print_at                        ; preserves d7/a3; clobbers d0,d1,a1
    addq.w  #1, d7
    cmpi.w  #16, d7
    bne.s   .wr
    lea     wave_rowbuf, a2               ; bottom border (row 24): BL + 32x bottom-edge + BR
    move.b  #$E7, (a2)+
    moveq   #32-1, d5
.wbot:
    move.b  #$E2, (a2)+
    dbra    d5, .wbot
    move.b  #$E8, (a2)+
    clr.b   (a2)
    moveq   #24, d3
    moveq   #0, d4
    lea     wave_rowbuf, a1
    bsr     print_at
    ; cursor marker row (row 6): blank except the current step's column
    lea     wave_rowbuf, a2
    moveq   #0, d6
    move.b  cur_wstep, d6
    moveq   #0, d5
.wcm:
    moveq   #$20, d1
    cmp.w   d5, d6
    bne.s   .wcm2
    moveq   #$80, d1                        ; solid block above the current step
.wcm2:
    move.b  d1, (a2)+
    addq.w  #1, d5
    cmpi.w  #32, d5
    bne.s   .wcm
    clr.b   (a2)
    moveq   #25, d3                         ; cursor marker on row 25 (just below the canvas box)
    moveq   #1, d4
    lea     wave_rowbuf, a1
    bsr     print_at
    ; status line (row 3, just below the WAVEFORM title): WAVE n   STEP ss   LVL vv
    moveq   #3, d3
    moveq   #1, d4
    lea     str_w_wave, a1
    bsr     print_at
    move.l  #$418C0003, (a0)               ; (3,6) wave number
    move.b  cur_wave, d3
    moveq   #0, d4
    bsr     draw_hex1
    moveq   #3, d3
    moveq   #8, d4
    lea     str_w_step, a1
    bsr     print_at
    move.l  #$419A0003, (a0)               ; (3,13) step
    move.b  cur_wstep, d3
    moveq   #0, d4
    bsr     draw_hex2
    moveq   #3, d3
    moveq   #16, d4
    lea     str_w_lvl, a1
    bsr     print_at
    move.l  #$41A80003, (a0)               ; (3,20) level = value at cursor
    lea     wave_ram, a1
    moveq   #0, d0
    move.b  cur_wave, d0
    lsl.w   #5, d0
    moveq   #0, d1
    move.b  cur_wstep, d1
    add.w   d1, d0
    move.b  (a1,d0.w), d3
    moveq   #0, d4
    bsr     draw_hex2
    move.b  #1, vdirty                    ; re-render next frame (entry frame overruns)
    rts
str_w_wave: dc.b "WAVE",0
str_w_step: dc.b "STEP",0
str_w_lvl:  dc.b "LVL",0
    even

; KIT instrument page: the kit selector + a fill map of its 16 pads.
render_kit:
    bsr     render_inst_hdr
    moveq   #5, d6                          ; blank the FM-page body (rows 5-27) before drawing,
.rkclr:                                      ; else the algo diagram / op grid / env curves linger
    moveq   #0, d0
    move.w  d6, d0
    lsl.w   #6, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #39, d5
.rkclrc:
    move.w  #' ', VDP_DATA
    dbra    d5, .rkclrc
    addq.w  #1, d6
    cmpi.w  #28, d6
    bne.s   .rkclr
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    moveq   #6, d3                          ; "KIT" + kit index at row 6 (cur_row 2; blank row 5 = spacer)
    moveq   #1, d4
    lea     str_kit, a1
    bsr     print_at
    move.l  #$43100003, (a0)               ; kit index at row 6 col 8
    move.b  (i_kit,a3), d3
    moveq   #0, d4
    cmpi.b  #2, cur_row
    bne.s   .rk1
    moveq   #$60, d4                         ; highlight the KIT field row
.rk1:
    bsr     draw_hex2
    moveq   #7, d3                          ; "RATE" + value at row 7 (cur_row 3)
    moveq   #1, d4
    lea     str_rate, a1
    bsr     print_at
    moveq   #0, d2                           ; highlight the RATE field row?
    cmpi.b  #3, cur_row
    bne.s   .rk2
    moveq   #$60, d2
.rk2:
    moveq   #0, d1
    move.b  (i_rate,a3), d1
    andi.w  #3, d1
    lsl.w   #2, d1
    lea     kit_rate_lbl, a1
    move.l  (a1,d1.w), a1                    ; rate name (.5X / 1X / 2X / 4X)
    moveq   #7, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #8, d3                          ; "TSP" + value at row 8 (cur_row 4)
    moveq   #1, d4
    lea     str_tsp, a1
    bsr     print_at
    move.l  #$44100003, (a0)               ; TSP value at row 8 col 8
    move.b  (i_tsp,a3), d3
    moveq   #0, d4
    cmpi.b  #4, cur_row
    bne.s   .rktsp
    moveq   #$60, d4                         ; highlight the TSP field row
.rktsp:
    bsr     draw_hex2
    moveq   #10, d3                         ; "PADS" + 16 fill markers at row 10 (blank row 9 = spacer)
    moveq   #1, d4
    lea     str_pads, a1
    bsr     print_at
    move.l  #$450C0003, (a0)               ; markers at row 10 col 6
    lea     sample_pool, a4
    adda.w  #16, a4                          ; skip the magic header -> directory
    moveq   #0, d2
    move.b  (i_kit,a3), d2
    andi.w  #15, d2                          ; clamp kit 0..15
    lsl.w   #8, d2                          ; kit * 256 (16 members x 16 bytes)
    adda.w  d2, a4
    moveq   #15, d5
.rkpad:
    move.l  4(a4), d0                       ; member length (0 = empty pad)
    moveq   #'-', d1
    tst.l   d0
    beq.s   .rkpe
    moveq   #'#', d1
.rkpe:
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    lea     16(a4), a4
    dbra    d5, .rkpad
    rts

PSG_TOP equ 6                             ; PSG field list top row
; TONE/NOISE instrument page: INST/TYPE header + a data-driven field list
render_tone:
    moveq   #10, d7                        ; VOL ATK HLD DCY TSP SWP VIB TRM TBL TBS
    bra.s   render_psg
render_noise:
    moveq   #12, d7                        ; + MODE RATE
render_psg:                               ; d7 = field count; a0 = VDP_CTRL
    bsr     render_inst_hdr               ; a3 = instrum[cur_instr]
    moveq   #0, d6                         ; field index
.prow:
    move.w  d6, d5                          ; display row = PSG_TOP + idx + group gaps
    addi.w  #PSG_TOP, d5                    ;   blank row after VOL(0), DCY(3), TRM(7), TBS(9)
    cmpi.w  #1, d6
    blo.s   .nog
    addq.w  #1, d5
    cmpi.w  #4, d6
    blo.s   .nog
    addq.w  #1, d5
    cmpi.w  #8, d6
    blo.s   .nog
    addq.w  #1, d5
    cmpi.w  #10, d6
    blo.s   .nog
    addq.w  #1, d5
.nog:
    move.w  d5, d3                          ; label at (row, col1)
    moveq   #1, d4
    move.w  d6, d0
    lsl.w   #2, d0
    lea     psg_lbl, a1
    move.l  (a1,d0.w), a1
    bsr     print_at
    lea     psg_off, a1                    ; value -> d1
    moveq   #0, d0
    move.b  (a1,d6.w), d0
    move.b  (a3,d0.w), d1
    moveq   #0, d2                          ; highlight offset (cur_row-2 == idx)
    move.b  cur_row, d0
    subq.b  #2, d0
    cmp.b   d6, d0
    bne.s   .pnh
    moveq   #$60, d2
.pnh:
    lea     psg_fmt, a1                    ; format dispatch
    move.b  (a1,d6.w), d0
    cmpi.b  #4, d0                          ; TBL: "--" when none ($FF), else the table # in hex2
    bne.s   .nottbl4
    cmpi.b  #$FF, d1
    bne.s   .ptbl_hex
    lea     str_none, a1                   ; no table -> "--"
    move.w  d5, d3
    moveq   #8, d4
    bsr     print_hl
    bra     .pnext
.ptbl_hex:
    moveq   #1, d0                          ; has a table -> fall through as hex2
.nottbl4:
    cmpi.b  #2, d0
    beq.s   .pmode
    cmpi.b  #3, d0
    beq.s   .prate
    moveq   #0, d3                          ; hex: value cell at (row, col8)
    move.w  d5, d3
    lsl.w   #6, d3
    addi.w  #8, d3
    add.w   d3, d3
    swap    d3
    ori.l   #$40000003, d3
    move.l  d3, (a0)
    move.b  d1, d3                          ; value
    move.b  d2, d4                          ; offset
    tst.b   d0
    beq.s   .ph1
    bsr     draw_hex2
    bra.s   .pnext
.ph1:
    bsr     draw_hex1
    bra.s   .pnext
.pmode:
    lea     mode_lbl, a1
    andi.w  #1, d1
    lsl.w   #2, d1
    move.l  (a1,d1.w), a1
    bra.s   .penum
.prate:
    lea     rate_lbl, a1
    andi.w  #3, d1
    lsl.w   #2, d1
    move.l  (a1,d1.w), a1
.penum:
    move.w  d5, d3                          ; print_hl(str, row, col8, offset d2)
    moveq   #8, d4
    bsr     print_hl
.pnext:
    addq.w  #1, d6
    cmp.w   d7, d6
    bne     .prow
    rts

render_fm:                                ; a0 = VDP_CTRL
    bsr     render_inst_hdr               ; INST + TYPE; a3 = instrum[cur_instr]
    moveq   #0, d6                         ; voice param: HLD VOL PAN TSP | ALGO FB AMS FMS
.vrow:
    move.w  d6, d3                          ; label at (FM_VTOP+idx, col1)
    addi.w  #FM_VTOP, d3
    cmpi.w  #4, d6                          ; blank row after TSP (splits channel | FM items)
    blo.s   .vng1
    addq.w  #1, d3
.vng1:
    moveq   #1, d4
    move.w  d6, d0
    lsl.w   #2, d0
    lea     voice_lbl, a1
    move.l  (a1,d0.w), a1
    bsr     print_at
    moveq   #0, d0                          ; value at (FM_VTOP+idx, col8)
    move.w  d6, d0
    addi.w  #FM_VTOP, d0
    cmpi.w  #4, d6
    blo.s   .vng2
    addq.w  #1, d0
.vng2:
    lsl.w   #6, d0
    addi.w  #8, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    lea     voice_off, a1
    moveq   #0, d0
    move.b  (a1,d6.w), d0
    move.b  (a3,d0.w), d3                  ; value
    moveq   #0, d4
    move.b  cur_row, d1                    ; highlight if cur_row-2 == voice idx
    subq.b  #2, d1
    cmp.b   d6, d1
    bne.s   .vnh
    moveq   #$60, d4
.vnh:
    lea     voice_fmt, a1                  ; TSP (fmt 1) draws 2 hex digits; the rest 1
    tst.b   (a1,d6.w)
    beq.s   .vh1
    move.b  d3, d2
    lsr.b   #4, d3
    bsr     draw_hex1
    move.b  d2, d3
    bsr     draw_hex1
    bra.s   .vdone
.vh1:
    bsr     draw_hex1
.vdone:
    addq.w  #1, d6
    cmpi.w  #NVOICE, d6
    bne.s   .vrow
    moveq   #FM_OHDR, d3                    ; operator grid header (LFO moved to PROJECT screen)
    moveq   #1, d4
    lea     str_hdr_fm, a1
    bsr     print_at
    moveq   #0, d6                          ; operator row 0..3
.oprow:
    moveq   #0, d0                          ; "OPn" at (FM_OTOP+op, col1)
    move.w  d6, d0
    addi.w  #FM_OTOP, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0
    add.w   d6, d0
    add.w   d6, d0                         ; op * 3
    lea     op_names, a1
    adda.w  d0, a1
    moveq   #2, d2
.oplbl:
    move.b  (a1)+, d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d2, .oplbl
    moveq   #0, d5                         ; param 0..7
.parm:
    moveq   #0, d0                         ; addr at (FM_OTOP+op, fm_scol[param])
    move.w  d6, d0
    addi.w  #FM_OTOP, d0
    lsl.w   #6, d0
    lea     fm_scol, a1
    moveq   #0, d1
    move.b  (a1,d5.w), d1
    add.w   d1, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d6, d0                         ; value = a3[i_op + op*10 + param]
    mulu.w  #FM_NPARM, d0
    add.w   d5, d0
    move.b  (i_op,a3,d0.w), d3
    moveq   #0, d4                          ; highlight if cur_row==NVOICE+2+op && cur_col==param
    move.b  cur_row, d1
    subi.b  #NVOICE+2, d1
    cmp.b   d6, d1
    bne.s   .nhl
    move.b  cur_col, d1
    cmp.b   d5, d1
    bne.s   .nhl
    moveq   #$60, d4
.nhl:
    lea     fm_pmax, a1                    ; max <= 15 -> show one nibble, else two
    move.b  (a1,d5.w), d1
    cmpi.b  #16, d1
    bhs.s   .wide
    bsr     draw_hex1
    bra.s   .pnext
.wide:
    bsr     draw_hex2
.pnext:
    addq.w  #1, d5
    cmpi.w  #FM_NPARM, d5
    bne     .parm
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .oprow
    bsr     draw_algo_diagram             ; a3 still = instrum[cur_instr]
    moveq   #0, d5                         ; OP labels centered under each envelope box
.eolbl:
    moveq   #0, d0                          ; clear high word (swap below puts it in cmd low!)
    move.w  d5, d0
    lsl.w   #3, d0                         ; slot*8
    addi.w  #ENV_LBLROW*64+ENV_COL+2, d0   ; row 25, col = ENV_COL+2 + slot*8 (centered)
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d5, d0                         ; op_names[slot*3 .. +2] = OP1/OP3/OP2/OP4
    add.w   d5, d0
    add.w   d5, d0
    lea     op_names, a1
    adda.w  d0, a1
    moveq   #2, d6
.eolc:
    move.b  (a1)+, d0
    andi.w  #$00FF, d0
    move.w  d0, VDP_DATA
    dbra    d6, .eolc
    addq.w  #1, d5
    cmpi.w  #4, d5
    bne.s   .eolbl
    rts

; draw the current algorithm's routing diagram (tilemap) for instrum a3
draw_algo_diagram:                        ; a0 = VDP_CTRL, a3 = instrument
    moveq   #0, d0
    move.b  (i_algo,a3), d0
    andi.w  #7, d0
    mulu.w  #ALGO_MAPSZ, d0
    lea     algo_maps, a2
    adda.w  d0, a2                         ; a2 = this algorithm's tilemap
    moveq   #0, d5                         ; tile row 0..ALGO_H-1
.ar:
    moveq   #0, d0                         ; addr at (ALGO_DIAG_ROW+row, ALGO_DIAG_COL)
    move.w  d5, d0
    addi.w  #ALGO_DIAG_ROW, d0
    lsl.w   #6, d0
    addi.w  #ALGO_DIAG_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    moveq   #ALGO_W-1, d6
.ac:
    moveq   #0, d1
    move.b  (a2)+, d1
    addi.w  #ALGO_TILEBASE, d1
    move.w  d1, VDP_DATA
    dbra    d6, .ac
    addq.w  #1, d5
    cmpi.w  #ALGO_H, d5
    bne.s   .ar
    rts

; ---- envelope diagram -----------------------------------------------------
; rasterise the current operator's ADSR shape into env_canvas, then DMA it.
; the envelope is y = f(x), so each column is one y -> no general line algo;
; consecutive columns are joined with a vertical run (env_colpix).
; env_rasterize: draw the curve into env_canvas (RAM only -- runs in the main
; loop, NOT in VBlank: it is far too heavy for the ~18k-cycle VBlank budget).
env_rasterize:
    lea     instrum, a3
    moveq   #0, d0
    move.b  cur_instr, d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3                         ; a3 = instrum[cur_instr]
    lea     env_canvas, a1                 ; clear the whole bitmap (all 4 envelopes)
    move.w  #(ENV_TILES*32/4)-1, d0
    moveq   #0, d1
.declr:
    move.l  d1, (a1)+
    dbra    d0, .declr
    move.b  #0, env_slot                  ; draw each operator into its 64px sub-column
.deslot:
    moveq   #0, d0                         ; a4 = this slot's op params
    move.b  env_slot, d0
    mulu.w  #FM_NPARM, d0
    addi.w  #i_op, d0
    lea     0(a3,d0.w), a4
    moveq   #0, d0                         ; aPeak = (127-TL) * ENV_AMAX / 127
    move.b  (2,a4), d0
    neg.w   d0
    addi.w  #127, d0
    mulu.w  #ENV_AMAX, d0
    divu.w  #127, d0
    andi.l  #$FFFF, d0
    move.w  d0, d3                         ; d3 = aPeak
    moveq   #0, d0                         ; aSus = aPeak * (15-SL) / 15
    move.b  (9,a4), d0
    andi.w  #$0F, d0
    neg.w   d0
    addi.w  #15, d0
    mulu.w  d3, d0
    divu.w  #15, d0
    andi.l  #$FFFF, d0
    move.w  d0, d4                         ; d4 = aSus
    moveq   #0, d0                         ; aSus2 = aSus * (31-D2) / 31
    move.b  (7,a4), d0
    andi.w  #$1F, d0
    neg.w   d0
    addi.w  #31, d0
    mulu.w  d4, d0
    divu.w  #31, d0
    andi.l  #$FFFF, d0
    move.w  d0, d5                         ; d5 = aSus2
    moveq   #0, d6                         ; x base = slot*64 + 2 (1px inside the box left)
    move.b  env_slot, d6
    lsl.w   #6, d6
    addq.w  #2, d6
    lea     env_pts, a2                    ; build (x,a) breakpoints (widths halved)
    move.w  d6, (a2)+                      ; P0 x = base
    clr.w   (a2)+                          ;    a = 0
    moveq   #0, d0                         ; wA = (31-AR)>>1
    move.b  (4,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P1 x
    move.w  d3, (a2)+                      ;    a = aPeak
    moveq   #0, d0                         ; wD1 = (31-D1)>>1
    move.b  (6,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P2 x
    move.w  d4, (a2)+                      ;    a = aSus
    addi.w  #12, d6                        ; sustain hold (halved)
    move.w  d6, (a2)+                      ; P3 x
    move.w  d5, (a2)+                      ;    a = aSus2
    moveq   #0, d0                         ; wR = (31-RR)>>1
    move.b  (8,a4), d0
    andi.w  #$1F, d0
    moveq   #31, d1
    sub.w   d0, d1
    lsr.w   #1, d1
    add.w   d1, d6
    move.w  d6, (a2)+                      ; P4 x
    clr.w   (a2)+                          ;    a = 0
    bsr     env_decor                      ; box + dashed timing/amplitude guides (behind)
    move.w  #ENV_BOT, env_prevy            ; connector starts at this envelope's baseline
    lea     env_pts, a2                    ; draw the 4 segments
.deseg:
    move.w  (a2), d0
    move.w  2(a2), d1
    move.w  4(a2), d2
    move.w  6(a2), d3
    bsr     env_seg
    addq.l  #4, a2
    cmpa.l  #env_pts+16, a2
    bne.s   .deseg
    addq.b  #1, env_slot
    cmpi.b  #4, env_slot
    blo     .deslot
    rts

; env_upload: push ENV_CHUNK canvas tiles to VRAM and advance env_upos. Runs
; one chunk per idle VBlank frame -- a full 64-tile blit overruns H40 VBlank and
; tears the picture, so the upload is spread over several frames. Keeps env_ready
; set until the whole canvas (and the static nametable, written on the first
; chunk) has been sent. a0 = VDP_CTRL on entry.
env_upload:
    tst.b   env_ntdone                     ; nametable gets its own frame (128 words)
    bne.s   .eutiles
    st      env_ntdone
    move.b  #1, env_ready                  ; tiles follow on subsequent idle frames
    moveq   #0, d5
.eunrow:
    moveq   #0, d0                          ; clear high word (swap below puts it in cmd low!)
    move.w  d5, d0
    addi.w  #ENV_ROW, d0
    lsl.w   #6, d0
    addi.w  #ENV_COL, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
    move.w  d5, d1
    mulu.w  #ENV_TW, d1
    addi.w  #ENV_TILEBASE, d1
    moveq   #ENV_TW-1, d2
.euncol:
    move.w  d1, VDP_DATA
    addq.w  #1, d1
    dbra    d2, .euncol
    addq.w  #1, d5
    cmpi.w  #ENV_TH, d5
    bne.s   .eunrow
    rts                                       ; nametable done -> tiles next frame
.eutiles:
    move.w  env_upos, d1                   ; VRAM addr = ENV_VRAM + env_upos*32
    lsl.w   #5, d1
    addi.w  #ENV_VRAM, d1                   ; addr spans $3400..$43FF (crosses $4000!)
    move.w  d1, d2                          ; A15,A14 -> command low word bits 1,0
    rol.w   #2, d2
    andi.w  #3, d2
    moveq   #0, d0
    move.w  d1, d0
    andi.w  #$3FFF, d0                      ; A13..A0 -> high word
    swap    d0
    or.w    d2, d0
    ori.l   #$40000000, d0
    move.l  d0, (a0)
    lea     env_canvas, a1                 ; source = env_canvas + env_upos*32
    move.w  env_upos, d1
    lsl.w   #5, d1
    adda.w  d1, a1
    move.w  #(ENV_CHUNK*16)-1, d0
.eutc:
    move.w  (a1)+, VDP_DATA
    dbra    d0, .eutc
    addi.w  #ENV_CHUNK, env_upos           ; next chunk, or finish the burst
    cmpi.w  #ENV_TILES, env_upos
    blo.s   .eumore
    clr.w   env_upos
    rts
.eumore:
    move.b  #1, env_ready                  ; more chunks -> keep going next idle frame
    rts

; env_seg: draw segment (d0=x0,d1=a0) -> (d2=x1,d3=a1); joins from env_prevy.
; clobbers d0-d7,a1; preserves a0,a2,a3.
env_seg:
    move.w  d2, d4
    sub.w   d0, d4                         ; dx
    bne.s   .esm
    move.w  d0, d5                         ; dx=0: single column at x0
    move.w  #ENV_BOT, d6
    sub.w   d3, d6
    bra.s   env_colpix
.esm:
    move.w  d0, d5                         ; x = x0
.esl:
    move.w  d3, d6                         ; a = a0 + (a1-a0)*(x-x0)/dx
    sub.w   d1, d6
    move.w  d5, d7
    sub.w   d0, d7
    muls.w  d7, d6
    divs.w  d4, d6
    add.w   d1, d6
    bpl.s   .esp
    moveq   #0, d6
.esp:
    cmpi.w  #ENV_AMAX, d6
    bls.s   .esc
    move.w  #ENV_AMAX, d6
.esc:
    move.w  #ENV_BOT, d7
    sub.w   d6, d7
    move.w  d7, d6                         ; d6 = y
    bsr     env_colpix
    addq.w  #1, d5
    cmp.w   d2, d5
    ble.s   .esl
    rts

; env_colpix: at column d5=x, fill from env_prevy to d6=y; clobbers d6,d7; keeps d0-d5
env_colpix:
    move.w  d6, d7                         ; d7 = target y
    move.w  env_prevy, d6                  ; d6 = old prev = start of the run
    move.w  d7, env_prevy                  ; remember target for the next column
    cmp.w   d7, d6                         ; iterate d6 from prev toward target d7
    ble.s   .ecu
.ecd:
    bsr     env_setpix
    subq.w  #1, d6
    cmp.w   d7, d6
    bge.s   .ecd
    rts
.ecu:
    bsr     env_setpix
    addq.w  #1, d6
    cmp.w   d7, d6
    ble.s   .ecu
    rts

; env_setpix: set colour-1 pixel at (d5=x,d6=y) in env_canvas; preserves all but flags
env_setpix:
    cmpi.w  #ENV_W, d5                     ; clamp: an off-canvas pixel would scribble
    bhs.s   .spclip                        ; past the 4 KB bitmap into the instrument pool
    cmpi.w  #ENV_H, d6
    bhs.s   .spclip
    movem.l d0-d2/a1, -(sp)
    move.w  d6, d0
    lsr.w   #3, d0
    mulu.w  #ENV_TW, d0                    ; tile_row * ENV_TW
    move.w  d5, d1
    lsr.w   #3, d1
    add.w   d1, d0                         ; + tile_col = tile index
    lsl.w   #5, d0                         ; * 32 bytes
    move.w  d6, d1
    andi.w  #7, d1
    lsl.w   #2, d1                         ; (y&7) * 4
    add.w   d1, d0
    move.w  d5, d1
    andi.w  #7, d1
    lsr.w   #1, d1                         ; (x&7) >> 1 = byte within the tile row
    add.w   d1, d0                         ; byte offset
    lea     env_canvas, a1
    move.b  #$10, d2                       ; even x -> high nibble
    btst    #0, d5
    beq.s   .spw
    move.b  #$01, d2                       ; odd x -> low nibble
.spw:
    or.b    d2, (a1,d0.w)
    movem.l (sp)+, d0-d2/a1
.spclip:
    rts

; env_hl: horizontal line/dash. d2=x0, d3=x1, d4=y, d7=0 solid / 1 dashed. keeps d2-d4,d7.
env_hl:
    move.w  d2, d5
.hll:
    tst.w   d7
    beq.s   .hlp
    btst    #0, d5                          ; dashed: only even columns
    bne.s   .hls
.hlp:
    move.w  d4, d6
    bsr     env_setpix
.hls:
    addq.w  #1, d5
    cmp.w   d3, d5
    ble.s   .hll
    rts

; env_vl: vertical line/dash. d4=x, d2=y0, d3=y1, d7=0 solid / 1 dashed. keeps d2-d4,d7.
env_vl:
    move.w  d2, d6
.vll:
    tst.w   d7
    beq.s   .vlp
    btst    #0, d6                          ; dashed: only even rows
    bne.s   .vls
.vlp:
    move.w  d4, d5
    bsr     env_setpix
.vls:
    addq.w  #1, d6
    cmp.w   d3, d6
    ble.s   .vll
    rts

; env_decor: bounding box (solid) + dashed timing/amplitude guides for env_slot.
; env_pts must hold the breakpoints; clobbers d0-d7,a1,a2.
env_decor:
    moveq   #0, d0                          ; box left = slot*64 + 1
    move.b  env_slot, d0
    lsl.w   #6, d0
    addq.w  #1, d0
    move.w  d0, d2                          ; box left
    move.w  d0, d3
    addi.w  #ENV_SUBW-3, d3                 ; box right (base+62)
    moveq   #ENV_BOXT, d4                   ; top edge
    moveq   #0, d7
    bsr     env_hl
    moveq   #ENV_BOXB, d4                   ; bottom edge
    moveq   #0, d7
    bsr     env_hl
    move.w  d2, d4                          ; left edge
    moveq   #ENV_BOXT, d2
    moveq   #ENV_BOXB, d3
    moveq   #0, d7
    bsr     env_vl
    moveq   #0, d0                          ; right edge
    move.b  env_slot, d0
    lsl.w   #6, d0
    addi.w  #ENV_SUBW-2, d0
    move.w  d0, d4
    moveq   #ENV_BOXT, d2
    moveq   #ENV_BOXB, d3
    moveq   #0, d7
    bsr     env_vl
    lea     env_pts, a2                    ; dashed vertical guides (1px inside the box)
    move.w  4(a2), d4                       ; P1.x (attack end)
    bsr     .vdash
    move.w  8(a2), d4                       ; P2.x (decay end)
    bsr     .vdash
    move.w  12(a2), d4                      ; P3.x (sustain end)
    bsr     .vdash
    moveq   #0, d0                          ; dashed horizontal guides: peak + sustain levels
    move.b  env_slot, d0
    lsl.w   #6, d0
    move.w  d0, d2
    addq.w  #2, d2                          ; curve left = base+2
    move.w  d0, d3
    addi.w  #ENV_SUBW-3, d3                 ; curve right = base+61
    lea     env_pts, a2
    move.w  #ENV_BOT, d4                     ; peak level y = ENV_BOT - aPeak
    sub.w   6(a2), d4
    moveq   #1, d7
    bsr     env_hl
    move.w  #ENV_BOT, d4                     ; sustain level y = ENV_BOT - aSus
    sub.w   10(a2), d4
    moveq   #1, d7
    bsr     env_hl
    rts
.vdash:
    moveq   #ENV_TOP, d2
    moveq   #ENV_BOT, d3
    moveq   #1, d7
    bra     env_vl

draw_hex1:                                ; d3 = value (low nibble), d4 = cursor offset
    move.b  d3, d0
    andi.w  #$000F, d0
    lea     hexd, a1
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_hex2:
    move.b  d3, d0
    lsr.b   #4, d0
    bsr.s   .n
    move.b  d3, d0
.n:
    andi.w  #$000F, d0
    lea     hexd, a1
    move.b  (a1,d0.w), d0
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_cmd:
    move.b  d3, d0
    bne.s   .v
    moveq   #'-', d0                       ; 0 = no command
    bra.s   .draw
.v:
    addi.b  #$40, d0                       ; 1-26 -> 'A'-'Z' (H = HOP)
.draw:
    andi.w  #$00FF, d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_note:
    cmpi.b  #$FF, d3
    bne.s   .real
    move.w  #'-', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    move.w  d0, VDP_DATA
    rts
.real:
    moveq   #0, d0
    move.b  d3, d0
    divu.w  #12, d0
    move.l  d0, d1
    swap    d1
    andi.w  #$000F, d1
    add.w   d1, d1
    lea     note_names, a1
    move.b  (a1,d1.w), d2
    andi.w  #$00FF, d2
    add.w   d4, d2
    move.w  d2, VDP_DATA
    move.b  (1,a1,d1.w), d2
    andi.w  #$00FF, d2
    add.w   d4, d2
    move.w  d2, VDP_DATA
    andi.w  #$00FF, d0
    addi.w  #'0', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

; d3 = note (0-95) -> "<letter>[#]<octave>" padded to 3 cols at the VDP write pos.
; like draw_note but with no '-' separator for naturals (so "C4" / "C#4").
draw_note_compact:
    moveq   #0, d0
    move.b  d3, d0
    divu.w  #12, d0
    move.l  d0, d1
    swap    d1
    andi.w  #$000F, d1
    add.w   d1, d1
    lea     note_names, a1
    move.b  (a1,d1.w), d2                   ; pitch letter
    andi.w  #$00FF, d2
    move.w  d2, VDP_DATA
    move.b  (1,a1,d1.w), d2                 ; accidental ('-' natural / '#' sharp)
    cmpi.b  #'#', d2
    bne.s   .dncn
    andi.w  #$00FF, d2                      ; sharp -> emit '#', then octave (3 chars)
    move.w  d2, VDP_DATA
    andi.w  #$00FF, d0
    addi.w  #'0', d0
    move.w  d0, VDP_DATA
    rts
.dncn:
    andi.w  #$00FF, d0                      ; natural -> octave then a pad space (3 chars)
    addi.w  #'0', d0
    move.w  d0, VDP_DATA
    move.w  #' ', d0
    move.w  d0, VDP_DATA
    rts

; ============================================================
; multi-voice engine
; ============================================================
; set up all 10 channels from ch_config (4 bytes each: type, p1, p2, p3)
engine_init:
    lea     ch_state, a6
    lea     ch_config, a1
    moveq   #0, d2                        ; channel index = song track
.ci:
    move.b  (a1)+, d0                     ; type
    move.b  d0, c_type(a6)
    move.b  (a1)+, d1                     ; p1
    move.b  (a1)+, d3                     ; p2
    move.b  (a1)+, d4                     ; p3
    cmpi.b  #1, d0
    bne.s   .ci_psg
    move.b  d1, c_ympart(a6)              ; FM: part / chreg / key
    move.b  d3, c_ymchreg(a6)
    move.b  d4, c_ymkey(a6)
    bra.s   .ci_go
.ci_psg:
    move.b  d1, c_psgt(a6)                ; PSG square/noise: tone / vol base
    move.b  d3, c_psgv(a6)
.ci_go:
    move.b  d2, c_track(a6)
    bsr     init_ch
    lea     CHSIZE(a6), a6
    addq.b  #1, d2
    cmpi.b  #NCH, d2
    bne.s   .ci
    move.b  #GROOVE, g_gctr
    move.b  #0, g_seq
    rts

init_ch:                                  ; a6 = channel (c_type/config already set)
    move.b  #$FF, c_note(a6)
    move.w  #0, c_period(a6)
    move.b  #0, c_vol(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #15, c_row(a6)
    move.b  #$FF, c_cstep(a6)            ; pre-start: first advance loads chain step 0
    move.b  #0, c_transp(a6)
    move.b  #0, c_trig(a6)
    move.b  #0, c_keyon(a6)
    move.b  #0, c_kshadow(a6)
    move.b  #$FF, c_hold(a6)             ; gate inactive (no auto key-off until a note sets it)
    move.b  #0, c_instr(a6)
    move.b  #0, c_modph(a6)
    move.b  #0, c_modph2(a6)
    move.b  #$FF, c_tbl(a6)
    move.b  #$FF, c_trow(a6)             ; so the first per-note table step lands on row 0
    move.l  #phrases, c_phrase(a6)
    move.b  #0, c_songpos(a6)            ; song row 0; chain = song[0][track]
    lea     song, a2
    moveq   #0, d0
    move.b  c_track(a6), d0
    move.b  (a2,d0.w), c_chain(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, c_shadowa(a6)
    rts

; drop any A/V transient overrides and revert F1's patch to the stored instrument
clear_live_patch:
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #1, repatch
    rts

toggle_play:
    move.b  playing, d0
    eori.b  #1, d0
    move.b  d0, playing
    bsr     clear_live_patch              ; play/stop = clean slate for A/V overrides
    move.b  playing, d0                   ; (ym_setup clobbered d0)
    tst.b   d0
    beq.s   .tp
    move.b  #0, play_mode                 ; Start = full song from the top
    move.b  #0, play_from
    bsr     engine_play_reset
.tp:
    rts

play_context:                             ; C+B: toggle audition of the current context
    tst.b   playing                        ; already playing -> stop
    beq.s   .pc_start
    move.b  #0, playing
    bra     clear_live_patch              ; drop A/V overrides on stop
.pc_start:
    move.b  cur_screen, d0
    cmpi.b  #SCR_SONG, d0
    bne.s   .pc_ch
    move.b  #0, play_mode                 ; SONG: full song from the cursor row
    move.b  cur_row, play_from
    bra.s   .pc_go
.pc_ch:
    cmpi.b  #SCR_CHAIN, d0
    bne.s   .pc_ph
    move.b  #1, play_mode                 ; CHAIN: solo this track's chain
    move.b  cur_row, play_from            ; ...starting at the step under the cursor
    bra.s   .pc_go
.pc_ph:
    cmpi.b  #SCR_PHRASE, d0
    bne.s   .pc_done                      ; INSTRUMENT: nothing to audition
    move.b  #2, play_mode                 ; PHRASE: solo this track's phrase
.pc_go:
    move.b  #1, playing
    bsr     clear_live_patch              ; fresh A/V override state each audition
    bsr     engine_play_reset
.pc_done:
    rts

; reset every channel for playback per play_mode (kshadow=$FF forces a key-off,
; silencing any hanging FM note when switching context mid-play)
engine_play_reset:
    move.b  #GROOVE, g_gctr
    lea     phrase_plays, a0               ; reset I-command counts + AMP shadow at play-start
    moveq   #NPHRASES+NLFO-1, d0           ; phrase_plays (16) + lfo_amp (16) are contiguous
.rpc:
    clr.b   (a0)+
    dbra    d0, .rpc
    lea     pshadow, a0                   ; FM patch shadows -> "none": each channel repatches on its
    moveq   #NCH-1, d0                    ; first note (loads the instrument before key-on, then deltas)
.rps:
    move.b  #$FF, (a0)+
    dbra    d0, .rps
    move.b  #0, g_wait                     ; W row-override off
    lea     lq_b0, a0                     ; clear all per-channel command slots (Q/X/O/U/F/C)
    move.w  #(c_cphase+NCH)-lq_b0-1, d0
.rlq:
    move.b  #0, (a0)+
    dbra    d0, .rlq
    lea     c_bend, a0                    ; clear P bend rates + R retrig slots
    move.w  #(c_rtctr+NCH)-c_bend-1, d0
.rlb:
    move.b  #0, (a0)+
    dbra    d0, .rlb
    moveq   #NCH-1, d7
    lea     ch_state, a6
.r:
    move.b  #$FF, c_note(a6)
    move.b  #15, c_row(a6)
    move.b  #$FF, c_cstep(a6)
    move.b  #0, c_transp(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_vol(a6)
    move.b  #0, c_trig(a6)
    move.b  #0, c_keyon(a6)
    move.b  #$FF, c_kshadow(a6)
    move.w  #$FFFF, c_shadowp(a6)
    move.b  #$FF, c_shadowa(a6)
    move.b  #$FF, c_tbl(a6)              ; no table until the first note
    move.b  #$FF, c_trow(a6)             ; per-note table starts at row 0
    move.l  #phrases, c_phrase(a6)
    tst.b   play_mode
    bne.s   .solo
    move.b  play_from, c_songpos(a6)      ; full song: chain = song[play_from][track]
    lea     song, a2
    moveq   #0, d0
    move.b  play_from, d0
    mulu.w  #NCH, d0
    moveq   #0, d1
    move.b  c_track(a6), d1
    add.w   d1, d0
    move.b  (a2,d0.w), c_chain(a6)
    bra.s   .next
.solo:
    move.b  c_track(a6), d0               ; solo: only cur_chan is active
    cmp.b   cur_chan, d0
    bne.s   .mute
    cmpi.b  #1, play_mode
    bne.s   .phsolo
    move.b  cur_chain, c_chain(a6)         ; chain-solo
    move.b  play_from, d0                  ; ...from the cursor's chain step
    subq.b  #1, d0                         ; engine advances to play_from on tick 1
    move.b  d0, c_cstep(a6)
    bra.s   .next
.phsolo:                                  ; phrase-solo: load cur_phrase
    move.b  #0, c_chain(a6)               ; placeholder (non-$FF = active)
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    lea     phrases, a2
    adda.w  d0, a2
    move.l  a2, c_phrase(a6)
    bra.s   .next
.mute:
    move.b  #$FF, c_chain(a6)              ; inactive (silenced)
.next:
    lea     CHSIZE(a6), a6
    dbra    d7, .r
    rts

; ---- per tick: fold the 6 FM LFOs into the SCB's YM write list. a5 = YM ptr, d5 = count
; (both in/out). Each on-LFO modulates its target channel's FM param additively around the
; channel's patch value and appends one YM write; the diff isn't needed because we only emit
; when the LFO is on. Resync resets the phase on note-on / phrase-start per the c_lfosync flag.
fmlfo_tick:
    movem.l d0-d4/d6-d7/a1-a4, -(sp)
    lea     lfo_cfg, a2
    moveq   #0, d6                          ; LFO index = phase index 0..NLFO-1
.flt:
    move.b  (LF_FLAGS,a2), d0
    btst    #0, d0                          ; LFO enabled?
    beq     .fltn
    moveq   #0, d1                          ; a3 = target channel
    move.b  (LF_CHAN,a2), d1
    cmpi.b  #NCH, d1
    bhs     .fltn
    mulu.w  #CHSIZE, d1
    lea     ch_state, a3
    adda.w  d1, a3
    cmpi.b  #1, c_type(a3)                  ; only FM channels carry these registers
    bne     .fltn
    move.b  (LF_FLAGS,a2), d0               ; resync mode (bits 1-2): 0 note / 1 phrase / 2 free
    lsr.b   #1, d0
    andi.w  #3, d0
    cmpi.b  #LFRS_FREE, d0
    beq.s   .flnors
    move.b  c_lfosync(a3), d1               ; mode 0 -> bit0 (note), 1 -> bit1 (phrase)
    btst    d0, d1
    beq.s   .flnors
    lea     lfo_phase, a4                    ; resync: restart 16-bit phase at offset*16 (hi byte)
    moveq   #0, d1
    move.b  (LF_POFF,a2), d1
    lsl.w   #4, d1
    lsl.w   #8, d1
    move.w  d6, d3
    add.w   d3, d3
    move.w  d1, (a4,d3.w)
.flnors:
    moveq   #0, d1                           ; advance 16-bit phase by the rate curve (full byte):
    move.b  (LF_RATE,a2), d1                 ; inc = (rate^2 >> 4) + rate -> fine at the slow end,
    move.w  d1, d3                            ; ~0 (frozen) at 0, ~3.9 Hz at FF
    mulu.w  d3, d3
    lsr.w   #4, d3
    add.w   d3, d1
    move.w  d6, d3
    add.w   d3, d3
    lea     lfo_phase, a4
    move.w  (a4,d3.w), d2
    add.w   d1, d2
    move.w  d2, (a4,d3.w)
    lsr.w   #8, d2                            ; integer part 0-255 -> shape per DIR
    move.b  (LF_FLAGS,a2), d3                 ; DIR (flags bits 3-4): 0 BOTH, 1 UP, 2 DOWN
    lsr.b   #3, d3
    andi.w  #3, d3
    beq.s   .dboth
    andi.w  #$7F, d2                          ; UP/DOWN: half phase = sawtooth at 2x rate
    cmpi.b  #2, d3
    bne.s   .flt1                             ; UP = rising ramp
    move.w  #127, d3                          ; DOWN = falling ramp
    sub.w   d2, d3
    move.w  d3, d2
    bra.s   .flt1
.dboth:
    cmpi.w  #128, d2                          ; full triangle fold -> -64..63
    blo.s   .flt1
    move.w  #255, d3
    sub.w   d2, d3
    move.w  d3, d2
.flt1:
    subi.w  #64, d2
    moveq   #0, d1
    move.b  (LF_DEPTH,a2), d1
    muls.w  d2, d1                           ; depth * tri
    asr.w   #5, d1                           ; >> 5 -> swing ~ +/- 2*depth
    move.w  d1, d0                           ; AMP bar: stash |delta|>>2 (cap 7) for this LFO
    bpl.s   .fmapos
    neg.w   d0
.fmapos:
    lsr.w   #2, d0
    cmpi.w  #7, d0
    bls.s   .fmacap
    moveq   #7, d0
.fmacap:
    lea     lfo_amp, a4
    move.b  d0, (a4,d6.w)
    moveq   #0, d0                           ; param table entry -> a4 = {patch_off, reg, max}
    move.b  (LF_PARM,a2), d0
    cmpi.w  #FMLFO_NPARM, d0
    bhs     .fltn
    mulu.w  #6, d0
    lea     fmlfo_ptab, a4
    adda.w  d0, a4
    lea     instrum, a1                      ; the target channel's instrument
    moveq   #0, d2
    move.b  c_instr(a3), d2
    mulu.w  #INSTR_SIZE, d2
    adda.w  d2, a1
    moveq   #0, d3                           ; base = patch param value
    move.b  (a4), d3
    moveq   #0, d2
    move.b  (a1,d3.w), d2
    add.w   d1, d2                           ; + LFO delta
    bpl.s   .flc0
    moveq   #0, d2
.flc0:
    moveq   #0, d3
    move.b  (2,a4), d3                       ; clamp to the param's max
    cmp.w   d3, d2
    bls.s   .flc1
    move.w  d3, d2
.flc1:
    moveq   #0, d3                           ; compose register byte: (value<<shift)|(co<<coshift)
    move.b  (3,a4), d3                       ; shift
    lsl.b   d3, d2
    move.b  (4,a4), d3                       ; co-param patch off ($FF = register holds only this)
    cmpi.b  #$FF, d3
    beq.s   .flnoco
    moveq   #0, d0
    move.b  (a1,d3.w), d0                    ; co-param value from the patch
    move.b  (5,a4), d3                       ; co shift
    lsl.b   d3, d0
    or.b    d0, d2
.flnoco:
    move.b  c_ympart(a3), (a5)+             ; append YM write: part, reg+chreg, value
    move.b  (1,a4), d3
    add.b   c_ymchreg(a3), d3
    move.b  d3, (a5)+
    move.b  d2, (a5)+
    addq.w  #1, d5
.fltn:
    lea     LF_SIZE(a2), a2
    addq.w  #1, d6
    cmpi.w  #NLFO, d6
    bne     .flt
    lea     ch_state+c_lfosync, a3          ; consume the resync flags for next tick
    moveq   #NCH-1, d7
.flclr:
    clr.b   (a3)
    lea     CHSIZE(a3), a3
    dbra    d7, .flclr
    movem.l (sp)+, d0-d4/d6-d7/a1-a4
    rts

; FM LFO param table: {patch off, YM reg, max, shift, co-param patch off ($FF=none), co shift}.
; Packed registers (DT+MUL in $30, FB+ALGO in $B0) recompose the co-param from the patch.
fmlfo_ptab:
    dc.b i_op+0*10+2, $40, 127, 0, $FF, 0           ; 0  TL S1
    dc.b i_op+1*10+2, $44, 127, 0, $FF, 0           ; 1  TL S3
    dc.b i_op+2*10+2, $48, 127, 0, $FF, 0           ; 2  TL S2
    dc.b i_op+3*10+2, $4C, 127, 0, $FF, 0           ; 3  TL S4
    dc.b i_op+0*10+1, $30, 7, 4, i_op+0*10+0, 0     ; 4  DT S1 (packed w/ MUL)
    dc.b i_op+1*10+1, $34, 7, 4, i_op+1*10+0, 0     ; 5  DT S3
    dc.b i_op+2*10+1, $38, 7, 4, i_op+2*10+0, 0     ; 6  DT S2
    dc.b i_op+3*10+1, $3C, 7, 4, i_op+3*10+0, 0     ; 7  DT S4
    dc.b i_op+0*10+0, $30, 15, 0, i_op+0*10+1, 4    ; 8  MUL S1 (packed w/ DT)
    dc.b i_op+1*10+0, $34, 15, 0, i_op+1*10+1, 4    ; 9  MUL S3
    dc.b i_op+2*10+0, $38, 15, 0, i_op+2*10+1, 4    ; A  MUL S2
    dc.b i_op+3*10+0, $3C, 15, 0, i_op+3*10+1, 4    ; B  MUL S4
    dc.b i_fb,   $B0, 7, 3, i_algo, 0               ; C  FB (packed w/ ALGO)
    dc.b i_algo, $B0, 7, 0, i_fb, 3                 ; D  ALGO (packed w/ FB)
    dc.b i_op+0*10+4, $50, 31, 0, i_op+0*10+3, 6    ; AR1 attack  (packed w/ RS)
    dc.b i_op+1*10+4, $54, 31, 0, i_op+1*10+3, 6    ; AR3
    dc.b i_op+2*10+4, $58, 31, 0, i_op+2*10+3, 6    ; AR2
    dc.b i_op+3*10+4, $5C, 31, 0, i_op+3*10+3, 6    ; AR4
    dc.b i_op+0*10+6, $60, 31, 0, i_op+0*10+5, 7    ; D1R1 decay1 (packed w/ AM)
    dc.b i_op+1*10+6, $64, 31, 0, i_op+1*10+5, 7    ; D1R3
    dc.b i_op+2*10+6, $68, 31, 0, i_op+2*10+5, 7    ; D1R2
    dc.b i_op+3*10+6, $6C, 31, 0, i_op+3*10+5, 7    ; D1R4
    dc.b i_op+0*10+7, $70, 31, 0, $FF, 0            ; D2R1 decay2 (alone)
    dc.b i_op+1*10+7, $74, 31, 0, $FF, 0            ; D2R3
    dc.b i_op+2*10+7, $78, 31, 0, $FF, 0            ; D2R2
    dc.b i_op+3*10+7, $7C, 31, 0, $FF, 0            ; D2R4
    dc.b i_op+0*10+8, $80, 15, 0, i_op+0*10+9, 4    ; RR1 release (packed w/ SL)
    dc.b i_op+1*10+8, $84, 15, 0, i_op+1*10+9, 4    ; RR3
    dc.b i_op+2*10+8, $88, 15, 0, i_op+2*10+9, 4    ; RR2
    dc.b i_op+3*10+8, $8C, 15, 0, i_op+3*10+9, 4    ; RR4
    dc.b i_op+0*10+9, $80, 15, 4, i_op+0*10+8, 0    ; SL1 sustain (packed w/ RR)
    dc.b i_op+1*10+9, $84, 15, 4, i_op+1*10+8, 0    ; SL3
    dc.b i_op+2*10+9, $88, 15, 4, i_op+2*10+8, 0    ; SL2
    dc.b i_op+3*10+9, $8C, 15, 4, i_op+3*10+8, 0    ; SL4
FMLFO_NPARM equ 34
    even
engine_tick:
    move.b  #0, patch_done                ; FM operator-patch budget: one per tick
    tst.b   playing
    bne.s   .play
    ; stopped: silence all channels (compose emits the change once)
    lea     scb_data, a3
    moveq   #0, d6
    lea     ym_data, a5
    moveq   #0, d5
    moveq   #NCH-1, d7
    lea     ch_state, a6
.sil:
    move.b  #0, c_vol(a6)
    move.b  #0, c_estate(a6)
    move.b  #0, c_keyon(a6)              ; FM: request key-off
    bsr     compose_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .sil
    move.b  d6, scb_count
    move.b  d5, ym_count
    move.b  d6, d0
    or.b    d5, d0
    or.b    repatch, d0                   ; a pending patch re-push also needs a push
    or.b    g_lfo_dirty, d0               ; ...as does a global-LFO ($22) change
    beq.s   .sret
    bsr     push_scb
.sret:
    bsr     wave_silence                  ; stopped -> park any sounding wave
    rts
.play:
    ; row advance gated by tempo: frames/row = 1250 / proj_tmpo (125 BPM -> 10 = old GROOVE)
    addq.b  #1, g_gctr
    move.l  #1250, d0
    moveq   #0, d1
    move.b  proj_tmpo, d1
    bne.s   .tdiv
    moveq   #1, d1                         ; guard (proj_tmpo is clamped >=32 anyway)
.tdiv:
    divu.w  d1, d0                         ; d0 low word = frames per row
    tst.b   g_wait                          ; W command: this-row frame-count override?
    beq.s   .nowait
    moveq   #0, d0
    move.b  g_wait, d0
.nowait:
    cmp.b   g_gctr, d0
    bhi.s   .noadv                         ; not enough frames elapsed yet
    move.b  #0, g_gctr
    move.b  #0, g_wait                      ; W is one row only
    move.b  #1, eng_adv                   ; playheads moved -> redraw the grid
    moveq   #NCH-1, d7
    lea     ch_state, a6
.adv:
    bsr     advance_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .adv
.noadv:
    ; per-channel envelope + compose (PSG -> a3/d6, FM -> a5/d5)
    lea     scb_data, a3
    moveq   #0, d6
    lea     ym_data, a5
    moveq   #0, d5
    moveq   #NCH-1, d7
    lea     ch_state, a6
.ch:
    bsr     env_ch
    bsr     table_cmd                     ; run the active table row's CMD column once per row entry
    bsr     hold_tick
    bsr     compose_ch
    lea     CHSIZE(a6), a6
    dbra    d7, .ch
    bsr     fmlfo_tick                    ; fold the 6 FM LFOs into the YM write list (a5/d5)
    move.b  d6, scb_count
    move.b  d5, ym_count
    move.b  d6, d0
    or.b    d5, d0
    or.b    repatch, d0                   ; a pending patch re-push also needs a push
    or.b    g_lfo_dirty, d0               ; ...as does a global-LFO ($22) change
    beq.s   .nopush
    bsr     push_scb
.nopush:
    bsr     wave_rebake                   ; re-arm the sounding wave each frame (sustain + live edits)
    rts

; ---- per-frame wave re-bake: re-push the sounding wave + re-arm (no phase reset on the
;      Z80 side, so it's seamless). a6/a1 set from wave_ch + its instrument. ----
wave_rebake:
    tst.b   wave_on
    beq.s   .wrx
    movea.l wave_ch, a6
    lea     instrum, a1
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a1
    movea.l a1, a4                        ; a4 = instrument for wave_env
    bsr     wave_env                      ; advance the AHD envelope one frame
    tst.b   c_estate(a6)                  ; envelope decayed to off?
    beq.s   .wr_off
    bsr     wave_lfo                      ; advance the 5 LFOs -> wbake_in (vol/warp/fold/drv/crush)
    bsr     wave_play                     ; bake (reads wbake_in) + push + re-arm
    rts
.wr_off:
    bsr     wave_silence                  ; env finished -> stop + park the DAC
.wrx:
    rts

; ---- stop a sounding wave (on STOP): clear the flag + tell the Z80 to park the DAC ----
wave_silence:
    tst.b   wave_on
    beq.s   .wsx
    move.b  #0, wave_on
    move.w  #$0100, Z80_BUSREQ
.wsw:
    btst    #0, Z80_BUSREQ
    bne.s   .wsw
    addq.b  #1, Z80_RAM+$1FF4             ; bump WV_OFF -> Z80 parks the DAC, leaves wave mode
    move.w  #$0000, Z80_BUSREQ
.wsx:
    rts

; gate countdown: $FF = held; else decrement, and request key-off when it hits 0
hold_tick:                                ; a6 = channel
    moveq   #0, d0                          ; C command: advance the chord arp phase (0->1->2->0)
    move.b  c_track(a6), d0
    lea     c_chord, a1
    tst.b   (a1,d0.w)
    beq.s   .hnochord
    lea     c_cphase, a1
    move.b  (a1,d0.w), d1
    addq.b  #1, d1
    cmpi.b  #3, d1
    blo.s   .hcph
    moveq   #0, d1
.hcph:
    move.b  d1, (a1,d0.w)
.hnochord:
    moveq   #0, d0                          ; P command: accumulate bend rate into c_pfine (clamp +-127)
    move.b  c_track(a6), d0
    lea     c_bend, a1
    move.b  (a1,d0.w), d1
    beq.s   .hnobend
    ext.w   d1
    lea     c_pfine, a1
    move.b  (a1,d0.w), d2
    ext.w   d2
    add.w   d1, d2
    cmpi.w  #127, d2
    ble.s   .hbc1
    moveq   #127, d2
.hbc1:
    cmpi.w  #-127, d2
    bge.s   .hbc2
    move.w  #-127, d2
.hbc2:
    move.b  d2, (a1,d0.w)
.hnobend:
    moveq   #0, d0                          ; R command: retrigger countdown
    move.b  c_track(a6), d0
    lea     c_rtper, a1
    move.b  (a1,d0.w), d1
    beq.s   .hnort
    lea     c_rtctr, a1
    move.b  (a1,d0.w), d2
    subq.b  #1, d2
    bne.s   .hrtset
    move.b  d1, d2                          ; reached 0 -> reload period + re-trigger
    move.b  #1, c_trig(a6)                  ; FM: re-key
    move.b  #1, c_estate(a6)               ; PSG: restart the envelope attack
    move.b  #0, c_ectr(a6)
.hrtset:
    move.b  d2, (a1,d0.w)
.hnort:
    move.b  c_hold(a6), d0
    cmpi.b  #$FF, d0
    beq.s   .hret
    subq.b  #1, d0
    move.b  d0, c_hold(a6)
    bne.s   .hret
    move.b  #0, c_keyon(a6)               ; gate expired -> FM key-off
    move.b  #3, c_estate(a6)               ; ...and PSG -> decay/release (env state 3); harmless on FM
    move.b  #0, c_ectr(a6)
    move.b  #$FF, c_hold(a6)
    bsr     cut_dac_if_sample              ; ...and a KIT/WAVE instrument -> stop the DAC playback
.hret:
    rts

cut_dac_if_sample:                         ; a6=ch: if c_instr is KIT/WAVE, tell the Z80 to stop the DAC
    movem.l d0/a0, -(sp)
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    lea     instrum, a0
    move.b  (i_type,a0,d0.w), d0
    subq.b  #1, d0                          ; KIT(1)/WAVE(2) -> 0/1; FM/TONE/NOISE out of range
    cmpi.b  #1, d0
    bhi.s   .cds_no
    move.w  #$0100, Z80_BUSREQ
.cds_w:
    btst    #0, Z80_BUSREQ
    bne.s   .cds_w
    addq.b  #1, Z80_RAM+$1FF4              ; bump WV_OFF -> Z80 stops the DAC sample/wave
    move.w  #$0000, Z80_BUSREQ
.cds_no:
    movem.l (sp)+, d0/a0
    rts

advance_ch:                               ; a6 = channel
    move.b  #0, hop_ctr                    ; H command: reset the per-advance hop guard
    cmpi.b  #$FF, c_chain(a6)             ; inactive (muted/empty) -> stay silent
    beq     .ret
    move.b  c_row(a6), d0
    addq.b  #1, d0
    cmpi.b  #16, d0
    blo.s   .gotrow
    cmpi.b  #2, play_mode                 ; phrase-solo: loop the phrase
    bne.s   .nextchain
    moveq   #0, d0
    move.b  cur_phrase, d0
    lsl.w   #6, d0
    lea     phrases, a1
    adda.w  d0, a1
    move.l  a1, c_phrase(a6)
    moveq   #0, d0
    bra.s   .gotrow
.nextchain:
    bsr     advance_chain                 ; phrase ended -> next chain step
    cmpi.b  #$FF, c_chain(a6)             ; became inactive?
    beq     .ret
    moveq   #0, d0
.gotrow:
    move.b  d0, c_row(a6)
    tst.b   d0                              ; row 0 = a new phrase began on this track
    bne.s   .nophs
    bset    #1, c_lfosync(a6)              ; -> FM LFO phrase-resync flag
    movea.l c_phrase(a6), a1               ; bump this phrase's play count (for the I command)
    move.l  a1, d1
    sub.l   #phrases, d1
    lsr.l   #6, d1                          ; phrase number = offset / PHRASE_SIZE
    lea     phrase_plays, a1
    addq.b  #1, (a1,d1.w)
.nophs:
    movea.l c_phrase(a6), a1
    move.w  d0, d1                         ; d1 = row*4 (command/param offset)
    lsl.w   #2, d1
    cmpi.b  #1, c_type(a6)                 ; per-note FM reset: a note-on this row reverts the
    bne.s   .noreset                       ;   Q/X overrides to the instrument's stored patch
    cmpi.b  #$FF, (a1,d1.w)               ;   (note byte at row offset 0; $FF = rest = no reset)
    beq.s   .noreset                       ; the Q/X dispatch just below re-applies for this row
    move.b  live_algo, d2                  ; ...but only when an override is actually live:
    and.b   live_vol, d2                   ;   all three $FF = nothing changed = no patch re-push
    and.b   live_fb, d2
    cmpi.b  #$FF, d2
    beq.s   .noreset
    move.b  #$FF, live_algo
    move.b  #$FF, live_vol
    move.b  #$FF, live_fb
    move.b  #1, repatch
.noreset:
    move.b  #0, cmd_tsp                    ; J command: clear this row's repeat-gated transpose
    move.b  #0, k_set                      ; K command: clear this row's gate-override flag
    move.b  #0, c_set                      ; C command: clear this row's chord-set flag
    move.b  #0, f_set                      ; F command: clear this row's finetune-set flag
    move.b  #0, p_set                      ; P command: clear this row's bend-set flag
    move.b  (2,a1,d1.w), d2               ; phrase command (letter A-Z = 1..26)
    cmpi.b  #8, d2                         ; H = HOP -> jump to PR row (phrase-structural, stays here)
    beq     .cmd_hop
    cmpi.b  #9, d2                         ; I xx = iteration: gate the note by a repeat mask
    beq     .cmd_i
    cmpi.b  #10, d2                        ; J xy = repeat-gated transpose (sibling of I)
    beq     .cmd_j
    cmpi.b  #20, d2                        ; T xx = tempo (BPM, global)
    beq     .cmd_t
    cmpi.b  #23, d2                        ; W xx = this row lasts xx frames (global)
    beq     .cmd_w
    bsr     exec_cmd                       ; Q/X/O/U/F/C/P/R/Y/K voice commands (or none) -- shared
    bra     .cmddone                       ; then resolve this row's note
.cmd_i:
    moveq   #0, d2
    move.b  (3,a1,d1.w), d2              ; mask byte (one bit per repeat, mod 8)
    move.l  a1, d3                         ; phrase number from c_phrase
    sub.l   #phrases, d3
    lsr.l   #6, d3
    lea     phrase_plays, a4
    moveq   #0, d1
    move.b  (a4,d3.w), d1                 ; play count (bumped at row 0 this pass)
    subq.b  #1, d1                         ; -> 0-based repeat index
    andi.w  #7, d1                         ; mod 8 -> bit
    btst    d1, d2
    bne     .cmddone                       ; bit set -> play the note this repeat
    bra     .ret                           ; bit clear -> suppress (rest)
.cmd_hop:
    addq.b  #1, hop_ctr                    ; runaway guard: H->H->... can't hang the tick
    cmpi.b  #32, hop_ctr
    bhs     .cmddone                       ; too many hops this advance -> bail, play the row
    moveq   #0, d0
    move.b  (3,a1,d1.w), d0               ; param = destination row (low nibble)
    andi.b  #$0F, d0
    bra     .gotrow                        ; jump there NOW -- the H row plays no sixteenth
.cmd_t:
    move.b  (3,a1,d1.w), d2               ; T xx = tempo (BPM); the row-advance uses 1250/proj_tmpo
    move.b  d2, proj_tmpo
    bra     .cmddone
.cmd_w:
    move.b  (3,a1,d1.w), g_wait           ; W xx = this row lasts xx frames (global, one row)
    bra     .cmddone
.cmd_j:                                    ; J xy: x = repeat mask (mod 4), y = signed transpose
    moveq   #0, d2
    move.b  (3,a1,d1.w), d2               ; param: x = mask (hi nibble), y = transpose (lo nibble)
    move.l  a1, d3                         ; phrase # = (c_phrase - phrases) / PHRASE_SIZE
    sub.l   #phrases, d3
    lsr.l   #6, d3
    lea     phrase_plays, a4
    moveq   #0, d1
    move.b  (a4,d3.w), d1                 ; play count (bumped at row 0 this pass)
    subq.b  #1, d1                         ; 0-based repeat index
    andi.w  #3, d1                         ; mod 4 -> repeat bit (0-3)
    move.b  d2, d3
    lsr.b   #4, d3                         ; d3 = x mask (high nibble -> bits 0-3)
    btst    d1, d3                          ; transpose active on this repeat?
    beq     .cmddone                       ; no -> cmd_tsp stays 0
    andi.b  #$0F, d2                       ; y = transpose nibble
    cmpi.b  #8, d2                         ; sign-extend the 4-bit value
    blo.s   .cj_set
    subi.b  #16, d2                         ; 8..F -> -8..-1
.cj_set:
    move.b  d2, cmd_tsp                    ; applied in .cmddone alongside chain/instrument transpose
    bra     .cmddone
.cmddone:                                 ; phrase path only now (the table never reaches here)
    lsl.w   #2, d0
    moveq   #0, d2
    move.b  (a1,d0.w), d2                 ; note (0-95) or $FF
    cmpi.w  #$FF, d2
    beq     .ret
    move.b  c_transp(a6), d3              ; + chain transpose (signed)
    ext.w   d3
    add.w   d3, d2
    lea     instrum, a4                    ; + per-instrument TSP (TONE/NOISE only)
    moveq   #0, d3
    move.b  (1,a1,d0.w), d3               ; phrase IN column = instrument #
    mulu.w  #INSTR_SIZE, d3
    adda.w  d3, a4
    cmpi.b  #3, (a4)                       ; TONE/NOISE (>=3) transpose -> ip_tsp
    bhs.s   .psgtsp
    cmpi.b  #2, (a4)                        ; FM (0) + KIT (1) transpose -> i_tsp; WAVE (2): none
    beq.s   .notsp
    move.b  (i_tsp,a4), d3
    bra.s   .addtsp
.psgtsp:
    move.b  (ip_tsp,a4), d3
.addtsp:
    ext.w   d3
    add.w   d3, d2
.notsp:
    move.b  cmd_tsp, d3                    ; + J command repeat-gated transpose (signed; 0 if inactive)
    ext.w   d3
    add.w   d3, d2
    tst.w   d2                             ; test the NOTE (the gate above may have left
    bmi     .ret                           ; cmpi flags -> would wrongly drop FM/KIT/WAVE)
    cmpi.w  #96, d2
    bhs     .ret
    move.b  d2, c_note(a6)
    movem.l d0/a0, -(sp)                    ; per-note state resets (d2 still holds the note this path needs):
    move.b  c_track(a6), d0                 ;   a new note clears C/F/P state unless that command is on its row,
    andi.w  #$00FF, d0                       ;   so chord/finetune/bend don't latch onto following notes
    tst.b   c_set
    bne.s   .crc
    lea     c_chord, a0
    clr.b   (a0,d0.w)
.crc:
    tst.b   f_set
    bne.s   .crf
    lea     c_pfine, a0                     ; no F this row -> drop the finetune (start at pitch)
    clr.b   (a0,d0.w)
.crf:
    tst.b   p_set
    bne.s   .crp
    lea     c_bend, a0                      ; no P this row -> stop the bend (c_pfine cleared above unless F)
    clr.b   (a0,d0.w)
.crp:
    movem.l (sp)+, d0/a0
    bset    #0, c_lfosync(a6)              ; note-on -> FM LFO note-resync flag
    move.b  (1,a1,d0.w), c_instr(a6)      ; phrase IN column -> channel's instrument
    lea     instrum, a4                    ; (re)start the macro table -- FM/TONE/NOISE, not KIT/WAVE
    moveq   #0, d3
    move.b  c_instr(a6), d3
    mulu.w  #INSTR_SIZE, d3
    move.b  (i_type,a4,d3.w), d1          ; KIT (1) / WAVE (2) are DAC voices -> no macro table
    cmpi.b  #1, d1
    beq.s   .notabl
    cmpi.b  #2, d1
    beq.s   .notabl
    move.b  (i_tbl,a4,d3.w), c_tbl(a6)
    move.b  #$FF, c_tcrow(a6)             ; note-on: re-arm so the (re)started row's CMD column fires
    tst.b   (i_tbs,a4,d3.w)               ; TBS 0 = per-note: step the playhead (don't restart)
    bne.s   .tbreset
    move.b  c_trow(a6), d1
    addq.b  #1, d1
    andi.b  #$0F, d1                       ; wrap 16 -> 0
    move.b  d1, c_trow(a6)
    bra.s   .tbctr
.tbreset:
    move.b  #0, c_trow(a6)               ; TBS>0 = per-tick: restart at row 0
.tbctr:
    move.b  #0, c_tctr(a6)
    bra.s   .notbset
.notabl:
    move.b  #$FF, c_tbl(a6)              ; KIT/WAVE: no macro table
.notbset:
    move.b  c_type(a6), d3
    beq     .square
    cmpi.b  #2, d3
    beq     .noise
    lea     instrum, a4                  ; FM channel: a KIT instrument plays a DAC sample
    moveq   #0, d2
    move.b  c_instr(a6), d2
    mulu.w  #INSTR_SIZE, d2
    cmpi.b  #1, (i_type,a4,d2.w)         ; i_type 1 = KIT
    bne.s   .nwkit
    move.b  (i_kit,a4,d2.w), d0          ; kit index
    moveq   #0, d1
    move.b  c_note(a6), d1
    andi.w  #$0F, d1                     ; pad = note % 16 (wraps every octave-ish)
    lea     0(a4,d2.w), a1               ; a1 = the KIT instrument (for gain/rate)
    bsr     dac_play
    move.b  #0, wave_on                  ; a sample takes the DAC -> end any wave note
    move.b  #0, c_keyon(a6)              ; DAC owns ch6 -> keep the FM voice silent
    move.b  #0, c_trig(a6)
    rts
.nwkit:
    cmpi.b  #2, (i_type,a4,d2.w)         ; i_type 2 = WAVE -> wavetable on the DAC
    bne.s   .fmtrig
    lea     0(a4,d2.w), a1               ; a1 = the WAVE instrument
    move.b  #1, c_estate(a6)             ; start the AHD envelope at attack
    move.b  #0, c_vol(a6)
    move.b  #0, c_ectr(a6)
    clr.l   wlfo_phase                    ; reset the 6 LFO phases (vol/warp/fold/drive/crush/pitch)
    clr.w   wlfo_phase+4
    movea.l a1, a4                        ; a4 = instrument for wave_env / wave_lfo
    bsr     wave_env                      ; advance once (ATK 0 -> instant peak)
    bsr     wave_lfo                      ; fill wbake_in for the first bake
    bsr     wave_play                     ; bake (reads wbake_in) + push + arm
    move.b  #1, wave_on                  ; mark sounding -> engine re-bakes it every frame
    move.l  a6, wave_ch
    move.b  #0, c_keyon(a6)              ; DAC owns ch6 -> keep the FM voice silent
    move.b  #0, c_trig(a6)
    rts
.fmtrig:
    cmpi.b  #5, c_track(a6)              ; F6 hosts the DAC: an FM note here must drop ch6 out of
    bne.s   .fm_nodac                    ;   DAC mode ($2B off) or the FM voice stays muted
    move.w  #$0100, Z80_BUSREQ
.fm_dacw:
    btst    #0, Z80_BUSREQ
    bne.s   .fm_dacw
    addq.b  #1, Z80_RAM+$1FF4            ; bump WV_OFF -> Z80 wave_off disables ch6 DAC
    move.w  #$0000, Z80_BUSREQ
.fm_nodac:
    ; on an FM note-on, revert each live override (Q/X/O/U) to the instrument's value -- unless
    ; that command is on this very row (its dirty flag was just set by the dispatch). Else a stale
    ; override sticks forever (same-instrument retriggers skip the patch re-emit).
    moveq   #0, d2
    move.b  c_track(a6), d2
    moveq   #0, d1
    move.b  c_instr(a6), d1
    mulu.w  #INSTR_SIZE, d1
    lea     instrum, a3
    adda.w  d1, a3                          ; a3 = the channel's instrument
    lea     lq_dirty, a4                    ; Q -> $B0 = (FB<<3)|ALGO
    tst.b   (a4,d2.w)
    bne.s   .fm_rq
    move.b  (i_fb,a3), d1
    andi.b  #7, d1
    lsl.b   #3, d1
    move.b  (i_algo,a3), d0
    andi.b  #7, d0
    or.b    d0, d1
    lea     lq_b0, a4
    move.b  d1, (a4,d2.w)
    lea     lq_dirty, a4
    move.b  #1, (a4,d2.w)
.fm_rq:
    lea     lx_dirty, a4                    ; X -> carrier volume = instrument i_vol
    tst.b   (a4,d2.w)
    bne.s   .fm_rx
    move.b  (i_vol,a3), d1
    lea     lx_vol, a4
    move.b  d1, (a4,d2.w)
    lea     lx_dirty, a4
    move.b  #1, (a4,d2.w)
.fm_rx:
    lea     lo_dirty, a4                    ; O -> $B4 = (pan<<6)|(AMS<<4)|FMS
    tst.b   (a4,d2.w)
    bne.s   .fm_ro
    move.b  (i_pan,a3), d1
    andi.b  #3, d1
    lsl.b   #6, d1
    move.b  (i_ams,a3), d0
    andi.b  #3, d0
    lsl.b   #4, d0
    or.b    d0, d1
    move.b  (i_fms,a3), d0
    andi.b  #7, d0
    or.b    d0, d1
    lea     lo_b4, a4
    move.b  d1, (a4,d2.w)
    lea     lo_dirty, a4
    move.b  #1, (a4,d2.w)
.fm_ro:
    lea     lu_dirty, a4                    ; U -> modulator TL offset = 0 (instrument's stored TL)
    tst.b   (a4,d2.w)
    bne.s   .fm_qok
    lea     lu_off, a4
    clr.b   (a4,d2.w)
    lea     lu_dirty, a4
    move.b  #1, (a4,d2.w)
.fm_qok:
    move.b  #1, c_trig(a6)               ; FM: (re)trigger the note
    move.b  #1, c_keyon(a6)
    tst.b   k_set                         ; K on this row -> keep its gate, skip the instrument HLD
    bne.s   .fm_hdone
    lea     instrum, a4                  ; HLD: gate time from the channel's instrument
    moveq   #0, d2                       ; (c_instr -- NOT cur_instr: the editor's current
    move.b  c_instr(a6), d2             ;  instrument must not change a playing FM voice's gate)
    mulu.w  #INSTR_SIZE, d2
    move.b  (i_hld,a4,d2.w), d2
    cmpi.b  #15, d2                      ; $F = hold until the next note
    bne.s   .hldcnt
    move.b  #$FF, c_hold(a6)
.fm_hdone:
    rts
.hldcnt:
    add.b   d2, d2                       ; HLD*2 (+1 so HLD=0 still gates, and != $FF)
    addq.b  #1, d2
    move.b  d2, c_hold(a6)
    rts
.noise:                                   ; noise: MODE/RATE from the instrument, AHD vol
    lea     instrum, a4
    moveq   #0, d2
    move.b  c_instr(a6), d2
    mulu.w  #INSTR_SIZE, d2
    adda.w  d2, a4
    moveq   #0, d2
    move.b  (ip_rate,a4), d2              ; NF = rate (bits 0-1): 0/1/2 = clk/512/1024/2048, 3 = T3
    andi.b  #3, d2
    tst.b   (ip_mode,a4)                  ; mode 0 = RANDOM (white) -> FB feedback bit
    bne.s   .n_per
    ori.b   #4, d2
.n_per:
    move.w  d2, c_period(a6)              ; 3-bit SN76489 noise control
    move.b  #1, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #0, c_vol(a6)
    rts
.square:
    add.w   d2, d2
    lea     notetable, a2
    move.w  (a2,d2.w), c_period(a6)
    move.b  #1, c_estate(a6)
    move.b  #0, c_ectr(a6)
    move.b  #0, c_vol(a6)
.ret:
    rts

; next chain step; on chain end ($FF), advance the song row instead of looping
advance_chain:                            ; a6 = channel
    moveq   #0, d1
    move.b  c_cstep(a6), d1
    addq.b  #1, d1
    andi.b  #$0F, d1
    lea     chains, a2
    moveq   #0, d0
    move.b  c_chain(a6), d0
    lsl.w   #5, d0                        ; * CHAIN_SIZE
    adda.w  d0, a2
    moveq   #0, d0
    move.b  d1, d0
    add.w   d0, d0                        ; step * 2
    move.b  (a2,d0.w), d2                 ; phrase# at this step
    cmpi.b  #$FF, d2
    bne.s   .step
    cmpi.b  #1, play_mode                 ; chain-solo: loop chain (step 0)
    bne.s   advance_song                  ; else: chain done -> next song row
    moveq   #0, d1
.step:
    move.b  d1, c_cstep(a6)
    bra.s   load_step                     ; d1 = step

; advance the channel's song row; load its chain at step 0 (loop song on $FF)
advance_song:                             ; a6 = channel
    moveq   #0, d3
    move.b  c_songpos(a6), d3
    addq.b  #1, d3
    moveq   #0, d0
    move.b  c_track(a6), d0
    move.w  d3, d4                        ; song[d3][track] = d3*NCH + track
    mulu.w  #NCH, d4
    add.w   d0, d4
    lea     song, a2
    move.b  (a2,d4.w), d2                 ; chain# at new row
    cmpi.b  #$FF, d2
    bne.s   .ok
    moveq   #0, d3                        ; song end -> loop to row 0
    move.b  (a2,d0.w), d2                 ; song[0][track]
.ok:
    move.b  d3, c_songpos(a6)
    move.b  d2, c_chain(a6)
    move.b  #0, c_cstep(a6)
    moveq   #0, d1                        ; chain step 0
    ; fall into load_step

load_step:                                ; a6 = channel; d1 = chain step
    lea     chains, a2
    moveq   #0, d0
    move.b  c_chain(a6), d0
    lsl.w   #5, d0
    adda.w  d0, a2
    moveq   #0, d0
    move.b  d1, d0
    add.w   d0, d0                        ; step * 2
    move.b  (a2,d0.w), d2                 ; phrase#
    move.b  (1,a2,d0.w), c_transp(a6)     ; transpose
    moveq   #0, d3
    move.b  d2, d3
    lsl.w   #6, d3                        ; * PHRASE_SIZE
    lea     phrases, a1
    adda.w  d3, a1
    move.l  a1, c_phrase(a6)
    rts

; ============================================================
; exec_cmd -- the shared voice-command executor: Q X O U K F C P R Y. a1 = row (cmd@+2,
; prm@+3), d1 = row offset, a6 = channel. Runs the command's effect and returns; the CALLER
; resolves the note (advance_ch falls into .cmddone) or not (table_cmd). The phrase-structural
; commands (H I J) and global ones (T W) are NOT here -- advance_ch keeps those inline. The
; local .cmddone is just an rts, so the handlers move in verbatim (they end `bra .cmddone`).
; ============================================================
exec_cmd:
    move.b  (2,a1,d1.w), d2               ; command letter (A-Z = 1..26)
    cmpi.b  #17, d2                        ; Q xy = one-shot ALGO(x)+FB(y) override
    beq     .cmd_q
    cmpi.b  #24, d2                        ; X xx = volume (carrier TL)
    beq     .cmd_x
    cmpi.b  #15, d2                        ; O xy = pan (FM L/R)
    beq     .cmd_o
    cmpi.b  #21, d2                        ; U xx = modulator TL (brightness)
    beq     .cmd_u
    cmpi.b  #11, d2                        ; K xx = note cut after xx ticks
    beq     .cmd_k
    cmpi.b  #6, d2                         ; F xx = finetune (signed period/F-num delta)
    beq     .cmd_f
    cmpi.b  #3, d2                         ; C xy = chord/arp (0,x,y semitones)
    beq     .cmd_c
    cmpi.b  #16, d2                        ; P xx = pitch bend (signed rate/tick)
    beq     .cmd_p
    cmpi.b  #18, d2                        ; R xx = retrigger every xx ticks
    beq     .cmd_r
    cmpi.b  #25, d2                        ; Y xy = FM LFO depth (AMS/FMS)
    beq     .cmd_y
    rts                                    ; not a voice command (or no command)
.cmd_q:
    cmpi.b  #1, c_type(a6)                 ; FM channels only
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = (ALGO<<4)|FB
    move.b  d2, d3
    lsr.b   #4, d3                         ; x nibble = ALGO 0-7
    andi.b  #7, d3
    andi.b  #7, d2                         ; y nibble = FB 0-7
    lsl.b   #3, d2                         ; -> $B0 value = (FB<<3)|ALGO
    or.b    d3, d2
    moveq   #0, d3                         ; per-channel live slot (this running channel, not F1)
    move.b  c_track(a6), d3
    lea     lq_b0, a4
    move.b  d2, (a4,d3.w)
    lea     lq_dirty, a4
    move.b  #1, (a4,d3.w)
    bra     .cmddone
.cmd_x:
    cmpi.b  #1, c_type(a6)
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = new volume 0-15
    andi.b  #$0F, d2
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     lx_vol, a4
    move.b  d2, (a4,d3.w)                 ; lx_vol[track] = live volume (this channel)
    lea     lx_dirty, a4
    move.b  #1, (a4,d3.w)
    bra     .cmddone
.cmd_o:
    cmpi.b  #1, c_type(a6)                 ; FM channels (DAC pan TBD)
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = x(L) y(R) nibbles -> $B4 pan bits 7/6
    moveq   #0, d3
    move.b  d2, d0
    andi.b  #$F0, d0                       ; x nibble set -> left on (bit7)
    beq.s   .o_nol
    ori.b   #$80, d3
.o_nol:
    andi.b  #$0F, d2                       ; y nibble set -> right on (bit6)
    beq.s   .o_nor
    ori.b   #$40, d3
.o_nor:
    moveq   #0, d0                          ; preserve the instrument's AMS/FMS
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    lea     instrum, a4
    adda.w  d0, a4
    move.b  (i_ams,a4), d0
    andi.b  #3, d0
    lsl.b   #4, d0
    or.b    d0, d3
    move.b  (i_fms,a4), d0
    andi.b  #7, d0
    or.b    d0, d3
    moveq   #0, d0
    move.b  c_track(a6), d0
    lea     lo_b4, a4
    move.b  d3, (a4,d0.w)
    lea     lo_dirty, a4
    move.b  #1, (a4,d0.w)
    bra     .cmddone
.cmd_u:
    cmpi.b  #1, c_type(a6)
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; PR = modulator TL offset 0-127 (added above stored TL)
    andi.b  #$7F, d2
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     lu_off, a4
    move.b  d2, (a4,d3.w)
    lea     lu_dirty, a4
    move.b  #1, (a4,d3.w)
    bra     .cmddone
.cmd_k:
    move.b  #1, k_set                      ; this row's note-on must keep K's gate, not the HLD
    move.b  (3,a1,d1.w), d2               ; K xx = key-off after xx ticks; K00 = cut now
    bne.s   .ck_hold
    move.b  #0, c_keyon(a6)                ; K00 = cut now: FM key-off...
    move.b  #3, c_estate(a6)               ; ...PSG/noise -> decay/release (state 3)...
    move.b  #0, c_ectr(a6)
    bsr     cut_dac_if_sample              ; ...and KIT/WAVE -> stop the DAC now
    bra     .cmddone
.ck_hold:
    move.b  d2, c_hold(a6)
    bra     .cmddone
.cmd_f:
    move.b  #1, f_set                      ; F on this row -> note-on keeps c_pfine
    move.b  (3,a1,d1.w), d2               ; F xx = signed fine pitch offset (period/F-num units)
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     c_pfine, a4
    move.b  d2, (a4,d3.w)
    bra     .cmddone
.cmd_c:
    move.b  #1, c_set                      ; C on this row -> note-on keeps the chord
    move.b  (3,a1,d1.w), d2               ; C xy = chord offsets (x<<4)|y semitones; 0 = off
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     c_chord, a4
    move.b  d2, (a4,d3.w)
    lea     c_cphase, a4
    move.b  #0, (a4,d3.w)                 ; restart the arp phase
    bra     .cmddone
.cmd_p:
    move.b  #1, p_set                      ; P on this row -> note-on keeps c_bend
    move.b  (3,a1,d1.w), d2               ; P xx = signed bend rate (period/F-num units per tick)
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     c_bend, a4
    move.b  d2, (a4,d3.w)
    bra     .cmddone
.cmd_r:
    move.b  (3,a1,d1.w), d2               ; R xx = retrigger every xx ticks
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     c_rtper, a4
    move.b  d2, (a4,d3.w)
    lea     c_rtctr, a4
    move.b  d2, (a4,d3.w)                 ; first retrig xx ticks from now
    bra     .cmddone
.cmd_y:
    cmpi.b  #1, c_type(a6)                ; FM channels only
    bne     .cmddone
    move.b  (3,a1,d1.w), d2               ; Y xy = FM LFO depth: x=AMS (0-3), y=FMS (0-7).
    moveq   #0, d3                         ; Builds $B4 = (instrument pan)<<6 | AMS<<4 | FMS and
    move.b  c_instr(a6), d3               ; rides O's lo_b4/lo_dirty shadow -> emitted now, reverts
    mulu.w  #INSTR_SIZE, d3               ; to the instrument next note (needs the global LFO $22 on
    lea     instrum, a4                    ; to be audible).
    adda.w  d3, a4
    moveq   #0, d3
    move.b  (i_pan,a4), d3                ; keep the instrument's pan bits
    lsl.b   #6, d3
    move.b  d2, d1                         ; AMS = high nibble -> bits 5-4
    lsr.b   #4, d1
    andi.b  #3, d1
    lsl.b   #4, d1
    or.b    d1, d3
    move.b  d2, d1                         ; FMS = low nibble -> bits 2-0
    andi.b  #7, d1
    or.b    d1, d3
    moveq   #0, d2
    move.b  c_track(a6), d2
    lea     lo_b4, a4
    move.b  d3, (a4,d2.w)
    lea     lo_dirty, a4
    move.b  #1, (a4,d2.w)
    bra     .cmddone
.cmddone:                                 ; local: the handlers' "done" -> just return (no note here)
    rts

; run the active table row's CMD column (cmd@+2, prm@+3) once on row entry, via exec_cmd.
; a6 = channel.
table_cmd:
    move.b  c_tbl(a6), d0
    cmpi.b  #$FF, d0
    beq.s   .tc_done                      ; no table
    tst.b   c_estate(a6)
    beq.s   .tc_done                      ; voice off -> don't run table commands
    move.b  c_trow(a6), d1
    cmp.b   c_tcrow(a6), d1
    beq.s   .tc_done                      ; same row -> its CMD already ran
    move.b  d1, c_tcrow(a6)               ; mark this row's CMD done
    moveq   #0, d2                        ; a1 = tbl_ram + table*64 + row*TROW
    move.b  d0, d2
    lsl.w   #6, d2
    moveq   #0, d0
    move.b  d1, d0
    lsl.w   #2, d0
    add.w   d0, d2
    lea     tbl_ram, a1
    adda.w  d2, a1
    moveq   #0, d1                        ; a1 already points at the row -> offset 0
    bsr     exec_cmd                      ; run the row's voice command -- no note resolution
.tc_done:
    rts

; software AHD volume envelope for PSG voices, driven by the playing instrument's
; VOL/ATK/HLD/DCY (FM voices use the YM2612 hardware envelope instead).
env_ch:                                   ; a6 = channel
    move.b  #$FF, c_tvol(a6)              ; default: no table-VOL override (.tapply / FM tick sets it)
    cmpi.b  #1, c_type(a6)
    bne.s   .ec_psg
    ; --- FM voice: tick the macro table (advance + latch c_tvol/c_ttsp), then done. The FM
    ;     envelope is the YM2612's; compose_fm consumes c_ttsp (pitch) and c_tvol (carrier TL). ---
    clr.b   c_ttsp(a6)                     ; default: no table transpose
    move.b  c_tbl(a6), d0
    cmpi.b  #$FF, d0
    beq     .e_done                        ; FM, no table -> nothing to latch
    lea     instrum, a4
    moveq   #0, d1
    move.b  c_instr(a6), d1
    mulu.w  #INSTR_SIZE, d1
    adda.w  d1, a4
    tst.b   c_keyon(a6)                    ; keyed off -> hold the current row (don't churn idle)
    beq.s   .fmt_latch
    move.b  (i_tbs,a4), d2
    beq.s   .fmt_latch                     ; TBS 0 = per-note: no per-tick advance
    addq.b  #1, c_tctr(a6)
    move.b  c_tctr(a6), d1
    cmp.b   d2, d1
    blo.s   .fmt_latch
    move.b  #0, c_tctr(a6)
    move.b  c_trow(a6), d1
    addq.b  #1, d1
    andi.b  #$0F, d1
    move.b  d1, c_trow(a6)
.fmt_latch:
    moveq   #0, d3
    move.b  c_tbl(a6), d3
    lsl.w   #6, d3
    moveq   #0, d1
    move.b  c_trow(a6), d1
    lsl.w   #2, d1
    add.w   d1, d3
    lea     tbl_ram, a1
    move.b  (t_vol,a1,d3.w), c_tvol(a6)   ; VOL column ($FF = no change) -> live carrier-TL override
    move.b  (t_tsp,a1,d3.w), c_ttsp(a6)   ; signed TSP -> fm_freq_send
    bra     .e_done
.ec_psg:
    move.b  c_estate(a6), d0
    beq     .e_done                        ; state 0 = off
    lea     instrum, a4                    ; a4 = instrum[c_instr]
    moveq   #0, d1
    move.b  c_instr(a6), d1
    mulu.w  #INSTR_SIZE, d1
    adda.w  d1, a4
    moveq   #0, d3                         ; macro table: advance at TBS, arp the period
    move.b  c_tbl(a6), d3
    cmpi.b  #$FF, d3
    beq     .notbl
    move.b  (i_tbs,a4), d2
    beq.s   .tapply                         ; TBS 0 = per-note: no per-tick advance
    addq.b  #1, c_tctr(a6)
    move.b  c_tctr(a6), d1
    cmp.b   d2, d1
    blo.s   .tapply
    move.b  #0, c_tctr(a6)
    move.b  c_trow(a6), d1
    addq.b  #1, d1
    andi.b  #$0F, d1                        ; loop row 16 -> 0
    move.b  d1, c_trow(a6)
.tapply:
    lsl.w   #6, d3                          ; table# * 64  (TBL_ROWS*TROW)
    moveq   #0, d1
    move.b  c_trow(a6), d1
    lsl.w   #2, d1                          ; row * TROW
    add.w   d1, d3
    lea     tbl_ram, a1                    ; editable RAM tables
    move.b  (t_vol,a1,d3.w), c_tvol(a6)   ; VOL column ($FF = no change) -> live override
    move.b  (t_tsp,a1,d3.w), d3            ; signed TSP offset (column 1)
    ext.w   d3
    moveq   #0, d1
    move.b  c_note(a6), d1
    add.w   d1, d3                          ; effective note
    moveq   #0, d0                          ; C command: add the chord arp offset (0,+x,+y)
    move.b  c_track(a6), d0
    lea     c_chord, a1
    move.b  (a1,d0.w), d1
    beq.s   .echord_no
    lea     c_cphase, a1
    move.b  (a1,d0.w), d0
    beq.s   .echord_no
    cmpi.b  #1, d0
    bne.s   .echord_y
    lsr.b   #4, d1                          ; phase 1 -> +x
    bra.s   .echord_add
.echord_y:
    andi.b  #$0F, d1                        ; phase 2 -> +y
.echord_add:
    ext.w   d1
    add.w   d1, d3
.echord_no:
    bmi.s   .notbl
    cmpi.w  #96, d3
    bhs.s   .notbl
    add.w   d3, d3
    lea     notetable, a1
    move.w  (a1,d3.w), c_period(a6)
.notbl:
    move.b  (ip_swp,a4), d3               ; SWP: per-tick pitch slide (signed period delta)
    beq.s   .noswp
    ext.w   d3
    add.w   c_period(a6), d3
    bgt.s   .swp1
    moveq   #1, d3                          ; clamp period 1..1023
    bra.s   .swpset
.swp1:
    cmpi.w  #1023, d3
    bls.s   .swpset
    move.w  #1023, d3
.swpset:
    move.w  d3, c_period(a6)
.noswp:
    move.b  c_estate(a6), d0              ; reload: the table-arp/chord path above clobbers d0
    cmpi.b  #1, d0
    bne.s   .e_hold
    move.b  (ip_atk,a4), d1               ; state 1 = attack
    bne.s   .a_ramp
    move.b  (ip_vol,a4), d1               ; ATK 0 -> instant to peak
    move.b  d1, c_vol(a6)
    move.b  #2, c_estate(a6)
    move.b  #0, c_ectr(a6)
    rts
.a_ramp:
    addq.b  #1, c_ectr(a6)                 ; one volume step per ATK ticks
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo     .e_done
    move.b  #0, c_ectr(a6)
    move.b  c_vol(a6), d1
    addq.b  #1, d1
    move.b  (ip_vol,a4), d2
    cmp.b   d2, d1
    blo.s   .a_set
    move.b  d2, d1                          ; reached peak -> hold
    move.b  #2, c_estate(a6)
    move.b  #0, c_ectr(a6)
.a_set:
    move.b  d1, c_vol(a6)
    rts
.e_hold:
    cmpi.b  #2, d0
    bne.s   .e_decay
    move.b  (ip_hld,a4), d1               ; state 2 = hold
    cmpi.b  #$0F, d1
    beq     .e_done                        ; F = infinite
    tst.b   d1
    beq.s   .h_end                         ; 0 = no hold
    add.b   d1, d1                          ; HLD * 2 ticks
    addq.b  #1, c_ectr(a6)
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo     .e_done
.h_end:
    move.b  #3, c_estate(a6)
    move.b  #0, c_ectr(a6)
    rts
.e_decay:
    move.b  (ip_dcy,a4), d1               ; state 3 = decay
    bne.s   .d_ramp
    move.b  #0, c_vol(a6)                 ; DCY 0 -> instant cut
    move.b  #0, c_estate(a6)
    rts
.d_ramp:
    addq.b  #1, c_ectr(a6)                 ; one step down per DCY ticks
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo.s   .e_done
    move.b  #0, c_ectr(a6)
    move.b  c_vol(a6), d1
    beq.s   .d_off
    subq.b  #1, d1
    move.b  d1, c_vol(a6)
    bne.s   .e_done
.d_off:
    move.b  #0, c_estate(a6)
.e_done:
    rts

compose_ch:                               ; a6=ch; a3/d6=PSG buf; a5/d5=YM buf
    move.b  c_type(a6), d0
    beq.s   .square
    cmpi.b  #2, d0
    beq     compose_noise
    bra     compose_fm
.square:
    moveq   #15, d1
    move.b  c_tvol(a6), d0                ; live table VOL ($FF = none) overrides the envelope
    cmpi.b  #$FF, d0
    bne.s   .sq_tv
    move.b  c_vol(a6), d0
.sq_tv:
    sub.b   d0, d1                        ; attenuation = 15 - volume
    bsr     psg_tremolo                   ; d1 += tremolo LFO
    move.w  c_period(a6), d2
    bsr     psg_vibrato                   ; d2 += vibrato LFO (preserves d1)
    moveq   #0, d0                          ; F/P fine pitch -> period. SUBTRACT: a bigger SN76489
    move.b  c_track(a6), d0                 ;   period = a LOWER note, so +pfine must shorten the
    lea     c_pfine, a1                      ;   period to raise pitch -- same direction as FM's F-num
    move.b  (a1,d0.w), d0
    ext.w   d0
    sub.w   d0, d2
    cmpi.b  #$FF, c_tbl(a6)                 ; C command (PSG): plain note only -- env_ch already
    bne.s   .fp_clamp                       ;   applies the chord on table notes (avoid double)
    moveq   #0, d0
    move.b  c_track(a6), d0
    lea     c_chord, a1
    moveq   #0, d3
    move.b  (a1,d0.w), d3                  ; packed (x<<4)|y
    beq.s   .fp_clamp
    lea     c_cphase, a1
    move.b  (a1,d0.w), d0                  ; arp phase
    beq.s   .fp_clamp                       ; phase 0 -> +0
    cmpi.b  #1, d0
    bne.s   .fc_y
    lsr.b   #4, d3                          ; phase 1 -> +x
    bra.s   .fc_off
.fc_y:
    andi.b  #$0F, d3                        ; phase 2 -> +y
.fc_off:
    moveq   #0, d0
    move.b  c_note(a6), d0
    add.w   d3, d0                          ; offset note = note + arp offset
    cmpi.w  #96, d0
    bhs.s   .fp_clamp                       ; out of range -> no arp this tick
    add.w   d0, d0
    lea     notetable, a1
    move.w  (a1,d0.w), d0                  ; period[note+offset]
    moveq   #0, d3
    move.b  c_note(a6), d3
    add.w   d3, d3
    sub.w   (a1,d3.w), d0                  ; - period[note] = delta (higher note -> lower period)
    add.w   d0, d2
.fp_clamp:
    tst.w   d2                              ; clamp period to [1, 1023]
    bgt.s   .fp_hi
    moveq   #1, d2
    bra.s   .fp_done
.fp_hi:
    cmpi.w  #1023, d2
    bls.s   .fp_done
    move.w  #1023, d2
.fp_done:
    cmp.w   c_shadowp(a6), d2
    beq.s   .sp
    move.w  d2, c_shadowp(a6)
    move.b  c_psgt(a6), d3
    move.b  d2, d0
    andi.b  #$0F, d0
    or.b    d0, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
    move.w  d2, d0
    lsr.w   #4, d0
    andi.w  #$003F, d0
    move.b  d0, (a3)+
    addq.b  #1, d6
.sp:
    cmp.b   c_shadowa(a6), d1
    beq.s   .sa
    move.b  d1, c_shadowa(a6)
    move.b  c_psgv(a6), d3
    or.b    d1, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.sa:
    rts

; PSG noise compose: control byte ($E0|mode from c_period) + vol ($F0|atten)
compose_noise:                            ; a6=ch; a3/d6=PSG buf
    moveq   #15, d1
    move.b  c_tvol(a6), d0                ; live table VOL ($FF = none) overrides the envelope
    cmpi.b  #$FF, d0
    bne.s   .no_tv
    move.b  c_vol(a6), d0
.no_tv:
    sub.b   d0, d1
    move.w  c_period(a6), d2
    cmp.w   c_shadowp(a6), d2
    beq.s   .nv
    move.w  d2, c_shadowp(a6)
    move.b  c_psgt(a6), d3                ; $E0
    move.b  d2, d0
    andi.b  #$07, d0                       ; noise mode 0-7
    or.b    d0, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.nv:
    cmp.b   c_shadowa(a6), d1
    beq.s   .nd
    move.b  d1, c_shadowa(a6)
    move.b  c_psgv(a6), d3                ; $F0
    or.b    d1, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
.nd:
    move.b  c_period(a6), d0             ; rate 3 = pitched: steal T3 (chan 2) for the noise pitch
    andi.b  #3, d0
    cmpi.b  #3, d0
    bne.s   .nret
    moveq   #0, d0
    move.b  c_note(a6), d0
    cmpi.w  #96, d0
    bhs.s   .nret                         ; no valid note yet -> leave T3 alone
    add.w   d0, d0
    lea     notetable, a1
    move.w  (a1,d0.w), d2                ; T3 period = notetable[note]
    move.b  d2, d3
    andi.b  #$0F, d3
    ori.b   #$C0, d3                     ; channel 2 tone latch + low nibble
    move.b  d3, (a3)+
    addq.b  #1, d6
    move.w  d2, d3
    lsr.w   #4, d3
    andi.w  #$3F, d3
    move.b  d3, (a3)+
    addq.b  #1, d6
    move.b  #$DF, (a3)+                  ; mute T3's own tone ($D0 vol latch | 15 = silent)
    addq.b  #1, d6
.nret:
    rts

; add the instrument's vibrato to a square period. VIB = (speed<<4)|depth; the LFO
; phase (c_modph) advances by speed each tick, indexing a 16-step signed sine.
; SMSGGDJ-style vibrato: triangle LFO on the period, phase += speed*4, 32 steps,
; depth -> exponential amplitude (vib_amp), delta = +-amp period units.
psg_vibrato:                              ; a6=ch, d2=period (in/out); preserves d1
    lea     instrum, a4
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a4
    moveq   #0, d0
    move.b  (ip_vib,a4), d0
    move.w  d0, d3
    andi.w  #$0F, d3                        ; depth index
    beq.s   .vret                          ; depth 0 = off
    lea     vib_amp, a1
    move.b  (a1,d3.w), d3                  ; exponential amplitude 0..60
    andi.w  #$F0, d0
    lsr.w   #2, d0                          ; speed * 4
    add.b   d0, c_modph(a6)               ; advance LFO phase
    moveq   #0, d0
    move.b  c_modph(a6), d0
    lsr.w   #3, d0
    andi.w  #$1F, d0                        ; step 0-31
    lea     vib_tri, a1
    move.b  (a1,d0.w), d0                  ; signed triangle -16..+16
    ext.w   d0
    muls.w  d3, d0                          ; amp * tri
    asr.w   #4, d0                          ; / 16 -> +-amp period units
    add.w   d0, d2
.vret:
    rts
vib_amp:    dc.b 0,1,2,3,4,5,6,8,10,13,17,22,28,36,46,60   ; SMSGGDJ exponential depth curve
vib_tri:    dc.b 0,2,4,6,8,10,12,14,16,14,12,10,8,6,4,2     ; 32-step signed triangle (x16)
            dc.b 0,-2,-4,-6,-8,-10,-12,-14,-16,-14,-12,-10,-8,-6,-4,-2
    even

; add the instrument's tremolo to a square attenuation (d1, 0=loud..15=silent).
; TRM = (speed<<4)|depth; own LFO phase (c_modph2). Preserves d2.
; SMSGGDJ-style tremolo: a one-directional triangular volume DIP (never louder
; than peak), phase += speed*4, 32 steps, dip = depth*tri(0..16..0)/16 (max = depth).
psg_tremolo:                              ; a6=ch, d1=attenuation (in/out)
    lea     instrum, a4
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a4
    moveq   #0, d0
    move.b  (ip_trm,a4), d0
    move.w  d0, d3
    andi.w  #$0F, d3                        ; depth
    beq.s   .tret                          ; depth 0 = off
    andi.w  #$F0, d0
    lsr.w   #2, d0                          ; speed * 4
    add.b   d0, c_modph2(a6)              ; advance LFO phase
    moveq   #0, d0
    move.b  c_modph2(a6), d0
    lsr.w   #3, d0
    andi.w  #$1F, d0                        ; step 0-31
    cmpi.w  #16, d0                        ; triangle 0 -> 16 -> 0 (peak dip at step 16)
    blo.s   .tup
    neg.w   d0
    addi.w  #32, d0
.tup:
    mulu.w  d3, d0                          ; depth * tri
    lsr.w   #4, d0                          ; dip = depth*tri/16  (0..depth)
    add.w   d0, d1                          ; dip volume = raise attenuation
    cmpi.w  #15, d1
    bls.s   .tret
    moveq   #15, d1                          ; clamp to silent
.tret:
    rts

; FM compose: emit YM writes (part,reg,value triples) into a5, count in d5
compose_fm:                               ; a6=ch; a5=YM ptr; d5=triple count
    moveq   #0, d0                          ; Q command: live $B0 (ALGO+FB) override for this channel?
    move.b  c_track(a6), d0
    lea     lq_dirty, a4
    tst.b   (a4,d0.w)
    beq.s   .cf_noq
    move.b  #0, (a4,d0.w)
    move.b  c_ympart(a6), (a5)+            ; emit $B0 + chreg = lq_b0[track] (morph the live timbre)
    move.b  #$B0, d1
    add.b   c_ymchreg(a6), d1
    move.b  d1, (a5)+
    lea     lq_b0, a4
    move.b  (a4,d0.w), (a5)+
    addq.w  #1, d5
.cf_noq:
    moveq   #0, d0                          ; X command: live carrier volume -> recompute carrier $40
    move.b  c_track(a6), d0
    lea     lx_dirty, a4
    tst.b   (a4,d0.w)
    beq.s   .cf_nox
    move.b  #0, (a4,d0.w)
    lea     lx_vol, a4
    move.b  (a4,d0.w), d1
    bsr     emit_x_tl
.cf_nox:
    moveq   #0, d0                          ; O command: live $B4 (pan / AMS / FMS)
    move.b  c_track(a6), d0
    lea     lo_dirty, a4
    tst.b   (a4,d0.w)
    beq.s   .cf_noo
    move.b  #0, (a4,d0.w)
    move.b  c_ympart(a6), (a5)+
    move.b  #$B4, d1
    add.b   c_ymchreg(a6), d1
    move.b  d1, (a5)+
    lea     lo_b4, a4
    move.b  (a4,d0.w), (a5)+
    addq.w  #1, d5
.cf_noo:
    moveq   #0, d0                          ; U command: live modulator TL offset -> recompute mod $40
    move.b  c_track(a6), d0
    lea     lu_dirty, a4
    tst.b   (a4,d0.w)
    beq.s   .cf_nou
    move.b  #0, (a4,d0.w)
    lea     lu_off, a4
    move.b  (a4,d0.w), d1
    bsr     emit_u_tl
.cf_nou:
    move.b  c_trig(a6), d0                  ; on a note trigger, emit this channel's operator patch
    beq     .nochg                          ;   (1 patch/tick, only if the SCB has room -- else defer)
    moveq   #0, d0
    move.b  c_track(a6), d0
    move.b  c_instr(a6), d1                 ; the note's own instrument
    lea     pshadow, a4
    cmp.b   (a4,d0.w), d1
    beq.s   .cf_keys                        ; that patch already loaded on this channel -> just key
    tst.b   patch_done
    bne     .cf_defer
    cmpi.w  #PATCH_CAP, d5
    bhi     .cf_defer
    move.b  d1, (a4,d0.w)                   ; pshadow[track] = instrument loaded (Y or own); a later plain
    move.b  #1, patch_done                  ;   note then has pshadow != c_instr -> re-patches = Y reverts
    bsr     emit_ch_patch                   ; d1 = chosen instrument's operator patch (before key-on)
    bra.s   .cf_emit
.cf_keys:
    cmpi.w  #YM_CAP, d5
    bhi     .cf_defer
.cf_emit:
    move.b  #0, c_trig(a6)
    move.b  #0, (a5)+                       ; key-off: part0, $28, ymkey
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), (a5)+
    addq.w  #1, d5
    bsr     fm_freq_send                   ; effective note (+ chord arp + fine) -> emit $A4/$A0
    move.b  #0, (a5)+                       ; key-on: part0, $28, $F0|ymkey
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), d3
    ori.b   #$F0, d3
    move.b  d3, (a5)+
    addq.w  #1, d5
    move.b  #1, c_kshadow(a6)
    rts
.cf_defer:
    rts                                     ; c_trig stays set -> retry next tick (no key-on yet)
.nochg:
    tst.b   c_keyon(a6)                     ; per-tick FM-freq re-send: only while the note is on
    beq.s   .nofreqres
    moveq   #0, d0                          ; ...and only if a pitch-mod (chord or bend) is active
    move.b  c_track(a6), d0
    lea     c_chord, a4
    tst.b   (a4,d0.w)
    bne.s   .dofreqres
    lea     c_bend, a4
    tst.b   (a4,d0.w)
    beq.s   .nofreqres
.dofreqres:
    cmpi.w  #YM_CAP, d5                      ; SCB headroom -> drop this tick's re-send if full
    bhi.s   .nofreqres
    bsr     fm_freq_send
.nofreqres:
    move.b  c_keyon(a6), d0               ; key state changed (e.g. stop -> off)?
    cmp.b   c_kshadow(a6), d0
    beq.s   .done
    move.b  d0, c_kshadow(a6)
    move.b  #0, (a5)+
    move.b  #$28, (a5)+
    move.b  c_ymkey(a6), d3
    tst.b   d0
    beq.s   .off
    ori.b   #$F0, d3                        ; key-on
.off:
    move.b  d3, (a5)+
    addq.w  #1, d5
.done:
    rts

; Append channel a6's full FM operator patch (operators $30-$80 + $B0/$B4) into the SCB at (a5)+,
; advancing the triple count d5. Channel-aware: emits to c_ympart / (reg + c_ymchreg), reads c_instr.
emit_ch_patch:                              ; d1 = instrument # to patch from (caller passes c_instr)
    movem.l d1-d4/d6/a3-a4, -(sp)
    moveq   #0, d0
    move.b  d1, d0
    mulu.w  #INSTR_SIZE, d0
    lea     instrum, a3
    adda.w  d0, a3                          ; a3 = the patch-source instrument
    moveq   #0, d6                          ; operator slot 0..3 (register order)
.ecp_op:
    move.w  d6, d4                          ; param base = i_op + slot*FM_NPARM
    mulu.w  #FM_NPARM, d4
    addi.w  #i_op, d4
    move.w  d6, d2                          ; reg offset = slot*4 + channel reg
    lsl.w   #2, d2
    moveq   #0, d1
    move.b  c_ymchreg(a6), d1
    add.w   d1, d2
    move.b  (1,a3,d4.w), d1                 ; $30: (DT<<4)|MUL
    lsl.b   #4, d1
    move.b  (0,a3,d4.w), d0
    or.b    d1, d0
    move.b  #$30, d3
    bsr     .ecp_emit
    move.b  (2,a3,d4.w), d0                 ; $40: TL (+ carrier VOL attenuation)
    moveq   #0, d1
    move.b  (i_algo,a3), d1
    andi.w  #7, d1
    lea     carrier_mask, a4
    btst    d6, (a4,d1.w)
    beq.s   .ecp_nov
    moveq   #15, d1
    sub.b   (i_vol,a3), d1
    lsl.b   #3, d1
    add.b   d1, d0
    cmpi.b  #127, d0
    bls.s   .ecp_nov
    moveq   #127, d0
.ecp_nov:
    move.b  #$40, d3
    bsr     .ecp_emit
    move.b  (3,a3,d4.w), d1                 ; $50: (RS<<6)|AR
    lsl.b   #6, d1
    move.b  (4,a3,d4.w), d0
    or.b    d1, d0
    move.b  #$50, d3
    bsr     .ecp_emit
    move.b  (5,a3,d4.w), d1                 ; $60: (AM<<7)|D1R
    lsl.b   #7, d1
    move.b  (6,a3,d4.w), d0
    or.b    d1, d0
    move.b  #$60, d3
    bsr     .ecp_emit
    move.b  (7,a3,d4.w), d0                 ; $70: D2R
    move.b  #$70, d3
    bsr     .ecp_emit
    move.b  (9,a3,d4.w), d1                 ; $80: (SL<<4)|RR
    lsl.b   #4, d1
    move.b  (8,a3,d4.w), d0
    or.b    d1, d0
    move.b  #$80, d3
    bsr     .ecp_emit
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .ecp_op
    moveq   #0, d2                          ; $B0: (FB<<3)|ALGO -- reg = $B0 + channel reg
    move.b  c_ymchreg(a6), d2
    move.b  (i_fb,a3), d1
    lsl.b   #3, d1
    move.b  (i_algo,a3), d0
    or.b    d1, d0
    move.b  #$B0, d3
    bsr     .ecp_emit
    move.b  (i_pan,a3), d0                  ; $B4: (pan<<6)|(AMS<<4)|FMS
    lsl.b   #6, d0
    move.b  (i_ams,a3), d1
    andi.b  #3, d1
    lsl.b   #4, d1
    or.b    d1, d0
    move.b  (i_fms,a3), d1
    andi.b  #7, d1
    or.b    d1, d0
    move.b  #$B4, d3
    bsr     .ecp_emit
    movem.l (sp)+, d1-d4/d6/a3-a4
    rts
.ecp_emit:                                  ; emit triple (c_ympart, d3+d2, d0) -> (a5)+, d5++
    move.b  c_ympart(a6), (a5)+
    move.b  d3, d1
    add.b   d2, d1
    move.b  d1, (a5)+
    move.b  d0, (a5)+
    addq.w  #1, d5
    rts

; X command helper: emit the channel's carrier $40 (TL) with live volume d1 (0-15).
; carrier TL = stored TL + (15-vol)*8, clamped 127. a6=ch, a5/d5=SCB.
emit_x_tl:
    movem.l d1-d4/d6/a3-a4, -(sp)
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    lea     instrum, a3
    adda.w  d0, a3
    moveq   #15, d4
    sub.b   d1, d4
    lsl.b   #3, d4                          ; d4 = atten = (15-vol)*8
    moveq   #0, d6
.ext_op:
    moveq   #0, d0                          ; carrier in this algorithm?
    move.b  (i_algo,a3), d0
    andi.w  #7, d0
    lea     carrier_mask, a4
    btst    d6, (a4,d0.w)
    beq.s   .ext_next
    move.w  d6, d2                          ; param base = i_op + slot*FM_NPARM
    mulu.w  #FM_NPARM, d2
    addi.w  #i_op, d2
    move.b  (2,a3,d2.w), d0                 ; carrier TL + atten, clamp 127
    add.b   d4, d0
    cmpi.b  #127, d0
    bls.s   .ext_clamp
    moveq   #127, d0
.ext_clamp:
    move.b  c_ympart(a6), (a5)+
    move.w  d6, d2                          ; reg = $40 + slot*4 + chreg
    lsl.w   #2, d2
    move.b  c_ymchreg(a6), d3
    add.b   d3, d2
    move.b  #$40, d3
    add.b   d2, d3
    move.b  d3, (a5)+
    move.b  d0, (a5)+
    addq.w  #1, d5
.ext_next:
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .ext_op
    movem.l (sp)+, d1-d4/d6/a3-a4
    rts

; U command helper: emit the channel's modulator $40 (TL) = stored TL + offset d1, clamp 127.
emit_u_tl:
    movem.l d1-d4/d6/a3-a4, -(sp)
    moveq   #0, d0
    move.b  c_instr(a6), d0
    mulu.w  #INSTR_SIZE, d0
    lea     instrum, a3
    adda.w  d0, a3
    move.b  d1, d4                          ; d4 = TL offset
    moveq   #0, d6
.eut_op:
    moveq   #0, d0                          ; modulator (NOT a carrier) in this algorithm?
    move.b  (i_algo,a3), d0
    andi.w  #7, d0
    lea     carrier_mask, a4
    btst    d6, (a4,d0.w)
    bne.s   .eut_next
    move.w  d6, d2
    mulu.w  #FM_NPARM, d2
    addi.w  #i_op, d2
    move.b  (2,a3,d2.w), d0
    add.b   d4, d0
    cmpi.b  #127, d0
    bls.s   .eut_clamp
    moveq   #127, d0
.eut_clamp:
    move.b  c_ympart(a6), (a5)+
    move.w  d6, d2
    lsl.w   #2, d2
    move.b  c_ymchreg(a6), d3
    add.b   d3, d2
    move.b  #$40, d3
    add.b   d2, d3
    move.b  d3, (a5)+
    move.b  d0, (a5)+
    addq.w  #1, d5
.eut_next:
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .eut_op
    movem.l (sp)+, d1-d4/d6/a3-a4
    rts

; emit the FM channel's frequency ($A4/$A0) from c_note + chord arp offset + c_pfine fine.
; a6=ch, a5/d5=SCB. Clobbers d0-d4/a4 (compose-context scratch). Used at trigger + per-tick re-send.
fm_freq_send:
    moveq   #0, d0
    move.b  c_note(a6), d0                  ; effective note = c_note + table TSP + chord arp offset
    move.b  c_ttsp(a6), d3                  ; macro-table transpose (signed; 0 when no table)
    ext.w   d3
    add.w   d3, d0
    moveq   #0, d3
    move.b  c_track(a6), d3
    lea     c_chord, a4
    move.b  (a4,d3.w), d1
    beq.s   .ffs_nochord
    lea     c_cphase, a4
    move.b  (a4,d3.w), d3
    beq.s   .ffs_nochord
    cmpi.b  #1, d3
    bne.s   .ffs_cy
    lsr.b   #4, d1                          ; phase 1 -> +x
    bra.s   .ffs_cadd
.ffs_cy:
    andi.b  #$0F, d1                        ; phase 2 -> +y
.ffs_cadd:
    ext.w   d1
    add.w   d1, d0
.ffs_nochord:
    tst.w   d0                              ; clamp the effective note to the fnum table [0,95]
    bpl.s   .ffs_clo
    moveq   #0, d0
.ffs_clo:
    cmpi.w  #95, d0
    bls.s   .ffs_chi
    moveq   #95, d0
.ffs_chi:
    bsr     fm_freq                         ; d1=$A4, d2=$A0
    moveq   #0, d3                          ; F command fine -> add to the 11-bit fnum
    move.b  c_track(a6), d3
    lea     c_pfine, a4
    move.b  (a4,d3.w), d3
    beq.s   .ffs_nofine
    ext.w   d3
    move.w  d1, d4
    andi.w  #7, d4
    lsl.w   #8, d4
    move.w  d2, d0
    andi.w  #$FF, d0
    or.w    d0, d4
    add.w   d3, d4
    bpl.s   .ffs_fhi
    moveq   #0, d4
.ffs_fhi:
    cmpi.w  #2047, d4
    bls.s   .ffs_fset
    move.w  #2047, d4
.ffs_fset:
    move.b  d4, d2
    andi.b  #$F8, d1
    move.w  d4, d0
    lsr.w   #8, d0
    andi.b  #7, d0
    or.b    d0, d1
.ffs_nofine:
    move.b  c_ympart(a6), (a5)+            ; freq hi: part, $A4+chreg, d1
    move.b  #$A4, d3
    add.b   c_ymchreg(a6), d3
    move.b  d3, (a5)+
    move.b  d1, (a5)+
    addq.w  #1, d5
    move.b  c_ympart(a6), (a5)+            ; freq lo: part, $A0+chreg, d2
    move.b  #$A0, d3
    add.b   c_ymchreg(a6), d3
    move.b  d3, (a5)+
    move.b  d2, (a5)+
    addq.w  #1, d5
    rts

; d0 = note (0-95) -> d1 = $A4 value (block<<3 | fnum hi), d2 = $A0 value (fnum lo)
fm_freq:
    andi.l  #$0000FFFF, d0
    divu.w  #12, d0                         ; low = block(octave), high = semitone
    move.w  d0, d4                          ; block
    clr.w   d0
    swap    d0                             ; semitone
    add.w   d0, d0                         ; * 2
    lea     fm_fnum, a1
    move.w  (a1,d0.w), d2                  ; fnum
    move.w  d2, d1
    lsr.w   #8, d1                         ; fnum >> 8
    andi.w  #$0007, d4
    lsl.w   #3, d4                         ; block << 3
    or.w    d4, d1                         ; $A4 value
    andi.w  #$00FF, d2                     ; $A0 value
    rts

push_scb:
    move.w  #$0100, Z80_BUSREQ
.w:
    btst    #0, Z80_BUSREQ
    bne.s   .w
    move.b  scb_count, d0                ; --- PSG section ---
    move.b  d0, Z80_RAM+$1F01
    beq.s   .nopsg
    ext.w   d0
    subq.w  #1, d0
    lea     scb_data, a4
    lea     Z80_RAM+$1F02, a3
.pcp:
    move.b  (a4)+, (a3)+
    dbra    d0, .pcp
.nopsg:
    moveq   #0, d7                        ; --- YM section (triples) ---
    move.b  ym_count, d7                 ; running triple count (composed note SCB)
    lea     Z80_RAM+$1F21, a2            ; mailbox YM write pointer
    tst.b   d7
    beq.s   .ymap
    move.w  d7, d0
    mulu.w  #3, d0
    subq.w  #1, d0
    lea     ym_data, a4
.ycp:
    move.b  (a4)+, (a2)+
    dbra    d0, .ycp
.ymap:
    tst.b   g_lfo_dirty                   ; global LFO changed -> emit $22 once (decoupled from F1)
    beq.s   .nolfo22
    move.b  #0, g_lfo_dirty
    moveq   #0, d0
    move.b  g_lfo, d0
    beq.s   .lfo22z                        ; 0 = off ($00); 1-8 = enable bit 3 | rate 0-7
    subq.b  #1, d0
    ori.b   #$08, d0
.lfo22z:
    move.b  #0, (a2)+                      ; YM triple: part0, reg $22, value
    move.b  #$22, (a2)+
    move.b  d0, (a2)+
    addq.b  #1, d7
.nolfo22:
    tst.b   repatch                       ; Q/X command or FM edit -> append the patch to THIS push
    beq.s   .noym
    move.b  #0, repatch
    bsr     ym_build_patch                ; appends into (a2)+, d7 += patch count (no race)
.noym:
    move.b  d7, Z80_RAM+$1F20            ; final ym_count = notes + (maybe) patch
    addq.b  #1, g_seq
    move.b  g_seq, Z80_RAM+$1F00
    move.w  #$0000, Z80_BUSREQ
    rts

; trigger a kit sample on the DAC: d0 = kit, d1 = pad (0..15).
; resolves (kit,pad) -> sample ROM addr via the directory, computes the Z80
; window bank/pointer, and pushes the DAC command (own BUSREQ). Empty pad = no-op.
dac_play:
    movem.l d2-d6/a0, -(sp)
    andi.w  #15, d0                         ; clamp kit 0..15 (guards an uninitialised i_kit)
    move.w  d0, d2                         ; member = pool + 16 (header) + (kit*16+pad)*16
    lsl.w   #4, d2
    add.w   d1, d2
    lsl.w   #4, d2                          ; *16 (member size)
    addi.w  #16, d2                         ; skip the magic header
    lea     sample_pool, a0
    move.l  (a0,d2.w), d3                  ; member offset (bytes from pool start)
    move.l  4(a0,d2.w), d4                 ; member length
    tst.l   d4
    beq     .dpx                           ; empty pad -> nothing
    adda.l  d3, a0                          ; a0 = absolute sample ROM address (A)
    move.l  a0, d3
    move.l  d3, d5                          ; bank = A >> 15
    lsr.l   #8, d5
    lsr.l   #7, d5
    andi.l  #$7FFF, d3                      ; ptr = $8000 | (A & $7FFF)
    ori.w   #$8000, d3
    move.w  #$0100, Z80_BUSREQ
.dpw:
    btst    #0, Z80_BUSREQ
    bne.s   .dpw
    move.b  d5, Z80_RAM+$1FB1              ; dbank lo / hi (Z80 little-endian)
    lsr.w   #8, d5
    move.b  d5, Z80_RAM+$1FB2
    move.b  d3, Z80_RAM+$1FB3              ; dptr lo / hi
    move.w  d3, d5
    lsr.w   #8, d5
    move.b  d5, Z80_RAM+$1FB4
    move.b  d4, Z80_RAM+$1FB5              ; dlen lo / hi
    move.w  d4, d5
    lsr.w   #8, d5
    move.b  d5, Z80_RAM+$1FB6
    moveq   #0, d5                        ; rate -> window step + half-rate flag
    move.b  (i_rate,a1), d5
    andi.w  #3, d5
    lea     rate_step, a0
    move.b  (a0,d5.w), Z80_RAM+$1FB8
    lea     rate_half, a0
    move.b  (a0,d5.w), Z80_RAM+$1FB9
    addq.b  #1, Z80_RAM+$1FB0              ; bump the DAC trigger
    move.w  #$0000, Z80_BUSREQ
.dpx:
    movem.l (sp)+, d2-d6/a0
    rts

; ---- advance the wave AHD envelope one frame (a6 = channel, a4 = WAVE instrument).
; Mirrors the PSG software AHD: state 1 attack (0->VOL) -> 2 hold (HLD) -> 3 decay (->0)
; -> 0 off. Sets c_vol 0-15, which bake_wave uses as the per-frame amplitude. Clobbers d0-d2.
wave_env:
    moveq   #0, d0
    move.b  c_estate(a6), d0
    beq     .wend                           ; state 0 = off (c_vol stays 0)
    cmpi.b  #1, d0
    bne.s   .whld
    move.b  (ip_atk,a4), d1                 ; --- attack ---
    bne.s   .wa_ramp
    move.b  (ip_vol,a4), d1                 ; ATK 0 -> instant to peak
    move.b  d1, c_vol(a6)
    move.b  #2, c_estate(a6)
    move.b  #0, c_ectr(a6)
    rts
.wa_ramp:
    addq.b  #1, c_ectr(a6)                  ; one step up per ATK ticks
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo     .wend
    move.b  #0, c_ectr(a6)
    move.b  c_vol(a6), d1
    addq.b  #1, d1
    move.b  (ip_vol,a4), d2
    cmp.b   d2, d1
    blo.s   .wa_set
    move.b  d2, d1                           ; reached peak -> hold
    move.b  #2, c_estate(a6)
    move.b  #0, c_ectr(a6)
.wa_set:
    move.b  d1, c_vol(a6)
    rts
.whld:
    cmpi.b  #2, d0
    bne.s   .wdcy
    move.b  (ip_hld,a4), d1                 ; --- hold ---
    cmpi.b  #$0F, d1
    beq     .wend                            ; F = infinite (sustain)
    tst.b   d1
    beq.s   .wh_end                          ; 0 = no hold
    add.b   d1, d1                            ; HLD*2 ticks
    addq.b  #1, c_ectr(a6)
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo     .wend
.wh_end:
    move.b  #3, c_estate(a6)
    move.b  #0, c_ectr(a6)
    rts
.wdcy:
    move.b  (ip_dcy,a4), d1                 ; --- decay ---
    bne.s   .wd_ramp
    move.b  #0, c_vol(a6)                    ; DCY 0 -> instant cut
    move.b  #0, c_estate(a6)
    rts
.wd_ramp:
    addq.b  #1, c_ectr(a6)                  ; one step down per DCY ticks
    move.b  c_ectr(a6), d2
    cmp.b   d1, d2
    blo     .wend
    move.b  #0, c_ectr(a6)
    move.b  c_vol(a6), d1
    beq.s   .wd_off
    subq.b  #1, d1
    move.b  d1, c_vol(a6)
    bne.s   .wend
.wd_off:
    move.b  #0, c_estate(a6)
.wend:
    rts

; ---- per-frame: fill wbake_in (the 5 values bake_wave reads) from the instrument's LFO grid.
; VOLUME's base is the live AHD level (c_vol) so tremolo rides inside the envelope; the four
; shapers use their static OFFSET field as the base. a4 = instrument, a6 = channel.
wave_lfo:
    movem.l d3-d5/a2-a3, -(sp)
    moveq   #0, d0                          ; VOLUME: base = env level, phase slot 0
    move.b  c_vol(a6), d0
    moveq   #0, d1
    move.b  (iwl_vd,a4), d1                 ; depth
    moveq   #0, d2
    move.b  (iwl_vr,a4), d2                 ; rate
    moveq   #0, d3
    bsr     wlfo_one
    move.b  d0, wbake_in
    lea     wlfo_sfld, a2                  ; shapers WARP/FOLD/DRIVE/CRUSH -> slots 1..4
    moveq   #1, d3
.wls:
    moveq   #0, d5
    move.b  (a2)+, d5                      ; OFFSET field
    moveq   #0, d0
    move.b  (a4,d5.w), d0                  ; base = static offset value
    moveq   #0, d5
    move.b  (a2)+, d5                      ; RATE field
    moveq   #0, d2
    move.b  (a4,d5.w), d2
    moveq   #0, d5
    move.b  (a2)+, d5                      ; DEPTH field
    moveq   #0, d1
    move.b  (a4,d5.w), d1
    bsr     wlfo_one
    lea     wbake_in, a3
    move.b  d0, (a3,d3.w)
    addq.w  #1, d3
    cmpi.w  #6, d3                          ; 5 table params (warp/fold/drive/crush/pitch)
    bne.s   .wls
    movem.l (sp)+, d3-d5/a2-a3
    rts

; wlfo_one: d0=base(0-15), d1=depth, d2=rate, d3=phase index (0-4). Returns d0 = clamp(base +
; (depth*triangle(phase))>>6, 0, 15) and advances wlfo_phase[d3] by rate (only if depth>0).
wlfo_one:
    andi.w  #15, d1                         ; depth 0 -> static base, no LFO, no phase advance
    beq.s   .wo_ret
    andi.w  #15, d2
    lea     wlfo_phase, a3
    move.b  (a3,d3.w), d4
    add.b   d2, d4                          ; phase += rate (byte wraps = LFO period)
    move.b  d4, (a3,d3.w)
    andi.w  #$FF, d4
    move.w  d4, d2                          ; triangle: fold 0..255 -> 0..127, centre 64
    cmpi.w  #128, d2
    blo.s   .wo_t
    move.w  #255, d5
    sub.w   d2, d5
    move.w  d5, d2
.wo_t:
    subi.w  #64, d2                         ; tri in -64..63
    muls.w  d2, d1                          ; depth * tri
    asr.w   #6, d1                          ; / 64 -> swing +/- depth
    add.w   d1, d0
    bpl.s   .wo_c
    moveq   #0, d0
.wo_c:
    cmpi.w  #15, d0
    bls.s   .wo_ret
    moveq   #15, d0
.wo_ret:
    rts

wlfo_sfld:                                  ; LFO field table: OFFSET, RATE, DEPTH
    dc.b iw_warp, iwl_wr, iwl_wd           ; -> wbake_in[1]
    dc.b iw_fold, iwl_fr, iwl_fd           ; -> wbake_in[2]
    dc.b iw_drive, iwl_dr, iwl_dd          ; -> wbake_in[3]
    dc.b iw_crush, iwl_cr, iwl_cd          ; -> wbake_in[4]
    dc.b iw_pitch, iwl_pr, iwl_pd          ; -> wbake_in[5] (detune/vibrato, applied by wave_play)
    even

; ---- bake the base wave (a5) through the shaper chain into wave_bake (32 B).
; a1 = WAVE instrument. Chain (DESIGN.md $10.6): WARP -> DRIVE -> FOLD -> CRUSH -> x VOL.
; WARP skews the source index (pivot p=16+WARP); DRIVE is a tanh ROM table; FOLD reflects
; past +/-T; CRUSH drops low bits; VOL = the AHD env level (c_vol) scaling the deviation.
; Preserves a1/a4/a5/a6; clobbers a2/a3/d0-d7 (wave_play reloads d0-d7 from wave_bake after).
bake_wave:
    moveq   #0, d2
    move.b  wbake_in, d2                  ; VOL: env level x tremolo (filled by wave_lfo)
    moveq   #0, d6
    move.b  wbake_in+2, d6                 ; FOLD (modulated)
    andi.w  #15, d6
    lsl.w   #3, d6                          ; FOLD * 8
    move.w  #128, d3
    sub.w   d6, d3                          ; d3 = fold threshold T = 128 - FOLD*8
    moveq   #0, d5
    move.b  wbake_in+4, d5                 ; CRUSH (modulated)
    andi.w  #15, d5
    lsr.w   #1, d5                          ; crush: drop = CRUSH>>1 low bits (0-7)
    moveq   #0, d7                          ; DRIVE: a3 = drivetab + DRIVE*256 (modulated)
    move.b  wbake_in+3, d7
    andi.w  #15, d7
    lsl.w   #8, d7
    lea     drivetab, a3
    adda.w  d7, a3
    moveq   #0, d7                          ; WARP: d7 = pivot p = 16 + WARP (modulated)
    move.b  wbake_in+1, d7
    andi.w  #15, d7
    addi.w  #16, d7
    moveq   #0, d6                          ; d6 = output step i
    lea     wave_bake, a2
    moveq   #32-1, d4
.bkl:
    cmpi.w  #16, d6                         ; WARP: skew the source index over 0..31
    bhs.s   .bw2
    move.w  d6, d1                          ; i<16: j = (i * p) >> 4
    mulu.w  d7, d1
    lsr.w   #4, d1
    bra.s   .bwd
.bw2:
    move.w  d6, d1                          ; i>=16: j = p + ((i-16)*(32-p)) >> 4
    subi.w  #16, d1
    moveq   #32, d0
    sub.w   d7, d0
    mulu.w  d0, d1
    lsr.w   #4, d1
    add.w   d7, d1
.bwd:
    cmpi.w  #31, d1                          ; clamp j to 0..31
    bls.s   .bw3
    moveq   #31, d1
.bw3:
    moveq   #0, d0
    move.b  (a5,d1.w), d0                  ; s = base[j] (warped read)
    move.b  (a3,d0.w), d0                  ; DRIVE: tanh soft-clip (sample -> sample)
    subi.w  #128, d0                       ; d = deviation -128..127
    cmp.w   d3, d0                          ; FOLD: reflect past +/- T
    ble.s   .bf1
    move.w  d3, d1                          ; d > T -> 2T - d
    add.w   d1, d1
    sub.w   d0, d1
    move.w  d1, d0
    bra.s   .bfd
.bf1:
    move.w  d3, d1
    neg.w   d1                              ; -T
    cmp.w   d1, d0
    bge.s   .bfd
    add.w   d1, d1                          ; d < -T -> -2T - d
    sub.w   d0, d1
    move.w  d1, d0
.bfd:
    tst.w   d5                              ; CRUSH: drop low bits
    beq.s   .bcd
    asr.w   d5, d0
    lsl.w   d5, d0
.bcd:
    muls.w  d2, d0                          ; VOL: d * VOL / 16
    asr.w   #4, d0
    addi.w  #128, d0                       ; back to 0-255, clamp
    bpl.s   .bp1
    moveq   #0, d0
.bp1:
    cmpi.w  #255, d0
    bls.s   .bp2
    move.w  #255, d0
.bp2:
    move.b  d0, (a2)+
    addq.w  #1, d6                          ; next output step
    dbra    d4, .bkl
    rts

; WAVE note trigger: push the base wave + pitch increment into Z80 RAM, arm wave mode.
; a1 = WAVE instrument; reads c_note(a6). CRITICAL: the 68k cannot read its own work RAM
; while holding the Z80 bus, so the wave is read into d0-d7 BEFORE the BUSREQ and only
; written under it (mirrors dac_play, which computes from RAM before grabbing the bus).
wave_play:
    movem.l d0-d7/a2-a5, -(sp)
    moveq   #0, d0                         ; note -> phase increment (notetable + 192)
    move.b  c_note(a6), d0
    cmpi.w  #96, d0
    bhs     .wpx
    add.w   d0, d0
    lea     notetable+192, a2
    movea.w (a2,d0.w), a4                  ; a4 = increment (max ~$2140, no sign issue)
    move.w  a4, d0                          ; PITCH: increment += increment*(pitch-8)/128
    moveq   #0, d1                          ; pitch 8 = in tune; +-7 ~= +-1 semitone (proportional)
    move.b  wbake_in+5, d1
    subi.w  #8, d1
    muls.w  d1, d0
    asr.l   #7, d0
    adda.w  d0, a4
    moveq   #0, d0                         ; base wave = wave_ram + WAVE# * 32
    move.b  (iw_wave,a1), d0
    andi.w  #15, d0
    lsl.w   #5, d0
    lea     wave_ram, a5
    adda.w  d0, a5
    bsr     bake_wave                      ; run the base wave through the shaper chain -> wave_bake
    movem.l wave_bake, d0-d7               ; read the 32 baked bytes (BEFORE the BUSREQ)
    move.w  #$0100, Z80_BUSREQ
.wpw:
    btst    #0, Z80_BUSREQ
    bne.s   .wpw
    lea     Z80_RAM+$1FD0, a3             ; write d0-d7 to WV_BUF, big-endian (no work-RAM
WB      macro                              ; access under BUSREQ: rol restores the reg)
    rol.l   #8, \1
    move.b  \1, (a3)+
    rol.l   #8, \1
    move.b  \1, (a3)+
    rol.l   #8, \1
    move.b  \1, (a3)+
    rol.l   #8, \1
    move.b  \1, (a3)+
    endm
    WB      d0
    WB      d1
    WB      d2
    WB      d3
    WB      d4
    WB      d5
    WB      d6
    WB      d7
    move.l  a4, d0                         ; WV_INC (LE)
    move.b  d0, Z80_RAM+$1FCC
    lsr.w   #8, d0
    move.b  d0, Z80_RAM+$1FCD
    addq.b  #1, Z80_RAM+$1FCB             ; bump the wave trigger -> Z80 arms wave mode
    move.w  #$0000, Z80_BUSREQ
.wpx:
    movem.l (sp)+, d0-d7/a2-a5
    rts
rate_step:  dc.b 1, 2, 4, 1               ; i_rate 0..3 = 1x/2x/4x/0.5x -> window step
rate_half:  dc.b 0, 0, 0, 1               ; i_rate 3 (0.5x) feeds each byte twice
    even

; push a YM2612 write list (part,reg,value triples) once: patch + key-on
; build YM ch0's patch from instrument 0's record and push it to the Z80.
; per op (n=0..3, reg offset n*4): $30=(DT<<4)|MUL $40=TL $50=AR $60=D1R
; $70=D2R $80=(SL<<4)|RR; then $B0=(FB<<3)|ALGO, $B4=$C0 (L+R)
ym_setup:                                 ; editor/boot path: own BUSREQ, build into the mailbox, push
    move.w  #$0100, Z80_BUSREQ
.w:
    btst    #0, Z80_BUSREQ
    bne.s   .w
    move.b  #0, Z80_RAM+$1F01            ; psg_count = 0
    lea     Z80_RAM+$1F21, a2            ; build straight into the YM mailbox
    moveq   #0, d7
    bsr     ym_build_patch
    move.b  d7, Z80_RAM+$1F20            ; ym_count
    addq.b  #1, g_seq
    move.b  g_seq, Z80_RAM+$1F00
    move.w  #$0000, Z80_BUSREQ
    rts

; build F1's patch (part,reg,value triples) into (a2)+, advancing d7 by the count.
; caller sets a2 (dest) + d7 (running count). NO BUSREQ / push of its own, so it is
; safe to call both standalone (ym_setup) and mid-SCB (push_scb's repatch append).
ym_build_patch:
    lea     instrum, a3                   ; F1's instrument: its own song instrument while
    moveq   #0, d0                        ; playing, cur_instr only when editing -- so viewing
    tst.b   playing                       ; another instrument can't overwrite a playing FM voice
    beq.s   .ybcur
    move.b  ch_state+c_instr, d0          ; F1 = channel 0
    bra.s   .ybgot
.ybcur:
    move.b  cur_instr, d0
.ybgot:
    mulu.w  #INSTR_SIZE, d0
    adda.w  d0, a3
    move.b  live_algo, d0                ; effective ALGO = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .haveal
    move.b  (i_algo,a3), d0
.haveal:
    move.b  d0, eff_algo
    move.b  live_vol, d0                 ; effective VOL = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .havevl
    move.b  (i_vol,a3), d0
.havevl:
    move.b  d0, eff_vol
    move.b  live_fb, d0                  ; effective FB = transient override or stored value
    cmpi.b  #$FF, d0
    bne.s   .havefb
    move.b  (i_fb,a3), d0
.havefb:
    move.b  d0, eff_fb
    ; ($22 global LFO is no longer emitted here -- it's a per-push emit in push_scb, off any channel)
    moveq   #0, d6                        ; operator slot 0..3 (rows are in register order)
.op:                                      ; params: MUL DT TL RS AR AM D1 D2 RR SL
    move.w  d6, d5
    mulu.w  #FM_NPARM, d5
    addi.w  #i_op, d5                     ; param base = i_op + slot*10
    move.w  d6, d4
    lsl.w   #2, d4                        ; reg offset = slot*4 (S1,S3,S2,S4 = rows OP1,OP3,OP2,OP4)
    move.b  (1,a3,d5.w), d1               ; $30: (DT<<4)|MUL
    lsl.b   #4, d1
    move.b  (0,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$30, d2
    bsr     .emit
    move.b  (2,a3,d5.w), d0               ; $40: TL (+ VOL attenuation if this op is a carrier)
    moveq   #0, d1
    move.b  eff_algo, d1
    andi.w  #7, d1
    lea     carrier_mask, a4
    btst    d6, (a4,d1.w)                 ; slot d6 a carrier in this algorithm?
    beq.s   .novol
    moveq   #15, d1                       ; atten = (15 - VOL) * 8
    sub.b   eff_vol, d1
    lsl.b   #3, d1
    add.b   d1, d0
    cmpi.b  #127, d0                      ; clamp (unsigned)
    bls.s   .novol
    moveq   #127, d0
.novol:
    move.b  #$40, d2
    bsr     .emit
    move.b  (3,a3,d5.w), d1               ; $50: (RS<<6)|AR
    lsl.b   #6, d1
    move.b  (4,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$50, d2
    bsr     .emit
    move.b  (5,a3,d5.w), d1               ; $60: (AM<<7)|D1R
    lsl.b   #7, d1
    move.b  (6,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$60, d2
    bsr     .emit
    move.b  (7,a3,d5.w), d0               ; $70: D2R
    move.b  #$70, d2
    bsr     .emit
    move.b  (9,a3,d5.w), d1               ; $80: (SL<<4)|RR
    lsl.b   #4, d1
    move.b  (8,a3,d5.w), d0
    or.b    d1, d0
    move.b  #$80, d2
    bsr     .emit
    addq.w  #1, d6
    cmpi.w  #4, d6
    bne     .op
    moveq   #0, d4                        ; $B0: (FB<<3)|ALGO
    move.b  eff_fb, d1
    lsl.b   #3, d1
    move.b  eff_algo, d0
    or.b    d1, d0
    move.b  #$B0, d2
    bsr     .emit
    move.b  (i_pan,a3), d0                ; $B4: (pan<<6)|(AMS<<4)|FMS
    lsl.b   #6, d0
    move.b  (i_ams,a3), d1
    andi.b  #3, d1
    lsl.b   #4, d1
    or.b    d1, d0
    move.b  (i_fms,a3), d1
    andi.b  #7, d1
    or.b    d1, d0
    move.b  #$B4, d2
    bsr     .emit
    rts
.emit:                                    ; emit triple: part0, (d2+d4), d0
    move.b  #0, (a2)+
    move.b  d2, d1
    add.b   d4, d1
    move.b  d1, (a2)+
    move.b  d0, (a2)+
    addq.w  #1, d7
    rts

; ============================================================
z80_load:
    move.w  #$0100, Z80_BUSREQ
    move.w  #$0100, Z80_RESET
.wb:
    btst    #0, Z80_BUSREQ
    bne.s   .wb
    lea     z80_blob, a1
    lea     Z80_RAM, a2
    move.w  #z80_blob_end-z80_blob-1, d0
.zc:
    move.b  (a1)+, (a2)+
    dbra    d0, .zc
    move.w  #$0000, Z80_RESET
    move.w  #$0000, Z80_BUSREQ
    moveq   #40, d0
.zd:
    dbra    d0, .zd
    move.w  #$0100, Z80_RESET
    rts

print_at:
    moveq   #0, d0
    move.w  d3, d0
    lsl.w   #6, d0
    add.w   d4, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
.pl:
    move.b  (a1)+, d1
    beq.s   .pd
    andi.w  #$00FF, d1
    move.w  d1, VDP_DATA
    bra.s   .pl
.pd:
    rts

; like print_at but adds d2 (char offset, e.g. $60 for highlight) to each tile
print_hl:                                 ; a1=str, d3=row, d4=col, d2=char offset
    moveq   #0, d0
    move.w  d3, d0
    lsl.w   #6, d0
    add.w   d4, d0
    add.w   d0, d0
    swap    d0
    ori.l   #$40000003, d0
    move.l  d0, (a0)
.phl:
    move.b  (a1)+, d1
    beq.s   .phd
    andi.w  #$00FF, d1
    add.w   d2, d1
    move.w  d1, VDP_DATA
    bra.s   .phl
.phd:
    rts

; ============================================================
; OPTIONS / PROJECT pages (SMSGGDJ-style field lists)
; ============================================================
draw_dec3:                                ; d3=0..255, d4=char offset; (a0) addr preset
    moveq   #0, d0
    move.b  d3, d0
    divu.w  #100, d0
    move.w  d0, d1
    add.w   #'0', d1
    add.w   d4, d1
    move.w  d1, VDP_DATA
    clr.w   d0
    swap    d0
    divu.w  #10, d0
    move.w  d0, d1
    add.w   #'0', d1
    add.w   d4, d1
    move.w  d1, VDP_DATA
    clr.w   d0
    swap    d0
    add.w   #'0', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

draw_dec_s:                               ; d3=signed byte, d4=offset; addr preset -> sign + 2 digits
    move.b  d3, d0
    ext.w   d0
    ext.l   d0                              ; clean 32-bit signed (divu uses the full long)
    moveq   #'+', d1
    tst.l   d0
    bpl.s   .ds
    moveq   #'-', d1
    neg.l   d0
.ds:
    add.w   d4, d1
    move.w  d1, VDP_DATA
    divu.w  #10, d0
    move.w  d0, d1
    andi.w  #$0F, d1
    add.w   #'0', d1
    add.w   d4, d1
    move.w  d1, VDP_DATA
    clr.w   d0
    swap    d0
    add.w   #'0', d0
    add.w   d4, d0
    move.w  d0, VDP_DATA
    rts

; NB: no per-render body clear -- clear_grid wipes on entry, and these fields are
; fixed-width so they self-overwrite; clearing rows 5-16 every render overran VBlank.
render_opts:                              ; VID(0) SYNC(1) PAL(2) -- render_kit idiom
    moveq   #5, d3
    moveq   #1, d4
    lea     str_o_vid, a1
    bsr     print_at
    moveq   #0, d2
    tst.b   cur_row
    bne.s   .ov
    moveq   #$60, d2
.ov:
    moveq   #0, d1
    move.b  opt_vid, d1
    cmpi.w  #2, d1
    bls.s   .ovc
    moveq   #2, d1
.ovc:
    lsl.w   #2, d1
    lea     vid_lbl, a1
    move.l  (a1,d1.w), a1
    moveq   #5, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #6, d3
    moveq   #1, d4
    lea     str_o_sync, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #1, cur_row
    bne.s   .os
    moveq   #$60, d2
.os:
    moveq   #0, d1
    move.b  opt_sync, d1
    cmpi.w  #2, d1
    bls.s   .osc
    moveq   #2, d1
.osc:
    lsl.w   #2, d1
    lea     sync_lbl, a1
    move.l  (a1,d1.w), a1
    moveq   #6, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #7, d3
    moveq   #1, d4
    lea     str_o_pal, a1
    bsr     print_at
    move.l  #$43900003, (a0)
    move.b  opt_pal, d3
    moveq   #0, d4
    cmpi.b  #2, cur_row
    bne.s   .op
    moveq   #$60, d4
.op:
    bra     draw_hex1

render_proj:                              ; TMPO TSP MODE / NEW DEMO / SLOT / SAVE LOAD
    moveq   #5, d3
    moveq   #1, d4
    lea     str_p_tmpo, a1
    bsr     print_at
    move.l  #$42900003, (a0)
    move.b  proj_tmpo, d3
    moveq   #0, d4
    tst.b   cur_row
    bne.s   .pt
    moveq   #$60, d4
.pt:
    bsr     draw_dec3
    moveq   #6, d3
    moveq   #1, d4
    lea     str_tsp, a1
    bsr     print_at
    move.l  #$43100003, (a0)
    move.b  proj_tsp, d3
    moveq   #0, d4
    cmpi.b  #1, cur_row
    bne.s   .ps
    moveq   #$60, d4
.ps:
    bsr     draw_hex2                       ; raw byte: 01+ = up, FF- = down (like every TSP field)
    moveq   #7, d3
    moveq   #1, d4
    lea     str_mode, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #2, cur_row
    bne.s   .pm
    moveq   #$60, d2
.pm:
    moveq   #0, d1
    move.b  proj_mode, d1
    cmpi.w  #1, d1
    bls.s   .pmc
    moveq   #1, d1
.pmc:
    lsl.w   #2, d1
    lea     pmode_lbl, a1
    move.l  (a1,d1.w), a1
    moveq   #7, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #9, d3
    moveq   #1, d4
    lea     str_p_new, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #3, cur_row
    bne.s   .pn
    moveq   #$60, d2
.pn:
    lea     str_go, a1
    moveq   #9, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #11, d3
    moveq   #1, d4
    lea     str_p_demo, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #4, cur_row
    bne.s   .pd
    moveq   #$60, d2
.pd:
    lea     str_go, a1
    moveq   #11, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #13, d3
    moveq   #1, d4
    lea     str_p_slot, a1
    bsr     print_at
    move.l  #$46900003, (a0)
    move.b  proj_slot, d3
    moveq   #0, d4
    cmpi.b  #5, cur_row
    bne.s   .psl
    moveq   #$60, d4
.psl:
    bsr     draw_hex1
    moveq   #15, d3
    moveq   #1, d4
    lea     str_p_save, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #6, cur_row
    bne.s   .pv
    moveq   #$60, d2
.pv:
    lea     str_go, a1
    moveq   #15, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #16, d3
    moveq   #1, d4
    lea     str_p_load, a1
    bsr     print_at
    moveq   #0, d2
    cmpi.b  #7, cur_row
    bne.s   .pl
    moveq   #$60, d2
.pl:
    lea     str_go, a1
    moveq   #16, d3
    moveq   #8, d4
    bsr     print_hl
    moveq   #17, d3                          ; LFO: global FM LFO (0 = off, 1-8 = on at rate 0-7)
    moveq   #1, d4
    lea     str_p_lfo, a1
    bsr     print_at
    move.l  #$48900003, (a0)
    move.b  g_lfo, d3
    moveq   #0, d4
    cmpi.b  #8, cur_row
    bne.s   .plf
    moveq   #$60, d4
.plf:
    bra     draw_hex1

edit_opts:                                ; B+dpad on OPTIONS: adjust the current field
    move.b  cur_row, d0
    beq.s   .eo_vid
    cmpi.b  #1, d0
    beq.s   .eo_sync
    lea     opt_pal, a1                     ; PAL 0..7
    moveq   #7, d3
    moveq   #1, d4
    bra.s   .eo_apply
.eo_vid:
    lea     opt_vid, a1
    moveq   #2, d3
    moveq   #1, d4
    bra.s   .eo_apply
.eo_sync:
    lea     opt_sync, a1
    moveq   #2, d3
    moveq   #1, d4
.eo_apply:
    bsr     adj_field
    bsr     apply_palette                   ; re-apply UI palette (harmless for VID/SYNC)
    bsr     save_config                     ; persist OPTIONS to SRAM
    rts

; ---- 8 UI palettes: c0 background, c1 text/cursor-block, c2 cursor glyph (= bg). MD $0BGR. ----
    dc.b    "GMDJPAL0"              ; locator for the browser palette ROM-patcher (PALETTE.md §5)
pal_table:                          ; SMSGGDJ's 8 schemes (SMS 2:2:2 -> MD: 1->$4 2->$A 3->$E)
    dc.w $0E40, $00EE, $0E40        ; 0 KIDD  yellow on sky blue (default; SMSGGDJ $34/$0F)
    dc.w $0000, $0EEE, $0000        ; 1 WHT   white on black
    dc.w $0040, $00EA, $0040        ; 2 GRN   green screen
    dc.w $0000, $00AE, $0000        ; 3 AMBR  amber terminal
    dc.w $0400, $0EE0, $0400        ; 4 CYAN  cyan on navy
    dc.w $0404, $0E0E, $0404        ; 5 PINK  magenta on purple
    dc.w $0EA4, $0A0E, $0EA4        ; 6 NEON  neon pink on light blue
    dc.w $0440, $0AE4, $0440        ; 7 MINT  mint on dark teal

apply_palette:                            ; load pal_table[opt_pal] into CRAM colours 0-2
    lea     VDP_CTRL, a0
    move.l  #$C0000000, (a0)
    moveq   #0, d0
    move.b  opt_pal, d0
    mulu.w  #6, d0                          ; 3 words per palette
    lea     pal_table, a1
    adda.w  d0, a1
    move.w  (a1)+, VDP_DATA
    move.w  (a1)+, VDP_DATA
    move.w  (a1)+, VDP_DATA
    rts

; ---- config block in cart SRAM (odd-byte, $A130F1-gated). Persists the OPTIONS across power.
; Layout: byte0 magic $A5, 1 opt_pal, 2 opt_vid, 3 opt_sync (each at $200001 + i*2). ----
save_config:
    move.b  #1, $A130F1                     ; map SRAM (writable)
    lea     $200001, a1
    move.b  #$A5, (a1)
    move.b  opt_pal, (2,a1)
    move.b  opt_vid, (4,a1)
    move.b  opt_sync, (6,a1)
    move.b  #0, $A130F1                     ; unmap (protect)
    rts
load_config:
    move.b  #1, $A130F1
    lea     $200001, a1
    cmpi.b  #$A5, (a1)                       ; valid config?
    bne.s   .lcdone
    move.b  (2,a1), opt_pal
    move.b  (4,a1), opt_vid
    move.b  (6,a1), opt_sync
.lcdone:
    move.b  #0, $A130F1
    rts

edit_proj:                                ; B+dpad on PROJECT: adjust TMPO/TSP/MODE/SLOT
    move.b  cur_row, d0
    beq.s   .ep_tmpo
    cmpi.b  #1, d0
    beq     .ep_tsp
    cmpi.b  #2, d0
    beq.s   .ep_mode
    cmpi.b  #5, d0
    beq.s   .ep_slot
    cmpi.b  #8, d0
    beq.s   .ep_lfo
    rts                                     ; NEW/DEMO/SAVE/LOAD: no dpad value
.ep_mode:
    lea     proj_mode, a1
    moveq   #1, d3
    moveq   #1, d4
    bra     adj_field
.ep_slot:
    lea     proj_slot, a1
    moveq   #8, d3
    moveq   #1, d4
    bsr     adj_field
    tst.b   proj_slot                       ; clamp to [1,8]
    bne.s   .eps
    move.b  #1, proj_slot
.eps:
    rts
.ep_lfo:
    lea     g_lfo, a1                        ; global FM LFO: 0=off, 1-8 = on at rate 0-7
    moveq   #8, d3
    moveq   #1, d4
    bsr     adj_field
    move.b  #1, g_lfo_dirty                   ; re-emit $22 on the next push -> new rate heard at once
    rts
.ep_tmpo:                                 ; L/R +-1, U/D +-10, clamp [32,255]
    moveq   #0, d0
    move.b  proj_tmpo, d0
    btst    #2, d2
    beq.s   .et1
    subq.w  #1, d0
.et1:
    btst    #3, d2
    beq.s   .et2
    addq.w  #1, d0
.et2:
    btst    #0, d2
    beq.s   .et3
    addi.w  #10, d0
.et3:
    btst    #1, d2
    beq.s   .et4
    subi.w  #10, d0
.et4:
    cmpi.w  #32, d0
    bge.s   .et5
    moveq   #32, d0
.et5:
    cmpi.w  #255, d0
    ble.s   .et6
    move.w  #255, d0
.et6:
    move.b  d0, proj_tmpo
    rts
.ep_tsp:                                  ; signed-byte transpose like every other TSP: L/R +-1,
    lea     proj_tsp, a1                    ;   U/D +-octave, wrap $00<->$FF (01+ up, FF- down)
    moveq   #255, d3
    moveq   #12, d4
    bra     adj_field

proj_action:                              ; B-tap on PROJECT: trigger the GO fields
    move.b  cur_row, d0
    cmpi.b  #3, d0
    beq.s   .pa_new
    cmpi.b  #4, d0
    beq.s   .pa_demo
    rts                                     ; SAVE/LOAD stubbed until the save system (M8)
.pa_new:
    bsr     clear_song
    bra.s   .pa_done
.pa_demo:
    bsr     load_demo
.pa_done:
    move.b  #0, cur_phrase
    move.b  #0, cur_chain
    move.b  #0, cur_songrow
    move.b  #1, need_clear
    rts

load_demo:                                ; phrases -> rests, then copy demo phrases/chains/song
    lea     phrases, a2
    move.w  #16*16-1, d0
.ld_clr:
    move.b  #$FF, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    dbra    d0, .ld_clr
    lea     chains, a2                     ; chains + song (contiguous) -> empty ($FF) so untouched
    move.w  #(NCHAINS*CHAIN_SIZE)+(NSONGROWS*NCH)-1, d0   ; slots aren't read as phrase 00 / garbage
.ld_ce:
    move.b  #$FF, (a2)+
    dbra    d0, .ld_ce
    lea     demo_phrases, a1
    lea     phrases, a2
    move.w  #(demo_end-demo_phrases)-1, d0
.ld_cp:
    move.b  (a1)+, (a2)+
    dbra    d0, .ld_cp
    lea     demo_chains, a1
    lea     chains, a2
    move.w  #(demo_chains_end-demo_chains)-1, d0
.ld_cc:
    move.b  (a1)+, (a2)+
    dbra    d0, .ld_cc
    lea     demo_song, a1
    lea     song, a2
    move.w  #(demo_song_end-demo_song)-1, d0
.ld_cs:
    move.b  (a1)+, (a2)+
    dbra    d0, .ld_cs
    rts

clear_song:                               ; blank project: phrases -> rests, chains + song empty ($FF)
    lea     phrases, a2
    move.w  #16*16-1, d0
.cz_p:
    move.b  #$FF, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    move.b  #0, (a2)+
    dbra    d0, .cz_p
    lea     chains, a2
    move.w  #(song-chains)-1, d0
.cz_c:
    move.b  #$FF, (a2)+
    dbra    d0, .cz_c
    lea     song, a2
    move.w  #(NSONGROWS*10)-1, d0
.cz_s:
    move.b  #$FF, (a2)+
    dbra    d0, .cz_s
    rts

Exception:
    bra.s   Exception

; ============================================================
; data
; ============================================================
str_title:  dc.b "GENMDDJ",0
ver_str:    dc.b "V0.01",0
str_hdr_ph: dc.b "   NOTE IN CMD",0
str_hdr_ch: dc.b "   PHR TSP    ",0
str_hdr_sg: dc.b "   F1 F2 F3 F4 F5 F6 T1 T2 T3 NO",0
str_hdr_in: dc.b "              ",0
str_hdr_fm: dc.b "OP  ML DT TL RS AR AM D1 D2 RR SL",0
str_scr_ph: dc.b "PHRASE",0
str_scr_ch: dc.b "CHAIN ",0
str_scr_sg: dc.b "SONG  ",0
str_scr_in: dc.b "INSTR ",0
str_scr_fm: dc.b "FM    ",0
str_scr_echo: dc.b "ECHO",0
str_scr_lfo: dc.b "FM LFO",0
str_scr_opt:  dc.b "OPTIONS",0
str_scr_proj: dc.b "PROJECT",0
str_scr_wave: dc.b "WAVFORM",0
str_scr_grv:  dc.b "GROOVE",0
str_scr_tb: dc.b "TABLE ",0
str_hdr_tb: dc.b "   V  TSP CMD",0
    even
table_scol: dc.b 4, 7, 11, 12             ; V(1) TSP(2) CMD-letter PRM(2) -> "A00" adjacent
op_names:   dc.b "OP1OP3OP2OP4"            ; rows in YM2612 register order (S1,S3,S2,S4)
fm_scol:    dc.b 5, 8, 11, 14, 17, 20, 23, 26, 29, 32   ; 10 op-param columns
fm_pmax:    dc.b 15, 7, 127, 3, 31, 1, 31, 31, 15, 15   ; MUL DT TL RS AR AM D1 D2 RR SL
fm_pstep:   dc.b 4, 4, 16, 1, 16, 1, 16, 4, 4, 4         ; B+U/D coarse step (<= range)
    even
str_inst:   dc.b "INST",0
str_wip:    dc.b "(WIP)",0
str_type:   dc.b "TYPE",0
str_kit:    dc.b "KIT",0
str_pads:   dc.b "PADS",0
    even
kit_rate_lbl: dc.l krn_1, krn_2, krn_4, krn_h   ; i_rate 0..3 = 1x/2x/4x/0.5x
krn_h:      dc.b ".5X",0
krn_1:      dc.b "1X ",0
krn_2:      dc.b "2X ",0
krn_4:      dc.b "4X ",0
    even
; OPTIONS / PROJECT page labels + enum tables (TSP/MODE reuse the FM/PSG strings)
str_o_vid:  dc.b "VID",0
str_o_sync: dc.b "SYNC",0
str_o_pal:  dc.b "PAL",0
str_p_tmpo: dc.b "TMPO",0
str_p_new:  dc.b "NEW",0
str_p_demo: dc.b "DEMO",0
str_p_slot: dc.b "SLOT",0
str_p_lfo:  dc.b "LFO",0
str_p_save: dc.b "SAVE",0
str_p_load: dc.b "LOAD",0
str_go:     dc.b "GO",0
str_vid_n:  dc.b "NTSC",0
str_vid_p:  dc.b "PAL ",0
str_vid_a:  dc.b "AUTO",0
str_syn_o:  dc.b "OFF",0
str_syn_i:  dc.b "IN ",0
str_syn_u:  dc.b "OUT",0
str_md_s:   dc.b "SONG",0
str_md_live: dc.b "LIVE",0
    even
vid_lbl:    dc.l str_vid_n, str_vid_p, str_vid_a
sync_lbl:   dc.l str_syn_o, str_syn_i, str_syn_u
pmode_lbl:  dc.l str_md_s, str_md_live
    even
str_voice:  dc.b "VOICE:",0
str_algo:   dc.b "ALGO",0
str_fb:     dc.b "FB",0
str_pan:    dc.b "PAN",0
str_ams:    dc.b "AMS",0
str_fms:    dc.b "FMS",0
str_hld:    dc.b "HLD",0
str_vol:    dc.b "VOL",0
str_lfo:    dc.b "LFO",0
str_global: dc.b "(GLOBAL)",0
str_atk:    dc.b "ATK",0
str_dcy:    dc.b "DCY",0
str_tsp:    dc.b "TSP",0
str_swp:    dc.b "SWP",0
str_vib:    dc.b "VIB",0
str_trm:    dc.b "TRM",0
str_tbl:    dc.b "TBL",0
str_tbs:    dc.b "TBS",0
str_none:   dc.b "--",0
str_mode:   dc.b "MODE",0
str_rate:   dc.b "RATE",0
str_t_fm:   dc.b "FM",0
str_t_kit:  dc.b "KIT",0
str_t_wav:  dc.b "WAVE",0
str_t_ton:  dc.b "TONE",0
str_t_noi:  dc.b "NOISE",0
str_random: dc.b "RANDOM  ",0               ; padded so a shorter value overwrites cleanly
str_period: dc.b "PERIODIC",0
str_r512:   dc.b "512     ",0
str_r1k:    dc.b "1K      ",0
str_r2k:    dc.b "2K      ",0
str_pitch:  dc.b "PITCHED ",0
    even
type_lbl:   dc.l str_t_fm, str_t_kit, str_t_wav, str_t_ton, str_t_noi
mode_lbl:   dc.l str_random, str_period
rate_lbl:   dc.l str_r512, str_r1k, str_r2k, str_pitch
voice_lbl:  dc.l str_hld, str_vol, str_pan, str_tsp, str_algo, str_fb, str_ams, str_fms  ; 8
voice_off:  dc.b i_hld, i_vol, i_pan, i_tsp, i_algo, i_fb, i_ams, i_fms
voice_max:  dc.b 15, 15, 3, 255, 7, 7, 3, 7
voice_step: dc.b 4, 4, 1, 12, 4, 4, 1, 4                 ; channel: HLD VOL PAN TSP | FM: ALGO FB AMS FMS
voice_fmt:  dc.b 0, 0, 0, 1, 0, 0, 0, 0                  ; TSP = hex2 signed; rest hex1
    even
; PSG instrument field tables (TONE = first 10; NOISE = all 12)
psg_lbl:    dc.l str_vol, str_atk, str_hld, str_dcy, str_tsp, str_swp, str_vib, str_trm, str_tbl, str_tbs, str_mode, str_rate
psg_off:    dc.b ip_vol, ip_atk, ip_hld, ip_dcy, ip_tsp, ip_swp, ip_vib, ip_trm, i_tbl, i_tbs, ip_mode, ip_rate
psg_max:    dc.b 15, 15, 15, 15, 255, 255, 255, 255, 31, 15, 1, 3
psg_step:   dc.b 4, 4, 4, 4, 12, 16, 16, 16, 16, 4, 1, 1   ; TSP=12; SWP/VIB/TRM/TBL=16
psg_fmt:    dc.b 0, 0, 0, 0, 1, 1, 1, 1, 4, 0, 2, 3   ; 0 hex1, 1 hex2, 2 MODE, 3 RATE, 4 TBL(-- or hex2)
    even
; WAVE instrument field set (11 fields)
wave_lbl:   dc.l str_w_wave, str_vol, str_atk, str_hld, str_dcy, str_warp, str_drive, str_fold, str_crush, str_tbl, str_tbs
wave_off:   dc.b iw_wave, ip_vol, ip_atk, ip_hld, ip_dcy, iw_warp, iw_drive, iw_fold, iw_crush, i_tbl, i_tbs
wave_max:   dc.b 15, 15, 15, 15, 15, 15, 15, 15, 15, 31, 15
wave_step:  dc.b 1, 4, 4, 4, 4, 1, 1, 1, 1, 16, 4
wave_fmt:   dc.b 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0    ; all hex1 except TBL (hex2)
    even
; WAVE instrument grid: 8 rows, up to 3 columns each ($FF = empty cell). All cells are 0-15.
wgrid_srow: dc.b 6, 7, 9, 10, 11, 12, 13, 14         ; screen row per grid row (gap at 8 = header; blank 5)
wgrid_cc:   dc.b 1, 3, 3, 3, 3, 3, 3, 3             ; columns per row (for cursor clamping)
    even
wgrid_lbl:  dc.l str_w_wave, str_env, str_vol, str_warp, str_fold, str_drive, str_crush, str_w_pitch
wgrid_off:  dc.b iw_wave, $FF, $FF                  ; WAVE: base wave #
    dc.b ip_atk,  ip_hld,  ip_dcy                   ; ENV:  AHD attack / hold / decay
    dc.b ip_vol,  iwl_vr,  iwl_vd                   ; VOLUME: peak / tremolo rate / depth
    dc.b iw_warp, iwl_wr,  iwl_wd                   ; WARP:  offset / rate / depth
    dc.b iw_fold, iwl_fr,  iwl_fd                   ; FOLD
    dc.b iw_drive,iwl_dr,  iwl_dd                   ; DRIVE
    dc.b iw_crush,iwl_cr,  iwl_cd                   ; CRUSH
    dc.b iw_pitch,iwl_pr,  iwl_pd                   ; PITCH: detune / vibrato rate / depth
    even
str_env:    dc.b "ENV",0
str_w_pitch: dc.b "PITCH",0
str_grid_hdr: dc.b "OFF RAT DEP",0
    even
str_warp:   dc.b "WARP",0
str_drive:  dc.b "DRIVE",0
str_fold:   dc.b "FOLD",0
str_crush:  dc.b "CRUSH",0
    even
NVOICE     equ 8                            ; channel items (HLD VOL PAN TSP) + FM items (ALGO FB AMS FMS)
type_names: dc.b "FMKTWVTNNS"               ; 2 chars per type: FM KIT WAVE TONE NOISE
map_letters: dc.b "SCPIT"                   ; map order: SONG CHAIN PHRASE INSTR TABLE
str_play:   dc.b "PLAY",0
str_stop:   dc.b "STOP",0
hexd:       dc.b "0123456789ABCDEF"
note_names: dc.b "C-C#D-D#E-F-F#G-G#A-A#B-"
field_scol: dc.b 4, 9, 12, 13
field_boff: dc.b 0, 1, 2, 3
chain_scol: dc.b 4, 8
song_scol:  dc.b 4, 7, 10, 13, 16, 19, 22, 25, 28, 31
track_names: dc.b "F1F2F3F4F5F6T1T2T3NO"      ; 2 chars per channel
ch_config:                                      ; type, p1, p2, p3 per channel
    dc.b 1, 0, 0, 0          ; F1 = FM YM ch0
    dc.b 1, 0, 1, 1          ; F2 = FM YM ch1
    dc.b 1, 0, 2, 2          ; F3 = FM YM ch2
    dc.b 1, 1, 0, 4          ; F4 = FM YM ch3
    dc.b 1, 1, 1, 5          ; F5 = FM YM ch4
    dc.b 1, 1, 2, 6          ; F6 = FM YM ch5
    dc.b 0, $80, $90, 0      ; T1 = square PSG ch0
    dc.b 0, $A0, $B0, 0      ; T2 = square PSG ch1
    dc.b 0, $C0, $D0, 0      ; T3 = square PSG ch2
    dc.b 2, $E0, $F0, 0      ; NO = noise PSG ch3
scr_order:  dc.b SCR_SONG, SCR_CHAIN, SCR_PHRASE, SCR_INSTR, SCR_TABLE  ; map pos -> screen id
scr_pos:    dc.b 2, 1, 0, 3, $FF, 4         ; screen id -> map pos ($FF = off the row, FM)
; 2D map grid (3 rows x 5 cols): vrow*5 + hcol -> screen id ($FF = empty cell)
scr_grid:   dc.b SCR_OPTS, SCR_PROJ,   $FF, SCR_WAVE, $FF   ; row 0 (above)
            dc.b SCR_SONG, SCR_CHAIN,  SCR_PHRASE, SCR_INSTR, SCR_TABLE  ; row 1 (main)
            dc.b $FF,      SCR_GROOVE, $FF, SCR_LFO,  SCR_ECHO ; row 2 (below): LFO under INSTR, ECHO under TABLE
scr_vrow:   dc.b 1,1,1,1,1,1,2,0,0,0,2,2     ; screen id -> grid row (..GR LFO)
scr_hcol:   dc.b 2,1,0,3,3,4,4,0,1,3,1,3     ; screen id -> grid col (ECHO now col 4, LFO col 3)
scr_letter: dc.b "PCSIFTEOPWGL"             ; screen id -> map-cross letter (L = LFO)
    even
scr_tabs:                                   ; {header, name} per screen, indexed by SCR_*
    dc.l str_hdr_ph, str_scr_ph             ; 0  PHRASE
    dc.l str_hdr_ch, str_scr_ch             ; 1  CHAIN
    dc.l str_hdr_sg, str_scr_sg             ; 2  SONG
    dc.l str_hdr_in, str_scr_in             ; 3  INSTR
    dc.l str_hdr_in, str_scr_fm             ; 4  FM (vestigial)
    dc.l str_hdr_tb, str_scr_tb             ; 5  TABLE
    dc.l str_hdr_in, str_scr_echo           ; 6  ECHO
    dc.l str_hdr_in, str_scr_opt            ; 7  OPTIONS
    dc.l str_hdr_in, str_scr_proj           ; 8  PROJECT
    dc.l str_hdr_in, str_scr_wave           ; 9  WAVEFORM
    dc.l str_hdr_in, str_scr_grv            ; 10 GROOVE
    dc.l str_hdr_in, str_scr_lfo            ; 11 LFO

tri_tile:                                   ; right-pointing playhead (tile $1F)
    dc.l $00000000
    dc.l $01000000
    dc.l $01100000
    dc.l $01110000
    dc.l $01110000
    dc.l $01100000
    dc.l $01000000
    dc.l $00000000

; 4 single-note phrases (note at row 0, rests after): C-4 E-4 G-4 C-5
demo_phrases:
    dc.b 48,0,0,0            ; phrase 0  C-4
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 52,1,0,0            ; phrase 1  E-4 (instrument 1 = TONE, the PSG voice)
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 55,1,0,0            ; phrase 2  G-4 (instrument 1 = TONE)
    rept 15
    dc.b $FF,0,0,0
    endr
    dc.b 60,0,0,0            ; phrase 3  C-5
    rept 15
    dc.b $FF,0,0,0
    endr
demo_end:
    even

; chains (2 steps each so the chain playhead has somewhere to move):
; each step = (phrase#, transpose); $FF phrase# = end-of-chain
demo_chains:
    dc.b 0,0, 3,0          ; chain 0: C-4 then C-5
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 1,0, 2,0          ; chain 1: E-4 then G-4
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 2,0, 1,0          ; chain 2: G-4 then E-4
    dcb.b CHAIN_SIZE-4, $FF
    dc.b 3,0, 0,0          ; chain 3: C-5 then C-4
    dcb.b CHAIN_SIZE-4, $FF
demo_chains_end:
    even

; song: chain# per track (F1 F2 F3 F4 F5 F6 T1 T2 T3 NO); $FF = empty/inactive
; demo plays F1 (FM) + T1 + T2 (square); the rest are silent
demo_song:
    dc.b 0,   $FF,$FF,$FF,$FF,$FF,  1,   2,   $FF, $FF   ; row 0
    dc.b 3,   $FF,$FF,$FF,$FF,$FF,  2,   1,   $FF, $FF   ; row 1
    dcb.b (NSONGROWS-2)*NCH, $FF
demo_song_end:
    even

; M6-A FM test: a minimal patch on YM channel 1 + key-on.
; triples: part(0=ch1-3), reg, value. algorithm 7 (all ops are carriers),
; op1 loud, ops 2-4 muted -> a single sine-ish FM voice.
; default FM voice (instrument 0): algo 7 (all carriers), op1 loud, op2-4 muted
default_fm:                        ; YM2612 grand-piano test patch (Sega manual)
    dc.b 0, 2, 6, 3, 0,0,15,15     ; type, algo=2, fb=6, pan(L+R), ams, fms, HLD=hold, VOL=full
    dc.b 1, 7, 35, 1,31,0,5,2,1,1  ; slot0 S1: MUL DT TL RS AR AM D1 D2 RR SL ($30=71..$80=11)
    dc.b 13,0, 45, 2,25,0,5,2,1,1  ; slot1 S3 ($34=0D..$84=11)
    dc.b 3, 3, 38, 1,31,0,5,2,1,1  ; slot2 S2 ($38=33..$88=11)
    dc.b 1, 0, 0,  2,20,0,7,2,6,10 ; slot3 S4 carrier ($3C=01..$8C=A6)
    dc.b $FF, 1                    ; i_tbl(none) i_tbs (offsets 48/49)
    dcb.b 14, 0                    ; offsets 50-63 reserved
    even

default_tone:                      ; a basic TONE (PSG square) instrument
    dc.b 3                          ; i_type = TONE
    dc.b 0,0,0,0,0,0,0              ; offsets 1-7 (FM voice bytes, unused by PSG)
    dc.b $F, 0, $F, 3              ; ip_vol ip_atk ip_hld ip_dcy (full, instant atk, sustain, decay on release)
    dc.b 0, 0, 0, 0                ; ip_tsp ip_swp ip_vib ip_trm
    dc.b 0, 0, 1, 0                ; (offsets 16/17 unused) ip_mode(periodic) ip_rate
    dcb.b 28, 0                    ; offsets 20-47 unused
    dc.b $FF, 1                    ; i_tbl(none) i_tbs (offsets 48/49)
    dcb.b 14, 0                    ; offsets 50-63 reserved
    even

; carrier slots per algorithm (bit d6 set = record slot d6 is a carrier, in S1,S3,S2,S4
; register order). VOL attenuates only carriers so it scales output without retiming/timbre.
carrier_mask:
    dc.b $08,$08,$08,$08,$0C,$0E,$0E,$0F
    even

; macro tables: NTABLE tables x TBL_ROWS rows x TROW bytes (vol, arp, cmd, prm).
; vol $FF = "no change". Table 0 is a demo major arpeggio; the rest are empty.
psg_tables:
    dc.b $FF,0,0,0,  $FF,4,0,0,  $FF,7,0,0,  $FF,0,0,0
    dc.b $FF,4,0,0,  $FF,7,0,0,  $FF,0,0,0,  $FF,4,0,0
    dc.b $FF,7,0,0,  $FF,0,0,0,  $FF,4,0,0,  $FF,7,0,0
    dc.b $FF,0,0,0,  $FF,4,0,0,  $FF,7,0,0,  $FF,0,0,0
    rept (NTABLE-1)*TBL_ROWS       ; tables 1-31: empty rows (no change)
    dc.b $FF, 0, 0, 0
    endr
    even

; YM2612 F-numbers for one octave (C..B); block = note/12 selects the octave
fm_fnum:
    dc.w 644, 682, 723, 766, 811, 859, 910, 965, 1022, 1083, 1147, 1215
    even

vdp_regs:
    dc.b $04, $74, $30, $3C, $07, $6C, $00, $00
    dc.b $00, $00, $00, $00, $81, $34, $00, $02
    dc.b $01, $00, $00, $FF, $FF, $00, $00, $80
vdp_regs_end:
    even

notetable:
    incbin "build/notes.bin"             ; 96 periods + 96 wave increments + 16x256 DRIVE
drivetab equ notetable+384               ; WAVE DRIVE table: drivetab + DRIVE*256 + sample
    even
z80_blob:
    incbin "build/driver.z80.bin"
z80_blob_end:
    even
    include "build/gitver.i"             ; git_hash_str (build stamp)
    even
splash_tiles:
    incbin "build/splash_tiles.bin"
splash_map:
    incbin "build/splash_map.bin"
    even
algo_tiles:
    incbin "build/algo_tiles.bin"
algo_maps:
    incbin "build/algo_maps.bin"
    even
    dc.b    "GMDJFON0"              ; locator for the browser font ROM-patcher (PALETTE.md §7)
font_data:
    incbin "build/font.bin"
font_end:
    even

; WAVE-screen tiles (MD 4bpp, colour 1) -> loaded at tile $E0. Lines sit near the inner
; edges with a 1px gap to the canvas content (1px interior padding on the box border).
wave_tiles:
    dc.l 0,0,0,0,0,0,0,$11111111                 ; $E0 centre line  (pixel row 7, the very bottom)
    dc.l 0,0,0,0,0,0,$11111111,0                  ; $E1 top edge     (pixel row 6)
    dc.l 0,$11111111,0,0,0,0,0,0                   ; $E2 bottom edge  (pixel row 1)
    dc.l $10,$10,$10,$10,$10,$10,$10,$10           ; $E3 left edge    (pixel col 6)
    dc.l $01000000,$01000000,$01000000,$01000000,$01000000,$01000000,$01000000,$01000000 ; $E4 right edge (col 1)
    dc.l 0,0,0,0,0,0,$11,$10                       ; $E5 top-left corner
    dc.l 0,0,0,0,0,0,$11000000,$01000000           ; $E6 top-right corner
    dc.l $10,$11,0,0,0,0,0,0                        ; $E7 bottom-left corner
    dc.l $01000000,$11000000,0,0,0,0,0,0           ; $E8 bottom-right corner

; AMP live bar: 8 height tiles ($E9..$F0), a 4px-wide column filling from the bottom (1..8px)
bar_tiles:
    dc.l 0,0,0,0,0,0,0,$00111100
    dc.l 0,0,0,0,0,0,$00111100,$00111100
    dc.l 0,0,0,0,0,$00111100,$00111100,$00111100
    dc.l 0,0,0,0,$00111100,$00111100,$00111100,$00111100
    dc.l 0,0,0,$00111100,$00111100,$00111100,$00111100,$00111100
    dc.l 0,0,$00111100,$00111100,$00111100,$00111100,$00111100,$00111100
    dc.l 0,$00111100,$00111100,$00111100,$00111100,$00111100,$00111100,$00111100
    dc.l $00111100,$00111100,$00111100,$00111100,$00111100,$00111100,$00111100,$00111100

sample_pool:                              ; kit directory (8x16 members) + 8-bit PCM (makesamples.py)
    incbin "build/samples.bin"
    even

    dcb.b ROM_SIZE-*, $FF                  ; pad to the full ROM (errors if pool overflows it)
ROM_END:
