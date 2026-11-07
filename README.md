# A camera

iPhone 全幅 4:3 / Apple Log 2 / 锁 24 fps 的四档录制相机。自用，纯侧载。

包标识 `link.aitimes.opengate`，二进制名仍为 `OpenGate`（改它会动 CI 打包路径），主屏显示名 **A camera**。

---

## 当前状态

**v0.2.0 — 录制骨架可用，色彩管线未接入。**

能做的：真机录出 `.mov`，四档可选，锁定精确 24.000 fps，LPCM 48 kHz / 16-bit 音轨，
开录前取一次精确定位写入元数据，曝光与白平衡可调，取景器带波形示波器。

不能做的：画面仍是系统 ISP 输出的 SDR，**不是 Apple Log 2**。Apple Log 2 需要自建 Metal 管线
（Bayer 解包 → demosaic → Apple Gamut → Log 曲线），依赖 Phase 2 探针的真机数据结构，尚未实现。

---

## 真机实测结论（iPhone 17 Pro Max / iOS 27.2）

第一轮探针已在 `iPhone18,2` 上跑通，几个关键事实与初始假设不同：

| 结论 | 实测 |
|---|---|
| 全传感器采集格式 | **存在**。`4224×3024 'btp2'`，最高 60 fps |
| `btp2` 是什么 | `kCVPixelFormatType_96VersatileBayerPacked12`，**12-bit packed Bayer**，即 ProRes RAW 的采集格式 |
| 画幅比例 | **4224/3024 = 1.397:1，不是 4:3**。真正的 4:3 是 `4032×3024` |
| HEVC 12.77MP | **通过**。会话创建成功，回读分辨率 4224×3024 未被改小，Main10 |
| ProRes HQ / LT | **通过**。会话与 `AVAssetWriter` 均接受 4224×3024 |
| Bayer 直出 | **可得**。sample buffer 携带 Bayer pattern、黑白电平、WB 倍率、Camera RGB→XYZ D65 矩阵 |

由此，「2 档稳过 + 2 档待验证」上调为：**四档技术路径全部成立，且 RAW 通路可用**。

---

## 四档

| 档 | 编码器 | 结构 | 预估写入 |
|---|---|---|---|
| 1 · HQ | ProRes 422 HQ | 10-bit 4:2:2 全 I 帧 | ≈135 MB/s |
| 2 · Plan A | HEVC Main10 | 10-bit 4:2:0 长 GOP（keyint 240） | ≈25 MB/s |
| 3 · Plan B | HEVC Main10 | 10-bit 4:2:0 全 I 帧 | ≈62 MB/s |
| 4 · LT | ProRes 422 LT | 10-bit 4:2:2 全 I 帧 | ≈95 MB/s |

体积顺序是 **HQ ＞ LT ≳ Plan B ＞ Plan A**，与档位编号不一致——长 GOP 让 Plan A 成为四档最小。

切档只在两条录制之间生效，录制中不可切：四档的编码器参数、像素格式、色彩标记都不同，
必须停录 → 重建 writer → 开新文件。采集前端不重建，省掉一次黑屏。

预估写入按 ProRes 422 HQ 约 3.54 bit/像素（由 1080p29.97 = 220 Mbps 反推）与 HEVC 目标码率折算。

---

## 关键实现约定

**帧率。** 设备侧 `activeVideoMinFrameDuration = 1/24`；写入侧每帧时间戳按
「真实经过时间 → 24 时基」折算：`CMTime(value: round(elapsed × 24), timescale: 24)`。
不用设备原始 PTS 直接写（会带 23.976 一类时基与累积误差），也不做纯累加
（真实帧率略低于标称时会与音频漂移）。

**元数据。** `AVAssetWriter.metadata` 必须在 `startWriting()` **之前**赋值——moov 头在文件开头成文，
之后再改不落盘且不报错。因此位置必须在开录前拿到，流程是
「限时取位置（默认 3 秒）→ 超时用 60 秒内缓存 → 都没有就写无位置的文件」，定位失败绝不阻塞录制。

**容器。** 四档统一 `.mov`。`.mp4` 对自定义元数据键会静默丢弃，而位置精度、档位、色彩管线
都靠自定义键记录；ProRes 本身也只能装进 QuickTime 容器。

**位置格式。** ISO 6709，Apple 官方 AVCaptureLocation 示例的写法：`%+08.4lf%+09.4lf/`，
带海拔时追加 `%+.3lf`。同时写 `com.aitimes.acamera.location` 记录水平精度、来源（实取/缓存）、
是否模糊位置授权，供后期判断这条位置能不能用来对轨。

---

## 曝光控制

AVFoundation 只提供整组的曝光模式（`locked` / `auto` / `continuousAutoExposure` / `custom`），
`custom` 下 duration 与 ISO 必须同时给定。所以「一个维度手动、另一个自动」必须软件闭环：

| 模式 | 实现 |
|---|---|
| A / A | 系统 `.continuousAutoExposure` |
| M / A | `.custom` 固定 ISO，按 `exposureTargetOffset` 闭环调快门（无级） |
| A / M | `.custom` 固定快门，按同一反馈调 ISO |
| M / M | `.custom` 两个值都固定 |

闭环用 `exposureTargetOffset`（单位 EV）作为唯一反馈量，5 Hz、阻尼 0.45、单步上限 0.6 EV。
不遍历像素统计亮度——后者每帧要扫一遍 Y 平面。

快门是连续 CMTime，不吸附 1/48、1/50 这类档位。物理上限是 `1/24`：曝光时间超过帧间隔会直接掉帧。

EV 在四种模式下都通过 `setExposureTargetBias` 生效，闭环的目标就是让 offset 收敛到 0。
**录制不锁曝光**，参数可在录制中实时调整。

---

## 白平衡

三档：自动（`.continuousAutoWhiteBalance`）/ 锁定（`.locked`）/ 手动。

手动模式下温度（2500–9500 K）与色调（-100…+100）是连续值，经 `getWhiteBalanceGains(for:)`
换算成 RGB 增益，clamp 到 `[1, maxWhiteBalanceGain]` 后用 `setWhiteBalanceModeLocked(with:)` 写入。

注意：白平衡的手动写入 API 叫 **Locked** 而不是 Custom，与曝光不对称。

---

## 波形示波器

64 列 × 128 亮度级，每列沿垂直方向等距取约 200 个采样点，单帧约 1.3 万次读取。
只读 Y 平面，不碰色度。每 4 帧产出一张图（24 fps → 6 Hz）。

绘制用 `CGImage`（8 KB 内存拷贝）而不是 SwiftUI `Canvas`——后者要逐格 fill 上万个矩形。
支持 8-bit / 10-bit × video range / full range 四种格式的归一化。

---

## 界面帧率

`Info.plist` 中 `CADisableMinimumFrameDurationOnPhone = false`：这是 iPhone 上以高于 60 Hz
渲染的开关，保持 false 即把界面封顶在 60 Hz。

界面本身也按这个前提设计：

- 回读频率 2 Hz（曝光、白平衡）
- 波形 6 Hz
- 滑块拖动只改本地草稿，松手才提交给设备，避免 60 Hz 触发 `lockForConfiguration`
- 曝光、白平衡、实时读数各自独立成子视图，参数刷新只重绘那一块

---

## 工程结构

```
OpenGate/
├── project.yml                     XcodeGen 工程定义
├── .github/workflows/build.yml     云端出未签名 IPA
└── Sources/
    ├── Info.plist
    ├── Assets.xcassets/            1024×1024 图标
    ├── App/
    │   ├── OpenGateApp.swift       根视图与页面切换
    │   ├── RecorderView.swift      录制主界面 + 曝光/白平衡面板
    │   ├── CameraPreviewView.swift 取景器 + 波形叠加
    │   └── ContentView.swift       探针页
    ├── Capture/
    │   ├── CaptureSettings.swift   四档定义 + 视频/音频输出参数
    │   ├── CaptureController.swift 会话配置：格式、24 fps、防抖、对焦
    │   ├── ExposureController.swift 四种曝光组合 + 软件闭环
    │   ├── WhiteBalanceController.swift
    │   ├── WaveformSampler.swift   Y 平面降采样 → CGImage
    │   ├── MovieRecorder.swift     writer、时间戳重建、元数据
    │   └── RecordingEngine.swift   状态机编排
    ├── Location/
    │   ├── LocationProvider.swift  一次性精确定位
    │   └── MovieMetadata.swift     ISO 6709 与自定义键
    ├── Probe/                      Phase 1 / Phase 2 硬件能力探针
    └── Support/ReportWriter.swift
```

---

## 构建

不依赖本地 Mac。推送到 GitHub 后，Actions 的 `macos-latest` runner 自动：

```
xcodegen generate
  → xcodebuild archive（CODE_SIGNING_ALLOWED=NO）
  → 打包 Payload/ 为 OpenGate.ipa
  → 上传 artifact + 覆盖 latest release
```

下载地址（滚动更新，永远指向最新）：

```
https://github.com/4gnyfgz2p7-ui/opengate/releases/download/latest/OpenGate.ipa
```

公开仓库的 macOS runner 不计费。

---

## 装机

1. Windows 装 iTunes（官网 `.exe` 版，非 Store 版）+ Apple 设备驱动
2. 用 [iloader](https://iloader.app)（v2.3.8+，已修复 anisette 503）登录 Apple ID 并导入 IPA
3. 信任开发者证书：设置 → 通用 → VPN 与设备管理
4. 开启开发者模式：设置 → 隐私与安全性 → 开发者模式 → 重启
5. 打开 App，授权相机与定位

后续自动续签用 SideStore + 回环 VPN：**首次**可借电脑，日常续签纯手机。
注意 SideStore 自身也是 7 天签名，超过 7 天不续会失去手机端全部自签能力，必须配快捷指令定时自动化。

侧载无需任何 entitlement——相机、麦克风、定位都是普通权限。

---

## 已知限制

1. **画面不是 Apple Log 2**。当前是系统 ISP 的 SDR 输出，色彩标记按 Rec.709 写。
   Metal 管线接入后改为 Apple Log 2，届时色原标记 BT.2020（Apple Gamut 无公开常量，
   存在已知偏差，需在 DaVinci 里实测确认）。
2. **HEVC 全幅未经端到端验证**。探针报告称会话成功并回读正确宽高，但尚未用真实相机帧跑完整编码。
3. **Bayer 直出通路已探测未接入**。`btp2` 在格式列表中存在，Phase 2 探针验证其帧结构与 RAW 元数据键名。
4. **色温范围是经验值**。AVFoundation 不暴露 `temperature` 的合法区间，2500–9500 K 覆盖常见场景，
   超出时由增益 clamp 兜底。
5. **预览与波形持续运行耗电**。长时间录制建议关掉波形（预览层保留，否则无法构图）。

---

## 探针报告怎么读

每项结论三级：`通过` / `注意` / `不通过`。关键几条：

- `opengate-format`：不通过 → 全幅需求本身要重估
- `hevc-ceiling`：不通过且实际输出与 4224×3024 不等 → 档 2 / 档 3 作废
- `fps-24-exact`：显示 `1001/24000` → 设备把 24 改成了 23.976
- `bayer-frame-structure`：`bytesPerRow` 不等于 6336 → 12-bit 打包方式与预期不同，解包 kernel 要改
