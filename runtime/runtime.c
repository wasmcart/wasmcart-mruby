/*
 * runtime.c — the wyvern engine core: a DragonRuby-style Ruby runtime as a
 * wasmcart cart. Game developers never touch this file — they take the
 * prebuilt wyvern.wasm and write Ruby in app/ (like DragonRuby's own closed
 * C core, except this one is open and 700 lines).
 *
 * Embeds the mruby VM (vendor/mruby, cross-built with emscripten) and runs a
 * game written against DragonRuby GTK idioms: `def tick args`,
 * `args.outputs.solids/sprites/labels/lines/sounds`, `args.inputs`,
 * `args.state`, bottom-left-origin 1280x720 coordinates, 60 ticks/second.
 * The Ruby layer (app/prelude.rb) defines that surface; the game
 * (app/main.rb) ships as SOURCE inside the .wasc and is parsed at boot.
 *
 * Renderer: solids/borders/lines + PNG sprites (stb_image; spritesheet
 * source rects, flips, rotation, tint, alpha) + 5x7 bitfont labels (upper
 * AND lower case). Audio: the official wc_pcm_mixer (WAV assets from the
 * cart zip, 16 voices) plus generated square-wave beeps through the same
 * mixer. Gamepad-first: buttons AND analog sticks reach Ruby.
 *
 * NOT DragonRuby: the official engine is proprietary; this is an
 * independent, tiny look-alike surface on the open wasmcart contract.
 */
#include "wasmcart.h"
#include "wc_cart.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#include "stb_image.h"

#define WC_PCM_MIXER_IMPLEMENTATION
#include "wc_pcm_mixer.h"

#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/array.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

/* the DragonRuby-style Ruby surface, embedded at build time (prelude.inc is
 * generated from prelude.rb by build.sh) — games ship ONLY their own Ruby.
 * An app/prelude.rb asset, if present, overrides it (a hacking hook). */
#include "prelude.inc" 

#define DEFAULT_WIDTH  1280
#define DEFAULT_HEIGHT 720
#define MAX_WIDTH  1280
#define MAX_HEIGHT 720
#define AUDIO_CAP 4096

WC_CART_BUFFERS;

WC_DETERMINISTIC_RNG

/* named state the harness reads by name — mirrored from Ruby on demand */
static uint32_t dbg_tick;
static int32_t  dbg_score;
static int32_t  dbg_aux;
static uint32_t dbg_ruby_ok = 1;

WC_DEBUG_FIELDS(
    WC_DBG("tick_count", dbg_tick,    WC_DBG_U32),
    WC_DBG("score",      dbg_score,   WC_DBG_I32),
    WC_DBG("aux",        dbg_aux,     WC_DBG_I32),
    WC_DBG("ruby_ok",    dbg_ruby_ok, WC_DBG_U32)
)

#define MARK_BOOT 1
#define MARK_RUBY_EXCEPTION 9

static mrb_state *mrb;
static uint32_t tick_n;
static uint32_t bg_color = 0x00000000;

/* cart "SRAM": 64 u32 slots (256 bytes), declared via save_ptr/save_size so
 * hosts persist it (.sav next to the cart in wasmcart-play; harness reads it
 * via wasm({op:'save'})). Ruby reaches it through Wyvern.save_u32/load_u32. */
#define SAVE_SLOTS 64
static uint32_t wc_save[SAVE_SLOTS];

/* ── raster helpers (bottom-left origin, like DragonRuby) ──────────── */

/* Current raster destination. NULL = the cart framebuffer (XRGB u32).
 * Non-NULL = a render target's RGBA8 buffer (row 0 = top, like a PNG, so
 * targets can be sampled by draw_sprite unchanged). */
static uint8_t *rt_buf = NULL;
static int rt_w, rt_h;

static inline int dest_w(void) { return rt_buf ? rt_w : DEFAULT_WIDTH; }
static inline int dest_h(void) { return rt_buf ? rt_h : DEFAULT_HEIGHT; }

static inline void blend_px(int x, int y_bl, uint32_t rgb, int a) {
    if (a <= 0 || x < 0 || x >= dest_w() || y_bl < 0 || y_bl >= dest_h()) return;
    if (rt_buf) {
        uint8_t *p = &rt_buf[((rt_h - 1 - y_bl) * rt_w + x) * 4];
        uint32_t sr = (rgb >> 16) & 0xFF, sg = (rgb >> 8) & 0xFF, sb = rgb & 0xFF;
        uint32_t da = p[3];
        /* source-over composite, alpha accumulates */
        uint32_t oa = a + da * (255 - a) / 255;
        if (oa == 0) return;
        p[0] = (uint8_t)((sr * a + p[0] * da * (255 - a) / 255) / oa);
        p[1] = (uint8_t)((sg * a + p[1] * da * (255 - a) / 255) / oa);
        p[2] = (uint8_t)((sb * a + p[2] * da * (255 - a) / 255) / oa);
        p[3] = (uint8_t)oa;
        return;
    }
    uint32_t *p = &wc_framebuffer[(DEFAULT_HEIGHT - 1 - y_bl) * DEFAULT_WIDTH + x];
    if (a >= 255) { *p = rgb; return; }
    uint32_t d = *p;
    uint32_t r = (((rgb >> 16) & 0xFF) * a + ((d >> 16) & 0xFF) * (255 - a)) / 255;
    uint32_t g = (((rgb >> 8) & 0xFF) * a + ((d >> 8) & 0xFF) * (255 - a)) / 255;
    uint32_t b = ((rgb & 0xFF) * a + (d & 0xFF) * (255 - a)) / 255;
    *p = (r << 16) | (g << 8) | b;
}

static inline void px(int x, int y_bl, uint32_t c) {
    blend_px(x, y_bl, c, 255);
}

static void fill_rect(int x, int y, int w, int h, uint32_t c, int a) {
    if (a <= 0) return;
    int x0 = x < 0 ? 0 : x, y0 = y < 0 ? 0 : y;
    int x1 = x + w > dest_w() ? dest_w() : x + w;
    int y1 = y + h > dest_h() ? dest_h() : y + h;
    if (a >= 255 && !rt_buf) {
        for (int yy = y0; yy < y1; yy++) {
            uint32_t *row = &wc_framebuffer[(DEFAULT_HEIGHT - 1 - yy) * DEFAULT_WIDTH];
            for (int xx = x0; xx < x1; xx++) row[xx] = c;
        }
        return;
    }
    for (int yy = y0; yy < y1; yy++)
        for (int xx = x0; xx < x1; xx++) blend_px(xx, yy, c, a);
}

static void border_rect(int x, int y, int w, int h, uint32_t c, int a) {
    fill_rect(x, y, w, 2, c, a);
    fill_rect(x, y + h - 2, w, 2, c, a);
    fill_rect(x, y, 2, h, c, a);
    fill_rect(x + w - 2, y, 2, h, c, a);
}

static void draw_line(int x0, int y0, int x1, int y1, uint32_t c, int a) {
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    for (;;) {
        blend_px(x0, y0, c, a);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

/* ── sprite cache: PNG assets decoded once, drawn many ─────────────── */

#define MAX_SPRITES 64
typedef struct {
    char path[160];
    uint8_t *rgba;   /* stb output: R,G,B,A byte order */
    int w, h;
    int active;
} sprite_t;
static sprite_t sprites[MAX_SPRITES];

static sprite_t *sprite_get(const char *path) {
    for (int i = 0; i < MAX_SPRITES; i++)
        if (sprites[i].active && strcmp(sprites[i].path, path) == 0) return &sprites[i];
    /* load */
    int slot = -1;
    for (int i = 0; i < MAX_SPRITES; i++) if (!sprites[i].active) { slot = i; break; }
    if (slot < 0) return NULL;
    int size = wc_asset_size(path, (unsigned int)strlen(path));
    if (size <= 0) {
        char line[200];
        snprintf(line, sizeof line, "sprite asset not found: %s", path);
        wc_log(line, (unsigned int)strlen(line));
        return NULL;
    }
    unsigned char *buf = malloc((size_t)size);
    if (!buf) return NULL;
    wc_load_asset(path, (unsigned int)strlen(path), buf, (unsigned int)size);
    int w, h, comp;
    uint8_t *pixels = stbi_load_from_memory(buf, size, &w, &h, &comp, 4);
    free(buf);
    if (!pixels) {
        char line[200];
        snprintf(line, sizeof line, "sprite decode failed: %s (%s)", path, stbi_failure_reason());
        wc_log(line, (unsigned int)strlen(line));
        return NULL;
    }
    sprite_t *s = &sprites[slot];
    snprintf(s->path, sizeof s->path, "%s", path);
    s->rgba = pixels; s->w = w; s->h = h; s->active = 1;
    return s;
}

/* Draw a sprite: dest rect (bottom-left origin), optional source rect
 * (spritesheet tile, TOP-left origin within the image like DragonRuby),
 * flips, rotation about the dest center (degrees, CCW), tint + alpha. */
static void draw_sprite(sprite_t *s, int dx, int dy, int dw, int dh,
                        int sx, int sy, int sw, int sh,
                        int flip_h, int flip_v, double angle_deg,
                        int tr, int tg, int tb, int ta) {
    if (!s || dw <= 0 || dh <= 0) return;
    if (sw <= 0) { sx = 0; sw = s->w; }
    if (sh <= 0) { sy = 0; sh = s->h; }

    double rad = angle_deg * (3.14159265358979323846 / 180.0);
    double cs = cos(rad), sn = sin(rad);
    double cxd = dx + dw / 2.0, cyd = dy + dh / 2.0;

    /* AABB of the (possibly rotated) dest rect */
    int pad = (angle_deg == 0.0) ? 0 : (int)(fabs(dw * cs) + fabs(dh * sn)) / 2 + 2;
    int x0 = angle_deg == 0.0 ? dx : (int)(cxd - (fabs(dw * cs) + fabs(dh * sn)) / 2) - 2;
    int y0 = angle_deg == 0.0 ? dy : (int)(cyd - (fabs(dw * sn) + fabs(dh * cs)) / 2) - 2;
    int x1 = angle_deg == 0.0 ? dx + dw : x0 + 2 * ((int)(cxd - x0)) + 4;
    int y1 = angle_deg == 0.0 ? dy + dh : y0 + 2 * ((int)(cyd - y0)) + 4;
    (void)pad;

    for (int yy = y0; yy < y1; yy++) {
        for (int xx = x0; xx < x1; xx++) {
            double lx = xx + 0.5 - cxd, ly = yy + 0.5 - cyd;
            double ux, uy;
            if (angle_deg == 0.0) { ux = lx; uy = ly; }
            else { ux = lx * cs + ly * sn; uy = -lx * sn + ly * cs; } /* inverse rotate */
            double fx = (ux + dw / 2.0) / dw;   /* 0..1 across dest */
            double fy = (uy + dh / 2.0) / dh;
            if (fx < 0 || fx >= 1 || fy < 0 || fy >= 1) continue;
            if (flip_h) fx = 1.0 - fx - 1e-9;
            if (flip_v) fy = 1.0 - fy - 1e-9;
            /* dest y grows UP; image rows grow DOWN — fy 0 = dest bottom = image bottom row of the tile */
            int ix = sx + (int)(fx * sw);
            int iy = sy + (sh - 1) - (int)(fy * sh);
            if (ix < 0 || ix >= s->w || iy < 0 || iy >= s->h) continue;
            const uint8_t *p = &s->rgba[(iy * s->w + ix) * 4];
            int a = (p[3] * ta) / 255;
            if (a <= 0) continue;
            uint32_t rgb = (((uint32_t)(p[0] * tr / 255)) << 16)
                         | (((uint32_t)(p[1] * tg / 255)) << 8)
                         |  ((uint32_t)(p[2] * tb / 255));
            blend_px(xx, yy, rgb, a);
        }
    }
}

/* ── 5x7 bitfont: A-Z a-z 0-9 space - . ! : > ───────────────────────── */
static const uint8_t FONT[68][7] = {
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0E},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11},
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C},
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F},
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x19,0x15,0x13,0x11,0x11,0x11},
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10},
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04},
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04},
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F},
    /* 26: digits */
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
    {0x0E,0x11,0x01,0x06,0x08,0x10,0x1F},{0x0E,0x11,0x01,0x06,0x01,0x11,0x0E},
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
    /* 36: space - . ! : > */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00},{0x00,0x00,0x00,0x1F,0x00,0x00,0x00},
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},{0x04,0x04,0x04,0x04,0x04,0x00,0x04},
    {0x00,0x0C,0x0C,0x00,0x0C,0x0C,0x00},{0x00,0x04,0x02,0x1F,0x02,0x04,0x00},
    /* 42: lowercase a-z */
    {0x00,0x00,0x0E,0x01,0x0F,0x11,0x0F},{0x10,0x10,0x1E,0x11,0x11,0x11,0x1E},
    {0x00,0x00,0x0F,0x10,0x10,0x10,0x0F},{0x01,0x01,0x0F,0x11,0x11,0x11,0x0F},
    {0x00,0x00,0x0E,0x11,0x1F,0x10,0x0E},{0x06,0x09,0x08,0x1C,0x08,0x08,0x08},
    {0x00,0x0F,0x11,0x11,0x0F,0x01,0x0E},{0x10,0x10,0x1E,0x11,0x11,0x11,0x11},
    {0x04,0x00,0x0C,0x04,0x04,0x04,0x0E},{0x02,0x00,0x06,0x02,0x02,0x12,0x0C},
    {0x10,0x10,0x12,0x14,0x18,0x14,0x12},{0x0C,0x04,0x04,0x04,0x04,0x04,0x0E},
    {0x00,0x00,0x1A,0x15,0x15,0x15,0x15},{0x00,0x00,0x1E,0x11,0x11,0x11,0x11},
    {0x00,0x00,0x0E,0x11,0x11,0x11,0x0E},{0x00,0x00,0x1E,0x11,0x1E,0x10,0x10},
    {0x00,0x00,0x0F,0x11,0x0F,0x01,0x01},{0x00,0x00,0x16,0x19,0x10,0x10,0x10},
    {0x00,0x00,0x0F,0x10,0x0E,0x01,0x1E},{0x08,0x08,0x1C,0x08,0x08,0x09,0x06},
    {0x00,0x00,0x11,0x11,0x11,0x13,0x0D},{0x00,0x00,0x11,0x11,0x11,0x0A,0x04},
    {0x00,0x00,0x11,0x11,0x15,0x15,0x0A},{0x00,0x00,0x11,0x0A,0x04,0x0A,0x11},
    {0x00,0x00,0x11,0x11,0x0F,0x01,0x0E},{0x00,0x00,0x1F,0x02,0x04,0x08,0x1F},
};

static int glyph_index(char ch) {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return 42 + (ch - 'a');
    if (ch >= '0' && ch <= '9') return 26 + (ch - '0');
    switch (ch) {
        case ' ': return 36; case '-': return 37; case '.': return 38;
        case '!': return 39; case ':': return 40; case '>': return 41;
    }
    return 36;
}

static void draw_label(int x, int y_top, const char *s, int scale, uint32_t c) {
    if (scale < 1) scale = 1;
    int cx = x;
    for (; *s; s++) {
        const uint8_t *g = FONT[glyph_index(*s)];
        for (int row = 0; row < 7; row++)
            for (int col = 0; col < 5; col++)
                if (g[row] & (0x10 >> col))
                    fill_rect(cx + col * scale, y_top - (row + 1) * scale, scale, scale, c, 255);
        cx += 6 * scale;
    }
}

/* ── sound cache: WAV assets + generated beeps, all through the mixer ─ */

#define MAX_SOUND_PATHS 32
typedef struct { char path[160]; int id; } sound_entry_t;
static sound_entry_t sound_paths[MAX_SOUND_PATHS];
static int sound_path_count;

static int sound_get(const char *path) {
    for (int i = 0; i < sound_path_count; i++)
        if (strcmp(sound_paths[i].path, path) == 0) return sound_paths[i].id;
    if (sound_path_count >= MAX_SOUND_PATHS) return -1;
    int size = wc_asset_size(path, (unsigned int)strlen(path));
    if (size <= 0) {
        char line[200];
        snprintf(line, sizeof line, "sound asset not found: %s", path);
        wc_log(line, (unsigned int)strlen(line));
        return -1;
    }
    unsigned char *buf = malloc((size_t)size);
    if (!buf) return -1;
    wc_load_asset(path, (unsigned int)strlen(path), buf, (unsigned int)size);
    int id = wc_mixer_load_wav(buf, size);
    free(buf);
    sound_entry_t *e = &sound_paths[sound_path_count++];
    snprintf(e->path, sizeof e->path, "%s", path);
    e->id = id;
    return id;
}

#define MAX_BEEPS 8
static struct { int freq; int id; } beeps[MAX_BEEPS];
static int beep_count;

static int beep_get(int freq) {
    for (int i = 0; i < beep_count; i++) if (beeps[i].freq == freq) return beeps[i].id;
    if (beep_count >= MAX_BEEPS) return beeps[0].id;
    /* 200ms decaying square at `freq`, mono 48k */
    int frames = 48000 / 5;
    int16_t *pcm = malloc(sizeof(int16_t) * frames);
    if (!pcm) return -1;
    float phase = 0;
    for (int i = 0; i < frames; i++) {
        float env = 1.0f - (float)i / frames;
        pcm[i] = (int16_t)((phase < 0.5f ? 6000 : -6000) * env);
        phase += (float)freq / 48000.0f;
        if (phase >= 1.0f) phase -= 1.0f;
    }
    int id = wc_mixer_load_raw(pcm, frames, 1, 48000);
    free(pcm);
    beeps[beep_count].freq = freq;
    beeps[beep_count].id = id;
    beep_count++;
    return id;
}

static int run_source(const char *name); /* fwd: used by the require bridge */

/* ── Ruby → C bridges (module Wyvern) ───────────────────────────────── */

static uint32_t rgb(mrb_int r, mrb_int g, mrb_int b) {
    return (((uint32_t)r & 0xFF) << 16) | (((uint32_t)g & 0xFF) << 8) | ((uint32_t)b & 0xFF);
}

static mrb_value wy_clear(mrb_state *m, mrb_value self) {
    mrb_int r, g, b;
    mrb_get_args(m, "iii", &r, &g, &b);
    bg_color = rgb(r, g, b);
    return mrb_nil_value();
}

static mrb_value wy_solid(mrb_state *m, mrb_value self) {
    mrb_int x, y, w, h, r, g, b, a;
    mrb_get_args(m, "iiiiiiii", &x, &y, &w, &h, &r, &g, &b, &a);
    fill_rect((int)x, (int)y, (int)w, (int)h, rgb(r, g, b), (int)a);
    return mrb_nil_value();
}

static mrb_value wy_border(mrb_state *m, mrb_value self) {
    mrb_int x, y, w, h, r, g, b, a;
    mrb_get_args(m, "iiiiiiii", &x, &y, &w, &h, &r, &g, &b, &a);
    border_rect((int)x, (int)y, (int)w, (int)h, rgb(r, g, b), (int)a);
    return mrb_nil_value();
}

static mrb_value wy_line(mrb_state *m, mrb_value self) {
    mrb_int x, y, x2, y2, r, g, b, a;
    mrb_get_args(m, "iiiiiiii", &x, &y, &x2, &y2, &r, &g, &b, &a);
    draw_line((int)x, (int)y, (int)x2, (int)y2, rgb(r, g, b), (int)a);
    return mrb_nil_value();
}

static mrb_value wy_sprite(mrb_state *m, mrb_value self) {
    mrb_int x, y, w, h, sx, sy, sw, sh, fh, fv, tr, tg, tb, ta;
    mrb_float angle;
    const char *path; mrb_int plen;
    mrb_get_args(m, "iiiis!fiiiiiiiiii", &x, &y, &w, &h, &path, &plen, &angle,
                 &sx, &sy, &sw, &sh, &fh, &fv, &tr, &tg, &tb, &ta);
    if (!path) return mrb_nil_value();
    char buf[160];
    mrb_int n = plen < 159 ? plen : 159;
    memcpy(buf, path, n); buf[n] = 0;
    sprite_t *s = sprite_get(buf);
    if (s) draw_sprite(s, (int)x, (int)y, (int)w, (int)h, (int)sx, (int)sy, (int)sw, (int)sh,
                       (int)fh, (int)fv, (double)angle, (int)tr, (int)tg, (int)tb, (int)ta);
    else fill_rect((int)x, (int)y, (int)w, (int)h, 0x00FF00FF, 255); /* missing-asset magenta */
    return mrb_nil_value();
}

static mrb_value wy_label(mrb_state *m, mrb_value self) {
    mrb_int x, y, scale, r, g, b;
    const char *s; mrb_int slen;
    mrb_get_args(m, "iis!iiii", &x, &y, &s, &slen, &scale, &r, &g, &b);
    if (s) {
        char buf[128];
        mrb_int n = slen < 127 ? slen : 127;
        memcpy(buf, s, n); buf[n] = 0;
        draw_label((int)x, (int)y, buf, (int)scale, rgb(r, g, b));
    }
    return mrb_nil_value();
}

static mrb_value wy_log(mrb_state *m, mrb_value self) {
    const char *s; mrb_int slen;
    mrb_get_args(m, "s", &s, &slen);
    wc_log(s, (unsigned int)slen);
    return mrb_nil_value();
}

static mrb_value wy_mark(mrb_state *m, mrb_value self) {
    mrb_int id;
    mrb_get_args(m, "i", &id);
    wc_debug_mark((uint32_t)id);
    return mrb_nil_value();
}

static mrb_value wy_beep(mrb_state *m, mrb_value self) {
    mrb_int freq, frames;
    mrb_get_args(m, "ii", &freq, &frames);
    (void)frames; /* envelope is baked into the generated sample */
    int id = beep_get((int)freq);
    if (id >= 0) wc_mixer_play(id, 0.8f, 0);
    return mrb_nil_value();
}

static mrb_value wy_sound(mrb_state *m, mrb_value self) {
    const char *path; mrb_int plen;
    mrb_float gain;
    mrb_int loop;
    mrb_get_args(m, "s!fi", &path, &plen, &gain, &loop);
    if (!path) return mrb_int_value(m, -1);
    char buf[160];
    mrb_int n = plen < 159 ? plen : 159;
    memcpy(buf, path, n); buf[n] = 0;
    int id = sound_get(buf);
    if (id >= 0) return mrb_int_value(m, wc_mixer_play(id, (float)gain, (int)loop));
    return mrb_int_value(m, -1);
}

static mrb_value wy_sound_stop(mrb_state *m, mrb_value self) {
    mrb_int channel;
    mrb_get_args(m, "i", &channel);
    wc_mixer_stop((int)channel);
    return mrb_nil_value();
}

static mrb_value wy_save_u32(mrb_state *m, mrb_value self) {
    mrb_int slot, value;
    mrb_get_args(m, "ii", &slot, &value);
    if (slot >= 0 && slot < SAVE_SLOTS) wc_save[slot] = (uint32_t)value;
    return mrb_nil_value();
}

static mrb_value wy_load_u32(mrb_state *m, mrb_value self) {
    mrb_int slot;
    mrb_get_args(m, "i", &slot);
    return mrb_int_value(m, (slot >= 0 && slot < SAVE_SLOTS) ? (mrb_int)wc_save[slot] : 0);
}

/* render target: find-or-create an "@rt:name" sprite entry backed by an RGBA
 * buffer and aim the rasterizer at it (empty name = back to the framebuffer).
 * Cleared to transparent on begin — a target re-renders when shoveled and
 * keeps its last pixels when not. */
static mrb_value wy_set_target(mrb_state *m, mrb_value self) {
    const char *name; mrb_int nlen, w, h;
    mrb_get_args(m, "sii", &name, &nlen, &w, &h);
    if (nlen == 0) { rt_buf = NULL; return mrb_nil_value(); }
    char key[160];
    snprintf(key, sizeof key, "@rt:%.*s", (int)(nlen < 150 ? nlen : 150), name);
    if (w < 1) w = DEFAULT_WIDTH;
    if (h < 1) h = DEFAULT_HEIGHT;
    if (w > 2048) w = 2048;
    if (h > 2048) h = 2048;
    sprite_t *s = NULL;
    for (int i = 0; i < MAX_SPRITES; i++)
        if (sprites[i].active && strcmp(sprites[i].path, key) == 0) { s = &sprites[i]; break; }
    if (s && (s->w != (int)w || s->h != (int)h)) { free(s->rgba); s->rgba = NULL; s->w = (int)w; s->h = (int)h; }
    if (!s) {
        for (int i = 0; i < MAX_SPRITES; i++) if (!sprites[i].active) { s = &sprites[i]; break; }
        if (!s) return mrb_nil_value();
        snprintf(s->path, sizeof s->path, "%s", key);
        s->w = (int)w; s->h = (int)h; s->rgba = NULL; s->active = 1;
    }
    if (!s->rgba) s->rgba = malloc((size_t)s->w * s->h * 4);
    if (!s->rgba) { s->active = 0; return mrb_nil_value(); }
    memset(s->rgba, 0, (size_t)s->w * s->h * 4);
    rt_buf = s->rgba; rt_w = s->w; rt_h = s->h;
    return mrb_nil_value();
}

static mrb_value wy_sound_gain(mrb_state *m, mrb_value self) {
    mrb_int channel; mrb_float gain;
    mrb_get_args(m, "if", &channel, &gain);
    wc_mixer_set_volume((int)channel, (float)gain);
    return mrb_nil_value();
}

static mrb_value wy_sound_playing(mrb_state *m, mrb_value self) {
    mrb_int channel;
    mrb_get_args(m, "i", &channel);
    return mrb_bool_value(wc_mixer_is_playing((int)channel));
}

/* load another .rb asset (the prelude's `require` — multi-file games) */
static mrb_value wy_load_script(mrb_state *m, mrb_value self) {
    const char *path; mrb_int plen;
    mrb_get_args(m, "s", &path, &plen);
    char buf[160];
    mrb_int n = plen < 159 ? plen : 159;
    memcpy(buf, path, n); buf[n] = 0;
    return mrb_bool_value(run_source(buf) == 0);
}

static mrb_value wy_debug_set(mrb_state *m, mrb_value self) {
    mrb_int slot, value;
    mrb_get_args(m, "ii", &slot, &value);
    if (slot == 0) dbg_score = (int32_t)value;
    else if (slot == 1) dbg_aux = (int32_t)value;
    return mrb_nil_value();
}

/* ── mruby boot ─────────────────────────────────────────────────────── */

static char *load_asset_text(const char *name) {
    int size = wc_asset_size(name, (unsigned int)strlen(name));
    if (size < 0) return NULL;
    char *buf = malloc((size_t)size + 1);
    if (!buf) return NULL;
    int got = wc_load_asset(name, (unsigned int)strlen(name), buf, (unsigned int)size);
    if (got < 0) { free(buf); return NULL; }
    buf[got] = 0;
    return buf;
}

static int ruby_guard(const char *what) {
    if (!mrb->exc) return 0;
    mrb_value msg = mrb_funcall(mrb, mrb_obj_value(mrb->exc), "inspect", 0);
    char line[256];
    snprintf(line, sizeof line, "ruby exception in %s: %s", what,
             mrb_string_p(msg) ? RSTRING_PTR(msg) : "(unprintable)");
    wc_log(line, (unsigned int)strlen(line));
    wc_debug_mark(MARK_RUBY_EXCEPTION);
    mrb->exc = NULL;
    dbg_ruby_ok = 0;
    return 1;
}

static int run_source(const char *name) {
    char *src = load_asset_text(name);
    if (!src) {
        char line[128];
        snprintf(line, sizeof line, "missing asset: %s", name);
        wc_log(line, (unsigned int)strlen(line));
        dbg_ruby_ok = 0;
        return -1;
    }
    mrb_load_nstring(mrb, src, strlen(src));
    free(src);
    return ruby_guard(name) ? -1 : 0;
}

WC_EXPORT wc_info_t *wc_get_info(void) {
    WC_FILL_INFO(WC_FLAG_DEBUG | WC_FLAG_DETERMINISTIC);
    wc_info.audio_sample_rate = 48000; /* the mixer's fixed output rate */
    wc_info.save_ptr  = (uint32_t)(uintptr_t)wc_save;
    wc_info.save_size = sizeof(wc_save);
    return &wc_info;
}

WC_EXPORT_INIT void wc_init(void) {
    WC_LOG("wyvern: mruby boot");
    wc_debug_mark(MARK_BOOT);
    wc_mixer_init();
    mrb = mrb_open();
    if (!mrb) { WC_LOG("wyvern: mrb_open failed"); dbg_ruby_ok = 0; return; }

    struct RClass *wc = mrb_define_module(mrb, "WC");
    mrb_define_module_function(mrb, wc, "clear_bg",   wy_clear,      MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, wc, "solid",      wy_solid,      MRB_ARGS_REQ(8));
    mrb_define_module_function(mrb, wc, "border",     wy_border,     MRB_ARGS_REQ(8));
    mrb_define_module_function(mrb, wc, "line",       wy_line,       MRB_ARGS_REQ(8));
    mrb_define_module_function(mrb, wc, "sprite",     wy_sprite,     MRB_ARGS_REQ(17));
    mrb_define_module_function(mrb, wc, "label",      wy_label,      MRB_ARGS_REQ(7));
    mrb_define_module_function(mrb, wc, "log",        wy_log,        MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, wc, "mark",       wy_mark,       MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, wc, "beep",       wy_beep,       MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, wc, "sound",      wy_sound,      MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, wc, "sound_stop", wy_sound_stop, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, wc, "debug_set",  wy_debug_set,  MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, wc, "save_u32",   wy_save_u32,   MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, wc, "load_script", wy_load_script, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, wc, "set_target",  wy_set_target,  MRB_ARGS_REQ(3));
    mrb_define_module_function(mrb, wc, "sound_gain",  wy_sound_gain,  MRB_ARGS_REQ(2));
    mrb_define_module_function(mrb, wc, "sound_playing", wy_sound_playing, MRB_ARGS_REQ(1));
    mrb_define_module_function(mrb, wc, "load_u32",   wy_load_u32,   MRB_ARGS_REQ(1));

    if (wc_host_info.flags & WC_HOST_FLAG_DETERMINISTIC) {
        mrb_funcall(mrb, mrb_top_self(mrb), "srand", 1, mrb_int_value(mrb, (mrb_int)wc_rng_state));
        ruby_guard("srand");
    }

    int prelude_ok;
    if (wc_asset_size("prelude.rb", 10) > 0) {
        prelude_ok = run_source("prelude.rb") == 0;
    } else {
        mrb_load_nstring(mrb, (const char *)WY_PRELUDE, WY_PRELUDE_LEN);
        prelude_ok = !ruby_guard("prelude(embedded)");
    }
    if (prelude_ok) run_source("main.rb");
}

WC_EXPORT_RENDER void wc_render(void) {
    for (int i = 0; i < DEFAULT_WIDTH * DEFAULT_HEIGHT; i++) wc_framebuffer[i] = bg_color;

    if (mrb && dbg_ruby_ok) {
        /* all four pads: buttons + both sticks each (controller_one..four) */
        mrb_value argv[20];
        for (int p = 0; p < 4; p++) {
            wc_pad_t *pd = &wc_pads[p];
            argv[p * 5 + 0] = mrb_int_value(mrb, (mrb_int)pd->buttons);
            argv[p * 5 + 1] = mrb_int_value(mrb, (mrb_int)pd->left_x);
            argv[p * 5 + 2] = mrb_int_value(mrb, (mrb_int)pd->left_y);
            argv[p * 5 + 3] = mrb_int_value(mrb, (mrb_int)pd->right_x);
            argv[p * 5 + 4] = mrb_int_value(mrb, (mrb_int)pd->right_y);
        }
        mrb_funcall_argv(mrb, mrb_top_self(mrb), mrb_intern_lit(mrb, "__wasmcart_frame"), 20, argv);
        ruby_guard("tick");
        rt_buf = NULL; /* never leave a frame aimed at a render target */
    }
    if (!dbg_ruby_ok) {
        fill_rect(0, DEFAULT_HEIGHT - 80, DEFAULT_WIDTH, 80, 0x00AA2222, 255);
        draw_label(24, DEFAULT_HEIGHT - 28, "RUBY EXCEPTION - SEE LOG", 4, 0x00FFFFFF);
    }

    /* time-based mix per the wc_pcm_mixer guidance; under the fixed-step
     * deterministic clock delta_ms is constant, so audio replays too */
    double delta = wc_time.delta_ms;
    if (delta <= 0 || delta > 100) delta = 1000.0 / 60.0;
    int frames = (int)(48000.0 * delta / 1000.0);
    wc_mixer_mix_f32(wc_audio_ring, AUDIO_CAP, &wc_audio_write_cursor, frames);

    tick_n++;
    dbg_tick = tick_n;
}
