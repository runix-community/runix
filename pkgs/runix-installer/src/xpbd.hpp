// A small 2D XPBD (extended position-based dynamics) solver for Bricks.
//
// Each substep predicts positions from velocities, moves particles to satisfy
// constraints (distance links with compliance, and contacts with walls and
// boxes), derives velocities from the corrected positions, and finally applies
// restitution to contact velocities, after Macklin, Müller and Chentanez,
// "XPBD" (2016) and Müller et al., "Detailed Rigid Body Simulation with
// Extended Position Based Dynamics" (2020).
#pragma once

#include <cstddef>
#include <vector>

namespace xpbd {

struct Vec {
    double x = 0;
    double y = 0;
    Vec operator+(Vec o) const { return {x + o.x, y + o.y}; }
    Vec operator-(Vec o) const { return {x - o.x, y - o.y}; }
    Vec operator*(double s) const { return {x * s, y * s}; }
    Vec& operator+=(Vec o) { x += o.x; y += o.y; return *this; }
    Vec& operator-=(Vec o) { x -= o.x; y -= o.y; return *this; }
    double dot(Vec o) const { return x * o.x + y * o.y; }
    double length() const;
};

struct Particle {
    Vec position;
    Vec velocity;
    Vec previous;
    double inverse_mass = 1;
    double radius = 0.5;
    /// 0 for no gravity (the ball), 1 for full gravity (debris).
    double gravity_scale = 1;
    /// 1 bounces back at full speed, 0 does not bounce.
    double restitution = 1;
    bool alive = true;
};

/// An axis-aligned box of infinite mass. A moving one (the paddle) passes its
/// velocity on through contacts.
struct Box {
    Vec min;
    Vec max;
    Vec velocity;
    bool alive = true;
};

/// Keeps two particles `rest` apart. Compliance is inverse stiffness: 0 is
/// rigid, larger values let the link stretch like a spring.
struct Link {
    std::size_t a = 0;
    std::size_t b = 0;
    double rest = 1;
    double compliance = 0;
};

struct Hit {
    std::size_t particle;
    std::size_t box;
};

class World {
public:
    /// Walls on the left (x = 0), right (x = width) and top (y = 0); the
    /// bottom is open, so things fall out of the world.
    double width = 40;
    double height = 20;
    Vec gravity{0, 60};
    int substeps = 8;

    std::vector<Particle> particles;
    std::vector<Box> boxes;
    std::vector<Link> links;

    /// Every particle-box contact during the last step, once per pair.
    std::vector<Hit> hits;

    void step(double seconds);

private:
    struct Contact {
        std::size_t particle;
        Vec normal;
        /// Velocity of what the particle touches, along the normal.
        Vec surface_velocity;
        /// Normal velocity before the position solve, for restitution.
        double approach;
    };
    std::vector<Contact> contacts_;

    void solve_link(Link& link, double& lambda, double substep);
    void collide(std::size_t index, double substep);
};

}  // namespace xpbd
