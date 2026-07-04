# ament_uv_check_virtualenv()
#
# Register a CTest test that verifies the committed lockfile is in sync with
# its source REQUIREMENTS file. Run as part of `colcon test`.
#
# A locked file is considered "in sync" when re-running `uv pip compile` on the
# REQUIREMENTS file produces the same set of pinned packages (ignoring comments,
# blank lines, and pip-compile annotations).
#
# This catches the common mistake of editing requirements.in but forgetting to
# re-run the lock target.
#
# Usage:
#   ament_uv_check_virtualenv(
#     [REQUIREMENTS <path>]   # default: same as ament_generate_virtualenv()
#     [LOCKFILE <path>]       # default: same as ament_generate_virtualenv()
#     [UV_CACHE <path>]       # default: same as ament_generate_virtualenv()
#     [TEST_NAME <name>]      # default: <pkg>_lockfile_check
#   )
#
# Must be called after ament_generate_virtualenv() so the requirements/lockfile
# can be inherited if not specified explicitly. Requires BUILD_TESTING (the
# standard ament test gate) for the test to be registered.

function(ament_uv_check_virtualenv)
  cmake_parse_arguments(_AUC
    ""
    "REQUIREMENTS;LOCKFILE;UV_CACHE;TEST_NAME"
    ""
    ${ARGN}
  )

  if(NOT BUILD_TESTING)
    return()
  endif()

  # Inherit defaults from ament_generate_virtualenv() via global properties.
  if(NOT _AUC_REQUIREMENTS)
    get_property(_AUC_REQUIREMENTS GLOBAL PROPERTY
      _ament_uv_virtualenv_${PROJECT_NAME}_REQUIREMENTS)
  elseif(NOT IS_ABSOLUTE "${_AUC_REQUIREMENTS}")
    set(_AUC_REQUIREMENTS "${CMAKE_CURRENT_SOURCE_DIR}/${_AUC_REQUIREMENTS}")
  endif()
  if(NOT _AUC_LOCKFILE)
    get_property(_AUC_LOCKFILE GLOBAL PROPERTY
      _ament_uv_virtualenv_${PROJECT_NAME}_LOCKFILE)
  elseif(NOT IS_ABSOLUTE "${_AUC_LOCKFILE}")
    set(_AUC_LOCKFILE "${CMAKE_CURRENT_SOURCE_DIR}/${_AUC_LOCKFILE}")
  endif()
  if(NOT _AUC_UV_CACHE)
    get_property(_AUC_UV_CACHE GLOBAL PROPERTY
      _ament_uv_virtualenv_${PROJECT_NAME}_UV_CACHE)
  endif()

  if(NOT _AUC_REQUIREMENTS OR NOT _AUC_LOCKFILE)
    message(FATAL_ERROR
      "ament_uv_check_virtualenv: REQUIREMENTS and LOCKFILE are required. "
      "Either pass them explicitly or call ament_generate_virtualenv(LOCKFILE ...) first.")
  endif()

  if(NOT _AUC_TEST_NAME)
    set(_AUC_TEST_NAME "${PROJECT_NAME}_lockfile_check")
  endif()

  find_program(UV_EXECUTABLE uv)
  if(NOT UV_EXECUTABLE)
    message(FATAL_ERROR
      "ament_uv_check_virtualenv: `uv` not found on PATH.")
  endif()

  find_package(Python3 REQUIRED COMPONENTS Interpreter)

  set(_CHECK_SCRIPT
    "${ament_uv_virtualenv_DIR}/../templates/check_lockfile.py")
  if(NOT EXISTS "${_CHECK_SCRIPT}")
    message(FATAL_ERROR
      "ament_uv_check_virtualenv: helper script not found at ${_CHECK_SCRIPT}")
  endif()

  set(_TEST_RESULTS_DIR "${AMENT_TEST_RESULTS_DIR}")
  if(NOT _TEST_RESULTS_DIR)
    set(_TEST_RESULTS_DIR "${CMAKE_BINARY_DIR}/test_results/${PROJECT_NAME}")
  endif()
  file(MAKE_DIRECTORY "${_TEST_RESULTS_DIR}")
  set(_XUNIT_OUT "${_TEST_RESULTS_DIR}/${_AUC_TEST_NAME}.xunit.xml")

  set(_CACHE_ARG "")
  if(_AUC_UV_CACHE)
    set(_CACHE_ARG "--uv-cache" "${_AUC_UV_CACHE}")
  endif()

  add_test(
    NAME ${_AUC_TEST_NAME}
    COMMAND
      "${Python3_EXECUTABLE}" "${_CHECK_SCRIPT}"
      --uv "${UV_EXECUTABLE}"
      --requirements "${_AUC_REQUIREMENTS}"
      --lockfile "${_AUC_LOCKFILE}"
      --xunit-output "${_XUNIT_OUT}"
      --test-name "${_AUC_TEST_NAME}"
      ${_CACHE_ARG}
  )
  set_tests_properties(${_AUC_TEST_NAME} PROPERTIES
    LABELS "ament_uv_virtualenv;lockfile"
    TIMEOUT 120
  )
endfunction()
