# CUDA strategy

Problem is compute bound and heavily uses FP64 instructions.

2 different cases of execution:
- without a reference filter
- with a reference filter, either min or max

#### Case 1: without a reference filter
kernels:
- (1) raster_interpolation
  - load raster points
  - create triangles
  - perform triangle interpolation
  - recude & keep 1 result per pixel in global memory
- (2) filter_averaging_none:
  - finish calculating average per pixel

#### Case 2: with a reference filter
kernels:
- (1) init_pixel_array_header:
  - init headers of result array
    - mixed async array/linked array list 
- (1) raster_interpolation:
  - load raster points
  - create triangles
  - perform triangle interpolation
  - record results in global memory
- (2) filter_averaging_min_max:
  - load interpolation results
  - perform raster filtering
  - calculate average
