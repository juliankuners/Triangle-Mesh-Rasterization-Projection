#pragma once

#include "../tmrp_common.hpp"

namespace ply2image {
namespace tmrpcuda {

bmp::bitmap<double> to_image_filter_min(
    std::size_t const width,
    std::size_t const height,
    std::vector<ply2image::raster_point> const& points);

bmp::bitmap<double> to_image_filter_max(
    std::size_t const width,
    std::size_t const height,
    std::vector<ply2image::raster_point> const& points);
    
bmp::bitmap<double> to_image_filter_none(
    std::size_t const width,
    std::size_t const height,
    std::vector<ply2image::raster_point> const& points);

}  // namespace tmrpcuda
}  // namespace ply2image