#include "render2d_gl.h"

#ifdef WC_ENABLE_GL2D

#define WC_USE_GL
#include "wasmcart.h"
#define WC_GL_BLIT_IMPLEMENTATION
#include "wc_gl_blit.h"
#include <math.h>
#include <string.h>

#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_LINEAR 0x2601
#define GL_NEAREST 0x2600
#define GL_UNSIGNED_BYTE 0x1401
#define GL_RGBA 0x1908
#define GL_TEXTURE0 0x84C0
#define GL_BLEND 0x0BE2
#define GL_SRC_ALPHA 0x0302
#define GL_ONE_MINUS_SRC_ALPHA 0x0303
#define GL_ARRAY_BUFFER 0x8892
#define GL_ELEMENT_ARRAY_BUFFER 0x8893
#define GL_DYNAMIC_DRAW 0x88E8
#define GL_STATIC_DRAW 0x88E4
#define GL_FLOAT 0x1406
#define GL_TRIANGLES 0x0004
#define GL_UNSIGNED_SHORT 0x1403
#define GL_LINES 0x0001
#define GL_COLOR_BUFFER_BIT 0x00004000

typedef struct { float x, y, u, v, r, g, b, a; } vertex_t;
typedef struct {
    const void *pixels;
    int w, h;
    int atlas_x, atlas_y;
    int used;
} texture_t;

static int ready;
static int frame_disabled;
/* Sticky: set on the first wy_r2d_disable (render target, TTF label,
 * @rt: sprite, exception banner). From then on every frame CPU-rasterizes
 * into the cart framebuffer and wy_r2d_end blits it to GL as a fullscreen
 * quad — GL hosts would otherwise present only the clear color, losing all
 * CPU-drawn content. Carts that never touch those features keep the GL
 * fast path; mixed carts get CPU-build behavior at CPU-build speed. */
static int cpu_mode;
static int width, height;
static float ndc_scale_x, ndc_scale_y;
static GLuint program, vao, buffer;
static GLuint static_buffer;
static GLint pos_attr, uv_attr, color_attr, tex_uniform, textured_uniform;
static texture_t textures[32];
#define ATLAS_SIZE 2048
static GLuint atlas_texture;
static int atlas_x, atlas_y, atlas_row_h;
#define SOLID_BATCH_MAX 4096
static vertex_t solid_batch[SOLID_BATCH_MAX * 4];
static int solid_batch_count;
static uint16_t solid_indices[SOLID_BATCH_MAX * 6];
static GLuint index_buffer;
static int solid_batch_has_alpha;
static vertex_t static_vertices[SOLID_BATCH_MAX * 4];
static int static_vertex_count;
static int static_item_count;
static uint32_t static_hash;
static int static_valid;
#define TEXTURED_BATCH_MAX 4096
static vertex_t textured_batch[TEXTURED_BATCH_MAX * 4];
static int textured_batch_count;
static GLuint textured_batch_texture;
static int blend_enabled = -1;
static int textured_enabled = -1;
static GLuint bound_texture;
static uint32_t current_clear_color = 0xFFFFFFFFu;
static wy_r2d_stats_t frame_stats;

static const char *VERTEX_SHADER =
    "#version 300 es\n"
    "in vec2 a_pos;\n"
    "in vec2 a_uv;\n"
    "in vec4 a_color;\n"
    "out vec2 v_uv;\n"
    "out vec4 v_color;\n"
    "void main() { gl_Position = vec4(a_pos, 0.0, 1.0); v_uv = a_uv; v_color = a_color; }\n";

static const char *FRAGMENT_SHADER =
    "#version 300 es\n"
    "precision mediump float;\n"
    "in vec2 v_uv;\n"
    "in vec4 v_color;\n"
    "out vec4 frag_color;\n"
    "uniform sampler2D u_tex;\n"
    "uniform int u_textured;\n"
    "void main() {\n"
    "  frag_color = v_color;\n"
    "  if (u_textured != 0) frag_color *= texture(u_tex, v_uv);\n"
    "}\n";

static void log_shader(GLuint object, const char *what, int shader) {
    GLint ok = 0, len = 0;
    if (shader) glGetShaderiv(object, GL_COMPILE_STATUS, &ok);
    else glGetProgramiv(object, GL_LINK_STATUS, &ok);
    if (ok) return;
    if (shader) glGetShaderiv(object, 0x8B84, &len);
    else glGetProgramiv(object, 0x8B84, &len);
    if (len > 0 && len < 512) {
        char log[512];
        if (shader) glGetShaderInfoLog(object, sizeof log, &len, log);
        else glGetProgramInfoLog(object, sizeof log, &len, log);
        wc_log(log, (unsigned int)len);
    } else {
        wc_log(what, (unsigned int)strlen(what));
    }
}

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    GLint length = (GLint)strlen(source);
    glShaderSource(shader, 1, &source, &length);
    glCompileShader(shader);
    log_shader(shader, "2d shader compilation failed", 1);
    return shader;
}

static void ndc(float x, float y, float *out_x, float *out_y) {
    *out_x = x * ndc_scale_x - 1.0f;
    *out_y = y * ndc_scale_y - 1.0f;
}

static void set_blend(int enabled) {
    if (blend_enabled == enabled) return;
    if (enabled) glEnable(GL_BLEND);
    else glDisable(GL_BLEND);
    blend_enabled = enabled;
}

static void set_textured(int enabled) {
    if (textured_enabled == enabled) return;
    glUniform1i(textured_uniform, enabled);
    textured_enabled = enabled;
}

static void bind_texture(GLuint texture) {
    if (bound_texture == texture) return;
    glBindTexture(GL_TEXTURE_2D, texture);
    bound_texture = texture;
}

static void draw_vertices(const vertex_t *vertices, int count, GLenum mode,
                          int textured, GLuint texture) {
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(sizeof(vertex_t) * count), vertices, GL_DYNAMIC_DRAW);
    set_textured(textured);
    if (textured) bind_texture(texture);
    glDrawArrays(mode, 0, count);
    frame_stats.draws++;
    frame_stats.upload_bytes += (uint32_t)(sizeof(vertex_t) * count);
}

static void flush_solid_batch(void) {
    if (!solid_batch_count) return;
    set_blend(solid_batch_has_alpha);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(sizeof(vertex_t) * solid_batch_count), solid_batch, GL_DYNAMIC_DRAW);
    set_textured(0);
    glDrawElements(GL_TRIANGLES, (GLsizei)((solid_batch_count / 4) * 6),
                   GL_UNSIGNED_SHORT, (const void *)0);
    frame_stats.draws++;
    frame_stats.solid_flushes++;
    frame_stats.upload_bytes += (uint32_t)(sizeof(vertex_t) * solid_batch_count);
    solid_batch_count = 0;
    solid_batch_has_alpha = 0;
}

static void flush_textured_batch(void) {
    if (!textured_batch_count) return;
    set_blend(1);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(sizeof(vertex_t) * textured_batch_count),
                 textured_batch, GL_DYNAMIC_DRAW);
    set_textured(1);
    bind_texture(textured_batch_texture);
    glDrawElements(GL_TRIANGLES, (GLsizei)((textured_batch_count / 4) * 6),
                   GL_UNSIGNED_SHORT, (const void *)0);
    frame_stats.draws++;
    frame_stats.tex_flushes++;
    frame_stats.upload_bytes += (uint32_t)(sizeof(vertex_t) * textured_batch_count);
    textured_batch_count = 0;
    textured_batch_texture = 0;
}

static void flush_batches(void) {
    flush_solid_batch();
    flush_textured_batch();
}

int wy_r2d_init(int w, int h) {
    width = w; height = h;
    ndc_scale_x = 2.0f / (float)w;
    ndc_scale_y = 2.0f / (float)h;
    memset(textures, 0, sizeof(textures));
    GLuint vs = compile_shader(GL_VERTEX_SHADER, VERTEX_SHADER);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
    program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glBindAttribLocation(program, 0, "a_pos");
    glBindAttribLocation(program, 1, "a_uv");
    glBindAttribLocation(program, 2, "a_color");
    glLinkProgram(program);
    log_shader(program, "2d program link failed", 0);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &buffer);
    glGenBuffers(1, &static_buffer);
    glGenBuffers(1, &index_buffer);
    for (int i = 0; i < SOLID_BATCH_MAX; i++) {
        uint16_t v = (uint16_t)(i * 4);
        solid_indices[i * 6 + 0] = v;
        solid_indices[i * 6 + 1] = (uint16_t)(v + 1);
        solid_indices[i * 6 + 2] = (uint16_t)(v + 2);
        solid_indices[i * 6 + 3] = v;
        solid_indices[i * 6 + 4] = (uint16_t)(v + 2);
        solid_indices[i * 6 + 5] = (uint16_t)(v + 3);
    }
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, index_buffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(solid_indices), solid_indices, GL_STATIC_DRAW);
    glGenTextures(1, &atlas_texture);
    glBindTexture(GL_TEXTURE_2D, atlas_texture);
    /* NEAREST matches the CPU renderer's point sampling — pixel-art parity
     * between the two backends (LINEAR softened sprite edges GL-only) */
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, ATLAS_SIZE, ATLAS_SIZE, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    pos_attr = glGetAttribLocation(program, "a_pos");
    uv_attr = glGetAttribLocation(program, "a_uv");
    color_attr = glGetAttribLocation(program, "a_color");
    tex_uniform = glGetUniformLocation(program, "u_tex");
    textured_uniform = glGetUniformLocation(program, "u_textured");
    glUseProgram(program);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, index_buffer);
    glEnableVertexAttribArray((GLuint)pos_attr);
    glEnableVertexAttribArray((GLuint)uv_attr);
    glEnableVertexAttribArray((GLuint)color_attr);
    glVertexAttribPointer((GLuint)pos_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)0);
    glVertexAttribPointer((GLuint)uv_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 2));
    glVertexAttribPointer((GLuint)color_attr, 4, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 4));
    glActiveTexture(GL_TEXTURE0);
    glUniform1i(tex_uniform, 0);
    glViewport(0, 0, width, height);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    ready = program != 0 && vao != 0 && buffer != 0 && static_buffer != 0 &&
            index_buffer != 0 && atlas_texture != 0;
    frame_disabled = 0;
    cpu_mode = 0;
    atlas_x = 0;
    atlas_y = 0;
    atlas_row_h = 0;
    textured_batch_texture = 0;
    blend_enabled = -1;
    textured_enabled = -1;
    bound_texture = atlas_texture;
    current_clear_color = 0xFFFFFFFFu;
    static_valid = 0;
    static_hash = 0;
    static_item_count = 0;
    static_vertex_count = 0;
    return ready;
}

int wy_r2d_begin(uint32_t clear_color) {
    if (!ready) return 0;
    solid_batch_count = 0;
    textured_batch_count = 0;
    textured_batch_texture = 0;
    solid_batch_has_alpha = 0;
    memset(&frame_stats, 0, sizeof(frame_stats));
    if (cpu_mode) {
        /* caller clears + CPU-rasterizes the framebuffer; end() blits it */
        frame_disabled = 1;
        return 0;
    }
    frame_disabled = 0;
    if (clear_color != current_clear_color) {
        glClearColor((float)((clear_color >> 16) & 255) / 255.0f,
                     (float)((clear_color >> 8) & 255) / 255.0f,
                     (float)(clear_color & 255) / 255.0f, 1.0f);
        current_clear_color = clear_color;
    }
    glClear(GL_COLOR_BUFFER_BIT);
    return 1;
}

/* XRGB u32 framebuffer → RGBA bytes for the blit texture */
static uint32_t blit_rgba[1280 * 720];

void wy_r2d_end(const uint32_t *fb) {
    if (wy_r2d_active()) {
        flush_batches();
    } else if (ready && frame_disabled && fb) {
        int n = width * height;
        for (int i = 0; i < n; i++) {
            uint32_t px = fb[i];
            blit_rgba[i] = 0xFF000000u | ((px >> 16) & 0xFFu) |
                           (px & 0x0000FF00u) | ((px & 0xFFu) << 16);
        }
        wc_gl_blit(blit_rgba, width, height);
    }
    wy_r2d_stats = frame_stats;
}

void wy_r2d_disable(void) {
    if (wy_r2d_active()) flush_batches();
    frame_disabled = 1;
    cpu_mode = 1;
}
int wy_r2d_active(void) { return ready && !frame_disabled; }

int wy_r2d_static_solid_batch(const int *items, int count, uint32_t hash) {
    if (!wy_r2d_active() || !items || count <= 0 || count > SOLID_BATCH_MAX) return 0;
    for (int i = 0; i < count; i++) {
        if (items[i * 6 + 5] != 255) return 0;
    }
    flush_batches();
    if (!static_valid || static_hash != hash || static_item_count != count) {
        for (int i = 0; i < count; i++) {
            const int *item = &items[i * 6];
            vertex_t *v = &static_vertices[i * 4];
            float x0, y0, x1, y1;
            float r = (float)((item[4] >> 16) & 255) / 255.0f;
            float g = (float)((item[4] >> 8) & 255) / 255.0f;
            float b = (float)(item[4] & 255) / 255.0f;
            ndc((float)item[0], (float)item[1], &x0, &y0);
            ndc((float)(item[0] + item[2]), (float)(item[1] + item[3]), &x1, &y1);
            v[0].x = x0; v[0].y = y0; v[1].x = x1; v[1].y = y0;
            v[2].x = x1; v[2].y = y1; v[3].x = x0; v[3].y = y1;
            for (int j = 0; j < 4; j++) {
                v[j].u = v[j].v = 0;
                v[j].r = r; v[j].g = g; v[j].b = b; v[j].a = 1.0f;
            }
        }
        static_vertex_count = count * 4;
        static_item_count = count;
        static_hash = hash;
        static_valid = 1;
        glBindBuffer(GL_ARRAY_BUFFER, static_buffer);
        glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(sizeof(vertex_t) * static_vertex_count),
                     static_vertices, GL_STATIC_DRAW);
    }
    set_blend(0);
    glBindBuffer(GL_ARRAY_BUFFER, static_buffer);
    glVertexAttribPointer((GLuint)pos_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)0);
    glVertexAttribPointer((GLuint)uv_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 2));
    glVertexAttribPointer((GLuint)color_attr, 4, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 4));
    set_textured(0);
    glDrawElements(GL_TRIANGLES, (GLsizei)(static_item_count * 6), GL_UNSIGNED_SHORT, (const void *)0);
    frame_stats.draws++;
    frame_stats.quads += (uint32_t)static_item_count;
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glVertexAttribPointer((GLuint)pos_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)0);
    glVertexAttribPointer((GLuint)uv_attr, 2, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 2));
    glVertexAttribPointer((GLuint)color_attr, 4, GL_FLOAT, GL_FALSE, sizeof(vertex_t), (const void *)(sizeof(float) * 4));
    set_blend(1);
    return 1;
}

int wy_r2d_solid(int x, int y, int w, int h, uint32_t color, int alpha) {
    if (!wy_r2d_active() || w <= 0 || h <= 0) return 0;
    if (textured_batch_count) flush_textured_batch();
    if (solid_batch_count + 4 > SOLID_BATCH_MAX * 4) flush_solid_batch();
    if (alpha < 255) solid_batch_has_alpha = 1;
    vertex_t *v = &solid_batch[solid_batch_count];
    float x0, y0, x1, y1;
    float r = (float)((color >> 16) & 255) / 255.0f;
    float g = (float)((color >> 8) & 255) / 255.0f;
    float b = (float)(color & 255) / 255.0f;
    float a = (float)alpha / 255.0f;
    ndc((float)x, (float)y, &x0, &y0); ndc((float)(x + w), (float)(y + h), &x1, &y1);
    v[0].x = x0; v[0].y = y0; v[1].x = x1; v[1].y = y0;
    v[2].x = x1; v[2].y = y1; v[3].x = x0; v[3].y = y1;
    for (int i = 0; i < 4; i++) {
        v[i].u = v[i].v = 0;
        v[i].r = r; v[i].g = g; v[i].b = b; v[i].a = a;
    }
    solid_batch_count += 4;
    frame_stats.quads++;
    return 1;
}

int wy_r2d_solid_batch(const int *items, int count) {
    if (!wy_r2d_active() || !items || count <= 0) return 0;
    if (textured_batch_count) flush_textured_batch();
    for (int i = 0; i < count; i++) {
        const int *item = &items[i * 6];
        int x = item[0], y = item[1], w = item[2], h = item[3];
        uint32_t color = (uint32_t)item[4];
        int alpha = item[5];
        if (w <= 0 || h <= 0) continue;
        if (solid_batch_count + 4 > SOLID_BATCH_MAX * 4) flush_solid_batch();
        if (alpha < 255) solid_batch_has_alpha = 1;
        vertex_t *v = &solid_batch[solid_batch_count];
        float x0, y0, x1, y1;
        float r = (float)((color >> 16) & 255) / 255.0f;
        float g = (float)((color >> 8) & 255) / 255.0f;
        float b = (float)(color & 255) / 255.0f;
        float a = (float)alpha / 255.0f;
        ndc((float)x, (float)y, &x0, &y0);
        ndc((float)(x + w), (float)(y + h), &x1, &y1);
        v[0].x = x0; v[0].y = y0; v[1].x = x1; v[1].y = y0;
        v[2].x = x1; v[2].y = y1; v[3].x = x0; v[3].y = y1;
        for (int j = 0; j < 4; j++) {
            v[j].u = v[j].v = 0;
            v[j].r = r; v[j].g = g; v[j].b = b; v[j].a = a;
        }
        solid_batch_count += 4;
        frame_stats.quads++;
    }
    return 1;
}

int wy_r2d_line(int x0, int y0, int x1, int y1, uint32_t color, int alpha) {
    if (!wy_r2d_active()) return 0;
    flush_batches();
    set_blend(1);
    vertex_t v[2];
    ndc((float)x0, (float)y0, &v[0].x, &v[0].y);
    ndc((float)x1, (float)y1, &v[1].x, &v[1].y);
    v[0].u = v[0].v = v[1].u = v[1].v = 0;
    {
        float r = (float)((color >> 16) & 255) / 255.0f;
        float g = (float)((color >> 8) & 255) / 255.0f;
        float b = (float)(color & 255) / 255.0f;
        float a = (float)alpha / 255.0f;
        for (int i = 0; i < 2; i++) {
            v[i].r = r; v[i].g = g; v[i].b = b; v[i].a = a;
        }
    }
    draw_vertices(v, 2, GL_LINES, 0, 0);
    return 1;
}

static texture_t *get_texture(const void *pixels, int w, int h) {
    for (int i = 0; i < 32; i++)
        if (textures[i].used && textures[i].pixels == pixels) return &textures[i];
    for (int i = 0; i < 32; i++) if (!textures[i].used) {
        texture_t *t = &textures[i];
        if (w > ATLAS_SIZE || h > ATLAS_SIZE) return NULL;
        if (atlas_x + w > ATLAS_SIZE) {
            atlas_x = 0;
            atlas_y += atlas_row_h;
            atlas_row_h = 0;
        }
        if (atlas_y + h > ATLAS_SIZE) return NULL;
        t->pixels = pixels; t->w = w; t->h = h;
        t->atlas_x = atlas_x; t->atlas_y = atlas_y; t->used = 1;
        bind_texture(atlas_texture);
        glTexSubImage2D(GL_TEXTURE_2D, 0, atlas_x, atlas_y, w, h,
                        GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        atlas_x += w;
        if (h > atlas_row_h) atlas_row_h = h;
        return t;
    }
    return NULL;
}

int wy_r2d_sprite(const void *pixels, int sw, int sh,
                  int dx, int dy, int dw, int dh, int sx, int sy, int srcw, int srch,
                  int flip_h, int flip_v, double angle, uint32_t tint, int alpha) {
    if (!wy_r2d_active() || !pixels || dw <= 0 || dh <= 0) return 0;
    texture_t *t = get_texture(pixels, sw, sh);
    if (!t) return 0;
    if (solid_batch_count) flush_solid_batch();
    if (!textured_batch_count) textured_batch_texture = atlas_texture;
    if (textured_batch_count + 4 > TEXTURED_BATCH_MAX * 4)
        flush_textured_batch();
    if (srcw <= 0) { sx = 0; srcw = sw; }
    if (srch <= 0) { sy = 0; srch = sh; }
    float uv0 = (float)(t->atlas_x + sx) / ATLAS_SIZE;
    float uv1 = (float)(t->atlas_x + sx + srcw) / ATLAS_SIZE;
    float vv0 = (float)(t->atlas_y + sy) / ATLAS_SIZE;
    float vv1 = (float)(t->atlas_y + sy + srch) / ATLAS_SIZE;
    if (flip_h) { float q = uv0; uv0 = uv1; uv1 = q; }
    if (flip_v) { float q = vv0; vv0 = vv1; vv1 = q; }
    float uv[8] = {uv0, vv1, uv1, vv1, uv1, vv0, uv0, vv0};
    vertex_t *v = &textured_batch[textured_batch_count];
    float r = (float)((tint >> 16) & 255) / 255.0f;
    float g = (float)((tint >> 8) & 255) / 255.0f;
    float b = (float)(tint & 255) / 255.0f;
    float a = (float)alpha / 255.0f;
    if (angle == 0.0) {
        ndc((float)dx, (float)dy, &v[0].x, &v[0].y);
        ndc((float)(dx + dw), (float)dy, &v[1].x, &v[1].y);
        ndc((float)(dx + dw), (float)(dy + dh), &v[2].x, &v[2].y);
        ndc((float)dx, (float)(dy + dh), &v[3].x, &v[3].y);
    } else {
        double rad = angle * 3.14159265358979323846 / 180.0;
        double cs = cos(rad), sn = sin(rad);
        double cx = dx + dw / 2.0, cy = dy + dh / 2.0;
        double px[4] = {-dw / 2.0, dw / 2.0, dw / 2.0, -dw / 2.0};
        double py[4] = {-dh / 2.0, -dh / 2.0, dh / 2.0, dh / 2.0};
        for (int i = 0; i < 4; i++) {
            double x = cx + px[i] * cs - py[i] * sn;
            double y = cy + px[i] * sn + py[i] * cs;
            ndc((float)x, (float)y, &v[i].x, &v[i].y);
        }
    }
    for (int i = 0; i < 4; i++) {
        v[i].u = uv[i * 2]; v[i].v = uv[i * 2 + 1];
        v[i].r = r; v[i].g = g; v[i].b = b; v[i].a = a;
    }
    textured_batch_count += 4;
    frame_stats.quads++;
    return 1;
}

#endif
