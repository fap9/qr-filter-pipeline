/**
 * \file main.cpp
 * \brief Measurement loop comparing the software chain against the PL pipeline.
 *
 * For every noise level and repetition the same noisy frame is fed to both
 * paths, so the comparison never depends on the noise being reproducible.
 * Results are printed as CSV lines that can be pasted into the report.
 *
 * Bare metal, Vitis, standalone on ps7_cortexa9_0. Build with -O2, otherwise
 * the software timings measure the debug build.
 */

#include "sw_filters.hpp"
#include "qr_image.hpp"

#include "xparameters.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include <unistd.h>


// --- frame geometry, must match the generics of axis_filter_top ----------- 

#define W 640
#define H 480
#define RGB_BYTES ((long)W * H * 3)
#define GRAY_BYTES ((long)W * H)


// --- experiment parameters ------------------------------------------------ 

static const int NOISE_LEVELS[] = { 0, 5, 10, 20, 30, 35, 40, 45, 50 };
#define NOISE_COUNT ((int)(sizeof(NOISE_LEVELS) / sizeof(NOISE_LEVELS[0])))
#define REPEATS 10
// payload of the QR code, kept short so version 3 is enough 
#define QR_TEXT "ZYNQ7000-PL-FILTER-PIPELINE"


// --- AXI VDMA, register offsets from document PG020 -------------------------------- 
#define VDMA_BASE XPAR_AXI_VDMA_0_BASEADDR  // VDMA registers
// DMACR... = controller register; DMASR... = state register (1 reg has 32 bit)
#define MM2S_DMACR 0x00
#define MM2S_DMASR 0x04
#define S2MM_DMACR 0x30
#define S2MM_DMASR 0x34
// image geometry
#define MM2S_VSIZE 0x50  
#define MM2S_HSIZE 0x54
#define S2MM_VSIZE 0xA0
#define S2MM_HSIZE 0xA4
// distance between two image rows
#define MM2S_FRMDLY_STRIDE 0x58  
#define S2MM_FRMDLY_STRIDE 0xA8
// start of frame buffer
#define MM2S_START_ADDR1 0x5C
#define S2MM_START_ADDR1 0xAC
// bit mask for controlling and status 
#define DMACR_RS 0x00000001u // run, cleared for stop 
#define DMACR_RESET 0x00000004u // self clearing soft reset 
#define DMASR_HALTED 0x00000001u  // channel is stopped
#define DMASR_IDLE 0x00000002u  // transfer ready (target of polling)
#define DMASR_ERRORS 0x00000070u // internal, slave and decode error

#define POLL_LIMIT 40000000u // roughly a 2 second at 667 MHz, then give up 


// Buffers: Xil_DCacheInvalidateRange works 32 Byte cache lines, unaligned range would discard neighbouring data
static uint8_t rgb_src[RGB_BYTES] __attribute__((aligned(32)));
static uint8_t sw_out[GRAY_BYTES] __attribute__((aligned(32)));
static uint8_t hw_out[GRAY_BYTES] __attribute__((aligned(32)));
static uint8_t tmp_gray[GRAY_BYTES] __attribute__((aligned(32)));
static uint8_t tmp_med[GRAY_BYTES] __attribute__((aligned(32)));

static QrRef qr_ref;


// --- helpers -------------------------------------------------------------- 
/// \brief Convert a timer interval to microseconds.
static uint32_t to_us(XTime start, XTime end) {
   return (uint32_t)(((uint64_t)(end - start) * 1000000u) / COUNTS_PER_SECOND);
}
/// \brief Write to VDMA.
static void vdma_write(uint32_t offset, uint32_t value) {
   Xil_Out32(VDMA_BASE + offset, value);
}
/// \brief Read from VDMA.
static uint32_t vdma_read(uint32_t offset) {
   return Xil_In32(VDMA_BASE + offset);
}

//// \brief Soft reset both channels and wait until the bits clear.
static bool vdma_reset() {
   vdma_write(MM2S_DMACR, DMACR_RESET);
   vdma_write(S2MM_DMACR, DMACR_RESET);

   for (uint32_t i = 0; i < POLL_LIMIT; ++i) {
      bool mm2s = (vdma_read(MM2S_DMACR) & DMACR_RESET) == 0;
      bool s2mm = (vdma_read(S2MM_DMACR) & DMACR_RESET) == 0;
      if (mm2s && s2mm) {
         return true;
      }
   }
   return false;
}

/**
 * \brief Launch one frame through the PL pipeline.
 * \param src RGB888 source in DDR
 * \param dst Gray8 destination in DDR
 */
static void vdma_start_frame(const uint8_t* src, uint8_t* dst) {
   vdma_write(S2MM_DMACR, DMACR_RS);
   vdma_write(S2MM_START_ADDR1, (uint32_t)(uintptr_t)dst);
   vdma_write(S2MM_FRMDLY_STRIDE, W);
   vdma_write(S2MM_HSIZE, W);
   // Starts Write Channel; see PG020 p.34 "This register must be written last for a particular channel" 
   vdma_write(S2MM_VSIZE, H);  

   vdma_write(MM2S_DMACR, DMACR_RS);
   vdma_write(MM2S_START_ADDR1, (uint32_t)(uintptr_t)src);
   vdma_write(MM2S_FRMDLY_STRIDE, W * 3);
   vdma_write(MM2S_HSIZE, W * 3);
   // Starts Read Channel; see PG020 p.31 "This register must be written last for a particular channel" 
   vdma_write(MM2S_VSIZE, H);
}

/**
 * \brief Poll until the write channel reports idle.
 * \return false on timeout or on a VDMA error flag
 */
static bool vdma_wait_done() {
   for (uint32_t i = 0; i < POLL_LIMIT; ++i) {
      uint32_t status = vdma_read(S2MM_DMASR);

      if ((status & DMASR_ERRORS) != 0) {
         xil_printf("VDMA error, S2MM_DMASR = 0x%08x\r\n", status);
         return false;
      }
      if ((status & (DMASR_IDLE | DMASR_HALTED)) != 0) {
         return true;
      }
   }
   xil_printf("VDMA timeout, S2MM_DMASR = 0x%08x\r\n", vdma_read(S2MM_DMASR));
   return false;
}



// --- main ----------------------------------------------------------------- 

int main() {      
   sleep(2);
   Xil_DCacheEnable();
   xil_printf("\r\n=== QR filter pipeline, PS vs PL ===\n\r");



   if (!qr_build(&qr_ref, QR_TEXT)) {
      xil_printf("QR encoding failed, check the heap size in lscript.ld\r\n");
      return 1;
   }
   if (!qr_place(&qr_ref, W, H, 0)) {
      xil_printf("QR does not fit into %dx%d\r\n", W, H);
      return 1;
   }
   print("In vdma_reset.\n");
   if (!vdma_reset()) {
      xil_printf("VDMA reset did not complete\r\n");
      return 1;
   }

   int total_modules = qr_ref.modules * qr_ref.modules;
   xil_printf("modules %d x %d, scale %d px, origin %d/%d\r\n",
              qr_ref.modules, qr_ref.modules, qr_ref.scale, qr_ref.origin_x, qr_ref.origin_y);
   xil_printf("CSV noise,run,us_sw,us_hw,us_hw_cached, err_raw,err_sw,err_hw,modules,diff_strict,diff_total\r\n");

   for (int n = 0; n < NOISE_COUNT; ++n) {
      int noise = NOISE_LEVELS[n];

      for (int run = 0; run < REPEATS; ++run) {

         // test frame; seed depends on level and run, every frame is different but reproducible
         qr_render(&qr_ref, rgb_src, W, H);
         qr_add_salt_pepper(rgb_src, W, H, noise, (uint32_t)(0x1000 + n * 97 + run));

         // ----- software Pipeline 
         XTime t_sw0, t_sw1;
         XTime_GetTime(&t_sw0);
         sw_pipeline(rgb_src, sw_out, tmp_gray, tmp_med, W, H);
         XTime_GetTime(&t_sw1);

         // tmp_gray holds rgb2gray output, so the unfiltered baseline costs no extra pass
         int err_raw = qr_count_module_errors(&qr_ref, tmp_gray, W, H);  // false modules without filtering
         int err_sw = qr_count_module_errors(&qr_ref, sw_out, W, H);  // false modules after median and gsauss


         // ----- hardware pipeline 
         XTime t_fl0, t_fl1, t_hw0, t_hw1, t_iv0, t_iv1;

         // from Cach to DDR
         XTime_GetTime(&t_fl0);
         Xil_DCacheFlushRange((INTPTR)rgb_src, RGB_BYTES);
         XTime_GetTime(&t_fl1);
         // put image through the window
         XTime_GetTime(&t_hw0);
         vdma_start_frame(rgb_src, hw_out);
         bool ok = vdma_wait_done();
         XTime_GetTime(&t_hw1);
         // get DDR image into cache
         XTime_GetTime(&t_iv0);
         Xil_DCacheInvalidateRange((INTPTR)hw_out, GRAY_BYTES);
         XTime_GetTime(&t_iv1);

         if (!ok) {
            xil_printf("aborting at noise %d run %d\r\n", noise, run);
            return 1;
         }

         // equivalence of the two paths 
         int err_hw = qr_count_module_errors(&qr_ref, hw_out, W, H);
         SwDiff diff;
         sw_compare(sw_out, hw_out, W, H, 2, 2, &diff);
         xil_printf("CSV %d,%d,%u,%u,%u,%d,%d,%d,%d,%d,%d\r\n",
                    noise, run,
                    to_us(t_sw0, t_sw1),
                    to_us(t_hw0, t_hw1),
                    to_us(t_hw0, t_hw1) + to_us(t_fl0, t_fl1) + to_us(t_iv0, t_iv1),
                    err_raw, err_sw, err_hw, total_modules,
                    diff.strict, diff.total);
      }
   }

   xil_printf("=== done ===\n\r");
   return 0;
}
