# MLX 0.32.3 的独立版构建

知会的独立版使用上游 **MLX 0.32.3** 与 **mlx-metal 0.32.3**。源码来自固定的官方 `v0.32.3` 提交，原始归档地址、SHA-256 与许可校验值记录在 [SOURCE.json](SOURCE.json)，上游 MIT 许可保存在 [LICENSE](LICENSE)。不修改推理源码，不改写二进制的最低系统版本字段。

## 构建方法

在项目开发环境中执行：

```sh
python3 scripts/build-mlx.py
```

脚本使用项目 `work/standalone-mlx/` 内独立的构建环境；不会安装或替换项目 `.venv` 中的 MLX。可通过 `--cache-dir` 选择其他项目内 `work/` 子目录。构建需要 Apple Silicon、Xcode 命令行工具、可用的 Metal Toolchain、`uv` 与 CMake 3.25 或更高。CMake 只用于开发构建，不随日常推理启动；脚本记录其实际版本，本机已验证构建使用 CMake 4.3.3。

固定构建输入：

- 受管理的 CPython **3.12.11**。
- 构建环境使用 `setuptools 84.0.0`、`wheel 0.48.0` 与 `typing_extensions 4.16.0`；CMake、Clang 与 SDK 的实际版本写入构建记录。
- `PYPI_RELEASE=1`，保持两份包的版本为 **0.32.3**。
- `MACOSX_DEPLOYMENT_TARGET=14.0`；CMake 同时指定 `CMAKE_OSX_DEPLOYMENT_TARGET=14.0` 与 `CMAKE_OSX_ARCHITECTURES=arm64`。
- `MLX_BUILD_PYTHON_STUBS=OFF`；CPU、Metal、safetensors 和 GGUF 支持保留上游默认开启状态。
- `MLX_METAL_JIT=OFF`，随包保留预编译 `mlx.metallib`，不要求使用者安装 Xcode 来准备这些内核。
- 分别使用上游 frontend 与 backend 分包流程；wheel 标签明确为 `macosx_14_0_arm64`。

脚本保留实际 SDK、Clang、CMake、构建命令、有效配置、源码及 wheel 校验值。上游在低于 26.2 的部署目标下会选择兼容的非 JACCL 实现及非 NAX 内核。本次原始源码构建产生的 `core`、`libmlx` 与附带 `libjaccl` 均按真实 **macOS 14.0** 目标编译；无需删去组件或修改 load command 来降低声明的系统要求。

## 缓存与分发

仅在固定源码、构建配置、wheel SHA-256、完整 `RECORD`、许可、原生依赖、实际最低系统版本与 Metal 资源均核对一致时复用缓存。校验不符时保留原缓存并失败，使用新的项目内缓存重新构建。

独立包构建器把这两份已验证 wheel 安装进新的应用运行环境副本；原开发 `.venv` 保留。App 中保留包的许可与元数据、源码来源和构建说明。源码地址固定到提交，可按记录重新构建；本说明不承诺不同 SDK、工具链或时间下的压缩包逐字节一致。

最低系统版本审计与本机实际推理检查不代表已经在 macOS 14 实机或所有 Mac 上完成运行验证。最终 App 的具体证据见对应版本的独立安装验收记录。
