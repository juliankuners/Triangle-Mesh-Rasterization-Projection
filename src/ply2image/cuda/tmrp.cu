#include <iostream>
#include <cstdio>
#include <cuda.h>
#include <cuda/std/limits>
#include <cuda/std/array>
#include <cuda/std/cmath>
#include <cuda/std/tuple>
#include <cuda/std/utility>
#include <cuda/semaphore>
#include <fmt/core.h>
#include <stdlib.h>

#include "tmrp.cuh"
#include "../progress_bar.hpp"

namespace ply2image {
namespace tmrpcuda {

#define checkCudaErrors(call)                                       \
do {                                                            \
    cudaError_t err = call;                                     \
    if (err != cudaSuccess) {                                   \
        printf("CUDA error at %s %d: %s\n", __FILE__, __LINE__, \
        cudaGetErrorString(err));                               \
        exit(EXIT_FAILURE);                                     \
    }                                                           \
} while (0)

struct filter_min {};
struct filter_max {};
struct filter_none {};

template<typename filter_type>
concept RasterFilterNone = std::is_same_v<filter_type, struct filter_none>;

template<typename filter_type>
concept RasterFilterMinMax = 
    std::is_same_v<filter_type, struct filter_min> ||
    std::is_same_v<filter_type, struct filter_max>;

template<typename filter_type>
concept RasterFilter = RasterFilterMinMax<filter_type> || RasterFilterNone<filter_type>;

template<typename T, int preallocated=8>
struct pixel_array {
    constexpr static int preallocated_v = preallocated;

    struct pixel_vector_header {
        int allocated_size;
        pixel_vector_header* next_header;
        
        // fetches from local array
        // index always starts at 0
        __device__ inline T* get(int index) {
            return reinterpret_cast<T*>(reinterpret_cast<char*>(this) + sizeof(*this)) + index;
        }
    };

    struct pixel_array_header {
        cuda::binary_semaphore<cuda::thread_scope_device> lock;
        pixel_vector_header* next_header;
        int last;

        __host__ __device__ pixel_array_header() : 
                lock(1),
                next_header(nullptr),
                last(0) {
            // pass
        }
    };
    
    int width;
    pixel_array_header* header_array;
    T* data_array;

    __host__ __device__ pixel_array(int width) :
            width(width),
            header_array(nullptr),
            data_array(nullptr) {
        // pass
    }

    __host__ __device__ constexpr int get_preallocated() {
        return preallocated;
    }

    __device__ void init_header(int x, int y) {
        new(&(header_array[y*width + x])) pixel_array_header();
    }

    // No bounds checking!
    __device__ void push_back(int x, int y, const T &value) { 
        pixel_array_header* cur_array_header = &(header_array[y*width + x]);
        int index = atomicAdd(&(cur_array_header->last), 1);

        if (index < preallocated) {
            data_array[(y*width + x) * preallocated + index] = value;
        } else {
            if (cur_array_header->next_header == nullptr) {
                allocate_arraynode(cur_array_header);
            }
            pixel_vector_header* cur_header = cur_array_header->next_header;
            index = index - preallocated;
            while (index >= cur_header->allocated_size) {
                if (cur_header->next_header == nullptr) {
                    allocate_arraynode(cur_array_header, cur_header);
                }
                index = index - cur_header->allocated_size;
                cur_header = cur_header->next_header;
            }
            T* sink = cur_header->get(index);
            *sink = value;
        }        
    }

private:
    __device__ void allocate_arraynode(pixel_array_header* array_header) {
        array_header->lock.acquire();
        if (array_header->next_header == nullptr) {
            pixel_vector_header* new_vectornode = static_cast<pixel_vector_header*>(malloc(preallocated * sizeof(T) + sizeof(pixel_vector_header)));

            new_vectornode->allocated_size = preallocated;
            new_vectornode->next_header = nullptr;

            array_header->next_header = new_vectornode;
            __threadfence_block();
        }
        array_header->lock.release();
    }

    __device__ void allocate_arraynode(pixel_array_header* array_header, pixel_vector_header* vector_header) {
        array_header->lock.acquire();
        if (vector_header->next_header == nullptr) {
            int new_size = vector_header->allocated_size*2;
            pixel_vector_header* new_vectornode = static_cast<pixel_vector_header*>(malloc(new_size * sizeof(T) + sizeof(pixel_vector_header)));

            new_vectornode->allocated_size = new_size;
            new_vectornode->next_header = nullptr;

            vector_header->next_header = new_vectornode;
            __threadfence_block();
        }
        array_header->lock.release();
    }
};

struct interpolation_result_min_max {
    double value_weighted;
    double weight;
    int rx;
    int ry;
};

// this raster_point is comparable to an optional<raster_point>
// if v equals infinity (0x7FF0_0000_0000_0000), the raster_point is non existent in the raster_image
struct raster_point {
    double x;
    double y;
    double v;

    __host__ __device__ bool exists() {
        return v != cuda::std::numeric_limits<double>::infinity();
    }

    __host__ __device__ raster_point(double x, double y, double v) :
            x(x),
            y(y),
            v(v) {
        // pass
    }

    __host__ __device__ static inline raster_point empty() {
        return raster_point(0, 0, cuda::std::numeric_limits<double>::infinity());
    }

    // warning: this default constructor is intended for the use within shared memory in cuda
    raster_point() = default;

    __host__ __device__ raster_point& operator=(const ply2image::raster_point &copy) {
        x = copy.x;
        y = copy.y;
        v = copy.v;
        return *this;
    }
};

template<int blockSizeX, int blockSizeY>
struct r_triangle_parent {
    using shared_rpoints_t = cuda::std::array<cuda::std::array<raster_point, blockSizeX+1>, blockSizeY+1>;
    const shared_rpoints_t &shared_rpoints;

    int ry1, rx1;
    int ry2, rx2;
    int ry3, rx3;

    __device__ r_triangle_parent(
                const shared_rpoints_t &shared_rpoints,
                int ry1, int rx1,
                int ry2, int rx2,
                int ry3, int rx3,
                int, int) : // keep the argument list the same for all child structs
            shared_rpoints(shared_rpoints),
            ry1(ry1), rx1(rx1),
            ry2(ry2), rx2(rx2),
            ry3(ry3), rx3(rx3) {
        // pass
    }

    __device__ inline const raster_point* p1() const {
        return &(shared_rpoints[ry1][rx1]);
    }

    __device__ inline const raster_point* p2() const {
        return &(shared_rpoints[ry2][rx2]);
    }

    __device__ inline const raster_point* p3() const {
        return &(shared_rpoints[ry3][rx3]);
    }
};

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
struct r_triangle {};

template<int blockSizeX, int blockSizeY, RasterFilterMinMax raster_filter>
struct r_triangle<blockSizeX, blockSizeY, raster_filter> : r_triangle_parent<blockSizeX, blockSizeY> {
    // base offset used in global memory, in contrast to relative offset in shared memory
    int base_ry, base_rx;

    __device__ r_triangle(
                const r_triangle_parent<blockSizeX, blockSizeY>::shared_rpoints_t &shared_rpoints,
                int ry1, int rx1,
                int ry2, int rx2,
                int ry3, int rx3,
                int base_ry, int base_rx) : // keep the argument list the same for all child structs
            r_triangle_parent<blockSizeX, blockSizeY>(
                shared_rpoints,
                ry1, rx1,
                ry2, rx2,
                ry3, rx3,
                base_ry, base_rx),
            base_ry(base_ry),
            base_rx(base_rx) {
        // pass
    }

    __device__ int absolute_ry1() const {
        return base_ry + this->ry1;
    }

    __device__ int absolute_rx1() const {
        return base_rx + this->rx1;
    }

    __device__ int absolute_ry2() const {
        return base_rx + this->ry2;
    }

    __device__ int absolute_rx2() const {
        return base_rx + this->rx2;
    }

    __device__ int absolute_ry3() const {
        return base_rx + this->ry3;
    }

    __device__ int absolute_rx3() const {
        return base_rx + this->rx3;
    }
};

template<int blockSizeX, int blockSizeY, RasterFilterNone raster_filter>
struct r_triangle<blockSizeX, blockSizeY, raster_filter> : r_triangle_parent<blockSizeX, blockSizeY> {
    using r_triangle_parent<blockSizeX, blockSizeY>::r_triangle_parent;
};

template<typename pixels_t>
struct raster_interpolation_config_parent {
    pixels_t pixels;
    int rwidth;
    int rheight;
    int vwidth;
    int vheight;

    __host__ __device__ raster_interpolation_config_parent(
                int rwidth,
                int rheight,
                int vwidth,
                int vheight) :
            pixels(vwidth),
            rwidth(rwidth),
            rheight(rheight),
            vwidth(vwidth),
            vheight(vheight) {
        // pass
    }
};

struct interpolation_results_filter_none {
    int width;
    double* average_values;
    double* average_weight_sum;

    __device__ interpolation_results_filter_none(int width) :
            width(width),
            average_values(nullptr),
            average_weight_sum(nullptr) {
        // pass
    };

    // warning: no bounds checking
    __device__ void add_result_reduce(int x, int y, double value_weighted, double weight) {
        const int index = y*width + x;
        average_values[index] += value_weighted * weight;
        average_weight_sum[index] += weight;
    }

};

template<RasterFilter raster_filter>
struct raster_interpolation_config {};

template<RasterFilterMinMax raster_filter>
struct raster_interpolation_config<raster_filter> : raster_interpolation_config_parent<pixel_array<interpolation_result_min_max>> {
    using raster_interpolation_config_parent<pixel_array<interpolation_result_min_max>>::raster_interpolation_config_parent;
};

template<RasterFilterNone raster_filter>
struct raster_interpolation_config<raster_filter> : raster_interpolation_config_parent<interpolation_results_filter_none> {
    using raster_interpolation_config_parent<interpolation_results_filter_none>::raster_interpolation_config_parent;
};

template<RasterFilterMinMax raster_filter>
__global__ void init_pixel_array_header(raster_interpolation_config<raster_filter> ri_conf) {
    const int idx = blockIdx.x*blockDim.x + threadIdx.x;
    const int idy = blockIdx.y*blockDim.y + threadIdx.y;

    // initialize *(ri_conf.pixels.header_array) in a grid stride loop
    for (int vy = idy; vy < ri_conf.vheight; vy += blockDim.y * gridDim.y) {
        for (int vx = idx; vx < ri_conf.vwidth; vx += blockDim.x * gridDim.x) {
            ri_conf.pixels.init_header(vx, vy);
        }
    }
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__global__ void raster_interpolation(
        raster_interpolation_config<raster_filter> ri_conf,
        const raster_point* __restrict__ raster_image) {
    __shared__ cuda::std::array<cuda::std::array<raster_point, blockSizeX+1>, blockSizeY+1> shared_rpoints;

    const int idx = blockIdx.x * blockSizeX + threadIdx.x;
    const int idy = blockIdx.y * blockSizeY + threadIdx.y;
    const int idb = threadIdx.y * blockSizeX + threadIdx.x;

    const int x_stride = blockSizeX * gridDim.x;
    const int y_stride = blockSizeY * gridDim.y;

    const int rx_leftover_pre = ri_conf.rwidth % x_stride;
    const int rx_leftover = cuda::std::min(ri_conf.rwidth, (rx_leftover_pre == 0 ? x_stride : rx_leftover_pre));
    const int rx_max = ri_conf.rwidth - rx_leftover;

    const int ry_leftover_pre = ri_conf.rheight % y_stride;
    const int ry_leftover = cuda::std::min(ri_conf.rheight, (ry_leftover_pre == 0 ? y_stride : ry_leftover_pre));
    const int ry_max = ri_conf.rheight - ry_leftover;
    
    const int extra_x =
        idb < blockSizeY ?
            blockSizeX : ((idb < blockSizeX + blockSizeY + 1) ?
            (idb - blockSizeY) : (-1));
    const int extra_y = 
        idb < blockSizeY ?
            idb : (idb < blockSizeX + blockSizeY + 1 ?
            blockSizeY : (-1));

    int ry;
    const bool full_block_x = rx_leftover > blockSizeX * (blockIdx.x + 1);
    const int idb_limit_max_x_pre = rx_leftover % blockSizeX;
    const int idb_limit_max_x = blockSizeY + (idb_limit_max_x_pre == 0 ? blockSizeX : idb_limit_max_x_pre);
    for (ry = idy; ry < ry_max; ry += y_stride) {
        const raster_point* pitched_raster_points = raster_image + ry*ri_conf.rwidth;
        int rx;
        const int extra_current = (ry - threadIdx.y + extra_y) * ri_conf.rwidth - threadIdx.x + extra_x;
        for (rx = idx; rx < rx_max; rx += x_stride) {
            shared_rpoints[threadIdx.y][threadIdx.x] = pitched_raster_points[rx];
            if (idb < blockSizeY + blockSizeX + 1) {
                shared_rpoints[extra_y][extra_x] = raster_image[extra_current + rx];
            }

            __syncthreads();
            create_triangles<blockSizeX, blockSizeY, raster_filter>(shared_rpoints, ri_conf, rx, ry);
            __syncthreads();
        }

        if (rx < ri_conf.rwidth && rx_leftover > blockSizeX * blockIdx.x + 1) { 
            shared_rpoints[threadIdx.y][threadIdx.x] = pitched_raster_points[rx];
        }
        if (full_block_x && idb < blockSizeX + blockSizeY + 1 || !full_block_x && idb >= blockSizeY && idb < idb_limit_max_x) {
            shared_rpoints[extra_y][extra_x] = raster_image[extra_current + rx];
        }
        __syncthreads();
        if (rx < ri_conf.rwidth - 1) {
            create_triangles<blockSizeX, blockSizeY, raster_filter>(shared_rpoints, ri_conf, rx, ry);
        }
        __syncthreads();
    }
    const raster_point* pitched_raster_points = raster_image + ry*ri_conf.rwidth;
    const int extra_current = (ry - threadIdx.y + extra_y) * ri_conf.rwidth - threadIdx.x + extra_x;
    const bool full_block_y = ry_leftover > blockSizeY * (blockIdx.y + 1);
    const int idb_limit_max_y_pre = ry_leftover % blockSizeY;
    const int idb_limit_max_y = (idb_limit_max_y_pre == 0 ? blockSizeY : idb_limit_max_y_pre);
    int rx;
    for (rx = idx; rx < rx_max; rx += x_stride) {
        if (ry < ri_conf.rheight && ry_leftover > blockSizeY * blockIdx.y + 1) {
            shared_rpoints[threadIdx.y][threadIdx.x] = pitched_raster_points[rx];
            if (full_block_y && idb < blockSizeX + blockSizeY + 1 || !full_block_y && idb < idb_limit_max_y) {
                shared_rpoints[extra_y][extra_x] = raster_image[extra_current + rx];
            }
        }
        __syncthreads();
        if (ry < ri_conf.rheight - 1) {
            create_triangles<blockSizeX, blockSizeY, raster_filter>(shared_rpoints, ri_conf, rx, ry);
        }
        __syncthreads();
    }
    
    if (rx < ri_conf.rwidth && ry < ri_conf.rheight) {
        shared_rpoints[threadIdx.y][threadIdx.x] = pitched_raster_points[rx];
    }
    if (full_block_x && full_block_y && idb < blockSizeX + blockSizeY + 1 || full_block_y && idb >= blockSizeY && idb < idb_limit_max_x || full_block_x && idb < idb_limit_max_y) {
        shared_rpoints[extra_y][extra_x] = raster_image[extra_current + rx];
    }
    __syncthreads();
    if (rx < ri_conf.rwidth - 1 && ry < ri_conf.rheight - 1) {
        create_triangles<blockSizeX, blockSizeY, raster_filter>(shared_rpoints, ri_conf, rx, ry);
    }
    __syncthreads();
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__device__ void create_triangles(
        cuda::std::array<cuda::std::array<raster_point, blockSizeX+1>, blockSizeY+1> &shared_rpoints,
        raster_interpolation_config<raster_filter> &ri_conf,
        int rx,
        int ry) {

    // either 0, 1 or 4 triangles are found
    int rpoint_count = 0;
    int non_existing_tri = 0;

    if (shared_rpoints[threadIdx.y][threadIdx.x].exists()) {
        rpoint_count++;
    } // else non_existing_tri = 0;
    if (shared_rpoints[threadIdx.y][threadIdx.x+1].exists()) {
        rpoint_count++;
    } else {
        non_existing_tri = 1;
    }
    if (shared_rpoints[threadIdx.y+1][threadIdx.x].exists()) {
        rpoint_count++;
    } else {
        non_existing_tri = 2;
    }
    if (shared_rpoints[threadIdx.y+1][threadIdx.x+1].exists()) {
        rpoint_count++;
    } else {
        non_existing_tri = 3;
    }
    
    // atleast one triangle
    if (rpoint_count >= 3) {
        // use binary logic to determine triangles
        char tri_x = static_cast<char>(non_existing_tri >> 1);
        char not_tri_x = tri_x^0x01;
        char tri_y = static_cast<char>(non_existing_tri & 0x01);
        char not_tri_y = tri_y^0x01;

        // triangle 1
        r_triangle<blockSizeX, blockSizeY, raster_filter> tri_1(
            shared_rpoints,
            threadIdx.y,                threadIdx.x+(not_tri_x&not_tri_y),  // px1, py1
            threadIdx.y + not_tri_x,    threadIdx.x+tri_x,                  // px2, py2
            threadIdx.y + 1,            threadIdx.x+(not_tri_x|not_tri_y),  // px3, py3
            ry, rx);
        process_triangle(
            tri_1,
            ri_conf);

        // 4 triangles total
        if (rpoint_count == 4) {
            // triangles 2-4
            r_triangle<blockSizeX, blockSizeY, raster_filter> tri_2(
                shared_rpoints,
                threadIdx.y,                    threadIdx.x + (tri_x&tri_y), 
                threadIdx.y + 1-(tri_x^tri_y),  threadIdx.x + (tri_x^tri_y),      
                threadIdx.y + 1,                threadIdx.x + (not_tri_x|tri_y),
                ry, rx);
            process_triangle(
                tri_2,
                ri_conf);
            r_triangle<blockSizeX, blockSizeY, raster_filter> tri_3(
                shared_rpoints,
                threadIdx.y,                    threadIdx.x + (tri_x&not_tri_y),
                threadIdx.y + tri_x,            threadIdx.x + not_tri_x,  
                threadIdx.y + 1,                threadIdx.x + (tri_x|not_tri_y),
                ry, rx);
            process_triangle(
                tri_3,
                ri_conf);
            r_triangle<blockSizeX, blockSizeY, raster_filter> tri_4(
                shared_rpoints,
                threadIdx.y,                    threadIdx.x + (not_tri_x&tri_y),
                threadIdx.y + (tri_x^tri_y),    threadIdx.x + 1-(tri_x^tri_y),
                threadIdx.y + 1,                threadIdx.x + (tri_x|tri_y),
                ry, rx);
            process_triangle(
                tri_4,
                ri_conf);
        }
    }
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__device__ void process_triangle(const r_triangle<blockSizeX, blockSizeY, raster_filter> &tri, raster_interpolation_config<raster_filter> &ri_conf) {
    // bounding box
    const int fx = cuda::std::clamp(
        static_cast<int>(cuda::std::floor(cuda::std::min({tri.p1()->x, tri.p2()->x, tri.p3()->x}))),
        0,
        ri_conf.vwidth - 1);
    const int tx = cuda::std::clamp(
        static_cast<int>(cuda::std::ceil(cuda::std::max({tri.p1()->x, tri.p2()->x, tri.p3()->x}))),
        0,
        ri_conf.vwidth - 1);
    if (fx == tx) {
        return;
    }
    const int fy = cuda::std::clamp(
        static_cast<int>(cuda::std::floor(cuda::std::min({tri.p1()->y, tri.p2()->y, tri.p3()->y}))),
        0,
        ri_conf.vheight - 1);
    const int ty = cuda::std::clamp(
        static_cast<int>(cuda::std::ceil(cuda::std::max({tri.p1()->y, tri.p2()->y, tri.p3()->y}))),
        0,
        ri_conf.vheight - 1);
    if (fy == ty) {
        return;
    }

    int hits = 0; // bitwise counting, 32 entries in 32-bit int
    int count = 0;
    constexpr int hits_bitsize = sizeof(hits)*8;
    // const int final_count = (tx - fx) * (ty - fy);
    uint32_t base = 0;
    for (int vy = fy; vy <= ty; vy++) {
        for (int vx = fx; vx <= tx; vx++) {
            hits = hits << 1;
            if (in_tri(tri, vx, vy)) {
                hits++;
            }
            count++;
            if (count >= hits_bitsize) {
                multiple_tri_interpolations(tri, ri_conf, fx, tx, fy, ty, hits, base);
                base += hits_bitsize;
                count = 0;
                hits = 0;
            }
        }
    }
    multiple_tri_interpolations(tri, ri_conf, fx, tx, fy, ty, hits<<(32-count), base);
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__device__ bool in_tri(const r_triangle<blockSizeX, blockSizeY, raster_filter> &tri, int vx, int vy) {
    auto sign = [](
        const double p1x, const double p1y,
        const double p2x, const double p2y,
        const double p3x, const double p3y) -> double {
            return (p1x - p3x) * (p2y - p3y) - (p2x - p3x) * (p1y - p3y);
        };

    const double d1 = sign(vx, vy, tri.p1()->x, tri.p1()->y, tri.p2()->x, tri.p2()->y);
    const double d2 = sign(vx, vy, tri.p2()->x, tri.p2()->y, tri.p3()->x, tri.p3()->y);
    const double d3 = sign(vx, vy, tri.p3()->x, tri.p3()->y, tri.p1()->x, tri.p1()->y);

    const bool neg = (d1 < 0) || (d2 < 0) || (d3 < 0);
    const bool pos = (d1 > 0) || (d2 > 0) || (d3 > 0);

    return !(neg && pos);
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__device__ void tri_interpolation(
        const r_triangle<blockSizeX, blockSizeY, raster_filter> &tri,
        raster_interpolation_config<raster_filter> &ri_conf,
        int next_hit_px,
        int next_hit_py) {
    auto area = [](
        const double p1x, const double p1y,
        const double p2x, const double p2y,
        const double p3x, const double p3y) -> double {
            auto distance = [](
                const double p1x, const double p1y,
                const double p2x, const double p2y) -> double {
                    auto sqr = [](const double v) -> double {
                        return v * v;
                    };
                    return cuda::std::sqrt(sqr(p1x - p2x) + sqr(p1y - p2y));
                };
            const double a = distance(p1x, p1y, p2x, p2y);
            const double b = distance(p2x, p2y, p3x, p3y);
            const double c = distance(p3x, p3y, p1x, p1y);
            const double s = (a + b + c) / 2.;
            return std::sqrt(s * (s - a) * (s - b) * (s - c));
        };

    const double area_1 = area(next_hit_px, next_hit_py, tri.p2()->x, tri.p2()->y, tri.p3()->x, tri.p3()->y);
    const double area_2 = area(next_hit_px, next_hit_py, tri.p3()->x, tri.p3()->y, tri.p1()->x, tri.p1()->y);
    const double area_3 = area(next_hit_px, next_hit_py, tri.p1()->x, tri.p1()->y, tri.p2()->x, tri.p2()->y);
    const double area_sum = area_1 + area_2 + area_3;

    const double weight_1 = area_1 / area_sum;
    const double weight_2 = area_2 / area_sum;
    const double weight_3 = area_3 / area_sum;

    const double weighted_value = 
        tri.p1()->v * weight_1 +
        tri.p2()->v * weight_2 +
        tri.p3()->v * weight_3;
        
    double nearest_weight;

    if constexpr(RasterFilterMinMax<raster_filter>) {
        int rx, ry;
        cuda::std::tie(nearest_weight, rx, ry) = cuda::std::max(
           {cuda::std::tuple{weight_1, tri.absolute_rx1(), tri.absolute_ry1()},
            cuda::std::tuple{weight_2, tri.absolute_rx2(), tri.absolute_ry2()},
            cuda::std::tuple{weight_3, tri.absolute_rx3(), tri.absolute_ry3()}},
            [](auto v1, auto v2) {
                return cuda::std::get<0>(v1) < cuda::std::get<0>(v2);
            });

        ri_conf.pixels.push_back(next_hit_px, next_hit_py, {weighted_value, nearest_weight, rx, ry});
    } else { // RasterFilterNone
        nearest_weight = cuda::std::max({weight_1, weight_2, weight_3});
        
        ri_conf.pixels.add_result_reduce(next_hit_px, next_hit_py, weighted_value, nearest_weight);
    }
}

template<int blockSizeX, int blockSizeY, RasterFilter raster_filter>
__device__ void multiple_tri_interpolations(
        const r_triangle<blockSizeX, blockSizeY, raster_filter> &tri,
        raster_interpolation_config<raster_filter> &ri_conf,
        int fx,
        int tx,
        int fy,
        int ty,
        int hits,
        uint32_t base) {
    int hits_left = __popc(hits);
    bool hits_non_empty = hits_left > 0;
    uint32_t hit_index = base;

    const int box_width = tx - fx + 1;

    int next_hit_px = -1;
    int next_hit_py = -1;
    while (hits_non_empty) {
        next_hit_px = -1;
        while (next_hit_px == -1) {
            if (hits & 0x80000000) {
                next_hit_px = fx + hit_index % box_width;
                next_hit_py = fy + hit_index / box_width;
            }
            hits = hits << 1;
            hit_index++;
        }

        tri_interpolation(tri, ri_conf, next_hit_px, next_hit_py);

        hits_left--;
        hits_non_empty = hits_left > 0;
    }
}

template<int blockSizeX, int blockSizeY>
__global__ void filter_averaging_none(raster_interpolation_config<filter_none> ri_conf) {
    const int idx = blockIdx.x*blockSizeX + threadIdx.x;
    const int idy = blockIdx.y*blockSizeY + threadIdx.y;

    const int y_stride = blockSizeY * gridDim.y;
    const int x_stride = blockSizeX * gridDim.x;

    double *average_values = ri_conf.pixels.average_values; // is also output
    double *average_weight_sum = ri_conf.pixels.average_weight_sum;

    for (int vy = idy; vy < ri_conf.vheight; vy += y_stride) {
        const int index_base = vy * ri_conf.vwidth;
        for (int vx = idx; vx < ri_conf.vwidth; vx += x_stride) {
            const int index = index_base + vx;

            average_values[index] = average_values[index] / average_weight_sum[index];
        }
    }
}

template<int blockSizeX, int blockSizeY, RasterFilterMinMax filter_type>
__global__ void filter_averaging_min_max(
        raster_interpolation_config<filter_type> ri_conf,
        double* __restrict__ out_image) {
    const int idx = blockIdx.x*blockSizeX + threadIdx.x;
    const int idy = blockIdx.y*blockSizeY + threadIdx.y;

    const int y_stride = blockSizeY * gridDim.y;
    const int x_stride = blockSizeX * gridDim.x;

    for (int vy = idy; vy < ri_conf.vheight; vy += y_stride) {
        const int index_base = vy * ri_conf.vwidth;
        for (int vx = idx; vx < ri_conf.vwidth; vx += x_stride) {
            const int index = index_base + vx;

            pixel_array<interpolation_result_min_max>::pixel_array_header* header_array = &(ri_conf.pixels.header_array[index]);

            const int length = header_array->last;
            if (length == 0) {
                out_image[index] = cuda::std::numeric_limits<double>::quiet_NaN();
            } else {
                constexpr int preallocated = decltype(ri_conf.pixels)::preallocated_v;
                const int data_index_base = index * preallocated;

                interpolation_result_min_max i_res = ri_conf.pixels.data_array[data_index_base+0];
                double min_max_value = i_res.value_weighted;
                int min_max_rx = i_res.rx;
                int min_max_ry = i_res.ry;

                auto min_max = [](double min_max_value, int min_max_rx, int min_max_ry, const interpolation_result_min_max &i_res){
                    if constexpr (std::is_same_v<filter_type, struct filter_min>) {
                        return cuda::std::min(
                           {cuda::std::tuple{min_max_value, min_max_rx, min_max_ry},
                            cuda::std::tuple{i_res.value_weighted, i_res.rx, i_res.ry}},
                            [](auto v1, auto v2) {
                                return cuda::std::get<0>(v1) < cuda::std::get<0>(v2);
                            });
                    } else { // filter_max
                        return cuda::std::max(
                           {cuda::std::tuple{min_max_value, min_max_rx, min_max_ry},
                            cuda::std::tuple{i_res.value_weighted, i_res.rx, i_res.ry}},
                            [](auto v1, auto v2) {
                                return cuda::std::get<0>(v1) < cuda::std::get<0>(v2);
                            });
                    }
                };

                for (int fixed_data_array_i = 1; fixed_data_array_i < cuda::std::min({preallocated, length}); fixed_data_array_i++) {
                    i_res = ri_conf.pixels.data_array[data_index_base + fixed_data_array_i];
                    cuda::std::tie(min_max_value, min_max_rx, min_max_ry) = min_max(min_max_value, min_max_rx, min_max_ry, i_res);
                }

                int leftover_length = length - preallocated;
                pixel_array<interpolation_result_min_max>::pixel_vector_header* next_array = header_array->next_header;
                while (leftover_length > 0) {
                    const int elements_in_array = cuda::std::min({next_array->allocated_size, leftover_length});
                    for (int vector_data_array_i = 0; vector_data_array_i < elements_in_array; vector_data_array_i++) {
                        i_res = *(next_array->get(vector_data_array_i));
                        cuda::std::tie(min_max_value, min_max_rx, min_max_ry) = min_max(min_max_value, min_max_rx, min_max_ry, i_res);
                    }
                    leftover_length = leftover_length - next_array->allocated_size;
                    next_array = next_array->next_header;
                }

                // calc running average
                double average_value = 0;
                double average_weight_sum = 0;

                min_max_rx--;
                min_max_ry--;
                
                auto min_max_filtering = [&](const interpolation_result_min_max &i_res){
                    // -> in each loop, filter for (rx, ry)
                    const int rel_rx = i_res.rx - min_max_rx;
                    const int rel_ry = i_res.ry - min_max_ry;
                    if (2 >= rel_rx && rel_rx >= 0 && 2 >= rel_ry && rel_ry >= 0) {
                        // --> add entry to running average
                        average_value += i_res.value_weighted * i_res.weight;
                        average_weight_sum += i_res.weight;
                    }
                };

                // loop over fixed_data_array
                for (int fixed_data_array_i = 0; fixed_data_array_i < cuda::std::min({preallocated, length}); fixed_data_array_i++) {
                    i_res = ri_conf.pixels.data_array[data_index_base + fixed_data_array_i];
                    min_max_filtering(i_res);
                }
                
                // loop over linked array list
                leftover_length = length - preallocated;
                next_array = header_array->next_header;
                while (leftover_length > 0) {
                    const int elements_in_array = cuda::std::min({next_array->allocated_size, leftover_length});
                    for (int vector_data_array_i = 0; vector_data_array_i < elements_in_array; vector_data_array_i++) {
                        i_res = *(next_array->get(vector_data_array_i));
                        min_max_filtering(i_res);
                    }
                    leftover_length = leftover_length - next_array->allocated_size;
                    next_array = next_array->next_header;
                }

                // finish running average
                average_value = average_value / average_weight_sum;

                // record result in output array
                out_image[index] = average_value;
            }
        }
    }

}

template<RasterFilter raster_filter>
bmp::bitmap<double> to_image(
        std::size_t const vwidth,
        std::size_t const vheight,
        std::vector<ply2image::raster_point> const& points) {
    const ply2image::raster_range range = ply2image::find_raster_range(points);
    if(range.w() < 2 || range.h() < 2){
        throw std::runtime_error("raster interpolation requires at least 2 columns and 2 rows");
    }

    fmt::print("raster with origin {:d}x{:d} and size {:d}x{:d}\n",
        range.min_x, range.min_y, range.w(), range.h());
    
    ply2image::percent_printer progress(30, "base line");

    // use custom raster_point instead of ply2image::raster_point
    int rwidth = range.w();
    int rheight = range.h();
    int rimage_size = rwidth * rheight;

    raster_point *raster_image = new raster_point[rimage_size];
    
    // init raster_image, as default constructor is insufficient for this struct
    raster_point empty_rpoint = raster_point::empty();
    for (int i=0; i<rimage_size; i++) {
        raster_image[i] = empty_rpoint;
    }

    progress.init("create raster image", points.size());
    for (const ply2image::raster_point &p: points) {
        auto const printer = progress.lazy_inc();

        raster_point &target_p = raster_image[range.y(p.ry)*rwidth + range.x(p.rx)];
        if (target_p.exists()) {
            throw std::runtime_error(fmt::format("raster point {:d}x{:d} exists twice", p.rx, p.ry));
        }
        target_p = p;
    }

    fmt::print("starting raster interpolation on gpu\n");

    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);

    if (deviceCount == 0) {
        fmt::print("No Cuda devices found.\nExiting...\n");
        exit(1);
    }

    if (deviceCount > 1) {
        fmt::print("Multiple CUDA devices detected.\nDefaulting to device 0.\n");
    }

    cudaDeviceProp deviceProp;
    cudaGetDeviceProperties(&deviceProp, 0);
    

    raster_interpolation_config<raster_filter> ri_config(rwidth, rheight, vwidth, vheight);

    // TODO: make this dynamic and check whether enough memory is provided by the gpu
    checkCudaErrors(cudaDeviceSetLimit(cudaLimitMallocHeapSize, 1610612736));

    // TODO: use cudaMallocPitch for 2d memory allocation?
    int vpixel_count = vwidth*vheight;

    constexpr int blockDimX = 8;
    constexpr int blockDimY = 4;
    dim3 blockDim(blockDimX, blockDimY);

    int threadCount = deviceProp.multiProcessorCount * deviceProp.maxThreadsPerMultiProcessor;
    const double sharedMemPerThread = static_cast<double>(deviceProp.sharedMemPerMultiprocessor)/deviceProp.maxThreadsPerMultiProcessor;
    const double factorSharedMem = std::min<double>(1.0, sharedMemPerThread/(sizeof(raster_point) * (blockDimX + 1) * (blockDimY + 1) / (blockDimX * blockDimY)));
    const double targetThreadCount = factorSharedMem * threadCount;
    const int newGridLength = static_cast<int>(std::floor(std::sqrt(targetThreadCount/(blockDim.x*blockDim.y))));
    
    dim3 gridDim(newGridLength, newGridLength);

    // init pixels of ri_config if min/max filter
    if constexpr(RasterFilterMinMax<raster_filter>) {
        pixel_array<interpolation_result_min_max> &pixels = ri_config.pixels;
        checkCudaErrors(cudaMalloc(
            &(pixels.header_array),
            vpixel_count*(sizeof(decltype(*(pixels.header_array))) + pixels.get_preallocated()*sizeof(interpolation_result_min_max))));
        pixels.data_array = reinterpret_cast<interpolation_result_min_max*>(pixels.header_array + vpixel_count);
        
        init_pixel_array_header<<<gridDim, blockDim>>>(ri_config);
        cudaDeviceSynchronize();
        checkCudaErrors(cudaPeekAtLastError());
    } else { // init pixels of ri_config if none filter
        interpolation_results_filter_none &pixels = ri_config.pixels;
        checkCudaErrors(cudaMalloc(
            &(pixels.average_values),
            vpixel_count*2*(sizeof(double))));
        pixels.average_weight_sum = pixels.average_values + vpixel_count;

        checkCudaErrors(cudaMemset(
            pixels.average_values,
            0,
            vpixel_count*2*(sizeof(double))));
    }


    int bytesize_rimage = rwidth*rheight*sizeof(raster_point);
    raster_point *d_raster_image;
    checkCudaErrors(cudaMalloc(
        &d_raster_image,
        bytesize_rimage));
    checkCudaErrors(cudaMemcpy(d_raster_image, raster_image, bytesize_rimage, cudaMemcpyHostToDevice));

    checkCudaErrors(cudaFuncSetCacheConfig(raster_interpolation<blockDimX, blockDimY, raster_filter>, cudaFuncCachePreferShared));
    raster_interpolation<blockDimX, blockDimY><<<gridDim, blockDim>>>(ri_config, d_raster_image);

    double* d_out_image;
    if constexpr (RasterFilterMinMax<raster_filter>) {
        cudaMalloc(
            &d_out_image,
            vpixel_count * sizeof(double)
        );
    }

    cudaDeviceSynchronize();
    checkCudaErrors(cudaPeekAtLastError());

    if constexpr (RasterFilterMinMax<raster_filter>) {
        checkCudaErrors(cudaFuncSetCacheConfig(filter_averaging_min_max<blockDimX, blockDimY, raster_filter>, cudaFuncCachePreferL1));
        filter_averaging_min_max<blockDimX, blockDimY, raster_filter><<<gridDim, blockDim>>>(ri_config, d_out_image);
    } else {
        checkCudaErrors(cudaFuncSetCacheConfig(filter_averaging_none<blockDimX, blockDimY>, cudaFuncCachePreferL1));
        filter_averaging_none<blockDimX, blockDimY><<<gridDim, blockDim>>>(ri_config);
        d_out_image = ri_config.pixels.average_values;
    }
    cudaDeviceSynchronize();
    checkCudaErrors(cudaPeekAtLastError());

    double* out_image_dyn = reinterpret_cast<double *>(malloc(vpixel_count * sizeof(double)));
    if (out_image_dyn==nullptr) {
        throw std::runtime_error("malloc() returned null");
    }
    checkCudaErrors(cudaMemcpy(out_image_dyn, d_out_image, vpixel_count * sizeof(double), cudaMemcpyDeviceToHost));

    const bmp::bitmap<double>::size_type out_image_size(vwidth, vheight);
    bmp::bitmap<double> image(out_image_size, out_image_dyn, out_image_dyn + vpixel_count);

    free(out_image_dyn);

    return image;
}

bmp::bitmap<double> to_image_filter_min(
        std::size_t const width,
        std::size_t const height,
        std::vector<ply2image::raster_point> const& points) {
    return to_image<filter_min>(width, height, points);
}

bmp::bitmap<double> to_image_filter_max(
        std::size_t const width,
        std::size_t const height,
        std::vector<ply2image::raster_point> const& points) {
    return to_image<filter_max>(width, height, points);
}

bmp::bitmap<double> to_image_filter_none(
        std::size_t const width,
        std::size_t const height,
        std::vector<ply2image::raster_point> const& points) {
    return to_image<filter_none>(width, height, points);
}


} // namespace tmrpcuda
} // namespace ply2image