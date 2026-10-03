# ACX720 人头计数 FPGA 文件包

整理日期：2026-10-04。推荐版本为 640×640、100 MHz、UpWords 优化及最新人头 INT8 权重。原工程、脚本、实验版本没有移动或删除。

## 目录

- `01_run`：配套 bit、权重、图结构、主机 Python 程序及启动脚本。
- `02_sources`：关键 HLS、RTL、约束和构建脚本快照。不是独立可重建的完整 Vivado 工程，依赖下述原项目与 IP。
- `03_evidence`：时序、资源、两图数值核对及五帧速度记录。
- `04_docs`：训练、优化、提频实验的原始说明快照，其中相对路径按原工作区解析。
- `file_manifest.json`：整理时所有文件的大小与 SHA256。

## 本机启动

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\codex\2026-09-27\yong\deliverables\ACX720_HEAD640_100MHz_20261004\01_run\run.ps1" -Source 0
```

另一摄像头用 `-Source 1`。Q/Esc 退出。脚本会烧录、上传权重并核对后运行；`-CheckOnly` 仅核对文件，不操作板卡。

需要本机 Vivado 2018.3、C:\Python314 的现有依赖、连接好的 JTAG 和以太网。板卡 XC7A35T-FGG484-2，FPGA 192.168.0.2，电脑网卡 192.168.0.3；本机邻居项应为 00-0a-35-01-fe-c0。供电/重新烧录会清空 DDR 权重。串口不是该入口的传输方式。

## 原工程位置

- Vivado：`D:\codex\2026-09-27\yong\work\board_head_qat640_upwords\head_qat640_upwords.xpr`
- HLS/IP：`D:\codex\2026-09-27\yong\hls\npu_head640_upwords_prj\solution1\impl\ip`
- 原验证产物：`D:\codex\2026-09-27\yong\outputs\head_training\qat_board_candidate640_upwords_v1\board`
- 重建脚本：原目录 `tools/build_head640_board.tcl`，参数 `upwords`；需要现有原工程/IP，禁止覆盖已经验证的 bit。

## 版本选择与限制

100 MHz 推荐版本上板约 2.49 秒/帧；最新复测在 clock105 候选目录 `rollback_100mhz_speed_5frames.json`，本包 `speed_5frames.json` 是此前约 2.48 秒的测量。两图逐字节核对通过，不代表完整精度、全工程 CDC 或长期稳定性验收。

105 MHz 版本位于原目录 `outputs/head_training/qat_board_candidate640_clock105_v1/board`，虽数值通过，但约 2.82 秒/帧，比 100 MHz 更慢，不推荐用于提速。

其他 `qat_board_candidate640_ft_v1`、`store4_v1`、`qat_board_candidate_v1` 为历史对照。旧 `outputs/acx720_yolo_realtime320.bit` 为通用检测版本，不要与本包人头权重混用。本包不包含训练数据、GPU 模型或中间编译缓存。
