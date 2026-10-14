# Python 包补充许可

应用内的 Python 包保留各自许可文件与 `dist-info` 元数据。本目录额外保存部分包的许可全文，保证即使原 wheel 没有附带独立许可文件，也能查阅原作者的版权声明及条款。

每个目录的 `SOURCE.json` 记录包版本、官方来源，以及源码归档或许可文件的 SHA-256；GitHub 来源还记录对应 tag 的完整 commit。文件按来源原文保留。本项目的 MIT 许可不替换这些依赖的许可。

ONNX Runtime 的 `LICENSE` 与 `ThirdPartyNotices.txt` 已保留在应用中 `Runtime/python/lib/python3.12/site-packages/onnxruntime/`。CPython 与底层组件说明另见 `python-standalone/`。
