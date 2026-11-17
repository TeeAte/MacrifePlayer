# 恢复缩放固件：已刷入并验证

文件：`ms2130_scaling_restored_candidate.bin`，53806 字节，SHA-256 `f006579770c14702387827dccb71bcd94994e4a00acb3f7d1aee1e6db20bfcd9`。

相对先前刷入的上游 `ms2130_patched_v1.bin`，从原始 `4k2.bin` 恢复代码偏移 0x937e、0x9399 的 `LCALL 0x89c9`（共 6 字节），再更新 2 字节代码校验（0x0af5）。EDID、USB 模式描述符及其他上游补丁不变。逐字节差异及基线哈希见 `scaling-restored-candidate.json`。

用户授权后，已先备份当前完整 65536 字节 Flash 至 `../backups/before-scaling-restore.bin`，与先前仓库固件有效部分一致并设为只读；新固件全部 53806 字节通过读回校验，刷写器退出码 0。用户已拔插 USB，实卡确认 1080p60、2K30、4K18 均显示完整画面并达到对应档位。2K50 仍仅约 32fps 上屏，不承诺稳定 2K50。测试关闭补帧与增强；未独立验证实际 HDMI 输入时序或原生 4K 像素细节。

刷写日志 `../scaling-restore-flash.log`，完整审计 `../scaling-restore-operation.json`。最初出厂固件的三份只读完整备份仍保留。
