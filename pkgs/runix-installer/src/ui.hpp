// Drawing only. One centered column under the Runix mark, one question per
// screen. Glyphs stay inside the Linux console's built-in font (box drawing,
// blocks, `·`, `■`) so nothing breaks if the larger console font fails to load.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

class App;

namespace ui {

/// Sets up color pairs. Call once after initscr.
void init_colors();
void draw(App& app);

/// Splits `width` cells between segments by size. Every non-empty segment
/// gets at least one cell, so a small boot partition never disappears.
std::vector<std::size_t> segment_cells(const std::vector<std::uint64_t>& sizes, std::size_t width);

}  // namespace ui
