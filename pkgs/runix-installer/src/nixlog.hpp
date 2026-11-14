// Follows `nix build --log-format internal-json`. Every `@nix {...}` line is an
// activity starting or stopping, or a result for one. Progress results carry
// `[done, expected, running, failed]`, the same numbers Nix's own progress bar
// prints as `[done/running/expected built, ...]`.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>

namespace nixlog {

// Activity types from Nix's logging.hh.
enum ActivityType : int {
    CopyPath = 100,
    FileTransfer = 101,
    Realise = 102,
    CopyPaths = 103,
    Builds = 104,
    Build = 105,
    Substitute = 108,
};

// Result types from Nix's logging.hh.
enum ResultType : int {
    BuildLogLine = 101,
    SetPhase = 104,
    Progress = 105,
    SetExpected = 106,
    PostBuildLogLine = 107,
};

struct Counts {
    std::uint64_t done = 0;
    std::uint64_t expected = 0;
    std::uint64_t running = 0;
    std::uint64_t failed = 0;
};

class Tracker {
public:
    /// Handles one line of output and returns what the log should show, if
    /// anything: plain lines pass through, Nix messages are unwrapped.
    std::optional<std::string> feed(const std::string& line);

    /// Each Nix process numbers its activities from 1 again, so the activities
    /// of a finished process are closed before the next one starts.
    void reset();

    Counts builds() const { return counts(Builds); }
    /// Store paths fetched from a binary cache.
    Counts paths() const { return counts(CopyPaths); }
    std::uint64_t downloaded() const { return bytes(FileTransfer); }
    std::uint64_t download_expected() const { return expected_bytes(FileTransfer); }

    /// 0..1 across builds and fetched paths, or nothing until Nix knows.
    std::optional<double> fraction() const;
    /// For example "3/12 built · 140/320 fetched · 1.2/3.4 GiB downloaded".
    std::string summary() const;
    /// What Nix is working on right now, for example "building hello-2.12".
    std::string current() const;

private:
    struct Activity {
        int type = 0;
        std::string label;
        Counts progress;
        std::map<int, std::uint64_t> expected;
        std::uint64_t order = 0;
    };

    std::map<std::uint64_t, Activity> activities_;
    std::map<int, Counts> stopped_;
    std::map<int, std::uint64_t> stopped_expected_;
    std::uint64_t order_ = 0;

    void stop(const Activity& activity);
    Counts counts(int type) const;
    std::uint64_t bytes(int type) const;
    std::uint64_t expected_bytes(int type) const;
};

/// "hello-2.12" from text holding "/nix/store/<hash>-hello-2.12.drv".
std::string store_name(const std::string& text);

/// Removes ANSI escape sequences and other control characters.
std::string clean(const std::string& text);

}  // namespace nixlog
