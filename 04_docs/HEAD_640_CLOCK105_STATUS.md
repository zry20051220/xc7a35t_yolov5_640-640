# 640 NPU 独立 105 MHz 候选测试（2026-10-03）

结论：时序与两图数值冒烟通过，但性能下降，不采用为速度版本。开发板已经恢复 100 MHz UpWords 版本，训练权重重新上传且两页 CRC 校验通过。

## 改动

- 独立工程：`work/board_head_qat640_clock105/head_qat640_clock105.xpr`。
- DDR/MIG UI 保持 100 MHz；增加 MMCM，将 NPU、启动器和位宽转换器置于 105 MHz。
- AXI interconnect S01 开启异步接口，连接 105 MHz NPU 与 100 MHz DDR。
- NPU 复位异步置位、三级同步释放；完成/错误先在源域寄存，再通过原顶层二级同步器。
- 只对启动、完成、错误的第一级同步器输入与复位同步器异步引脚设置例外。AXI 数据跨域沿用生成 IP 的最大延迟及偏斜约束。
- Clock Wizard 使用 No_buffer，避免将 MIG 已生成的 UI 时钟错误重定义为独立主时钟。
- Vivado 2018.3 XDC 不支持本次尝试的 foreach/if 写法，已改为直接约束，端点存在性检查放在 Tcl 构建脚本。

## 最终实现

- LUT 19238/20800（92.49%），BRAM 45.5/50（91%），DSP 82/90（91.11%）。
- WNS +0.359 ns，WHS +0.031 ns，建立/保持检查无失败端点。
- AXI bus skew 报告无 VIOLATED。
- CDC 报告不是零告警：原以太网通路存在告警，新增异步复位 OR 及生成 IP 复位路径存在组合逻辑告警。启动、完成、错误同步链确认，不能据此宣称全工程 CDC 或长期可靠性验收完成。
- 比特流 SHA256：`d61037957dd5406291426f5878b123dd463f1945e3f11c9e3b642000ae672847`。

## 实板测试

候选目录：`outputs/head_training/qat_board_candidate640_clock105_v1/board`。

- 已通过 JTAG 自动烧录，日志 `program.log`。
- 权重页 CRC：`e4d74646`、`fa21ae7d` 均匹配。
- SCUT PartA_00001：第 22601 帧，统计 5，三个输出层逐字节误差均为零。
- 用户图片 1.jpg：第 22602 帧，统计 7，三个输出层逐字节误差均为零；该图没有人数真值。
- 105 MHz 五帧 22610–22614：中位耗时 2.8201003 秒，0.354597 FPS，全部输出 CRC 匹配。
- 恢复 100 MHz 后现场五帧 22630–22634：中位耗时 2.4882055 秒，0.401896 FPS，全部输出 CRC 匹配。
- 同图、同权重、同图结构比较：105 MHz 耗时增加 13.3387%。证据 `speed_comparison_same_session.json`。

新增 AXI 异步转换的握手/缓存延迟可能抵消了计算频率收益，这是推断，未完成逐层性能归因。不要把时钟提高 5% 等同于整网提速 5%。

## 当前板上及建议使用

已经恢复 `qat_board_candidate640_upwords_v1/board/head_qat640_candidate.bit`，见候选目录 `rollback_program.log`；恢复后权重 CRC 和五帧数值测试通过。

推荐继续使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\codex\2026-09-27\yong\scripts\run_head_detection.ps1" -InputSize 640 -UpWords -Source 0
```

`-Clock105` 仅保留为实验对照，启动仍需数值验收记录且提示已实测更慢。未修改默认版本；未删除任何原比特流或权重。两图/五帧测试不代表完整数据集精度或长期视频稳定性验收。
