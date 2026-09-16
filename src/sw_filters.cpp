/**
 * \file sw_filters.cpp
 * \brief Implementation of the software filter chain.
 */


#include "sw_filters.hpp"

// ----- comparator primitives -----
/// \brief Smaller of two values.
static inline uint8_t cmin(uint8_t a, uint8_t b) {
   return (a < b) ? a : b;
}

/// \brief Larger of two values.
static inline uint8_t cmax(uint8_t a, uint8_t b) {
   return (a < b) ? b : a;
}


/// \brief Median of three, depth 3 comparators. 
static inline uint8_t med3(uint8_t p, uint8_t q, uint8_t r) {
   return cmax(cmin(p, q), cmin(cmax(p, q), r));
}

/**
 * \brief Sort three values, depth 3 comparators.
 * \param x first
 * \param y second
 * \param z third
 * \param lo smallest
 * \param mid middle
 * \param hi largest
 */
static inline void sort3(uint8_t x, uint8_t y, uint8_t z,
                         uint8_t* lo, uint8_t* mid, uint8_t* hi) {
   uint8_t t1 = cmin(x, y);
   uint8_t t2 = cmax(x, y);
   uint8_t h1 = cmax(t1, z);

   *lo = cmin(t1, z);
   *mid = cmin(t2, h1);
   *hi = cmax(t2, h1);
}

/* --- window kernels ------------------------------------------------------
 * Row pointers plus column indices: the kernel itself only sees nine values. 
 * Same as the PL, where the line buffers form the window. */


/// \brief Median of the 3x3 window, three stage network from median.vhd.
static inline uint8_t median9(const uint8_t* r_above, const uint8_t* r_center, const uint8_t* r_below, int xl, int xc, int xr) {
   uint8_t lo_a, mid_a, hi_a;
   uint8_t lo_b, mid_b, hi_b;
   uint8_t lo_c, mid_c, hi_c;

   sort3(r_above[xl], r_center[xl], r_below[xl], &lo_a, &mid_a, &hi_a);
   sort3(r_above[xc], r_center[xc], r_below[xc], &lo_b, &mid_b, &hi_b);
   sort3(r_above[xr], r_center[xr], r_below[xr], &lo_c, &mid_c, &hi_c);

   uint8_t maxmin = cmax(cmax(lo_a, lo_b), lo_c);
   uint8_t medmed = med3(mid_a, mid_b, mid_c);
   uint8_t minmax = cmin(cmin(hi_a, hi_b), hi_c);

   return med3(maxmin, medmed, minmax);
}


/// \brief Weighted sum of the 3x3 window, add tree from gauss.vhd.
static inline uint8_t gauss9(const uint8_t* r_above, const uint8_t* r_center, const uint8_t* r_below, int xl, int xc, int xr) {
   uint32_t corners = (uint32_t)r_above[xl] + r_above[xr] + r_below[xl] + r_below[xr];  // weight 1
   uint32_t edges = (uint32_t)r_above[xc] + r_center[xl] + r_center[xr] + r_below[xc];  // weight 2
   uint32_t acc = corners + (edges << 1) + ((uint32_t)r_center[xc] << 2) + 8;  // +8 rounds 

   return (uint8_t)(acc >> 4);  // divide by 16 
}

/* --- filter stages -------------------------------------------------------- */

void sw_rgb2gray(const uint8_t* src, uint8_t* dst, int width, int height) {
   int n = width * height;

   for (int i = 0; i < n; ++i) {
      const uint8_t* p = src + 3 * i;
#if SW_PIXEL_ORDER_BGR
      uint32_t b = p[0];
      uint32_t g = p[1];
      uint32_t r = p[2];
#else
      uint32_t r = p[0];
      uint32_t g = p[1];
      uint32_t b = p[2];
#endif
      // +128 rounds to nearest instead of truncating
      dst[i] = (uint8_t)((77 * r + 150 * g + 29 * b + 128) >> 8);
   }
}


// Both 3x3 stages share the same loop shape: rows are clamped once per line through the pointers

void sw_median3x3(const uint8_t* src, uint8_t* dst, int width, int height) {
   for (int y = 0; y < height; ++y) {
      const uint8_t* r0 = src + (long)width * ((y > 0) ? (y - 1) : 0);
      const uint8_t* r1 = src + (long)width * y;
      const uint8_t* r2 = src + (long)width * ((y < height - 1) ? (y + 1) : (height - 1));
      uint8_t* out = dst + (long)width * y;

      //  all three columns collapse onto one 
      if (width == 1) {
         out[0] = median9(r0, r1, r2, 0, 0, 0);
         continue;
      }
      // left border replicated 
      out[0] = median9(r0, r1, r2, 0, 0, 1); 
      // no replication
      for (int x = 1; x < width - 1; ++x) {
         out[x] = median9(r0, r1, r2, x - 1, x, x + 1);
      }
      // right border replicated
      out[width - 1] = median9(r0, r1, r2, width - 2, width - 1, width - 1);
   }
}

void sw_gauss3x3(const uint8_t* src, uint8_t* dst, int width, int height) {
   for (int y = 0; y < height; ++y) {
      const uint8_t* r0 = src + (long)width * ((y > 0) ? (y - 1) : 0);
      const uint8_t* r1 = src + (long)width * y;
      const uint8_t* r2 = src + (long)width * ((y < height - 1) ? (y + 1) : (height - 1));
      uint8_t* out = dst + (long)width * y;

      if (width == 1) {
         out[0] = gauss9(r0, r1, r2, 0, 0, 0);
         continue;
      }
      // left border
      out[0] = gauss9(r0, r1, r2, 0, 0, 1);
      // no replicatio
      for (int x = 1; x < width - 1; ++x) {
         out[x] = gauss9(r0, r1, r2, x - 1, x, x + 1);
      }
      // right border
      out[width - 1] = gauss9(r0, r1, r2, width - 2, width - 1, width - 1);
   }
}


/// \brief Software writes and reads two full intermediate images. Difference is what the result chapter has to quantify.
void sw_pipeline(const uint8_t* rgb_src, uint8_t* dst, uint8_t* tmp_gray, uint8_t* tmp_med, int width, int height) {
   sw_rgb2gray(rgb_src, tmp_gray, width, height);
   sw_median3x3(tmp_gray, tmp_med, width, height);
   sw_gauss3x3(tmp_med, dst, width, height);
}


void sw_compare(const uint8_t* ref, const uint8_t* dut, int width, int height, int margin_right, int margin_bottom, SwDiff* out) {
   out->total = 0;
   out->strict = 0;
   out->max_dev = 0;
   out->max_dev_strict = 0;
   out->first_x = -1;
   out->first_y = -1;

   for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
         int i = y * width + x;
         int a = ref[i];
         int b = dut[i];

         if (a == b) continue;
         
         int dev = (a > b) ? (a - b) : (b - a);
         out->total += 1;
         if (dev > out->max_dev) {
            out->max_dev = dev;
         }

         /* top and left are not excluded, the PL replicates correctly there */
         if ((x < width - margin_right) && (y < height - margin_bottom)) {
            out->strict += 1;
            if (dev > out->max_dev_strict) {
               out->max_dev_strict = dev;
            }
            if (out->first_y < 0) {
               out->first_x = x;
               out->first_y = y;
            }
         }
      }
   }
}

