// Starting other programs without a shell, so no argument is ever parsed twice.
#pragma once

#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace process {

using Arguments = std::vector<std::string>;
using Environment = std::vector<std::pair<std::string, std::string>>;

struct Output {
    bool started = false;
    /// The exit status, or 128 + signal.
    int status = -1;
    std::string out;
    std::string err;
    std::string start_error;

    bool ok() const { return started && status == 0; }
};

/// Runs to completion and collects both streams. `input` goes to stdin.
Output capture(const Arguments& arguments, const std::string& input = "");

/// stdout of a successful run, or nothing.
std::optional<std::string> stdout_of(const Arguments& arguments);

/// Runs with stdout and stderr merged, calling `line` for each line as it
/// arrives. Returns the exit status, or nothing when it could not start.
std::optional<int> stream(const Arguments& arguments, const Environment& environment,
                          const std::function<void(const std::string&)>& line,
                          std::string& start_error);

/// Runs on the real terminal and waits. Returns false if it could not start.
bool interactive(const Arguments& arguments, std::string& start_error);

/// "128 + signal" or the plain exit code, as text for messages.
std::string describe_status(int status);

}  // namespace process
