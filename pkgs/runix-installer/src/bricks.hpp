// Bricks: a paddle, a ball and a wall to break, on the XPBD solver. Broken
// bricks shatter into debris pairs held by soft links, which tumble under
// gravity; catching debris with the paddle scores too.
//
// World units: x in console columns, y in half rows, since a console cell is
// about twice as tall as it is wide. That keeps the ball round.
#pragma once

#include <random>
#include <vector>

#include "games.hpp"
#include "xpbd.hpp"

namespace games {

class Bricks : public Game {
public:
    Bricks(int width, int height, std::uint32_t seed);

    void input(Input input) override;
    void update(double seconds) override;
    Frame frame() const override;
    bool over() const override { return over_; }
    int score() const override { return score_; }
    void restart() override;
    std::vector<std::pair<std::string, std::string>> hints() const override;

    // For tests.
    const xpbd::World& world() const { return world_; }
    xpbd::World& world() { return world_; }
    int lives() const { return lives_; }
    int level() const { return level_; }
    bool served() const { return served_; }
    int bricks_left() const;
    double paddle_x() const { return paddle_x_; }
    double ball_speed() const { return speed_; }

private:
    int columns_;
    int rows_;
    std::mt19937 random_;
    xpbd::World world_;
    /// Colour of each box (index 0 is the paddle) and each particle.
    std::vector<Role> box_roles_;
    std::vector<Role> particle_roles_;
    double paddle_x_ = 0;
    double paddle_speed_ = 0;
    double paddle_hold_ = 0;
    double paddle_half_ = 4.5;
    double speed_ = 26;
    int score_ = 0;
    int lives_ = 3;
    int level_ = 1;
    bool served_ = false;
    bool over_ = false;

    double paddle_top() const;
    void build_level();
    void place_paddle(double seconds);
    void hold_ball();
    void serve();
    void bounce_off_paddle();
    void keep_ball_speed();
    void shatter(std::size_t box);
    void drop(std::size_t particle);
    void compact();
};

}  // namespace games
