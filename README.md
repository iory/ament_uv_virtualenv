# ament_uv_virtualenv

`colcon build` 実行時に **パッケージローカルな Python venv を [`uv`](https://github.com/astral-sh/uv) で構築する** ament_cmake ビルドシステム拡張です。`catkin_virtualenv` の ROS 2 / `uv` 版にあたります。

各 ROS 2 パッケージは自分の `requirements.in` / `requirements.txt` を置き、CMakeLists.txt で 1〜2 行マクロを呼ぶだけで:

- パッケージごとに独立した venv が `share/<pkg>/venv/` 以下に install される
- venv 内 Python で動く Python ノードが `ros2 run` から普通に起動できる
- システムの `rclpy` などは `--system-site-packages` 経由で見える

という構成が手に入ります。

---

## 目次

- [動機](#動機)
- [前提条件](#前提条件)
- [クイックスタート](#クイックスタート)
- [マクロリファレンス](#マクロリファレンス)
  - [`ament_generate_virtualenv()`](#ament_generate_virtualenv)
  - [`ament_uv_install_python_scripts()`](#ament_uv_install_python_scripts)
  - [`ament_uv_check_virtualenv()`](#ament_uv_check_virtualenv)
- [`requirements.in` と `requirements.txt`](#requirementsin-と-requirementstxt)
- [Lockfile ワークフロー](#lockfile-ワークフロー)
- [uv キャッシュと hardlink dedup](#uv-キャッシュと-hardlink-dedup)
- [仕組み](#仕組み)
- [類似プロジェクトとの比較](#類似プロジェクトとの比較)
- [既知の制約](#既知の制約)

---

## 動機

ROS 2 パッケージで PyPI 由来の Python ライブラリ（`scikit-robot` / `trimesh` / `mediapipe` 等）を使いたいとき、選択肢は実質次のいずれかです:

1. システム Python に `pip install --user` する（パッケージ間で衝突する）
2. 各ノードで自前に venv を切り替える（`ros2 run` から起動できなくなる）
3. `colcon-poetry-ros` / `colcon-uv` 等の colcon プラグインを使う（colcon そのものに拡張を入れる必要がある）

このパッケージは **ament_cmake のビルドステップに組み込む** という最も侵襲性の低い方法でこの問題を解きます。`colcon` 本体に手を入れる必要はなく、対象パッケージの `CMakeLists.txt` にマクロ呼び出しを足すだけで動きます。

---

## 前提条件

- ROS 2（Humble / Iron / Jazzy で動作確認）
- `uv` が PATH 上にあること
  ```bash
  pip install --user uv
  # または
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ```
- `python3-venv`（システム標準で入っているはず）

---

## クイックスタート

`my_python_pkg` というパッケージから利用する例:

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

または、git の最新ブランチを直接使うことも可能:

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

# requirements.in があれば自動検出、なければ requirements.txt を見る
ament_generate_virtualenv()

# Python スクリプトと bash ラッパーを install
ament_uv_install_python_scripts(
  PROGRAMS
    scripts/my_node.py
  STRIP_PY_EXTENSION
)

ament_package()
```

### 4. ノード本体 `scripts/my_node.py`

```python
#!/usr/bin/env python3
import rclpy                       # ← system-site-packages 経由で見える
from rclpy.node import Node
import skrobot                     # ← venv 内にインストール済み
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

### 5. ビルドと実行

```bash
colcon build --packages-up-to my_python_pkg
source install/setup.bash
ros2 run my_python_pkg my_node    # STRIP_PY_EXTENSION で .py が剥がれている
```

---

## マクロリファレンス

### `ament_generate_virtualenv()`

パッケージローカルな venv を build ディレクトリに生成し、`share/<pkg>/<venv_name>/` 以下に install します。

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

| 引数 | 既定値 | 説明 |
|---|---|---|
| `REQUIREMENTS` | `requirements.in` か `requirements.txt`（自動検出） | 入力 requirements ファイル。相対パスは `${CMAKE_CURRENT_SOURCE_DIR}` 起点 |
| `LOCKFILE` | 未指定（build tree のみ） | コミット可能な lockfile のパス（ソース tree 相対）。指定すると build はこのファイルから sync するだけになり、再 resolve は `<pkg>_lock_virtualenv` ターゲットで明示的に行う。詳細は [Lockfile ワークフロー](#lockfile-ワークフロー) |
| `VENV_NAME` | `venv` | venv ディレクトリ名（複数 venv が必要なとき変更） |
| `PYTHON` | システム標準 | `uv venv --python` に渡す。`3.11`, `/usr/bin/python3.12` 等 |
| `SYSTEM_SITE_PACKAGES` | `ON` | `OFF` にすると `rclpy` 等が venv から見えなくなるので注意 |
| `UV_CACHE` | uv デフォルト (`~/.cache/uv`) | uv のキャッシュ場所を上書き。CI で `/tmp` 等に固定したいとき。詳細は [uv キャッシュと hardlink dedup](#uv-キャッシュと-hardlink-dedup) |

**生成物**:

```
install/<pkg>/share/<pkg>/<venv_name>/
├── bin/python                      ← venv インタプリタ（システム python へのシンボリックリンク）
├── lib/python3.X/site-packages/    ← uv pip sync でインストールされた依存
└── pyvenv.cfg
```

### `ament_uv_install_python_scripts()`

Python スクリプトを `share/<pkg>/scripts/` に置き、対応する **bash ラッパー** を `lib/<pkg>/` に生成・install します。bash ラッパーは venv の Python を `exec` するので、`ros2 run` から起動した瞬間に venv 内 Python が使われます。

```cmake
ament_uv_install_python_scripts(
  PROGRAMS scripts/foo.py scripts/bar.py
  [DESTINATION lib/<pkg>]
  [SCRIPTS_DESTINATION share/<pkg>/scripts]
  [STRIP_PY_EXTENSION]
)
```

| 引数 | 既定値 | 説明 |
|---|---|---|
| `PROGRAMS`（必須） | — | 対象の `.py` ファイル（複数可） |
| `DESTINATION` | `lib/<pkg>` | bash ラッパーの install 先（`ros2 run` の探索パス） |
| `SCRIPTS_DESTINATION` | `share/<pkg>/scripts` | `.py` 本体の install 先 |
| `STRIP_PY_EXTENSION` | OFF | ラッパー名から `.py` を取り除く（`ros2 run pkg foo` で起動できるようになる） |

**呼び出し前に `ament_generate_virtualenv()` を必ず呼ぶこと**。venv 名を内部参照しているため。

### `ament_uv_check_virtualenv()`

`colcon test` で実行されるテストを 1 つ登録し、コミット済み `LOCKFILE` が `REQUIREMENTS` から再生成されたものと一致することを検証します。`requirements.in` を編集したのに lockfile を更新し忘れた、を CI で捕まえるためのものです。

```cmake
ament_uv_check_virtualenv(
  [REQUIREMENTS <path>]   # 既定: ament_generate_virtualenv() の値を継承
  [LOCKFILE <path>]       # 既定: ament_generate_virtualenv() の値を継承
  [UV_CACHE <path>]       # 既定: ament_generate_virtualenv() の値を継承
  [TEST_NAME <name>]      # 既定: <pkg>_lockfile_check
)
```

`ament_generate_virtualenv(LOCKFILE ...)` を先に呼んでいる場合は、引数なしで呼ぶだけで設定を継承します:

```cmake
ament_generate_virtualenv(
  REQUIREMENTS requirements.in
  LOCKFILE requirements.txt
)

if(BUILD_TESTING)
  ament_uv_check_virtualenv()
endif()
```

比較時は **コメント・空行・`# via ...` の provenance 行を無視**します。差分があれば xunit XML を出力し、`colcon test-result` でレポートされます。

---

## `requirements.in` と `requirements.txt`

| 入力 | 推奨用途 |
|---|---|
| `requirements.txt` | トップレベル依存だけ書く。手書き運用。 |
| `requirements.in` | loose 指定（`scikit-robot>=0.3`）を `requirements.in` に書き、解決済みの完全 pin を `LOCKFILE` (例: `requirements.txt`) にコミットして再現性確保したい場合。 |

`LOCKFILE` を指定しない場合、ビルドのたびに `uv pip compile` で `build/<pkg>/requirements.locked.txt` に lockfile を展開してから `uv pip sync` します。`LOCKFILE` を指定した場合の挙動は次節を参照。

**transitive 依存（trimesh, shapely 等）は自動的に解決されます**。

---

## Lockfile ワークフロー

`LOCKFILE` パラメータを使うと、再現性のあるビルドが手に入ります:

```cmake
ament_generate_virtualenv(
  REQUIREMENTS requirements.in
  LOCKFILE requirements.txt   # ← ソース tree にコミット可能
)

if(BUILD_TESTING)
  ament_uv_check_virtualenv()
endif()
```

**ビルド時の挙動**:

- `requirements.txt` (LOCKFILE) が存在する → `uv pip sync` で venv を同期するだけ。再 resolve なし
- 存在しない初回ビルド → 警告とともに 1 回だけ生成（その後コミット推奨）
- `requirements.in` を編集しても **lockfile は自動更新されない**

**lockfile の更新（明示操作）**:

```bash
# requirements.in を編集したあと:
colcon build --packages-select <pkg> --cmake-target <pkg>_lock_virtualenv

git diff requirements.txt  # 変更を確認してコミット
git add requirements.txt
git commit
```

**CI での drift 検出**:

```bash
colcon test --packages-select <pkg>
colcon test-result --verbose
# `<pkg>_lockfile_check` が失敗していたら lockfile が古い
```

`LOCKFILE` を指定しない場合は、毎回 `uv pip compile` が走り build tree 内の lockfile が更新されるだけ（コミット対象なし）。気軽な使い方をしたいだけならこちらで十分です。

---

## uv キャッシュと hardlink dedup

`uv` は wheels をデフォルトで `~/.cache/uv` に展開し、新しい venv を作るたびに **キャッシュから venv へハードリンクを張る**ことで高速かつ省ディスクなインストールを実現します。

```
~/.cache/uv/wheels-v1/
├── numpy-2.0.0/      ← 元データ（1 コピーのみ）
└── trimesh-4.0.0/

build/pkg_a/venv/lib/python3.12/site-packages/numpy/  ← inode 共有
build/pkg_b/venv/lib/python3.12/site-packages/numpy/  ← inode 共有
```

複数の venv を持つワークスペースでも、同じバージョンの numpy・scipy・torch などが**実体としては 1 コピーしか存在しない**ため、5 個の venv ≠ 5 倍のディスク使用量です。CI で venv をキャッシュしておけば 2 回目以降のビルドは sync 差分だけになります。

`UV_CACHE` パラメータでキャッシュ場所を上書きできます:

```cmake
ament_generate_virtualenv(
  UV_CACHE ${CMAKE_BINARY_DIR}/uv-cache    # ビルドごとに分離
)
```

```cmake
ament_generate_virtualenv(
  UV_CACHE /var/cache/uv                   # CI で永続化
)
```

ハードリンクの仕組み上、**キャッシュと venv は同じファイルシステム上**にある必要があります。tmpfs と別パーティションをまたぐ場合 uv は自動でコピーにフォールバックします（dedup の恩恵は失われますが動作はします）。

---

## 仕組み

`ament_generate_virtualenv()` は CMake の `add_custom_command` を使って以下を **ALL ターゲット**として登録します。

```
[1] uv venv --allow-existing --system-site-packages <build>/venv
[2] uv pip compile --python <build>/venv/bin/python
                   <src>/requirements.txt
                   -o <build>/requirements.locked.txt
[3] uv pip sync    --python <build>/venv/bin/python
                   <build>/requirements.locked.txt
[4] touch <build>/venv.stamp
```

- `requirements.txt` の mtime が変わったときだけ `add_custom_command` が再実行される
- `--allow-existing` のおかげで venv ディレクトリは作り直されず、`uv pip sync` が **差分だけ install / 不要パッケージを uninstall** する
- これにより「依存を 1 つ追加・削除しただけ」のケースで venv が丸ごと再構築される無駄を避けられる
- install フェーズでは `install(DIRECTORY <build>/venv/ DESTINATION share/<pkg>/venv USE_SOURCE_PERMISSIONS)` で venv 全体をコピー（CMake のデフォルトでシンボリックリンクは保持される）

ラッパースクリプトは自身の絶対パスから install prefix を逆算し、`share/<pkg>/<venv>/bin/python` を `exec` する単純な bash です。`AMENT_PREFIX_PATH` 等は **`ament_package()` が暗黙に環境フックを生成してくれる** ので、別途手当てする必要はありません。

---

## 類似プロジェクトとの比較

| プロジェクト | 形態 | venv ツール | ament_index 統合 | C++ ターゲット同居 | colcon プラグイン要 |
|---|---|---|---|---|---|
| `catkin_virtualenv` | catkin マクロ | virtualenv + pip-tools | catkin 任せ | ◎ | 不要 |
| `colcon-poetry-ros` | colcon プラグイン | poetry-bundle | 環境フック自前生成 | × | **必要** |
| `colcon-uv` | colcon プラグイン | uv venv | data-files に手書き必須 | △ | **必要** |
| **`ament_uv_virtualenv`** | **ament_cmake マクロ** | **uv venv + uv pip sync** | **`ament_package()` 任せ** | **◎** | **不要** |

`ament_uv_virtualenv` の特徴:

- ✅ **新しい colcon プラグインを追加 install しなくて良い**（既存ワークフローへの侵襲が低い）
- ✅ **C++ ターゲットと同居可能** — 同じパッケージで `add_executable` した C++ ノードと、venv 内 Python ノードを混在させられる
- ✅ **`uv pip sync` 採用で venv の差分更新** — 依存を変えても丸ごと作り直さない
- ✅ **常に `uv pip compile` を経由** — 手書き `requirements.txt` でも transitive 解決が効く
- ✅ **lock ファイルが build artifact として残る** — `build/<pkg>/requirements.locked.txt`
- ✅ **コミット可能 lockfile + drift 検出** — `LOCKFILE` + `ament_uv_check_virtualenv()` で再現性 CI が組める
- ✅ **hardlink dedup を活用** — 複数 venv 間で同じパッケージを共有、ディスク・ビルド時間ともに節約

---

## 既知の制約

### `merge-install` モードで全パッケージの venv が衝突する可能性

`colcon build --merge-install` を使うと全パッケージの `share/` が一つに統合されます。`share/<pkg>/venv/` のパスはパッケージ別なので衝突はしませんが、**ワークスペース全体で 1 venv を共有したい** ニーズには未対応です。

回避策: 共有 venv 専用の小パッケージを作って `<exec_depend>` させる、など。

### scripts と venv が異なるディレクトリに分かれる

`ros2 run pkg foo` で起動するパスは:

```
lib/<pkg>/foo               ← bash wrapper
└─ exec ─►  share/<pkg>/venv/bin/python  share/<pkg>/scripts/foo.py
```

ラッパーは `${BASH_SOURCE[0]}` から install prefix を逆算しているため、**install prefix を移動するとパスが追従しない symlink を作っていれば動きません**。`install/` をコピーして使う運用では symlink を解決した実体を配ってください。

### 複数 venv を同一パッケージで使う場合

`ament_uv_install_python_scripts()` は **直近に登録された VENV_NAME** だけを参照します。1 パッケージで 2 つ以上の venv を持って使い分けたい場合は、現状はマクロ拡張が必要です。

### git+ URL の依存と `--reinstall-package`

`requirements.txt` に `pkg @ git+https://.../repo@main` と書いた場合、main が動いても uv のキャッシュを優先するため自動追従しません。最新を引きたいときは `~/.cache/uv` をクリアするか、コミットハッシュを明示してください。

---

## ライセンス

Apache-2.0
