# RDM-ARM —— Gitee 建仓 + 1.0.3 双源发版

状态：**双源已同步**。`origin`（Gitee）与 `github` 的分支、tag、Release 与附件全部一致。

## 这一轮做了什么

1. **在 Gitee 建了仓**（`charsen/moo-RDM`），双源发布终于补齐 —— 之前 1.0.0 / 1.0.1 /
   1.0.2 三个版本只有 GitHub 一侧。
2. **发布 1.0.3**（同事试用反馈的三条改动），两端同时发。
3. **把 1.0.1 与 1.0.2 的 Release 回填到 Gitee**，让两侧 Release 列表完全对齐。

## 仓库信息

| | |
| --- | --- |
| Gitee（canonical） | https://gitee.com/charsen/moo-RDM |
| GitHub（镜像） | https://github.com/charsen/moo-RDM |
| 可见性 | 公开（两侧一致） |
| 默认分支 | `master` |
| 描述 | RDM 的原生 Apple 芯片重写版：让 macOS 显示器跑出它真正支持的任何分辨率（含被系统隐藏的 HiDPI 模式）。不是 fork，Swift + 公开 API 重新实现。 |

### 建仓过程踩到的两点

- **Gitee 不接受空仓库设为公开**：`PATCH` 返回 422
  `空仓库不支持设置为公开仓库`。所以顺序必须是「建仓（private）→ 推内容 → 再改公开」。
  建仓时传 `private: false` 也会被静默忽略，实际仍是 private，建完必须复核。
- **Gitee 的 `PATCH /repos/{owner}/{repo}` 不是部分更新**：只传 `private` 会 400
  `name is missing`，必须同时带上 `name`。这与 moo-git-fleet 记录过的
  `PATCH /releases/{id}` 是同一类毛病。

## 同步结果

### 引用（逐远端回读核验）

`git ls-remote` 两侧完全一致：

```
af066bf  refs/heads/master
533d213  refs/tags/1.0.0        (peeled 7215c7a)
78b4a8f  refs/tags/1.0.1        (peeled ea1c841)
58fded4  refs/tags/1.0.2        (peeled 8609c40)
         refs/tags/1.0.3        (peeled af066bf)
```

`1.0.3` 的 peeled commit 与 `master` 顶点相同，符合「tag 打在发布准备 commit 上」的惯例。

### Release 与附件

`1.0.3` 已提升为**正式 Release**（两端一致），`1.0.1` / `1.0.2` 保持 prerelease。
这样仓库首页会显示「最新版本」，同事找下载入口不用翻 prerelease 列表。
两端各一个通用二进制附件：

| 版本 | 附件 | 字节 | SHA-256（两端一致，已实测下载比对） |
| --- | --- | --- | --- |
| 1.0.1 | `RDM-ARM-1.0.1-universal.zip` | 1 496 697 | `08fccd90fa2926fc1884418129b631205746f484f4e57da5c836984103a18aa4` |
| 1.0.2 | `RDM-ARM-1.0.2-universal.zip` | 1 522 026 | `810609208af04a8666395e0bf79bad9ad0efb7863385d68d88fcf5fdf60dc060` |
| 1.0.3 | `RDM-ARM-1.0.3-universal.zip` | 1 517 079 | `9eaadf97d2fa7e26fe0ebd313f3f9331943f5fc329c598d05c232e7c9fe3f8e7` |

三个附件都是从**两个远端各自下载**后与本地构建产物比对的，不是只看接口返回值。

Gitee 每个 Release 还会**自动附带两个源码包**（`1.0.x.zip` / `1.0.x.tar.gz`，
各约 46.5 KB），这是平台行为，不是我们传的。比对哈希时不要把它们当成应用包 ——
第一遍核对就因此报了三个假 MISMATCH。

## 1.0.3 的内容

同事试用后的三条反馈：

1. **去掉配置文件的导出与导入**。菜单项、偏好设置按钮、`MenuActionRouter` 的处理方法、
   `ProfileStore.export/importProfiles`，以及随之变成死代码的 `notify` / `reportError`
   全部移除，本地化键一并清理（脚本核对了全部 88 个键，无孤儿）。保存 / 应用 / 删除不受影响。
2. **分辨率与刷新率拆成两个并列菜单**。分辨率只列几何尺寸（每个只出现一次），切换时
   尽量保留当前刷新率；刷新率只列当前分辨率支持的档位，只有一个档位时整个菜单不出现。
3. **默认只显示 HiDPI 模式**。标准分辨率在菜单开关或偏好设置里放出来。

顺带修了两处：黑屏保护的描述原本只给分辨率，改刷新率时会报回同一个分辨率（新增
`DisplayMode.detailedTitle`，标题也改成「保持这个设置？」）；「没有可用模式」的文案
原来复用了 `menu.noDisplays`（「未检测到显示器」），在只是被筛选条件过滤空时是错的。

### 验证

| 项 | 结果 |
| --- | --- |
| 通用构建 | `x86_64 arm64`，2.4 MB |
| CI（Xcode 15.4 / Swift 5.10） | 全绿 |
| 分辨率条目载荷 | 从 2304×1296@60 看各条目分别带 60 Hz；576×435 与 416×312 因无 60 Hz 档落到 75 Hz |
| 刷新率菜单作用域 | 四个档位全部停在 `2304 × 1296 [4608 × 2592]`，只有刷新率不同 |
| 单档刷新率 | 840×525 下该菜单不出现，回到 2304×1296 后重新出现 |
| HiDPI 默认 | 菜单中「仅显示 HiDPI 模式」为勾选状态 |
| 黑屏保护 | `--selftest --roundtrip` 还原往返 PASS |
| 双源附件 | 两侧下载哈希均与本地一致 |
| 正式 Release | GitHub `/releases/latest` 返回 `1.0.3`；Gitee 该版 `prerelease=False`；两端附件仍在 |

## 凭证

Gitee 与 GitHub 的 API token 都在 `/Volumes/dev/git_tokens`（`## gitee_token` /
`## github_token`），只在进程内一次性读取，不打印。

> moo-git-fleet 的 NOTES 里记过教训：**不要 `cat` 或 `sed` 这个文件**，token 排在标题行
> 的下一段，常见脱敏正则匹配不上，会把它原样打进会话输出。本次全程只取单个变量。

### 正式 Release 的提升

`1.0.3` 从 prerelease 提升为正式版，两端各一次 PATCH：

- **GitHub**：`PATCH /repos/{owner}/{repo}/releases/{id}`，只传 `{"prerelease": false}`
  即可 —— 它是真正的部分更新。
- **Gitee**：`PATCH /repos/{owner}/{repo}/releases/{id}` **不是部分更新**，只传
  `prerelease` 会被拒。必须把 `tag_name` / `name` / `body` / `prerelease` /
  `target_commitish` 整套原样回传，所以先把当前 Release 读出来重建 payload 再提交。
  与建仓时 `PATCH /repos/{owner}/{repo}` 缺 `name` 报 400 是同一个毛病。

提升后复核：GitHub `/releases/latest` 返回 `1.0.3`（`prerelease=False`），
Gitee 列表中 `1.0.3` 的 `prerelease` 也为 `False`，两端附件未受影响。

## 下一步（未做）

- 复盘清单里仍留着：快捷键注册失败静默、零测试、无 `LICENSE`、无 `CHANGELOG`、
  9 个长期未使用的本地化键。
- `1.0.1` / `1.0.2` 仍是 prerelease。历史版本保持原样即可，不影响「最新版本」显示。
