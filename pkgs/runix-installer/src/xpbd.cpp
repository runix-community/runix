#include "xpbd.hpp"

#include <algorithm>
#include <cmath>

namespace xpbd {

double Vec::length() const {
    return std::sqrt(x * x + y * y);
}

void World::step(double seconds) {
    hits.clear();
    if (seconds <= 0 || substeps <= 0) return;
    const double substep = seconds / substeps;
    std::vector<double> lambdas(links.size(), 0.0);
    for (int iteration = 0; iteration < substeps; ++iteration) {
        contacts_.clear();
        // Predict.
        for (auto& particle : particles) {
            if (!particle.alive || particle.inverse_mass == 0) continue;
            particle.velocity += gravity * (particle.gravity_scale * substep);
            particle.previous = particle.position;
            particle.position += particle.velocity * substep;
        }
        // Solve positions. XPBD resets the multipliers every substep.
        std::fill(lambdas.begin(), lambdas.end(), 0.0);
        for (std::size_t index = 0; index < links.size(); ++index) solve_link(links[index], lambdas[index], substep);
        for (std::size_t index = 0; index < particles.size(); ++index) {
            if (particles[index].alive && particles[index].inverse_mass != 0) collide(index, substep);
        }
        // Velocities follow from where the solve put each particle.
        for (auto& particle : particles) {
            if (!particle.alive || particle.inverse_mass == 0) continue;
            particle.velocity = (particle.position - particle.previous) * (1.0 / substep);
        }
        // Restitution: the position solve stopped the approach; bounce back by
        // the particle's restitution, relative to the surface it touched.
        for (const auto& contact : contacts_) {
            Particle& particle = particles[contact.particle];
            double along = (particle.velocity - contact.surface_velocity).dot(contact.normal);
            double target = std::max(-particle.restitution * contact.approach, 0.0);
            if (along < target) particle.velocity += contact.normal * (target - along);
        }
    }
}

void World::solve_link(Link& link, double& lambda, double substep) {
    if (link.a >= particles.size() || link.b >= particles.size()) return;
    Particle& a = particles[link.a];
    Particle& b = particles[link.b];
    if (!a.alive || !b.alive) return;
    double weight = a.inverse_mass + b.inverse_mass;
    if (weight == 0) return;
    Vec delta = a.position - b.position;
    double length = delta.length();
    if (length < 1e-9) return;
    Vec normal = delta * (1.0 / length);
    double constraint = length - link.rest;
    double alpha = link.compliance / (substep * substep);
    double change = (-constraint - alpha * lambda) / (weight + alpha);
    lambda += change;
    a.position += normal * (a.inverse_mass * change);
    b.position -= normal * (b.inverse_mass * change);
}

void World::collide(std::size_t index, double substep) {
    (void)substep;
    Particle& particle = particles[index];
    const double radius = particle.radius;
    auto touch = [&](Vec normal, Vec surface_velocity) {
        contacts_.push_back({index, normal, surface_velocity, (particle.velocity - surface_velocity).dot(normal)});
    };

    // The three walls are rigid and still.
    if (particle.position.x - radius < 0) {
        touch({1, 0}, {});
        particle.position.x = radius;
    }
    if (particle.position.x + radius > width) {
        touch({-1, 0}, {});
        particle.position.x = width - radius;
    }
    if (particle.position.y - radius < 0) {
        touch({0, 1}, {});
        particle.position.y = radius;
    }

    for (std::size_t box_index = 0; box_index < boxes.size(); ++box_index) {
        const Box& box = boxes[box_index];
        if (!box.alive) continue;
        Vec closest{std::clamp(particle.position.x, box.min.x, box.max.x),
                    std::clamp(particle.position.y, box.min.y, box.max.y)};
        Vec offset = particle.position - closest;
        double distance = offset.length();
        if (distance >= radius) continue;
        Vec normal;
        double depth;
        if (distance > 1e-9) {
            normal = offset * (1.0 / distance);
            depth = radius - distance;
        } else {
            // The centre is inside the box: leave through the nearest face.
            double left = particle.position.x - box.min.x;
            double right = box.max.x - particle.position.x;
            double top = particle.position.y - box.min.y;
            double bottom = box.max.y - particle.position.y;
            double nearest = std::min({left, right, top, bottom});
            if (nearest == left) normal = {-1, 0};
            else if (nearest == right) normal = {1, 0};
            else if (nearest == top) normal = {0, -1};
            else normal = {0, 1};
            depth = nearest + radius;
        }
        touch(normal, box.velocity);
        particle.position += normal * depth;
        bool seen = std::any_of(hits.begin(), hits.end(),
                                [&](const Hit& hit) { return hit.particle == index && hit.box == box_index; });
        if (!seen) hits.push_back({index, box_index});
    }
}

}  // namespace xpbd
