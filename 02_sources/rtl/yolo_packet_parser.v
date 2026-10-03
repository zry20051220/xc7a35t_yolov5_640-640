`timescale 1ns/1ps
module yolo_packet_parser(
    input wire clk, input wire rst,
    input wire [7:0] s_data, input wire s_valid, input wire s_last,
    output reg s_ready,
    output reg [7:0] payload_data, output reg payload_valid,
    output reg [31:0] frame_id,
    output reg [15:0] packet_index, output reg [15:0] total_packets,
    output reg payload_is_weight,
    output reg frame_start, output reg frame_done, output reg packet_error
);
    reg [15:0] count;
    reg [15:0] payload_len;
    reg [31:0] magic;
    reg [7:0] version, msg_type, flags;
    reg [15:0] width, height;
`ifdef NPU_REALTIME320
    localparam IMAGE_SIZE = 640;
`else
    localparam IMAGE_SIZE = 640;
`endif
    always @(posedge clk) begin
        if (rst) begin
            count<=0; payload_len<=0; magic<=0; frame_id<=0;
            packet_index<=0; total_packets<=0; width<=0; height<=0;
            version<=0; msg_type<=0; flags<=0; payload_valid<=0;
            payload_is_weight<=0;
            frame_start<=0; frame_done<=0; packet_error<=0; s_ready<=1;
        end else begin
            payload_valid<=0; frame_start<=0; frame_done<=0;
            if (s_valid && s_ready) begin
                case(count)
                    0: magic[31:24]<=s_data; 1: magic[23:16]<=s_data;
                    2: magic[15:8]<=s_data; 3: magic[7:0]<=s_data;
                    4: version<=s_data; 5: msg_type<=s_data;
                    6: frame_id[31:24]<=s_data; 7: frame_id[23:16]<=s_data;
                    8: frame_id[15:8]<=s_data; 9: frame_id[7:0]<=s_data;
                    10: width[15:8]<=s_data; 11: width[7:0]<=s_data;
                    12: height[15:8]<=s_data; 13: height[7:0]<=s_data;
                    15: flags<=s_data;
                    16: total_packets[15:8]<=s_data; 17: total_packets[7:0]<=s_data;
                    18: packet_index[15:8]<=s_data; 19: packet_index[7:0]<=s_data;
                    22: payload_len[15:8]<=s_data;
                    23: begin
                        payload_len[7:0]<=s_data;
                        payload_is_weight <= (msg_type == 8'd2);
                        if(magic!=32'h594f4c4f || version!=1 ||
                           (msg_type!=1 && msg_type!=2) ||
                           (msg_type==1 && (width!=IMAGE_SIZE || height!=IMAGE_SIZE)) ||
                           (msg_type==2 && (width!=640 || height!=640)) ||
                           {payload_len[15:8],s_data}>1400)
                            packet_error<=1;
                        else begin packet_error<=0; if(packet_index==0) frame_start<=1; end
                    end
                    default: if(count>=24 && count<(24 + payload_len)) begin
                        payload_data<=s_data; payload_valid<=!packet_error;
                    end
                endcase
                count<=count+1;
            end
            if(s_last) begin
                if(!packet_error && flags[0]) frame_done<=1;
                count<=0;
            end
        end
    end
endmodule
