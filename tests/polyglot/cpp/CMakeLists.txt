cmake_minimum_required(VERSION 3.20)
project(polyglot_smoke_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(greet greet.cpp)
add_executable(test_greet test_greet.cpp)
target_link_libraries(test_greet PRIVATE greet)

enable_testing()
add_test(NAME greet COMMAND test_greet)
