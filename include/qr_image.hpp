/**
 * \file qr_image.hpp
 * \brief Test image generation and module level evaluation for the filter chain.
 *
 * Renders a QR module grid into an RGB888 frame, adds impulse noise, and counts
 * how many modules survive a filter run. Everything here is free of Xilinx and
 * of qrcodegen dependencies, so it builds on a host as well; only qr_build() in
 * qr_encode.cpp touches the encoder library.
 */
#ifndef QR_IMAGE_HPP
#define QR_IMAGE_HPP


#include <stdint.h>
#include "qrcodegen.hpp"


/// \brief Module grid side length for version 40, the largest QR code.
#define QR_MAX_MODULES 177
/// \brief Quiet zone width in modules, as required by the standard.
#define QR_QUIET_MODULES 4
/// \brief Grey level below which a pixel counts as dark. Fixed, not adaptive.
#define QR_THRESHOLD 128


/// \brief A QR module grid together with its placement in the frame.
struct QrRef {
   int modules; /**< side length in modules */
   int scale; /**< pixels per module */
   int origin_x; /**< leftmost pixel of module column 0 */
   int origin_y; /**< topmost pixel of module row 0 */
   uint8_t grid[QR_MAX_MODULES * QR_MAX_MODULES]; /**< 1 = dark, row major */
};

/**
 * \brief Encode text into a module grid; it allocates and should run once at start up.
 * \return false on encoder failure
 */
bool qr_build(QrRef* ref, const char* text);


/**
 * \brief Compute scale and origin so the grid fits centred with a quiet zone.
 * \return false if it does not fit
 */
bool qr_place(QrRef* ref, int width, int height, int scale);


/**
 * \brief Draw the grid into an RGB888 frame, quiet zone white.
 * \param ref placed grid
 * \param rgb 3*width*height bytes
 * \param width frame width
 * \param height frame height
 */
void qr_render(const QrRef* ref, uint8_t* rgb, int width, int height);


/**
 * \brief Add salt and pepper noise to an RGB888 frame.
 *
 * \param rgb frame, modified in place
 * \param width frame width
 * \param height frame height
 * \param percent share of affected pixels, 0 to 100
 * \param seed xorshift32 seed, must be non zero
 */
void qr_add_salt_pepper(uint8_t* rgb, int width, int height, int percent, uint32_t seed);


/**
 * \brief Count modules whose centre pixel has the wrong colour. Averaging would smooth the noise -> hide filters contributen.
 * \return number of wrong modules, out of modules*modules
 */
int qr_count_module_errors(const QrRef* ref, const uint8_t* gray, int width, int height);


#endif /* QR_IMAGE_HPP */
