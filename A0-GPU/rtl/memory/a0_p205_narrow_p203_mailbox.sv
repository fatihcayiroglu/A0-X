`timescale 1ns/1ps
// P205: synthesizable TWO 8-bit register mailboxes wrapping the real P203
// tagged, commit-acknowledged bridge. There are no tied-off P203 data pins.
// Host and controller each use a 6-bit register index + 8-bit data.
// This is a synchronous proof interface, NOT a CDC/PCIe/DDR PHY.
module a0_p205_narrow_p203_mailbox #(
  parameter integer FRAME_WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer BANK_INDEX=0,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  input logic ctrl_valid,ctrl_write,
  input logic [5:0] ctrl_addr,
  input logic [7:0] ctrl_wdata,
  output logic ctrl_ready,
  output logic [7:0] ctrl_rdata,
  output logic fault,busy
);
  logic fault_q,host_cmd_pending_q,host_read_wait_q,host_done_q,host_error_q;
  logic [31:0] host_word_addr_q;
  logic [47:0] host_pixel_q,host_result_q;
  logic host_op_q,host_op_loaded_q;
  logic [3:0] host_addr_mask_q;
  logic [5:0] host_pixel_mask_q;
  logic ctrl_req_pending_q,ctrl_rsp_pending_q,flush_ack_q;
  logic ctrl_request_write_q,ctrl_response_error_q,ctrl_error_loaded_q;
  logic [31:0] ctrl_request_addr_q,ctrl_request_id_q,ctrl_response_id_q;
  logic [47:0] ctrl_request_pixel_q,ctrl_response_pixel_q;
  logic [3:0] ctrl_response_id_mask_q;
  logic [5:0] ctrl_response_pixel_mask_q;
  wire bridge_fault,bridge_busy,bridge_flush_req,bridge_flush_ack;
  wire bridge_bank_ready,bridge_bank_rsp_valid,bridge_bank_rsp_error;
  wire [47:0] bridge_bank_rsp_pixel;
  wire bridge_ctrl_req_valid,bridge_ctrl_req_write,bridge_ctrl_req_ready;
  wire [31:0] bridge_ctrl_req_addr,bridge_ctrl_req_id;
  wire [47:0] bridge_ctrl_req_pixel;
  wire bridge_ctrl_rsp_ready;
  wire bridge_ctrl_rsp_valid=ctrl_rsp_pending_q && !fault_q;
  assign bridge_flush_ack=flush_ack_q;

  a0_p203_tagged_controller_bridge #(
    .FRAME_WORDS(FRAME_WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .BANK_INDEX(BANK_INDEX),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) bridge(
    .clk(clk),.rst_n(rst_n),
    .bank_cmd_valid(host_cmd_pending_q && !fault_q),
    .bank_cmd_write(host_op_q),
    .bank_cmd_word_addr(host_word_addr_q),
    .bank_cmd_pixel(host_pixel_q),
    .bank_cmd_ready(bridge_bank_ready),
    .bank_rsp_valid(bridge_bank_rsp_valid),
    .bank_rsp_error(bridge_bank_rsp_error),
    .bank_rsp_pixel(bridge_bank_rsp_pixel),
    .fault(bridge_fault),.busy(bridge_busy),
    .ctrl_flush_req(bridge_flush_req),.ctrl_flush_ack(bridge_flush_ack),
    .ctrl_req_valid(bridge_ctrl_req_valid),
    .ctrl_req_write(bridge_ctrl_req_write),
    .ctrl_req_word_addr(bridge_ctrl_req_addr),
    .ctrl_req_pixel(bridge_ctrl_req_pixel),
    .ctrl_req_id(bridge_ctrl_req_id),
    .ctrl_req_ready(bridge_ctrl_req_ready),
    .ctrl_rsp_valid(bridge_ctrl_rsp_valid),
    .ctrl_rsp_error(ctrl_response_error_q),
    .ctrl_rsp_pixel(ctrl_response_pixel_q),
    .ctrl_rsp_id(ctrl_response_id_q),
    .ctrl_rsp_ready(bridge_ctrl_rsp_ready)
  );
  assign bridge_ctrl_req_ready=rst_n && !fault_q &&
    !ctrl_req_pending_q && !ctrl_rsp_pending_q;
  assign host_ready=rst_n && (!host_write || !fault_q);
  assign ctrl_ready=rst_n && (!ctrl_write || !fault_q);
  assign fault=fault_q || bridge_fault;
  assign busy=host_cmd_pending_q || host_read_wait_q ||
    ctrl_req_pending_q || ctrl_rsp_pending_q || bridge_busy;
  always_comb begin
    host_rdata=8'd0;
    if(host_addr==6'h01)
      host_rdata={2'b0,bridge_busy,fault,host_done_q,
                  host_read_wait_q,host_cmd_pending_q,bridge_flush_req};
    else if(host_addr==6'h02)host_rdata={7'd0,host_op_q};
    else if(host_addr>=6'h04 && host_addr<=6'h07)
      host_rdata=host_word_addr_q[(host_addr-6'h04)*8 +:8];
    else if(host_addr>=6'h08 && host_addr<=6'h0d)
      host_rdata=host_pixel_q[(host_addr-6'h08)*8 +:8];
    else if(host_addr>=6'h10 && host_addr<=6'h15)
      host_rdata=host_result_q[(host_addr-6'h10)*8 +:8];
    else if(host_addr==6'h16)
      host_rdata={7'd0,host_error_q};
  end
  always_comb begin
    ctrl_rdata=8'd0;
    if(ctrl_addr==6'h01)
      ctrl_rdata={4'd0,fault,ctrl_rsp_pending_q,
                  ctrl_req_pending_q,bridge_flush_req};
    else if(ctrl_addr==6'h02)
      ctrl_rdata={7'd0,ctrl_request_write_q};
    else if(ctrl_addr>=6'h04 && ctrl_addr<=6'h07)
      ctrl_rdata=ctrl_request_addr_q[(ctrl_addr-6'h04)*8 +:8];
    else if(ctrl_addr>=6'h08 && ctrl_addr<=6'h0d)
      ctrl_rdata=ctrl_request_pixel_q[(ctrl_addr-6'h08)*8 +:8];
    else if(ctrl_addr>=6'h10 && ctrl_addr<=6'h13)
      ctrl_rdata=ctrl_request_id_q[(ctrl_addr-6'h10)*8 +:8];
  end

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      fault_q<=0;host_cmd_pending_q<=0;host_read_wait_q<=0;
      host_done_q<=0;host_error_q<=0;host_word_addr_q<=0;
      host_pixel_q<=0;host_result_q<=0;host_op_q<=0;
      host_op_loaded_q<=0;host_addr_mask_q<=0;host_pixel_mask_q<=0;
      ctrl_req_pending_q<=0;ctrl_rsp_pending_q<=0;flush_ack_q<=0;
      ctrl_request_write_q<=0;ctrl_response_error_q<=0;
      ctrl_error_loaded_q<=0;ctrl_request_addr_q<=0;
      ctrl_request_id_q<=0;ctrl_request_pixel_q<=0;
      ctrl_response_id_q<=0;ctrl_response_pixel_q<=0;
      ctrl_response_id_mask_q<=0;ctrl_response_pixel_mask_q<=0;
    end else begin
      flush_ack_q<=0;
      if(bridge_fault)begin
        fault_q<=1;host_error_q<=1;host_done_q<=1;
      end
      if(host_cmd_pending_q && bridge_bank_ready)begin
        host_cmd_pending_q<=0;
        if(host_op_q)begin
          host_done_q<=1;host_error_q<=0;
        end else host_read_wait_q<=1;
      end
      if(host_read_wait_q && bridge_bank_rsp_valid)begin
        host_read_wait_q<=0;host_done_q<=1;
        host_error_q<=bridge_bank_rsp_error;
        host_result_q<=bridge_bank_rsp_pixel;
        if(bridge_bank_rsp_error)fault_q<=1;
      end
      if(bridge_ctrl_req_valid && bridge_ctrl_req_ready)begin
        ctrl_req_pending_q<=1;
        ctrl_request_write_q<=bridge_ctrl_req_write;
        ctrl_request_addr_q<=bridge_ctrl_req_addr;
        ctrl_request_pixel_q<=bridge_ctrl_req_pixel;
        ctrl_request_id_q<=bridge_ctrl_req_id;
      end
      if(bridge_ctrl_rsp_valid && bridge_ctrl_rsp_ready)begin
        ctrl_rsp_pending_q<=0;ctrl_req_pending_q<=0;
        ctrl_error_loaded_q<=0;ctrl_response_id_mask_q<=0;
        ctrl_response_pixel_mask_q<=0;
      end
      if(host_valid && host_write && host_ready)begin
        if(host_addr==6'h00)begin
          if(host_wdata==8'h01)begin
            if(bridge_flush_req || !host_op_loaded_q ||
               host_addr_mask_q!=4'hf ||
               (host_op_q && host_pixel_mask_q!=6'h3f) ||
               host_cmd_pending_q || host_read_wait_q || host_done_q ||
               fault || bridge_busy)fault_q<=1;
            else host_cmd_pending_q<=1;
          end else if(host_wdata==8'h02)begin
            if(!host_done_q || host_cmd_pending_q || host_read_wait_q ||
               fault)fault_q<=1;
            else begin
              host_done_q<=0;host_error_q<=0;host_result_q<=0;
              host_op_loaded_q<=0;host_addr_mask_q<=0;
              host_pixel_mask_q<=0;
            end
          end else fault_q<=1;
        end else if(!host_cmd_pending_q && !host_read_wait_q &&
                    !host_done_q)begin
          if(host_addr==6'h02)begin
            if(host_wdata>8'd1)fault_q<=1;
            else begin host_op_q<=host_wdata[0];host_op_loaded_q<=1;end
          end else if(host_addr>=6'h04 && host_addr<=6'h07)begin
            host_word_addr_q[(host_addr-6'h04)*8 +:8]<=host_wdata;
            host_addr_mask_q[host_addr-6'h04]<=1;
          end else if(host_addr>=6'h08 && host_addr<=6'h0d)begin
            host_pixel_q[(host_addr-6'h08)*8 +:8]<=host_wdata;
            host_pixel_mask_q[host_addr-6'h08]<=1;
          end else fault_q<=1;
        end else fault_q<=1;
      end
      if(ctrl_valid && ctrl_write && ctrl_ready)begin
        if(ctrl_addr==6'h00)begin
          if(ctrl_wdata==8'h01)begin
            if(!bridge_flush_req || ctrl_req_pending_q ||
               ctrl_rsp_pending_q || fault)fault_q<=1;
            else flush_ack_q<=1;
          end else if(ctrl_wdata==8'h02)begin
            if(!ctrl_req_pending_q || ctrl_rsp_pending_q ||
               !ctrl_error_loaded_q ||
               ctrl_response_id_mask_q!=4'hf ||
               (!ctrl_request_write_q &&
                ctrl_response_pixel_mask_q!=6'h3f) || fault)
              fault_q<=1;
            else ctrl_rsp_pending_q<=1;
          end else fault_q<=1;
        end else if(ctrl_req_pending_q && !ctrl_rsp_pending_q)begin
          if(ctrl_addr==6'h14)begin
            if(ctrl_wdata>8'd1)fault_q<=1;
            else begin ctrl_response_error_q<=ctrl_wdata[0];
                       ctrl_error_loaded_q<=1;end
          end else if(ctrl_addr>=6'h18 && ctrl_addr<=6'h1b)begin
            ctrl_response_id_q[(ctrl_addr-6'h18)*8 +:8]<=ctrl_wdata;
            ctrl_response_id_mask_q[ctrl_addr-6'h18]<=1;
          end else if(ctrl_addr>=6'h20 && ctrl_addr<=6'h25)begin
            ctrl_response_pixel_q[(ctrl_addr-6'h20)*8 +:8]<=ctrl_wdata;
            ctrl_response_pixel_mask_q[ctrl_addr-6'h20]<=1;
          end else fault_q<=1;
        end else fault_q<=1;
      end
    end
  end
endmodule
