add_library(AsteriskTime
    time_client.cpp)

target_include_directories(AsteriskTime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(AsteriskTime PUBLIC rt)
