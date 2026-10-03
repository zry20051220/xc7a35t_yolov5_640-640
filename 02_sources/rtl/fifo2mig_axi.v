
module fifo2mig_axi
#(
  parameter WR_DDR_BYTE_ADDR_BEGIN = 0      ,   //写数据起始地址
  parameter WR_DDR_BYTE_ADDR_END   = 200    ,   //写数据结束地址   
  parameter RD_DDR_BYTE_ADDR_BEGIN = 0      ,   //读数据起始地址
  parameter RD_DDR_BYTE_ADDR_END   = 200    ,   //读数据的结束地址
  parameter AXI_LEN                = 8'd31,     //burst length = 32，需要写入的数据的长度
  parameter AXI_ID                 = 4'b0000    //对应ID号
)
(
  //FIFO Interface ports（FIFO对应端口信号）
  input               wr_addr_clr         ,     //写FIFO清空控制信号，执行清空操作的时候需要保证3个及以上时钟周期的高电平
  input               weight_mode         ,     // 1 selects the 4 MiB weight region
  input [1:0]         weight_page         ,
  input               output_read_mode    ,     // 1 reads conv1 output at 2 MiB
  output              wr_fifo_rdreq       ,     //FIFO的写请求
  input     [127:0]   wr_fifo_rddata      ,     //FIFO需要写入的数据
  input               wr_fifo_empty       ,     //FIFO为空标志信号
  input     [5:0]     wr_fifo_rd_cnt      ,     //写FIF0的数据计数
  input               wr_fifo_rst_busy    ,     //写时钟复位忙信号（为1表示复位中，为0表示复位完成）

  input               rd_addr_clr         ,     //读FIFO清空控制信号，执行清空操作的时候需要保证3个及以上时钟周期的高电平          
  output              rd_fifo_wrreq       ,     //FIFO的读请求                                        
  output    [127:0]   rd_fifo_wrdata      ,     //FIFO读取到的数据                                      
  input               rd_fifo_alfull      ,     //FIFO为空标志信号                                      
  input     [5:0]     rd_fifo_wr_cnt      ,     //读FIF0的读计数                                       
  input               rd_fifo_rst_busy    ,     //读时钟复位忙信号（为1表示复位中，为0表示复位完成）                      
  // Application interface ports（DDR3的用户接口）
  input               ui_clk              ,     //用户侧时钟信号
  input               ui_clk_sync_rst     ,     //用户侧复位信号
  input               mmcm_locked         ,     //PLL锁定信号：为1表示锁定
  input               init_calib_complete ,     // DDR 控制器对外部 DDR3 存储器初始化和校准完成信号：为1表示完成，可以对DDR3进行读写
  // Slave Interface Write Address Ports（从接口写地址接口）
  output    [3:0]     m_axi_awid          ,     //写地址ID
  output reg[27:0]    m_axi_awaddr        ,     //一次突发传输的写地址
  output    [7:0]     m_axi_awlen         ,     //突发写数据长度
  output    [2:0]     m_axi_awsize        ,     //突发写数据的大小
  output    [1:0]     m_axi_awburst       ,     //突发写类型;
  output    [0:0]     m_axi_awlock        ,     //锁类型
  output    [3:0]     m_axi_awcache       ,     //cache类型
  output    [2:0]     m_axi_awprot        ,     //保护类型
  output    [3:0]     m_axi_awqos         ,     //质量服务
  output reg          m_axi_awvalid       ,     //写地址有效信号
  input               m_axi_awready       ,     //写地址准备好信号
  // Slave Interface Write Data Ports（写数通道信号）
  output    [127:0]   m_axi_wdata         ,     //写的数据
  output    [15:0]    m_axi_wstrb         ,     //写数据有效的字节阀门
  output reg          m_axi_wlast         ,     //传输的最后一个数据传输
  output reg          m_axi_wvalid        ,     //写有效
  input               m_axi_wready        ,     //写就绪
  // Slave Interface Write Response Ports（写响应通道信号）
  input     [3:0]     m_axi_bid           ,     //写响应ID
  input     [1:0]     m_axi_bresp         ,     //写响应，2'b00： OKAY， 2'b01： EXOKAY， 2'b10： SLVERR， 2'b11：DECERR。
  input               m_axi_bvalid        ,     //写响应有效
  output              m_axi_bready        ,     //接收响应就绪
  // Slave Interface Read Address Ports（读地址接口）
  output    [3:0]     m_axi_arid          ,      //读地址ID                      
  output reg[27:0]    m_axi_araddr        ,      //一次突发传输的读地址          
  output    [7:0]     m_axi_arlen         ,      //突发读数据长度                    
  output    [2:0]     m_axi_arsize        ,      //突发读数据的大小                   
  output    [1:0]     m_axi_arburst       ,      //突发读类型                      
  output    [0:0]     m_axi_arlock        ,      //锁类型                        
  output    [3:0]     m_axi_arcache       ,      //cache类型                    
  output    [2:0]     m_axi_arprot        ,      //保护类型                       
  output    [3:0]     m_axi_arqos         ,      //质量服务                       
  output reg          m_axi_arvalid       ,      //读地址有效信号                    
  input               m_axi_arready       ,      //读地址准备好信号                   
  // Slave Interface Read Data Ports（读数据端口信号）
  input     [3:0]     m_axi_rid           ,      //读ID
  input     [127:0]   m_axi_rdata         ,      //读的数据                    
  input     [1:0]     m_axi_rresp         ,      //读响应   
  input               m_axi_rlast         ,      //读传输最后一个数据
  input               m_axi_rvalid        ,      //读数据有效
  output              m_axi_rready               //读数据就绪
);
    localparam S_IDLE    = 7'b0000001,      //空闲状态
               S_ARB     = 7'b0000010,      //读写仲裁状态
               S_WR_ADDR = 7'b0000100,      //写地址状态
               S_WR_DATA = 7'b0001000,      //写数据状态
               S_WR_RESP = 7'b0010000,      //等待写响应
               S_RD_ADDR = 7'b0100000,      //读地址状态
               S_RD_RESP = 7'b1000000;      //等待读响应
               
               
    reg [6:0] status; //定义所需状态
    reg [6:0] nxt_status;
    
    wire wr_ddr3_req;
    wire rd_ddr3_req;
    
    reg      wr_rd_poll  ;  //0:allow wr  1:allow rd
    wire[5:0]wr_req_cnt_thresh;
    wire[5:0]rd_req_cnt_thresh;
    reg [7:0]wr_data_cnt ;
    reg weight_mode_d;
    reg output_read_mode_d;
    reg [1:0] weight_page_d;
    wire wr_mode_change = (weight_mode ^ weight_mode_d) |
                          (weight_mode && (weight_page != weight_page_d));
    wire [27:0] weight_begin = 28'h0400000 + weight_page * 28'h012c000;
    wire rd_mode_change = wr_mode_change | (output_read_mode ^ output_read_mode_d);
`ifdef NPU_REALTIME320
    // Image length changes, but uploaded weight pages remain 0x12c000 bytes.
    wire [27:0] wr_begin = weight_mode ? weight_begin : 28'd0;
    wire [27:0] wr_end = weight_mode ? weight_begin + 28'h012bffe : 28'd1228798;
    wire [27:0] rd_begin = output_read_mode ? 28'h1923800 : weight_mode ? weight_begin : 28'd0;
    wire [27:0] rd_end = output_read_mode ? 28'h19486fe :
        weight_mode ? weight_begin + 28'h012bffe : 28'd1228798;
`else
    wire [27:0] wr_begin = weight_mode ? weight_begin : WR_DDR_BYTE_ADDR_BEGIN;
    wire [27:0] wr_end = weight_mode ?
        (weight_begin + WR_DDR_BYTE_ADDR_END - WR_DDR_BYTE_ADDR_BEGIN) :
        WR_DDR_BYTE_ADDR_END;
    wire [27:0] rd_begin = output_read_mode ? 28'h1923800 :
        weight_mode ? weight_begin : RD_DDR_BYTE_ADDR_BEGIN;
    wire [27:0] rd_end = output_read_mode ? 28'h19bd4fe : weight_mode ?
        (weight_begin + RD_DDR_BYTE_ADDR_END - RD_DDR_BYTE_ADDR_BEGIN) :
        RD_DDR_BYTE_ADDR_END;
`endif

    always @(posedge ui_clk or posedge ui_clk_sync_rst)
      if (ui_clk_sync_rst) begin
        weight_mode_d <= 1'b0;
        weight_page_d <= 2'd0;
        output_read_mode_d <= 1'b0;
      end else begin
        weight_mode_d <= weight_mode;
        weight_page_d <= weight_page;
        output_read_mode_d <= output_read_mode;
      end
    
    //AXI接口信号的产生
    //写操作
    assign m_axi_awid    = AXI_ID   ; //output [3:0]      m_axi_awid   
    assign m_axi_awsize  = 3'b100   ; //output [2:0]      m_axi_awsize 
    assign m_axi_awburst = 2'b01    ; //output [1:0]      m_axi_awburst
    assign m_axi_awlock  = 1'b0     ; //output [0:0]      m_axi_awlock 
    assign m_axi_awcache = 4'b0000  ; //output [3:0]      m_axi_awcache
    assign m_axi_awprot  = 3'b000   ; //output [2:0]      m_axi_awprot 
    assign m_axi_awqos   = 4'b0000  ; //output [3:0]      m_axi_awqos    
    assign m_axi_awlen   = AXI_LEN  ;
    
    assign m_axi_wstrb   = 16'hffff ; //output [15:0]     m_axi_wstrb 
    assign m_axi_wdata   = wr_fifo_rddata;
    
    assign m_axi_bready  = 1'b1     ; //output            m_axi_bready
    
    //读操作信号的产生
    assign m_axi_arid    = AXI_ID   ; //output [3:0]      m_axi_arid   
    assign m_axi_arsize  = 3'b100   ; //output [2:0]      m_axi_arsize 
    assign m_axi_arburst = 2'b01    ; //output [1:0]      m_axi_arburst
    assign m_axi_arlock  = 1'b0     ; //output [0:0]      m_axi_arlock 
    assign m_axi_arcache = 4'b0000  ; //output [3:0]      m_axi_arcache
    assign m_axi_arprot  = 3'b000   ; //output [2:0]      m_axi_arprot 
    assign m_axi_arqos   = 4'b0000  ; //output [3:0]      m_axi_arqos
    assign m_axi_arlen   = AXI_LEN  ;
    
    assign m_axi_rready  = ~rd_fifo_alfull; //output            m_axi_rready

    //读写FIFO接口的设置    
    assign wr_fifo_rdreq = m_axi_wvalid && m_axi_wready; //写FIFO请求信号
    assign rd_fifo_wrreq = m_axi_rvalid && m_axi_rready; //读FIFO请求信号
    assign rd_fifo_wrdata = m_axi_rdata;
    
    assign wr_req_cnt_thresh = (m_axi_awlen == 1'b0)? 1'b0 : AXI_LEN-1'b1;//写数据计数
    assign rd_req_cnt_thresh = AXI_LEN;
    assign wr_ddr3_req = (wr_fifo_rst_busy == 1'b0) && (wr_fifo_rd_cnt >= wr_req_cnt_thresh) ? 1'b1:1'b0;//当写入的数据超过AXI_LEN的值的时候产生写请求信号
    assign rd_ddr3_req = (rd_fifo_rst_busy == 1'b0) && (rd_fifo_wr_cnt <= rd_req_cnt_thresh) ? 1'b1:1'b0;//当读出的数据小于AXI_LEN的时候产生读请求信号
        
    //需要写入的地址m_axi_awaddr
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_awaddr <= WR_DDR_BYTE_ADDR_BEGIN;
      else if(wr_addr_clr || wr_mode_change)
        m_axi_awaddr <= wr_begin;
      else if(m_axi_awaddr >= wr_end)
        m_axi_awaddr <= wr_begin;
      else if((status == S_WR_RESP) && m_axi_bready && m_axi_bvalid && (m_axi_bresp == 2'b00) && (m_axi_bid == AXI_ID))
        m_axi_awaddr <= m_axi_awaddr + ((m_axi_awlen + 1'b1)<<4);
      else
        m_axi_awaddr <= m_axi_awaddr;
    end
    
    //写入地址有效信号m_axi_awvalid
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_awvalid <= 1'b0;
      else if((status == S_WR_ADDR) && m_axi_awready && m_axi_awvalid)
        m_axi_awvalid <= 1'b0;
      else if(status == S_WR_ADDR)
        m_axi_awvalid <= 1'b1;
      else
        m_axi_awvalid <= m_axi_awvalid;
    end

      //写有效m_axi_wvalid
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_wvalid <= 1'b0;
      else if((status == S_WR_DATA) && m_axi_wready && m_axi_wvalid && m_axi_wlast)
        m_axi_wvalid <= 1'b0;
      else if(status == S_WR_DATA)
        m_axi_wvalid <= 1'b1;
      else
        m_axi_wvalid <= m_axi_wvalid;
    end

     //wr_data_cnt  
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        wr_data_cnt <= 1'b0;
      else if(status == S_ARB)
        wr_data_cnt <= 1'b0;
      else if(status == S_WR_DATA && m_axi_wready && m_axi_wvalid)
        wr_data_cnt <= wr_data_cnt + 1'b1;
      else
        wr_data_cnt <= wr_data_cnt;
    end
        
    //传输最后一个字节的信号m_axi_wlast
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_wlast <= 1'b0;
      else if(status == S_WR_DATA && m_axi_wready && m_axi_wvalid && m_axi_wlast)
        m_axi_wlast <= 1'b0;
      else if(status == S_WR_DATA && m_axi_awlen == 8'd0)
        m_axi_wlast <= 1'b1;
      else if(status == S_WR_DATA && m_axi_wready && m_axi_wvalid && (wr_data_cnt == m_axi_awlen -1'b1))
        m_axi_wlast <= 1'b1;
      else
        m_axi_wlast <= m_axi_wlast;
    end    

    
    //一次突发传输的读地址m_axi_araddr，一次写操作完成之后地址增加（m_axi_arlen+1'b1 >> 4）
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_araddr <= RD_DDR_BYTE_ADDR_BEGIN;
      else if(rd_addr_clr || rd_mode_change)
        m_axi_araddr <= rd_begin;
      else if(m_axi_araddr >= rd_end)
        m_axi_araddr <= rd_begin;
      else if((status == S_RD_RESP) && m_axi_rready && m_axi_rvalid && m_axi_rlast && (m_axi_rresp == 2'b00) && (m_axi_rid == AXI_ID))
        m_axi_araddr <= m_axi_araddr + ((m_axi_awlen + 1'b1)<<4);
      else
        m_axi_araddr <= m_axi_araddr;
    end
     
    //读地址有效信号m_axi_arvalid
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        m_axi_arvalid <= 1'b0;
      else if((status == S_RD_ADDR) && m_axi_arready && m_axi_arvalid)
        m_axi_arvalid <= 1'b0;
      else if(status == S_RD_ADDR)
        m_axi_arvalid <= 1'b1;
      else
        m_axi_arvalid <= m_axi_arvalid;
    end
    
    always@(posedge ui_clk or posedge ui_clk_sync_rst)
    begin
      if(ui_clk_sync_rst)
        wr_rd_poll <= 1'b0;
      else if(status == S_ARB)
        wr_rd_poll <= ~wr_rd_poll;
      else
        wr_rd_poll <= wr_rd_poll;
    end
    
  always@(posedge ui_clk or posedge ui_clk_sync_rst)
  begin
    if(ui_clk_sync_rst)
      status <= S_IDLE;
    else
      status <= nxt_status;
  end

  always@(*)
  begin
    case(status)
      S_IDLE:
      begin
        if(mmcm_locked && init_calib_complete)
          nxt_status = S_ARB;
        else
          nxt_status = S_IDLE;
      end

      S_ARB:
      begin
        if((wr_ddr3_req == 1'b1) && (wr_rd_poll == 1'b0))
          nxt_status = S_WR_ADDR;
        else if((rd_ddr3_req == 1'b1) && (wr_rd_poll == 1'b1))
          nxt_status = S_RD_ADDR;
        else
          nxt_status = S_ARB;
      end

      S_WR_ADDR:
      begin
        if(m_axi_awready && m_axi_awvalid)
          nxt_status = S_WR_DATA;
        else
          nxt_status = S_WR_ADDR;
      end

      S_WR_DATA:
      begin
        if(m_axi_wready && m_axi_wvalid && m_axi_wlast)
          nxt_status = S_WR_RESP;
        else
          nxt_status = S_WR_DATA;
      end

      S_WR_RESP:
      begin
        if(m_axi_bready && m_axi_bvalid && (m_axi_bresp == 2'b00) && (m_axi_bid == AXI_ID))
          nxt_status = S_ARB;
        else if(m_axi_bready && m_axi_bvalid)
          nxt_status = S_IDLE;
        else
          nxt_status = S_WR_RESP;
      end

      S_RD_ADDR:
      begin
        if(m_axi_arready && m_axi_arvalid)
          nxt_status = S_RD_RESP;
        else
          nxt_status = S_RD_ADDR;
      end

      S_RD_RESP:
      begin
        if(m_axi_rready && m_axi_rvalid && m_axi_rlast && (m_axi_rresp == 2'b00) && (m_axi_rid == AXI_ID))
          nxt_status = S_ARB;
        else if(m_axi_rready && m_axi_rvalid && m_axi_rlast)
          nxt_status = S_IDLE;
        else
          nxt_status = S_RD_RESP;
      end

      default: nxt_status = S_IDLE;
    endcase
  end

endmodule
