# ament_uv_virtualenv

English | [日本語](README_ja.md)

An ament_cmake build-system extension that **builds a package-local Python venv with [`uv`](https://github.com/astral-sh/uv) during `colcon build`**. It is the ROS 2 / `uv` counterpart of `catkin_virtualenv`.

Each ROS 2 package keeps its own `requirements.in` / `requirements.txt` and calls one or two macros from its CMakeLists.txt. With that:

- each package gets an independent venv, installed under `share/<pkg>/venv/`;
- Python nodes running on the venv's Python start normally from `ros2 run`;
- the system `rclpy` and friends stay visible through `--system-site-packages`.

---

## Contents

- [Motivation](#motivation)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Macro reference](#macro-reference)
  - [`ament_generate_virtualenv()`](#ament_generate_virtualenv)
  - [`ament_uv_install_python_scripts()`](#ament_uv_install_python_scripts)
  - [`ament_uv_install_python_package()`](#ament_uv_install_python_package)
  - [`ament_uv_check_virtualenv()`](#ament_uv_check_virtualenv)
- [`requirements.in` and `requirements.txt`](#requirementsin-and-requirementstxt)
- [Lockfile workflow](#lockfile-workflow)
- [uv cache and hardlink dedup](#uv-cache-and-hardlink-dedup)
- [How it works](#how-it-works)
- [Comparison with similar projects](#comparison-with-similar-projects)
- [Known limitations](#known-limitations)

---

## Motivation

To use Python libraries from PyPI (`scikit-robot`, `trimesh`, `mediapipe`, ...) in a ROS 2 package, the practical choices are:

1. `pip install --user` into the system Python (packages collide with each other);
2. switch to a hand-made venv in each node (the node can no longer be started with `ros2 run`);
3. a colcon plugin such as `colcon-poetry-ros` or `colcon-uv` (colcon itself needs an extension).

This package solves it in the least invasive way: **as a step of the ament_cmake build**. colcon is left alone; the package only adds macro calls to its `CMakeLists.txt`.

---

## Prerequisites

- ROS 2 (tested on Humble / Iron / Jazzy)
- `uv` on PATH
  ```bash
  pip install --user uv
  # or
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- `python3-venv` (normally installed with the system Python)

---

## Quick start

Using it from a package called `my_python_pkg`:

### 1. `package.xml`

```xml
<?xml version="1.0"?>
<package format="3">
  <name>my_python_pkg</name>
  <version>0.0.1</version>
  <description>...</description>
  <maintainer email="you@example.com">You</maintainer>
  <license>Apache-2.0</license>

  <buildtool_depend>ament_cmake</buildtool_depend>
  <buildtool_depend>ament_uv_virtualenv</buildtool_depend>

  <depend>rclpy</depend>

  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
```

### 2. `requirements.txt`

```
scikit-robot
numpy
```

A git branch can be used directly too:

```
scikit-robot @ git+https://github.com/iory/scikit-robot.git@main
numpy
```

### 3. `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.8)
project(my_python_pkg)

find_package(ament_cmake REQUIRED)
find_package(ament_uv_virtualenv REQUIRED)
find_package(rclpy REQUIRED)

# Uses requirements.in when present, requirements.txt otherwise
ament_generate_virtualenv()

# Install the Python scripts and their bash wrappers
ament_uv_install_python_scripts(
  PROGRAMS
    scripts/my_node.py
  STRIP_PY_EXTENSION
)

ament_package()
```

### 4. The node, `scripts/my_node.py`

```python
#!/usr/bin/env python3
import rclpy                       # <- visible through system-site-packages
from rclpy.node import Node
import skrobot                     # <- installed in the venv
from skrobot.models import PR2

class MyNode(Node):
    def __init__(self):
        super().__init__('my_node')
        robot = PR2()
        self.get_logger().info(f'#links={len(robot.link_list)}')

def main():
    rclpy.init()
    node = MyNode()
    rclpy.spin_once(node, timeout_sec=1.0)
    node.destroy_node()
    rclpy.shutdown()

if __name__ == '__main__':
    main()
```

### 5. Build and run

```bash
colcon build --packages-up-to my_python_pkg
source install/setup.bash
ros2 run my_python_pkg my_node    # STRIP_PY_EXTENSION dropped the .py
```

---

## Macro reference

### `ament_generate_virtualenv()`

Creates a package-local venv in the build directory and installs it under `share/<pkg>/<venv_name>/`.

```cmake
ament_generate_virtualenv(
  [REQUIREMENTS <path>]
  [LOCKFILE <path>]
  [VENV_NAME <name>]
  [PYTHON <X.Y|path>]
  [SYSTEM_SITE_PACKAGES <ON|OFF>]
  [UV_CACHE <path>]
)
```

| Argument | Default | Description |
|---|---|---|
| `REQUIREMENTS` | `requirements.in` or `requirements.txt` (auto-detected) | Input requirements file. A relative path is taken from `${CMAKE_CURRENT_SOURCE_DIR}` |
| `LOCKFILE` | unset (build tree only) | Path of a committable lockfile (relative to the source tree). When set, the build only syncs from this file; re-resolving is an explicit step through the `<pkg>_lock_virtualenv` target. See [Lockfile workflow](#lockfile-workflow) |
| `VENV_NAME` | `venv` | Name of the venv directory (change it when one package needs several venvs) |
| `PYTHON` | system default | Passed to `uv venv --python`: `3.11`, `/usr/bin/python3.12`, ... |
| `SYSTEM_SITE_PACKAGES` | `ON` | With `OFF`, `rclpy` and the rest of ROS are no longer visible from the venv |
| `UV_CACHE` | uv default (`~/.cache/uv`) | Overrides uv's cache location, e.g. to pin it to `/tmp` on CI. See [uv cache and hardlink dedup](#uv-cache-and-hardlink-dedup) |

**Output**:

```
install/<pkg>/share/<pkg>/<venv_name>/
├── bin/python                      <- venv interpreter (symlink to the system python)
├── lib/python3.X/site-packages/    <- dependencies installed by uv pip sync
└── pyvenv.cfg
```

### `ament_uv_install_python_scripts()`

Installs Python scripts into `share/<pkg>/scripts/` and generates a **bash wrapper** for each into `lib/<pkg>/`. The wrapper `exec`s the venv's Python, so a node started with `ros2 run` runs on the venv's Python from the first instruction.

```cmake
ament_uv_install_python_scripts(
  PROGRAMS scripts/foo.py scripts/bar.py
  [DESTINATION lib/<pkg>]
  [SCRIPTS_DESTINATION share/<pkg>/scripts]
  [STRIP_PY_EXTENSION]
)
```

| Argument | Default | Description |
|---|---|---|
| `PROGRAMS` (required) | — | The `.py` files (one or more) |
| `DESTINATION` | `lib/<pkg>` | Where the bash wrappers are installed (the path `ros2 run` searches) |
| `SCRIPTS_DESTINATION` | `share/<pkg>/scripts` | Where the `.py` files themselves are installed |
| `STRIP_PY_EXTENSION` | OFF | Drop `.py` from the wrapper name (so `ros2 run pkg foo` works) |

**Call `ament_generate_virtualenv()` first**: this macro looks up the venv name it registered.

### `ament_uv_install_python_package()`

Installs the package's own Python module tree and makes it **importable when the venv's interpreter is run directly**.

```cmake
ament_uv_install_python_package(
  [PACKAGE_DIR <dir>]      # default: <pkg> (relative to CMAKE_CURRENT_SOURCE_DIR)
  [DESTINATION <dir>]      # default: share/<pkg>
  [PTH_NAME <name>]        # default: _ament_uv_<pkg>_path.pth
)
```

The bash wrappers from `ament_uv_install_python_scripts()` set `PYTHONPATH` before `exec`ing the venv's python, so `ros2 run` works. But **starting the venv's python directly adds nothing to `sys.path`**, and you get:

```console
$ install/<pkg>/share/<pkg>/venv/bin/python
>>> from <pkg>.core import Thing
ModuleNotFoundError: No module named '<pkg>'
```

That rules out every ordinary use: Jupyter, plain scripts, trying things interactively. This macro fixes it with one `.pth` file in the venv's `site-packages`.

**Why not `uv pip install -e .`**: `ament_generate_virtualenv()` syncs the venv with `uv pip sync`, and `uv pip sync` **uninstalls every package that is not in the lockfile**. An editable install of the package itself disappears on the next build. A `.pth` is not a package record, so `uv pip sync` leaves it alone (verified).

The generated `.pth` does not bake in an absolute path; it resolves relative to `sys.prefix`:

```python
import os, site, sys; site.addsitedir(os.path.normpath(os.path.join(sys.prefix, '../')))
```

so **moving the install prefix does not break it**.

```cmake
ament_generate_virtualenv(REQUIREMENTS requirements.in LOCKFILE requirements.txt)

# Use in place of install(DIRECTORY <pkg> DESTINATION share/<pkg>)
ament_uv_install_python_package()

ament_uv_install_python_scripts(PROGRAMS scripts/my_node.py STRIP_PY_EXTENSION)
```

Usage (with the workspace sourced, from any directory):

```bash
source install/setup.bash
install/<pkg>/share/<pkg>/venv/bin/python -c "from <pkg>.core import Thing"
```

Sibling ament packages (`rclpy`, other `ament_python` packages) reach `PYTHONPATH` through `source install/setup.bash`, so **sourcing is still required**. This macro only covers the package itself.

**Call it after `ament_generate_virtualenv()`**: it looks up the venv name, and it relies on the order the install rules are declared in to put the `.pth` in place after the venv itself is installed.

### `ament_uv_check_virtualenv()`

Registers one test, run by `colcon test`, that checks the committed `LOCKFILE` matches what `REQUIREMENTS` resolves to. It catches "edited `requirements.in` but forgot to update the lockfile" on CI.

```cmake
ament_uv_check_virtualenv(
  [REQUIREMENTS <path>]   # default: inherited from ament_generate_virtualenv()
  [LOCKFILE <path>]       # default: inherited from ament_generate_virtualenv()
  [UV_CACHE <path>]       # default: inherited from ament_generate_virtualenv()
  [TEST_NAME <name>]      # default: <pkg>_lockfile_check
)
```

After `ament_generate_virtualenv(LOCKFILE ...)`, calling it without arguments inherits the settings:

```cmake
ament_generate_virtualenv(
  REQUIREMENTS requirements.in
  LOCKFILE requirements.txt
)

if(BUILD_TESTING)
  ament_uv_check_virtualenv()
endif()
```

The comparison **ignores comments, blank lines and the `# via ...` provenance lines**. A difference produces a xunit XML, which `colcon test-result` reports.

---

## `requirements.in` and `requirements.txt`

| Input | Recommended for |
|---|---|
| `requirements.txt` | Top-level dependencies only, maintained by hand. |
| `requirements.in` | Loose specs (`scikit-robot>=0.3`) in `requirements.in`, with the fully pinned resolution committed as the `LOCKFILE` (e.g. `requirements.txt`) for reproducibility. |

Without `LOCKFILE`, every build runs `uv pip compile` into `build/<pkg>/requirements.locked.txt` and then `uv pip sync`s from it. For the behaviour with `LOCKFILE`, see the next section.

**Transitive dependencies (trimesh, shapely, ...) are resolved automatically.**

---

## Lockfile workflow

The `LOCKFILE` parameter gives reproducible builds:

```cmake
ament_generate_virtualenv(
  REQUIREMENTS requirements.in
  LOCKFILE requirements.txt   # <- can be committed to the source tree
)

if(BUILD_TESTING)
  ament_uv_check_virtualenv()
endif()
```

**At build time**:

- `requirements.txt` (the LOCKFILE) exists -> the venv is only synced with `uv pip sync`; nothing is re-resolved
- first build, file missing -> it is generated once, with a warning (commit it afterwards)
- editing `requirements.in` **does not update the lockfile**

**Updating the lockfile (an explicit step)**:

```bash
# after editing requirements.in:
colcon build --packages-select <pkg> --cmake-target <pkg>_lock_virtualenv

git diff requirements.txt  # review, then commit
git add requirements.txt
git commit
```

**Detecting drift on CI**:

```bash
colcon test --packages-select <pkg>
colcon test-result --verbose
# a failing `<pkg>_lockfile_check` means the lockfile is stale
```

Without `LOCKFILE`, `uv pip compile` runs on every build and only updates the lockfile in the build tree (nothing to commit). That is enough for casual use.

---

## uv cache and hardlink dedup

`uv` unpacks wheels into `~/.cache/uv` by default and **hardlinks them from the cache into each new venv**, which makes installs fast and cheap on disk.

```
~/.cache/uv/wheels-v1/
├── numpy-2.0.0/      <- the data (one copy)
└── trimesh-4.0.0/

build/pkg_a/venv/lib/python3.12/site-packages/numpy/  <- shares the inodes
build/pkg_b/venv/lib/python3.12/site-packages/numpy/  <- shares the inodes
```

Even in a workspace with many venvs, the same version of numpy, scipy, torch, ... **exists only once on disk**, so 5 venvs do not cost 5x the space. With the venvs cached on CI, later builds only sync the difference.

The `UV_CACHE` parameter overrides the cache location:

```cmake
ament_generate_virtualenv(
  UV_CACHE ${CMAKE_BINARY_DIR}/uv-cache    # separate per build
)
```

```cmake
ament_generate_virtualenv(
  UV_CACHE /var/cache/uv                   # persisted on CI
)
```

Hardlinks need **the cache and the venv on the same filesystem**. Across tmpfs or partitions uv falls back to copying (no dedup, but it works).

---

## How it works

`ament_generate_virtualenv()` registers the following with CMake's `add_custom_command`, as part of the **ALL target**:

```
[1] uv venv --allow-existing --system-site-packages <build>/venv
[2] uv pip compile --python <build>/venv/bin/python
                   <src>/requirements.txt
                   -o <build>/requirements.locked.txt
[3] uv pip sync    --python <build>/venv/bin/python
                   <build>/requirements.locked.txt
[4] touch <build>/venv.stamp
```

- the `add_custom_command` reruns only when the mtime of `requirements.txt` changes
- thanks to `--allow-existing` the venv directory is not recreated, and `uv pip sync` **installs only the difference and uninstalls what is no longer needed**
- so adding or removing one dependency does not rebuild the whole venv
- the install phase copies the whole venv with `install(DIRECTORY <build>/venv/ DESTINATION share/<pkg>/venv USE_SOURCE_PERMISSIONS)` (symlinks are kept, as CMake does by default)

The wrapper script is plain bash: it derives the install prefix from its own absolute path and `exec`s `share/<pkg>/<venv>/bin/python`. `AMENT_PREFIX_PATH` and the like need no extra handling, since **`ament_package()` generates the environment hooks implicitly**.

---

## Comparison with similar projects

| Project | Form | venv tool | ament_index integration | Coexists with C++ targets | Needs a colcon plugin |
|---|---|---|---|---|---|
| `catkin_virtualenv` | catkin macro | virtualenv + pip-tools | left to catkin | ◎ | no |
| `colcon-poetry-ros` | colcon plugin | poetry-bundle | generates its own environment hooks | × | **yes** |
| `colcon-uv` | colcon plugin | uv venv | data-files written by hand | △ | **yes** |
| **`ament_uv_virtualenv`** | **ament_cmake macro** | **uv venv + uv pip sync** | **left to `ament_package()`** | **◎** | **no** |

What `ament_uv_virtualenv` gives you:

- ✅ **No new colcon plugin to install** (low impact on existing workflows)
- ✅ **Coexists with C++ targets**: a C++ node built with `add_executable` and Python nodes on the venv can live in the same package
- ✅ **Incremental venv updates through `uv pip sync`**: changing a dependency does not rebuild everything
- ✅ **Always goes through `uv pip compile`**: transitive dependencies are resolved even for a hand-written `requirements.txt`
- ✅ **The lockfile remains as a build artifact**: `build/<pkg>/requirements.locked.txt`
- ✅ **Committable lockfile + drift detection**: `LOCKFILE` + `ament_uv_check_virtualenv()` make a reproducibility check on CI possible
- ✅ **Uses hardlink dedup**: identical packages are shared between venvs, saving disk and build time

---

## Known limitations

### Venvs of all packages in `merge-install` mode

`colcon build --merge-install` merges every package's `share/` into one. `share/<pkg>/venv/` is per package, so nothing collides, but **sharing one venv across the whole workspace** is not supported.

Workaround: a small package dedicated to the shared venv, which others `<exec_depend>` on.

### Scripts and the venv live in different directories

The path `ros2 run pkg foo` takes:

```
lib/<pkg>/foo               <- bash wrapper
└─ exec ─►  share/<pkg>/venv/bin/python  share/<pkg>/scripts/foo.py
```

The wrapper derives the install prefix from `${BASH_SOURCE[0]}`, so **a symlink that does not follow a moved install prefix breaks it**. If you copy `install/` around, ship the resolved files rather than symlinks.

### Several venvs in one package

`ament_uv_install_python_scripts()` only refers to the **most recently registered VENV_NAME**. Using two or more venvs in one package currently needs an extension of the macros.

### git+ URL dependencies and `--reinstall-package`

With `pkg @ git+https://.../repo@main` in `requirements.txt`, uv prefers its cache and does not follow `main` as it moves. To pull the latest, clear `~/.cache/uv` or pin a commit hash.

---

## License

Apache-2.0
