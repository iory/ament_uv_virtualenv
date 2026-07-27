# ament_uv_install_python_package()
#
# Install the package's own Python module tree AND make it importable by the
# venv's interpreter when that interpreter is invoked directly.
#
# Why this exists:
#   ament_uv_install_python_scripts() generates a bash wrapper that exports
#   PYTHONPATH before exec'ing the venv python, so `ros2 run` works. But nothing
#   makes the package importable when a user runs the venv interpreter directly:
#
#     $ install/<pkg>/share/<pkg>/venv/bin/python
#     >>> from <pkg>.core import Thing
#     ModuleNotFoundError: No module named '<pkg>'
#
#   That is the normal way to use a package from Jupyter, from a plain script,
#   or interactively. This macro closes that gap by dropping a .pth file into
#   the venv's site-packages.
#
# Why a .pth and not `uv pip install -e .`:
#   ament_generate_virtualenv() syncs the venv with `uv pip sync`, which
#   uninstalls anything not present in the lockfile. An editable install of the
#   package itself is therefore removed on the next build. A .pth file is not a
#   package record, so `uv pip sync` leaves it alone (verified).
#
# The generated .pth resolves its target relative to sys.prefix rather than
# baking in an absolute path, so moving the install tree does not break it.
#
# Usage:
#   ament_generate_virtualenv(...)          # must be called first
#   ament_uv_install_python_package(
#     [PACKAGE_DIR <dir>]      # default: <pkg>  (relative to CMAKE_CURRENT_SOURCE_DIR)
#     [DESTINATION <dir>]      # default: share/<pkg>
#     [PTH_NAME <name>]        # default: _ament_uv_<pkg>_path.pth
#   )

function(ament_uv_install_python_package)
  cmake_parse_arguments(_AUP
    ""
    "PACKAGE_DIR;DESTINATION;PTH_NAME"
    ""
    ${ARGN}
  )

  if(NOT _AUP_PACKAGE_DIR)
    set(_AUP_PACKAGE_DIR "${PROJECT_NAME}")
  endif()
  if(NOT _AUP_DESTINATION)
    set(_AUP_DESTINATION "share/${PROJECT_NAME}")
  endif()
  if(NOT _AUP_PTH_NAME)
    set(_AUP_PTH_NAME "_ament_uv_${PROJECT_NAME}_path.pth")
  endif()

  if(IS_ABSOLUTE "${_AUP_PACKAGE_DIR}")
    set(_pkg_src "${_AUP_PACKAGE_DIR}")
  else()
    set(_pkg_src "${CMAKE_CURRENT_SOURCE_DIR}/${_AUP_PACKAGE_DIR}")
  endif()
  if(NOT IS_DIRECTORY "${_pkg_src}")
    message(FATAL_ERROR
      "ament_uv_install_python_package: package directory not found: ${_pkg_src}")
  endif()

  get_property(_VENV_NAME GLOBAL PROPERTY
    _ament_uv_virtualenv_${PROJECT_NAME}_VENV_NAME)
  if(NOT _VENV_NAME)
    message(FATAL_ERROR
      "ament_uv_install_python_package: must call ament_generate_virtualenv() "
      "before ament_uv_install_python_package()")
  endif()

  # Install the module tree itself.
  install(DIRECTORY "${_pkg_src}" DESTINATION "${_AUP_DESTINATION}")

  # Work out how to get from the installed venv root back to the directory that
  # contains the module tree, so the .pth can be written without an absolute
  # path. Default layout: share/<pkg>/venv -> share/<pkg>, i.e. "..".
  set(_venv_install_dir "share/${PROJECT_NAME}/${_VENV_NAME}")
  file(RELATIVE_PATH _rel_to_pkg_parent
    "/${_venv_install_dir}" "/${_AUP_DESTINATION}")
  if(_rel_to_pkg_parent STREQUAL "")
    set(_rel_to_pkg_parent ".")
  endif()

  set(_pth_build_path "${CMAKE_CURRENT_BINARY_DIR}/${_AUP_PTH_NAME}")
  # A .pth line starting with "import" is executed by the site module. sys.prefix
  # is the venv root at runtime, wherever the tree has been moved to.
  file(WRITE "${_pth_build_path}"
    "import os, site, sys; site.addsitedir(os.path.normpath(os.path.join(sys.prefix, '${_rel_to_pkg_parent}')))\n")

  # The venv's python version is not known until the venv exists, so locate
  # site-packages at install time rather than configure time. This runs after
  # ament_generate_virtualenv()'s install(DIRECTORY) because install rules
  # execute in declaration order and that macro must be called first.
  install(CODE "
    file(GLOB _aup_site_packages
      \"\${CMAKE_INSTALL_PREFIX}/${_venv_install_dir}/lib/python*/site-packages\")
    if(NOT _aup_site_packages)
      message(FATAL_ERROR
        \"ament_uv_install_python_package: no site-packages under \"
        \"\${CMAKE_INSTALL_PREFIX}/${_venv_install_dir}/lib/. The venv was not \"
        \"installed, so '${PROJECT_NAME}' would be silently unimportable from \"
        \"the venv interpreter.\")
    endif()
    list(GET _aup_site_packages 0 _aup_target)
    file(INSTALL DESTINATION \"\${_aup_target}\" TYPE FILE
         FILES \"${_pth_build_path}\")
    message(STATUS
      \"[${PROJECT_NAME}] venv import path: \${_aup_target}/${_AUP_PTH_NAME}\")
  ")
endfunction()
