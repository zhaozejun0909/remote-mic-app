# 本地移植：重复 HID 权限轮询

- 状态：最小修复完成，待系统权限验收；来源：[上游 #532](https://github.com/HD838A/remote-mic-app/pull/532) 与其必要修正 [#534](https://github.com/HD838A/remote-mic-app/pull/534)。
- 触发与证据：本地每个已绑定/发现 monitor 各有 1Hz timer，各自调用进程级权限 API。上游确认只共享 timer 仍会查询 N 次，必须把求值也共享；本轮未测真实 TCC IPC 速率。
- 修复：独立 HIDPermissionPoll 每 tick 求值一次后广播；订阅析构自动取消，最后订阅退出停止 timer，保留 1Hz 撤权响应。显式注入的测试权限/调度器保留隔离。
- 验证：两个订阅者一次 tick 仅求值一次；最后析构停 timer、重复取消、回调中自取消通过。真实权限撤销与系统 IPC 待测，见 [验收手册](../Testing/LocalPerformanceFixes.md)。
