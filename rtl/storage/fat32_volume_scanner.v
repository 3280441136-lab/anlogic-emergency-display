// Adapted reference: 03第三方的课程资料/完赛篇/第七讲：FAT32文件系统升级/第6课_FAT32文件系统/fat32_volume_scanner.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    // PIC1..PIC6.BMP in the root directory (product 2026-11-02: six images).
    output reg  [5:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    // Product rewrite: stream BPB/MBR/directory fields; no 512-byte multi-read register array.
    // Sector CRC is verified before replay by the upstream adapter.
    localparam IDLE=0, REQ0=1, WAIT0=2, REQBOOT=3, WAITBOOT=4, PARSE=5,
       LAYOUT=6, ROOT_MINUS=7, ROOT_SHIFT=8, ROOT_ADD=9, ROOT_REQ=10,
       ROOT_WAIT=11, ROOT_NEXT=12, FAT_REQ=13, FAT_WAIT=14, FAT_PARSE=15, FINISH=16,
       FAT_CHECK=17;
    reg [4:0] state;
    reg [7:0] first_byte, spc, fats, partition_type;
    reg [15:0] bytes_per_sector,reserved,root_entries,fat16,signature;
    reg [31:0] total_sectors,fat_sectors,root_cluster,partition_start;
    reg [31:0] volume_base,fat_span,root_minus,root_scaled,root_next,cluster_count;
    reg [31:0] total_less_reserved,data_sector_count;
    reg [2:0] shift;
    reg [7:0] root_sector;
    reg [9:0] root_hops;
    reg [8:0] fat_offset;
    reg [87:0] name;
    reg entry_ok,name_ok,attr_ok;reg [7:0] bpb_checks;reg bpb_valid;
    reg [2:0] resource_index;
    reg [15:0] cluster_hi,cluster_lo;
    reg [31:0] size;
    // Timing: a matched entry is committed one cycle after its byte 31 through
    // registered per-resource enables; the FAT range check is registered before use.
    reg [5:0] commit_en;reg [31:0] commit_cluster,commit_size;reg root_next_bad;
    assign scan_busy=state!=IDLE;
    function [2:0] spc_shift;
     input [7:0] val;
     begin case(val)2:spc_shift=1;4:spc_shift=2;8:spc_shift=3;16:spc_shift=4;
      32:spc_shift=5;64:spc_shift=6;128:spc_shift=7;default:spc_shift=0;endcase end
    endfunction
    task fail;
     input [7:0] code;
     begin fs_error<=code;state<=FINISH;end
    endtask
    always @(posedge clk or negedge rst_n) begin
     if(!rst_n) begin
      state<=IDLE;scan_done<=0;fs_error<=0;partition_lba<=0;sectors_per_cluster<=0;
      fat_start_lba<=0;data_start_lba<=0;max_cluster<=0;resource_valid<=0;
      resource0_cluster<=0;resource1_cluster<=0;resource2_cluster<=0;resource3_cluster<=0;resource4_cluster<=0;resource5_cluster<=0;
      resource0_size<=0;resource1_size<=0;resource2_size<=0;resource3_size<=0;resource4_size<=0;resource5_size<=0;
      sector_req<=0;sector_lba<=0;first_byte<=0;spc<=0;fats<=0;partition_type<=0;
      bytes_per_sector<=0;reserved<=0;root_entries<=0;fat16<=0;signature<=0;
      total_sectors<=0;fat_sectors<=0;root_cluster<=0;partition_start<=0;volume_base<=0;
      total_less_reserved<=0;data_sector_count<=0;fat_span<=0;root_minus<=0;root_scaled<=0;root_next<=0;cluster_count<=0;
      shift<=0;root_sector<=0;root_hops<=0;fat_offset<=0;name<=0;
      bpb_checks<=0;bpb_valid<=0;entry_ok<=0;name_ok<=0;attr_ok<=0;resource_index<=0;cluster_hi<=0;cluster_lo<=0;size<=0;
      commit_en<=0;commit_cluster<=0;commit_size<=0;root_next_bad<=0;
     end else begin
      scan_done<=0;sector_req<=0;commit_en<=0;
      if(commit_en[0]) begin resource_valid[0]<=1;resource0_cluster<=commit_cluster;resource0_size<=commit_size;end
      if(commit_en[1]) begin resource_valid[1]<=1;resource1_cluster<=commit_cluster;resource1_size<=commit_size;end
      if(commit_en[2]) begin resource_valid[2]<=1;resource2_cluster<=commit_cluster;resource2_size<=commit_size;end
      if(commit_en[3]) begin resource_valid[3]<=1;resource3_cluster<=commit_cluster;resource3_size<=commit_size;end
      if(commit_en[4]) begin resource_valid[4]<=1;resource4_cluster<=commit_cluster;resource4_size<=commit_size;end
      if(commit_en[5]) begin resource_valid[5]<=1;resource5_cluster<=commit_cluster;resource5_size<=commit_size;end
      if(sector_valid&&(state==WAIT0||state==WAITBOOT)) begin
       case(sector_byte_index)
        0:first_byte<=sector_byte;
        11:bytes_per_sector[7:0]<=sector_byte;12:bytes_per_sector[15:8]<=sector_byte;
        13:spc<=sector_byte;14:reserved[7:0]<=sector_byte;15:reserved[15:8]<=sector_byte;
        16:fats<=sector_byte;17:root_entries[7:0]<=sector_byte;18:root_entries[15:8]<=sector_byte;
        22:fat16[7:0]<=sector_byte;23:fat16[15:8]<=sector_byte;
        32:total_sectors[7:0]<=sector_byte;33:total_sectors[15:8]<=sector_byte;
        34:total_sectors[23:16]<=sector_byte;35:total_sectors[31:24]<=sector_byte;
        36:fat_sectors[7:0]<=sector_byte;37:fat_sectors[15:8]<=sector_byte;
        38:fat_sectors[23:16]<=sector_byte;39:fat_sectors[31:24]<=sector_byte;
        44:root_cluster[7:0]<=sector_byte;45:root_cluster[15:8]<=sector_byte;
        46:root_cluster[23:16]<=sector_byte;47:root_cluster[31:24]<={4'd0,sector_byte[3:0]};
        450:partition_type<=sector_byte;
        454:partition_start[7:0]<=sector_byte;455:partition_start[15:8]<=sector_byte;
        456:partition_start[23:16]<=sector_byte;457:partition_start[31:24]<=sector_byte;
        64:begin
         fat_span<=fats==2?fat_sectors<<1:fat_sectors;
         total_less_reserved<=total_sectors-reserved;
         bpb_checks[0]<=bytes_per_sector==512;
         bpb_checks[1]<=spc!=0&&(spc&(spc-1'b1))==0;
         bpb_checks[2]<=reserved!=0;
         bpb_checks[3]<=fats==1||fats==2;
         bpb_checks[4]<=root_entries==0&&fat16==0;
         bpb_checks[5]<=fat_sectors!=0;
         bpb_checks[6]<=total_sectors!=0;
         bpb_checks[7]<=root_cluster>=2;
        end
        65:bpb_valid<=&bpb_checks;
        510:signature[7:0]<=sector_byte;511:signature[15:8]<=sector_byte;
        default:;
       endcase
      end
      if(sector_valid&&state==ROOT_WAIT) begin
       case(sector_byte_index[4:0])
        0:begin name[87:80]<=sector_byte;entry_ok<=0;end
        1:name[79:72]<=sector_byte;2:name[71:64]<=sector_byte;3:name[63:56]<=sector_byte;
        4:name[55:48]<=sector_byte;5:name[47:40]<=sector_byte;6:name[39:32]<=sector_byte;
        7:name[31:24]<=sector_byte;8:name[23:16]<=sector_byte;9:name[15:8]<=sector_byte;10:name[7:0]<=sector_byte;
        // Byte 11 is the attribute; the name is complete. Name and attribute checks are
        // registered separately and combined at byte 12 (timing: shared byte bus fanout).
        11:begin
         name_ok<=(name[87:64]==24'h504943 &&
                   name[63:56]>=8'h31&&name[63:56]<=8'h36&&
                   name[55:24]==32'h20202020&&name[23:0]==24'h424d50);
         attr_ok<=(sector_byte&8'h18)==0;
         resource_index<=name[58:56]-3'd1;
        end
        12:entry_ok<=name_ok&&attr_ok;
        20:cluster_hi[7:0]<=sector_byte;21:cluster_hi[15:8]<=sector_byte;
        26:cluster_lo[7:0]<=sector_byte;27:cluster_lo[15:8]<=sector_byte;
        28:size[7:0]<=sector_byte;29:size[15:8]<=sector_byte;30:size[23:16]<=sector_byte;
        31:begin
         commit_en<=entry_ok ? (6'b000001<<resource_index) : 6'b000000;
         commit_cluster<={4'd0,cluster_hi[11:0],cluster_lo};commit_size<={sector_byte,size[23:0]};
        end
        default:;
       endcase
      end
      if(sector_valid&&state==FAT_WAIT&&sector_byte_index[8:2]==fat_offset[8:2]) begin
       case(sector_byte_index[1:0])
        0:root_next[7:0]<=sector_byte;1:root_next[15:8]<=sector_byte;
        2:root_next[23:16]<=sector_byte;3:root_next[31:24]<={4'd0,sector_byte[3:0]};
       endcase
      end
      case(state)
       IDLE:if(scan_start) begin fs_error<=0;resource_valid<=0;volume_base<=0;partition_lba<=0;state<=REQ0;end
       REQ0:if(!sector_busy)begin sector_lba<=0;sector_req<=1;state<=WAIT0;end
       WAIT0:if(sector_done)begin
        if(sector_error!=0)fail(8'h10);
        else if(signature!=16'haa55)fail(8'h20);
        else if(first_byte==8'heb||first_byte==8'he9)state<=PARSE;
        else if(partition_type==8'h0b||partition_type==8'h0c)begin
         volume_base<=partition_start;partition_lba<=partition_start;state<=REQBOOT;
        end else fail(8'h21);
       end
       REQBOOT:if(!sector_busy)begin sector_lba<=volume_base;sector_req<=1;state<=WAITBOOT;end
       WAITBOOT:if(sector_done)begin
        if(sector_error!=0)fail(8'h10);else if(signature!=16'haa55)fail(8'h20);else state<=PARSE;
       end
       PARSE:begin
        if(!bpb_valid)fail(8'h21);
        else begin
         sectors_per_cluster<=spc;shift<=spc_shift(spc);
         fat_start_lba<=volume_base+reserved;state<=LAYOUT;
        end
       end
       LAYOUT:begin
        data_start_lba<=fat_start_lba+fat_span;
        data_sector_count<=total_less_reserved-fat_span;
        root_sector<=0;root_hops<=0;state<=ROOT_MINUS;
       end
       ROOT_MINUS:begin cluster_count<=data_sector_count>>shift;root_minus<=root_cluster-2;state<=ROOT_SHIFT;end
       ROOT_SHIFT:begin max_cluster<=cluster_count+1'b1;root_scaled<=root_minus<<shift;state<=ROOT_ADD;end
       ROOT_ADD:begin sector_lba<=data_start_lba+root_scaled;state<=ROOT_REQ;end
       ROOT_REQ:if(!sector_busy)begin sector_req<=1;entry_ok<=0;state<=ROOT_WAIT;end
       ROOT_WAIT:if(sector_done)begin if(sector_error!=0)fail(8'h10);else state<=ROOT_NEXT;end
       ROOT_NEXT:begin
        if((resource_valid|commit_en)==6'h3f)state<=FINISH;
        else if(root_sector+1<sectors_per_cluster)begin root_sector<=root_sector+1'b1;sector_lba<=sector_lba+1'b1;state<=ROOT_REQ;end
        else begin fat_offset<={root_cluster[6:0],2'b00};sector_lba<=fat_start_lba+(root_cluster>>7);state<=FAT_REQ;end
       end
       FAT_REQ:if(!sector_busy)begin sector_req<=1;state<=FAT_WAIT;end
       FAT_WAIT:if(sector_done)begin if(sector_error!=0)fail(8'h10);else state<=FAT_CHECK;end
       FAT_CHECK:begin
        root_next_bad<=root_next<2||root_next>max_cluster||root_next==root_cluster||root_hops==1023;
        state<=FAT_PARSE;
       end
       FAT_PARSE:begin
        if(root_next_bad)fail(8'h22);
        else begin root_hops<=root_hops+1'b1;root_cluster<=root_next;root_sector<=0;state<=ROOT_MINUS;end
       end
       FINISH:begin scan_done<=1;state<=IDLE;end
       default:state<=IDLE;
      endcase
     end
    end
endmodule
