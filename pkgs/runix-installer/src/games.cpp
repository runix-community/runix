#include "games.hpp"

#include <algorithm>

#include "bricks.hpp"
#include "fetch.hpp"
#include "snake.hpp"
#include "util.hpp"

namespace games {

Frame::Frame(int width_, int height_)
    : width(std::max(width_, 0)), height(std::max(height_, 0)),
      cells(static_cast<std::size_t>(width * height)) {}

Cell& Frame::at(int x, int y) {
    // Writes off the board land here and are never drawn.
    static thread_local Cell outside;
    if (x < 0 || y < 0 || x >= width || y >= height) {
        outside = {};
        return outside;
    }
    return cells[static_cast<std::size_t>(y * width + x)];
}

void Frame::text(int x, int y, const std::string& value, Role role, bool bold) {
    std::size_t start = 0;
    int column = x;
    while (start < value.size()) {
        std::size_t end = start + 1;
        while (end < value.size() && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) ++end;
        at(column++, y) = {value.substr(start, end - start), role, bold};
        start = end;
    }
}

std::string package_name(const std::string& activity) {
    std::string name = activity;
    auto space = name.find(' ');
    if (space != std::string::npos) name = name.substr(space + 1);
    auto detail = name.find(" (");
    if (detail != std::string::npos) name = name.substr(0, detail);
    return util::trim(name);
}

namespace {

/// The snake game in the hub. Every board cell is two columns wide, so the
/// board looks square on the console.
class Snake : public Game {
public:
    Snake(int width, int height, std::uint32_t seed) : game_(std::max(width / 2, 8), std::max(height, 4), seed) {}

    void input(Input input) override {
        switch (input) {
            case Input::Up: game_.turn(snake::Direction::Up); break;
            case Input::Down: game_.turn(snake::Direction::Down); break;
            case Input::Left: game_.turn(snake::Direction::Left); break;
            case Input::Right: game_.turn(snake::Direction::Right); break;
            case Input::Restart:
                if (game_.over()) game_.restart();
                break;
            case Input::Action: break;
        }
    }

    void update(double seconds) override {
        constexpr double interval = 0.11;
        elapsed_ = std::min(elapsed_ + seconds, interval * 3);
        while (elapsed_ >= interval) {
            elapsed_ -= interval;
            game_.step();
        }
    }

    // Each package Nix finishes drops a bonus pellet.
    void package(const std::string& name) override {
        (void)name;
        game_.add_food();
    }

    Frame frame() const override {
        Frame frame(game_.width() * 2, game_.height());
        for (int y = 0; y < game_.height(); ++y) {
            for (int x = 0; x < game_.width(); ++x) {
                frame.at(x * 2, y) = {" ", Role::Muted, false};
                frame.at(x * 2 + 1, y) = {"·", Role::Muted, false};
            }
        }
        for (const auto& point : game_.food()) {
            frame.at(point.x * 2, point.y) = {"▐", Role::Warn, true};
            frame.at(point.x * 2 + 1, point.y) = {"▌", Role::Warn, true};
        }
        bool head = true;
        for (const auto& point : game_.body()) {
            Cell cell{"█", head ? Role::Light : Role::Accent, head};
            frame.at(point.x * 2, point.y) = cell;
            frame.at(point.x * 2 + 1, point.y) = cell;
            head = false;
        }
        frame.status = "score " + std::to_string(game_.score()) + "   each package Nix finishes drops a pellet";
        if (game_.won()) {
            frame.banner = " The board is full. You win! ";
            frame.banner_role = Role::Accent;
        } else if (game_.over()) {
            frame.banner = " Game over · r to play again ";
            frame.banner_role = Role::Error;
        }
        return frame;
    }

    bool over() const override { return game_.over(); }
    int score() const override { return game_.score(); }
    void restart() override { game_.restart(); }

    std::vector<std::pair<std::string, std::string>> hints() const override {
        if (game_.over()) return {{"r", "play again"}, {"esc", "games"}};
        return {{"arrows", "steer"}, {"esc", "games"}};
    }

private:
    snake::Game game_;
    double elapsed_ = 0;
};

template <typename T>
std::unique_ptr<Game> make(int width, int height, std::uint32_t seed) {
    return std::make_unique<T>(width, height, seed);
}

}  // namespace

const std::vector<Entry>& catalog() {
    static const std::vector<Entry> entries{
        {"Snake", "eat, grow, and stay off the walls", make<Snake>},
        {"Fetch", "catch the packages Nix is installing, let broken ones fall", make<Fetch>},
        {"Bricks", "break the wall; real 2D physics, debris and all", make<Bricks>},
    };
    return entries;
}

}  // namespace games
