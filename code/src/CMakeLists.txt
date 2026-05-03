add_subdirectory(time)

add_library(Asterisk
    io/bcast_bus.cpp
    net/tdma_scheduler.cpp
    utils/circuit.cpp
    utils/types.cpp
    utils/helpers.cpp
    asterisk/sharing.cpp
    asterisk/rand_gen_pool.cpp
    asterisk/offline_evaluator.cpp
    asterisk/online_evaluator_load_balanced.cpp
    assistedMPC/sharing.cpp
    assistedMPC/rand_gen_pool.cpp
    assistedMPC/offline_evaluator.cpp)

target_include_directories(Asterisk PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(Asterisk PUBLIC Boost::system EMPTool NTL GMP AsteriskTime nlohmann_json::nlohmann_json)
