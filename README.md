# Macrife Player

Macrife Player 是一个面向 macOS 的专用补帧视频播放器，聚焦于本地视频播放、实时视频采集、字幕处理，以及 GPU 加速的画质提升与补帧。

项目中包含 FFmpeg 相关解封装/解码能力、Metal 渲染管线、RIFE 补帧、Anime4K 以及 MetalFX 超分等模块，目标是提供更高质量、更流畅的视频观看体验。

## 目录结构

```text
MacrifePlayer/          # 主应用代码
  App/                  # 应用入口与全局初始化
  Audio/                # 音频播放与静音读取器
  Capture/              # 屏幕/摄像头采集相关
  FFmpeg/               # FFmpeg 包装和流读取实现
  Media/                # 媒体源、轨道与会话管理
  Metal/                # Metal 相关渲染工具与后处理
  RIFE/                 # RIFE 插帧推理与调度实现
  Subtitle/             # 字幕解析与渲染
  Support/              # 通用工具、日志、视频处理辅助
  UI/                   # 播放器界面与控制逻辑
  Upscaler/             # 超分辨率相关实现
  Info.plist            # App 配置

Playback/              # 播放引擎与解码/同步核心
  App/                  # 应用级入口/委托
  Media/                # 播放媒体抽象
  UI/                   # 播放器窗口与统计面板
  ...

FFmpegShim/            # FFmpeg 桥接/封装
Frameworks/            # 第三方/系统框架目录
Resources/             # 资源文件、语言包、图片等
MacrifePlayer.xcodeproj  # Xcode 项目
Macrife Player.app/    # 生成产物（已构建应用）
```

## 功能概览

- 兼容常见本地视频格式，如 mp4、mov、mkv、avi、m4v、webm 等
- 基于 FFmpeg 的音视频解封装与解码
- 低延迟播放与音画同步控制
- 支持屏幕录制与摄像头/采集设备输入
- 字幕支持（内封字幕与外挂字幕）
- GPU 加速视频渲染
- RIFE 帧插值补帧，提升低帧率视频观看体验
- MetalFX 空间超分辨率与 Anime4K 画质增强
- 支持不同播放模式、采样状态监控与性能统计

## 技术特点

### 1. Audio/Video Playback

核心播放逻辑位于 `Playback/` 与 `MacrifePlayer/` 中，负责：

- 媒体源打开与流选择
- 视频/音频/字幕轨道管理
- 时钟同步与播放状态推进
- 帧队列与渲染循环管理

### 2. RIFE 插帧

`Playback/RIFEInterpolationEngine.swift`、`MacrifePlayer/RIFE/` 等文件实现了插帧推理流程，适合在低帧率视频中提升流畅度。该部分大量使用 Metal / CoreML / GPU 运行时，端到端覆盖了：

- 帧读取
- 模型选择
- 调度与重排
- 输出合成
- 性能统计

### 3. Metal / GPU 渲染

`MacrifePlayer/Metal/` 和 `Playback/VideoRenderView.swift` 中有完整的金属渲染管线，用于：

- YUV 到 RGB 转换
- 字幕叠加
- 画质增强后处理
- 视网膜/超分辨率输出

### 4. 采集与屏幕录制

`MacrifePlayer/Capture/` 下包含采集设备、屏幕录制、视频帧读取器等实现，可用于：

- 实时视频输入播放
- 采集卡/摄像头输入
- 屏幕内容捕获与处理

## 运行环境

- macOS
- Xcode
- Apple Silicon 或 Intel Mac（具体取决于项目构建目标）
- 如使用屏幕录制、摄像头采集等功能，需要在系统中授权相应权限

> 该项目依赖 macOS 的系统框架、Metal、AVFoundation、CoreVideo 等能力，因此它不是跨平台项目。

## 构建与运行

1. 打开 Xcode
2. 选择 `MacrifePlayer.xcodeproj`
3. 选择目标 `MacrifePlayer` 或对应的应用目标
4. 选择本机 Mac 作为运行设备
5. 点击 Run / Build

如果运行过程中出现权限问题，请检查：

- 屏幕录制权限
- 摄像头/麦克风权限
- Xcode 代码签名与证书配置

## 典型开发说明

这个仓库更接近“本地应用研究型/实验型播放器工程”，而不是一个简洁的通用开源播放器模板。它包含：

- 自定义 FFmpeg 适配层
- Metal 着色器与后处理管线
- 高性能播放/补帧调度机制
- 画质增强、超分与插帧实验代码

因此，构建和调试时，建议优先关注以下几个目录：

- `Playback/`：播放引擎核心
- `MacrifePlayer/Metal/`：渲染与 GPU 逻辑
- `MacrifePlayer/RIFE/`：补帧与模型推理
- `MacrifePlayer/Capture/`：采集设备相关

## 注意事项

- 项目中包含大量实验性质的渲染与补帧逻辑，兼容性和稳定性会受到系统版本、GPU 型号和权限配置影响。
- 某些功能依赖 Metal / CoreML / FFmpeg 的编译和运行环境，调试时需要保持工具链和系统环境一致。
- 对于无源码或未完全恢复的历史代码，文件注释中可能保留了“重建/逆向工程”说明，这属于工程实现特征，不代表最终产品已完成商用级封装。

## 许可证

本仓库目前未附带明确的开源许可证说明。如果你计划二次分发、商用或公开发布，请先确认所有依赖组件和代码授权范围。

## 说明

这是一个面向本地开发和实验研究的 macOS 视频播放器工程，适合用于：

- 学习 FFmpeg + Metal + AVFoundation 集成
- 探索实时补帧与 GPU 超分
- 研究双平台播放增强思路
- 扩展视频采集与字幕处理能力

如果你愿意，我也可以继续为这个项目补一份更偏“项目介绍型”的 README，或者进一步细化成“开发者文档 / 安装说明 / 功能说明”版本。
