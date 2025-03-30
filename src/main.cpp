#include <fmt/color.h>
#include <argparse/argparse.hpp>

#include <algorithm>
#include <numeric>
#include <span>
#include <tuple>

#include "ply/ply.hpp"
#include "bitmap/io/image_format_png.hpp"
#include "bitmap/bitmap.hpp"
#include "bitmap/binary_write.hpp"
#include "ply2image/argparse.hpp"
#include "ply2image/tmrp.hpp"
#include "ply2image/cuda/tmrp.cuh"

template<typename T, typename... Args>
struct FirstType {
    using type = T;
};

int main(int argc, char** argv)try{
    using namespace std::literals;
    using namespace ply2image;

    std::locale::global(std::locale("C"));

    argparse::ArgumentParser program(argv[0], "1.1", argparse::default_arguments::version);

    program.add_argument("--help")
        .action([&](std::string const&) {
            print_help(program, argv[0]);
            std::exit(0);
        })
        .default_value(false)
        .help("shows help message and exits")
        .implicit_value(true)
        .nargs(0);

    program.add_argument("-i", "--input")
        .help("3D input file in PLY format")
        .required();

    program.add_argument("-w", "--width")
        .help("width of the output image")
        .scan<'u', std::size_t>()
        .required();
    program.add_argument("-h", "--height")
        .help("height of the output image")
        .scan<'u', std::size_t>()
        .required();

    program.add_argument("-o", "--output")
        .help("name of the output image")
        .required();

    program.add_argument("--output-format")
        .help(fmt::format("file format of the output {:s}", valid_values_string(file_format_strings)))
        .default_value(std::string(file_format_strings[0]));

    program.add_argument("--x-element")
        .help("the PLY element from which the x image positions are taken")
        .default_value("vertex"s);
    program.add_argument("--y-element")
        .help("the PLY element from which the y image positions are taken")
        .default_value("vertex"s);
    program.add_argument("--value-element")
        .help("the PLY element from which the image values are taken")
        .default_value("vertex"s);
    program.add_argument("--x-raster-element")
        .help("the PLY element from which the x raster positions are taken")
        .default_value("vertex"s);
    program.add_argument("--y-raster-element")
        .help("the PLY element from which the y raster positions are taken")
        .default_value("vertex"s);

    program.add_argument("-x", "--x-property")
        .help("the PLY element property used as x image position (must not be a list type)")
        .default_value("x"s);
    program.add_argument("-y", "--y-property")
        .help("the PLY element property used as y image position (must not be a list type)")
        .default_value("y"s);
    program.add_argument("-v", "--value-property")
        .help("the PLY element property converted to image values (must not be a list type)")
        .default_value("z"s);

    program.add_argument("--x-raster-property")
        .help("the PLY element property used as x raster position (must not be a list type)")
        .default_value("raster_x"s);
    program.add_argument("--y-raster-property")
        .help("the PLY element property used as y raster position (must not be a list type)")
        .default_value("raster_y"s);

    program.add_argument("--raster-filter")
        .help(fmt::format("raster filter {:s}", valid_values_string(raster_filter_strings)))
        .default_value(std::string(raster_filter_strings[0]));

    program.add_argument("--disable-raster")
        .help("explicitly disable gap interpolation via raster")
        .implicit_value(true)
        .default_value(false);

    program.add_argument("--x-scale")
        .help("all x values are multiplied by x-scale")
        .scan<'g', double>()
        .default_value(static_cast<double>(1.));
    program.add_argument("--y-scale")
        .help("all y values are multiplied by y-scale")
        .scan<'g', double>()
        .default_value(static_cast<double>(1.));
    program.add_argument("--value-scale")
        .help("all pixel values are multiplied by value-scale")
        .scan<'g', double>()
        .default_value(static_cast<double>(1.));

    program.add_argument("--x-pre-scale-offset")
        .help("all x values are added with x-pre-scale-offset before scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));
    program.add_argument("--y-pre-scale-offset")
        .help("all y values are added with y-pre-scale-offset before scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));
    program.add_argument("--value-pre-scale-offset")
        .help("all pixel values are added with value-pre-scale-offset before scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));

    program.add_argument("--x-post-scale-offset")
        .help("all x values are added with x-post-scale-offset after scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));
    program.add_argument("--y-post-scale-offset")
        .help("all y values are added with y-post-scale-offset after scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));
    program.add_argument("--value-post-scale-offset")
        .help("all pixel values are added with value-post-scale-offset after scaling")
        .scan<'g', double>()
        .default_value(static_cast<double>(0.));
    program.add_argument("--cuda")
        .help("use CUDA for tmrp interpolation")
        .implicit_value(true)
        .default_value(false);


    try{
        program.parse_args(argc, argv);
    }catch(std::runtime_error const& error){
        fmt::print(fmt::emphasis::bold | fg(fmt::color::red), "Error: {:s}\n\n", error.what());
        print_help(program, argv[0]);
        return -1;
    }

    auto const input_filepath = std::filesystem::path(program.get<std::string>("-i"));
    auto const output_filepath = std::filesystem::path(program.get<std::string>("-o"));
    auto const output_format =
        parse_enum_string<file_format>(file_format_strings, program.get<std::string>("--output-format"));

    if(auto const
        ext = trim_left(output_filepath.extension().string(), '.'),
        format = std::string(file_format_strings[static_cast<int>(output_format)]);
        ext != format
    ){
        throw std::runtime_error(fmt::format(
            "file extension of output file {:?} is different from specified output format {:?}",
            ext, format));
    }

    auto const width = program.get<std::size_t>("-w");
    auto const height = program.get<std::size_t>("-h");

    auto const x_element = program.get<std::string>("--x-element");
    auto const y_element = program.get<std::string>("--y-element");
    auto const v_element = program.get<std::string>("--value-element");

    auto const x_property = program.get<std::string>("-x");
    auto const y_property = program.get<std::string>("-y");
    auto const v_property = program.get<std::string>("-v");

    auto const arg_xr_element = get_raster<std::string>(program, "--x-raster-element", "--disable-raster");
    auto const arg_yr_element = get_raster<std::string>(program, "--y-raster-element", "--disable-raster");
    auto const arg_xr_property = get_raster<std::string>(program, "--x-raster-property", "--disable-raster");
    auto const arg_yr_property = get_raster<std::string>(program, "--y-raster-property", "--disable-raster");
    auto const explicit_raster =
        program.is_used("--x-raster-element") ||
        program.is_used("--y-raster-element") ||
        program.is_used("--x-raster-property") ||
        program.is_used("--y-raster-property");
    auto const filter =
        parse_enum_string<raster_filter>(raster_filter_strings, program.get<std::string>("--raster-filter"));

    auto const x_scale = program.get<double>("--x-scale");
    auto const y_scale = program.get<double>("--y-scale");
    auto const v_scale = program.get<double>("--value-scale");

    auto const x_pre_scale = program.get<double>("--x-pre-scale-offset");
    auto const y_pre_scale = program.get<double>("--y-pre-scale-offset");
    auto const v_pre_scale = program.get<double>("--value-pre-scale-offset");

    auto const x_post_scale = program.get<double>("--x-post-scale-offset");
    auto const y_post_scale = program.get<double>("--y-post-scale-offset");
    auto const v_post_scale = program.get<double>("--value-post-scale-offset");

    auto const cuda_enabled = program.get<bool>("--cuda");

    // load file
    ply::ply data;
    data.load(input_filepath);

    {
        auto names = data.element_names();
        std::ranges::sort(names);
        if(std::unique(names.begin(), names.end()) != names.end()){
            fmt::print(fmt::emphasis::bold | fg(fmt::color::orange),
                "Warning: PLY file contains duplicate element names, when accessed the first element is used\n");
        }
    }

    // display file structure
    {
        auto used_properties = std::vector<std::array<std::string_view, 2>>{
            {x_element, x_property}, {y_element, y_property}, {v_element, v_property}};

        if(arg_xr_element){
            used_properties.push_back({*arg_xr_element, *arg_xr_property});
        }

        if(arg_yr_element){
            used_properties.push_back({*arg_yr_element, *arg_yr_property});
        }

        auto const element_count = data.element_count();
        auto const element_count_width = fmt::format("{:d}", element_count).size();
        for(std::size_t i = 0; i < element_count; ++i){
            auto const element_name = data.element_name(i);
            fmt::print("element {:>{}d} {:?} with {:d} values\n", i, element_count_width,
                element_name, data.value_count(i));

            {
                auto names = data.property_names(i);
                std::ranges::sort(names);
                if(std::unique(names.begin(), names.end()) != names.end()){
                    fmt::print(fmt::emphasis::bold | fg(fmt::color::orange),
                        "    Warning: Element {:s} contains duplicate property names, "
                        "when accessed the first property is used\n", element_name);
                }
            }

            auto const property_count = data.property_count(i);
            auto const property_count_width = fmt::format("{:d}", property_count).size();
            for(std::size_t j = 0; j < property_count; ++j){
                auto const property_name = data.property_name(i, j);
                auto const test = std::array{element_name, property_name};
                bool const used = contains(used_properties, test);
                if(used){
                    std::erase(used_properties, test);
                }
                fmt::print(used ? fmt::emphasis::bold : fmt::emphasis(),
                    "    property {:>{}d} {:?} with type {:s}\n", j, property_count_width,
                    property_name, data.property_type_name(i, j));
            }
        }
    }

    auto const [xr_element, xr_property, yr_element, yr_property] =
        [&]()->std::array<std::optional<std::string>, 4>{
            if(arg_xr_element){
                if(explicit_raster || (
                    data.contains_property(*arg_xr_element, *arg_xr_property) &&
                    data.contains_property(*arg_yr_element, *arg_yr_property)
                )){
                    return {arg_xr_element, arg_xr_property, arg_yr_element, arg_yr_property};
                }else{
                    fmt::print(fmt::emphasis::bold | fg(fmt::color::orange),
                        "Warning: Disable raster interpulation because element vertex does not contain the "
                        "properties raster_x and raster_y. Use --disable-raster to disable this warning.\n");
                }
            }

            return {std::nullopt, std::nullopt, std::nullopt, std::nullopt};
        }();


    // value count of the three used properties
    auto const count = [&]{
        auto const x_count = data.value_count(x_element);

        if(x_count != data.value_count(y_element)){
            throw std::runtime_error("--y-element has different value count then --x-element");
        }

        if(x_count != data.value_count(v_element)){
            throw std::runtime_error("--v-element has different value count then --x-element");
        }

        if(xr_element && x_count != data.value_count(*xr_element)){
            throw std::runtime_error("--x-raster-element has different value count then --x-element");
        }

        if(yr_element && x_count != data.value_count(*yr_element)){
            throw std::runtime_error("--y-raster-element has different value count then --x-element");
        }

        return x_count;
    }();

    if(count == 0){
        throw std::runtime_error("value count is 0");
    }


    auto const image_convert =
        [&]<typename Point, typename... RasterFilter>(std::type_identity<Point>, RasterFilter const& ... raster_filter){
            // extract used data
            std::vector<Point> points(count);
            auto const convert = [&points]<ply::valid_value T>(auto const& setter, std::span<T const> const list){
                if constexpr(ply::scalar_value<T>){
                    for(std::size_t i = 0; i < points.size(); ++i){
                        setter(points[i], list[i]);
                    }
                }else{
                    throw std::runtime_error("list type properties are not supported");
                }
            };

            auto const set_x = [=](Point& p, auto const v){
                    p.x = (static_cast<double>(v) + x_pre_scale) * x_scale + x_post_scale;
                };
            auto const set_y = [=](Point& p, auto const v){
                    p.y = (static_cast<double>(v) + y_pre_scale) * y_scale + y_post_scale;
                };
            auto const set_v = [=](Point& p, auto const v){
                    p.v = (static_cast<double>(v) + v_pre_scale) * v_scale + v_post_scale;
                };
            std::visit([=](auto const& v){ convert(set_x, v); }, data.values(x_element, x_property));
            std::visit([=](auto const& v){ convert(set_y, v); }, data.values(y_element, y_property));
            std::visit([=](auto const& v){ convert(set_v, v); }, data.values(v_element, v_property));

            if constexpr(std::is_same_v<Point, raster_point>){
                auto const set_rx = [](Point& p, auto const v){ p.rx = raster_convert(v); };
                auto const set_ry = [](Point& p, auto const v){ p.ry = raster_convert(v); };
                std::visit([=](auto const& v){ convert(set_rx, v); }, data.values(*xr_element, *xr_property));
                std::visit([=](auto const& v){ convert(set_ry, v); }, data.values(*yr_element, *yr_property));
            }

            if constexpr (std::is_same_v<Point, raster_point>) {
                if (cuda_enabled) {
                    if constexpr (std::is_same_v<typename FirstType<RasterFilter...>::type, min_value_filter>) {
                        return tmrpcuda::to_image_filter_min(width, height, points);
                    } else if constexpr (std::is_same_v<typename FirstType<RasterFilter...>::type, max_value_filter>) {
                        return tmrpcuda::to_image_filter_max(width, height, points);
                    } else if constexpr (std::is_same_v<typename FirstType<RasterFilter...>::type, none_filter>) { 
                        return tmrpcuda::to_image_filter_none(width, height, points);
                    }
                }
            }

            // convert list to image
            return to_image<Point>(width, height, points, raster_filter ...);
        };

    auto const image =
        [&]{
            if(xr_element){
                switch(filter){
                    case raster_filter::min:
                        return image_convert(std::type_identity<raster_point>(), min_value_filter{});
                    case raster_filter::max:
                        return image_convert(std::type_identity<raster_point>(), max_value_filter{});
                    case raster_filter::none:
                        return image_convert(std::type_identity<raster_point>(), none_filter{});
                }
                throw std::logic_error("invalid raster filter");
            }else{
                return image_convert(std::type_identity<point>());
            }
        }();

    [&]{
        switch(output_format){
            case file_format::bbf: {
                bmp::binary_write(image, output_filepath.string());
            } return;
            case file_format::png: {
                bmp::bitmap<bmp::pixel::masked_g16u> png_image(image.size());
                std::ranges::transform(image, png_image.begin(),
                    [](double const v){
                        if(std::isnan(v)){
                            return bmp::pixel::masked_g16u{.v = {}, .m = true};
                        }else{
                            return bmp::pixel::masked_g16u{
                                .v = static_cast<std::uint16_t>(std::round(std::clamp(v, static_cast<double>(0.), static_cast<double>(65535.)))), .m = false};
                        }
                    });

                bmp::png::write(png_image, output_filepath.string());
            } return;
        }

        throw std::logic_error("invalid file format");
    }();
}catch(std::system_error const& error){
    fmt::print(fmt::emphasis::bold | fg(fmt::color::red),
        "System error:\n"
        "  Category: {:s}\n"
        "      Code: {:d}\n"
        "   Message: {:s}\n",
        error.code().category().name(), error.code().value(), error.code().message());
    return 3;
}catch(std::exception const& error){
    fmt::print(fmt::emphasis::bold | fg(fmt::color::red), "Error: {:s}\n", error.what());
    return 2;
}
