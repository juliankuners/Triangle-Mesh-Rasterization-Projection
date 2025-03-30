#pragma once

#include <iostream>

namespace ply2image{

class percent_printer{
    public:
    struct lazy_incer{
        percent_printer& printer;
        ~lazy_incer();
    };
    percent_printer(std::size_t const label_width, std::string_view const base_line_label);
    void init(std::string_view const label, std::size_t const count);
    lazy_incer lazy_inc();

    private:
    void operator++();
    std::size_t label_width_ = 0;
    std::size_t count_ = 0;
    std::size_t prints_ = 0;
    std::size_t i_ = 0;
};

} // namespace ply2image