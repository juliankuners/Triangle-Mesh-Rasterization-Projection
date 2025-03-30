#include "progress_bar.hpp"

#include <fmt/color.h>

namespace ply2image{


percent_printer::lazy_incer::~lazy_incer(){
    ++printer;
}

percent_printer::percent_printer(std::size_t const label_width, std::string_view const base_line_label)
        : label_width_(label_width){
    if(base_line_label.size() > label_width_){
        throw std::logic_error("label width is larger then specified");
    }

    fmt::print("{:>{}s}: "
        "===================================================================================================="
        "\n", base_line_label, label_width_);
    std::fflush(stdout);
}

void percent_printer::init(std::string_view const label, std::size_t const count){
    if(label.size() > label_width_){
        throw std::logic_error("label width is larger then specified");
    }

    fmt::print("{:>{}s}: ", label, label_width_);
    std::fflush(stdout);

    count_ = count;
    prints_ = 0;
    i_ = 0;
}

percent_printer::lazy_incer percent_printer::lazy_inc(){
    return {*this};
}

void percent_printer::operator++(){
    ++i_;

    if(count_ == 0){
        throw std::logic_error("percent printer used without init call");
    }

    if(i_ > count_){
        throw std::logic_error("percent printer run out of range");
    }

    auto const percent =
        static_cast<std::size_t>(std::ceil(static_cast<double>(i_) / static_cast<double>(count_) * 100.));

    bool need_flush = false;
    for(; prints_ < percent; ++prints_){
        fmt::print(">");
        need_flush = true;
    }

    if(i_ == count_){
        fmt::print(" done\n");
        need_flush = true;
    }

    if(need_flush){
        std::fflush(stdout);
    }
}

} // namespace ply2image