// The game hub shown while Nix installs the system. Every game draws into a
// grid of cells and never touches the terminal, so the games stay testable and
// the installer draws all of them the same way.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace games {

/// Colours by meaning; the UI maps them to the console palette.
enum class Role { Empty, Muted, Accent, Light, Warn, Error, Blue, Magenta, Cyan };

struct Cell {
    /// One column wide: a single character from the console's own font.
    std::string glyph = " ";
    Role role = Role::Empty;
    bool bold = false;
};

struct Frame {
    int width = 0;
    int height = 0;
    std::vector<Cell> cells;
    /// The line under the board: score, lives, level.
    std::string status;
    /// A message across the middle of the board, such as "Game over".
    std::string banner;
    Role banner_role = Role::Light;

    Frame(int width, int height);
    Cell& at(int x, int y);
    /// Writes text from (x, y), clipped to the board. Glyphs are single characters.
    void text(int x, int y, const std::string& value, Role role, bool bold = false);
};

enum class Input { Up, Down, Left, Right, Action, Restart };

class Game {
public:
    virtual ~Game() = default;
    virtual void input(Input input) = 0;
    /// Advances by real time since the last call.
    virtual void update(double seconds) = 0;
    /// Nix finished building or fetching a package with this name.
    virtual void package(const std::string& name) { (void)name; }
    virtual Frame frame() const = 0;
    virtual bool over() const = 0;
    virtual int score() const = 0;
    virtual void restart() = 0;
    /// Footer hints while playing, as (key, action).
    virtual std::vector<std::pair<std::string, std::string>> hints() const = 0;
};

struct Entry {
    const char* name;
    const char* description;
    /// Makes the game for a board of `width` by `height` cells.
    std::unique_ptr<Game> (*make)(int width, int height, std::uint32_t seed);
};

/// The games on offer, in menu order.
const std::vector<Entry>& catalog();

/// "glibc-2.40" from Nix's "fetching glibc-2.40" or "building foo (buildPhase)".
std::string package_name(const std::string& activity);

}  // namespace games
