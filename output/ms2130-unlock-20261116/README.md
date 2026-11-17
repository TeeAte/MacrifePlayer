# MS2130 2K / 4K 固件操作记录

目标设备：USB3 Video，VID:PID `345F:2130`，序列号 `20210623`，USB位置 `0x01240000`，5Gbps连接。

原固件读取两次，各65536字节，逐字节一致；刷写器的第三次自动备份也与前两份完全一致。原固件头部与程序校验有效，备份设为只读，完整保留Flash尾部。

- 恢复原件：`backups/original-read1.bin`
- 第二份备份：`backups/original-read2.bin`
- 刷前自动备份：`backups/preflash-auto.bin`
- 原件SHA-256：`77df5d706d27a39ad09f56d3de39384d9eae43be0784e3d5db28a02eb8260ea5`

目标固件来自 https://github.com/steve-m/ms2130_patcher ，文件 `firmware/ms2130_patched_v1.bin`，53806字节。使用同仓库C源码从 `4k2.bin` 重新生成，结果与仓库提供固件逐字节一致，头部和程序校验均有效。

目标SHA-256：`d617e20475d78b46dc5df702311312fff90e2e49356ebc22ee372738d257c80f`

刷写器来自 https://github.com/steve-m/ms213x_flash 。原始源码为 `tools/ms213x_flash.upstream.c`，本地适配源码为 `tools/ms213x_flash.c`。仅修改工具：macOS优先HID接口、保存完整Flash、擦写错误立即停止、验证失败返回错误；没有改动目标固件。未安装驱动或Homebrew依赖，使用本机已有libusb/hidapi。

执行命令（本目录）：

```sh
./tools/ms213x_flash -w firmware/ms2130_patched_v1.bin -r backups/preflash-auto.bin
```

刷写日志见 `flash.log`。不使用禁用校验的 `-n`。最新结果以 `operation.json` 与实际刷后设备格式记录为准；目标固件内的分辨率描述符不能替代真实画面与帧率测试。

如以后需要恢复，应使用以上原固件和同一刷写器，先确认仍为同一设备，并另存当时固件。恢复示例（此命令尚未执行）：

```sh
./tools/ms213x_flash -w backups/original-read1.bin -r backups/before-restore.bin
```

完成刷写及验证后需要重新上电，再检查USB枚举、分辨率与实际画面。

## 完成结果

固件成功写入并通过逐字节读回校验。用户拔插重新上电后，macOS通过AVFoundation实际枚举到2560×1440最高50FPS、3840×2160约18FPS，并保留1920×1080最高60FPS；均有yuvs与420v接口。USB仍为5Gbps。见`formats-before.json`、`formats-after.json`与`device-after.txt`。

这里只验证固件和设备格式枚举，未做真实画面、持续帧率或原生4K细节测试。

## 恢复缩放版本：最新刷写与实卡验证

用户授权后，已刷入 `firmware/ms2130_scaling_restored_candidate.bin`，SHA-256 `f006579770c14702387827dccb71bcd94994e4a00acb3f7d1aee1e6db20bfcd9`。该版本只恢复 4k2.bin 的两处原始缩放调用（6 字节），并更新代码校验（2 字节），其余上游补丁及 EDID、USB 模式不变。

刷前完整备份 `backups/before-scaling-restore.bin`（65536 字节，只读），SHA-256 `9befe1402f582f1fd2cc482f44f6f494800623536a9f8aea58ecdf45459d3e39`，其有效部分与先前刷入的仓库固件逐字节一致。刷写器已对新固件全部 53806 字节执行读回比对并成功退出。日志 `scaling-restore-flash.log`；完整审计及性能计数 `scaling-restore-operation.json`。

用户拔插 USB 后，设备仍为 345F:2130、序列号 20210623、5Gbps。Player 实卡确认：

- 1920×1080 YUVS 60fps：完整画面，上屏约 60fps。
- 2560×1440 YUVS 30fps：完整画面，约一分钟运行保持约 30fps；原先右侧与底部的大块黑边消失。PS5 设置页显示分辨率选择为 2160p；未独立读取 HDMI 输入时序。
- 3840×2160 YUVS 18fps：完整画面，上屏约 18fps；不代表 4K60，也未验证原生 4K 像素细节。
- 2560×1440 YUVS 50fps：上屏仍仅约 32fps，继续保留 2K30 为此卡默认档。

以上均关闭 AI 补帧与图像增强，未重新测补帧性能。当前 Player 留在 2K30 YUVS 模式。原始出厂固件与上游补丁版备份均保留。
