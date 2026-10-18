# RDM-ARM 1.2.0 —— 审计结果可机器读取，自检脱离硬件依赖

状态：**双源已发布**。`origin`（Gitee）与 `github` 的分支、tag、Release 与附件一致。

## 起因

1.1.0 把「刷新率为什么拿不到」讲清楚了，但只讲给人看：一张 8 行的表，脚本没法用。
而 8 行是终端可读性限制，不是数据限制——`geometries` 里其实有 31 行。

同一轮还暴露了两件事：`offeredAtAnyGeometry` 取的是表格第一行而不是面积最大者；
「链路预算读不到」被当成「链路够不着」报了出去。加上自检必须插着显示器才能跑，
CI 永远够不着这套逻辑。于是 1.2.0 做三件事：数据可机器读、判断改对、测试挪进 CI。

## 改了什么

| 位置 | 变化 |
| --- | --- |
| `--refresh-audit --json` | 全量 `geometries`；`verdict`、`recommendation.kind`、`command`、`computesOnly`、`bestCase`、`alreadyOffered`；不适用的键省略而非 `null` |
| `--capabilities --json` | `display` / `edid` / `nativeTiming` / `nativeCeiling` / `link` / `hiddenRates` / `override{installed,writable}` |
| `--edid --json` | 明确报错 exit 2 并指向 `--emit-edid`；不再静默忽略 `--json` 打印文本表 |
| 判定 | `offeredAtAnyGeometry` 改为取面积最大的 offered 行；新增 `isUndetermined`；`largestReachingTarget` 改名 `recommendedGeometry` |
| 输出 | 结论优先报零成本答案；`unknown` 与 `unreachable` 分开措辞 |
| 自检 | `--selftest-timing` 拆合成段与真机段，45 条断言（41 合成 + 4 真机）；无头环境 41 PASS + 1 SKIP + exit 0 |
| 覆盖 | `hidden` 分支补 9 条端到端断言（合成 EDID 声明 1080p@75、模式表只列 60） |
| CI | 新增 headless self-test 步骤 |
| 版本 | 三处同步 1.2.0 |

源文件数不变（27），`--refresh-audit`/`--capabilities` 的文本路径行为只改了结论行顺序。

## 屏幕上的样子

```bash
$ rdm-arm --refresh-audit -r 75
    verdict        available now at 2048 × 1536
```

以前这里会说「within the link budget at 1920 × 1080, but the panel never declared it」
再加一条 `--custom-timing` 建议——而 2048 × 1536 的 75 Hz 早就在系统列表里，右键就能选。

```bash
$ rdm-arm --refresh-audit -r 75 --json | jq '.verdict, .recommendation'
"offered"
{
  "kind": "available-now",
  "width": 2048,
  "height": 1536,
  "pointWidth": 1024,
  "pointHeight": 768
}
```

`verdict` ∈ `offered` / `hidden` / `synthesizable` / `unreachable` / `unknown`；
`recommendation.kind` ∈ `available-now` / `mode-switch` / `custom-timing`，后两者带
可直接执行的 `command`，`computesOnly: true` 表示它在 Apple 芯片上只算不写。

## 三个判断错误的成因

| 症状 | 根因 |
| --- | --- |
| `-r 75` 报「already offered at **640 × 480**」，而 2048 × 1536 早已提供 | 属性取表格第一行；表格序是 native → EDID 声明 → 面积，不是面积序 |
| 结论先讲要合成时序、要管理员密码的那条路 | 只认「支持程度最高」的行，不认「现在就能用」的行 |
| 预算读不到时仍说「链路只到这儿」 | `unknown`（没读到）被当成 `unreachable`（读到了且不够） |

三条各自都有断言钉住，并做过 mutation：把 `offeredAtAnyGeometry` 改回 `.first{}`、
把 `isUndetermined` 写死 `false`、丢弃 EDID 声明层，分别触发 FAIL。

## CI 两次红，判据错了两版

这段值得记下来，因为两次都是**断言写错了**，不是代码写错了。

第一版要求「有传输服务就必须读得到 EDID」：

```
FAIL  EDID readable for display 0
```

GitHub macOS runner 有虚拟屏，`IOPortTransportState` 条目是有的，只是那条 transport
不带 EDID——「有 transport」既不等于「有面板」，也不能反推「没面板」。

第二版改成「有 transport 但没 EDID 就算失败」，并给出更细的报错：

```
FAIL  EDID readable for display 0 — transport exists but no EDID came back
```

仍然红，因为 runner 恰好就是这一种。

第三版问的是真问题——**整机有没有任何 transport 发布过可解析的 EDID**：

| 情形 | 结论 |
| --- | --- |
| 没有显示器 | SKIP |
| 有 transport 但整机没有任何 EDID（VM / 无头 runner / 屏幕共享） | SKIP |
| 整机有 EDID，但这个显示器取不到（真面板） | FAIL |

这一版在 runner 上是 `SKIP  no EDID anywhere in the I/O registry`，41 PASS，exit 0；
本机真面板仍 45 PASS / 0 SKIP。两条分支都用「临时把 `read()` 打回 `nil`」实测过，
不是推演出来的。

顺带留下一个真的守卫：如果哪天 `Candidate` 匹配或解析回归，导致整机有 EDID 却读不出来，
它会红——这是它该守的东西。

## 验证

| 项 | 结果 |
| --- | --- |
| CI（`644631d`） | **success**；`archs: x86_64 arm64`；三处版本一致；41 PASS + 1 SKIP |
| `--selftest-timing`（本机） | **45 PASS / 0 FAIL**，0 SKIP，exit 0 |
| `--selftest`（本机） | exit 0，9 个顶层项，能力子菜单内容完整 |
| `--refresh-audit --json` 结构 | `verdict=offered`、`recommendation.kind=available-now`、31 行 geometries |
| `--capabilities --json` | 9 个顶层键，`architecture=arm64` |
| `--edid --json` | exit 2，提示指向 `--emit-edid` |
| 两个 slice | arm64 与 x86_64（Rosetta）输出的审计 JSON 结构与数值一致；Rosetta 下 `override.writable=false` 仍生效 |
| mutation | 4 次（offeredAtAnyGeometry / isUndetermined / declared 层 / 无屏模拟），全部按预期 FAIL 或 SKIP |
| 拆提交 | 两个提交各自单独 build + 自检通过，不是把文件切开 |
| zip 内容 | `RDM-ARM.app`（1.2.0，双切片，ad-hoc）+ `安装说明.txt`（版本号 1.2.0） |
| 双源附件 | 两侧下载后与本地构建产物 `shasum -a 256` 三方一致 |
| `/releases/latest` | 两端均返回 `1.2.0`，`prerelease=False` |

### 发布时踩的一个坑

第一次传 GitHub 附件用的是 multipart 表单（Gitee 要求那种），但 GitHub 的
`uploads.github.com` 要的是**原始字节流**。结果存进去的是 multipart 信封，
比本地文件多 174 字节，哈希 `61460eef…`。

这个错误只有把附件**下载回来算哈希**才看得见：上传接口返回 `state: uploaded`、
`size` 也显示 1 677 977（不是报错，是它真的存了信封）。发现后删掉重传原始流，
再下载校验为 `82de5211…`。CDN 对公开直链还有几分钟旧缓存，带 `Cache-Control: no-cache`
重取才拿到新内容——核对哈希时别被这层缓存骗到。

## 未验证 / 已知边界

- **`hidden` 分支仍是合成样本**：本机面板声明的速率 macOS 全列了出来，
  `--capabilities` 报 `hidden rates none`，造不出现场。真机样本要拿一台能跑 override 的
  Intel 机器，不是代码能补的。
- **Apple 芯片写 override 仍然无效**（1.1.0 的真机结论）。`--write` 在弹密码前拦住，
  退出码 3；时序仍可算、可 `--emit-edid` 导出。
- **链路预算来自 Apple 私有 DCP 类**，系统升级可能改类名；读不到就只说「判不了」，
  不猜数。
- GitHub runner 上的 1 SKIP 属于环境（虚拟屏），不是覆盖缺口。

## 引用（逐远端回读核验）

```
644631d  refs/heads/master   (origin 与 github 一致)
071bf3a  refs/tags/1.2.0     (annotated → 644631d，两端对象 ID 相同)
```

| commit | 说明 |
| --- | --- |
| `7b246cb` | `fix: 审计结论先给「现在就能用」的答案，并把「读不到预算」与「够不着」分开` |
| `c229680` | `feat: 审计与能力信息支持 --json，自检不再依赖真机面板` |
| `6eb5be3` | `chore(release): 版本号提到 1.2.0` |
| `b2487f0` | `fix: 虚拟屏不算「EDID 读不到」，自检该 SKIP 而不是 FAIL` |
| `644631d` | `fix: 判据换成「注册表里有没有 EDID」，runner 上的 transport 不发布 EDID` ← **tag 在这里** |

后两个 `fix` 都是 CI 红的产物，且都发生在 tag 之前——这次没有出现「tag 停在失败提交上」。

## 发布物

| 项 | 值 |
| --- | --- |
| 文件 | `RDM-ARM-1.2.0-universal.zip` |
| 字节 | 1 677 803 |
| SHA-256 | `82de5211758d7b7ec96f21ec26f95f30af6f009d23798799839a4b5baa2703e2` |
| 架构 | `x86_64 arm64` |
| 签名 | ad-hoc（首次打开需 `xattr -dr com.apple.quarantine`） |

产物从 **tag 所在提交**构建（`git rev-parse 1.2.0^{commit}` 与 `HEAD` 相等已核对）。

| 平台 | Release | 附件 |
| --- | --- | --- |
| GitHub | https://github.com/charsen/moo-RDM/releases/tag/1.2.0 | ✅ 1 677 803 B |
| Gitee | https://gitee.com/charsen/moo-RDM/releases/tag/1.2.0 | ✅ 1 677 803 B |

```
GitHub 下载  82de5211758d7b7ec96f21ec26f95f30af6f009d23798799839a4b5baa2703e2
Gitee  下载  82de5211758d7b7ec96f21ec26f95f30af6f009d23798799839a4b5baa2703e2
本地产物     82de5211758d7b7ec96f21ec26f95f30af6f009d23798799839a4b5baa2703e2
```

Gitee 侧自动附带源码包 `1.2.0.zip` / `1.2.0.tar.gz`，是平台行为，比对哈希时不算进来。

### 上传方式

凭据取自 `/Volumes/dev/git_tokens`（`## gitee_token` / `## github_token`），只在脚本进程内
读取，不打印、不进命令行参数。

- GitHub：`POST /repos/{owner}/{repo}/releases`（201）→
  `POST https://uploads.github.com/.../assets?name=…`，**body 为原始字节**，
  `Content-Type: application/octet-stream`
- Gitee：`GET /releases/tags/{tag}` 对不存在的 tag 返回 `200` + `null`（不是 404），
  脚本据此判断新建；`POST /releases` → `POST .../releases/{id}/attach_files`（multipart，字段 `file`）

## 遗留

- `hidden` 的真机样本仍然缺（同上）。
- 命令行 `-lm` 仍默认列全部模式，保留原行为。
- 本地工具链比 CI 新（Swift 6.4 vs 5.10）。1.1.0 已经因此白推一次；本次两个 `fix`
  是断言写错导致的红，不是编译差异——但这条纪律继续有效：**本机绿不等于 CI 绿，
  tag 只打 CI 绿过的提交。**
