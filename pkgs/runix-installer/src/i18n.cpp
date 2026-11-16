#include "i18n.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>

#include "json.hpp"

namespace i18n {
namespace {

struct Catalog {
    std::string name;
    std::map<std::string, std::string, std::less<>> strings;
};

std::map<std::string, Catalog>& catalogs() {
    static std::map<std::string, Catalog> all{{"en", {"English", {}}}};
    return all;
}

std::vector<Language>& language_list() {
    static std::vector<Language> list{{"en", "English"}};
    return list;
}

std::string& current_code() {
    static std::string code = "en";
    return code;
}

}  // namespace

bool add(const std::string& code, std::string_view text) {
    auto root = json::parse(text);
    if (!root || !root->is_object() || code.empty()) return false;
    Catalog catalog;
    catalog.name = (*root)["language"].string().value_or(code);
    const json::Value& strings = (*root)["strings"];
    for (std::size_t index = 0; index < strings.keys.size(); ++index) {
        if (auto value = strings.values[index].string(); value && !value->empty())
            catalog.strings[strings.keys[index]] = *value;
    }
    auto& list = language_list();
    std::erase_if(list, [&](const Language& language) { return language.code == code; });
    list.push_back({code, catalog.name});
    catalogs()[code] = std::move(catalog);
    return true;
}

std::vector<std::string> load(const std::string& directory) {
    namespace fs = std::filesystem;
    std::vector<std::string> problems;
    std::error_code error;
    std::vector<fs::path> files;
    for (const auto& entry : fs::directory_iterator(directory, error))
        if (entry.path().extension() == ".json") files.push_back(entry.path());
    std::sort(files.begin(), files.end());
    for (const auto& path : files) {
        std::ifstream file(path);
        std::stringstream text;
        text << file.rdbuf();
        if (!add(path.stem().string(), text.str())) problems.push_back(path.string() + ": not a translation catalog");
    }
    return problems;
}

const std::vector<Language>& languages() { return language_list(); }

bool use(const std::string& code) {
    if (!catalogs().contains(code)) return false;
    current_code() = code;
    return true;
}

const std::string& current() { return current_code(); }

std::string tr(std::string_view english) {
    const Catalog& catalog = catalogs().at(current_code());
    auto found = catalog.strings.find(english);
    return found == catalog.strings.end() ? std::string(english) : found->second;
}

std::string format(std::string_view pattern, std::initializer_list<std::string> arguments) {
    std::string text = tr(pattern);
    std::string out;
    auto argument = arguments.begin();
    for (std::size_t index = 0; index < text.size(); ++index) {
        if (text.compare(index, 2, "{}") == 0 && argument != arguments.end()) {
            out += *argument++;
            ++index;
        } else {
            out += text[index];
        }
    }
    return out;
}

}  // namespace i18n
