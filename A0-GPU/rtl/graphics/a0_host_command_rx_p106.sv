`timescale 1ns/1ps
// P106 DEVELOPMENT: validated P44 V1 32-byte packets, plus P106 V2 56-byte
// TRIANGLE packets with fragment state.  Sliding byte window resync; no
// bus/PCIe, queueing, guaranteed resynchronization, or simulator qualification.
// Holds ALL decoded fields stable until cmd_ready.
module a0_host_command_rx_p106 (
    input logic clk,rst_n,
    input logic in_valid,
    output logic in_ready,
    input logic [7:0] in_byte,
    output logic cmd_valid,
    input logic cmd_ready,
    output logic [1:0] cmd_opcode,
    output logic [15:0] cmd_tag,
    output logic [23:0] cmd_color,cmd_depth,
    output logic signed [15:0] cmd_x0,cmd_y0,cmd_x1,cmd_y1,cmd_x2,cmd_y2,
    output logic [1:0] cmd_depth_op,
    output logic cmd_depth_write,cmd_blend_enable,
    output logic [7:0] cmd_alpha,
    output logic cmd_scissor_enable,
    output logic [15:0] cmd_scissor_x,cmd_scissor_y,cmd_scissor_w,cmd_scissor_h,
    output logic [31:0] invalid_frame_count
);
    logic [447:0] window_q;
    logic [5:0] collected_q;
    logic [447:0] candidate;
    logic [255:0] p1;
    logic [447:0] p2;
    logic [7:0] flags;
    logic p1_magic,p2_magic,p1_canonical,p2_canonical,p1_valid,p2_valid;

    function automatic logic [31:0] crc32_bytes(input logic [415:0] bytes,
                                                 input integer nbytes);
        logic [31:0] crc;
        crc=32'hffffffff;
        for(integer i=0;i<nbytes;i++) begin
            crc=crc ^ {24'd0,bytes[i*8+:8]};
            for(integer j=0;j<8;j++) begin
                if(crc[0])crc=(crc>>1)^32'hedb88320;
                else crc=crc>>1;
            end
        end
        return ~crc;
    endfunction

    assign in_ready=rst_n && !cmd_valid;
    assign candidate={in_byte,window_q[447:8]};
    // The newest 32 bytes occupy the upper 256 bits; the newest 56 all bits.
    assign p1=candidate[447:192];
    assign p2=candidate;
    assign flags=p2[263:256];
    assign p1_magic=(p1[31:0]==32'h43473041 && p1[39:32]==8'd1);
    assign p2_magic=(p2[31:0]==32'h43473041 && p2[39:32]==8'd2);
    assign p1_canonical=
        (p1[47:40]<=8'd3) && (p1[95:88]==8'd0) &&
        (p1[223:192]==32'd0) &&
        ((p1[47:40]==8'd1)||(p1[191:96]==96'd0)) &&
        ((p1[47:40]<=8'd1)||(p1[87:64]==24'd0));
    assign p2_canonical=
        (p2[47:40]==8'd1) && (p2[95:88]==8'd0) &&
        (p2[223:192]==32'd0) && (p2[255:248]==8'd0) &&
        (flags[7:5]==3'd0) && (p2[287:272]==16'd0) &&
        (p2[415:352]==64'd0) &&
        ((flags[4] && (p2[335:320]!=16'd0) &&
           (p2[351:336]!=16'd0)) ||
         (!flags[4] && p2[351:288]==64'd0));
    assign p1_valid=p1_magic && p1_canonical &&
                    (crc32_bytes({192'd0,p1[223:0]},28)==p1[255:224]);
    assign p2_valid=p2_magic && p2_canonical &&
                    (crc32_bytes(p2[415:0],52)==p2[447:416]);

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            window_q<='0;collected_q<='0;
            cmd_valid<=1'b0;cmd_opcode<='0;cmd_tag<='0;cmd_color<='0;
            cmd_depth<=24'hffffff;cmd_depth_op<=2'd0;
            cmd_depth_write<=1'b0;cmd_blend_enable<=1'b0;
            cmd_alpha<=8'd255;cmd_scissor_enable<=1'b0;
            cmd_scissor_x<=0;cmd_scissor_y<=0;
            cmd_scissor_w<=0;cmd_scissor_h<=0;
            cmd_x0<=0;cmd_y0<=0;cmd_x1<=0;cmd_y1<=0;
            cmd_x2<=0;cmd_y2<=0;invalid_frame_count<=0;
        end else if(cmd_valid) begin
            if(cmd_ready) begin
                cmd_valid<=1'b0;
                window_q<='0;collected_q<='0;
            end
        end else if(in_valid && in_ready) begin
            window_q<=candidate;
            if(collected_q<6'd56)collected_q<=collected_q+6'd1;
            if(collected_q>=6'd31 && p1_magic && p1_valid) begin
                cmd_valid<=1'b1;
                cmd_opcode<=p1[41:40];
                cmd_tag<=p1[63:48];cmd_color<=p1[87:64];
                cmd_x0<=p1[111:96];cmd_y0<=p1[127:112];
                cmd_x1<=p1[143:128];cmd_y1<=p1[159:144];
                cmd_x2<=p1[175:160];cmd_y2<=p1[191:176];
                cmd_depth<=24'hffffff;cmd_depth_op<=2'd0;
                cmd_depth_write<=1'b0;cmd_blend_enable<=1'b0;
                cmd_alpha<=8'd255;cmd_scissor_enable<=1'b0;
                cmd_scissor_x<=0;cmd_scissor_y<=0;
                cmd_scissor_w<=0;cmd_scissor_h<=0;
            end else if(collected_q>=6'd55 && p2_magic && p2_valid) begin
                cmd_valid<=1'b1;
                cmd_opcode<=2'd1;cmd_tag<=p2[63:48];
                cmd_color<=p2[87:64];
                cmd_x0<=p2[111:96];cmd_y0<=p2[127:112];
                cmd_x1<=p2[143:128];cmd_y1<=p2[159:144];
                cmd_x2<=p2[175:160];cmd_y2<=p2[191:176];
                cmd_depth<=p2[247:224];cmd_depth_op<=flags[1:0];
                cmd_depth_write<=flags[2];cmd_blend_enable<=flags[3];
                cmd_alpha<=p2[271:264];cmd_scissor_enable<=flags[4];
                cmd_scissor_x<=p2[303:288];cmd_scissor_y<=p2[319:304];
                cmd_scissor_w<=p2[335:320];cmd_scissor_h<=p2[351:336];
            end else if((collected_q>=6'd31 && p1_magic && !p1_valid) ||
                        (collected_q>=6'd55 && p2_magic && !p2_valid)) begin
                if(invalid_frame_count!=32'hffffffff)
                    invalid_frame_count<=invalid_frame_count+32'd1;
            end
        end
    end
endmodule
