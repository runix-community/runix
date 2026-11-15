#include "snake.hpp"

#include <algorithm>

namespace snake {

namespace {

bool opposite(Direction a, Direction b) {
    return (a == Direction::Up && b == Direction::Down) || (a == Direction::Down && b == Direction::Up) ||
           (a == Direction::Left && b == Direction::Right) || (a == Direction::Right && b == Direction::Left);
}

Point moved(Point point, Direction direction) {
    switch (direction) {
        case Direction::Up: --point.y; break;
        case Direction::Down: ++point.y; break;
        case Direction::Left: --point.x; break;
        case Direction::Right: ++point.x; break;
    }
    return point;
}

}  // namespace

Game::Game(int width, int height, std::uint32_t seed)
    : width_(std::max(width, 4)), height_(std::max(height, 3)), random_(seed) {
    restart();
}

void Game::restart() {
    body_.clear();
    food_.clear();
    pending_.clear();
    direction_ = Direction::Right;
    score_ = 0;
    over_ = false;
    won_ = false;
    // Three cells in the middle, heading right; the head is at the front.
    Point head{width_ / 2, height_ / 2};
    for (int i = 0; i < 3; ++i) body_.push_back({head.x - i, head.y});
    spawn_food();
}

bool Game::occupied(Point point) const {
    return std::find(body_.begin(), body_.end(), point) != body_.end();
}

bool Game::has_food(Point point) const {
    return std::find(food_.begin(), food_.end(), point) != food_.end();
}

bool Game::spawn_food() {
    std::vector<Point> free;
    for (int y = 0; y < height_; ++y) {
        for (int x = 0; x < width_; ++x) {
            Point point{x, y};
            if (!occupied(point) && !has_food(point)) free.push_back(point);
        }
    }
    if (free.empty()) return false;
    std::uniform_int_distribution<std::size_t> pick(0, free.size() - 1);
    food_.push_back(free[pick(random_)]);
    return true;
}

void Game::place_food(Point point) {
    if (!occupied(point) && !has_food(point)) food_.push_back(point);
}

void Game::add_food() {
    if (!over_ && food_.size() < max_food) spawn_food();
}

void Game::turn(Direction direction) {
    if (over_ || pending_.size() >= 2) return;
    Direction last = pending_.empty() ? direction_ : pending_.back();
    if (direction == last || opposite(direction, last)) return;
    pending_.push_back(direction);
}

void Game::step() {
    if (over_) return;
    if (!pending_.empty()) {
        direction_ = pending_.front();
        pending_.pop_front();
    }
    Point head = moved(body_.front(), direction_);
    if (head.x < 0 || head.y < 0 || head.x >= width_ || head.y >= height_) {
        over_ = true;
        return;
    }
    auto eaten = std::find(food_.begin(), food_.end(), head);
    bool grows = eaten != food_.end();
    // The tail moves away this step unless the snake grows, so the head may
    // follow it into that cell.
    auto end = grows ? body_.end() : body_.end() - 1;
    if (std::find(body_.begin(), end, head) != end) {
        over_ = true;
        return;
    }
    body_.push_front(head);
    if (grows) {
        food_.erase(eaten);
        ++score_;
        best_ = std::max(best_, score_);
        if (static_cast<int>(body_.size()) == width_ * height_) {
            won_ = true;
            over_ = true;
            return;
        }
        if (food_.empty()) spawn_food();
    } else {
        body_.pop_back();
    }
}

}  // namespace snake
