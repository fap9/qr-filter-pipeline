/**
 * \file qr_image.cpp
 * \brief Placement, rendering, noise and module scoring.
 */

#include "qr_image.hpp"
#include "sw_filters.hpp"


/**
 * \brief xorshift32, same generator as the testbenches.
 * \param state seed, updated in place
 * \return pseudo random value
 */
static uint32_t next_rnd(uint32_t* state) {
   uint32_t s = *state;
   s ^= s << 13;
   s ^= s >> 17;
   s ^= s << 5;
   *state = s;
   return s;
}


bool qr_place(QrRef* ref, int width, int height, int scale) {
   if ((ref->modules <= 0) || (ref->modules > QR_MAX_MODULES)) {
      return false;
   }

   int span = ref->modules + 2 * QR_QUIET_MODULES;
   int limit = (width < height) ? width : height;

   if (scale <= 0) {
      scale = limit / span;  // largest scale that still leaves the quiet zone 
   }
   if (scale <= 0) {
      return false;
   }
   if (span * scale > limit) {
      return false;
   }

   ref->scale = scale;
   ref->origin_x = (width - ref->modules * scale) / 2;
   ref->origin_y = (height - ref->modules * scale) / 2;
   return true;
}


void qr_render(const QrRef* ref, uint8_t* rgb, int width, int height) {
   // quiet zone and background 
   for (long i = 0; i < (long)width * height; ++i) {
      sw_store_rgb(rgb + 3 * i, 255, 255, 255);
   }

   for (int my = 0; my < ref->modules; ++my) {
      for (int mx = 0; mx < ref->modules; ++mx) {
         if (ref->grid[my * ref->modules + mx] == 0) {
            continue; // light module, background already white 
         }

         int x0 = ref->origin_x + mx * ref->scale;
         int y0 = ref->origin_y + my * ref->scale;

         for (int dy = 0; dy < ref->scale; ++dy) {
            uint8_t* row = rgb + 3 * ((long)(y0 + dy) * width + x0);
            for (int dx = 0; dx < ref->scale; ++dx) {
               sw_store_rgb(row + 3 * dx, 0, 0, 0);
            }
         }
      }
   }
}


void qr_add_salt_pepper(uint8_t* rgb, int width, int height, int percent, uint32_t seed) {
   if (percent <= 0) {
      return;
   }

   uint32_t state = (seed != 0) ? seed : 1;

   for (long i = 0; i < (long)width * height; ++i) {
      if ((next_rnd(&state) % 100) < (uint32_t)percent) {
         uint8_t v = (next_rnd(&state) & 1) ? 255 : 0;
         sw_store_rgb(rgb + 3 * i, v, v, v);
      }
   }
}

int qr_count_module_errors(const QrRef* ref, const uint8_t* gray, int width, int height) {
   int errors = 0;
   int half = ref->scale / 2;

   for (int my = 0; my < ref->modules; ++my) {
      int py = ref->origin_y + my * ref->scale + half;
      if ((py < 0) || (py >= height)) {
         continue;
      }

      for (int mx = 0; mx < ref->modules; ++mx) {
         int px = ref->origin_x + mx * ref->scale + half;
         if ((px < 0) || (px >= width)) {
            continue;
         }

         uint8_t dark = (gray[(long)py * width + px] < QR_THRESHOLD) ? 1 : 0;
         if (dark != ref->grid[my * ref->modules + mx]) {
            errors += 1;
         }
      }
   }
   return errors;
}


bool qr_build(QrRef* ref, const char* text) {
   try {
      qrcodegen::QrCode qr = qrcodegen::QrCode::encodeText(text, qrcodegen::QrCode::Ecc::MEDIUM);

      int n = qr.getSize();
      if ((n <= 0) || (n > QR_MAX_MODULES)) {
         return false;
      }

      ref->modules = n;
      for (int y = 0; y < n; ++y) {
         for (int x = 0; x < n; ++x) {
            ref->grid[y * n + x] = qr.getModule(x, y) ? 1 : 0;
         }
      }
      return true;

   } catch (...) {
      return false;  // data too long or invalid arguments 
   }
}

