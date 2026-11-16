// Translations of the installer's own text. A catalog is a JSON file named
// after its language code (de.json, ru.json...):
//
//   { "language": "Deutsch", "strings": { "Welcome": "Willkommen" } }
//
// Keys are the English text exactly as the installer shows it; "{}" in a
// key stands for a value filled in later, and the translation places it.
// Missing strings fall back to English, so a partial catalog is fine.
#pragma once

#include <initializer_list>
#include <string>
#include <string_view>
#include <vector>

namespace i18n {

struct Language {
    std::string code;
    std::string name;
};

/// Reads every <code>.json in `directory`; English is always available.
/// Returns the problems found, one per unreadable file.
std::vector<std::string> load(const std::string& directory);
/// Adds one catalog from JSON text. Returns false when it is malformed.
bool add(const std::string& code, std::string_view json);
const std::vector<Language>& languages();
/// Switches to a loaded language; false, and no change, for unknown codes.
bool use(const std::string& code);
const std::string& current();

/// The current language's text for `english`, or `english` itself.
std::string tr(std::string_view english);
/// tr(pattern) with each "{}" replaced by the next argument.
std::string format(std::string_view pattern, std::initializer_list<std::string> arguments);

}  // namespace i18n

using i18n::tr;

/// Marks text for translation where it is defined; tr() translates it
/// where it is shown. The template extractor looks for both.
#define N_(text) text
