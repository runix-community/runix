// A small JSON reader, enough for lsblk output and Nix's internal-json log.
// Missing keys and wrong types read as null, so callers never need to check
// the shape before indexing.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace json {

class Value {
public:
    enum class Type { Null, Bool, Number, String, Array, Object };

    Type type = Type::Null;
    bool boolean = false;
    double number = 0;
    std::string text;
    std::vector<Value> items;
    std::vector<std::pair<std::string, Value>> members;

    bool is_null() const { return type == Type::Null; }
    bool is_string() const { return type == Type::String; }
    bool is_array() const { return type == Type::Array; }
    bool is_object() const { return type == Type::Object; }

    const Value& operator[](std::string_view key) const;
    const Value& operator[](std::size_t index) const;

    std::optional<std::string> string() const;
    /// Numbers, and strings holding a number (lsblk prints sizes either way).
    std::optional<std::uint64_t> unsigned_number() const;
    std::optional<std::int64_t> integer() const;
    bool is_true() const { return type == Type::Bool && boolean; }
};

/// Returns nothing for malformed input or trailing garbage.
std::optional<Value> parse(std::string_view input);

}  // namespace json
