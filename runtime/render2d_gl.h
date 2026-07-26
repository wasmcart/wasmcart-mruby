#ifndef WY_RENDER2D_GL_H
#define WY_RENDER2D_GL_H

#include <stdint.h>

/* Per-frame GL diagnostics, latched at wy_r2d_end so a host reading the
 * debug fields mid-frame sees the last completed frame. All zero in the
 * CPU build. Defined in runtime.c so both builds link one copy. */
typedef struct {
    uint32_t draws;         /* glDrawElements/glDrawArrays calls */
    uint32_t solid_flushes;
    uint32_t tex_flushes;
    uint32_t quads;         /* rect/sprite quads submitted */
    uint32_t upload_bytes;  /* glBufferData bytes this frame */
} wy_r2d_stats_t;
extern wy_r2d_stats_t wy_r2d_stats;

#ifdef WC_ENABLE_GL2D

int  wy_r2d_init(int width, int height);
/* returns 1 when this frame renders via GL; 0 when the caller must clear
 * and CPU-rasterize the framebuffer (sticky cpu_mode, see render2d_gl.c) */
int  wy_r2d_begin(uint32_t clear_color);
/* fb: the cart framebuffer — blitted to GL when the frame was CPU-rendered */
void wy_r2d_end(const uint32_t *fb);
void wy_r2d_disable(void);
int  wy_r2d_active(void);
int  wy_r2d_solid(int x, int y, int w, int h, uint32_t color, int alpha);
int  wy_r2d_solid_batch(const int *items, int count);
int  wy_r2d_static_solid_batch(const int *items, int count, uint32_t hash);
int  wy_r2d_line(int x0, int y0, int x1, int y1, uint32_t color, int alpha);
int  wy_r2d_sprite(const void *pixels, int sw, int sh,
                   int dx, int dy, int dw, int dh,
                   int sx, int sy, int srcw, int srch,
                   int flip_h, int flip_v, double angle,
                   uint32_t tint, int alpha);

#else

static inline int wy_r2d_init(int width, int height) {
    (void)width; (void)height; return 0;
}
static inline int wy_r2d_begin(uint32_t clear_color) { (void)clear_color; return 0; }
static inline void wy_r2d_end(const uint32_t *fb) { (void)fb; }
static inline void wy_r2d_disable(void) {}
static inline int wy_r2d_active(void) { return 0; }
static inline int wy_r2d_solid(int x, int y, int w, int h, uint32_t color, int alpha) {
    (void)x; (void)y; (void)w; (void)h; (void)color; (void)alpha; return 0;
}
static inline int wy_r2d_solid_batch(const int *items, int count) {
    (void)items; (void)count; return 0;
}
static inline int wy_r2d_static_solid_batch(const int *items, int count, uint32_t hash) {
    (void)items; (void)count; (void)hash; return 0;
}
static inline int wy_r2d_line(int x0, int y0, int x1, int y1, uint32_t color, int alpha) {
    (void)x0; (void)y0; (void)x1; (void)y1; (void)color; (void)alpha; return 0;
}
static inline int wy_r2d_sprite(const void *pixels, int sw, int sh,
                                int dx, int dy, int dw, int dh,
                                int sx, int sy, int srcw, int srch,
                                int flip_h, int flip_v, double angle,
                                uint32_t tint, int alpha) {
    (void)pixels; (void)sw; (void)sh; (void)dx; (void)dy; (void)dw; (void)dh;
    (void)sx; (void)sy; (void)srcw; (void)srch; (void)flip_h; (void)flip_v;
    (void)angle; (void)tint; (void)alpha; return 0;
}

#endif

#endif
