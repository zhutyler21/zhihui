# Markdown 笔记与原生渲染

会议笔记默认以排版预览打开；空笔记显示开始写笔记。点击“编辑”后使用原生 `TextEditor` 编辑 Markdown 原文，等宽字体与简短语法提示帮助录入。点击“完成”会等待现有 `AppModel.saveNotesIfNeeded()` 实际保存，再切回预览。失败时显示错误并保留原文与编辑状态。

原数据库中的笔记字符串不迁移、不清洗、不转换；普通文字仍是合法段落。Markdown 只影响显示，来源字符串始终是存储的依据。现有自动保存由 AppModel 负责，没有另建自动保存计时器。

## 集成接口

```swift
MarkdownNotesView(model: model)
    .id(meeting.id)

MarkdownBody(text: meeting.summary)
MarkdownBody(text: turn.answer)
```

笔记视图以会议 ID 拥有自己的编辑状态。所有输入写入继续通过 `updateNoteDraft`，保留切换会议时的编辑锁。完成操作捕获所属会议、保存序号、原文；只有保存成功、仍是同一会议、当前原文与捕获值相同且 `noteDirty == false` 才进入预览。旧会议的迟到保存完成不能切换新会议的编辑状态。`MarkdownNoteSession` 是视图实际使用的 Foundation 状态逻辑，也直接用于失败与迟到完成测试。

## 显示能力

- 一级到六级标题、段落、段落之间的空行。
- Markdown 软换行显示为空格；两个行尾空格或反斜线产生硬换行。
- 有序、无序、任务列表，含缩进与简单续行；任务状态在预览中只读，编辑原文时修改 `[ ]` / `[x]`。
- 引文、分隔线。
- 反引号或波浪线围栏代码；代码原始换行、空行、缩进和 CRLF 保留。显示语言，并用原生复制按钮复制代码正文。只有代码块横向滚动。
- 管道表格、列对齐、转义管道、行内代码中的管道。宽表或窗口较窄时使用 `ViewThatFits` 自动转为按行展示的“字段名 / 内容”卡片，避免挤压中文列或出现页面横向滚动。
- 行内加粗、斜体、删除线、链接和代码使用本地 Foundation `AttributedString` 解析，再交给 SwiftUI `Text`。

所有显示由原生 SwiftUI 组成，没有 WebView、HTML 页面或远程图片下载。HTML 不执行。链接只有在用户点击时由系统处理；仅 http、https、mailto 链接可交互，其他 scheme 不激活。图片 Markdown 不加载图像。此实现不是完整 CommonMark 引擎，例如引用式链接、脚注、数学公式和复杂嵌套列表不在本版支持范围；原文仍完整保留，可继续编辑。

## 结构与布局

`MarkdownDocument.swift` 包含纯解析器、块类型、原始 UTF16 来源范围和笔记编辑状态。块、列表项、表格行/单元格使用来源位置派生的确定性 ID，不依赖 `ForEach` 的可变数组 offset。引用嵌套设上限，异常深的标记仍作为文字保留，避免递归堆栈失控。未闭合代码围栏保留后续原文作为代码。

`MarkdownRendering.swift` 提供通用 `MarkdownBody(text:)`。解析结果为派生缓存，通过 `onChange(of:initial:)` 在原文变化时更新，不在每次 body 计算中重复解析。段落和中文适应当前可用宽度；代码保持等宽横向滚动。使用系统文字样式、标题可访问性标签、原生按钮和选中文字，颜色来自自适配 `Design`。渲染区域单独使用适合链接文字的 `Design.accent`；完成按钮容器使用 `accentFill` 保持深色模式下白字对比。

## 已执行验证

先写测试并观察缺少解析模块的预期编译失败，再实现。验证命令：

```sh
bash scripts/test-markdown.sh
xcrun swiftc -swift-version 5 -typecheck -target arm64-apple-macosx14.0 \
  -module-name Zhihui -module-cache-path work/fixture/markdown-tests/module-cache \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia Sources/*.swift
```

两个命令均通过，没有编译警告。测试同时执行纯解析 / 状态逻辑，以及真实现有 AppModel + 带鉴权的本机 HTTP 测试服务：

- 中文与 emoji / 组合字符、来源 UTF16 范围、确定性 ID。
- 原文不变、代码空行 / 缩进 / CRLF、未闭合围栏、缩进 tab 围栏、转义语法。
- 软 / 硬换行、列表、任务、引文、表格边界、八列表格、行内样式和不安全链接过滤。
- 失败保存仍留编辑，脏草稿和已变化原文不能误进预览，A 迟到完成不能影响 B。
- **实际 AppModel 保存**原 Markdown 字符串后通过 HTTP 读回精确相等；实际 HTTP 500 拒绝保存后原文、dirty、编辑状态与错误提示保留；真实切换并加载 B 后处理 A 的完成票据不会修改 B。

测试产物都位于项目 `work/fixture/markdown-tests/<本次运行>/`；隔离环境变量防止测试访问正式录音队列。脚本只停止自己启动的测试服务。测试没有打开 GUI、修改 dist / 已安装应用或录音权限。

以上证明编译、解析和实际保存流程，不替代原生页面视觉与点击验收；窗口缩窄、深色模式、长中文、宽表、代码复制等真实 UI 验证由整体界面验收执行。
