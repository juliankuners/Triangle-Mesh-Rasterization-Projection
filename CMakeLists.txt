cmake_minimum_required(VERSION 3.20)

project(ply2image LANGUAGES CXX CUDA)

set(DEFAULT_BUILD_TYPE "Release")

find_package(fmt REQUIRED)
find_package(PNG REQUIRED)
find_package(argparse REQUIRED)
find_package(CUDAToolkit REQUIRED)

add_executable(${PROJECT_NAME}
"${CMAKE_SOURCE_DIR}/src/main.cpp"
"${CMAKE_SOURCE_DIR}/src/ply2image/argparse.cpp"
"${CMAKE_SOURCE_DIR}/src/ply2image/progress_bar.cpp"
"${CMAKE_SOURCE_DIR}/src/ply2image/cuda/tmrp.cu"
)
target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_23)
target_link_libraries(${PROJECT_NAME} fmt::fmt)
target_link_libraries(${PROJECT_NAME} PNG::PNG)
target_link_libraries(${PROJECT_NAME} argparse::argparse)

target_include_directories(${PROJECT_NAME} PRIVATE ${CUDAToolkit_INCLUDE_DIRS})

function(CUDA_CONVERT_FLAGS EXISTING_TARGET)
    get_property(old_flags TARGET ${EXISTING_TARGET} PROPERTY INTERFACE_COMPILE_OPTIONS)
    if(NOT "${old_flags}" STREQUAL "")
        string(REPLACE ";" "," CUDA_flags "${old_flags}")
        set_property(TARGET ${EXISTING_TARGET} PROPERTY INTERFACE_COMPILE_OPTIONS
            "$<$<BUILD_INTERFACE:$<COMPILE_LANGUAGE:CXX>>:${old_flags}>$<$<BUILD_INTERFACE:$<COMPILE_LANGUAGE:CUDA>>:-Xcompiler=${CUDA_flags}>"
            )
    endif()
endfunction()

if(MSVC)
  target_compile_options(${PROJECT_NAME} INTERFACE  /W4 )
  # target_link_options(${PROJECT_NAME} PUBLIC /NODEFAULTLIB:libcmt.lib /NODEFAULTLIB:libcmtd.lib /NODEFAULTLIB:msvcrtd.lib) # release dll
  # target_link_options(${PROJECT_NAME} PUBLIC /NODEFAULTLIB:msvcrt.lib /NODEFAULTLIB:libcmtd.lib /NODEFAULTLIB:msvcrtd.lib) # release static
  target_link_options(${PROJECT_NAME} PUBLIC /NODEFAULTLIB:libcmt.lib /NODEFAULTLIB:libcmtd.lib /NODEFAULTLIB:msvcrt.lib) # debug dll
  # target_link_options(${PROJECT_NAME} PUBLIC /NODEFAULTLIB:libcmt.lib /NODEFAULTLIB:libcmtd.lib /NODEFAULTLIB:msvcrt.lib) # debug static
  # target_link_options(${PROJECT_NAME} PUBLIC /NODEFAULTLIB:libcmt.lib /NODEFAULTLIB:msvcrtd.lib) # debug static release dll
else()
  target_compile_options(${PROJECT_NAME} INTERFACE  -Wall -Wextra -Wpedantic -Wconversion -Werror)
endif()

# include the next line for a CUDA debug build
# target_compile_options(${PROJECT_NAME} PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:--generate-line-info -G>)
target_compile_options(${PROJECT_NAME} PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-maxrregcount=64>)
target_compile_options(${PROJECT_NAME} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-O3>)

CUDA_CONVERT_FLAGS(${PROJECT_NAME})

if(APPLE)
  # We need to add the path to the driver (libcuda.dylib) as an rpath, 
  # so that the static cuda runtime can find it at runtime.
  set_property(TARGET ply2image 
               PROPERTY
               BUILD_RPATH ${CMAKE_CUDA_IMPLICIT_LINK_DIRECTORIES})
endif()
