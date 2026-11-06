# OpenGate

iPhone 全传感器 4:3、Apple Log 2、锁 24fps 四档录制的自用相机 App。

当前阶段：**能力探针**（Probe）。在写任何录制管线之前，先在真机上回答六个待验证点，避免整条工程建立在错误前提上。

## 为什么先做探针

任务书把「四档」的核心不确定性收敛到两个问题：

1. 4224×3024 的 **视频采集格式** 对第三方 App 是否可见（Apple 只在 Final Cut Camera 里开放了 Open Gate）。
2. 硬件 HEVC 编码器吃到 12.77 MP 时，是接受、拒建，还是**静默改小**。

第三个问题是 Bayer：`AVCaptureVideoDataOutput` 是否暴露 Bayer 像素格式，决定前端是「真 RAW 直出」还是「10-bit YUV 起步」。

这三条不验证就写管线，失败点会出现在几千行代码之后，而且是静默失败。

## 探针测什么

| 编号 | 项目 | 判决依据 |
| --- | --- | --- |
| 1 | 格式枚举 | `AVCaptureDevice.formats` 全量导出，标记 4224×3024 / 4:3 / 视频可用 / 支持 24fps |
| 2 | 像素格式 | 配置会话后读 `availableVideoPixelFormatTypes`，筛 Bayer 四字符码 |
| 3 | HEVC 天花板 | `VTCopySupportedPropertyDictionaryForEncoder` + 真实建会话 |
| 4 | 静默改尺寸 | 真实编码一帧，从输出 `CMFormatDescription` 回读实际宽高 |
| 5 | ProRes | `kCMVideoCodecType_AppleProRes422HQ/LT` 会话 + `AVAssetWriter` 接受度 |
| 6 | 环境 | 热状态、低电量、可用空间 |

第 4 项是唯一能证明「有没有被偷偷改小」的证据，不能靠会话创建成功来推断。

## 工程结构

```
OpenGate/
├── project.yml                     XcodeGen 工程定义
├── .github/workflows/build.yml     云端出未签名 IPA
└── Sources/
    ├── Info.plist
    ├── App/
    │   ├── OpenGateApp.swift
    │   └── ContentView.swift
    ├── Probe/
    │   ├── Models.swift            报告数据模型
    │   ├── DeviceProbe.swift       格式枚举 + 像素格式
    │   ├── EncoderProbe.swift      VideoToolbox + AVAssetWriter
    │   └── ProbeEngine.swift       编排 + 结论生成
    └── Support/
        └── ReportWriter.swift      JSON / 文本报告
```

## 构建

不依赖本地 Mac。推送到 GitHub 后，Actions 的 `macos-latest` runner 自动：

```
xcodegen generate
  → xcodebuild archive（关闭签名）
  → 打包 Payload/ 为 OpenGate.ipa
  → 上传 artifact + 发布滚动 release
```

下载地址固定为：

```
https://github.com/<账号>/<仓库>/releases/download/latest/OpenGate.ipa
```

公开仓库的 macOS runner 不计费；私有仓库按 10 倍分钟计，单次构建约 5–8 分钟。

## 装机

1. iPhone 安装 SideStore，首次配对需一台装了 Apple 设备的 Windows 电脑（一次性）。
2. 用免费 Apple ID 签名上述 IPA。
3. 开启「开发者模式」。
4. 打开 App，授权相机，点「运行探测」。
5. 点「导出 JSON 报告」，把文件发回来做判定。

## 报告怎么读

每项结论三级：`通过` / `注意` / `不通过`。

关键看两条：

- `opengate-format`：不通过 → 全幅需求本身要重估，四档讨论失去意义。
- `hevc-ceiling`：不通过且 `实际输出` 与 4224×3024 不等 → 档 2 / 档 3 不可用，退回两档 ProRes。

`bayer-video` 为「注意」不致命：前端改成 10-bit YUV 仍可完成 Apple Log 2 管线，只是失去 RAW 元数据的还原余量。
