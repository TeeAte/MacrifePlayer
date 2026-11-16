# 采集低延迟与补帧验证（2026-11-16）

保留 AI 补帧，减少等待旧画面的时间。采集面板中选择「极限电竞」可使用最小队列预算；「平衡抗抖动」多保留少量余量。当前版本按用户选择提供手动「主机30FPS」模式：60FPS采集，固定隔帧取样，再用AI补到60FPS；移除了自动图像识别。真正60FPS内容选择「原始输入」。

## 实现

- 采集回调只收帧、解析元数据，并在手动主机30模式下按PTS网格固定隔帧取样，再投递到有界队列；转换与推理在独立线程执行。
- 极限模式：采集待处理和 AI 输入各最多 1 帧，最多 2 对在途；平衡模式分别为 2 帧和 3 对。
- 已完成结果按整对输出的数量限制缓冲，保留中间插帧的播放间距。过载后丢弃旧输入，断流恢复不补算大段历史画面。
- 实时补帧使用独立播放锚点，避免普通回放的 150–600ms 迟到容差与时钟回拨累积延迟。
- 固定目标网格复用上一对已输出的源帧，避免再次执行 NV12 往返转换；源帧和插值帧仍保持一致的色彩处理。
- 显示采用双 drawable、非阻塞 GPU 在途上限和屏幕刷新率拉帧；GPU 完成前保留源像素缓冲和 CVMetalTexture 引用。
- 固定目标帧率始终按目标时间网格输出；修复原生 60→60 被当成 2X、30→120 被当成 2X 的问题。网格末端拷贝当前帧，避免多延迟一个源帧。
- 性能面板新增「应用内画面滞后」及采集、AI 输入、在途任务读数。该估计截止到显示取帧，不含 HDMI/USB、采集卡内部处理、GPU 展示和屏幕扫描。

## 模型比较

设备为 Apple M1 Pro。用户停止游戏后重新测量，20 次预热后样本，每次合成一张中间帧；仅作本机当前运行方式的比较。

| 方案 | 输入与推理条件 | 均值 | P95 |
|---|---|---:|---:|
| 现有 RIFE 4.25 Lite | 1080p NV12 源，576p 光流，单实例完整 `runChain` | 44.58 ms | 46.72 ms |
| 现有 RIFE 4.25 | 同上 | 44.05 ms | 47.69 ms |
| 现有 RIFE 4.26 | 同上 | 42.39 ms | 46.89 ms |
| Apple Low Latency Frame Interpolation | 720p NV12 源，单张中间帧 | 5.53 ms | 5.58 ms |
| Apple Low Latency Frame Interpolation | 1080p NV12 源，单张中间帧 | 113.57 ms | 116.45 ms |

这些值不包含采集与显示，也不是同分辨率、同画质的跨模型排名。RIFE 数据使用现有生产推理代码、六张循环移动图案输入；Apple 数据使用合成移动图案。实际游戏的质量、运动伪影和持续负载需要另外检查。

第一轮中 Lite 没有显示速度优势，故未自动替换现有模型。当时 Apple 接口通过支持检测，720p 值得继续评估，1080p 实测不适合低延迟。第二轮已接入下述 720p 中间帧方案。该低延迟配置需要 macOS 26 或更高版本，并应做运行时支持检测和后台预热。

来源：[Practical-RIFE 官方模型说明](https://github.com/hzwer/Practical-RIFE#trained-model)、[Apple 实时视频效果介绍](https://developer.apple.com/videos/play/wwdc2025/300/)、[Apple 低延迟插帧配置](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration)。

## 回归与复测

运行 `sh Tests/run-capture-latency-tests.sh`。第一轮 9 项回归覆盖队列容量变化、过载保鲜、阻塞唤醒、关闭重开、插值帧节奏、卡顿恢复、在途预算、固定目标帧率，以及启动偏好值误开文件。

Release 构建会按项目现有脚本更新仓库根目录的 `Macrife Player.app` 并进行本地签名。

停止游戏后的最终 USB3 Video 实测（极限模式，以下为诊断时刻的采样值）：

| 输入 / 目标 | 实测显示 FPS | 应用内画面滞后 | AI 在途 |
|---|---:|---:|---:|
| 1080p60 / 60 | 59.94 | 8.5 ms | 0 对：输入已经达到目标 |
| 1080p30 / 60，关闭静帧跳过以强制推理 | 44.93 | 79.3 ms | 2 对 |

AI 路径确实生成了中间帧，队列未出现持续增长，两轮测试均正常退出。30→60 的强制推理测试尚未稳定达到 60 FPS，仍受模型与 GPU/ANE 处理能力限制，不能把「目标 60 FPS」当成已达成的输出帧率。上述短测不代表游戏全过程的延迟分布或输入到屏幕的端到端延迟。

带 `fps60`、`v426`、`NO` 偏好参数的启动回归也已实测：`currentURL: nil`，无文件打开错误，并按时正常退出。9 项回归、Release 构建及 `codesign --verify --deep --strict` 通过。

真实采集测试使用 USB3 Video / UltraSemi 和自动匹配的 USB3 Digital Audio；以下偏好值仅通过启动参数临时覆盖。AppKit 投递的这些偏好值会被过滤，避免误把 `fps60`、`v426`、`NO` 当视频文件。

```sh
# 1080p30 → 60，强制运行网络以验证 AI 路径，运行约 14 秒后正常退出。
'./Macrife Player.app/Contents/MacOS/Macrife Player' \
  --capture-go --capture-fps=30 --capture-hold=12 --dump-delay=0.8 --dump-exit \
  -macrife.rifeRateMode fps60 -macrife.rifeModel v426 -macrife.rifeStaticFrameSkip NO

# 原生 1080p60 → 60，验证不发生多余的 2X 推理。
'./Macrife Player.app/Contents/MacOS/Macrife Player' \
  --capture-go --capture-fps=60 --capture-hold=6 --dump-delay=0.8 --dump-exit \
  -macrife.rifeRateMode fps60 -macrife.rifeModel v426
```


## 第二轮：Apple 低延迟模式与 Macrife 参考

用户选择优先帧率与跟手感，接受 AI 中间帧细节可能偏软。模型配置面板新增 **Apple 低延迟 (720p AI · 原帧保真)**，用于 2X 插帧：

- 原始 1080p 帧直接保留，同一 CVPixelBuffer 原样输出；中间帧在最多 1280×720 生成后恢复源尺寸。
- NV12 两平面在 Metal 直接缩放。缩小、`VTFrameProcessor.process(with:parameters:)` 和放大合入一个 command buffer，只等待一次；缓冲与 CVMetalTexture 引用一直保留至 GPU 完成。
- 以最新采集时轴和实际处理均耗安排显示，消除启动预热留下的固定延迟。第一张 AI 帧也建立正确锚点，避免被原帧的零等待时钟直接吞掉。
- 120Hz 显示循环继续及时取帧；没有新画面时保留上一张 drawable，避免重复绘制旧画面。窗口缩放与设置变动仍触发重绘。
- 非 2X 帧率、HDR 或不支持的系统/格式回退现有 RIFE。Apple 不适用的 RIFE 调度控件在面板中禁用，状态区显示真实后端。
- 延迟增加最近 240 张显示取帧样本的 P50/P95；FPS 使用约一秒计数窗口和单调时钟，避免额外诊断刷新把 60fps 读成 40/70fps。

### 实测

M1 Pro，USB3 Video，1920×1080、30fps 真实采集，目标 60fps，极限模式。25 秒持续测试结果：

| 指标 | 结果 |
|---|---:|
| 全程平均显示取帧率（含启动） | 58.67 fps |
| 已显示帧 | 1473 |
| 真正生成的 AI 中间帧 | 751 |
| 最近 240 帧应用内滞后 P50 | 35.3 ms |
| 最近 240 帧应用内滞后 P95 | 41.9 ms |
| 最后诊断时刻的应用内滞后 | 33.5 ms |
| 应用内每对帧处理均耗 | 16.9 ms |

上述延迟截至显示取帧，不含采集卡、HDMI/USB、GPU 展示与屏幕扫描。短测平均接近 60fps，不代表在所有 GPU 负载和游戏场景下恒定 60fps。独立合成图像测试中，缩小＋AI＋放大全链路平均 **7.94 ms**、P95 **9.66 ms**；独立测试与实际播放竞争 GPU 的条件不同。

### 参考 Macrife

找到的工程是本机 `Dev/Macrife`。参考 `Sources/Macrife/Pipeline/RIFEEngine.swift` 的双帧 `preparePair` / `makeRGBInputs(from:and:)`：播放器现有 RIFE 也把两个输入的转换合并提交，并在 GPU 完成前保留纹理引用。没有直接采用离线转码的大在途窗口。

相同输入下，合并前后输出的 **3,110,400 个 NV12 有效字节完全一致**（MAE=0、最大误差=0）。该改动的单实例提速很小，主要收益来自 Apple 模式与实时播放调度，不能把离线吞吐量当作采集延迟。

### 验证与使用

- `sh Tests/run-capture-latency-tests.sh`：第二轮共 **12 项**回归。
- `sh Tests/run-apple-interpolation-tests.sh`：实际调用系统 AI，检查中间帧内容、1080p 尺寸、时间戳、34 张 AI 输出及原始帧对象保真。
- Release 构建和本地代码签名校验通过。
- 收尾复测原生 1080p60：显示采样 60.23fps、应用内滞后 P50 3.0ms / P95 7.5ms，未做多余 AI 推理；采集卡已恢复为 60FPS。

新模式测试入口：

```sh
'./Macrife Player.app/Contents/MacOS/Macrife Player' \
  --capture-go --capture-fps=30 --capture-hold=25 --dump-delay=0.8 --dump-exit \
  -macrife.rifeRateMode fps60 -macrife.rifeModel appleLowLatency
```

以上30FPS采集数据保留作历史对照；当前使用下述60FPS采集的手动主机30模式。


## 第三轮：手动主机30FPS／60FPS采集

按用户最终要求取消自动识别，采集配置第5项改为「主机30FPS模式」，仅保留两个选项：

- **原始输入（不抽帧）**：按实际采集帧率路由。
- **主机30FPS（60FPS采集 · AI补到60FPS）**：保持设备60FPS，立即从第一张输入开始固定隔帧取样，不做图像比较、检测预热或重复帧确认。启动时选择设备真实上报的60Hz档位，AI目标设为60FPS；macOS26及以上选择Apple低延迟后端，失败仍走既有RIFE回退。

取样使用采集PTS相对于首帧的奇偶网格，漏一个回调不会反转取样相位。重复槽位在进入待处理队列前丢弃，不会在GPU繁忙时把较早一拍的原帧替换为同一画面的晚一拍。该模式由用户保证主机运行于30FPS/60Hz的2:2输出；主机变成60FPS时应手动切回原始输入。固定相位不判断哪张图像是重复，因此不声称每次启动都选中HDMI重复对中较早的一张。

内容帧率随每个排队输入传到处理线程，避免切换模式时使用另一张帧的节奏。切换和断流只清除系统AI的上一帧引用，保留已预热模型及计数。

### 验证

- `sh Tests/run-capture-latency-tests.sh`：16项，新增立即启动、59.94/60Hz抖动、漏帧保相位、开关/断流恢复、重复帧不挤掉原帧。
- `sh Tests/run-apple-interpolation-tests.sh`：真实系统AI收到1080p60的A,A,B,B合成输入，35张源帧加34张AI帧按1/60秒连续输出，原始像素缓冲保持对象一致；清理帧对历史后不会跨模式插值。独立全链路均耗6.88ms、P95 7.73ms，仅代表此次独立合成测试。
- Release构建及本地签名校验通过。

USB3 Video真实采集25秒，1920×1080、设备60FPS、手动主机30模式、Apple720p中间帧、极限延迟：

| 指标 | 本轮结果 |
|---|---:|
| 全程平均显示取帧率（含启动） | 57.77 fps |
| 最后约一秒显示取帧率 | 57.52 fps |
| 已显示帧 | 1452 |
| 已生成AI中间帧 | 748 |
| 入口固定跳过槽位 | 753 |
| 最近240帧应用内滞后P50 | 35.9 ms |
| 最近240帧应用内滞后P95 | 43.7 ms |
| 应用内每对帧处理均耗 | 17.0 ms |

设备和连接读回均为60FPS，处理队列在采样时为空，没有改成30FPS采集。该测试验证手动路径及持续吞吐；未测量手柄到屏幕的端到端延迟，也未通过图像识别确认当时主机内容帧率。不能据此声称比上一轮30FPS采集降低了多少硬件延迟。

使用：采集面板选择1080p NV12，「主机30FPS」模式，延迟选极限。启动时自动选择60FPS采集并开启上述AI配置。

## 静止文字闪烁修复

原始1080p与720p生成后放大的中间帧交替显示时，小字/细线清晰度变化会造成闪烁。在实际系统AI合成的静止单像素笔画样本中复现，修复前亮度MAE为30.777/255。

在原有Metal放大阶段融合静止区域保护：比较相邻两张1080p原帧的3×3邻域亮度和色度，仅在一致区域复用当前原帧的全分辨率像素，变化区域继续保留AI结果，阈值附近平滑混合。沿用同一个command buffer及一次GPU等待，不增加帧缓冲；原始帧对象保持不变。NV12视频/全范围分别处理，合成输出均保持限制范围，避免黑位或彩色文字的范围切换。打包422回退仍使用原来的普通缩放路径，当前采集卡默认NV12走完整保护。

真实AI测试新增静止细字、彩色高频细线、全范围转换，以及运动区域不能被整帧复制替代的检查。限制范围静止细字MAE为0.000/255，全范围转换后为0.449/255（8位量化）；彩色像素误差不超过1。运动区域仍与当前原帧明显不同，AI输出数量、时间戳与1080p原帧保真回归均通过。


## 第二次文字修复：透明HUD上的位移/重影

用户反馈第一版仍然左右抖动、重影。第一版的合成用例覆盖完全静止的文字，未覆盖游戏HUD背景和抗锯齿变化。读取USB3 Video的16张实际游戏帧（约0.5秒，保持原规格），对比原始帧与真实AI输出，任务、道具和操作提示文字在原帧位置稳定，在AI帧中发生明显形变。3×3邻域中的背景像素变化会让原有静止保护失效。

新增屏幕边缘HUD的笔画/轮廓保护：

- 在相邻1080p原帧中匹配同位置的亮/暗细笔画，不再要求笔画旁的背景全部静止。
- 半分辨率遮罩覆盖每个2×2原像素，并向外扩展约6像素，保护抗锯齿、阴影及AI偏移产生的重影。
- 遮罩短暂衰减，避免保护随噪声每帧开关；复用的是当前原帧，不冻结旧文字。
- 中央视野继续AI运动插值；中心静止画面仍沿用原有静止像素保护。该增强主要针对屏幕边缘HUD，不保证消除中心移动姓名牌等所有模型伪影。
- 缩小、AI、遮罩和放大仍在同一个command buffer中执行，一次等待，不增加源帧前视或帧队列。换模式和断流清除遮罩历史。
- 原生路径实际启用后，处理状态新增“HUD文字保护”；打包422回退不显示该标记。

真实游戏15对原帧/中间帧对照，统计位置稳定的亮文字像素，亮度MAE（8位）：

| 区域 | 第一版保护 | 新保护 | 像素样本数 |
|---|---:|---:|---:|
| 任务文字 | 36.911 | 0.000 | 18216 |
| 操作提示 | 51.554 | 0.000 | 1678 |
| 道具文字 | 31.610 | 0.000 | 12466 |

这是这段游戏样本的像素验证，不代表所有字体、透明度和运动条件。原始游戏帧及对照仅保存在本机临时目录，没有加入仓库。

新增程序生成的“固定细字＋移动背景＋变化抗锯齿”回归，笔画误差0.517/255，原始帧保真、运动区域保持AI、全/限制范围和彩色细字回归通过；采集时序16项回归通过。

最终预览已确认显示“HUD文字保护”。用户在验证时切回固定60FPS，并开启MetalFX空间上采样；当次UI采样为59.0FPS，处理均耗18.9ms，最近240张显示取帧P50 38.7ms / P95 43.6ms，输入与AI待处理队列为空。这是运行时快照，启动后曾关闭AI，因此不把全程平均读数当作AI路径的持续帧率。新的主观观看效果仍以用户实际游戏反馈为准。

## 其他低延迟模型调研记录（2026-11-16，暂不实测）

用户要求先记录，不做实测。本节仅核对官方仓库、发布说明、模型代码与作者公开数据；没有安装或执行候选模型、运行性能测试或切换播放器后端。下面的数值不是本机测试结果，不能直接与前文M1 Pro的应用内滞后比较。

### 候选与证据

| 候选 | 官方资料已确认 | 本机接入/性能仍待确认 |
|---|---|---|
| **ANR FG / Apex Neural Rendering** | 官网列出M1及以上、macOS26及以上；作者公布M2 Max上1080p、2X时每张生成帧4.26ms。公开Mac测试包存在。 | M1 Pro耗时、Mac接口能否接普通采集帧、额外运动/深度数据需求、真实游戏HUD质量，以及是否有适合嵌入播放器的SDK。 |
| **ODF-VFI / OpenDuckFrame** | 面向Apple Silicon；以RIFE4.25上游权重做四阶段结构精简，未经重新训练。 | 精简后的画质、在本机是否快于当前Apple路径，以及移植到现有流水线的代价；没有确认可直接比较的M1 Pro测速。 |
| **Nano / Open-Frame-gen** | 约89.9K参数；作者报告RTX3050 Laptop上1080p模型推理101.1±2.4FPS，Nano使用FP16；公开PyTorch和ONNX权重。 | 目前主程序面向Windows/CUDA/TensorRT；需要另行验证Core ML/Metal转换、M1 Pro性能和文字/运动画质。 |
| **RifeMetal** | 原生MPSGraph＋Metal实现，内置RIFE4.25；有全分辨率、半分辨率、四分之一内部推理档，最后做全分辨率warp/blend。 | 属于替换推理后端与调节内部网格，并非新训练模型；没有确认优于当前Apple后端的本机耗时。 |

来源：[ANR官网性能表](https://apexcompute.com/neural-rendering)、[ANR Mac测试包发布说明](https://github.com/apex-compute/ANR/releases/tag/FG-V.B15)、[OpenDuckFrame说明](https://github.com/Jun-Rex/OpenDuckFrame#readme)、[Nano作者结果与运行条件](https://github.com/Deadly-pro/Open-Frame-gen#results)、[RifeMetal质量档位](https://github.com/cinemore/rife-metal#quality-tiers)。

### ANR版本与可用性

- 调研时最新公开版本为FG V.B18，发布于北京时间2026-11-15；说明写明沿用V.B16模型权重。
- Mac测试包仍为V.B15，发布于北京时间2026-11-13。不能将最新Windows/Linux包的权重更新视为Mac包已经同步。
- 主仓库仍将模型源码标为“coming soon”。本轮确认了Mac测试包，没有确认面向第三方播放器的正式Mac SDK/API；测试包约467MB，未下载安装。
- 官网的4.26ms是M2 Max的1080p、2X生成耗时，既不是M1 Pro成绩，也不是采集卡到屏幕的总延迟。

来源：[V.B18发布说明](https://github.com/apex-compute/ANR/releases/tag/FG-V.B18)、[V.B15发布说明](https://github.com/apex-compute/ANR/releases/tag/FG-V.B15)、[源码状态](https://github.com/apex-compute/ANR#apex-neural-rendering-anr)、[性能表](https://apexcompute.com/neural-rendering)。

### 比较时容易混淆的项目

- **ODF整机体验不等于其模型延迟。** 其README明确增强实时输出至少预留80ms自适应缓冲，可选自动视频时序会请求140ms；未来若借鉴四阶段模型，应单独测试模型及现有低延迟流水线，不照搬其播放缓冲。
- **Nano速度表的精度不同。** Nano为FP16，对照模型为FP32；不能将表中倍数当作同精度、同画质结论。作者同表PSNR为Nano28.40、RIFE HDv3 29.27，轻量化存在画质取舍。
- **RIFE上游没有确认更晚的新权重。** 本轮查阅的官方列表仍列4.25、4.25.lite、4.26；上游推荐多数场景默认4.25。原生Metal/MLX移植不等于训练模型升级。
- **MetalFX游戏插帧不等于当前VideoToolbox接口。** MetalFX插帧接口包含深度和运动纹理输入；采集卡只有最终图像，若采用此类接口，需要另外解决输入数据及其处理开销。
- **PushFPS的Mac预览可作为时序/HUD参考。** 其Windows版支持在估计运动数据后调用ANR；Mac预览使用自己的CPU块匹配＋Metal运动补偿，并不等于已经有Mac版ANR采集卡集成，也不是一个新的AI模型。

来源：[OpenDuckFrame缓冲与限制](https://github.com/Jun-Rex/OpenDuckFrame#support-and-limits)、[Nano测速条件](https://github.com/Deadly-pro/Open-Frame-gen#results)、[RIFE官方模型列表](https://github.com/hzwer/Practical-RIFE#trained-model)、[Apple MetalFX插帧输入](https://developer.apple.com/documentation/metalfx/mtlfxframeinterpolatorbase)、[PushFPS的ANR与Mac说明](https://github.com/DosukaSOL/PushFPS#anr-frame-generation-by-apex-compute)。

### 留待恢复实测后的顺序

1. **ANR Mac测试包**：先确认接口和输入要求，再决定能否进行同场景对照；它是本轮最值得关注的新模型候选，但尚不能认定比现有方案更快。
2. **ODF-VFI四阶段方案**：检查模型结构及原生实现，比较完整模型与精简模型的耗时和HUD/运动质量。
3. **Nano**：先评估Core ML/Metal可转换性，再考虑是否值得制作本机实验版本。
4. **RifeMetal后端**：作为RIFE原生GPU实现的对照路线。

恢复测试时统一使用同一段1080p60采集、主机30FPS内容，分别记录模型完整处理耗时、P50/P95、真实显示FPS、应用内滞后、转换/缩放开销及HUD重影。现阶段结论仅为“有值得验证的新候选”，尚无证据证明某候选在本机降低了总延迟。
