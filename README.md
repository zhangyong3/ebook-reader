# 页间 · Leaf

原生 macOS 电子书阅读器。最低 macOS 14，SwiftUI / AppKit 界面，系统 WebKit 排版，本地 SQLite 书库，无需应用账号或后台服务；离线阅读与查词不联网，语句解析按需调用你配置的模型接口。

## 使用

构建产物位于 `dist/Leaf.app`，双击打开。也可将应用拖入 Applications。

1. 拖入 EPUB，或按 ⌘O 导入。空书库可打开内置《阅读器使用指南》。
2. 点击正文两侧留白处的箭头，或用左右方向键翻页；右下角显示“当前页 / 全书总页数”，修改当前页并按回车可跨章节跳转。工具栏可打开目录、搜索、书签与排版设置。拖动正文和右侧查词/笔记面板之间的分隔线，可调整面板宽度。
3. 在“页间 → 管理离线词典”中导入 MDX。配套 MDD、CSS、图片和音频放在相同目录。词库保留在原位置，导入后请不要移动。
4. 双击或拖动选中文字，鼠标旁会显示查词、翻译、高亮、书签四个图标；选中本身不会发起查询。按住 Command 单击正文单词，可直接取词并打开右侧离线释义，无需先选中。点击查词在右侧显示离线释义，点击翻译打开“语句解析”。
5. 在“页间 → 软件设置…”（⌘,）填写 Base URL、API Key 和模型。解析以流式显示译文、简明句式与语块、关键语法、短语、B1 及以上重点词汇和例句，可随时停止；仅在点击解析时发送选中文字。
6. 右击高亮可删除或修改颜色和方式（透明色块、下划线、删除线），下一次高亮沿用最近修改的样式。点击书签图标会在原文留下别针，从左侧“书签”列表跳回。
7. 双击正文非文字区域可直接输入即时笔记，输入自动保存。平时仅显示文字，编辑时显示光标和贴合内容的细虚线框，随文字与换行自动伸缩；右击可删除或修改字体、颜色和字号。右侧“笔记”列表可以定位。
8. 在正文选词查词或解析语句后，该位置会自动留下虚线下划线；支持 Command 单击取词和选区工具栏，并在重新打开书籍后恢复。自动标记独立保存，不加入手动笔记列表或笔记导出。旧版历史没有原文位置，无法据此补画原来的标记。
9. 右侧“历史”保存查词及解析结果；相同内容只保留最近一次（忽略大小写和多余空白，查词与解析分别判重）。点击记录恢复当时内容，不重复请求模型。
10. 在“笔记”菜单导出本书 Markdown，或备份全部笔记为 JSON。恢复 JSON 前先导入对应的原版 EPUB。

示例词典在 `Fixtures/Leaf Demo.mdx` 与同名 MDD 中，包含 reader、leaf、annotation、reading、测试等原创建例词条。音频是一段测试音，不是真人发音。

## 功能与范围

- 流式 EPUB 2/3：章节目录、分页 / 按章连续滚动、图片、书内链接、脚注跳转、书签、全文搜索。
- 字体、字号、行距、正文宽度、白昼 / 纸色 / 夜读主题；每本书独立保存。右侧面板使用原生可拖动分栏，宽度为 280–640 点，并为正文保留最小阅读宽度。
- MDX/MDD 2.x：UTF-8、UTF-16LE、GBK/GB18030、Big5，未压缩 / zlib / LZO1X，关键字索引混淆，词条跳转与本地资源。
- 浮动选区工具栏、高亮 / 下划线 / 删除线、别针书签、带字体样式的即时笔记；批注保存 CFI、章节、摘录和前后文。位置不匹配时尝试唯一文本定位，失败则保留笔记并提示。
- 本地进度与批注保存、Markdown 导出、JSON 笔记合并恢复。备份不包含 EPUB 和词库，也不覆盖现有阅读设置。
- 导入 EPUB 后保留应用内副本；按 SHA-256 区分文件版本，同一文件不会重复导入。

暂不支持 DRM、固定版式 EPUB、自由手绘、云同步、PDF/TXT 等其它格式，以及 MDX 1.x/3.x、需要注册密码的词库、非空 Compact 样式模板和词库自带 JavaScript。

页码按当前字体、字号、行距及可用阅读宽高对全书计算，不是原书印刷页码。切换侧栏或调整排版后，后台重新分页；计算期间显示“正在分页…”，正常翻页仍可使用。滚动模式按阅读区域的一屏作为一页。书内脚注当前为跳转与返回，不是脚注弹窗。

已验证自建格式样本，以及本机牛津高阶第 9 版词库的导入与基础查词。Compact/Compat 标记为 Yes、StyleSheet 为空的普通 HTML 词库可以正常导入；非空模板仍需另行适配。词典释义跟随系统深浅色外观；深色下覆盖低对比度的前景和背景颜色，切回浅色恢复词库原样式。词典中的复杂脚本交互会被禁用；依赖脚本才能显示的定义暂不承诺兼容。

## 构建

需要安装 Xcode，并选择其命令行工具。当前在 Xcode 27.2 / Swift 6.4.2 上构建验证；源码使用 Swift 5.9 包格式与 macOS 14 API。

```sh
./scripts/build.sh                    # 当前 Mac 架构，Debug
./scripts/build.sh release universal  # Apple Silicon + Intel，Release
./scripts/test.sh                     # 核心测试
```

也可用 Xcode 打开 `Package.swift` 开发。应用运行不需要 Node.js 或 Python；离线阅读与查词不需要网络，语句解析需要访问所配置的接口。Python 用于生成测试样本与本地流式测试服务：

```sh
python3 scripts/make-fixtures.py
```

构建脚本生成应用图标、打包本地资源与依赖声明，并进行 ad-hoc 签名。当前产物是开发试用版本，没有 Developer ID 签名或 Apple 公证；正式对外分发需要后续完成签名与公证。

## 本地数据

默认目录：`~/Library/Application Support/Leaf/`

- `library.sqlite`、`library.sqlite-wal`、`library.sqlite-shm`：书库、排版、进度、批注、查询标记、查询历史、Base URL 和模型。
- API Key：按 Base URL 分别保存在数据目录下的 `api-keys.json` 本地明文文件中，文件权限为仅当前用户读写（0600）；不写入数据库、日志或笔记备份。设置页以圆点显示已保存的 Key，修改后保存，清空后保存即删除。旧版钥匙串中的 Key 不自动读取或迁移，升级后需重新填写。
- 历史保存解析文本和词典 HTML 快照；词典配套图片、CSS 和音频仍需原词典文件可用。JSON 笔记备份不包含历史或接口配置。
- `Books/<SHA-256>/original.epub`：导入副本。
- `Books/<SHA-256>/content/`：排版资源，按章访问。

备份完整书库时先退出应用，再复制整个 Leaf 目录。仅用 JSON 导出时，可单独保存和恢复笔记，但必须保留对应 EPUB。

EPUB 导入限制为 512 MB，单个解压资源不超过 128 MB，解压总量不超过 1 GB。词库使用内存映射和按块读取，最多缓存一个展开的正文块；关键词索引在首次使用时于后台解析，当前未做跨启动磁盘索引缓存。

调试可用 `LEAF_LIBRARY_PATH` 指定独立书库，避免测试污染个人数据。

## 结构与格式扩展

- `Sources/LeafCore/EPUBImporter.swift`：EPUB/ZIP 导入、校验与字体反混淆。
- `Sources/LeafCore/MDict.swift`：词典解析，与正文阅读独立。
- `Sources/LeafCore/LibraryStore.swift`：本地数据库与批注恢复。
- `Sources/LeafApp/WebViews.swift`：本地资源协议、WebKit 与原生交互。
- `Sources/LeafApp/Resources/Web/reader.js`：EPUB.js 桥接、文本选区与批注定位。
- `Sources/LeafApp/ContentView.swift`、`Panels.swift`、`StudyPanels.swift`：原生界面、历史与软件设置。
- `Sources/LeafApp/OpenAIClient.swift`：OpenAI 兼容 Chat Completions SSE；`Sources/LeafCore/LocalAPIKeyStore.swift` 负责本地 Key 保存。
- `Sources/LeafApp/StudyActions.swift`：查询历史、流式生命周期与笔记样式。

新增格式应新增独立的导入器和阅读视图，共用书库、批注列表与导出。首版位置字段为 EPUB CFI；接入 PDF 时必须新增 PDF 页面/坐标定位类型与数据迁移，不将 PDF 转换为 EPUB，也不把坐标塞入 CFI。

## 验证

20 项核心测试（含可选本地词库回归）覆盖 EPUB 元数据与重复导入、危险路径和损坏文件、字体反混淆、数据库持久化与恢复、MDX Unicode / 索引混淆 / LZO / 跳转、跨正文块读取、MDD 图片音频，以及 RIPEMD-128 标准测试向量；新增旧批注兼容、即时笔记样式持久化、历史判重、本地 Key 保存/清空/隔离与文件权限、接口地址校验、SSE 中文分片和完成/错误状态测试。

真实窗口验证了目录跳转、选区工具栏查词、右键高亮样式、即时笔记、解析历史回放、设置页面、保存与重开笔记、字号重排、跨章搜索、MDD 图片与音频链接、Markdown 文件导出。Debug 的可选集成检查还验证四种窗口尺寸及书籍脚本被 CSP 拦截。

```sh
open -n dist/Leaf.app \
  --env "LEAF_LIBRARY_PATH=$PWD/.build/SmokeLibrary" \
  --args --open "$PWD/Fixtures/Guide.epub" \
  --check-report "$PWD/.build/integration-report.json"
```

上面的 `--check-report` 仅在 Debug 构建生效。在隔离书库已导入词典的情况下，加上 `--dictionary-check` 会检查深色/浅色/深色切换、行内 important 颜色恢复、深色正文最小 4.5:1 对比度和 300/500/360 点分栏宽度。集成检查窗口为 920×600、920×800、1180×600、1180×800，均展开左右侧栏。实际运行验证基于本机 Apple Silicon 系统；macOS 14 与 Intel 机器仍需真机回归。内存与启动耗时尚未建立性能基线。

### 翻页和页码验证

```sh
./scripts/test-pagination.sh
```

原生 WebKit 集成检查覆盖全书章节页数、逐页跨章跳转、首尾箭头、非法页码、字号/侧栏重排、最小阅读宽度、滚动模式翻页，以及重排后每页仍可到达。测试使用独立书库，不访问接口或个人数据。后台排版每次仅测量一个章节，完成后释放临时排版视图；只保留章节页数与分页位置，不修改 EPUB 原文。

### 标记位置回归验证

```sh
./scripts/test-annotation-layout.sh
```

脚本构建 Debug 应用，在独立测试书库中创建高亮、实线下划线、删除线、查询虚线和书签，逐项对照真实文字 Range 坐标。检查 14 种布局状态：左右侧栏展开/折叠、不同右栏宽度、920×600 最小窗口、正文宽度上限两侧，以及分页/滚动模式。误差超过 1px 或覆盖层数量不符即失败，报告保留在 `.build/annotation-layout.*/report.json`。也可在 `--check-report` 启动命令后增加 `--annotation-layout-check`，使用空白隔离书库运行。

本次修复前，居中正文只平移而不改变宽度时会漏掉标记重绘，回归检查测得 105.5px / 140.5px 偏移；修复后 14 种状态均通过，最大误差低于 0.02px。覆盖层统一在下一动画帧重绘，并监听视口几何变化及 EPUB 显示/重排事件。

### 语句解析本地集成验证

启动 `python3 scripts/mock-openai.py` 后，在上述 Debug 启动命令末尾增加 `--study-check`。测试书库应已导入词典；始终使用独立的 `LEAF_LIBRARY_PATH`。检查使用 127.0.0.1:8769 上的模拟 Chat Completions 服务与临时测试字符串，不读取或保存真实 Key。

16 项检查覆盖不自动查词、工具栏、实际高亮着色与样式复用、别针、即时笔记样式与持久化、历史判重、增量流、中文与 emoji、停止、HTTP 错误以及历史回放、查询虚线标记、同位置判重与独立持久化。真实 OpenAI 服务尚未带 Key 验证；需要用户在软件设置中填写该服务支持的模型名称与有效凭据。

句子结构只概括整体句式和语块，不逐项列主谓宾；词汇由模型按当前义项筛选 CEFR B1 及以上（包含 B1），不列基础词。历史结果保留生成时的内容，点击“重新解析”可按当前规则重新生成。

Base URL 默认 `https://api.openai.com/v1`，也支持 OpenAI 兼容服务的 HTTPS 地址；仅本机 localhost 允许 HTTP。请求采用 `POST /chat/completions`、`stream: true`，不跟随重定向。接口参考：[Chat Completions](https://platform.openai.com/docs/api-reference/chat/create)。

第三方声明见 `ThirdParty/`，随应用一同打包。
