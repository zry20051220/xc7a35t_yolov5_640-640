# 640 人头模型微调

2026-10-03：30 轮浮点微调及 10 轮 640 QAT 均完成，新候选完整评估、整板时序及两张真实 FPGA 图片的数值验收通过。当前板上为新微调候选，旧版本文件保留。

## 配置

- 新目录：`outputs/head_training/head_relu640_ft_v1`。
- 从 `head_relu320_v1/best_weights.pth` 严格加载全部模型参数，不是从头训练。
- 初始权重 SHA256：868808ac1578673ddaa6d5f72a28f4a3c96e0decd69b05b8fc50ee565ae9cbd9。
- FPGA 兼容 ReLU / Focus 网络、单类 head、原像素锚框保持不变。
- 输入 640×640，batch 4，计划 30 轮，AdamW，初始学习率 0.00005，余弦衰减。
- 训练集 2534 张、验证集 861 张；不把独立测试集用于梯度或选权重。
- 保存 best / last / resume 检查点，按验证损失保留候选。验证损失下降不代表计数误差一定下降。
- 新程序参数化输入分辨率、初始人头模型和学习率；旧 320 默认训练设置保持不变。

## 检查

独立小规模运行 `head_relu640_ft_smoke_v1` 已完成，16 张训练图、8 张验证图，形状正确且损失有限，未出现显存溢出。
40 项现有电脑端单元测试通过。
正式训练以独立隐藏后台进程启动，初始 PID 51480；应结合进程命令行及日志确认当前状态，不能只凭 PID 判断。

日志：`outputs/head_training/head_relu640_ft_v1_stdout.log` 和 `head_relu640_ft_v1_stderr.log`。
进度：训练目录中的 `history.jsonl`，每个完整训练/验证轮次追加一次。
完成标记：`completed.json`；没有该文件不能称训练完成。

## 后续验收

### 已完成的完整验证集比较

固定 640 输入、confidence 0.3 / NMS 0.35，861 张验证图：
旧浮点模型 AP50 0.8462093、人数 MAE 2.1196283；新浮点模型 AP50 0.8514409、人数 MAE 2.0557491。
这是约 3% 的人数误差改善，不是大幅提升，也不是新 INT8 上板精度。
新浮点权重 SHA256 ff292bff6aa691322b8df8509eb52d10492aea31f6bf0dce7080de8c9e0ac850。
评估目录：`eval_float640_ft_nms035_val_v1`、`eval_float640_baseline_nms035_val_v1`。
独立测试集尚未用于新模型调参。

### 量化感知训练

`head_qat640_ft_smoke_v1` 一轮小规模检查完成，量化 CPU 输出形状验证通过。
正式运行 `head_qat640_ft_v1` 从新浮点最佳权重开始，计划 10 轮、batch 4；训练/验证划分保持不变。
日志 `head_qat640_ft_v1_stdout.log` / `head_qat640_ft_v1_stderr.log`。
训练后仍需完整量化验证、固定参数的独立测试及 FPGA 验收。小规模完成不等于正式训练完成。

### 正式 INT8 验收进度

10 轮正式 QAT 已完成，最佳验证损失 0.1362407。固定 confidence 0.3 / NMS 0.35：

| 数据 | 旧 INT8 人数 MAE | 新 INT8 人数 MAE | 旧 AP50 | 新 AP50 |
|---|---:|---:|---:|---:|
| 验证 861 张 | 2.2323 | 1.9280 | 0.828858 | 0.843838 |
| 独立测试 1000 张 | 2.3720 | 2.0770 | 0.825102 | 0.842314 |

测试集 precision 81.61% → 83.31%，recall 83.27% → 85.05%。
>=50 人的密集图片人数 MAE：验证 186 张 4.8333 → 4.1452，测试 225 张 5.1156 → 4.8133。
新权重 SHA256：89f5568df22c69c3b5a4a14252705fd6742a0a09ea0428ee2d062b5f7713c780。
完整评估目录 `eval_qat640_ft_nms035_val_v1` / `eval_qat640_ft_nms035_test_v1`。
以上是量化模型电脑评估，不是整个测试集的真实 FPGA 精度验收。

### 上板候选

目录 `outputs/head_training/qat_board_candidate640_ft_v1/board`。
已导出 60 层，生成两页打包权重、add3 查表及 100 步调度；布局和原提速版完全一致。
SCUT 图片整数参考及上板预检查通过；40 项电脑端单元测试通过。
打包权重 SHA256 8e16eb1c7135ea7b7acc9107c1cce6c6c6f562710ba95809afc8a08a1c1c7f98。
图 SHA256 458b8ae436395febaa1e8c7eb4f6fe5f9f3f1be38423594b553336ed8bacda34。
新工程 `work/board_head_qat640_ft/head_qat640_ft.xpr` 已启动编译。
整板时序已通过：WNS +0.719 ns、WHS +0.029 ns。LUT 17992/20800（86.50%）、BRAM 44.5/50（89%）、DSP 76/90（84.44%）。DRC 无错误；仍有原工程复位和约束警告，未完成长期稳定性或完整跨时钟域验收。
新候选已经 JTAG 烧录，bit SHA256 27e6de9ada4656b76d74a915110dea6b2d135bd8e7d75f7282f9d0e421e215dd。
两页权重 CRC e4d74646 / fa21ae7d 验证通过。
帧 22401（SCUT）和 22402（用户 1.jpg）每张三个输出头共 151200 字节逐字节零误差。
SCUT GT 5，计数 5；用户图计数 7，未知真值，不宣称计数正确。单帧耗时约 2.55 秒。
验收 `numerical_smoke.json` 绑定 bit、图、权重哈希和实际烧录日志；仍不具备固件自报身份协议。

### 摄像头使用新版

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\codex\2026-09-27\yong\scripts\run_head_detection.ps1" -InputSize 640 -FineTuned -Source 0
```

`-FineTuned` 和旧 `-SpeedCandidate` 不可同时使用。原命令带 `-SpeedCandidate` 会切回旧训练权重，不代表新版。
默认重新烧录并上传权重；确认板上仍保持当前新版及 DDR 权重时，可加 `-ReuseLoadedBoard`。
默认 confidence 0.3 / NMS 0.35，Q / Esc 退出。启动哈希检查及 40 项单元测试通过。
摄像头长时间稳定性尚未验收。独立测试集精度仍为电脑量化模型结果，不等于整套 FPGA 数据集验收。

训练完成后先做 640 全验证集检测和人数误差评估，与现有模型相同后处理（confidence 0.3 / NMS 0.35）比较。
再进行 INT8 量化或 QAT、量化误差和密集人群评估、固定配置的独立测试集验收。
只有候选精度合适且 FPGA 整数参考和实际上板数值验证通过，才考虑更新部署。
本次启动不表示新精度已提高，也不表示新权重已上传开发板。
