# A camera

iPhone 全传感器 Open Gate、Apple Log 2、锁 24fps 四档录制的自用相机 App。

当前阶段：**能力探针**。在写录制管线之前，先用真机把关键前提验完。

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

由此，「2 档稳过 + 2 档待验证」的判断可以上调为：**四档技术路径全部成立，且 RAW 通路可用**。

## 探针测什么

Phase 1（静态能力）：

1. 全量枚举 `AVCaptureDevice.formats`，标记尺寸、像素格式、帧率范围
2. 读 `availableVideoPixelFormatTypes`，识别 Bayer 四字符码
3. `VTCopySupportedPropertyDictionaryForEncoder` 预问编码器支持性
4. 真实建 `VTCompressionSession` 并编码一帧，回读实际输出宽高
5. `AVAssetWriter` 对 ProRes / HEVC 输出设置的接受度

Phase 2（真机实测）：

6. 锁定 `1/24` 后回读 `activeVideoMinFrameDuration`，区分精确 24.000 与 23.976
7. 真开相机采 btp2 帧，读 `bytesPerRow` 验证 12-bit 打包布局（4224 宽应为 6336 字节/行）
8. 打印 sample buffer / pixel buffer 的 RAW 元数据键名
9. 统计 30 帧的实际帧率与间隔抖动

第 4 项与第 7 项是唯一能证明「没被偷偷改小」「打包格式对得上」的证据，不能靠推断。

## 工程结构

```
OpenGate/
├── project.yml                     XcodeGen 工程定义
├── .github/workflows/build.yml     云端出未签名 IPA
└── Sources/
    ├── Info.plist                  显示名 A camera
    ├── Assets.xcassets/
    │   └── AppIcon.appiconset/     1024×1024 图标
    ├── App/
    │   ├── OpenGateApp.swift
    │   └── ContentView.swift
    ├── Probe/
    │   ├── Models.swift            报告数据模型
    │   ├── DeviceProbe.swift       格式枚举 + 像素格式
    │   ├── EncoderProbe.swift      VideoToolbox + AVAssetWriter
    │   ├── LiveCaptureProbe.swift  Phase 2 真机采集实测
    │   └── ProbeEngine.swift       编排 + 结论生成
    └── Support/
        └── ReportWriter.swift      JSON / 文本报告
```

工程名与二进制名仍是 `OpenGate`，主屏显示名为 `A camera`。改二进制名会影响 CI 打包路径，暂不动。

## 构建

不依赖本地 Mac。推送到 GitHub 后，Actions 的 `macos-latest` runner 自动：

```
xcodegen generate
  → xcodebuild archive（关闭签名）
  → 打包 Payload/ 为 OpenGate.ipa
  → 上传 artifact + 发布滚动 release
```

下载地址固定：

```
https://github.com/4gnyfgz2p7-ui/opengate/releases/download/latest/OpenGate.ipa
```

公开仓库的 macOS runner 不计费。

## 装机

1. Windows 装 iTunes（官网 .exe 版，非 Store 版）+ Apple 设备驱动
2. 用 [iloader](https://iloader.app)（v2.3.8+，已修复 anisette 503）登录 Apple ID 并导入 IPA
3. 手机信任开发者证书：设置 → 通用 → VPN 与设备管理
4. 开启开发者模式：设置 → 隐私与安全性 → 开发者模式 → 重启
5. 打开 App，授权相机，运行探测，导出 JSON

后续自动续签用 SideStore + 回环 VPN：**首次**可借电脑，日常续签纯手机。注意 SideStore 自身也是 7 天签名，超过 7 天不续会失去手机端全部自签能力，必须配快捷指令定时自动化。

## 报告怎么读

每项结论三级：`通过` / `注意` / `不通过`。关键几条：

- `opengate-format`：不通过 → 全幅需求本身要重估
- `hevc-ceiling`：不通过且实际输出与 4224×3024 不等 → 档 2 / 档 3 作废
- `fps-24-exact`：显示 `1001/24000` → 设备把 24 改成了 23.976
- `bayer-frame-structure`：`bytesPerRow` 不等于 6336 → 12-bit 打包方式与预期不同，解包 kernel 要改
