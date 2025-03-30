#pragma once

#include <stdint.h>
#include <ranges>

#include "../bitmap/bitmap.hpp"
#include "../ply/ply.hpp"
#include "progress_bar.hpp"
#include "tmrp_common.hpp"

namespace ply2image{

inline constexpr auto NaN = std::numeric_limits<double>::quiet_NaN();

template <typename Point>
struct raw_pixel;

template <>
struct raw_pixel<point>{
    double weight;
    double value;
};

template <>
struct raw_pixel<raster_point>{
    double weight;
    double value;
    std::int64_t rx;
    std::int64_t ry;
};

struct none_filter{};

template <ply::valid_value T>
std::int64_t raster_convert(T const v){
    using limits = std::numeric_limits<std::int64_t>;
    if constexpr(ply::scalar_value<T>){
        if constexpr(std::is_floating_point_v<T>){
            if(v != std::floor(v)){
                throw std::runtime_error("raster property contains at least one non-integer value");
            }else if(v < static_cast<T>(limits::min()) || v > static_cast<T>(limits::max())){
                throw std::runtime_error("raster property value is out of range");
            }
        }else if constexpr(std::is_same_v<T, std::uint64_t>){
            if(v > std::uint64_t(limits::max())){
                throw std::runtime_error("raster property value is out of range");
            }
        }

        return static_cast<std::int64_t>(v);
    }else{
        throw std::runtime_error("list type properties are not supported");
    }
}

struct max_value_filter{
    constexpr auto operator()(std::vector<raw_pixel<raster_point>> const& p)const{
        return std::ranges::max_element(p, [](raw_pixel<raster_point> const& a, raw_pixel<raster_point> const& b){
            return a.value < b.value;
        });
    }
};

struct min_value_filter{
    constexpr auto operator()(std::vector<raw_pixel<raster_point>> const& p)const{
        return std::ranges::min_element(p, [](raw_pixel<raster_point> const& a, raw_pixel<raster_point> const& b){
            return a.value < b.value;
        });
    }
};

// projection -> state-of-the-art (version 1 of 2)
bmp::bitmap<std::vector<raw_pixel<point>>> to_vector_image(
        std::size_t const width,
        std::size_t const height,
        std::vector<point> const& points
    ){
    bmp::bitmap<std::vector<raw_pixel<point>>> vector_image(width, height);
    for(auto const& p: points){
        auto const x = p.x;
        auto const y = p.y;
        auto const ix = static_cast<std::size_t>(std::floor(x));
        auto const iy = static_cast<std::size_t>(std::floor(y));
        auto const xr = x - std::floor(x);
        auto const yr = y - std::floor(y);
        if(ix < vector_image.w() && iy < vector_image.h()){
            auto const weight = (1.f - xr) * (1.f - yr);
            vector_image(ix    , iy    ).push_back({weight, p.v});
        }
        if(ix + 1 < vector_image.w() && iy < vector_image.h()){
            auto const weight = (      xr) * (1.f - yr);
            vector_image(ix + 1, iy    ).push_back({weight, p.v});
        }
        if(ix < vector_image.w() && iy + 1 < vector_image.h()){
            auto const weight = (1.f - xr) * (      yr);
            vector_image(ix    , iy + 1).push_back({weight, p.v});
        }
        if(ix + 1 < vector_image.w() && iy + 1 < vector_image.h()){
            auto const weight = (      xr) * (      yr);
            vector_image(ix + 1, iy + 1).push_back({weight, p.v});
        }
    }
    return vector_image;
}

raster_range find_raster_range(std::vector<raster_point> const& points){
    using limits = std::numeric_limits<std::int64_t>;
    raster_range range{limits::max(), limits::min(), limits::max(), limits::min()};
    for(auto const& p: points){
        range.min_x = std::min(range.min_x, p.rx);
        range.max_x = std::max(range.max_x, p.rx);
        range.min_y = std::min(range.min_y, p.ry);
        range.max_y = std::max(range.max_y, p.ry);
    }
    return range;
}

constexpr double sqr(double const v)noexcept{
    return v * v;
}

double distance(bmp::point<double> const& a, bmp::point<double> const& b){
    return std::sqrt(sqr(a.x() - b.x()) + sqr(a.y() - b.y()));
}

double area(std::array<bmp::point<double>, 3> const& t){
    auto const a = distance(t[0], t[1]);
    auto const b = distance(t[1], t[2]);
    auto const c = distance(t[2], t[0]);
    auto const s = (a + b + c) / 2.;
    return std::sqrt(s * (s - a) * (s - b) * (s - c));
}

constexpr bool is_inside(std::array<raster_point, 3> const& t, bmp::point<double> const& p){
    constexpr auto sign =
        [](std::array<bmp::point<double>, 3> const& t){
            return (t[0].x() - t[2].x()) * (t[1].y() - t[2].y()) - (t[1].x() - t[2].x()) * (t[0].y() - t[2].y());
        };

    auto const d1 = sign({p, {t[0].x, t[0].y}, {t[1].x, t[1].y}});
    auto const d2 = sign({p, {t[1].x, t[1].y}, {t[2].x, t[2].y}});
    auto const d3 = sign({p, {t[2].x, t[2].y}, {t[0].x, t[0].y}});

    auto const neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    auto const pos = (d1 > 0) || (d2 > 0) || (d3 > 0);

    return !(neg && pos);
}

// projection -> Triangle-Mesh-Rasterization-Projection (version 2 of 2)
template <typename RasterFilter>
bmp::bitmap<std::vector<raw_pixel<raster_point>>> to_vector_image(
        std::size_t const width,
        std::size_t const height,
        std::vector<raster_point> const& points,
        RasterFilter const& raster_filter
    ){
    auto const range = find_raster_range(points);
    if(range.w() < 2 || range.h() < 2){
        throw std::runtime_error("raster interpolation requires at least 2 columns and 2 rows");
    }

    fmt::print("raster with origin {:d}x{:d} and size {:d}x{:d}\n",
        range.min_x, range.min_y, range.w(), range.h());

    percent_printer progress(30, "base line");

    bmp::bitmap<std::optional<raster_point>> raster_image(range.w(), range.h());
    progress.init("create raster image", points.size());
    for(auto const& p: points){
        auto const printer = progress.lazy_inc();

        auto& target_p = raster_image(range.x(p.rx), range.y(p.ry));
        if(target_p){
            throw std::runtime_error(fmt::format("raster point {:d}x{:d} exists twice", p.rx, p.ry));
        }
        target_p = p;
    }

    progress.init("raster interpolation", (raster_image.h() - 1) * (raster_image.w() - 1));
    bmp::bitmap<std::vector<raw_pixel<raster_point>>> vector_image(width, height);
    for(std::size_t iy = 0; iy < raster_image.h() - 1; ++iy){
        for(std::size_t ix = 0; ix < raster_image.w() - 1; ++ix){
            auto const printer = progress.lazy_inc();

            std::vector<raster_point> region;
            region.reserve(4);

            if(auto const p = raster_image(ix, iy)){
                region.push_back(*p);
            }

            if(auto const p = raster_image(ix + 1, iy)){
                region.push_back(*p);
            }

            if(auto const p = raster_image(ix, iy + 1)){
                region.push_back(*p);
            }

            if(auto const p = raster_image(ix + 1, iy + 1)){
                region.push_back(*p);
            }

            if(region.size() < 3){
                continue;
            }

            std::vector<std::array<raster_point, 3>> triangles;
            if(region.size() == 3){
                triangles.reserve(1);
                triangles.push_back({region[0], region[1], region[2]});
            }else{
                triangles.reserve(4);
                triangles.push_back({region[0], region[1], region[2]});
                triangles.push_back({region[1], region[2], region[3]});
                triangles.push_back({region[2], region[3], region[0]});
                triangles.push_back({region[3], region[0], region[1]});
            }

            for(auto const& t: triangles){
                // find integer bounting box around the floating point triangle within the target image
                auto const fx = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(std::floor(
                    std::min({t[0].x, t[1].x, t[2].x}))), std::int64_t(0), static_cast<std::int64_t>(width - 1)));
                auto const tx = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(std::ceil(
                    std::max({t[0].x, t[1].x, t[2].x}))), std::int64_t(0), static_cast<std::int64_t>(width - 1)));
                if(tx == fx){
                    continue;
                }

                auto const fy = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(std::floor(
                    std::min({t[0].y, t[1].y, t[2].y}))), std::int64_t(0), static_cast<std::int64_t>(height - 1)));
                auto const ty = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(std::ceil(
                    std::max({t[0].y, t[1].y, t[2].y}))), std::int64_t(0), static_cast<std::int64_t>(height - 1)));
                if(ty == fy){
                    continue;
                }

                for(std::size_t y = fy; y <= ty; ++y){
                    for(std::size_t x = fx; x <= tx; ++x){
                        auto const p = bmp::point<double>(static_cast<double>(x), static_cast<double>(y));
                        if(!is_inside(t, p)){
                            continue;
                        }

                        std::array<double, 3> const areas{{
                            area({p, t[1], t[2]}),
                            area({p, t[2], t[0]}),
                            area({p, t[0], t[1]})
                        }};
                        auto const area_sum = areas[0] + areas[1] + areas[2];
                        std::array<double, 3> const weight{{
                            areas[0] / area_sum,
                            areas[1] / area_sum,
                            areas[2] / area_sum
                        }};

                        auto const value =
                            t[0].v * weight[0] +
                            t[1].v * weight[1] +
                            t[2].v * weight[2];

                        auto const index = std::max({
                            std::pair{weight[0], std::size_t(0)},
                            std::pair{weight[1], std::size_t(1)},
                            std::pair{weight[2], std::size_t(2)}}).second;

                        vector_image(x, y).push_back({weight[index], value, t[index].rx, t[index].ry});
                    }
                }
            }
        }
    }

    if constexpr(!std::same_as<RasterFilter, none_filter>){
        // filter values via raster information
        progress.init("reference filter", vector_image.point_count());
        for(auto& p: vector_image){
            auto const printer = progress.lazy_inc();

            if(p.empty()){
                continue;
            }

            auto const iter = raster_filter(p);
            std::erase_if(p,
                [ref_rx = iter->rx, ref_ry = iter->ry](raw_pixel<raster_point> const& v){
                    return std::abs(ref_rx - v.rx) > 1 || std::abs(ref_ry - v.ry) > 1;
                });

        }
    }

    return vector_image;
}

template <typename Point, typename ... RasterFilter>
bmp::bitmap<double> to_image(
        std::size_t const width,
        std::size_t const height,
        std::vector<Point> const& points,
        RasterFilter const& ... raster_filter
        ){
    using raw_pixel = ply2image::raw_pixel<Point>;

    auto const vector_image = to_vector_image(width, height, points, raster_filter ...);
    
    bmp::bitmap<double> image(width, height, NaN);
    std::ranges::transform(vector_image, image.begin(),
        [](std::vector<raw_pixel> const& data){
            if(data.empty()){
                return NaN;
            }else [[likely]]{
                if(data.size() == 1){
                    return data[0].value;
                }

                auto const sum_weight = std::transform_reduce(data.begin(), data.end(), static_cast<double>(0.), std::plus<double>{},
                    [](raw_pixel const& v){
                        if(v.weight < static_cast<double>(0.)){
                            throw std::logic_error("negative weight");
                        }
                        return v.weight;
                    });
                if(sum_weight == static_cast<double>(0.)){
                    return NaN;
                }

                auto const value = std::transform_reduce(data.begin(), data.end(), static_cast<double>(0.), std::plus<double>{},
                    [](raw_pixel const& v){
                        return v.value * v.weight;
                    });
                return value / sum_weight;
            }
        });

    return image;
}

} // namespace ply2image