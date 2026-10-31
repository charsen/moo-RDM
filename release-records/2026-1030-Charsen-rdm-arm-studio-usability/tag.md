# RDM-ARM 1.4.2 —— Studio Display 常用模式、跨屏匹配与镜像守卫

状态：**本地已合并，签名与公证完成；待 push/tag。**
`feat-rdm-usability`、`dev`、`master` 指向同一提交；`build/RDM-ARM-1.4.2-universal.dmg`
已 Developer ID 签名、Apple 公证并 staple。尚未 push 到 Gitee/GitHub，尚未打 tag。

## 起因

目标是让新接入的 Studio Display 与 BenQ PD2705U 都能稳定使用 `2304 × 1296 ⚡️ @ 60 Hz`。
Studio Display 的系统模式表原本没有这一档，通过 `/Library` 下的 `scale-resolutions`
override 补齐；随后把注意力转到 RDM-ARM 本身的可用性、性能和边界行为。

这一轮从 1.3.0 累积到 1.4.2，没有把中间版本单独发出去。

## 本轮范围

| 版本 | 内容 |
| --- | --- |
| 1.3.0 | 设置窗口按 tab 懒加载、偏好原地更新；显示配置预设（分辨率/旋转/镜像/排列/亮度）；按屏记忆启动恢复与折衷提示；能力审计修正；亮度滑杆、登录时启动、全局快捷键；菜单/动作性能优化；自定义分辨率 CLI 与菜单入口 |
| 1.3.1 | 修复 `SLSSetDisplayRotation` 在改过分辨率后静默失效：setter 成功后提交一次空显示配置；`CFBundleVersion` 与版本号拆开 |
| 1.3.2 | 暂时隐藏自定义缩放分辨率入口（实现与自检保留），记入 TODOS；CI 断言帮助里不再出现该参数 |
| 1.4.0 | Studio Display 常用组（原生 5K/默认/更多空间/更大界面/兼容）；单一刷新率时隐藏刷新率子菜单；每屏“匹配另一块显示器”；亮度 25/50/75/100% 快捷档 |
| 1.4.1 | 镜像从屏不再提供单屏分辨率/刷新率/匹配，提示先停止镜像，动作层加守卫；新增“启动时恢复模式”开关；Studio 旋转子菜单加标准支架提示 |
| 1.4.2 | `DisplayNameCache`：按显示身份持久化名称，镜像从屏不再退化成“显示器 2” |

版本与构建号：`1.4.2 (build 8)`，`build.sh` / `AppInfo.swift` / `Resources/Info.plist`
三处一致。

## 真机验证

硬件：本机 M4 Max / macOS 27.0.1，Studio Display + BenQ PD2705U。

- 1.4.1 两回合：针对性 21 项 + 完整回归 51 项，全部通过。
  - 镜像从屏无分辨率/刷新/匹配；主屏保留分辨率；旋转提示；启动恢复 off 不动作、on 生效；设置复选框读写与禁用状态。
  - 单屏切换、双屏同分辨率、镜像/停止、预设、亮度滑杆与快捷档、改分辨率后旋转、跨屏匹配只改目标、自定义分辨率校验、最终模式/排列/旋转/亮度恢复。
- 1.4.2 两回合：名称专项 10 项 + 核心回归 27 项，全部通过。
  - 在线名称写入缓存 → 镜像后从屏仍为 `BenQ PD2705U`，菜单标题一致；缓存按身份持久化。
  - 镜像守卫、单屏切换、匹配只改目标、亮度 50%、旋转与最终恢复均正常。
- 最终自检：`--selftest-timing` 74 PASS / 1 SKIP；`--selftest` 通过。
- 安装态：`/Applications/RDM-ARM.app` 为 `1.4.2 (build 8)`，两块屏均为 `2304 × 1296 ⚡️ @ 60 Hz`。

## 交付物

```
build/RDM-ARM-1.4.2-universal.dmg
arch      x86_64 arm64
size      3.6M
sha256    57577fdf3a939813a12687e8678e56b1cc11565e10df4f69d7671eb51d41fa3b
```

`spctl`：`Notarized Developer ID`。DMG 内包含 App 与「应用程序」快捷方式。

## 升级注意

- Bundle ID 保持 `com.mooeen.rdm`；1.2.1 的旧域 `io.rdmarm.RDM-ARM` 仍会在新域为空时一次性迁移。
- 自定义缩放分辨率入口自 1.3.2 起隐藏；已经写入 `/Library` 的 `scale-resolutions`
  override 不受影响，Studio Display 的 `2304 × 1296` 仍可用。
- “按屏记忆”默认开启；若不想启动时覆盖在系统设置里手改的模式，关闭
  “启动时恢复模式”即可，重插与唤醒的记忆仍保留。
- 镜像从屏跟随主屏时序；先“停止镜像”，再改单屏分辨率或做跨屏匹配。
- Studio Display 标准支架不能旋转；菜单会提示，VESA 版本仍可使用角度。

## 未做/限制

- 自定义缩放分辨率重新放出：实现保留，重放前需补管理员写入的真机验证（TODOS）。
- 预设记录主屏指定：macOS 27 没有公开/可用的私有主屏设置符号（TODOS）。
- 虚拟屏支持：`CGVirtualDisplay` + 硬件镜像成本较高，暂不纳入（TODOS）。
- Mac App Store：当前功能依赖私有 API 与 `/Library` 提权写入，不适合直接上架；
  要上架需单独的沙盒、公开 API Lite 版。
- 5K 自定义时序仍受 EDID 描述符 655.35 MHz 像素时钟上限限制。
