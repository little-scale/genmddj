/* GENMDDJ .gmdj player and offline renderer.
 *
 * Wraps one extracted song in the ROM's real SRAM directory format, asks the ROM
 * to auto-load it through a private config marker, and captures the libretro
 * core's authentic stereo output. Stem export repeats the deterministic render
 * with one hardware voice enabled at a time.
 */
#include <errno.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dlfcn.h>

#include "../../tools/emu/libretro.h"

#define GMDJ_HEADER 32u
#define DATA_SIZE   23904u
#define SRAM_LEAD   1u
#define DIR_SIG     8u
#define CONFIG_OFS  16u
#define DIR_BASE    2304u
#define HEAP_BASE   2816u
#define VOICE_MASK_ALL 0x03ffu

static const char *const voice_names[10] = {
    "F1", "F2", "F3", "F4", "F5", "F6-DAC", "T1", "T2", "T3", "NO"
};

struct song_file {
    uint8_t *file;
    size_t size;
    const uint8_t *data;
    char title[9];
};

struct wav_out {
    FILE *file;
    uint64_t frames;
    int failed;
};

struct audio_resampler {
    struct wav_out *wav;
    unsigned input_rate;
    unsigned output_rate;
    uint64_t input_index;
    uint64_t next_output_index;
    int16_t previous_left;
    int16_t previous_right;
    int have_previous;
};

static struct audio_resampler *active_resampler;
static enum retro_pixel_format pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static const char *ym2612_core = "mame (ym2612)";

static int regular_file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static void default_repo_path(char *out, size_t out_size, const char *argv0,
                              const char *from_root, const char *from_player) {
    snprintf(out, out_size, "%s", from_root);
    if (regular_file_exists(out)) return;

    const char *slash = strrchr(argv0, '/');
    if (!slash) return;
    size_t directory_length = (size_t)(slash - argv0);
    snprintf(out, out_size, "%.*s/%s", (int)directory_length, argv0, from_player);
}

static void put_u16le(FILE *f, uint16_t v) {
    uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)};
    fwrite(b, 1, sizeof b, f);
}

static void put_u32le(FILE *f, uint32_t v) {
    uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
    fwrite(b, 1, sizeof b, f);
}

static int wav_open(struct wav_out *w, const char *path, unsigned rate) {
    memset(w, 0, sizeof *w);
    w->file = fopen(path, "wb");
    if (!w->file) {
        fprintf(stderr, "cannot create %s: %s\n", path, strerror(errno));
        return 0;
    }
    fwrite("RIFF", 1, 4, w->file); put_u32le(w->file, 0);
    fwrite("WAVEfmt ", 1, 8, w->file); put_u32le(w->file, 16);
    put_u16le(w->file, 1); put_u16le(w->file, 2);
    put_u32le(w->file, rate); put_u32le(w->file, rate * 4u);
    put_u16le(w->file, 4); put_u16le(w->file, 16);
    fwrite("data", 1, 4, w->file); put_u32le(w->file, 0);
    if (ferror(w->file)) {
        fclose(w->file); w->file = NULL;
        fprintf(stderr, "cannot write WAV header to %s\n", path);
        return 0;
    }
    return 1;
}

static int wav_close(struct wav_out *w) {
    uint64_t bytes64 = w->frames * 4u;
    if (bytes64 > UINT32_MAX) {
        fprintf(stderr, "render exceeds the 4 GB RIFF/WAV limit\n");
        w->failed = 1;
    }
    uint32_t bytes = (uint32_t)bytes64;
    if (!w->failed) {
        if (fseek(w->file, 4, SEEK_SET) != 0) w->failed = 1;
        else put_u32le(w->file, 36u + bytes);
        if (fseek(w->file, 40, SEEK_SET) != 0) w->failed = 1;
        else put_u32le(w->file, bytes);
    }
    if (fclose(w->file) != 0) w->failed = 1;
    w->file = NULL;
    return !w->failed;
}

static void write_sample_pair(int16_t left, int16_t right) {
    struct wav_out *active_wav = active_resampler ? active_resampler->wav : NULL;
    if (!active_wav || active_wav->failed) return;
    uint8_t b[4] = {
        (uint8_t)left, (uint8_t)((uint16_t)left >> 8),
        (uint8_t)right, (uint8_t)((uint16_t)right >> 8)
    };
    if (fwrite(b, 1, sizeof b, active_wav->file) != sizeof b) active_wav->failed = 1;
    else active_wav->frames++;
}

/* Streaming linear interpolation on an exact rational clock. Genesis Plus GX
 * supplies the emulated mix at its native frontend rate (normally 44.1 kHz);
 * this changes only the delivered WAV clock, never the emulated console clocks.
 */
static void resampler_push(int16_t left, int16_t right) {
    struct audio_resampler *r = active_resampler;
    if (!r || !r->wav || r->wav->failed) return;
    if (!r->have_previous) {
        r->previous_left = left;
        r->previous_right = right;
        r->have_previous = 1;
        r->input_index = 0;
        r->next_output_index = 1;
        write_sample_pair(left, right);
        return;
    }

    r->input_index++;
    uint64_t interval_start = (r->input_index - 1) * (uint64_t)r->output_rate;
    uint64_t interval_end = r->input_index * (uint64_t)r->output_rate;
    while (r->next_output_index * (uint64_t)r->input_rate <= interval_end) {
        uint64_t position = r->next_output_index * (uint64_t)r->input_rate - interval_start;
        int64_t dl = (int64_t)left - r->previous_left;
        int64_t dr = (int64_t)right - r->previous_right;
        int32_t out_left = r->previous_left + (int32_t)((dl * (int64_t)position + r->output_rate / 2) / r->output_rate);
        int32_t out_right = r->previous_right + (int32_t)((dr * (int64_t)position + r->output_rate / 2) / r->output_rate);
        write_sample_pair((int16_t)out_left, (int16_t)out_right);
        r->next_output_index++;
    }
    r->previous_left = left;
    r->previous_right = right;
}

static void audio_sample_cb(int16_t left, int16_t right) {
    resampler_push(left, right);
}

static size_t audio_batch_cb(const int16_t *data, size_t frames) {
    for (size_t i = 0; i < frames; i++) resampler_push(data[i * 2], data[i * 2 + 1]);
    return frames;
}

static bool environment_cb(unsigned cmd, void *data) {
    static const char *tmp = "/tmp";
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        pixel_format = *(const enum retro_pixel_format *)data;
        (void)pixel_format;
        return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = tmp;
        return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *(bool *)data = true;
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *variable = data;
        if (!strcmp(variable->key, "genesis_plus_gx_ym2612")) {
            variable->value = ym2612_core;
            return true;
        }
        return false;
    }
    default:
        return false;
    }
}

static void video_cb(const void *data, unsigned width, unsigned height, size_t pitch) {
    (void)data; (void)width; (void)height; (void)pitch;
}
static void input_poll_cb(void) {}
static int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)port; (void)device; (void)index; (void)id;
    return 0;
}

static uint8_t *read_entire_file(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long end = ftell(f);
    if (end < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    uint8_t *p = malloc((size_t)end ? (size_t)end : 1u);
    if (!p || fread(p, 1, (size_t)end, f) != (size_t)end) {
        fprintf(stderr, "cannot read %s\n", path);
        free(p); fclose(f); return NULL;
    }
    fclose(f);
    *size = (size_t)end;
    return p;
}

static int load_song(const char *path, struct song_file *song) {
    memset(song, 0, sizeof *song);
    song->file = read_entire_file(path, &song->size);
    if (!song->file) return 0;
    if (song->size != GMDJ_HEADER + DATA_SIZE || memcmp(song->file, "GMDJSONG", 8) != 0) {
        fprintf(stderr, "%s is not a 23,904-byte GENMDDJ song container\n", path);
        return 0;
    }
    unsigned version = song->file[8];
    unsigned declared = ((unsigned)song->file[10] << 8) | song->file[11];
    if (version != 1 || declared != DATA_SIZE) {
        fprintf(stderr, "%s uses unsupported .gmdj version/size (%u/%u)\n", path, version, declared);
        return 0;
    }
    memcpy(song->title, song->file + 12, 8);
    song->title[8] = 0;
    for (int i = 7; i >= 0 && (song->title[i] == ' ' || song->title[i] == 0); i--) song->title[i] = 0;
    song->data = song->file + GMDJ_HEADER;
    return 1;
}

static uint16_t song_checksum(const uint8_t *data) {
    uint32_t sum = 0;
    for (size_t i = 0; i < DATA_SIZE; i++) sum += data[i];
    return (uint16_t)sum;
}

static int populate_sram(uint8_t *sram, size_t size, const struct song_file *song, uint16_t mask) {
    if (size < SRAM_LEAD + HEAP_BASE + DATA_SIZE) {
        fprintf(stderr, "emulator SRAM buffer is too small (%zu bytes)\n", size);
        return 0;
    }
    memset(sram, 0xff, size);
    memcpy(sram + SRAM_LEAD + DIR_SIG, "GMD1", 4);

    uint8_t *config = sram + SRAM_LEAD + CONFIG_OFS;
    config[0] = 0xa5; config[1] = 0; config[2] = 2; config[3] = 0;
    config[4] = 0; config[5] = 1; config[6] = 0x5a; config[7] = 2; config[8] = 0xc3;
    memcpy(config + 9, "PLY1", 4);
    config[13] = (uint8_t)(mask >> 8);
    config[14] = (uint8_t)mask;

    uint8_t *entry = sram + SRAM_LEAD + DIR_BASE;
    uint16_t checksum = song_checksum(song->data);
    entry[0] = 0xa5; entry[1] = 1;                 /* valid, raw */
    entry[2] = 0; entry[3] = 0;                   /* heap offset */
    entry[4] = (uint8_t)(DATA_SIZE >> 8);
    entry[5] = (uint8_t)DATA_SIZE;
    memcpy(entry + 6, song->file + 12, 8);
    entry[14] = (uint8_t)(checksum >> 8);
    entry[15] = (uint8_t)checksum;
    memcpy(sram + SRAM_LEAD + HEAP_BASE, song->data, DATA_SIZE);
    return 1;
}

static int ensure_directory(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        if (S_ISDIR(st.st_mode)) return 1;
        fprintf(stderr, "stem output path is not a directory: %s\n", path);
        return 0;
    }
    if (mkdir(path, 0777) == 0) return 1;
    fprintf(stderr, "cannot create stem directory %s: %s\n", path, strerror(errno));
    return 0;
}

static char *default_output_name(const char *input) {
    size_t n = strlen(input);
    char *out = malloc(n + 5);
    if (!out) return NULL;
    memcpy(out, input, n + 1);
    char *slash = strrchr(out, '/');
    char *dot = strrchr(slash ? slash + 1 : out, '.');
    if (dot && strcmp(dot, ".gmdj") == 0) *dot = 0;
    strcat(out, ".wav");
    return out;
}

static char *stem_path(const char *dir, const char *voice) {
    size_t n = strlen(dir) + strlen(voice) + 6;
    char *p = malloc(n);
    if (p) snprintf(p, n, "%s/%s.wav", dir, voice);
    return p;
}

static void usage(FILE *f, const char *argv0) {
    fprintf(f,
        "usage: %s [options] song.gmdj\n"
        "  -o, --output FILE   render the original stereo mix (default: song.wav)\n"
        "      --stems DIR     also render F1..NO hardware-voice stereo stems\n"
        "  -s, --seconds N     render duration in seconds (default: 30)\n"
        "      --rom FILE      GENMDDJ ROM (default: build/genmddj.bin)\n"
        "      --core FILE     libretro core (default: tools/emu/genesis_plus_gx_libretro.dylib)\n"
        "      --ym2612 CORE   FM core: mame or nuked (default: mame)\n"
        "  -r, --sample-rate HZ output rate: 44100, 48000, or 96000 (default: 44100)\n"
        "      --validate      validate and describe the song without emulating it\n", argv0);
}

int main(int argc, char **argv) {
    char default_rom[4096], default_core[4096];
    default_repo_path(default_rom, sizeof default_rom, argv[0],
                      "build/genmddj.bin", "../../build/genmddj.bin");
    default_repo_path(default_core, sizeof default_core, argv[0],
                      "tools/emu/genesis_plus_gx_libretro.dylib",
                      "../../tools/emu/genesis_plus_gx_libretro.dylib");
    const char *rom_path = default_rom;
    const char *core_path = default_core;
    const char *output_path = NULL, *stems_dir = NULL;
    double seconds = 30.0;
    unsigned output_rate = 44100;
    int validate_only = 0, option_index = 0;
    static const struct option options[] = {
        {"output", required_argument, 0, 'o'}, {"stems", required_argument, 0, 1000},
        {"seconds", required_argument, 0, 's'}, {"rom", required_argument, 0, 1001},
        {"core", required_argument, 0, 1002}, {"validate", no_argument, 0, 1003},
        {"ym2612", required_argument, 0, 1004},
        {"sample-rate", required_argument, 0, 'r'},
        {"help", no_argument, 0, 'h'}, {0, 0, 0, 0}
    };
    int c;
    while ((c = getopt_long(argc, argv, "o:s:r:h", options, &option_index)) != -1) {
        switch (c) {
        case 'o': output_path = optarg; break;
        case 's': {
            char *end = NULL; seconds = strtod(optarg, &end);
            if (!end || *end || seconds <= 0.0 || seconds > 86400.0) {
                fprintf(stderr, "invalid render duration: %s\n", optarg); return 1;
            }
            break;
        }
        case 'r': {
            char *end = NULL;
            unsigned long rate = strtoul(optarg, &end, 10);
            if (!end || *end || (rate != 44100 && rate != 48000 && rate != 96000)) {
                fprintf(stderr, "unsupported sample rate: %s (use 44100, 48000, or 96000)\n", optarg);
                return 1;
            }
            output_rate = (unsigned)rate;
            break;
        }
        case 'h': usage(stdout, argv[0]); return 0;
        case 1000: stems_dir = optarg; break;
        case 1001: rom_path = optarg; break;
        case 1002: core_path = optarg; break;
        case 1003: validate_only = 1; break;
        case 1004:
            if (!strcmp(optarg, "mame")) ym2612_core = "mame (ym2612)";
            else if (!strcmp(optarg, "nuked")) ym2612_core = "nuked (ym2612)";
            else { fprintf(stderr, "invalid YM2612 core: %s (use mame or nuked)\n", optarg); return 1; }
            break;
        default: usage(stderr, argv[0]); return 1;
        }
    }
    if (optind + 1 != argc) { usage(stderr, argv[0]); return 1; }
    const char *song_path = argv[optind];
    struct song_file song;
    if (!load_song(song_path, &song)) { free(song.file); return 2; }
    if (validate_only) {
        printf("valid GENMDDJ song: title=\"%s\", version=1, data=%u bytes, checksum=%04X\n",
               song.title[0] ? song.title : "SONG", DATA_SIZE, song_checksum(song.data));
        free(song.file); return 0;
    }

    char *owned_output = NULL;
    if (!output_path && !stems_dir) {
        output_path = owned_output = default_output_name(song_path);
        if (!output_path) {
            fprintf(stderr, "out of memory while creating the output filename\n");
            free(song.file); return 3;
        }
    }
    if ((output_path && !*output_path) || (stems_dir && !ensure_directory(stems_dir))) {
        free(owned_output); free(song.file); return 3;
    }

    size_t rom_size = 0;
    uint8_t *rom = read_entire_file(rom_path, &rom_size);
    if (!rom) { free(owned_output); free(song.file); return 3; }
    void *core = dlopen(core_path, RTLD_NOW);
    if (!core) {
        fprintf(stderr, "cannot load emulator core %s: %s\n", core_path, dlerror());
        free(rom); free(owned_output); free(song.file); return 3;
    }

    void (*retro_set_environment)(retro_environment_t);
    void (*retro_set_video_refresh)(retro_video_refresh_t);
    void (*retro_set_input_poll)(retro_input_poll_t);
    void (*retro_set_input_state)(retro_input_state_t);
    void (*retro_set_audio_sample)(retro_audio_sample_t);
    void (*retro_set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*retro_init)(void);
    void (*retro_deinit)(void);
    bool (*retro_load_game)(const struct retro_game_info *);
    void (*retro_unload_game)(void);
    void (*retro_run)(void);
    void (*retro_reset)(void);
    void (*retro_get_system_av_info)(struct retro_system_av_info *);
    void *(*retro_get_memory_data)(unsigned);
    size_t (*retro_get_memory_size)(unsigned);
#define LOAD_SYM(name) do { *(void **)(&(name)) = dlsym(core, #name); \
    if (!(name)) { fprintf(stderr, "emulator core is missing %s\n", #name); goto core_fail; } \
    } while (0)
    LOAD_SYM(retro_set_environment); LOAD_SYM(retro_set_video_refresh);
    LOAD_SYM(retro_set_input_poll); LOAD_SYM(retro_set_input_state);
    LOAD_SYM(retro_set_audio_sample); LOAD_SYM(retro_set_audio_sample_batch);
    LOAD_SYM(retro_init); LOAD_SYM(retro_deinit); LOAD_SYM(retro_load_game);
    LOAD_SYM(retro_unload_game); LOAD_SYM(retro_run); LOAD_SYM(retro_reset);
    LOAD_SYM(retro_get_system_av_info); LOAD_SYM(retro_get_memory_data);
    LOAD_SYM(retro_get_memory_size);
#undef LOAD_SYM

    retro_set_environment(environment_cb);
    retro_set_video_refresh(video_cb);
    retro_set_input_poll(input_poll_cb);
    retro_set_input_state(input_state_cb);
    retro_set_audio_sample(audio_sample_cb);
    retro_set_audio_sample_batch(audio_batch_cb);
    retro_init();
    struct retro_game_info game = {0};
    game.path = rom_path; game.data = rom; game.size = rom_size;
    if (!retro_load_game(&game)) { fprintf(stderr, "emulator rejected %s\n", rom_path); retro_deinit(); goto core_fail; }

    uint8_t *sram = retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t sram_size = retro_get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!sram || !sram_size) {
        fprintf(stderr, "emulator core did not expose cartridge SRAM\n");
        retro_unload_game(); retro_deinit(); goto core_fail;
    }
    struct retro_system_av_info av = {0};
    retro_get_system_av_info(&av);
    unsigned input_rate = (unsigned)(av.timing.sample_rate + 0.5);
    double fps = av.timing.fps;
    if (!input_rate || fps <= 1.0) {
        fprintf(stderr, "emulator reported invalid audio/video timing\n");
        retro_unload_game(); retro_deinit(); goto core_fail;
    }
    unsigned long frames = (unsigned long)(seconds * fps + 0.999999);
    int pass = 0, ok = 1;
    printf("emulation: YM2612=%s, PSG=Genesis Plus GX SN76496, stereo %u Hz -> %u Hz\n",
           ym2612_core, input_rate, output_rate);

#define RENDER_FILE(path_, mask_) do { \
        if (!populate_sram(sram, sram_size, &song, (mask_))) { ok = 0; break; } \
        if (pass++) retro_reset(); \
        struct wav_out wav; \
        struct audio_resampler resampler = {0}; \
        if (!wav_open(&wav, (path_), output_rate)) { ok = 0; break; } \
        resampler.wav = &wav; resampler.input_rate = input_rate; resampler.output_rate = output_rate; \
        active_resampler = &resampler; \
        for (unsigned long frame = 0; frame < frames && !wav.failed; frame++) retro_run(); \
        active_resampler = NULL; \
        if (!wav_close(&wav)) { fprintf(stderr, "failed while writing %s\n", (path_)); ok = 0; break; } \
        printf("rendered %s: %.2f s, %llu stereo frames @ %u Hz\n", \
               (path_), seconds, (unsigned long long)wav.frames, output_rate); \
    } while (0)

    if (output_path) RENDER_FILE(output_path, VOICE_MASK_ALL);
    if (ok && stems_dir) {
        for (int i = 0; i < 10 && ok; i++) {
            char *path = stem_path(stems_dir, voice_names[i]);
            if (!path) { ok = 0; break; }
            RENDER_FILE(path, (uint16_t)(1u << i));
            free(path);
        }
    }
#undef RENDER_FILE

    retro_unload_game(); retro_deinit(); dlclose(core);
    free(rom); free(owned_output); free(song.file);
    return ok ? 0 : 4;

core_fail:
    dlclose(core); free(rom); free(owned_output); free(song.file);
    return 4;
}
