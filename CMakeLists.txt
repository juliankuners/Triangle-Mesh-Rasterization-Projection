cmake_minimum_required(VERSION 3.20)

project(ply2image LANGUAGES CXX)

set(DEFAULT_BUILD_TYPE "Release")

find_package(fmt REQUIRED)
find_package(PNG REQUIRED)
find_package(argparse REQUIRED)

add_executable(${PROJECT_NAME}
"${CMAKE_SOURCE_DIR}/src/main.cpp"
"${CMAKE_SOURCE_DIR}/src/ply2image/argparse.cpp"
"${CMAKE_SOURCE_DIR}/src/ply2image/progress_bar.cpp"
)
target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_23)
target_link_libraries(${PROJECT_NAME} fmt::fmt)
target_link_libraries(${PROJECT_NAME} PNG::PNG)
target_link_libraries(${PROJECT_NAME} argparse::argparse)

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

target_compile_options(${PROJECT_NAME} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-O3>)

