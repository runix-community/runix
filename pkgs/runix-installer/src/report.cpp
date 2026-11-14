#include "report.hpp"

#include <fstream>
#include <sstream>

#include "process.hpp"
#include "util.hpp"

namespace report {

namespace {

bool word_character(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

}  // namespace

std::string redact(const std::string& text, const std::string& word, const std::string& replacement) {
    if (word.empty()) return text;
    std::string out;
    std::size_t position = 0;
    while (true) {
        std::size_t found = text.find(word, position);
        if (found == std::string::npos) break;
        std::size_t end = found + word.size();
        bool starts = found == 0 || !word_character(text[found - 1]);
        bool ends = end == text.size() || !word_character(text[end]);
        out.append(text, position, found - position);
        out += starts && ends ? replacement : word;
        position = end;
    }
    out.append(text, position, std::string::npos);
    return out;
}

std::string build(const Details& details, const std::string& log) {
    std::string body = log;
    // The default host name says nothing about the machine, and is also part
    // of paths such as /mnt/etc/runix, so it stays.
    if (details.host != "runix") body = redact(body, details.host, "<host>");
    body = redact(body, details.user, "<user>");
    bool cut = body.size() > max_bytes;
    if (cut) {
        body = body.substr(body.size() - max_bytes);
        body = body.substr(body.find('\n') == std::string::npos ? 0 : body.find('\n') + 1);
    }
    std::ostringstream out;
    out << "Runix installer report\n"
        << "error:       " << details.error << "\n"
        << "failed step: " << details.failed_step << "\n"
        << "boot mode:   " << details.boot_mode << "\n"
        << "boot loader: " << details.loader << "\n"
        << "filesystem:  " << details.filesystem << "\n"
        << "layout:      " << details.layout << "\n";
    if (!details.nix_summary.empty()) out << "nix:         " << details.nix_summary << "\n";
    out << "\n---- install log" << (cut ? " (end only)" : "") << " ----\n" << body;
    if (!body.empty() && body.back() != '\n') out << "\n";
    return out.str();
}

std::string read_log(const char* path, const std::deque<std::string>& fallback) {
    std::ifstream file(path, std::ios::binary);
    if (file) {
        std::ostringstream text;
        text << file.rdbuf();
        if (!text.str().empty()) return text.str();
    }
    std::string text;
    for (const auto& line : fallback) text += line + "\n";
    return text;
}

Result upload(const std::string& service, const std::string& content) {
    auto output = process::capture(
        {"curl", "-fsS", "--max-time", "60", "-H", "Content-Type: text/plain", "--data-binary", "@-", service},
        content);
    if (!output.started) return {"", output.start_error};
    std::string url = util::trim(output.out);
    if (output.status != 0 || url.rfind("http", 0) != 0) {
        std::string reason = util::trim(output.err);
        return {"", reason.empty() ? "the paste service did not answer" : reason};
    }
    return {url, ""};
}

}  // namespace report
