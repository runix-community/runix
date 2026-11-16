#include "fetch.hpp"
#include "i18n.hpp"

#include <algorithm>
#include <array>

#include "util.hpp"

namespace games {

namespace {

// Between real packages from the install, some Runix regulars fall too.
constexpr std::array<const char*, 18> regulars{
    "glibc",   "bash",      "coreutils", "runit",   "mdevd",      "nix",
    "zwwm",    "blxshell",  "openssl",   "zlib",    "util-linux", "ncurses",
    "mesa",    "pipewire",  "wayland",   "libinput", "fish",      "limine",
};
// Things no one wants in their store.
constexpr std::array<const char*, 5> breakage{
    "hash mismatch", "404 not found", "corrupt nar", "untrusted sig", "infinite recursion",
};
constexpr std::size_t longest_name = 18;
constexpr std::size_t queue_limit = 24;

}  // namespace

Fetch::Fetch(int width, int height, std::uint32_t seed)
    : columns_(std::max(width, 24)), rows_(std::max(height, 6)), random_(seed) {
    restart();
}

void Fetch::restart() {
    items_.clear();
    score_ = 0;
    lives_ = 3;
    over_ = false;
    basket_x_ = (columns_ - basket_width_) / 2;
    spawn_timer_ = 0.5;
    message_.clear();
}

double Fetch::fall_speed() const {
    // Rows per second, quicker as the score climbs.
    return std::min(3.0 + score_ * 0.12, 9.0);
}

void Fetch::say(std::string message) {
    message_ = std::move(message);
    message_timer_ = 2.5;
}

void Fetch::drop(const std::string& name, bool broken, double x) {
    std::string label = "[" + util::take(name, longest_name) + "]";
    double widest = columns_ - static_cast<double>(util::width(label));
    items_.push_back({label, std::clamp(x, 0.0, std::max(widest, 0.0)), 0, broken});
}

void Fetch::spawn() {
    std::uniform_real_distribution<double> chance(0, 1);
    std::uniform_real_distribution<double> column(0, columns_);
    if (chance(random_) < 0.18) {
        std::uniform_int_distribution<std::size_t> pick(0, breakage.size() - 1);
        drop(breakage[pick(random_)], true, column(random_));
        return;
    }
    std::string name;
    if (!queue_.empty()) {
        name = queue_.front();
        queue_.pop_front();
    } else {
        std::uniform_int_distribution<std::size_t> pick(0, regulars.size() - 1);
        name = regulars[pick(random_)];
    }
    drop(name, false, column(random_));
}

void Fetch::package(const std::string& name) {
    if (name.empty()) return;
    queue_.push_back(name);
    if (queue_.size() > queue_limit) queue_.pop_front();
}

void Fetch::input(Input input) {
    switch (input) {
        case Input::Left:
            basket_x_ = std::max(basket_x_ - 3, 0);
            break;
        case Input::Right:
            basket_x_ = std::min(basket_x_ + 3, columns_ - basket_width_);
            break;
        case Input::Restart:
            if (over_) restart();
            break;
        default:
            break;
    }
}

void Fetch::update(double seconds) {
    if (over_) return;
    seconds = std::clamp(seconds, 0.0, 0.1);
    if (message_timer_ > 0) message_timer_ -= seconds;

    spawn_timer_ -= seconds;
    if (spawn_timer_ <= 0) {
        spawn();
        // A package fetched by Nix arrives sooner than a filler one.
        spawn_timer_ = std::max(0.55, (queue_.empty() ? 1.6 : 1.0) - score_ * 0.02);
    }

    const double basket_row = rows_ - 1;
    const double speed = fall_speed();
    for (auto item = items_.begin(); item != items_.end();) {
        double before = item->y;
        item->y += speed * seconds;
        bool reached = before < basket_row && item->y >= basket_row;
        double centre = item->x + util::width(item->label) / 2.0;
        bool inside = centre >= basket_x_ && centre < basket_x_ + basket_width_;
        if (reached && inside) {
            if (item->broken) {
                --lives_;
                say(i18n::format("caught {}, that one was broken", {item->label}));
            } else {
                ++score_;
                say(i18n::format("fetched {}", {item->label}));
            }
            item = items_.erase(item);
        } else if (item->y >= rows_) {
            if (!item->broken) {
                --lives_;
                say(i18n::format("missed {}", {item->label}));
            }
            item = items_.erase(item);
        } else {
            ++item;
        }
        if (lives_ <= 0) {
            over_ = true;
            return;
        }
    }
}

Frame Fetch::frame() const {
    Frame frame(columns_, rows_);
    for (const auto& item : items_) {
        frame.text(static_cast<int>(item.x), static_cast<int>(item.y), item.label,
                   item.broken ? Role::Error : Role::Cyan, item.broken);
    }
    std::string basket = "└" + util::repeat("─", static_cast<std::size_t>(basket_width_ - 2)) + "┘";
    frame.text(basket_x_, rows_ - 1, basket, Role::Accent, true);
    std::string hearts;
    for (int heart = 0; heart < lives_; ++heart) hearts += "♥";
    frame.status = i18n::format("fetched {}", {std::to_string(score_)}) + "   " + hearts;
    frame.status += "   " + (message_timer_ > 0 ? message_ : tr("red ones are broken, let them fall"));
    if (over_) {
        frame.banner = " " + tr("Game over · r to play again") + " ";
        frame.banner_role = Role::Error;
    }
    return frame;
}

std::vector<std::pair<std::string, std::string>> Fetch::hints() const {
    if (over_) return {{"r", N_("play again")}, {"esc", N_("games")}};
    return {{"left/right", N_("move the basket")}, {"esc", N_("games")}};
}

}  // namespace games
