# A camera · UI 交接文档

> 这份文档给接手界面的 AI。目标是**不用问人就能改**：项目是什么、怎么构建、每个问题对着哪个文件哪一段、什么改法算对、什么绝对不能碰，都写在里面。
>
> 画面管线（Bayer / Metal / 编码）正由另一个会话处理，**不要动 `Sources/Pipeline/` 与 `Sources/Capture/MovieRecorder.swift`**。

---

## 1. 项目是什么

iPhone 专业录制 App，名为 **A camera**，包标识 `link.aitimes.opengate`。目标机型 iPhone 17 Pro Max（`iPhone18,2`，iOS 27.2）。

核心能力：

- **全传感器 4224×3024**（实测比例 1.397:1，不是 4:3；4032×3024 是裁切后的 4:3）
- 锁精确 24 fps（回读 `1/24`）
- 四档录制，按码率从低到高：**HEVC 长 GOP → HEVC 全 I 帧 → ProRes 422 LT → ProRes 422 HQ**
- 音频 LPCM 48 kHz / 16-bit / 2 ch
- 录制开始瞬间取一次精确定位写进文件元数据
- 规划中：Apple Log 2、LUT 导入/预览/烧录（**未实现**）

技术栈：SwiftUI + AVFoundation + Metal。工程用 **XcodeGen**（`project.yml`）生成，`.xcodeproj` 不入库。

---

## 2. 构建与交付

Windows 上没有 iOS 工具链，编译必须走 GitHub Actions 的 macOS 机器。

```powershell
cd F:\OpenGate
python tools\build.py        # 推送 → 等构建 → 下载产物到 _local，全程自动重试
```

产物落在 `F:\OpenGate\_local\OpenGate-<版本>.ipa`，用 iloader 装机（`C:\Users\amazi\AppData\Local\iloader\iloader.exe`）。

**改版本号**：`project.yml` 里 `MARKETING_VERSION`（如 `0.5.12`）与 `CURRENT_PROJECT_VERSION`（整数，+1）。不发版号的话 `build.py` 会把新包命名成旧名字。

**推送令牌**：`F:\OpenGate\.token`（GitHub PAT，需 `repo` + `workflow`，有有效期，过期要用户重新生成）。`github.com` 被墙，`api.github.com` 可通，所以 `tools/build.py` 走 API 推送。

---

## 3. 代码地图

```
F:\OpenGate\
├─ project.yml                       XcodeGen 工程定义、版本号
├─ ISSUES.md                         全量问题备忘（含画面问题，仅作背景）
├─ Sources\
│  ├─ App\
│  │  ├─ RecorderView.swift          ★ 界面主体，1069 行，本次工作的主战场
│  │  ├─ CameraPreviewView.swift     取景层封装 + WaveformView 波形绘制
│  │  └─ OpenGateApp.swift           入口 + AppDelegate 方向锁
│  ├─ Capture\
│  │  ├─ CaptureController.swift     会话配置、格式选择、锁 4224×3024
│  │  ├─ CaptureSettings.swift       QualityTier 四档定义
│  │  ├─ RecordingEngine.swift       状态机、计时、波形接线、元数据
│  │  ├─ ExposureController.swift    曝光四种组合、EV100 反算
│  │  ├─ WhiteBalanceController.swift 自动/锁定/手动
│  │  ├─ DeviceOrientationObserver.swift 方向检测（rotation.degrees）
│  │  └─ MovieRecorder.swift         ⚠ 另一个会话在改，别动
│  ├─ Pipeline\                      ⚠ 另一个会话在改，别动
│  ├─ Location\                     定位与元数据
│  ├─ Probe\                        探针页
│  └─ Support\                      崩溃记录、报告
└─ _local\                          产物 IPA
```

`RecorderView.swift` 内部结构（行号会漂，用符号名搜）：

| 符号 | 作用 |
|---|---|
| `body` | `GeometryReader` → `layoutZones(size:)` 算出三块矩形 → `ZStack` 摆放 |
| `struct Zones` | `preview` / `bar` / `controls` / `lens`（横屏镜头侧竖轨） |
| `layoutZones(size:)` | **所有布局数值都在这里**，横竖屏各一套 |
| `forceInterface(_:)` | 用 `requestGeometryUpdate` 让窗口跟着拍摄方向转 |
| `previewPane` | 取景视图，按 rect 定尺寸与位置 |
| `lensRail` | 横屏时镜头侧竖轨：时间码 + 波形 |
| `topBarPane` | 竖屏顶栏：档位 / 波形 / 方向 / 设置 |
| `standbyControls` | 待机：一行档位+按钮、一块参数面板、录制条 |
| `recordingControls` | 录制中：只有曝光条 + 停止键 |
| `ExposureStrip` | 曝光面板（第 510 行起） |
| `WhiteBalanceStrip` | 白平衡面板（第 674 行起） |
| `SettingsSheet` | 设置页（第 843 行起） |

---

## 4. 硬约束（违反即做错）

1. **画面优先**。取景是主体，任何控件都不许压在画面上。用**分区矩形**实现（`layoutZones` 返回互不重叠的 rect），不要用 `.overlay` 叠上去。
2. **取景靠近镜头模组一侧，但不紧贴**。留 12–14pt。镜头在机身背面左上角：竖拍靠上、横拍 A（`degrees == 0`）靠左、横拍 B（`degrees == 180`）靠右、倒置（270）靠下。
3. **镜头侧那条边留给波形图**。波形与时间码放同一侧（镜头侧），不放顶部。
4. **录制中只留四样**：监看画面、录制时间码、曝光条、停止键。参数、档位、设置、白平衡全部隐去。
5. **App 内不许写说明文字**。不要"按住滑块拖动…""视场角更大…"这类解释。说明只放对话里。唯一的例外是**失败原因**（如"画面未能写入：…"），因为那是运行状态不是说明书。
6. **波形图上不许有文字**。"过曝 / 死黑 / 正常"这类标签全部禁止，只用上下两条削波指示线的颜色表达。
7. **档位按码率从低到高排序，名称用编码名**（`HEVC 长 GOP` / `HEVC 全 I 帧` / `ProRes 422 LT` / `ProRes 422 HQ`），不要 Plan A/B 这类内部代号。
8. **界面上不出现 4032 那一档**。用户只要全幅，降级是内部兜底，不该在 UI 上露出来。
9. **状态栏常隐**（`.statusBarHidden(true)`）。录制中隐时间码重复。
10. **不加多余的防呆提示**。用户明确讨厌"你选了 X，确定吗"这种。用选项排布引导（默认项在前、危险项在后），不要加文字。

---

## 5. 问题清单

状态：`待办` = 没改；`半修` = 改过但实测仍不对；`已修` = 已确认。

### A. 方向与旋转（用户原话：「界面旋转全是问题」「UI没转」）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| A1 | 横拍时只有画面转了，控件还是竖的 | 整套 UI 跟着拍摄方向一起转 | `forceInterface(_:)` + `Info.plist` 方向声明 + `UIApplicationSceneManifest` | 已改待实测：真根因 = 180/270 映射写反 + 无运行期方向锁，见 §5b |
| A2 | 竖着拿手机时看到一屏**横躺**的控件 | 界面永远正着；只有取景框随画幅变形 | 曾经整层 `rotationEffect` 转过，现已删；确认没有残留 | 已改待实测：横躺真因是旋转打架后根视图 transform 卡死（0802 截图，EXIF=1），加方向锁后不再打架 |
| A3 | 取景被转了两次，压成中间一条 | 只转一层 | 同上 | 已改待实测：同 A2，锁方向后两个旋转源消失 |
| A4 | 按"切换方向"按钮后画面立刻变黑、无法录制 | 切方向不重建预览 UIView，会话不中断 | `previewPane` 的 `CameraPreviewView` 身份要稳定；`layoutZones` 只改 frame | 半修：`CameraPreviewView` 已有重新入窗再挂 session 的兜底；方向锁减少窗口抖动次数 |
| A5 | 四个方向（竖/横A/横B/倒置）表现不一致 | 四个方向都要正确，包括黑边与控件落点 | `layoutZones` 的 `landscape` 分支只区分横竖，没区分 0/180 | 已改待实测：映射修正（180→landscapeLeft、270→portraitUpsideDown），270° 竖屏整组垂直镜像 |

**A 组最重要**。用户明确说"每个方向都有问题"。0.5.14 的做法（详见 §5b）：

- 运行期支持方向恒等于拍摄方向（`AppDelegate.supportedMask`），物理旋转不再自转；
- `degrees`、`videoRotationAngle`、窗口 interface orientation 三个量严格同轴；
- 窗口未转到位的一瞬只画黑底（`inSync` 判断），不渲染矛盾布局；
- 取景贴镜头侧 12pt（横拍贴轨、竖拍上贴），270° 顶栏随镜头侧落到窗口底部。

### B. 画面位置与裁剪（用户原话：「画面没1侧顶满，镜头方向空间不够」「是靠近不是紧贴」）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| B1 | 取景短边没顶满，两侧留黑 | 短边方向贴满，黑边只出现在几何上必然的那一侧 | `layoutZones` 里 `preview` 的计算 | 半修 |
| B2 | 镜头侧空间不够，波形挤 | 镜头侧要留出足够宽给波形栏 | 横屏 `railWidth: 104`、`controlsWidth: min(300, w*0.30)` 需要重算 | 待办 |
| B3 | 取景没靠近镜头侧 | 靠近但不紧贴（12–14pt） | `layoutZones` 的定位逻辑 | 已改待实测：横拍贴轨 12pt、竖拍上贴、270° 随镜头侧 |
| B4 | 用了 `resizeAspectFill` 裁切 | 只允许 `resizeAspect`（等比完整显示，可留黑边），不许裁切 | `CameraPreviewView` 的 `videoGravity` | 已修：`resizeAspect` |

画幅比例不要写死，用 `engine.captureAspect`（真实 4224:3024 = 1.397）。

### C. 控件遮挡与分区（用户原话：「参数滑块等不能遮挡到画面」「大的黑边给参数调节滑块另一边塞波形图」）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| C1 | 曝光/白平衡滑块压住画面 | 滑块永远在画面外的黑区 | `layoutZones` 的 `controls` 矩形 | 半修 |
| C2 | 顶栏压住画面顶部 | 顶栏独立成行，不与画面重叠 | `topBarPane` + `bar` 矩形 | 半修 |
| C3 | 横屏时控件区太窄，内容挤成一列 | 横屏控件区宽度按内容需要给（320–360），不要 `w*0.30` | `layoutZones` 横屏分支 | 待办 |
| C4 | **横屏时录制时间和波形在上面** | 放**镜头一侧的竖轨**（横拍 A 在左，横拍 B 在右） | `lensRail` | 已改待实测：轨已实现，此前被 180/270 映射错乱掩盖（0801 实为倒置档），映射修正后四方向各归其位 |

### 5b、0.5.14 改动（方向重做，本机模拟验证后落地）

只动了 `Sources/App/OpenGateApp.swift` 与 `Sources/App/RecorderView.swift`，管线与录制未碰：

1. **方向锁**：`OpenGateApp` 挂 `AppDelegate`（`UIApplicationDelegateAdaptor`），
   `application(_:supportedInterfaceOrientationsFor:)` 恒返回 `AppDelegate.supportedMask`。
   `forceInterface` 先写 mask 再 `requestGeometryUpdate`——运行期永远只允许当前拍摄方向，
   物理转机身不再自转，两个旋转源打架（0802 整层横躺的根因）消除。
2. **映射修正**（旧版 180/270 写反）：
   `0→landscapeRight、90→portrait、180→landscapeLeft、270→portraitUpsideDown`，
   与 `AVCaptureConnection.videoRotationAngle` 常量严格同轴，预览层无需补角。
3. **过渡保护**：`body` 里 `inSync = (窗口横竖 == degrees 横竖)`，不同步时只画黑底，
   不渲染矛盾布局（0801「横屏竖长条预览」的一瞬定格不再出现）。
4. **贴镜头侧**：横拍取景贴轨 12pt、参数侧 10pt；竖拍预览上贴；
   270° 顶栏/控件/取景整组 `flipY`（倒置握持时镜头在窗口底部，波形条跟着过去）。
5. **本机验证**：`og-layout-sim/`（工作区）与 `layoutZones` 同构的 Python 模拟器——
   旧逻辑复现 0801（倒置→横窗竖预览）与 180（竖窗横预览）两个故障态；
   新逻辑 4 方向 × 待机/录制 6 场景全过：互不重叠、预览形状与窗口方向一致、
   轨在镜头侧、贴边 12pt。模拟器复现值与实机截图实测差 <3%。
6. 版本 0.5.13/11 → **0.5.14/12**（0.5.12/13 被中间会话占用但无落地产物）。
7. **旋转监测 + 黑屏逃生门**（用户新报「点旋转按钮瞬间黑屏无响应」后补）：
   `Sources/App/RotationMonitor.swift` 记整条链（按键→锁面→申请→回执→窗口尺寸/安全区/
   实际 px 分辨率→预览连接），Timer 看门狗测主线程停顿，落盘 `rotation-log.txt`，
   设置页新增「方向监测」板块（导出/复制）。几何 2.5s 未生效自动补发，3.7s 仍不齐
   `forceShow` 放行界面——死黑屏从此有上限。
   判断口诀：时间线里「回执成功但窗口没跟上」= 几何被系统延迟/拒绝；
   「主线程停顿 x s」= 真无响应；「预览连接不存在/角度被改」= 画面黑但 UI 活着。
8. 状态：**待装机实测**。装机后按 §8 清单逐项打勾，重点：四方向各截一张、
   连续切两次方向画面不黑、倒置档顶栏在镜头侧；再按一次方向键看
   「设置 → 方向监测」时间线是否闭环（申请 → 回执 → 窗口跟上 ≤ 0.5 s）。

### D. 控件设计（用户原话见 §6）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| D1 | 曝光条顶部常驻 `ISO / 快门 / +EV` 读数 | **删掉**。只有"手调模块"是唯一实际曝光值 | `ExposureStrip` | 已修 |
| D2 | `+0.9 EV` 怎么算都不准 | 那个值是 `exposureTargetOffset`（相对测光目标的偏差），不是曝光值 | 同上 | 已修：改用全手动时 `EV100 = log2(N²/t) − log2(ISO/100)` |
| D3 | 非全手动模式给了 EV 滑块 | 四种组合：ISO 自动/手动 × 快门 自动/手动。**只有"一维手动一维自动"时**给统一 EV 滑块；全手动时给两个独立滑块，不给 EV | `ExposureStrip` 的模式切换 | 半修 |
| D4 | 半自动时改一维，另一维不补偿 | 改一维时另一维**反比补偿**，保持总曝光不变 | `ExposureController` | 待办 |
| D5 | 全手动时还显示 EV | 全手动隐藏 EV 滑块，只显示反算出的 EV100 数值 | `ExposureStrip` | 半修 |
| D6 | 白平衡点"手动"只选中不弹滑块 | **第二次**点"手动"才弹滑块（这是设计，不是 bug，别"修"掉） | `WhiteBalanceStrip` | 已修 |
| D7 | 波形图只用来看曝光 | 登顶=过曝救不回（红），触底=死黑（蓝），中间正常。不要画文字 | `WaveformView` | 已修 |
| D8 | 波形图曾撑成 104×208 长条压住状态栏 | 图片必须 `Color.clear` 占位 + `overlay` + `clipped()`，或直接 `resizable().scaledToFill().clipped()` | `WaveformView` | 已修 |
| D9 | 录制中没有时长显示 | 录制中顶栏（横屏在竖轨）显示红点 + `mm:ss` | `recordingTimecode`、`lensRail` | 已修 |
| D10 | 停止后时间码不清零 | 收尾时 `elapsed = 0` | `RecordingEngine.finish` | 已修 |

### E. 统一性与缩放（用户原话：「设计不统一、缩放问题全要改」）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| E1 | 曝光、白平衡各画一块浮层，圆角与内边距不一致 | 合并成**一块**参数面板，统一圆角 16、内边距 12/9 | `standbyControls` + `ExposureStrip(embedded:)` / `WhiteBalanceStrip(embedded:)` | 半修 |
| E2 | 不同机型/字号下按钮大小乱 | 关键尺寸给上下限：录制键 64pt（内圆 52）、波形 104×40、档位 chip 高 28–32 | `recordBar`、`waveform`、`statusChip` | 半修 |
| E3 | 小屏（SE 尺寸）内容溢出 | 控件区内容必须能滚动（`ScrollView` + `scrollBounceBehavior(.basedOnSize)`），且滚动区不与画面重叠 | `controlsPane` | 半修 |
| E4 | 安全区处理不一致 | 统一读 `windowInsets`（横屏时灵动岛在侧边，不能只给左右固定 12pt） | `windowInsets` | 半修 |

### F. 性能（用户原话：「界面尽可能省性能」「界面锁最高60Hz」）

| # | 现象 | 期望 | 位置 | 状态 |
|---|---|---|---|---|
| F1 | 界面以 120Hz 刷新 | 锁最高 60Hz | 用 `CADisplayLink`/`UIScreen.maximumFramesPerSecond` 或在 `Info.plist` 加 `CADisableMinimumFrameDurationOnPhone = false`（已有） | 半修 |
| F2 | 波形图每帧都触发主线程刷新 | 降采样到 3–4 Hz，只在产出新图时回主线程 | `WaveformSampler` 的 `decimation` | 已修 |
| F3 | 录制中仍有大量 `@Published` 变动触发重绘 | 录制中减少非必需的状态更新 | `RecordingEngine` 的 tick | 待办 |

---

## 6. 用户原话（判断标准，别自行演绎）

按时间顺序，直接引用：

1. 「界面尽可能省性能」「界面锁最高60Hz，可手调白平衡，有波形图」
2. 「注意设备方向问题…波形图可再降采样」
3. 「注意横着时拍的是不是可以同步横过来…直接给用户手动切换方向的按键」
4. 「存储限制解开 切横竖时整个UI没变…曝光在非全手动模式下是统一给EV调节滑块…采集就绪不应放在最上面…拍摄档位由码率低到高排序 名称为其编码名称而不是怪的什么PlanA…简化拍摄界面UI」
5. 「注意拍摄界面简洁性」
6. 「在开始录制时仅保留关键监事与曝光调节功能和上方录制时间，参数显示什么的都不要」
7. 「不止曝光条是曝光控制的一系列还有要显示到当前ISO与快门」→ 后来被第 12 条推翻
8. 「波形图我只用来看曝光…波形图的顶改为log拍出来完全过曝救不回来的」「暗部死黑也是同理」
9. 「不是那个铺满而是高度或宽铺满就好，裁切的那个删掉」
10. 「横屏只转了画面但其他完全没转…预览画面都向镜头模组方向移…大的黑边给参数调节滑块另一边塞波形图，白平衡点到手动时应再次点击"手动"后弹出」
11. 「注意预览总要靠近摄像头模一侧」「是靠近不是紧贴，另一侧就是镜头那侧要留给波形图」
12. 「参数滑块等不能遮挡到画面」「下方ISO和快门后的曝光参数删掉只有手调模块是唯一实际曝光值或者全手动时才显示估算实时曝光值，现在估曝光算法不准」
13. 「画面没1侧顶满，镜头方向空间不够，按切换横竖屏的按钮立刻画面变黑无法录制」
14. 「UI没转，上方不知道什么东西，录完视频左下角录制时间未清零」
15. 「横屏时录制时间和波形图说过要放镜头一侧而不是上面的，重改横向的UI，把那个不是全幅的删掉，波形图上"死黑"字删掉都说过不要这些说明会影响观看」
16. 「不许在app上装说明浪费位置，在对话简单说就好」
17. 「界面旋转全是问题」
18. 「每个方向都有问题包括黑边 UI阻挡、设计不统一、缩放问题全要改」
19. 「开录没有录制时间」

---

## 7. 已确认的事实（别再重复验证）

- 真全幅 **4224×3024**，像素格式 `btp2`，`bytesPerRow = 6336`（无行填充）
- 帧率回读 `1/24` 精确；`commitConfiguration()` 与 `startRunning()` 都会重置帧时长，两处之后都要重钉
- 档位标识：`hevc-long-gop` / `hevc-all-intra` / `prores-422-lt` / `prores-422-hq`
- 元数据写在 `AVAssetWriter.metadata`，**必须在 `startWriting()` 之前**，否则不落盘且不报错
- `UIApplicationSceneManifest` 必须在 `Info.plist` 里，否则窗口不跟设备转（这是"只有画面转"的根因）
- 波形图 `CGImage` 是 48×96 的竖图，直接放进 `ZStack` 会被按比例撑成大长条
- 本机是 iPhone 17 Pro Max，灵动岛在竖屏顶部 / 横屏一侧

---

## 8. 交付检查清单

改完自检，全部通过才算完成：

- [ ] 四个方向（竖 / 横拍 A `0` / 横拍 B `180` / 倒置 `270`）各截一张图，控件与画面都不重叠
- [ ] 切方向两次以上，画面不黑、能开录
- [ ] 竖拍：取景左右贴满，上下留黑给顶栏与控件
- [ ] 横拍：波形与时间码在镜头侧竖轨，参数面板在另一侧，画面居中不裁切
- [ ] 录制中屏幕上只剩：画面、时间码、曝光条、停止键
- [ ] 界面里搜不到"按住""说明""提示""视场角更大""过曝""死黑"这类字
- [ ] 波形图尺寸稳定在 104×40，不压状态栏
- [ ] 档位菜单四项按码率升序，名称是编码名
- [ ] 白平衡"手动"点两次才出滑块
- [ ] 全手动模式下没有 EV 滑块，只有一个 EV100 读数
- [ ] 停止录制后时间码归零
- [ ] `python tools\build.py` 能出包，`_local` 里有新版本 IPA

---

## 9. 相关素材

截图（HEIC，NAS）：`Z:\手机素材\IMG_0758.HEIC`、`IMG_0761.heic`、`IMG_0775.HEIC` ~ `IMG_0779.HEIC`、`IMG_0780.HEIC` ~ `IMG_0785.HEIC`

用户随手画的标注（黄线标"垃圾"）：`Z:\手机素材\IMG_0752.heic`

录制成片（用来核对时间码、方向标记）：`Z:\手机素材\A_20261107_*.mov`

> 若 `Z:` 盘符不可用，直接走 UNC：`\\Z4pro-y2s9\团队文件-极空间影像\手机素材\`
