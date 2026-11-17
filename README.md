# Space Station

> 剪贴板工作台 ·  macOS（Apple Silicon）

Space Station 是一个常驻 macOS 状态栏的剪贴板工作台。复制即捕获，空格键唤起统一预览，并根据剪贴内容预测下一步可执行的 Action。全部数据保存在本机，不上传、不联网。

> 本仓库是**源码仓库**。编译好的 DMG 在 [Releases](../../releases) 下载。

## 功能

- **剪贴板历史** — 文本 / 图片 / 文件 / URL 统一捕获与检索，数据来源可追溯
- **超级 Quick Look** — 空格键预览图片、视频、PDF、文档、代码；由 Space Station 接管，非系统 Quick Look
- **Action 预测** — 依据剪贴内容预测并推荐下一步操作（复制、粘贴、净化链接、Favorite 等）
- **Split / 导航 / 筛选** — 多栏对照、类型筛选、收藏舱，按使用习惯组织的导航
- **链接净化** — 去除跟踪参数后写回卡片
- **本地 OCR** — 图片文字用 Apple Vision 在本机识别
- **缩略图缓存** — 内存 LRU + 磁盘缓存，滚动流畅
- **边缘指示器** — 卡片墙可滚动方向的可点击提示，支持整屏翻页

## 系统要求

- Apple Silicon（M 系列）Mac
- macOS 15 或更高版本

## 构建

需要 Xcode 15+。仓库自带 `.xcodeproj`，也可由 `project.yml` 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成：

```bash
xcodegen generate
open SpaceStation.xcodeproj
```

在 Xcode 中选择 `SpaceStation` scheme 编译运行。应用为 `LSUIElement`，启动后常驻状态栏。

## 许可

本项目采用 **GNU AGPL-3.0** 开源许可，详见 [LICENSE](LICENSE)。欢迎 Fork 与二次开发。

如需要将本软件用于闭源分发或 Mac App Store 上架等不适合 AGPL 的场景，可联系作者获取**专有许可**（双许可）。

第三方组件与归属见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。

---

*Space Station — 把剪贴板变成工作台。*
