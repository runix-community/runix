// Turns a failed installation's log into a report that can be uploaded and
// linked from a GitHub issue. Uploading only happens when the user asks.
#pragma once

#include <deque>
#include <string>

namespace report {

inline constexpr const char* default_paste_url = "https://paste.rs/";
inline constexpr const char* issues_url = "https://github.com/runix-community/runix/issues/new";
/// Paste services refuse large uploads; the end of the log holds the error.
inline constexpr std::size_t max_bytes = 512 * 1024;

struct Details {
    std::string error;
    std::string failed_step;
    std::string boot_mode;
    std::string loader;
    std::string filesystem;
    std::string layout;
    std::string nix_summary;
    /// Removed from the log so the report does not name the machine or user.
    std::string host;
    std::string user;
};

/// Replaces whole-word occurrences of `word`. Letters, digits, '_' and '-'
/// count as part of a word, so "runix-install" never matches "runix".
std::string redact(const std::string& text, const std::string& word, const std::string& replacement);

/// A header describing the failure, then the end of the log.
std::string build(const Details& details, const std::string& log);

/// The installer's log file, or the lines kept on screen when it is missing.
std::string read_log(const char* path, const std::deque<std::string>& fallback);

struct Result {
    std::string url;
    std::string error;
};

/// Uploads with curl and returns the paste's address.
Result upload(const std::string& service, const std::string& content);

}  // namespace report
