/**
 * \file sw_filters.hpp
 * \brief Software path of the filter chain: rgb2gray -> median 3x3 -> gauss 3x3.
 *
 * Same arithmetic as the PL modules (rgb2gray.vhd, median.vhd, gauss.vhd). No Xilinx headers, so the same source builds on a PC
 * and under Vitis. Timing, cache handling and VDMA belong to the application layer. Border handling differs: software clamps 
 * on all four sides, the PL only on top and left.
 */
 
#ifndef SW_FILTERS_HPP
#define SW_FILTERS_HPP

#include <stdint.h>

// Pixel byte order in memory, 1 = B,G,R. VDMA puts lowest address on tdata[7:0], where axis_rgb2gray expects blue. if RGB change here.
#ifndef SW_PIXEL_ORDER_BGR
#define SW_PIXEL_ORDER_BGR 1
#endif

/**
 * \brief Store one RGB888 pixel in the order the PL expects.
 * \param pixel destination
 * \param r red
 * \param g green
 * \param b blue
 */
static inline void sw_store_rgb(uint8_t* pixel, uint8_t r, uint8_t g, uint8_t b) {
#if SW_PIXEL_ORDER_BGR
   pixel[0] = b;
   pixel[1] = g;
   pixel[2] = r;
#else
   pixel[0] = r;
   pixel[1] = g;
   pixel[2] = b;
#endif
}

/**
 * \brief RGB888 to Gray8, Y = (77R + 150G + 29B + 128) >> 8.
 * \param src 3*W*H bytes
 * \param dst W*H bytes
 * \param width pixels
 * \param height lines
 */
void sw_rgb2gray(const uint8_t* src, uint8_t* dst, int width, int height);

/**
 * \brief Median 3x3, same comparator network as median.vhd.
 * \param src input
 * \param dst output
 * \param width pixels
 * \param height lines
 */
void sw_median3x3(const uint8_t* src, uint8_t* dst, int width, int height);

/**
 * \brief Convolution with [1 2 1; 2 4 2; 1 2 1]/16, rounded via (sum + 8) >> 4.
 * \param src input
 * \param dst output
 * \param width pixels
 * \param height lines
 */
void sw_gauss3x3(const uint8_t* src, uint8_t* dst, int width, int height);

/**
 * \brief Full chain, caller supplies the scratch buffers.
 * \param rgb_src RGB888 frame
 * \param dst Gray8 result
 * \param tmp_gray scratch
 * \param tmp_med scratch
 * \param width pixels
 * \param height lines
 */
void sw_pipeline(const uint8_t* rgb_src, uint8_t* dst, uint8_t* tmp_gray, uint8_t* tmp_med, int width, int height);

/** \brief Result of a frame comparison. */
struct SwDiff {
   int total; /**< differing pixels, whole frame */
   int strict; /**< differing pixels inside the strict region */
   int max_dev; /**< largest deviation, whole frame */
   int max_dev_strict; /**< largest deviation, strict region */
   int first_x; /**< first strict mismatch, -1 if none */
   int first_y; /**< first strict mismatch, -1 if none */
};

/**
 * \brief Compare two Gray8 frames, excluding the PL border ring..
 *
 * \param ref reference
 * \param dut frame under test
 * \param width pixels
 * \param height lines
 * \param margin_right excluded columns
 * \param margin_bottom excluded lines
 * \param out report
 */
void sw_compare(const uint8_t* ref, const uint8_t* dut, int width, int height, int margin_right, int margin_bottom, SwDiff* out);


#endif /* SW_FILTERS_HPP */

