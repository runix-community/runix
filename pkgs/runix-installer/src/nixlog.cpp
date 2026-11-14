#include "nixlog.hpp"

#include <algorithm>
#include <vector>

#include "json.hpp"
#include "util.hpp"

namespace nixlog {

namespace {

constexpr std::string_view prefix = "@nix ";
constexpr std::string_view store = "/nix/store/";
constexpr std::size_t hash_length = 32;

// Nix's lvlInfo. Talkative and chattier messages stay out of the log.
constexpr std::int64_t loudest_level = 3;

std::string first_string(const json::Value& fields) {
    return fields[0].string().value_or("");
}

}  // namespace

std::string clean(const std::string& text) {
    std::string out;
    for (std::size_t i = 0; i < text.size(); ++i) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c == 0x1B && i + 1 < text.size()) {
            char kind = text[i + 1];
            if (kind == '[') {
                i += 2;
                while (i < text.size() && !(text[i] >= 0x40 && text[i] <= 0x7E)) ++i;
            } else if (kind == ']') {
                i += 2;
                while (i < text.size() && text[i] != '\a' &&
                       !(text[i] == 0x1B && i + 1 < text.size() && text[i + 1] == '\\')) {
                    ++i;
                }
                if (i < text.size() && text[i] == 0x1B) ++i;
            } else {
                ++i;
            }
            continue;
        }
        if (c == '\t') {
            out += ' ';
        } else if (c >= 0x20 && c != 0x7F) {
            out += static_cast<char>(c);
        }
    }
    return out;
}

std::string store_name(const std::string& text) {
    std::size_t start = text.find(store);
    if (start == std::string::npos) return text;
    start += store.size();
    std::size_t end = text.find_first_of("'\" /", start);
    std::string name = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (name.size() > hash_length + 1 && name[hash_length] == '-') name = name.substr(hash_length + 1);
    if (name.size() > 4 && name.compare(name.size() - 4, 4, ".drv") == 0) name.resize(name.size() - 4);
    return name;
}

std::optional<std::string> Tracker::feed(const std::string& line) {
    if (line.compare(0, prefix.size(), prefix) != 0) {
        return clean(line);
    }
    auto message = json::parse(std::string_view(line).substr(prefix.size()));
    if (!message || !message->is_object()) return clean(line);
    const auto& value = *message;
    std::string action = value["action"].string().value_or("");
    std::uint64_t id = value["id"].unsigned_number().value_or(0);

    if (action == "msg") {
        if (value["level"].integer().value_or(0) > loudest_level) return std::nullopt;
        std::string text = clean(value["msg"].string().value_or(""));
        return text.empty() ? std::nullopt : std::optional(text);
    }

    if (action == "start") {
        Activity activity;
        activity.type = static_cast<int>(value["type"].integer().value_or(0));
        activity.order = ++order_;
        const auto& fields = value["fields"];
        std::string text = value["text"].string().value_or("");
        switch (activity.type) {
            case Build:
                activity.label = "building " + store_name(fields.is_array() ? first_string(fields) : text);
                break;
            case Substitute:
            case CopyPath:
                activity.label = "fetching " + store_name(fields.is_array() ? first_string(fields) : text);
                break;
            default:
                break;
        }
        activities_[id] = activity;
        // One line per package keeps the log readable; byte transfers are not logged.
        if (activity.type == Build || activity.type == Substitute) return activity.label;
        return std::nullopt;
    }

    if (action == "stop") {
        auto found = activities_.find(id);
        if (found != activities_.end()) {
            stop(found->second);
            activities_.erase(found);
        }
        return std::nullopt;
    }

    if (action == "result") {
        int type = static_cast<int>(value["type"].integer().value_or(0));
        const auto& fields = value["fields"];
        auto found = activities_.find(id);
        switch (type) {
            case BuildLogLine:
            case PostBuildLogLine: {
                std::string text = clean(first_string(fields));
                return text.empty() ? std::nullopt : std::optional("  " + text);
            }
            case Progress:
                if (found != activities_.end()) {
                    auto number = [&](std::size_t index) { return fields[index].unsigned_number().value_or(0); };
                    found->second.progress = Counts{number(0), number(1), number(2), number(3)};
                }
                return std::nullopt;
            case SetExpected:
                if (found != activities_.end()) {
                    int of = static_cast<int>(fields[0].integer().value_or(0));
                    found->second.expected[of] = fields[1].unsigned_number().value_or(0);
                }
                return std::nullopt;
            case SetPhase:
                if (found != activities_.end() && found->second.type == Build) {
                    std::string& label = found->second.label;
                    label = label.substr(0, label.find(" (")) + " (" + first_string(fields) + ")";
                }
                return std::nullopt;
            default:
                return std::nullopt;
        }
    }
    return std::nullopt;
}

void Tracker::stop(const Activity& activity) {
    Counts& total = stopped_[activity.type];
    total.done += activity.progress.done;
    total.expected += activity.progress.expected;
    total.failed += activity.progress.failed;
    for (const auto& [type, amount] : activity.expected) stopped_expected_[type] += amount;
}

void Tracker::reset() {
    for (const auto& [id, activity] : activities_) stop(activity);
    activities_.clear();
}

Counts Tracker::counts(int type) const {
    Counts total;
    if (auto found = stopped_.find(type); found != stopped_.end()) total = found->second;
    total.running = 0;
    for (const auto& [id, activity] : activities_) {
        if (activity.type != type) continue;
        total.done += activity.progress.done;
        total.expected += activity.progress.expected;
        total.running += activity.progress.running;
        total.failed += activity.progress.failed;
    }
    return total;
}

std::uint64_t Tracker::bytes(int type) const {
    return counts(type).done;
}

std::uint64_t Tracker::expected_bytes(int type) const {
    std::uint64_t total = 0;
    if (auto found = stopped_expected_.find(type); found != stopped_expected_.end()) total = found->second;
    for (const auto& [id, activity] : activities_) {
        if (auto amount = activity.expected.find(type); amount != activity.expected.end()) total += amount->second;
    }
    return total;
}

std::optional<double> Tracker::fraction() const {
    Counts built = builds();
    Counts fetched = paths();
    std::uint64_t expected = built.expected + fetched.expected;
    if (expected == 0) return std::nullopt;
    double done = static_cast<double>(built.done + fetched.done);
    return std::clamp(done / static_cast<double>(expected), 0.0, 1.0);
}

std::string Tracker::summary() const {
    std::vector<std::string> parts;
    Counts built = builds();
    Counts fetched = paths();
    if (built.expected > 0) {
        std::string part = std::to_string(built.done) + "/" + std::to_string(built.expected) + " built";
        if (built.failed > 0) part += ", " + std::to_string(built.failed) + " failed";
        parts.push_back(part);
    }
    if (fetched.expected > 0) {
        parts.push_back(std::to_string(fetched.done) + "/" + std::to_string(fetched.expected) + " fetched");
    }
    std::uint64_t down = downloaded();
    std::uint64_t total = download_expected();
    if (down > 0 && total >= down) {
        parts.push_back(util::format_size(down) + " of " + util::format_size(total) + " downloaded");
    } else if (down > 0) {
        parts.push_back(util::format_size(down) + " downloaded");
    }
    std::string text;
    for (const auto& part : parts) {
        if (!text.empty()) text += "  ·  ";
        text += part;
    }
    return text;
}

std::string Tracker::current() const {
    const Activity* latest = nullptr;
    std::size_t busy = 0;
    for (const auto& [id, activity] : activities_) {
        if (activity.label.empty()) continue;
        // A substitution owns a copy of the same path; count the path once.
        if (activity.type == CopyPath) continue;
        ++busy;
        if (!latest || activity.order > latest->order) latest = &activity;
    }
    if (!latest) return "";
    if (busy > 1) return latest->label + "  (+" + std::to_string(busy - 1) + " more)";
    return latest->label;
}

}  // namespace nixlog
