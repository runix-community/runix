#include "json.hpp"

#include <cmath>
#include <cstdlib>

namespace json {

namespace {

const Value null_value;

class Parser {
public:
    explicit Parser(std::string_view input) : input_(input) {}

    std::optional<Value> document() {
        Value value;
        if (!parse_value(value, 0)) return std::nullopt;
        skip_space();
        if (position_ != input_.size()) return std::nullopt;
        return value;
    }

private:
    static constexpr int max_depth = 128;
    std::string_view input_;
    std::size_t position_ = 0;

    void skip_space() {
        while (position_ < input_.size()) {
            char c = input_[position_];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
            ++position_;
        }
    }

    bool consume(char expected) {
        skip_space();
        if (position_ < input_.size() && input_[position_] == expected) {
            ++position_;
            return true;
        }
        return false;
    }

    bool literal(std::string_view word) {
        if (input_.substr(position_, word.size()) != word) return false;
        position_ += word.size();
        return true;
    }

    bool parse_value(Value& value, int depth) {
        if (depth > max_depth) return false;
        skip_space();
        if (position_ >= input_.size()) return false;
        char c = input_[position_];
        switch (c) {
            case '{': return parse_object(value, depth);
            case '[': return parse_array(value, depth);
            case '"':
                value.type = Value::Type::String;
                return parse_string(value.text);
            case 't':
                value.type = Value::Type::Bool;
                value.boolean = true;
                return literal("true");
            case 'f':
                value.type = Value::Type::Bool;
                return literal("false");
            case 'n':
                return literal("null");
            default:
                return parse_number(value);
        }
    }

    bool parse_object(Value& value, int depth) {
        value.type = Value::Type::Object;
        ++position_;
        if (consume('}')) return true;
        do {
            skip_space();
            std::string key;
            if (position_ >= input_.size() || input_[position_] != '"' || !parse_string(key)) return false;
            if (!consume(':')) return false;
            Value member;
            if (!parse_value(member, depth + 1)) return false;
            value.members.emplace_back(std::move(key), std::move(member));
        } while (consume(','));
        return consume('}');
    }

    bool parse_array(Value& value, int depth) {
        value.type = Value::Type::Array;
        ++position_;
        if (consume(']')) return true;
        do {
            Value item;
            if (!parse_value(item, depth + 1)) return false;
            value.items.push_back(std::move(item));
        } while (consume(','));
        return consume(']');
    }

    static void append_utf8(std::string& out, std::uint32_t code) {
        if (code < 0x80) {
            out += static_cast<char>(code);
        } else if (code < 0x800) {
            out += static_cast<char>(0xC0 | (code >> 6));
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else if (code < 0x10000) {
            out += static_cast<char>(0xE0 | (code >> 12));
            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (code >> 18));
            out += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (code & 0x3F));
        }
    }

    bool hex4(std::uint32_t& code) {
        if (position_ + 4 > input_.size()) return false;
        code = 0;
        for (int i = 0; i < 4; ++i) {
            char c = input_[position_++];
            code <<= 4;
            if (c >= '0' && c <= '9') code |= c - '0';
            else if (c >= 'a' && c <= 'f') code |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') code |= c - 'A' + 10;
            else return false;
        }
        return true;
    }

    bool parse_string(std::string& out) {
        ++position_;
        while (position_ < input_.size()) {
            char c = input_[position_++];
            if (c == '"') return true;
            if (c != '\\') {
                out += c;
                continue;
            }
            if (position_ >= input_.size()) return false;
            char escape = input_[position_++];
            switch (escape) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    std::uint32_t code;
                    if (!hex4(code)) return false;
                    if (code >= 0xD800 && code < 0xDC00 && literal("\\u")) {
                        std::uint32_t low;
                        if (!hex4(low)) return false;
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    }
                    append_utf8(out, code);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }

    bool parse_number(Value& value) {
        std::size_t start = position_;
        while (position_ < input_.size()) {
            char c = input_[position_];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') {
                ++position_;
            } else {
                break;
            }
        }
        if (start == position_) return false;
        std::string token(input_.substr(start, position_ - start));
        char* end = nullptr;
        value.number = std::strtod(token.c_str(), &end);
        value.type = Value::Type::Number;
        return end && *end == '\0';
    }
};

}  // namespace

const Value& Value::operator[](std::string_view key) const {
    for (const auto& [name, member] : members) {
        if (name == key) return member;
    }
    return null_value;
}

const Value& Value::operator[](std::size_t index) const {
    return index < items.size() ? items[index] : null_value;
}

std::optional<std::string> Value::string() const {
    if (type != Type::String) return std::nullopt;
    return text;
}

std::optional<std::uint64_t> Value::unsigned_number() const {
    if (type == Type::Number && number >= 0 && std::isfinite(number)) {
        return static_cast<std::uint64_t>(number);
    }
    if (type == Type::String && !text.empty()) {
        char* end = nullptr;
        unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
        if (end && *end == '\0' && text[0] != '-') return parsed;
    }
    return std::nullopt;
}

std::optional<std::int64_t> Value::integer() const {
    if (type == Type::Number && std::isfinite(number)) return static_cast<std::int64_t>(number);
    return std::nullopt;
}

std::optional<Value> parse(std::string_view input) {
    return Parser(input).document();
}

}  // namespace json
