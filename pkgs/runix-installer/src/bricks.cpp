#include "bricks.hpp"
#include "i18n.hpp"

#include <algorithm>
#include <cmath>

namespace games {

namespace {

constexpr double ball_radius = 0.5;
constexpr double debris_radius = 0.4;
constexpr double paddle_speed = 48;
/// How long one key press keeps the paddle moving; key repeat refreshes it.
constexpr double paddle_hold = 0.12;
constexpr std::size_t ball = 0;
constexpr std::size_t paddle = 0;

constexpr Role row_roles[] = {Role::Error, Role::Warn, Role::Accent, Role::Cyan, Role::Blue, Role::Magenta};

}  // namespace

Bricks::Bricks(int width, int height, std::uint32_t seed)
    : columns_(std::max(width, 20)), rows_(std::max(height, 8)), random_(seed) {
    world_.width = columns_;
    world_.height = rows_ * 2.0;
    paddle_half_ = std::max(3.5, columns_ / 10.0);
    restart();
}

double Bricks::paddle_top() const {
    return (rows_ - 1) * 2.0;
}

void Bricks::restart() {
    score_ = 0;
    lives_ = 3;
    level_ = 1;
    speed_ = 26;
    over_ = false;
    build_level();
}

void Bricks::build_level() {
    world_.particles.clear();
    world_.links.clear();
    world_.boxes.clear();
    box_roles_.clear();
    particle_roles_.clear();

    paddle_x_ = columns_ / 2.0;
    world_.boxes.push_back({{paddle_x_ - paddle_half_, paddle_top()}, {paddle_x_ + paddle_half_, paddle_top() + 1}, {}});
    box_roles_.push_back(Role::Light);

    // Rows of 4-column bricks with a one-column gap, from the second text row.
    int brick_rows = std::clamp(rows_ / 3, 2, 5);
    int count = (columns_ - 1) / 5;
    int left = (columns_ - (count * 5 - 1)) / 2;
    for (int row = 0; row < brick_rows; ++row) {
        double top = (row + 1) * 2.0;
        for (int index = 0; index < count; ++index) {
            double x = left + index * 5;
            world_.boxes.push_back({{x, top}, {x + 4, top + 2}, {}});
            box_roles_.push_back(row_roles[(row + level_ - 1) % std::size(row_roles)]);
        }
    }

    xpbd::Particle ball_particle;
    ball_particle.radius = ball_radius;
    ball_particle.gravity_scale = 0;
    ball_particle.restitution = 1;
    world_.particles.push_back(ball_particle);
    particle_roles_.push_back(Role::Light);
    served_ = false;
    hold_ball();
}

int Bricks::bricks_left() const {
    int count = 0;
    for (std::size_t index = 1; index < world_.boxes.size(); ++index) count += world_.boxes[index].alive ? 1 : 0;
    return count;
}

void Bricks::hold_ball() {
    auto& particle = world_.particles[ball];
    particle.position = {paddle_x_, paddle_top() - ball_radius - 0.05};
    particle.previous = particle.position;
    particle.velocity = {};
}

void Bricks::serve() {
    if (served_ || over_) return;
    served_ = true;
    std::uniform_real_distribution<double> side(-0.45, 0.45);
    xpbd::Vec direction{side(random_), -1};
    world_.particles[ball].velocity = direction * (speed_ / direction.length());
}

void Bricks::input(Input input) {
    switch (input) {
        case Input::Left:
            paddle_speed_ = -paddle_speed;
            paddle_hold_ = paddle_hold;
            break;
        case Input::Right:
            paddle_speed_ = paddle_speed;
            paddle_hold_ = paddle_hold;
            break;
        case Input::Up:
        case Input::Action:
            serve();
            break;
        case Input::Restart:
            if (over_) restart();
            break;
        case Input::Down:
            break;
    }
}

void Bricks::place_paddle(double seconds) {
    if (paddle_hold_ > 0) {
        paddle_hold_ -= seconds;
    } else {
        paddle_speed_ = 0;
    }
    double before = paddle_x_;
    paddle_x_ = std::clamp(paddle_x_ + paddle_speed_ * seconds, paddle_half_, columns_ - paddle_half_);
    auto& box = world_.boxes[paddle];
    box.min.x = paddle_x_ - paddle_half_;
    box.max.x = paddle_x_ + paddle_half_;
    // The paddle is kinematic: contacts take its real motion into account.
    box.velocity = {seconds > 0 ? (paddle_x_ - before) / seconds : 0, 0};
}

void Bricks::bounce_off_paddle() {
    // Where the ball lands on the paddle steers it, up to 60 degrees off vertical.
    auto& particle = world_.particles[ball];
    double offset = std::clamp((particle.position.x - paddle_x_) / paddle_half_, -1.0, 1.0);
    double angle = offset * (M_PI / 3);
    particle.velocity = {std::sin(angle) * speed_, -std::cos(angle) * speed_};
}

void Bricks::keep_ball_speed() {
    // Collisions may shave speed off; the game keeps it constant, and never
    // lets the ball settle into a near-horizontal path.
    auto& velocity = world_.particles[ball].velocity;
    double length = velocity.length();
    if (length < 1e-6) return;
    velocity = velocity * (speed_ / length);
    double minimum = 0.3 * speed_;
    if (std::abs(velocity.y) < minimum) {
        velocity.y = velocity.y < 0 ? -minimum : minimum;
        double sign = velocity.x < 0 ? -1 : 1;
        velocity.x = sign * std::sqrt(std::max(speed_ * speed_ - minimum * minimum, 0.0));
    }
}

void Bricks::shatter(std::size_t box) {
    const auto& brick = world_.boxes[box];
    xpbd::Vec centre = (brick.min + brick.max) * 0.5;
    std::uniform_real_distribution<double> kick(-8, 8);
    std::uniform_real_distribution<double> lift(-14, -4);
    std::size_t first = world_.particles.size();
    for (int side = -1; side <= 1; side += 2) {
        xpbd::Particle piece;
        piece.position = centre + xpbd::Vec{side * 1.0, 0};
        piece.previous = piece.position;
        piece.velocity = {kick(random_) + side * 3, lift(random_)};
        piece.radius = debris_radius;
        piece.gravity_scale = 1;
        piece.restitution = 0.35;
        world_.particles.push_back(piece);
        particle_roles_.push_back(box_roles_[box]);
    }
    // A slightly soft link: the pair tumbles like a stick and wobbles a little.
    world_.links.push_back({first, first + 1, 2.0, 0.0005});
}

void Bricks::drop(std::size_t particle) {
    world_.particles[particle].alive = false;
    for (const auto& link : world_.links) {
        if (link.a == particle) world_.particles[link.b].alive = false;
        if (link.b == particle) world_.particles[link.a].alive = false;
    }
}

void Bricks::compact() {
    // Drop dead debris once enough has piled up; the ball stays at index 0.
    std::size_t dead = std::count_if(world_.particles.begin(), world_.particles.end(),
                                     [](const xpbd::Particle& particle) { return !particle.alive; });
    if (dead < 16) return;
    std::vector<std::size_t> remap(world_.particles.size(), static_cast<std::size_t>(-1));
    std::vector<xpbd::Particle> particles;
    std::vector<Role> roles;
    for (std::size_t index = 0; index < world_.particles.size(); ++index) {
        if (index != ball && !world_.particles[index].alive) continue;
        remap[index] = particles.size();
        particles.push_back(world_.particles[index]);
        roles.push_back(particle_roles_[index]);
    }
    std::vector<xpbd::Link> links;
    for (auto link : world_.links) {
        if (remap[link.a] == static_cast<std::size_t>(-1) || remap[link.b] == static_cast<std::size_t>(-1)) continue;
        link.a = remap[link.a];
        link.b = remap[link.b];
        links.push_back(link);
    }
    world_.particles = std::move(particles);
    world_.links = std::move(links);
    particle_roles_ = std::move(roles);
}

void Bricks::update(double seconds) {
    if (over_) return;
    seconds = std::clamp(seconds, 0.0, 0.05);
    place_paddle(seconds);
    if (!served_) hold_ball();
    world_.step(seconds);

    bool paddle_hit = false;
    for (const auto& hit : world_.hits) {
        if (hit.box == paddle) {
            if (hit.particle == ball) {
                paddle_hit = true;
            } else if (world_.particles[hit.particle].alive) {
                // Caught debris.
                score_ += 5;
                drop(hit.particle);
            }
        } else if (hit.particle == ball && world_.boxes[hit.box].alive) {
            world_.boxes[hit.box].alive = false;
            score_ += 10;
            shatter(hit.box);
        }
    }
    if (served_) {
        if (paddle_hit) bounce_off_paddle();
        keep_ball_speed();
    } else {
        hold_ball();
    }

    for (std::size_t index = 1; index < world_.particles.size(); ++index) {
        if (world_.particles[index].position.y > world_.height + 4) drop(index);
    }
    compact();

    if (world_.particles[ball].position.y > world_.height + 1) {
        --lives_;
        served_ = false;
        if (lives_ <= 0) {
            over_ = true;
            return;
        }
        hold_ball();
    }
    if (bricks_left() == 0) {
        ++level_;
        speed_ *= 1.12;
        build_level();
    }
}

Frame Bricks::frame() const {
    Frame frame(columns_, rows_);
    for (std::size_t index = 1; index < world_.boxes.size(); ++index) {
        const auto& box = world_.boxes[index];
        if (!box.alive) continue;
        int row = static_cast<int>(box.min.y / 2);
        for (int x = static_cast<int>(box.min.x); x < static_cast<int>(box.max.x); ++x) {
            frame.at(x, row) = {"█", box_roles_[index], false};
        }
    }
    const auto& paddle_box = world_.boxes[paddle];
    for (int x = static_cast<int>(std::floor(paddle_box.min.x)); x < static_cast<int>(std::ceil(paddle_box.max.x)); ++x) {
        frame.at(x, rows_ - 1) = {"▀", Role::Light, true};
    }
    // Half blocks give the ball and debris half-row positions.
    for (std::size_t index = 0; index < world_.particles.size(); ++index) {
        const auto& particle = world_.particles[index];
        if (!particle.alive) continue;
        int x = static_cast<int>(std::floor(particle.position.x));
        double half_rows = particle.position.y / 2;
        int row = static_cast<int>(std::floor(half_rows));
        if (x < 0 || x >= columns_ || row < 0 || row >= rows_) continue;
        bool upper = half_rows - row < 0.5;
        frame.at(x, row) = {upper ? "▀" : "▄", particle_roles_[index], index == ball};
    }
    std::string hearts;
    for (int heart = 0; heart < lives_; ++heart) hearts += "♥";
    frame.status = i18n::format("score {}", {std::to_string(score_)}) + "   " +
                   i18n::format("level {}", {std::to_string(level_)}) + "   " + hearts + "   " +
                   tr("catch the falling debris for extra points");
    if (over_) {
        frame.banner = " " + tr("Game over · r to play again") + " ";
        frame.banner_role = Role::Error;
    } else if (!served_) {
        frame.banner = " " + tr("Space to serve") + " ";
        frame.banner_role = Role::Accent;
    }
    return frame;
}

std::vector<std::pair<std::string, std::string>> Bricks::hints() const {
    if (over_) return {{"r", N_("play again")}, {"esc", N_("games")}};
    return {{"left/right", N_("move")}, {"space", N_("serve")}, {"esc", N_("games")}};
}

}  // namespace games
