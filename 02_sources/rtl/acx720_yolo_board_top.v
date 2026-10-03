`timescale 1ns/1ps

// ACX720-V3 (XC7A35T) board ingress design.
// UDP payload format is defined by sw/host/eth_protocol.py. Valid 640x640 RGB888
// image bytes are stripped from the 24-byte application header, packed into
// 16-bit words and committed to DDR3 through the official two-port MIG wrapper.
module acx720_yolo_board_top(
    input Clk, input reset_n,
    inout [15:0] ddr3_dq, inout [1:0] ddr3_dqs_n,
    inout [1:0] ddr3_dqs_p, output [13:0] ddr3_addr,
    output [2:0] ddr3_ba, output ddr3_ras_n, output ddr3_cas_n,
    output ddr3_we_n, output ddr3_reset_n, output [0:0] ddr3_ck_p,
    output [0:0] ddr3_ck_n, output [0:0] ddr3_cke,
    output [0:0] ddr3_cs_n, output [1:0] ddr3_dm,
    output [0:0] ddr3_odt,
    output ad7606_cs_n_o, output ad7606_rd_n_o,
    input ad7606_busy_i, input [15:0] ad7606_db_i,
    output [2:0] ad7606_os_o, output ad7606_reset_o,
    output ad7606_convst_o,
    input rgmii_rx_clk_i, input [3:0] rgmii_rxd, input rgmii_rxdv,
    output rgmii_tx_clk, output [3:0] rgmii_txd, output rgmii_txen,
    output eth_reset_n, output [1:0] led
);
    localparam [47:0] LOCAL_MAC = 48'h00_0a_35_01_fe_c0;
    localparam [31:0] LOCAL_IP  = 32'hc0_a8_00_02;
    localparam [15:0] LOCAL_PORT = 16'd5000;

    wire clk_100m, clk_200m, pll_locked;
    wire rgmii_rx_clk, gmii_rx_clk, clk125m;
    wire [7:0] gmii_rxd, udp_data;
    wire gmii_rxdv, udp_valid, udp_done;
    wire ddr3_init_done, wrfifo_full;
    wire [7:0] image_byte;
    wire image_valid, frame_start, frame_done, packet_error;
    wire payload_is_weight;
    reg upload_weights;
    reg [1:0] weight_page;
    reg report_is_weight;
    wire [31:0] frame_id;
    wire [15:0] packet_index, total_packets;
    reg byte_phase;
    reg [7:0] low_byte;
    reg [15:0] ddr_word;
    reg ddr_word_valid;
    reg frame_seen, error_seen;
    (* ASYNC_REG = "TRUE" *) reg ddr_init_meta, ddr_init_rx;
    localparam [19:0] FRAME_WORDS = 20'd614400;
`ifdef NPU_REALTIME320
    localparam [19:0] IMAGE_WORDS = 20'd614400;
    localparam [19:0] OUTPUT_WORDS = 20'd75648;
`else
    localparam [19:0] IMAGE_WORDS = FRAME_WORDS;
    localparam [19:0] OUTPUT_WORDS = 20'd315008; // Three heads + 16-byte DDR alignment gap.
`endif
    // Internal CRC state before the conventional final XOR.
    localparam [31:0] GOLDEN_INPUT_CRC = 32'h5f5583a0;
    localparam [31:0] GOLDEN_OUTPUT_CRC = 32'h98a0080c;
    wire [15:0] read_word;
    wire read_empty;
    reg read_active, read_pending, read_verified, read_bad;
    reg [16:0] read_wait;
    reg [19:0] read_count;
    reg [31:0] ingress_crc, expected_crc, read_crc;
    reg frame_done_d1, frame_done_d2, frame_toggle;
    (* ASYNC_REG = "TRUE" *) reg frame_toggle_meta, frame_toggle_sync;
    reg frame_toggle_seen;
    (* ASYNC_REG = "TRUE" *) reg weight_mode_meta_100m, weight_mode_sync_100m;
    (* ASYNC_REG = "TRUE" *) reg npu_done_meta, npu_done_sync;
    (* ASYNC_REG = "TRUE" *) reg npu_error_meta, npu_error_sync;
    reg weight_verified, npu_start_toggle, npu_phase_started;
    reg golden_input_verified, output_read_mode, output_verified;
    reg output_read_complete;
    reg [25:0] diagnostic_counter;
    reg [31:0] output_crc_report;
    reg output_crc_toggle;
    reg npu_done_prev;
    wire npu_done, npu_error;
    wire tensor_ready, tensor_complete, tensor_tx_start, tensor_tx_active;
    wire [15:0] tensor_payload_length;
    wire [7:0] tensor_payload_data;
    wire tensor_start = npu_phase_started && npu_done_sync && !npu_done_prev && !npu_error_sync;
    wire read_word_valid = read_active && !read_empty && (!output_read_mode || tensor_ready);

    function [31:0] crc_byte;
        input [31:0] crc_in;
        input [7:0] data_in;
        reg [31:0] c;
        integer bit_index;
        begin
            c = crc_in ^ data_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                c = c[0] ? (c >> 1) ^ 32'hedb88320 : (c >> 1);
            crc_byte = c;
        end
    endfunction

    function [31:0] crc_word;
        input [31:0] crc_in;
        input [15:0] data_in;
        begin
            crc_word = crc_byte(crc_byte(crc_in, data_in[7:0]), data_in[15:8]);
        end
    endfunction

    assign eth_reset_n = 1'b1;
    // LED0 means ap_done, not a host-side numerical comparison or detection score.
    assign led = {ddr3_init_done,
                  npu_phase_started ?
                  (npu_done_sync & ~npu_error_sync) :
                  (read_bad ? diagnostic_counter[25] : read_verified)};
    // Unused ADC connector is held inactive/safe.
    assign ad7606_cs_n_o = 1'b1;
    assign ad7606_rd_n_o = 1'b1;
    assign ad7606_os_o = 3'b000;
    assign ad7606_reset_o = 1'b0;
    assign ad7606_convst_o = 1'b1;
    mmcm u_mmcm(.clk_out1(clk_200m), .clk_out2(clk_100m),
                .resetn(reset_n), .locked(pll_locked), .clk_in1(Clk));
    clk_wiz_0 u_rxclk(.clk_out1(rgmii_rx_clk), .clk_in1(rgmii_rx_clk_i));
    rgmii_to_gmii u_rgmii_rx(
        .reset(~reset_n), .rgmii_rx_clk(rgmii_rx_clk),
        .rgmii_rxd(rgmii_rxd), .rgmii_rxdv(rgmii_rxdv),
        .gmii_rx_clk(gmii_rx_clk), .gmii_rxdv(gmii_rxdv),
        .gmii_rxd(gmii_rxd), .gmii_rxer());
    eth_udp_rx_gmii u_udp_rx(
        .reset_n(reset_n), .gmii_rx_clk(gmii_rx_clk),
        .gmii_rxdv(gmii_rxdv), .gmii_rxd(gmii_rxd), .clk125m_o(clk125m),
        .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP), .local_port(LOCAL_PORT),
        .exter_mac(), .exter_ip(), .exter_port(), .rx_data_length(),
        .data_overflow_i(1'b0), .payload_valid_o(udp_valid),
        .payload_dat_o(udp_data), .one_pkt_done(udp_done),
        .pkt_error(), .debug_crc_check());

    yolo_packet_parser u_parser(
        .clk(clk125m), .rst(~reset_n), .s_data(udp_data),
        .s_valid(udp_valid), .s_last(udp_done), .s_ready(),
        .payload_data(image_byte), .payload_valid(image_valid),
        .frame_id(frame_id), .packet_index(packet_index),
        .total_packets(total_packets), .frame_start(frame_start),
        .payload_is_weight(payload_is_weight),
        .frame_done(frame_done), .packet_error(packet_error));

    always @(posedge clk125m) begin
        if(!reset_n) begin
            ddr_init_meta <= 1'b0; ddr_init_rx <= 1'b0;
            byte_phase <= 1'b0; low_byte <= 8'd0; ddr_word <= 16'd0;
            ddr_word_valid <= 1'b0; frame_seen <= 1'b0; error_seen <= 1'b0;
            ingress_crc <= 32'hffffffff;
            expected_crc <= 32'hffffffff;
            frame_done_d1 <= 1'b0; frame_done_d2 <= 1'b0;
            frame_toggle <= 1'b0;
            upload_weights <= 1'b0;
            weight_page <= 2'd0;
        end else begin
            ddr_init_meta <= ddr3_init_done;
            ddr_init_rx <= ddr_init_meta;
            ddr_word_valid <= 1'b0;
            if(frame_start) begin
                frame_seen <= 1'b0;
                error_seen <= 1'b0;
                upload_weights <= payload_is_weight;
                weight_page <= payload_is_weight ? frame_id[25:24] : 2'd0;
            end
            frame_done_d1 <= frame_done;
            frame_done_d2 <= frame_done_d1;
            if(frame_start) ingress_crc <= 32'hffffffff;
            else if(ddr_word_valid) ingress_crc <= crc_word(ingress_crc, ddr_word);
            if(frame_done_d2) begin
                expected_crc <= ingress_crc;
                frame_toggle <= ~frame_toggle;
            end
            if(packet_error) error_seen <= 1'b1;
            if(image_valid && ddr_init_rx && !wrfifo_full) begin
                if(!byte_phase) low_byte <= image_byte;
                else begin ddr_word <= {image_byte, low_byte}; ddr_word_valid <= 1'b1; end
                byte_phase <= ~byte_phase;
            end
            if(frame_done) frame_seen <= 1'b1;
        end
    end

    always @(posedge clk_100m) begin
        if (!reset_n || !ddr3_init_done) begin
            frame_toggle_meta <= 1'b0;
            frame_toggle_sync <= 1'b0;
            frame_toggle_seen <= 1'b0;
            read_active <= 1'b0;
            read_pending <= 1'b0;
            read_wait <= 17'd0;
            read_verified <= 1'b0;
            read_bad <= 1'b0;
            read_count <= 20'd0;
            read_crc <= 32'hffffffff;
            weight_mode_meta_100m <= 1'b0;
            weight_mode_sync_100m <= 1'b0;
            npu_done_meta <= 1'b0;
            npu_done_sync <= 1'b0;
            npu_error_meta <= 1'b0;
            npu_error_sync <= 1'b0;
            weight_verified <= 1'b0;
            npu_start_toggle <= 1'b0;
            npu_phase_started <= 1'b0;
            golden_input_verified <= 1'b0;
            output_read_mode <= 1'b0;
            output_verified <= 1'b0;
            output_read_complete <= 1'b0;
            diagnostic_counter <= 26'd0;
            output_crc_report <= 32'd0;
            report_is_weight <= 1'b0;
            output_crc_toggle <= 1'b0;
            npu_done_prev <= 1'b0;
        end else begin
            diagnostic_counter <= diagnostic_counter + 1'b1;
            weight_mode_meta_100m <= upload_weights;
            weight_mode_sync_100m <= weight_mode_meta_100m;
            npu_done_meta <= npu_done;
            npu_done_sync <= npu_done_meta;
            npu_error_meta <= npu_error;
            npu_error_sync <= npu_error_meta;
            npu_done_prev <= npu_done_sync;
            frame_toggle_meta <= frame_toggle;
            frame_toggle_sync <= frame_toggle_meta;
            if (frame_toggle_sync != frame_toggle_seen) begin
                frame_toggle_seen <= frame_toggle_sync;
                // Let the final write FIFO burst drain before DDR readback.
                read_pending <= 1'b1;
                read_active <= 1'b0;
                read_wait <= 17'd100000;
                read_verified <= 1'b0;
                read_bad <= 1'b0;
                read_count <= 20'd0;
                read_crc <= 32'hffffffff;
                npu_phase_started <= 1'b0;
                golden_input_verified <= 1'b0;
                output_read_mode <= 1'b0;
                output_verified <= 1'b0;
                output_read_complete <= 1'b0;
            end else if (tensor_start) begin
                // Stream all three detection heads only after the full graph finishes.
                output_read_mode <= 1'b1;
                read_pending <= 1'b1;
                read_active <= 1'b0;
                read_wait <= 17'd100000;
                read_count <= 20'd0;
                read_crc <= 32'hffffffff;
                output_verified <= 1'b0;
                output_read_complete <= 1'b0;
            end else if (read_pending) begin
                if (read_wait == 17'd0) begin
                    read_pending <= 1'b0;
                    read_active <= 1'b1;
                end else read_wait <= read_wait - 1'b1;
            end else if (read_word_valid) begin
                read_crc <= crc_word(read_crc, read_word);
                read_count <= read_count + 1'b1;
                if (read_count == (output_read_mode ? OUTPUT_WORDS :
                    (weight_mode_sync_100m ? FRAME_WORDS : IMAGE_WORDS)) - 1'b1) begin
                    read_active <= 1'b0;
                    if (output_read_mode) begin
                        output_read_complete <= 1'b1;
                        // Packetizer owns the data checksum and UDP completion handshake.
                        output_verified <= 1'b0;
                    end else begin
                    read_verified <= (crc_word(read_crc, read_word) == expected_crc);
                    read_bad <= (crc_word(read_crc, read_word) != expected_crc);
                    if (crc_word(read_crc, read_word) == expected_crc) begin
                        if (weight_mode_sync_100m) begin
                            weight_verified <= 1'b1;
                            report_is_weight <= 1'b1;
                            output_crc_report <= crc_word(read_crc, read_word) ^ 32'hffffffff;
                            output_crc_toggle <= ~output_crc_toggle;
                        end
                        else if (weight_verified) begin
                            golden_input_verified <=
                                (crc_word(read_crc, read_word) == GOLDEN_INPUT_CRC);
                            npu_start_toggle <= ~npu_start_toggle;
                            npu_phase_started <= 1'b1;
                        end
                    end
                    end
                end
            end
        end
    end

    // Weight ACKs retain WGT1. Image results use DAT1 raw tensor packets.
    // Broadcast destination MAC avoids dependence on FPGA-side ARP support.
    (* ASYNC_REG = "TRUE" *) reg crc_toggle_meta, crc_toggle_sync;
    reg crc_toggle_seen;
    reg [5:0] crc_payload_index;
    wire crc_tx_start = crc_toggle_sync ^ crc_toggle_seen;
    wire crc_payload_req;
    wire crc_tx_done;
    wire gmii_tx_clk;
    wire gmii_txen;
    wire [7:0] gmii_txd;
    reg [7:0] crc_payload_data;

    always @(*) begin
        case (crc_payload_index)
            0: crc_payload_data = report_is_weight ? 8'h57 : 8'h43;
            1: crc_payload_data = report_is_weight ? 8'h47 : 8'h52;
            2: crc_payload_data = report_is_weight ? 8'h54 : 8'h43;
            3: crc_payload_data = 8'h31; // 1
            4: crc_payload_data = output_crc_report[31:24];
            5: crc_payload_data = output_crc_report[23:16];
            6: crc_payload_data = output_crc_report[15:8];
            7: crc_payload_data = output_crc_report[7:0];
            default: crc_payload_data = 8'h00;
        endcase
    end

    always @(posedge clk125m) begin
        if (!reset_n) begin
            crc_toggle_meta <= 1'b0;
            crc_toggle_sync <= 1'b0;
            crc_toggle_seen <= 1'b0;
            crc_payload_index <= 6'd0;
        end else begin
            crc_toggle_meta <= output_crc_toggle;
            crc_toggle_sync <= crc_toggle_meta;
            if (crc_tx_start) begin
                crc_toggle_seen <= crc_toggle_sync;
                crc_payload_index <= 6'd0;
            end else if (crc_payload_req && !tensor_tx_active && crc_payload_index < 6'd39) begin
                crc_payload_index <= crc_payload_index + 1'b1;
            end
        end
    end

    yolo_tensor_packetizer #(.TOTAL_WORDS(OUTPUT_WORDS)) u_tensor_packetizer(
        .clk(clk_100m), .tx_clk(clk125m), .reset_n(reset_n), .start(tensor_start),
        .frame_id(frame_id), .word_data(read_word),
        .word_valid(read_word_valid && output_read_mode), .word_ready(tensor_ready),
        .complete(tensor_complete), .tx_start(tensor_tx_start), .tx_done(crc_tx_done),
        .payload_req(crc_payload_req), .payload_length(tensor_payload_length),
        .payload_data(tensor_payload_data), .tx_active(tensor_tx_active));

    wire tensor_select = tensor_tx_active || tensor_tx_start;
    eth_udp_tx_gmii u_crc_udp_tx(
        .clk125M(clk125m), .reset_n(reset_n),
        .tx_en_pulse(crc_tx_start || tensor_tx_start), .tx_done(crc_tx_done),
        .dst_mac(48'hff_ff_ff_ff_ff_ff), .src_mac(LOCAL_MAC),
        .dst_ip(32'hc0_a8_00_03), .src_ip(LOCAL_IP),
        .dst_port(16'd6102), .src_port(LOCAL_PORT),
        .data_length(tensor_select ? tensor_payload_length : 16'd40), .payload_req_o(crc_payload_req),
        .payload_dat_i(tensor_select ? tensor_payload_data : crc_payload_data), .gmii_tx_clk(gmii_tx_clk),
        .gmii_txen(gmii_txen), .gmii_txd(gmii_txd));

    gmii_to_rgmii u_crc_gmii_to_rgmii(
        .reset_n(reset_n), .gmii_tx_clk(gmii_tx_clk),
        .gmii_txd(gmii_txd), .gmii_txen(gmii_txen), .gmii_txer(1'b0),
        .rgmii_tx_clk(rgmii_tx_clk), .rgmii_txd(rgmii_txd),
        .rgmii_txen(rgmii_txen));

    ddr3_ctrl_2port #(
        // Address parameters count 16-bit words, not image bytes.
        // One 640x640x3 frame occupies exactly 614400 words.
        .DW(16), .WR_ADDR_BEGIN(0), .WR_ADDR_END(FRAME_WORDS-1),
        .RD_ADDR_BEGIN(0), .RD_ADDR_END(FRAME_WORDS-1)
    ) u_ddr3(
        .ddr3_clk200m(clk_200m), .ddr3_rst_n(pll_locked),
        .upload_weights(upload_weights),
        .weight_page(weight_page),
        .output_read_mode(output_read_mode),
        .ddr3_init_done(ddr3_init_done), .wrfifo_clr(~ddr3_init_done),
        .npu_start_toggle(npu_start_toggle),
        .npu_done(npu_done), .npu_error(npu_error),
        .wrfifo_clk(clk125m), .wrfifo_wren(ddr_word_valid),
        .wrfifo_din(ddr_word), .wrfifo_full(wrfifo_full), .wrfifo_wr_cnt(),
        .rdfifo_clr(~read_active), .rdfifo_clk(clk_100m),
        .rdfifo_rden(read_word_valid),
        .rdfifo_dout(read_word), .rdfifo_empty(read_empty), .rdfifo_rd_cnt(),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n),
        .ddr3_dqs_p(ddr3_dqs_p), .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
        .ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cke(ddr3_cke), .ddr3_cs_n(ddr3_cs_n),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt));
endmodule
