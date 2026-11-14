#include "util.hpp"

#include <array>
#include <cstdio>

namespace util {

std::string format_size(std::uint64_t bytes) {
    static constexpr std::array<const char*, 5> units{"B", "KiB", "MiB", "GiB", "TiB"};
    double value = static_cast<double>(bytes);
    std::size_t unit = 0;
    while (value >= 1024.0 && unit + 1 < units.size()) {
        value /= 1024.0;
        ++unit;
    }
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%.1f %s", value, units[unit]);
    return buffer;
}

std::string percent(std::uint64_t part, std::uint64_t total) {
    if (total == 0) return "0%";
    auto permille = static_cast<std::uint64_t>(static_cast<unsigned __int128>(part) * 1000 / total);
    if (permille == 0 && part > 0) return "<0.1%";
    return std::to_string(permille / 10) + "." + std::to_string(permille % 10) + "%";
}

std::string trim(std::string_view text) {
    auto space = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
    std::size_t start = 0;
    std::size_t end = text.size();
    while (start < end && space(text[start])) ++start;
    while (end > start && space(text[end - 1])) --end;
    return std::string(text.substr(start, end - start));
}

std::vector<std::string> split(std::string_view text, char separator) {
    std::vector<std::string> parts;
    std::size_t start = 0;
    while (true) {
        std::size_t end = text.find(separator, start);
        if (end == std::string_view::npos) {
            parts.emplace_back(text.substr(start));
            return parts;
        }
        parts.emplace_back(text.substr(start, end - start));
        start = end + 1;
    }
}

std::string lower(std::string_view text) {
    std::string out(text);
    for (char& c : out) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return out;
}

bool contains(std::string_view text, std::string_view part) {
    return text.find(part) != std::string_view::npos;
}

static bool continuation(char c) {
    return (static_cast<unsigned char>(c) & 0xC0) == 0x80;
}

std::size_t width(std::string_view text) {
    std::size_t count = 0;
    for (char c : text) {
        if (!continuation(c)) ++count;
    }
    return count;
}

std::string take(std::string_view text, std::size_t count) {
    std::size_t seen = 0;
    for (std::size_t i = 0; i < text.size(); ++i) {
        if (!continuation(text[i])) {
            if (seen == count) return std::string(text.substr(0, i));
            ++seen;
        }
    }
    return std::string(text);
}

std::string fit(std::string_view text, std::size_t count) {
    if (width(text) <= count) return pad_right(text, count);
    if (count < 4) return take(text, count);
    return take(text, count - 4) + "... ";
}

std::string pad_left(std::string_view text, std::size_t count) {
    std::size_t length = width(text);
    return (length < count ? std::string(count - length, ' ') : std::string()) + std::string(text);
}

std::string pad_right(std::string_view text, std::size_t count) {
    std::size_t length = width(text);
    return std::string(text) + (length < count ? std::string(count - length, ' ') : std::string());
}

std::string repeat(std::string_view text, std::size_t count) {
    std::string out;
    out.reserve(text.size() * count);
    for (std::size_t i = 0; i < count; ++i) out += text;
    return out;
}

std::vector<std::string> wrap(std::string_view text, std::size_t count) {
    std::vector<std::string> lines;
    if (count == 0) return lines;
    for (const auto& paragraph : split(text, '\n')) {
        std::string line;
        for (const auto& word : split(paragraph, ' ')) {
            std::string piece = word;
            while (width(piece) > count) {
                if (!line.empty()) {
                    lines.push_back(line);
                    line.clear();
                }
                lines.push_back(take(piece, count));
                piece = piece.substr(take(piece, count).size());
            }
            if (line.empty()) {
                line = piece;
            } else if (width(line) + 1 + width(piece) <= count) {
                line += " " + piece;
            } else {
                lines.push_back(line);
                line = piece;
            }
        }
        lines.push_back(line);
    }
    return lines;
}

}  // namespace util
