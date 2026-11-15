// Snake, playable while Nix installs the system. Pure game logic: no drawing
// and no clock, so it can be tested; the app steps it on a timer.
#pragma once

#include <cstdint>
#include <deque>
#include <random>
#include <vector>

namespace snake {

struct Point {
    int x = 0;
    int y = 0;
    bool operator==(const Point&) const = default;
};

enum class Direction { Up, Down, Left, Right };

class Game {
public:
    /// Most pellets on the board at once, counting bonus pellets.
    static constexpr std::size_t max_food = 5;

    Game(int width, int height, std::uint32_t seed);

    /// Queues a turn for the next steps. A turn straight back into the body
    /// is ignored, as are turns beyond two pending ones.
    void turn(Direction direction);
    /// Moves one cell: eats, grows, or ends the game on a wall or the body.
    void step();
    /// Drops a bonus pellet, if there is room and fewer than max_food.
    void add_food();
    /// Starts a new round; the best score is kept.
    void restart();
    /// Puts a pellet at a chosen cell (for tests).
    void place_food(Point point);

    int width() const { return width_; }
    int height() const { return height_; }
    const std::deque<Point>& body() const { return body_; }
    const std::vector<Point>& food() const { return food_; }
    int score() const { return score_; }
    int best() const { return best_; }
    bool over() const { return over_; }
    /// The snake filled the whole board.
    bool won() const { return won_; }
    bool occupied(Point point) const;

private:
    int width_;
    int height_;
    std::mt19937 random_;
    std::deque<Point> body_;
    std::vector<Point> food_;
    Direction direction_ = Direction::Right;
    std::deque<Direction> pending_;
    int score_ = 0;
    int best_ = 0;
    bool over_ = false;
    bool won_ = false;

    bool has_food(Point point) const;
    bool spawn_food();
};

}  // namespace snake
