#pragma once

#include <argparse/argparse.hpp>
#include <fmt/color.h>

#include <type_traits>
#include <ranges>

namespace ply2image{

using namespace std::literals;

enum class file_format{
    bbf = 0,
    png = 1
};

constexpr std::string_view file_format_strings[] = {"bbf"sv, "png"sv};

enum class raster_filter{
    min = 0,
    max = 1,
    none = 2,
};

constexpr std::string_view raster_filter_strings[] = {"min"sv, "max"sv, "none"sv};

std::string valid_values_string(std::ranges::output_range<std::string_view> auto const& list){
    auto const begin = std::ranges::begin(list);
    auto const end = std::ranges::end(list);
    if(begin == end){
        throw std::logic_error("no valid values");
    }

    auto result = "(valid values: "s;
    result += fmt::format("{:?}", *begin);
    for(auto const& entry: std::span(std::next(begin), end)){
        result += fmt::format(", {:?}", entry);
    }
    result += ")"s;
    return result;
}

std::string trim_left(std::string_view const text, char const character);

constexpr bool contains(auto list, auto value){
    return std::ranges::find(list, value) != list.end();
}

template <typename T>
requires std::is_enum_v<T>
T parse_enum_string(std::ranges::output_range<std::string_view> auto const& list, std::string_view const value){
    auto const iter = std::ranges::find(list, value);
    if(iter == std::ranges::end(list)){
        throw std::runtime_error(
            fmt::format("invalid file format {:s} {:s}", value, valid_values_string(list)));
    }
    return static_cast<T>(iter - std::ranges::begin(list));
}

template <typename T>
std::optional<T> get_raster(
    argparse::ArgumentParser const& program,
    std::string_view const arg_name,
    std::string_view const disabled_name
){
    if(program.get<bool>(disabled_name)){
        if(program.is_used(arg_name)){
            throw std::runtime_error(
                "You cannot use " + std::string(arg_name) + " together with " + std::string(disabled_name));
        }else{
            return std::nullopt;
        }
    }else{
        return program.get<T>(arg_name);
    }
}

} // namespace ply2image

void print_help(argparse::ArgumentParser const& program, std::string_view const program_name);