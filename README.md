# MemeMemo

轻量的 macOS 菜单栏表情包管理器。点击菜单栏中的笑脸图标即可打开原生面板，不占 Dock，也不依赖云端服务。

## 当前可用（MVP）

- 菜单栏面板、搜索框、分类栏与自定义分类。
- 图片导入和剪贴板捕获开关；捕获期间复制图片会自动保存。
- 图片本地 PNG 存储、SHA-256 去重、右键复制/修改备注/移动/删除。
- 管理模式下的多选、批量移动和删除。
- 备注和已写入 OCR 文本的本地检索；没有备注时会使用 OCR 文本，仍为空时为“未命名”。
- 按住拖动图块排序，排序按分类持久化。
- 使用 `manifest.json` 和 `images/` 目录的 ZIP 导入/导出。

## 开发与运行

需要 macOS 14+ 和 Swift 6。执行：

```bash
./script/build_and_run.sh
```

应用会打包到 `dist/MemeMemo.app`。白盒检查：

```bash
swift run MemeMemoWhitebox
```

本地表情包库位于 `~/Library/Application Support/MemeMemo/`；图片在 `images/`，元数据在 `library.json`。

## OCR 说明

本轮已提供离线 OCR 抽象和 Tesseract 调用接口，但尚未将 Tesseract 二进制及 `chi_sim`、`eng` 语言数据打进应用包。这样可以避免把系统 Vision 冒充为“开源 OCR”。下一轮会把可再分发的开源运行时及其许可文件随 `.app` 一起封装，达到真正的离线开箱即用。

详细进度见 `Docs/ROADMAP.md`，续作信息见 `Docs/HANDOFF.md`。
