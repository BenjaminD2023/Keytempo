# 电池与进程功耗测量

2026-10-22，Apple M4 MacBook Air / macOS 27。之前的 CPU、RSS、文件写入结果不等于电池功耗测量。

## 门槛与口径

把用户的“1 W/h”按**平均功率低于 1 W，即每小时能量消耗低于 1 Wh**记录。W/h 字面是功率的变化率。

- **进程 CPU 归属能量**：内核按任务记账的 CPU 能量，可用 nJ / 实际秒数换算为平均 W。
- **App 引起的完整电池增量**：还可能包括其他进程服务、GPU、显示、内存、存储与唤醒成本，不能用上一个数字自动替代。
- **整机电池输出**：所有应用和硬件的总和，不能全部归给 Keytempo。

## 本次实测

使用 SDK 公开的 `proc_pid_rusage(RUSAGE_INFO_V6)`，读取 `ri_energy_nj`，按 `ΔnJ / 1e9 / Δ单调秒数` 换算。`ri_penergy_nj` 是 P 核子集，不再加一次。CPU 时间通过本机 Mach timebase 125/3 换算，未将 ticks 直接当作纳秒。Bank billed/serviced 计数单列，没有混进电池瓦数。

场景：已运行的 Release 进程 PID 50119，窗口关闭、未执行真实输入场景，低电量模式已开启。全局权限与真实输入验证仍按用户此前选择留待稍后。其他桌面应用正常运行，没有改变屏幕亮度、节能设置或系统权限。

| 指标 | 180 秒样本 |
|---|---:|
| 实际时长 | 180.000015 s |
| 样本数 | 37，每 5 秒计划采样 |
| CPU 归属能量增量 | 0.004319848 J |
| **平均 CPU 归属功率** | **0.000023999154 W（0.0240 mW）** |
| 最大单采样区间平均 CPU 功率 | 0.000468554257 W |
| 此时段 CPU 能量 | 0.000001199958 Wh |
| CPU 时间增量 | 0.0266232 s |
| 单核口径 CPU | 0.01479% |
| package idle wakeups 增量 | 0 |
| interrupt wakeups 增量 | 15 |
| 进程读取 / 写入 / logical writes | 均为 0 字节 |

原始记录：`artifacts/power-idle-process.json`。PID 身份稳定，计数单调、无读取错误。最大采样间隔 8.474 秒，存在调度抖动，但未超过工具 10 秒的中断判定。非零累计能量和工具正向自检证明本机支持该计数，不是把“不支持”误报成零功耗。

工具自检：让工具自己的进程进行约 0.2 秒计算，能量计数增长 68,113,742 nJ、CPU 时间增长 0.189694 秒。不存在 PID 的测试返回 unavailable / process_not_found，不输出“0 W”。工具只在手动运行期间采样，不作为 App 后台服务运行。

上述测量早于 Keytempo 更名与菜单栏 WPM 更新。当时的图标更新仅修改资源、Info.plist 与打包脚本，Swift 源代码未更改；重新签名会改变可执行文件校验值。新图标首次加载的其他进程开销未单独归属测量。本报告不将旧样本冒充更名后版本的新一轮功耗实测。

## 1.1.0 build 5 复核

新版仍在全局权限未授权、没有真实输入的路径各采样约 30 秒：仅菜单栏、功能窗口尚未打开时，平均 CPU 归属功率 `0.000004932746 W`；打开统计、设置、中英界面与历史后关闭窗口，重新采样为 `0.00000019055 W`。两次进程身份稳定、计数单调，进程磁盘写入和 package idle wakeups 增量为 0。原始记录为 `artifacts/keytempo-build5-cold-menu-energy.json` 与 `artifacts/keytempo-build5-warm-menu-clean-energy.json`。CPU 归属计数在短窗口中很小，不能称整机电池“零耗电”。

这些读数低于 1 W，仅证明对应稳态短样本的**进程 CPU 归属部分**；没有覆盖启动绘制、实际输入、GPU、WindowServer 或整机电池增量。RSS 复核发现使用多语言界面后超过原目标，已实施菜单弹窗按需创建／关闭释放；内存结果与仍未达标的部分见 `PERFORMANCE.md`。不从短时功耗或这次结构优化推断全部性能目标达成。

## 结论与限制

**这次空闲样本的 CPU 归属功率低于 1 W，没有测得需要针对这一项降到 1 W 以下的情况。完整的 App 电池增量低于 1 W 尚未验证。** 不把进程计数冒充整机电池精确归因，也不从空闲外推持续输入或统计窗口打开时的功耗。

首次检查时电池电压 11.293 V、放电电流约 0.821 A，乘积约 **9.27 W，是当时整机的电池端估计**，不是本 App 功率。未进行受控 App 开/关电池对照，没有用它推算 Keytempo 的额外瓦数。

`powermetrics` 本次返回需要 superuser；`sudo -n` 返回需要密码，没有取得管理员采样权限。Activity Monitor 的 Energy Impact 是相对指标，不能当作 W。当前只有 CLT，没有完整 Instruments。

要严格验收完整电池增量，需要保持电源、屏幕亮度、前台任务及其他进程负载一致，做多轮 App 退出/运行的配对电池测量，报告噪声和不确定范围；全局统计还需在真实输入权限开启后复测。若配对增量仍超过 1 W，再依据实际 CPU、唤醒、I/O、GPU 或跨进程服务证据定位、优化并同条件重测。

## 复现

```sh
mkdir -p artifacts
clang -O2 -Wall -Wextra -Werror scripts/measure_energy.c -o artifacts/measure-energy
artifacts/measure-energy --self-test
artifacts/measure-energy APP_PID 180 5 > artifacts/power-idle-process.json
```

需要包含 RUSAGE_INFO_V6 的 SDK；运行时不支持、无权限、PID 重用或长采样中断会显式返回 unavailable/invalid，不当作低功耗。不要将测量工具设为登录项或随 App 常驻。

一级资料：[Apple Recount 的 CPU 能量记账](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)、[task.c 的总量与 P 核子集](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)、[Bank 跨任务记账](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/bank/bank.c)、[Apple 对 Energy Impact 的定义](https://support.apple.com/en-hk/guide/activity-monitor/actmntr43697/mac)、[电池遥测电流/电压单位](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/Resources/com.apple.bdc.metadata.plist)。
