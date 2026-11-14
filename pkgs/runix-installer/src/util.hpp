#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace util {

/// "512.0 GiB"
std::string format_size(std::uint64_t bytes);
/// "12.5%", or "<0.1%" for a sliver that would round to zero.
std::string percent(std::uint64_t part, std::uint64_t total);

std::string trim(std::string_view text);
std::vector<std::string> split(std::string_view text, char separator);
std::string lower(std::string_view text);
bool contains(std::string_view text, std::string_view part);

/// Characters, not bytes. Everything the UI prints is one column wide.
std::size_t width(std::string_view text);
/// The first `count` characters.
std::string take(std::string_view text, std::size_t count);
/// Pads with spaces, or cuts with "...", to exactly `count` characters.
std::string fit(std::string_view text, std::size_t count);
std::string pad_left(std::string_view text, std::size_t count);
std::string pad_right(std::string_view text, std::size_t count);
std::string repeat(std::string_view text, std::size_t count);

/// Breaks text into lines of at most `count` characters at spaces.
std::vector<std::string> wrap(std::string_view text, std::size_t count);

}  // namespace util
