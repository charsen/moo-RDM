# moo-RDM 协作提醒

> 规则来源：通用协作、授权、Git 与测试规则见 `~/.agents/AGENTS.md`（每轮自动加载）；Moo/Laravel 领域规则见 `~/.agents/moo.md`（涉及 scaffold/Schema/migration/Composer 时先读）。本文件只写本仓特有约束，不复制全局规则；冲突时以本文件为准。

本仓是 macOS 原生 Swift/AppKit 项目。改显示、原生壳或发布流程前，先读现有 `NOTES.md`、`README.md` 和目标文件。

## 检查更新

改更新相关代码或发版前，先读 [`docs/UPDATE-CHECK.md`](docs/UPDATE-CHECK.md)。所有客户端统一走 `/api/v1/updates/check`；平台/架构矩阵、手动/自动策略和发布清单以该文档为准，不要新增旧通道。

## 构建与产物

构建或发版前先读 `docs/BUILD.md`。每次构建后必须核对产物路径、版本、平台/架构、文件大小、SHA-256、签名或安装验证，并把结果写回 `docs/BUILD.md` 的「最近构建」；没有核对结果不得发布。
有 `scripts/verify-build.sh` 的仓，构建后必须运行并保证通过；脚本中的哈希随版本更新。
macOS 包必须使用 Developer ID Application 签名，并完成 Apple 公证 + staple；`verify-build.sh` 必须通过 `spctl` 和 `stapler`，未公证不得发布。
