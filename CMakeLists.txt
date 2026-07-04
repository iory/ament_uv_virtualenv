cmake_minimum_required(VERSION 3.8)
project(ament_uv_virtualenv NONE)

find_package(ament_cmake REQUIRED)

# Helper macros — included by the auto-generated <pkg>Config.cmake when a
# downstream package does `find_package(ament_uv_virtualenv)`.
install(
  DIRECTORY cmake/
  DESTINATION share/${PROJECT_NAME}/cmake
)

# Templates used by ament_uv_install_python_scripts() to materialize wrappers.
install(
  DIRECTORY templates/
  DESTINATION share/${PROJECT_NAME}/templates
)

ament_package(
  CONFIG_EXTRAS "ament_uv_virtualenv-extras.cmake"
)
