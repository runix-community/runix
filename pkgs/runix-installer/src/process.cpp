#include "process.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

namespace process {

namespace {

std::vector<char*> argv_of(const Arguments& arguments) {
    std::vector<char*> argv;
    for (const auto& argument : arguments) argv.push_back(const_cast<char*>(argument.c_str()));
    argv.push_back(nullptr);
    return argv;
}

int decode(int raw) {
    if (WIFEXITED(raw)) return WEXITSTATUS(raw);
    if (WIFSIGNALED(raw)) return 128 + WTERMSIG(raw);
    return -1;
}

int wait_for(pid_t pid) {
    int raw = 0;
    while (waitpid(pid, &raw, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return decode(raw);
}

// A pipe that reports exec failures: closed on a successful exec, or carrying
// errno when exec fails.
struct ExecReport {
    int fds[2] = {-1, -1};

    bool open() { return pipe2(fds, O_CLOEXEC) == 0; }

    [[noreturn]] void fail_in_child() {
        int error = errno;
        (void)!write(fds[1], &error, sizeof error);
        _exit(127);
    }

    /// In the parent: an empty string when exec succeeded.
    std::string result(const std::string& program) {
        close(fds[1]);
        int error = 0;
        ssize_t got;
        do {
            got = read(fds[0], &error, sizeof error);
        } while (got < 0 && errno == EINTR);
        close(fds[0]);
        if (got == sizeof error) return "could not start " + program + ": " + std::strerror(error);
        return "";
    }
};

void reset_signals() {
    signal(SIGINT, SIG_DFL);
    signal(SIGQUIT, SIG_DFL);
    signal(SIGTSTP, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
}

}  // namespace

Output capture(const Arguments& arguments, const std::string& input) {
    Output output;
    int in[2], out[2], err[2];
    ExecReport report;
    if (pipe2(in, O_CLOEXEC) || pipe2(out, O_CLOEXEC) || pipe2(err, O_CLOEXEC) || !report.open()) {
        output.start_error = std::string("pipe: ") + std::strerror(errno);
        return output;
    }
    auto argv = argv_of(arguments);
    pid_t pid = fork();
    if (pid == 0) {
        reset_signals();
        dup2(in[0], 0);
        dup2(out[1], 1);
        dup2(err[1], 2);
        execvp(argv[0], argv.data());
        report.fail_in_child();
    }
    close(in[0]);
    close(out[1]);
    close(err[1]);
    if (pid < 0) {
        output.start_error = std::string("fork: ") + std::strerror(errno);
        close(in[1]);
        close(out[0]);
        close(err[0]);
        close(report.fds[0]);
        close(report.fds[1]);
        return output;
    }
    output.start_error = report.result(arguments[0]);

    // Write stdin while draining both outputs, so a large input cannot deadlock.
    std::size_t written = 0;
    if (input.empty()) {
        close(in[1]);
        in[1] = -1;
    }
    pollfd fds[3] = {{out[0], POLLIN, 0}, {err[0], POLLIN, 0}, {in[1], POLLOUT, 0}};
    char buffer[4096];
    while (fds[0].fd >= 0 || fds[1].fd >= 0) {
        if (poll(fds, 3, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < 2; ++i) {
            if (fds[i].fd >= 0 && fds[i].revents) {
                ssize_t got = read(fds[i].fd, buffer, sizeof buffer);
                if (got > 0) {
                    (i == 0 ? output.out : output.err).append(buffer, static_cast<std::size_t>(got));
                } else if (got == 0 || errno != EINTR) {
                    close(fds[i].fd);
                    fds[i].fd = -1;
                }
            }
        }
        if (fds[2].fd >= 0 && fds[2].revents) {
            ssize_t sent = write(fds[2].fd, input.data() + written, input.size() - written);
            if (sent > 0) written += static_cast<std::size_t>(sent);
            if (sent < 0 && errno != EINTR) written = input.size();
            if (written >= input.size()) {
                close(fds[2].fd);
                fds[2].fd = -1;
            }
        }
    }
    if (fds[2].fd >= 0) close(fds[2].fd);
    output.status = wait_for(pid);
    output.started = output.start_error.empty();
    return output;
}

std::optional<std::string> stdout_of(const Arguments& arguments) {
    Output output = capture(arguments);
    if (!output.ok()) return std::nullopt;
    return output.out;
}

std::optional<int> stream(const Arguments& arguments, const Environment& environment,
                          const std::function<void(const std::string&)>& line,
                          std::string& start_error) {
    int out[2];
    ExecReport report;
    if (pipe2(out, O_CLOEXEC) || !report.open()) {
        start_error = std::string("pipe: ") + std::strerror(errno);
        return std::nullopt;
    }
    auto argv = argv_of(arguments);
    pid_t pid = fork();
    if (pid == 0) {
        reset_signals();
        int null = open("/dev/null", O_RDONLY);
        if (null >= 0) dup2(null, 0);
        dup2(out[1], 1);
        dup2(out[1], 2);
        for (const auto& [key, value] : environment) setenv(key.c_str(), value.c_str(), 1);
        execvp(argv[0], argv.data());
        report.fail_in_child();
    }
    close(out[1]);
    if (pid < 0) {
        start_error = std::string("fork: ") + std::strerror(errno);
        close(out[0]);
        close(report.fds[0]);
        close(report.fds[1]);
        return std::nullopt;
    }
    start_error = report.result(arguments[0]);
    std::string pending;
    char buffer[8192];
    while (true) {
        ssize_t got = read(out[0], buffer, sizeof buffer);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        pending.append(buffer, static_cast<std::size_t>(got));
        std::size_t start = 0;
        std::size_t end;
        // Nix ends progress lines with \r too; either one finishes a line.
        while ((end = pending.find_first_of("\r\n", start)) != std::string::npos) {
            if (end > start) line(pending.substr(start, end - start));
            start = end + 1;
        }
        pending.erase(0, start);
    }
    if (!pending.empty()) line(pending);
    close(out[0]);
    int status = wait_for(pid);
    if (!start_error.empty()) return std::nullopt;
    return status;
}

bool interactive(const Arguments& arguments, std::string& start_error) {
    ExecReport report;
    if (!report.open()) {
        start_error = std::string("pipe: ") + std::strerror(errno);
        return false;
    }
    auto argv = argv_of(arguments);
    pid_t pid = fork();
    if (pid == 0) {
        reset_signals();
        execvp(argv[0], argv.data());
        report.fail_in_child();
    }
    if (pid < 0) {
        start_error = std::string("fork: ") + std::strerror(errno);
        close(report.fds[0]);
        close(report.fds[1]);
        return false;
    }
    // The child owns the terminal; Ctrl+C there must not end the installer.
    struct sigaction ignore {}, old_int {}, old_quit {};
    ignore.sa_handler = SIG_IGN;
    sigaction(SIGINT, &ignore, &old_int);
    sigaction(SIGQUIT, &ignore, &old_quit);
    start_error = report.result(arguments[0]);
    wait_for(pid);
    sigaction(SIGINT, &old_int, nullptr);
    sigaction(SIGQUIT, &old_quit, nullptr);
    return start_error.empty();
}

std::string describe_status(int status) {
    if (status > 128) return "killed by signal " + std::to_string(status - 128);
    return "exit status " + std::to_string(status);
}

}  // namespace process
