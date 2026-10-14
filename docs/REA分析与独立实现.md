# Foresight 只读分析与知会实现依据

分析日期：2026-10-13。对象：本机 `/Applications/Foresight.app`，arm64。

公开仓库保留这份分析与独立实现的说明。以下提到的原始 `docs/rea/` 转储只在本机保留，不随源码或 Release 上传；路径与证据标识用于解释历史分析范围，不表示公开提供原应用或原始分析文件。

## 实际执行的 REA 分析

使用 `npx -y rea-agents@6.4.0` 的 CLI，未运行 setup，未改动 MCP/技能配置，也未向原应用注入本项目代码。

| 操作 | 保存证据 | 证据标识 |
| --- | --- | --- |
| inspect-artifact /Applications/Foresight.app --format json | rea/foresight-artifact.json | ev_319da002f29c099436f1aa9aa8e1e82439eeb94df13a8081d7bd9ee61fa6473f |
| inspect-macho /Applications/Foresight.app --format json | rea/foresight-macho.json | ev_855210b1f902deacfa2a46dda99f7ad9cc01dce9436dc6072e22b888456191ce |
| trace-dylib-resolution /Applications/Foresight.app --architecture arm64 --format json | rea/foresight-dylibs.json | ev_de3fa701f5d220d6ec911e538bfc6689ea06b9d44bde4dc38cca6421ebf0a0fa |
| project-apple-application-graph rea/apple-graph-input.json --format json | rea/foresight-apple-graph.json | ev_052b679e703dc84fcc96df46b3c675abccf6b1f2cead6529d0e8ba36b38c7056 |
| providers --format json | rea/providers.json | 配置状态，非功能证明 |

原主二进制 SHA-256：`fa98b856bfbe9b40cdebfb9f975f7867ec5c0a3ca75b81214a096a60b6db8326`。
REA 包清单中的目录 digest 为 `b6b9512bb33b194c547793e90fcd1dec09733454a22e4a4ee29d33d2db87ecf6`；目录清单哈希和主二进制哈希含义不同。

REA 清单观察到 252 个内容节点，并给出 macOS bundle/Framework 结构。Mach-O load commands 中有 FlutterMacOS、LiteRT、Metal 等依赖。导出符号中存在：

- `OdmlSpeechProcessorTranscribe` / `OdmlSpeechProcessorFinishStream`：转写相关原生入口。
- `litert_lm_create_conversation_v2`：语言模型对话入口。
- `embedding_gemma_compute_text_embedding`：文本向量入口。
- `invokeRetrievalOnlyPipeline` / `invokeRetrievalOnlyPipelineWithFilters`：检索及带过滤条件的入口。

这些证据证明入口/依赖存在，不能仅凭名称证明调用顺序、线程安全、筛选语义、模型能力或整个功能已复刻。本机 REA providers 检查显示 Ghidra/Hopper/IDA 未配置；本次没有取得原程序完整反编译源码，也没有宣称恢复了 Google 专有实现。

## 数据与界面补充观察

原 SQLite 的只读 schema/count 记录在 `rea/database-metadata.json`。这是 Python SQLite 元数据检查，不冒充 REA 的数据库反编译结果。

- `event_transcript_table` 以事件标识及时间保存完整转写 JSON 和 AI 摘要。
- `notes_table` 保存手写与增强笔记。
- `event_document_table` 将事件与文档关联；`source_text_table` 保存来源文本；`document_embeddings` 保存文档向量。
- 本次观察源文本 64 行、文档向量 62 行，会议关联 5 行。这个数量仅是当时快照，不证明所有转写已被索引。

通过 CUA 实际查看原生会议与提问页面：浅灰蓝背景、深蓝主动作、白色圆角内容区、左侧图标导航、按日期分组会议列表，以及底部问答输入。知会借鉴信息层级与留白，不使用 Google 商标、图标素材或原程序页面代码。

## 独立实现的设计

1. 原生 SwiftUI + AppKit 主窗口；会议、知识库、提问和回收站都在应用中管理。
2. 自有 SQLite 数据库，UUID 会议标识。会议的转写、笔记、摘要和附件均保存 `meeting_id`。删除可恢复，检索前排除回收站。
3. 中文转写使用公开 SenseVoice int8 与 sherpa-onnx；本地语言生成使用 Qwen3-4B-Instruct-2507 的 MLX 4bit 权重；语义检索使用 BGE-small-zh-v1.5。均独立于 Foresight 可执行文件/模型。
4. 向量检索先在 SQL 限定范围，再计算相关性；可选全部资料、全部会议或指定会议。将原文证据及编号交给本地模型回答，并显示引用。
5. 文件先保存副本，再抽取文本、分块和索引。读不了的资料保留状态，不能伪装成已索引。
6. 原会议导入使用只读 SQLite 连接与独立快照，按原事件/时间防重复，不写回原数据库，不自动导入邮件/通讯录。

模型来源、固定 revision 及 SHA-256 写入 `models/manifest.json`；许可文本保留在 `docs/licenses/`。SenseVoice 权重使用 FunASR MODEL_LICENSE，不能把其工具代码许可当成权重的许可。当前交付是本机使用的独立应用；未发布原程序、未规避其登录/授权或商用分析工具许可。

## 验证边界

原功能分析证据和新应用运行证据分别保存。新应用的完成状态以本项目验收记录为准，不能用 REA 的 `complete-within-inventory` 清单覆盖度声称新应用全部功能完成。所有集成测试使用项目内隔离数据目录。
