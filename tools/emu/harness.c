/* Headless libretro screenshotter.
 *
 *   retroshot <core.dylib> <rom.bin> <out.ppm> [frames]
 *
 * Loads a libretro core, runs the ROM for N frames (default 120), and writes
 * the last video frame as a binary PPM (P6). A reusable, permission-free way to
 * see what a Mega Drive ROM actually renders.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include "libretro.h"

static unsigned g_fmt = RETRO_PIXEL_FORMAT_0RGB1555;
static unsigned g_w = 0, g_h = 0;
static uint8_t  g_fb[1024 * 512 * 4];

/* audio capture (interleaved stereo int16) */
#define AUD_MAX (48000 * 2 * 30)
static int16_t g_aud[AUD_MAX];
static size_t  g_aud_n = 0;
static void aud_push(int16_t l, int16_t r) {
    if (g_aud_n + 2 <= AUD_MAX) { g_aud[g_aud_n++] = l; g_aud[g_aud_n++] = r; }
}

static bool env_cb(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        g_fmt = *(const enum retro_pixel_format *)data; return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = "/tmp"; return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *(bool *)data = true; return true;
    default:
        return false;
    }
}
static void video_cb(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data) return;                 /* duped frame: keep previous */
    g_w = w; g_h = h;
    size_t bpp = (g_fmt == RETRO_PIXEL_FORMAT_XRGB8888) ? 4 : 2;
    if ((uint64_t)w * h * bpp > sizeof(g_fb)) return;
    for (unsigned y = 0; y < h; y++)
        memcpy(g_fb + y * w * bpp, (const uint8_t *)data + y * pitch, w * bpp);
}
static unsigned g_buttons = 0;     /* RetroPad id bitmask to hold (for input tests) */
static void  input_poll_cb(void) {}
static int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port == 0 && (device & 0xFF) == RETRO_DEVICE_JOYPAD) {
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)g_buttons;  /* bitmask query */
        if (id < 16) return (g_buttons >> id) & 1;
    }
    return 0;
}
static void  audio_cb(int16_t l, int16_t r) { aud_push(l, r); }
static size_t audio_batch_cb(const int16_t *d, size_t f) {
    for (size_t i = 0; i < f; i++) aud_push(d[2 * i], d[2 * i + 1]);
    return f;
}

static void write_wav(const char *base, unsigned rate) {
    char path[1200];
    snprintf(path, sizeof path, "%s.wav", base);
    FILE *o = fopen(path, "wb");
    if (!o) return;
    uint32_t data_bytes = (uint32_t)(g_aud_n * sizeof(int16_t));
    uint32_t byterate = rate * 2 * 2;
    uint32_t chunk = 36 + data_bytes;
    fwrite("RIFF", 1, 4, o); fwrite(&chunk, 4, 1, o); fwrite("WAVE", 1, 4, o);
    fwrite("fmt ", 1, 4, o);
    uint32_t sub1 = 16; uint16_t fmt = 1, ch = 2, bps = 16, align = 4;
    fwrite(&sub1, 4, 1, o); fwrite(&fmt, 2, 1, o); fwrite(&ch, 2, 1, o);
    fwrite(&rate, 4, 1, o); fwrite(&byterate, 4, 1, o);
    fwrite(&align, 2, 1, o); fwrite(&bps, 2, 1, o);
    fwrite("data", 1, 4, o); fwrite(&data_bytes, 4, 1, o);
    fwrite(g_aud, 1, data_bytes, o);
    fclose(o);
}

#define SYM(n) do { *(void **)(&n) = dlsym(core, #n); \
    if (!n) { fprintf(stderr, "missing symbol %s\n", #n); return 2; } } while (0)

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: retroshot core rom out.ppm [frames] [btnmask_hex]\n"); return 1; }
    int frames = argc > 4 ? atoi(argv[4]) : 120;
    const char *btn = argc > 5 ? argv[5] : NULL;
    int scripted = btn && strchr(btn, '@');   /* input script: "maskHex@frames,maskHex@frames,..." */
    if (btn && !scripted) g_buttons = (unsigned)strtoul(btn, NULL, 16);

    void *core = dlopen(argv[1], RTLD_NOW);
    if (!core) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }

    void (*retro_set_environment)(retro_environment_t);
    void (*retro_set_video_refresh)(retro_video_refresh_t);
    void (*retro_set_input_poll)(retro_input_poll_t);
    void (*retro_set_input_state)(retro_input_state_t);
    void (*retro_set_audio_sample)(retro_audio_sample_t);
    void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*retro_init)(void);
    bool (*retro_load_game)(const struct retro_game_info *);
    void (*retro_run)(void);
    void (*retro_get_system_av_info)(struct retro_system_av_info *);
    void (*retro_set_controller_port_device)(unsigned, unsigned);
    void *(*retro_get_memory_data)(unsigned);
    size_t (*retro_get_memory_size)(unsigned);
    SYM(retro_set_environment); SYM(retro_set_video_refresh);
    SYM(retro_set_input_poll);  SYM(retro_set_input_state);
    SYM(retro_set_audio_sample); SYM(retro_set_audio_sample_batch);
    SYM(retro_init); SYM(retro_load_game); SYM(retro_run);
    SYM(retro_get_system_av_info); SYM(retro_set_controller_port_device);
    SYM(retro_get_memory_data); SYM(retro_get_memory_size);

    retro_set_environment(env_cb);
    retro_set_video_refresh(video_cb);
    retro_set_input_poll(input_poll_cb);
    retro_set_input_state(input_state_cb);
    retro_set_audio_sample(audio_cb);
    retro_set_audio_sample_batch(audio_batch_cb);
    retro_init();

    FILE *f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[2]); return 3; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    void *buf = malloc(sz);
    if (fread(buf, 1, sz, f) != (size_t)sz) { fprintf(stderr, "read fail\n"); return 3; }
    fclose(f);

    struct retro_game_info gi = {0};
    gi.path = argv[2]; gi.data = buf; gi.size = sz;
    if (!retro_load_game(&gi)) { fprintf(stderr, "retro_load_game failed\n"); return 4; }
    /* optional controller device override: GENMDDJ_DEV=<hex> (e.g. 101) */
    const char *dev = getenv("GENMDDJ_DEV");
    if (dev) retro_set_controller_port_device(0, (unsigned)strtoul(dev, NULL, 16));

    /* optional SRAM restore: RETROSHOT_SRAM=<path> is loaded into the core's
       SAVE_RAM after load_game (the core allocates it during load). The printed
       buffer size tells us how the core sized SRAM (odd-byte packed vs linear). */
    {
        void  *sram   = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
        size_t sramsz = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
        const char *srampath = getenv("RETROSHOT_SRAM");
        fprintf(stderr, "SRAM: core buffer = %zu bytes\n", sramsz);
        if (srampath && sram && sramsz) {
            FILE *sf = fopen(srampath, "rb");
            if (sf) {
                size_t n = fread(sram, 1, sramsz, sf);
                fclose(sf);
                fprintf(stderr, "SRAM: loaded %zu bytes from %s\n", n, srampath);
            } else fprintf(stderr, "SRAM: cannot open %s\n", srampath);
        }
    }

    struct retro_system_av_info av; memset(&av, 0, sizeof av);
    retro_get_system_av_info(&av);
    unsigned arate = (unsigned)(av.timing.sample_rate ? av.timing.sample_rate : 44100);

    if (scripted) {                             /* run "maskHex@frames,..." steps in order */
        char sc[2048];
        strncpy(sc, btn, sizeof sc - 1); sc[sizeof sc - 1] = 0;
        char *save = NULL, *tok = strtok_r(sc, ",", &save);
        while (tok) {
            char *at = strchr(tok, '@');
            g_buttons = (unsigned)strtoul(tok, NULL, 16);   /* strtoul stops at '@' */
            int nf = at ? atoi(at + 1) : 1;
            for (int i = 0; i < nf; i++) retro_run();
            tok = strtok_r(NULL, ",", &save);
        }
    } else {
        for (int i = 0; i < frames; i++) retro_run();
    }

    write_wav(argv[3], arate);                  /* <out>.wav alongside the ppm */
    fprintf(stderr, "audio: %zu samples @ %u Hz -> %s.wav\n", g_aud_n / 2, arate, argv[3]);

    /* optional SRAM dump: RETROSHOT_SRAM_OUT=<path> writes SAVE_RAM after the run */
    {
        const char *outp = getenv("RETROSHOT_SRAM_OUT");
        void  *sram   = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
        size_t sramsz = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
        if (outp && sram && sramsz) {
            FILE *of = fopen(outp, "wb");
            if (of) { fwrite(sram, 1, sramsz, of); fclose(of);
                fprintf(stderr, "SRAM: dumped %zu bytes to %s\n", sramsz, outp); }
        }
    }

    if (!g_w || !g_h) { fprintf(stderr, "no frame captured\n"); return 5; }
    FILE *o = fopen(argv[3], "wb");
    fprintf(o, "P6\n%u %u\n255\n", g_w, g_h);
    for (unsigned i = 0; i < g_w * g_h; i++) {
        uint8_t r, g, b;
        if (g_fmt == RETRO_PIXEL_FORMAT_XRGB8888) {
            uint32_t p = ((uint32_t *)g_fb)[i];
            r = (p >> 16) & 0xFF; g = (p >> 8) & 0xFF; b = p & 0xFF;
        } else if (g_fmt == RETRO_PIXEL_FORMAT_RGB565) {
            uint16_t p = ((uint16_t *)g_fb)[i];
            r = ((p >> 11) & 0x1F) << 3; g = ((p >> 5) & 0x3F) << 2; b = (p & 0x1F) << 3;
        } else { /* 0RGB1555 */
            uint16_t p = ((uint16_t *)g_fb)[i];
            r = ((p >> 10) & 0x1F) << 3; g = ((p >> 5) & 0x1F) << 3; b = (p & 0x1F) << 3;
        }
        fputc(r, o); fputc(g, o); fputc(b, o);
    }
    fclose(o);
    fprintf(stderr, "retroshot: %ux%u fmt=%u, %d frames\n", g_w, g_h, g_fmt, frames);
    return 0;
}
