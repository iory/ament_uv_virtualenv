# ament_uv_install_python_scripts()
#
# Install Python entry points whose runtime interpreter is the package-local
# venv created by ament_generate_virtualenv().
#
# For each program:
#   * the original .py is installed to share/<pkg>/scripts/<basename>
#   * a bash wrapper that exec's the venv's python is installed to
#     lib/<pkg>/<wrapper-name>, so it is discoverable by `ros2 run`.
#
# Usage:
#   ament_uv_install_python_scripts(
#     PROGRAMS scripts/foo.py scripts/bar.py
#     [DESTINATION lib/<pkg>]               # wrapper destination (default: lib/<pkg>)
#     [SCRIPTS_DESTINATION share/<pkg>/scripts]   # python destination
#     [STRIP_PY_EXTENSION]                  # name wrappers without the .py suffix
#   )

function(ament_uv_install_python_scripts)
  cmake_parse_arguments(_AUI
    "STRIP_PY_EXTENSION"
    "DESTINATION;SCRIPTS_DESTINATION"
    "PROGRAMS"
    ${ARGN}
  )

  if(NOT _AUI_PROGRAMS)
    message(FATAL_ERROR "ament_uv_install_python_scripts: PROGRAMS argument is required")
  endif()
  if(NOT _AUI_DESTINATION)
    set(_AUI_DESTINATION "lib/${PROJECT_NAME}")
  endif()
  if(NOT _AUI_SCRIPTS_DESTINATION)
    set(_AUI_SCRIPTS_DESTINATION "share/${PROJECT_NAME}/scripts")
  endif()

  get_property(_VENV_NAME GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_VENV_NAME)
  if(NOT _VENV_NAME)
    message(FATAL_ERROR
      "ament_uv_install_python_scripts: must call ament_generate_virtualenv() "
      "before ament_uv_install_python_scripts()")
  endif()

  set(_TEMPLATE "${ament_uv_virtualenv_DIR}/../templates/python_wrapper.sh.in")
  if(NOT EXISTS "${_TEMPLATE}")
    message(FATAL_ERROR
      "ament_uv_install_python_scripts: wrapper template not found at ${_TEMPLATE}")
  endif()

  set(_WRAPPER_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/_uv_wrappers")
  file(MAKE_DIRECTORY "${_WRAPPER_BUILD_DIR}")

  # Variables consumed by configure_file via @VAR@ substitution. PROJECT_NAME
  # is already defined; the rest are loop-local.
  set(VENV_NAME             "${_VENV_NAME}")
  set(SCRIPTS_DESTINATION   "${_AUI_SCRIPTS_DESTINATION}")

  foreach(_script IN LISTS _AUI_PROGRAMS)
    if(IS_ABSOLUTE "${_script}")
      set(_script_path "${_script}")
    else()
      set(_script_path "${CMAKE_CURRENT_SOURCE_DIR}/${_script}")
    endif()
    if(NOT EXISTS "${_script_path}")
      message(FATAL_ERROR "ament_uv_install_python_scripts: script not found: ${_script_path}")
    endif()

    get_filename_component(_basename "${_script_path}" NAME)
    if(_AUI_STRIP_PY_EXTENSION)
      get_filename_component(_wrapper_name "${_script_path}" NAME_WE)
    else()
      set(_wrapper_name "${_basename}")
    endif()

    set(SCRIPT_BASENAME "${_basename}")
    set(_wrapper_path "${_WRAPPER_BUILD_DIR}/${_wrapper_name}")
    configure_file("${_TEMPLATE}" "${_wrapper_path}" @ONLY)

    # The wrapper is generated under CMAKE_CURRENT_BINARY_DIR. install(PROGRAMS)
    # is overridden by ament_cmake_symlink_install under `colcon build
    # --symlink-install`, and that override does not stage build-tree files
    # correctly — the wrapper ends up missing from install/<pkg>/lib/<pkg>/.
    # Use install(CODE) + file(INSTALL ...) to bypass the override and copy
    # the wrapper directly. The wrapper is generated content, so a real copy
    # is the correct semantic anyway (rebuild regenerates it).
    install(CODE
      "file(INSTALL
            DESTINATION \"\${CMAKE_INSTALL_PREFIX}/${_AUI_DESTINATION}\"
            TYPE PROGRAM
            FILES \"${_wrapper_path}\")")

    # The user's script lives in the source tree; install(PROGRAMS) works
    # correctly under --symlink-install for source-tree files.
    install(PROGRAMS "${_script_path}"
            DESTINATION "${_AUI_SCRIPTS_DESTINATION}")
  endforeach()
endfunction()
