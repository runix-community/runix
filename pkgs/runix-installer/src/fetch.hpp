// Fetch: catch the packages Nix is installing as they fall, and dodge the
// broken ones. Real package names arrive from the install as Nix finishes them;
// between them, familiar ones fill in.
#pragma once

#include <deque>
#include <random>
#include <string>
#include <vector>

#include "games.hpp"

namespace games {

class Fetch : public Game {
public:
    Fetch(int width, int height, std::uint32_t seed);

    void input(Input input) override;
    void update(double seconds) override;
    void package(const std::string& name) override;
    Frame frame() const override;
    bool over() const override { return over_; }
    int score() const override { return score_; }
    void restart() override;
    std::vector<std::pair<std::string, std::string>> hints() const override;

    struct Item {
        std::string label;
        double x = 0;
        double y = 0;
        bool broken = false;
    };

    // For tests.
    const std::vector<Item>& items() const { return items_; }
    int lives() const { return lives_; }
    int basket_x() const { return basket_x_; }
    int basket_width() const { return basket_width_; }
    std::size_t queued() const { return queue_.size(); }
    /// Drops a package at column x.
    void drop(const std::string& name, bool broken, double x);
    /// Stops the random drops, so only drop() adds packages.
    void stop_spawning() { spawn_timer_ = 1e9; }

private:
    int columns_;
    int rows_;
    std::mt19937 random_;
    std::vector<Item> items_;
    std::deque<std::string> queue_;
    int basket_x_ = 0;
    int basket_width_ = 11;
    double spawn_timer_ = 0.5;
    int score_ = 0;
    int lives_ = 3;
    bool over_ = false;
    std::string message_;
    double message_timer_ = 0;

    double fall_speed() const;
    void spawn();
    void say(std::string message);
};

}  // namespace games
