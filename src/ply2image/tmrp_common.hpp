#pragma once

#include <stdint.h>
#include <ranges>

#include "../bitmap/bitmap.hpp"

namespace ply2image{

struct point{
    double x;
    double y;
    double v;
};

struct raster_point{
    double x;
    double y;
    double v;
    std::int64_t rx;
    std::int64_t ry;

    operator bmp::point<double>()const{
        return {x, y};
    };
};

struct raster_range{
    std::int64_t min_x;
    std::int64_t max_x;
    std::int64_t min_y;
    std::int64_t max_y;

    std::size_t w()const{
        return static_cast<std::size_t>(max_x + 1 - min_x);
    }

    std::size_t h()const{
        return static_cast<std::size_t>(max_y + 1 - min_y);
    }

    std::size_t x(std::int64_t const x)const{
        return static_cast<std::size_t>(x - min_x);
    }

    std::size_t y(std::int64_t const y)const{
        return static_cast<std::size_t>(y - min_y);
    }
};

ply2image::raster_range find_raster_range(std::vector<ply2image::raster_point> const& points);

} // namespace ply2image