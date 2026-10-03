# ACX720-V3 上板工程（XC7A35T）

本目录已经加入基于官方 ACX720-V3 35T 工程的板级实现，使用 Vivado
2018.3 重新综合、布局布线并生成 bitstream。

## 已上板验证的 bitstream

- 50 MHz 板载时钟、复位和官方 MIG DDR3 控制器；
- RGMII/GMII UDP 接收，固定地址 `192.168.0.2:5000`；
- 校验 24 字节 YOLO 应用头（magic、版本、类型、640x640 尺寸、分包长度）；
- 去掉应用头和包尾 CRC，把图片或量化 Focus 字节按 16 bit 打包写入 DDR3；
- `LED[1]`：DDR3 初始化完成；
- `LED[0]`：DDR3 整帧读回 CRC 与收到的数据一致；
- AD7606 接口保持在安全的非工作电平，以兼容官方 XDC。

已上板回归的互连版本为 `outputs/acx720_yolo_axi_fabric_idle_npu.bit`：
量化 Focus 帧与普通 RGB 帧连续发送后，用户确认两个 LED 均亮。
其实现报告 WNS `+0.982 ns`、TNS `0`、DRC `0 Errors`。

## 烧录

1. 用 Vivado 2018.3 打开
   `board/acx720_yolo_board/ad7606C_ddr3_rgmii.xpr`。
2. 打开 Hardware Manager，连接 JTAG，选择器件 `xc7a35t_0`。
3. Program Device，选择 `outputs/acx720_yolo_axi_fabric_idle_npu.bit`。
4. 板卡网线直连电脑，把电脑有线网卡设为 `192.168.0.3/24`。
5. 当前接收固件不应答 ARP。在管理员 PowerShell 中添加临时邻居记录
   （Windows 重启后需重加）：

```powershell
netsh interface ipv4 add neighbors "以太网" 192.168.0.2 00-0a-35-01-fe-c0 store=active
```

   如果有线网卡名称不是“以太网”，先用 `Get-NetAdapter` 查看并替换名称。
   用 `Get-NetNeighbor -IPAddress 192.168.0.2` 确认 MAC 地址后再发送。
6. 安装主机依赖并发送图片：

```powershell
py -m pip install -r sw\host\requirements.txt
py sw\host\send_test_frame.py your_image.jpg --ip 192.168.0.2 --port 5000
```

为后续第一层卷积测试准备 DDR 输入时，加上 `--model-input`：

```powershell
py sw\host\send_test_frame.py your_image.jpg --ip 192.168.0.2 --port 5000 --model-input
```

这个选项按照模型的实际预处理执行直接缩放、RGB、`/255`、UINT8 量化和
Focus 重排，生成 12×320×320 的 CHW 字节流。当前 bitstream 仍只做 DDR
读回校验；它不会执行卷积。

DDR3 初始化后 `LED[1]` 应点亮。新 bitstream 在收完一帧后等待约 1 ms，
随后从 DDR3 读回 614400 个 16 位字并与写入时的整帧 CRC32 比较；
仅当两者相同，`LED[0]` 才点亮。读回约需数毫秒，发送结束后稍等再观察。
v2 将 DDR 写入地址范围修正为一帧（614400 个 16 位字），因此连续发送
多帧时均从缓冲区起点写入。旧版 `acx720_yolo_crc_readback_640.bit`
误将字节数当成字数，导致第二帧校验失败、第三帧又通过，请勿再烧录旧版。
发送脚本打印 `sent frame` 仅代表电脑端调用发送成功，不能证明板卡收到了数据。
旧版 `outputs/acx720_yolo_ingress_640.bit` 的 LED0 只表示收到末包，
两版 LED0 含义不同。

## 权重上传实验版（已上板验证）

`outputs/acx720_yolo_weight_upload_idle_npu.bit` 在原有两种输入帧之外支持
类型 2 的权重帧。它将第一层 1856 字节权重和偏置补零到整帧长度，写入
DDR3 `0x400000`，再从同一地址读回做 CRC 校验。综合与布线通过，WNS
`+0.982 ns`、DRC `0 Errors`、0 锁存器。实板第 201 帧普通图片、
第 202 帧权重、第 203 帧量化 Focus 图片均由用户确认 D0/D1 同时亮。
首次冷启动直接发送权重帧时仅 D1 亮，原因未查明；建议先发送一帧普通
图片作为网络通路预热，再发送权重与量化图片。
卷积核虽然已连接 DDR3，但启动接口仍保持空闲，不能运行推理。

烧录这个实验版后，先等待 LED[1] 亮，再发送权重帧，等 LED[0] 亮后
再发送量化图片；两帧之间不要抢发：

```powershell
py sw\host\send_first_layer_weights.py --frame-id 200
py sw\host\send_test_frame.py your_image.jpg --model-input --frame-id 201
```

这两次 LED[0] 均亮才表示相应整帧 DDR 写入/读回一致，**不表示卷积已运行**。
电脑端 `sent` 也不等于板卡确认。

## 第一层自动启动实验版（待上板验证）

`outputs/acx720_yolo_conv1_start_unverified.bit` 在上述传输基础上，
只有权重帧和随后量化 Focus 图片帧分别通过 DDR 读回 CRC 校验后，
才通过 AXI-Lite 启动第一层卷积。D1 表示 DDR 初始化完成；D0 在权重
上传校验通过后点亮，在量化图片通过校验并开始运算时熄灭，第一层
`ap_done` 且无 AXI-Lite 错误时再点亮。D0 再次点亮只表示运算结束，
**不表示输出数值已验证，也不表示完整 YOLOv5n 检测可用**。

该版本已烧录上板；用户确认 D1 亮、第 204 帧普通图片与第 205 帧权重
D0/D1 同亮，第 206 帧量化 Focus 图片后 D0 先灭再亮。综合、布局布线
WNS `+0.778 ns`、DRC `0 Errors`、0 锁存器。

## 第一层标准输出 CRC 实验版（待上板验证）

`outputs/acx720_yolo_conv1_output_crc_unverified.bit` 针对项目提供的
`img.int.npy` 标准输入，在第一层完成后从 DDR3 `0x200000` 读回
1,638,400 字节，并与标准输出 CRC32 `1ea472ba` 比较。仅当输入确实
是标准张量且输出 CRC 一致时 D0 才亮；普通图片仍沿用上一版的
`ap_done` 指示。D1 始终表示 DDR 初始化完成。当前综合、布局布线通过，
WNS `+0.552 ns`、TNS `0`、DRC `0 Errors`，**尚未上板验证**。

烧录后等待 D1 亮，然后每步完成后看 D0 再进行下一步：

```powershell
python sw/host/send_test_frame.py 'C:\Users\zry\Desktop\img\1.jpg' --frame-id 207
python sw/host/send_first_layer_weights.py --frame-id 208
python sw/host/send_reference_first_layer_input.py --frame-id 209
```

标准输入发送后 D0 会在运算和输出读回期间保持熄灭；最终亮起才是
第一层输出 CRC 匹配的实板证据。若 D0 不亮，需进一步区分传输、
计算和输出读回问题，不应直接判定模型错误。

实测第 207 帧普通图片、第 208 帧权重均点亮 D0/D1；第 209 帧
标准输入后 D0 熄灭未再亮，原因尚未定位。

## 第一层输出诊断版（待上板验证）

`outputs/acx720_yolo_conv1_output_diagnostic.bit` 保持原有计算与
输出 CRC 路径，仅细化 D0 指示。D1 仍表示 DDR 初始化完成。
标准输入通过校验并启动后，D0 常灭表示尚未见到 `ap_done`；
快闪约 6 次/秒表示已完成计算、正在读回输出；慢闪约 1.5 次/秒
表示输出读回结束但 CRC 不匹配；常亮表示输出 CRC 与标准值匹配。
如果输入帧自身的 DDR 读回 CRC 不匹配，D0 也会慢闪，此时计算
不会启动。普通图片仍沿用 `ap_done` 指示。

诊断版整板布线 WNS `+0.123 ns`、TNS `0`、DRC `0 Errors`；
尚未上板验证。重新烧录后建议先发普通图片预热，再发权重和标准输入，
每一帧后观察 D0，避免混淆出错阶段。

实测恢复 Windows 静态 ARP 映射后，普通图片和权重均通过；标准输入完成
后 D0 约 2 Hz 慢闪，因此输出读回已经结束，但 CRC 与黄金值不一致。

## 第一层 CRC UDP 回传版（待上板验证）

`outputs/acx720_yolo_conv1_crc_udp.bit` 在输出读回结束后，向电脑
`192.168.0.3:6102` 发送一个 UDP 包。载荷固定为 8 字节：ASCII
`CRC1`，随后是 4 字节大端实际 CRC32。电脑端运行：

```powershell
python sw/host/receive_first_layer_crc.py --timeout 60
```

必须先启动接收程序，再发送标准输入。该版本整板布局布线 WNS
`+0.494 ns`、TNS `0`、DRC `0 Errors`；UDP 载荷仿真及电脑端解析测试
通过，尚未上板验证。

## DDR FIFO 字序修正版（待上板验证）

实板回传的稳定错误 CRC `3d6c9e45` 和前 32 字节全 `ff`，经软件模型
精确复现为：每个 128 位 DDR beat 内的 8 个 16 位字顺序反转。旧入口
CRC 因写入、读回各反转一次而无法发现该问题，但 HLS 的独立 AXI 主机
会直接看到错序的输入、权重和 64 位偏置。

`outputs/acx720_yolo_conv1_fifo_order_fix.bit` 在写 DDR 前和读 DDR 后
分别修正 16 位字序，并保留 CRC 与前 32 字节 UDP 回传。布局布线 WNS
`+0.638 ns`、TNS `0`、DRC `0 Errors`。该版本尚未上板验证；验收标准
是电脑收到 `FPGA output crc32=1ea472ba ... match=True`。

## 重建当前实验版

```powershell
cd board\acx720_yolo_board
D:\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -source check_axi_fabric.tcl
D:\Xilinx\Vivado\2018.3\bin\vivado.bat -mode batch -source build_weight_upload_bit.tcl
```

## 能力边界

当前实验 bitstream 是“图片/第一层权重接收 + DDR3 整帧读回 CRC”版本，不是完整的
YOLOv5n 推理 bitstream。用户提供的模型已确认为 640x640、20 类、60 层
INT8 网络，量化权重已打包为 `yolov5n_int8_weights.bin`，逐层地址、
scale/zero-point 和卷积参数位于 `yolov5n_int8_manifest.json`。Q28 偏置
卷积 IP 已通过仿真并接通板级 DDR3 数据路径，但 AXI-Lite 启动控制、
卷积结果校验、整网调度、检测头回传和 NMS 仍未完成。
