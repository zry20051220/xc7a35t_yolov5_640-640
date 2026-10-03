# 640 访存与功能算子提速实验

2026-10-03。以 `qat_board_candidate640_ft_v1/board` 为当前已上板基线，保持其模型、权重、分辨率及后处理不变。基线耗时中位约 2.54024 秒/帧。

## 改动

共享 HLS 源码增加可选开关；旧核心未定义这些开关，旧 bit 和已验证 IP 不变。
`NPU_UPSAMPLE_WORDS`：读取一行输入，四个输入字节扩展为一个 64 位输出字；缓存展开行并写出两份，避免对同一行重复读取。宽度非 4 的倍数回退到原逐字节实现。
新增测试覆盖宽度 4、8、20、40、320，以及奇数宽度 7，校验输出后的哨兵字节不被覆盖。C 仿真全部零误差。

## 未采用的组合实验

`NPU_ELEMENT_TWO` 尝试每轮处理两个字节。但 HLS 将 ELEMENT_BYTE 的启动间隔从 1 提高到 2，局部延迟 17 → 18 周期，未取得这段循环的提速；HLS DSP 估算增至 86。因此不把此组合推进上板，先验证上采样单项。
组合项目 `hls/npu_head640_ops2_prj` 的联合仿真是实验记录，不代表采用它。

## 当前候选

仅启用整行上采样的新核心：`hls/npu_realtime/npu_head640_upwords.cpp`。
项目 `hls/npu_head640_upwords_prj`。C 仿真和硬件联合仿真通过，IP 导出完成。
HLS 核心估算 BRAM18K 83、DSP 82、FF 20047、LUT 26180；不代表整板实际资源。
候选目录 `outputs/head_training/qat_board_candidate640_upwords_v1/board` 从新微调基线复制同一权重、图、调度和参考输出。
独立工程 `work/board_head_qat640_upwords/head_qat640_upwords.xpr` 已启动编译。
整板实现通过：LUT 18735/20800（90.07%）、BRAM 45.5/50（91%）、DSP 82/90（91.11%），WNS +0.514 ns、WHS +0.028 ns。DRC 无错误，仍有原工程约束、复位等警告。
候选已烧录；bit SHA256 aa3fc282497eee9f76a3f9ffe2ef101ffdbea095c6ac13b833e2800262629051。
两页权重 CRC e4d74646 / fa21ae7d 校验通过，使用与基线完全相同的微调权重和网络图。
帧 22501、22502 对应 SCUT 和用户图片，三个检测头均与整数参考逐字节零误差，计数保持 5 / 7。用户图未知真值，不宣称计数正确。
相同图片、权重及发送参数的 5 帧对比：中位耗时 2.540244 → 2.478381 秒，减少 0.061864 秒（2.435%），约 0.4035 FPS。所有检测头 CRC 一致。这只是同图短时测试，不代表摄像头长期稳定性或完整 FPGA 数据集准确率验收。
记录为候选目录中的 `numerical_smoke.json`、`speed_5frames.json`、`speed_comparison.json`，旧记录不覆盖。
40 项单元测试及新版入口哈希检查通过。

### 当前上板与使用

当前板上为上采样优化候选，原微调版及此前版本保留。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\codex\2026-09-27\yong\scripts\run_head_detection.ps1" -InputSize 640 -UpWords -Source 0
```

`-UpWords`、`-FineTuned`、`-SpeedCandidate` 只能选择一个。`-FineTuned` 会切回原微调版。
默认重新烧录并上传权重，确认板上和 DDR 确实保持当前候选时可加 `-ReuseLoadedBoard`。
仍未完成摄像头长时间测试，速度提升幅度小且资源余量减少。

## 时钟评估

NPU、AXI 互连和 DDR MIG 共享 `ui_clk`，并非只改一个 NPU 时钟参数即可提频。
暂不修改 DDR 时钟配置，先完成数据路径优化的实测；后续提频需评估独立时钟域与 AXI 跨域资源、复位及整板时序。尚未验证任何新时钟频率。
