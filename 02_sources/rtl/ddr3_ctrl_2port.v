module ddr3_ctrl_2port #(
  parameter DW            = 16,
  parameter WR_ADDR_BEGIN = 0,
  parameter WR_ADDR_END   = 1024,
  parameter RD_ADDR_BEGIN = 0,
  parameter RD_ADDR_END   = 1024
)
(
  //clock reset
  input           ddr3_clk200m  ,
  input           ddr3_rst_n    ,
  input           upload_weights,
  input [1:0]     weight_page,
  input           output_read_mode,
  input           npu_start_toggle,
  output          npu_done,
  output          npu_error,
  output          ddr3_init_done,
  //wr_fifo Interface
  input           wrfifo_clr    ,
  input           wrfifo_clk    ,
  input           wrfifo_wren   ,
  input  [DW-1:0] wrfifo_din    ,
  output          wrfifo_full   ,
  output [15:0]   wrfifo_wr_cnt ,
  //rd_fifo Interface
  input           rdfifo_clr    ,
  input           rdfifo_clk    ,
  input           rdfifo_rden   ,
  output [DW-1:0] rdfifo_dout   ,
  output          rdfifo_empty  ,
  output [15:0]   rdfifo_rd_cnt ,
  //DDR3 Interface
  // Inouts
  inout  [15:0]   ddr3_dq       ,
  inout  [1:0]    ddr3_dqs_n    ,
  inout  [1:0]    ddr3_dqs_p    ,
  // Outputs      
  output [13:0]   ddr3_addr     ,
  output [2:0]    ddr3_ba       ,
  output          ddr3_ras_n    ,
  output          ddr3_cas_n    ,
  output          ddr3_we_n     ,
  output          ddr3_reset_n  ,
  output [0:0]    ddr3_ck_p     ,
  output [0:0]    ddr3_ck_n     ,
  output [0:0]    ddr3_cke      ,
  output [0:0]    ddr3_cs_n     ,
  output [1:0]    ddr3_dm       ,
  output [0:0]    ddr3_odt      
);

  wire          wrfifo_rden;
  wire [127:0]  wrfifo_dout;
  wire [127:0]  wrfifo_dout_ordered;
  wire [5 : 0]  wrfifo_rd_cnt;
  wire          wrfifo_empty;
  wire          wrfifo_wr_rst_busy;
  wire          wrfifo_rd_rst_busy;

  wire          rdfifo_wren;
  wire [127:0]  rdfifo_din_raw;
  wire [127:0]  rdfifo_din_ordered;
  wire [5 : 0]  rdfifo_wr_cnt;
  wire          rdfifo_full;
  wire          rdfifo_wr_rst_busy;
  wire          rdfifo_rd_rst_busy;

  wire          ui_clk;
  wire          ui_clk_sync_rst;
  wire          mmcm_locked;
  wire          init_calib_complete;
  (* ASYNC_REG = "TRUE" *) reg weight_mode_meta;
  (* ASYNC_REG = "TRUE" *) reg [1:0] weight_page_meta, weight_page_ui;
  (* ASYNC_REG = "TRUE" *) reg weight_mode_ui;
  (* ASYNC_REG = "TRUE" *) reg output_mode_meta;
  (* ASYNC_REG = "TRUE" *) reg output_mode_ui;
  reg           wrfifo_clr_sync_ui_clk;
  reg           wr_addr_clr;
  reg           rdfifo_clr_sync_ui_clk;
  reg           rd_addr_clr;

  wire [3:0]    s_axi_awid;
  wire [27:0]   s_axi_awaddr;
  wire [7:0]    s_axi_awlen;
  wire [2:0]    s_axi_awsize;
  wire [1:0]    s_axi_awburst;
  wire [0:0]    s_axi_awlock;
  wire [3:0]    s_axi_awcache;
  wire [2:0]    s_axi_awprot;
  wire [3:0]    s_axi_awqos;
  wire          s_axi_awvalid;
  wire          s_axi_awready;

  wire [127:0]  s_axi_wdata;
  wire [15:0]   s_axi_wstrb;
  wire          s_axi_wlast;
  wire          s_axi_wvalid;
  wire          s_axi_wready;

  wire [3:0]    s_axi_bid;
  wire [1:0]    s_axi_bresp;
  wire          s_axi_bvalid;
  wire          s_axi_bready;

  wire [3:0]    s_axi_arid;
  wire [27:0]   s_axi_araddr;
  wire [7:0]    s_axi_arlen;
  wire [2:0]    s_axi_arsize;
  wire [1:0]    s_axi_arburst;
  wire [0:0]    s_axi_arlock;
  wire [3:0]    s_axi_arcache;
  wire [2:0]    s_axi_arprot;
  wire [3:0]    s_axi_arqos;
  wire          s_axi_arvalid;
  wire          s_axi_arready;

  wire [3:0]    s_axi_rid;
  wire [127:0]  s_axi_rdata;
  wire [1:0]    s_axi_rresp;
  wire          s_axi_rlast;
  wire          s_axi_rvalid;
  wire          s_axi_rready;

  assign ddr3_init_done = mmcm_locked && init_calib_complete;

  // Xilinx asymmetric FIFOs present the first 16-bit word at the opposite
  // end of a 128-bit beat. Reverse the eight words at both DDR boundaries so
  // byte addresses agree with independent AXI masters such as the HLS NPU.
  assign wrfifo_dout_ordered = {
      wrfifo_dout[15:0], wrfifo_dout[31:16],
      wrfifo_dout[47:32], wrfifo_dout[63:48],
      wrfifo_dout[79:64], wrfifo_dout[95:80],
      wrfifo_dout[111:96], wrfifo_dout[127:112]};
  assign rdfifo_din_ordered = {
      rdfifo_din_raw[15:0], rdfifo_din_raw[31:16],
      rdfifo_din_raw[47:32], rdfifo_din_raw[63:48],
      rdfifo_din_raw[79:64], rdfifo_din_raw[95:80],
      rdfifo_din_raw[111:96], rdfifo_din_raw[127:112]};

  // The first DDR burst follows the frame header by at least 512 bytes.
  always @(posedge ui_clk or posedge ui_clk_sync_rst) begin
    if (ui_clk_sync_rst) begin
      weight_mode_meta <= 1'b0;
      weight_page_meta <= 2'd0;
      weight_page_ui <= 2'd0;
      weight_mode_ui <= 1'b0;
      output_mode_meta <= 1'b0;
      output_mode_ui <= 1'b0;
    end else begin
      weight_mode_meta <= upload_weights;
      weight_page_meta <= weight_page;
      weight_page_ui <= weight_page_meta;
      weight_mode_ui <= weight_mode_meta;
      output_mode_meta <= output_read_mode;
      output_mode_ui <= output_mode_meta;
    end
  end

  wr_ddr3_fifo wr_ddr3_fifo
  (
    .rst           (wrfifo_clr         ), // input  wire rst
    .wr_clk        (wrfifo_clk         ), // input  wire wr_clk
    .rd_clk        (ui_clk             ), // input  wire rd_clk
    .din           (wrfifo_din         ), // input  wire [15 : 0] din
    .wr_en         (wrfifo_wren        ), // input  wire wr_en
    .rd_en         (wrfifo_rden        ), // input  wire rd_en
    .dout          (wrfifo_dout        ), // output wire [127 : 0] dout
    .full          (wrfifo_full        ), // output wire full
    .empty         (wrfifo_empty       ), // output wire empty
    .rd_data_count (wrfifo_rd_cnt      ), // output wire [5 : 0] rd_data_count
    .wr_data_count (wrfifo_wr_cnt      ), // output wire [8 : 0] wr_data_count
    .wr_rst_busy   (wrfifo_wr_rst_busy ), // output wire wr_rst_busy
    .rd_rst_busy   (wrfifo_rd_rst_busy )  // output wire rd_rst_busy
  );

  rd_ddr3_fifo rd_ddr3_fifo
  (
    .rst           (rdfifo_clr         ), // input wire rst
    .wr_clk        (ui_clk             ), // input wire wr_clk
    .rd_clk        (rdfifo_clk         ), // input wire rd_clk
    .din           (rdfifo_din_ordered ), // input wire [127 : 0] din
    .wr_en         (rdfifo_wren        ), // input wire wr_en
    .rd_en         (rdfifo_rden        ), // input wire rd_en
    .dout          (rdfifo_dout        ), // output wire [15 : 0] dout
    .full          (rdfifo_full        ), // output wire full
    .empty         (rdfifo_empty       ), // output wire empty
    .rd_data_count (rdfifo_rd_cnt      ), // output wire [8 : 0] rd_data_count
    .wr_data_count (rdfifo_wr_cnt      ), // output wire [5 : 0] wr_data_count
    .wr_rst_busy   (rdfifo_wr_rst_busy ), // output wire wr_rst_busy
    .rd_rst_busy   (rdfifo_rd_rst_busy )  // output wire rd_rst_busy
  );

  always@(posedge ui_clk)
  begin
    wrfifo_clr_sync_ui_clk <= wrfifo_clr;
    wr_addr_clr <= wrfifo_clr_sync_ui_clk;
  end

  always@(posedge ui_clk)
  begin
    rdfifo_clr_sync_ui_clk <= rdfifo_clr;
    rd_addr_clr <= rdfifo_clr_sync_ui_clk;
  end

  fifo2mig_axi
  #(
    .WR_DDR_BYTE_ADDR_BEGIN (WR_ADDR_BEGIN*(DW/8) ),
    .WR_DDR_BYTE_ADDR_END   (WR_ADDR_END  *(DW/8) ),
    .RD_DDR_BYTE_ADDR_BEGIN (RD_ADDR_BEGIN*(DW/8) ),
    .RD_DDR_BYTE_ADDR_END   (RD_ADDR_END  *(DW/8) ),
    .AXI_LEN                (8'd31                ),
    .AXI_ID                 (4'b0000              )
  )fifo2mig_axi
  (
    //FIFO Interface ports
    .wr_addr_clr         (wr_addr_clr         ), //1:clear sync ui_clk
    .weight_mode         (weight_mode_ui      ),
    .output_read_mode    (output_mode_ui      ),
    .weight_page         (weight_page_ui      ),
    .wr_fifo_rdreq       (wrfifo_rden         ),
    .wr_fifo_rddata      (wrfifo_dout_ordered ),
    .wr_fifo_empty       (wrfifo_empty        ),
    .wr_fifo_rd_cnt      (wrfifo_rd_cnt       ),
    .wr_fifo_rst_busy    (wrfifo_wr_rst_busy | wrfifo_rd_rst_busy),

    .rd_addr_clr         (rd_addr_clr         ), //1:clear sync ui_clk
    .rd_fifo_wrreq       (rdfifo_wren         ),
    .rd_fifo_wrdata      (rdfifo_din_raw      ),
    .rd_fifo_alfull      (rdfifo_full         ),
    .rd_fifo_wr_cnt      (rdfifo_wr_cnt       ),
    .rd_fifo_rst_busy    (rdfifo_wr_rst_busy | rdfifo_rd_rst_busy),
    // Application interface ports
    .ui_clk              (ui_clk              ),
    .ui_clk_sync_rst     (ui_clk_sync_rst     ),
    .mmcm_locked         (mmcm_locked         ),
    .init_calib_complete (init_calib_complete ),
    // Slave Interface Write Address Ports
    .m_axi_awid          (s_axi_awid          ),
    .m_axi_awaddr        (s_axi_awaddr        ),
    .m_axi_awlen         (s_axi_awlen         ),
    .m_axi_awsize        (s_axi_awsize        ),
    .m_axi_awburst       (s_axi_awburst       ),
    .m_axi_awlock        (s_axi_awlock        ),
    .m_axi_awcache       (s_axi_awcache       ),
    .m_axi_awprot        (s_axi_awprot        ),
    .m_axi_awqos         (s_axi_awqos         ),
    .m_axi_awvalid       (s_axi_awvalid       ),
    .m_axi_awready       (s_axi_awready       ),
    // Slave Interface Write Data Ports
    .m_axi_wdata         (s_axi_wdata         ),
    .m_axi_wstrb         (s_axi_wstrb         ),
    .m_axi_wlast         (s_axi_wlast         ),
    .m_axi_wvalid        (s_axi_wvalid        ),
    .m_axi_wready        (s_axi_wready        ),
    // Slave Interface Write Response Ports
    .m_axi_bid           (s_axi_bid           ),
    .m_axi_bresp         (s_axi_bresp         ),
    .m_axi_bvalid        (s_axi_bvalid        ),
    .m_axi_bready        (s_axi_bready        ),
    // Slave Interface Read Address Ports
    .m_axi_arid          (s_axi_arid          ),
    .m_axi_araddr        (s_axi_araddr        ),
    .m_axi_arlen         (s_axi_arlen         ),
    .m_axi_arsize        (s_axi_arsize        ),
    .m_axi_arburst       (s_axi_arburst       ),
    .m_axi_arlock        (s_axi_arlock        ),
    .m_axi_arcache       (s_axi_arcache       ),
    .m_axi_arprot        (s_axi_arprot        ),
    .m_axi_arqos         (s_axi_arqos         ),
    .m_axi_arvalid       (s_axi_arvalid       ),
    .m_axi_arready       (s_axi_arready       ),
    // Slave Interface Read Data Ports
    .m_axi_rid           (s_axi_rid           ),
    .m_axi_rdata         (s_axi_rdata         ),
    .m_axi_rresp         (s_axi_rresp         ),
    .m_axi_rlast         (s_axi_rlast         ),
    .m_axi_rvalid        (s_axi_rvalid        ),
    .m_axi_rready        (s_axi_rready        )
  );

  // Ingress is S00. S01 is reserved for the NPU data-width converter.
  // Both masters and MIG use the MIG-generated ui_clk.
  assign s_axi_bid[3:1] = 3'b000;
  assign s_axi_rid[3:1] = 3'b000;
  wire [3:0] mig_axi_awid;
  wire [31:0] mig_axi_awaddr;
  wire [7:0] mig_axi_awlen;
  wire [2:0] mig_axi_awsize;
  wire [1:0] mig_axi_awburst;
  wire mig_axi_awlock;
  wire [3:0] mig_axi_awcache;
  wire [2:0] mig_axi_awprot;
  wire [3:0] mig_axi_awqos;
  wire mig_axi_awvalid;
  wire mig_axi_awready;
  wire [127:0] mig_axi_wdata;
  wire [15:0] mig_axi_wstrb;
  wire mig_axi_wlast;
  wire mig_axi_wvalid;
  wire mig_axi_wready;
  wire [3:0] mig_axi_bid;
  wire [1:0] mig_axi_bresp;
  wire mig_axi_bvalid;
  wire mig_axi_bready;
  wire [3:0] mig_axi_arid;
  wire [31:0] mig_axi_araddr;
  wire [7:0] mig_axi_arlen;
  wire [2:0] mig_axi_arsize;
  wire [1:0] mig_axi_arburst;
  wire mig_axi_arlock;
  wire [3:0] mig_axi_arcache;
  wire [2:0] mig_axi_arprot;
  wire [3:0] mig_axi_arqos;
  wire mig_axi_arvalid;
  wire mig_axi_arready;
  wire [3:0] mig_axi_rid;
  wire [127:0] mig_axi_rdata;
  wire [1:0] mig_axi_rresp;
  wire mig_axi_rlast;
  wire mig_axi_rvalid;
  wire mig_axi_rready;

  // The HLS AXI-Lite control is held idle until a board-side launcher is added.
  // This instance proves resource integration, not inference functionality.
  wire [31:0] npu64_awaddr;
  wire [7:0] npu64_awlen;
  wire [2:0] npu64_awsize;
  wire [1:0] npu64_awburst;
  wire [1:0] npu64_awlock;
  wire [3:0] npu64_awregion;
  wire [3:0] npu64_awcache;
  wire [2:0] npu64_awprot;
  wire [3:0] npu64_awqos;
  wire npu64_awvalid;
  wire npu64_awready;
  wire [63:0] npu64_wdata;
  wire [7:0] npu64_wstrb;
  wire npu64_wlast;
  wire npu64_wvalid;
  wire npu64_wready;
  wire [1:0] npu64_bresp;
  wire npu64_bvalid;
  wire npu64_bready;
  wire [31:0] npu64_araddr;
  wire [7:0] npu64_arlen;
  wire [2:0] npu64_arsize;
  wire [1:0] npu64_arburst;
  wire [1:0] npu64_arlock;
  wire [3:0] npu64_arregion;
  wire [3:0] npu64_arcache;
  wire [2:0] npu64_arprot;
  wire [3:0] npu64_arqos;
  wire npu64_arvalid;
  wire npu64_arready;
  wire [63:0] npu64_rdata;
  wire [1:0] npu64_rresp;
  wire npu64_rlast;
  wire npu64_rvalid;
  wire npu64_rready;
  wire [31:0] npu128_awaddr;
  wire [7:0] npu128_awlen;
  wire [2:0] npu128_awsize;
  wire [1:0] npu128_awburst;
  wire npu128_awlock;
  wire [3:0] npu128_awcache;
  wire [2:0] npu128_awprot;
  wire [3:0] npu128_awregion;
  wire [3:0] npu128_awqos;
  wire npu128_awvalid;
  wire npu128_awready;
  wire [127:0] npu128_wdata;
  wire [15:0] npu128_wstrb;
  wire npu128_wlast;
  wire npu128_wvalid;
  wire npu128_wready;
  wire [1:0] npu128_bresp;
  wire npu128_bvalid;
  wire npu128_bready;
  wire [31:0] npu128_araddr;
  wire [7:0] npu128_arlen;
  wire [2:0] npu128_arsize;
  wire [1:0] npu128_arburst;
  wire npu128_arlock;
  wire [3:0] npu128_arcache;
  wire [2:0] npu128_arprot;
  wire [3:0] npu128_arregion;
  wire [3:0] npu128_arqos;
  wire npu128_arvalid;
  wire npu128_arready;
  wire [127:0] npu128_rdata;
  wire [1:0] npu128_rresp;
  wire npu128_rlast;
  wire npu128_rvalid;
  wire npu128_rready;

  // Start crosses from the 100 MHz board state machine to MIG ui_clk.
  (* ASYNC_REG = "TRUE" *) reg npu_start_meta, npu_start_sync;
  reg npu_start_seen;
  always @(posedge ui_clk or posedge ui_clk_sync_rst) begin
    if (ui_clk_sync_rst) begin
      npu_start_meta <= 1'b0;
      npu_start_sync <= 1'b0;
      npu_start_seen <= 1'b0;
    end else begin
      npu_start_meta <= npu_start_toggle;
      npu_start_sync <= npu_start_meta;
      npu_start_seen <= npu_start_sync;
    end
  end
  wire npu_start_pulse = npu_start_sync ^ npu_start_seen;
  wire [7:0] ctrl_awaddr;
  wire ctrl_awvalid;
  wire ctrl_awready;
  wire [31:0] ctrl_wdata;
  wire [3:0] ctrl_wstrb;
  wire ctrl_wvalid;
  wire ctrl_wready;
  wire [1:0] ctrl_bresp;
  wire ctrl_bvalid;
  wire ctrl_bready;
  wire [7:0] ctrl_araddr;
  wire ctrl_arvalid;
  wire ctrl_arready;
  wire [31:0] ctrl_rdata;
  wire [1:0] ctrl_rresp;
  wire ctrl_rvalid;
  wire ctrl_rready;

`ifdef NPU_REALTIME320
  npu_realtime320_launcher u_npu_first_layer_launcher (
`else
  npu_complete_layer_launcher u_npu_first_layer_launcher (
`endif
    .clk(ui_clk), .rst_n(~ui_clk_sync_rst), .start(npu_start_pulse),
    .busy(), .done(npu_done), .error(npu_error),
    .awaddr(ctrl_awaddr),
    .awvalid(ctrl_awvalid),
    .awready(ctrl_awready),
    .wdata(ctrl_wdata),
    .wstrb(ctrl_wstrb),
    .wvalid(ctrl_wvalid),
    .wready(ctrl_wready),
    .bresp(ctrl_bresp),
    .bvalid(ctrl_bvalid),
    .bready(ctrl_bready),
    .araddr(ctrl_araddr),
    .arvalid(ctrl_arvalid),
    .arready(ctrl_arready),
    .rdata(ctrl_rdata),
    .rresp(ctrl_rresp),
    .rvalid(ctrl_rvalid),
    .rready(ctrl_rready)
  );

  yolo_npu_conv u_yolo_npu_conv (
    .s_axi_control_AWADDR(ctrl_awaddr),
    .s_axi_control_AWVALID(ctrl_awvalid),
    .s_axi_control_AWREADY(ctrl_awready),
    .s_axi_control_WDATA(ctrl_wdata),
    .s_axi_control_WSTRB(ctrl_wstrb),
    .s_axi_control_WVALID(ctrl_wvalid),
    .s_axi_control_WREADY(ctrl_wready),
    .s_axi_control_BRESP(ctrl_bresp),
    .s_axi_control_BVALID(ctrl_bvalid),
    .s_axi_control_BREADY(ctrl_bready),
    .s_axi_control_ARADDR(ctrl_araddr),
    .s_axi_control_ARVALID(ctrl_arvalid),
    .s_axi_control_ARREADY(ctrl_arready),
    .s_axi_control_RDATA(ctrl_rdata),
    .s_axi_control_RRESP(ctrl_rresp),
    .s_axi_control_RVALID(ctrl_rvalid),
    .s_axi_control_RREADY(ctrl_rready),
    .ap_clk(ui_clk),
    .ap_rst_n(~ui_clk_sync_rst),
    .interrupt(),
    .m_axi_gmem0_AWADDR(npu64_awaddr),
    .m_axi_gmem0_AWLEN(npu64_awlen),
    .m_axi_gmem0_AWSIZE(npu64_awsize),
    .m_axi_gmem0_AWBURST(npu64_awburst),
    .m_axi_gmem0_AWLOCK(npu64_awlock),
    .m_axi_gmem0_AWREGION(npu64_awregion),
    .m_axi_gmem0_AWCACHE(npu64_awcache),
    .m_axi_gmem0_AWPROT(npu64_awprot),
    .m_axi_gmem0_AWQOS(npu64_awqos),
    .m_axi_gmem0_AWVALID(npu64_awvalid),
    .m_axi_gmem0_AWREADY(npu64_awready),
    .m_axi_gmem0_WDATA(npu64_wdata),
    .m_axi_gmem0_WSTRB(npu64_wstrb),
    .m_axi_gmem0_WLAST(npu64_wlast),
    .m_axi_gmem0_WVALID(npu64_wvalid),
    .m_axi_gmem0_WREADY(npu64_wready),
    .m_axi_gmem0_BRESP(npu64_bresp),
    .m_axi_gmem0_BVALID(npu64_bvalid),
    .m_axi_gmem0_BREADY(npu64_bready),
    .m_axi_gmem0_ARADDR(npu64_araddr),
    .m_axi_gmem0_ARLEN(npu64_arlen),
    .m_axi_gmem0_ARSIZE(npu64_arsize),
    .m_axi_gmem0_ARBURST(npu64_arburst),
    .m_axi_gmem0_ARLOCK(npu64_arlock),
    .m_axi_gmem0_ARREGION(npu64_arregion),
    .m_axi_gmem0_ARCACHE(npu64_arcache),
    .m_axi_gmem0_ARPROT(npu64_arprot),
    .m_axi_gmem0_ARQOS(npu64_arqos),
    .m_axi_gmem0_ARVALID(npu64_arvalid),
    .m_axi_gmem0_ARREADY(npu64_arready),
    .m_axi_gmem0_RDATA(npu64_rdata),
    .m_axi_gmem0_RRESP(npu64_rresp),
    .m_axi_gmem0_RLAST(npu64_rlast),
    .m_axi_gmem0_RVALID(npu64_rvalid),
    .m_axi_gmem0_RREADY(npu64_rready)
  );

  yolo_npu_axi_dwidth u_yolo_npu_axi_dwidth (
    .s_axi_aclk(ui_clk),
    .s_axi_aresetn(~ui_clk_sync_rst),
    .s_axi_awid(1'b0),
    .s_axi_awaddr(npu64_awaddr),
    .s_axi_awlen(npu64_awlen),
    .s_axi_awsize(npu64_awsize),
    .s_axi_awburst(npu64_awburst),
    .s_axi_awlock(npu64_awlock[0]),
    .s_axi_awcache(npu64_awcache),
    .s_axi_awprot(npu64_awprot),
    .s_axi_awregion(npu64_awregion),
    .s_axi_awqos(npu64_awqos),
    .s_axi_awvalid(npu64_awvalid),
    .s_axi_awready(npu64_awready),
    .s_axi_wdata(npu64_wdata),
    .s_axi_wstrb(npu64_wstrb),
    .s_axi_wlast(npu64_wlast),
    .s_axi_wvalid(npu64_wvalid),
    .s_axi_wready(npu64_wready),
    .s_axi_bid(),
    .s_axi_bresp(npu64_bresp),
    .s_axi_bvalid(npu64_bvalid),
    .s_axi_bready(npu64_bready),
    .s_axi_arid(1'b0),
    .s_axi_araddr(npu64_araddr),
    .s_axi_arlen(npu64_arlen),
    .s_axi_arsize(npu64_arsize),
    .s_axi_arburst(npu64_arburst),
    .s_axi_arlock(npu64_arlock[0]),
    .s_axi_arcache(npu64_arcache),
    .s_axi_arprot(npu64_arprot),
    .s_axi_arregion(npu64_arregion),
    .s_axi_arqos(npu64_arqos),
    .s_axi_arvalid(npu64_arvalid),
    .s_axi_arready(npu64_arready),
    .s_axi_rid(),
    .s_axi_rdata(npu64_rdata),
    .s_axi_rresp(npu64_rresp),
    .s_axi_rlast(npu64_rlast),
    .s_axi_rvalid(npu64_rvalid),
    .s_axi_rready(npu64_rready),
    .m_axi_awaddr(npu128_awaddr),
    .m_axi_awlen(npu128_awlen),
    .m_axi_awsize(npu128_awsize),
    .m_axi_awburst(npu128_awburst),
    .m_axi_awlock(npu128_awlock),
    .m_axi_awcache(npu128_awcache),
    .m_axi_awprot(npu128_awprot),
    .m_axi_awregion(npu128_awregion),
    .m_axi_awqos(npu128_awqos),
    .m_axi_awvalid(npu128_awvalid),
    .m_axi_awready(npu128_awready),
    .m_axi_wdata(npu128_wdata),
    .m_axi_wstrb(npu128_wstrb),
    .m_axi_wlast(npu128_wlast),
    .m_axi_wvalid(npu128_wvalid),
    .m_axi_wready(npu128_wready),
    .m_axi_bresp(npu128_bresp),
    .m_axi_bvalid(npu128_bvalid),
    .m_axi_bready(npu128_bready),
    .m_axi_araddr(npu128_araddr),
    .m_axi_arlen(npu128_arlen),
    .m_axi_arsize(npu128_arsize),
    .m_axi_arburst(npu128_arburst),
    .m_axi_arlock(npu128_arlock),
    .m_axi_arcache(npu128_arcache),
    .m_axi_arprot(npu128_arprot),
    .m_axi_arregion(npu128_arregion),
    .m_axi_arqos(npu128_arqos),
    .m_axi_arvalid(npu128_arvalid),
    .m_axi_arready(npu128_arready),
    .m_axi_rdata(npu128_rdata),
    .m_axi_rresp(npu128_rresp),
    .m_axi_rlast(npu128_rlast),
    .m_axi_rvalid(npu128_rvalid),
    .m_axi_rready(npu128_rready)
  );

  yolo_ddr_axi_interconnect u_yolo_ddr_axi_interconnect (
    .INTERCONNECT_ACLK(ui_clk),
    .INTERCONNECT_ARESETN(~ui_clk_sync_rst),
    .S00_AXI_ARESET_OUT_N(),
    .S00_AXI_ACLK(ui_clk),
    .S00_AXI_AWID(s_axi_awid[0]),
    .S00_AXI_AWADDR({4'b0000, s_axi_awaddr}),
    .S00_AXI_AWLEN(s_axi_awlen),
    .S00_AXI_AWSIZE(s_axi_awsize),
    .S00_AXI_AWBURST(s_axi_awburst),
    .S00_AXI_AWLOCK(s_axi_awlock),
    .S00_AXI_AWCACHE(s_axi_awcache),
    .S00_AXI_AWPROT(s_axi_awprot),
    .S00_AXI_AWQOS(s_axi_awqos),
    .S00_AXI_AWVALID(s_axi_awvalid),
    .S00_AXI_AWREADY(s_axi_awready),
    .S00_AXI_WDATA(s_axi_wdata),
    .S00_AXI_WSTRB(s_axi_wstrb),
    .S00_AXI_WLAST(s_axi_wlast),
    .S00_AXI_WVALID(s_axi_wvalid),
    .S00_AXI_WREADY(s_axi_wready),
    .S00_AXI_BID(s_axi_bid[0]),
    .S00_AXI_BRESP(s_axi_bresp),
    .S00_AXI_BVALID(s_axi_bvalid),
    .S00_AXI_BREADY(s_axi_bready),
    .S00_AXI_ARID(s_axi_arid[0]),
    .S00_AXI_ARADDR({4'b0000, s_axi_araddr}),
    .S00_AXI_ARLEN(s_axi_arlen),
    .S00_AXI_ARSIZE(s_axi_arsize),
    .S00_AXI_ARBURST(s_axi_arburst),
    .S00_AXI_ARLOCK(s_axi_arlock),
    .S00_AXI_ARCACHE(s_axi_arcache),
    .S00_AXI_ARPROT(s_axi_arprot),
    .S00_AXI_ARQOS(s_axi_arqos),
    .S00_AXI_ARVALID(s_axi_arvalid),
    .S00_AXI_ARREADY(s_axi_arready),
    .S00_AXI_RID(s_axi_rid[0]),
    .S00_AXI_RDATA(s_axi_rdata),
    .S00_AXI_RRESP(s_axi_rresp),
    .S00_AXI_RLAST(s_axi_rlast),
    .S00_AXI_RVALID(s_axi_rvalid),
    .S00_AXI_RREADY(s_axi_rready),
    .S01_AXI_ARESET_OUT_N(),
    .S01_AXI_ACLK(ui_clk),
    .S01_AXI_AWID(1'b0),
    .S01_AXI_AWADDR(npu128_awaddr),
    .S01_AXI_AWLEN(npu128_awlen),
    .S01_AXI_AWSIZE(npu128_awsize),
    .S01_AXI_AWBURST(npu128_awburst),
    .S01_AXI_AWLOCK(npu128_awlock),
    .S01_AXI_AWCACHE(npu128_awcache),
    .S01_AXI_AWPROT(npu128_awprot),
    .S01_AXI_AWQOS(npu128_awqos),
    .S01_AXI_AWVALID(npu128_awvalid),
    .S01_AXI_AWREADY(npu128_awready),
    .S01_AXI_WDATA(npu128_wdata),
    .S01_AXI_WSTRB(npu128_wstrb),
    .S01_AXI_WLAST(npu128_wlast),
    .S01_AXI_WVALID(npu128_wvalid),
    .S01_AXI_WREADY(npu128_wready),
    .S01_AXI_BID(),
    .S01_AXI_BRESP(npu128_bresp),
    .S01_AXI_BVALID(npu128_bvalid),
    .S01_AXI_BREADY(npu128_bready),
    .S01_AXI_ARID(1'b0),
    .S01_AXI_ARADDR(npu128_araddr),
    .S01_AXI_ARLEN(npu128_arlen),
    .S01_AXI_ARSIZE(npu128_arsize),
    .S01_AXI_ARBURST(npu128_arburst),
    .S01_AXI_ARLOCK(npu128_arlock),
    .S01_AXI_ARCACHE(npu128_arcache),
    .S01_AXI_ARPROT(npu128_arprot),
    .S01_AXI_ARQOS(npu128_arqos),
    .S01_AXI_ARVALID(npu128_arvalid),
    .S01_AXI_ARREADY(npu128_arready),
    .S01_AXI_RID(),
    .S01_AXI_RDATA(npu128_rdata),
    .S01_AXI_RRESP(npu128_rresp),
    .S01_AXI_RLAST(npu128_rlast),
    .S01_AXI_RVALID(npu128_rvalid),
    .S01_AXI_RREADY(npu128_rready),
    .M00_AXI_ARESET_OUT_N(),
    .M00_AXI_ACLK(ui_clk),
    .M00_AXI_AWID(mig_axi_awid),
    .M00_AXI_AWADDR(mig_axi_awaddr),
    .M00_AXI_AWLEN(mig_axi_awlen),
    .M00_AXI_AWSIZE(mig_axi_awsize),
    .M00_AXI_AWBURST(mig_axi_awburst),
    .M00_AXI_AWLOCK(mig_axi_awlock),
    .M00_AXI_AWCACHE(mig_axi_awcache),
    .M00_AXI_AWPROT(mig_axi_awprot),
    .M00_AXI_AWQOS(mig_axi_awqos),
    .M00_AXI_AWVALID(mig_axi_awvalid),
    .M00_AXI_AWREADY(mig_axi_awready),
    .M00_AXI_WDATA(mig_axi_wdata),
    .M00_AXI_WSTRB(mig_axi_wstrb),
    .M00_AXI_WLAST(mig_axi_wlast),
    .M00_AXI_WVALID(mig_axi_wvalid),
    .M00_AXI_WREADY(mig_axi_wready),
    .M00_AXI_BID(mig_axi_bid),
    .M00_AXI_BRESP(mig_axi_bresp),
    .M00_AXI_BVALID(mig_axi_bvalid),
    .M00_AXI_BREADY(mig_axi_bready),
    .M00_AXI_ARID(mig_axi_arid),
    .M00_AXI_ARADDR(mig_axi_araddr),
    .M00_AXI_ARLEN(mig_axi_arlen),
    .M00_AXI_ARSIZE(mig_axi_arsize),
    .M00_AXI_ARBURST(mig_axi_arburst),
    .M00_AXI_ARLOCK(mig_axi_arlock),
    .M00_AXI_ARCACHE(mig_axi_arcache),
    .M00_AXI_ARPROT(mig_axi_arprot),
    .M00_AXI_ARQOS(mig_axi_arqos),
    .M00_AXI_ARVALID(mig_axi_arvalid),
    .M00_AXI_ARREADY(mig_axi_arready),
    .M00_AXI_RID(mig_axi_rid),
    .M00_AXI_RDATA(mig_axi_rdata),
    .M00_AXI_RRESP(mig_axi_rresp),
    .M00_AXI_RLAST(mig_axi_rlast),
    .M00_AXI_RVALID(mig_axi_rvalid),
    .M00_AXI_RREADY(mig_axi_rready)
  );

  mig_7series_0 u_mig_7series_0 (
    // Memory interface ports
    .ddr3_addr            (ddr3_addr           ),  // output [13:0]   ddr3_addr
    .ddr3_ba              (ddr3_ba             ),  // output [2:0]    ddr3_ba
    .ddr3_cas_n           (ddr3_cas_n          ),  // output          ddr3_cas_n
    .ddr3_ck_n            (ddr3_ck_n           ),  // output [0:0]    ddr3_ck_n
    .ddr3_ck_p            (ddr3_ck_p           ),  // output [0:0]    ddr3_ck_p
    .ddr3_cke             (ddr3_cke            ),  // output [0:0]    ddr3_cke
    .ddr3_ras_n           (ddr3_ras_n          ),  // output          ddr3_ras_n
    .ddr3_reset_n         (ddr3_reset_n        ),  // output          ddr3_reset_n
    .ddr3_we_n            (ddr3_we_n           ),  // output          ddr3_we_n
    .ddr3_dq              (ddr3_dq             ),  // inout [15:0]    ddr3_dq
    .ddr3_dqs_n           (ddr3_dqs_n          ),  // inout [1:0]     ddr3_dqs_n
    .ddr3_dqs_p           (ddr3_dqs_p          ),  // inout [1:0]     ddr3_dqs_p
    .init_calib_complete  (init_calib_complete ),  // output          init_calib_complete
    .ddr3_cs_n            (ddr3_cs_n           ),  // output [0:0]    ddr3_cs_n
    .ddr3_dm              (ddr3_dm             ),  // output [1:0]    ddr3_dm
    .ddr3_odt             (ddr3_odt            ),  // output [0:0]    ddr3_odt
    // Application interface ports
    .ui_clk               (ui_clk              ),  // output          ui_clk
    .ui_clk_sync_rst      (ui_clk_sync_rst     ),  // output          ui_clk_sync_rst
    .mmcm_locked          (mmcm_locked         ),  // output          mmcm_locked
    .aresetn              (ddr3_rst_n          ),  // input           aresetn
    .app_sr_req           (1'b0                ),  // input           app_sr_req
    .app_ref_req          (1'b0                ),  // input           app_ref_req
    .app_zq_req           (1'b0                ),  // input           app_zq_req
    .app_sr_active        (                    ),  // output          app_sr_active
    .app_ref_ack          (                    ),  // output          app_ref_ack
    .app_zq_ack           (                    ),  // output          app_zq_ack
    // Slave Interface Write Address Ports
    .s_axi_awid           (mig_axi_awid          ),  // input [3:0]     s_axi_awid
    .s_axi_awaddr         (mig_axi_awaddr[27:0]        ),  // input [27:0]    s_axi_awaddr
    .s_axi_awlen          (mig_axi_awlen         ),  // input [7:0]     s_axi_awlen
    .s_axi_awsize         (mig_axi_awsize        ),  // input [2:0]     s_axi_awsize
    .s_axi_awburst        (mig_axi_awburst       ),  // input [1:0]     s_axi_awburst
    .s_axi_awlock         (mig_axi_awlock        ),  // input [0:0]     s_axi_awlock
    .s_axi_awcache        (mig_axi_awcache       ),  // input [3:0]     s_axi_awcache
    .s_axi_awprot         (mig_axi_awprot        ),  // input [2:0]     s_axi_awprot
    .s_axi_awqos          (mig_axi_awqos         ),  // input [3:0]     s_axi_awqos
    .s_axi_awvalid        (mig_axi_awvalid       ),  // input           s_axi_awvalid
    .s_axi_awready        (mig_axi_awready       ),  // output          s_axi_awready
    // Slave Interface Write Data Ports
    .s_axi_wdata          (mig_axi_wdata         ),  // input [127:0]   s_axi_wdata
    .s_axi_wstrb          (mig_axi_wstrb         ),  // input [15:0]    s_axi_wstrb
    .s_axi_wlast          (mig_axi_wlast         ),  // input           s_axi_wlast
    .s_axi_wvalid         (mig_axi_wvalid        ),  // input           s_axi_wvalid
    .s_axi_wready         (mig_axi_wready        ),  // output          s_axi_wready
    // Slave Interface Write Response Ports
    .s_axi_bid            (mig_axi_bid           ),  // output [3:0]    s_axi_bid
    .s_axi_bresp          (mig_axi_bresp         ),  // output [1:0]    s_axi_bresp
    .s_axi_bvalid         (mig_axi_bvalid        ),  // output          s_axi_bvalid
    .s_axi_bready         (mig_axi_bready        ),  // input           s_axi_bready
    // Slave Interface Read Address Ports
    .s_axi_arid           (mig_axi_arid          ),  // input [3:0]     s_axi_arid
    .s_axi_araddr         (mig_axi_araddr[27:0]        ),  // input [27:0]    s_axi_araddr
    .s_axi_arlen          (mig_axi_arlen         ),  // input [7:0]     s_axi_arlen
    .s_axi_arsize         (mig_axi_arsize        ),  // input [2:0]     s_axi_arsize
    .s_axi_arburst        (mig_axi_arburst       ),  // input [1:0]     s_axi_arburst
    .s_axi_arlock         (mig_axi_arlock        ),  // input [0:0]     s_axi_arlock
    .s_axi_arcache        (mig_axi_arcache       ),  // input [3:0]     s_axi_arcache
    .s_axi_arprot         (mig_axi_arprot        ),  // input [2:0]     s_axi_arprot
    .s_axi_arqos          (mig_axi_arqos         ),  // input [3:0]     s_axi_arqos
    .s_axi_arvalid        (mig_axi_arvalid       ),  // input           s_axi_arvalid
    .s_axi_arready        (mig_axi_arready       ),  // output          s_axi_arready
    // Slave Interface Read Data Ports
    .s_axi_rid            (mig_axi_rid           ),  // output [3:0]    s_axi_rid
    .s_axi_rdata          (mig_axi_rdata         ),  // output [127:0]  s_axi_rdata
    .s_axi_rresp          (mig_axi_rresp         ),  // output [1:0]    s_axi_rresp
    .s_axi_rlast          (mig_axi_rlast         ),  // output          s_axi_rlast
    .s_axi_rvalid         (mig_axi_rvalid        ),  // output          s_axi_rvalid
    .s_axi_rready         (mig_axi_rready        ),  // input           s_axi_rready
    // System Clock Ports
    .sys_clk_i            (ddr3_clk200m        ),
    .sys_rst              (ddr3_rst_n          )   // input sys_rst
  );

endmodule
