/* Floyd-Steinberg over an OKLab image, for tools/texquant.py.
   A pixel takes the palette entry nearest by dL^2 + dC^2 + 4 dH^2 -- the
   colormap's matcher -- and its OKLab error spreads 7/3/5/1 in serpentine
   order. Ties go to the lower index. */

#include <math.h>

static int nearest(const float *t, const float *pal, const float *chroma, int n)
{
    float tc = sqrtf(t[1] * t[1] + t[2] * t[2]), low = INFINITY;
    int best = 0;
    for (int i = 0; i < n; i++) {
        const float *p = pal + i * 3;
        float dl = t[0] - p[0], dc = tc - chroma[i];
        float da = t[1] - p[1], db = t[2] - p[2];
        float dh2 = da * da + db * db - dc * dc;
        float d = dl * dl + dc * dc + 4.0f * (dh2 > 0.0f ? dh2 : 0.0f);
        if (d < low) { low = d; best = i; }
    }
    return best;
}

static void spread(float *img, int w, int h, int x, int y, const float *e, float k)
{
    if (x < 0 || x >= w || y >= h) return;
    float *t = img + (y * w + x) * 3;
    for (int c = 0; c < 3; c++) t[c] += e[c] * k;
}

static float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : v > hi ? hi : v;
}

void fs_dither(float *img, int w, int h, const float *pal, int n, unsigned char *out)
{
    float chroma[256];
    for (int i = 0; i < n && i < 256; i++)
        chroma[i] = sqrtf(pal[i * 3 + 1] * pal[i * 3 + 1] + pal[i * 3 + 2] * pal[i * 3 + 2]);

    for (int y = 0; y < h; y++) {
        int dir = (y & 1) ? -1 : 1;
        for (int k = 0; k < w; k++) {
            int x = dir > 0 ? k : w - 1 - k;
            float *t = img + (y * w + x) * 3, e[3];
            /* accumulated error can walk out of gamut; hold it near */
            t[0] = clampf(t[0], 0.0f, 1.0f);
            t[1] = clampf(t[1], -0.4f, 0.4f);
            t[2] = clampf(t[2], -0.4f, 0.4f);
            int i = nearest(t, pal, chroma, n);
            out[y * w + x] = (unsigned char) i;
            for (int c = 0; c < 3; c++) e[c] = t[c] - pal[i * 3 + c];
            spread(img, w, h, x + dir, y,     e, 7.0f / 16.0f);
            spread(img, w, h, x - dir, y + 1, e, 3.0f / 16.0f);
            spread(img, w, h, x,       y + 1, e, 5.0f / 16.0f);
            spread(img, w, h, x + dir, y + 1, e, 1.0f / 16.0f);
        }
    }
}
