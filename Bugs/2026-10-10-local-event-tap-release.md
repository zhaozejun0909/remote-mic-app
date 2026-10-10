# 本地移植：键盘监听端口未注销

- 状态：最小修复完成，待真实长跑验收；来源：[上游 #501](https://github.com/HD838A/remote-mic-app/pull/501)。
- 触发：HID 重建或反复录入快捷键，stop/start 循环；旧代码仅 disable 与摘除 RunLoop source，系统侧端口仍登记。
- 上游现场与对照：长期累积上千个 tap、退出后恢复；100 次循环，旧清理残留 100 个，显式 invalidate 后为 0。本次读取原记录与最终代码，不把上游现场当作本机复现。
- 本地检查：`KeyboardEventSuppressor`、`ShortcutCaptureMonitor` 的 stop 和 source 创建失败路径均缺少 invalidate。历史日志有重复 HID 重建，但未取得本机有效端口计数；本机探针和测试进程无法创建 tap，实际端口实验跳过。
- 修复：独立 `EventTapPort.release`，两处 stop 和两处失败分支共用；不改按键映射和语音事件。
- 验证：现有回归、Release 构建；真实 tap 不累积及 WindowServer CPU A/B 待测，步骤见 [验收手册](../Testing/LocalPerformanceFixes.md)。
