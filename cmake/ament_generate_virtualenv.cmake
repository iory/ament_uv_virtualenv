# ament_generate_virtualenv()
#
# Build a package-local Python venv at colcon-build time using `uv` directly.
# Requires `uv` on PATH at configure time.
#
# Usage:
#   ament_generate_virtualenv(
#     [REQUIREMENTS <path>]            # default: requirements.in if present, else requirements.txt
#     [LOCKFILE <path>]                # optional; relative to source tree.
#                                      # When set, sync from this committed lockfile
#                                      # instead of re-resolving every build.
#                                      # If missing it is generated once on first build.
#     [VENV_NAME <name>]               # default: "venv"
#     [PYTHON <X.Y|path>]              # default: system default; passed to `uv venv --python`.
#                                      # A path pins the exact interpreter, which is
#                                      # what you want when the venv has to import
#                                      # the distro's ROS extension modules.
#     [SYSTEM_SITE_PACKAGES <ON|OFF>]  # default: ON (so rclpy / ROS Python is importable)
#     [UV_CACHE <path>]                # optional; uv cache directory (passed via --cache-dir).
#                                      # Falls back to uv's default (~/.cache/uv) when unset.
#                                      # uv uses the cache as a hardlink farm — multiple venvs
#                                      # deduplicate identical wheels at the inode level.
#   )
#
# After install:
#   <prefix>/share/<pkg>/<venv_name>/bin/python   <- venv interpreter
#
# Custom targets exposed:
#   <pkg>_generate_virtualenv     ALL target that builds and syncs the venv.
#   <pkg>_lock_virtualenv         Manual target. Re-resolves the LOCKFILE from
#                                 REQUIREMENTS and writes it to the source tree.
#                                 Only created when LOCKFILE is given.
#                                 Run via: colcon build --cmake-target <pkg>_lock_virtualenv
#
# Workflow modes:
#   * Without LOCKFILE: every build re-runs `uv pip compile` against REQUIREMENTS,
#     producing build/<pkg>/requirements.locked.txt. Suitable for casual usage.
#   * With LOCKFILE: builds sync from the committed lockfile only. Resolution is
#     a deliberate, opt-in operation via <pkg>_lock_virtualenv. Suitable when
#     reproducibility across machines matters.

function(ament_generate_virtualenv)
  cmake_parse_arguments(_AGV
    ""
    "REQUIREMENTS;LOCKFILE;VENV_NAME;PYTHON;SYSTEM_SITE_PACKAGES;UV_CACHE"
    ""
    ${ARGN}
  )

  # --- Resolve requirements file --------------------------------------------
  if(NOT _AGV_REQUIREMENTS)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/requirements.in")
      set(_AGV_REQUIREMENTS "${CMAKE_CURRENT_SOURCE_DIR}/requirements.in")
    elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/requirements.txt")
      set(_AGV_REQUIREMENTS "${CMAKE_CURRENT_SOURCE_DIR}/requirements.txt")
    else()
      message(FATAL_ERROR
        "ament_generate_virtualenv: no REQUIREMENTS specified and neither "
        "requirements.in nor requirements.txt found in ${CMAKE_CURRENT_SOURCE_DIR}")
    endif()
  elseif(NOT IS_ABSOLUTE "${_AGV_REQUIREMENTS}")
    set(_AGV_REQUIREMENTS "${CMAKE_CURRENT_SOURCE_DIR}/${_AGV_REQUIREMENTS}")
  endif()
  if(NOT EXISTS "${_AGV_REQUIREMENTS}")
    message(FATAL_ERROR "ament_generate_virtualenv: requirements file not found: ${_AGV_REQUIREMENTS}")
  endif()

  # --- Defaults --------------------------------------------------------------
  if(NOT _AGV_VENV_NAME)
    set(_AGV_VENV_NAME "venv")
  endif()
  if(NOT DEFINED _AGV_SYSTEM_SITE_PACKAGES)
    set(_AGV_SYSTEM_SITE_PACKAGES ON)
  endif()

  # --- Resolution target Python ---------------------------------------------
  # `uv pip compile` resolves for the interpreter it happens to run under, not
  # for the venv's Python. On a host whose default is newer than PYTHON, that
  # silently drops dependencies that only exist below that version -- pytest
  # needs `exceptiongroup` on 3.10 but not on 3.11+, so the lockfile came out
  # missing it and the venv could not even import pytest. Pin the resolution to
  # the same version the venv is built with.
  #
  # PYTHON may also be an interpreter path, which is the only way to be sure the
  # venv runs the very interpreter the host's ROS C extensions were built for.
  # `uv pip compile --python-version` only understands an X.Y string, so ask the
  # interpreter itself rather than trying to parse its path.
  set(_COMPILE_PY_OPTS "")
  if(_AGV_PYTHON)
    set(_AGV_PYTHON_VERSION "${_AGV_PYTHON}")
    if(IS_ABSOLUTE "${_AGV_PYTHON}")
      execute_process(
        COMMAND "${_AGV_PYTHON}" -c "import sys; print('%d.%d' % sys.version_info[:2])"
        OUTPUT_VARIABLE _AGV_PYTHON_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _AGV_PYTHON_RESULT
      )
      if(NOT _AGV_PYTHON_RESULT EQUAL 0)
        message(FATAL_ERROR
          "ament_generate_virtualenv: PYTHON was given as the path "
          "'${_AGV_PYTHON}', but running it failed. Pass an existing "
          "interpreter or an X.Y version string.")
      endif()
    endif()
    list(APPEND _COMPILE_PY_OPTS "--python-version" "${_AGV_PYTHON_VERSION}")
  endif()

  # --- Locate uv -------------------------------------------------------------
  find_program(UV_EXECUTABLE uv)
  if(NOT UV_EXECUTABLE)
    message(FATAL_ERROR
      "ament_generate_virtualenv: `uv` not found on PATH. Install it via "
      "`pip install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`.")
  endif()

  set(_VENV_DIR "${CMAKE_CURRENT_BINARY_DIR}/${_AGV_VENV_NAME}")
  set(_VENV_PY  "${_VENV_DIR}/bin/python")
  set(_STAMP    "${CMAKE_CURRENT_BINARY_DIR}/${_AGV_VENV_NAME}.stamp")

  set(_VENV_OPTS "--allow-existing")
  if(_AGV_SYSTEM_SITE_PACKAGES)
    list(APPEND _VENV_OPTS "--system-site-packages")
  endif()
  if(_AGV_PYTHON)
    list(APPEND _VENV_OPTS "--python" "${_AGV_PYTHON}")
  endif()

  # --- Cache directory plumbing ---------------------------------------------
  set(_UV_CACHE_OPTS "")
  if(_AGV_UV_CACHE)
    if(NOT IS_ABSOLUTE "${_AGV_UV_CACHE}")
      set(_AGV_UV_CACHE "${CMAKE_CURRENT_BINARY_DIR}/${_AGV_UV_CACHE}")
    endif()
    list(APPEND _UV_CACHE_OPTS "--cache-dir" "${_AGV_UV_CACHE}")
  endif()

  # --- Lockfile semantics ----------------------------------------------------
  # Two modes:
  #   * LOCKFILE set:   build syncs from <source>/<LOCKFILE>, and a manual
  #                     re-resolve target is exposed.
  #   * LOCKFILE unset: every build resolves to build/<pkg>/requirements.locked.txt.
  if(_AGV_LOCKFILE)
    if(IS_ABSOLUTE "${_AGV_LOCKFILE}")
      set(_LOCKED "${_AGV_LOCKFILE}")
    else()
      set(_LOCKED "${CMAKE_CURRENT_SOURCE_DIR}/${_AGV_LOCKFILE}")
    endif()

    # Manual lock target: re-resolve REQUIREMENTS into the committed lockfile.
    # Users invoke via: colcon build --cmake-target <pkg>_lock_virtualenv
    add_custom_target(${PROJECT_NAME}_lock_virtualenv
      COMMAND ${CMAKE_COMMAND} -E echo
              "[${PROJECT_NAME}] uv pip compile ${_AGV_REQUIREMENTS} -> ${_LOCKED}"
      COMMAND "${UV_EXECUTABLE}" pip compile ${_UV_CACHE_OPTS} ${_COMPILE_PY_OPTS} --quiet
              "${_AGV_REQUIREMENTS}" -o "${_LOCKED}"
      COMMENT "[${PROJECT_NAME}] Regenerating lockfile ${_LOCKED}"
      VERBATIM
    )

    # First-time generation: if the committed lockfile is missing entirely,
    # create it once so the build does not hard-fail. We log a warning so the
    # user knows to commit it.
    if(NOT EXISTS "${_LOCKED}")
      message(WARNING
        "ament_generate_virtualenv: LOCKFILE ${_LOCKED} is missing. "
        "Generating it from ${_AGV_REQUIREMENTS}. Commit the result for reproducible builds.")
      execute_process(
        COMMAND "${UV_EXECUTABLE}" pip compile ${_UV_CACHE_OPTS} ${_COMPILE_PY_OPTS} --quiet
                "${_AGV_REQUIREMENTS}" -o "${_LOCKED}"
        RESULT_VARIABLE _compile_rc
      )
      if(NOT _compile_rc EQUAL 0)
        message(FATAL_ERROR
          "ament_generate_virtualenv: failed to compile ${_AGV_REQUIREMENTS} into ${_LOCKED}")
      endif()
    endif()

    set(_SYNC_INPUT "${_LOCKED}")
    set(_SYNC_DEPENDS "${_LOCKED}")
    set(_BUILD_COMPILE_CMDS "")
  else()
    # Status quo: re-resolve every build into a build-tree lockfile.
    set(_LOCKED "${CMAKE_CURRENT_BINARY_DIR}/requirements.locked.txt")
    set(_SYNC_INPUT "${_LOCKED}")
    set(_SYNC_DEPENDS "${_AGV_REQUIREMENTS}")
    # Compile is run as a build step inline with sync (see below).
    set(_BUILD_COMPILE_CMDS
      COMMAND "${UV_EXECUTABLE}" pip compile ${_UV_CACHE_OPTS} --quiet
              --python "${_VENV_PY}"
              "${_AGV_REQUIREMENTS}" -o "${_LOCKED}"
    )
  endif()

  # --- The actual build step ------------------------------------------------
  # `uv venv --allow-existing` is a no-op when the venv is already present
  # with the requested options, so it is safe to run on every build.
  # `uv pip sync` reconciles the venv with the lockfile (installs missing,
  # removes extraneous), keeping it in lockstep without `rm -rf`.
  add_custom_command(
    OUTPUT "${_STAMP}"
    COMMAND ${CMAKE_COMMAND} -E echo "[${PROJECT_NAME}] uv venv -> ${_VENV_DIR}"
    COMMAND "${UV_EXECUTABLE}" venv ${_UV_CACHE_OPTS} ${_VENV_OPTS} "${_VENV_DIR}"
    ${_BUILD_COMPILE_CMDS}
    COMMAND "${UV_EXECUTABLE}" pip sync ${_UV_CACHE_OPTS} --python "${_VENV_PY}" "${_SYNC_INPUT}"
    COMMAND ${CMAKE_COMMAND} -E touch "${_STAMP}"
    DEPENDS ${_SYNC_DEPENDS}
    COMMENT "[${PROJECT_NAME}] Syncing venv via uv from ${_SYNC_INPUT}"
    VERBATIM
  )

  add_custom_target(${PROJECT_NAME}_generate_virtualenv ALL
    DEPENDS "${_STAMP}"
  )

  # --- Install the whole venv ----------------------------------------------
  install(
    DIRECTORY "${_VENV_DIR}/"
    DESTINATION "share/${PROJECT_NAME}/${_AGV_VENV_NAME}"
    USE_SOURCE_PERMISSIONS
  )

  # Cache for ament_uv_install_python_scripts() and ament_uv_check_virtualenv();
  # use a GLOBAL property since function-scope variables don't survive across files.
  set_property(GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_VENV_NAME "${_AGV_VENV_NAME}")
  set_property(GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_REQUIREMENTS "${_AGV_REQUIREMENTS}")
  set_property(GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_LOCKFILE "${_LOCKED}")
  set_property(GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_UV_CACHE "${_AGV_UV_CACHE}")
endfunction()
