`timescale 1ns/1ps
// P209: independent synchronous pixel readout from two committed shadow
// EBR banks. Shadow words update ONLY on the host's acknowledged, validated
// P208/P203 write COMMIT. No P208/P207/P206 implementation is altered.
// The publication epoch is attached to each pixel, but NO video timing /
// whole-frame scanout boundary is implemented here.
module a0_p209_independent_scanout #(
  parameter integer WORDS=1024,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy,
  input logic scan_req_valid,
  input logic [9:0] scan_word_index,
  output logic scan_req_ready,
  output logic scan_rsp_valid,
  output logic [47:0] scan_rsp_pixel,
  output logic [31:0] scan_rsp_epoch
);
  localparam integer AW=$clog2(WORDS);
  logic mirror_fault_q,mirror_scrub_q,boot_ready_q;
  logic [AW-1:0] scrub_idx_q;
  logic host_bank_q,op_write_q,op_loaded_q;
  logic [31:0] staged_addr_q;
  logic [47:0] staged_pixel_q,pending_pixel_q;
  logic [3:0] staged_addr_mask_q;
  logic [5:0] staged_pixel_mask_q;
  logic pending_write_q,pending_bank_q,seen_done_q,seen_ok_q;
  logic [AW-1:0] pending_index_q;
  logic pending_pub_q,pending_pub_bank_q;
  logic front_valid_q,front_bank_q,scan_rsp_bank_q;
  logic [31:0] epoch_q;
  wire low_ready,low_fault,low_busy;
  wire [7:0] low_rdata;
  wire [31:0] selected_base=BASE_WORD_ADDR+
     (host_bank_q ? 32'(WORDS) : 32'd0);
  wire [31:0] selected_offset=staged_addr_q-selected_base;
  wire selected_address_ok=staged_addr_q>=selected_base &&
      selected_offset<WORDS;
  wire [AW-1:0] selected_index=selected_offset[AW-1:0];
  wire scan_addr_ok=scan_word_index<WORDS;
  wire mirror_write_commit=host_valid && host_write && host_ready &&
      host_addr==6'h00 && host_wdata==8'h02 &&
      pending_write_q && seen_done_q && seen_ok_q &&
      !low_fault && !mirror_fault_q;
  wire pub_fire=host_valid && host_write && host_ready &&
      host_addr==6'h31 && host_wdata==8'h01;
  wire [AW-1:0] shadow_waddr=mirror_scrub_q ? scrub_idx_q :
      pending_index_q;
  wire [47:0] shadow_wdata=mirror_scrub_q ? 48'd0 :
      pending_pixel_q;
  wire shadow0_we=rst_n && (mirror_scrub_q ||
      (mirror_write_commit && !pending_bank_q));
  wire shadow1_we=rst_n && (mirror_scrub_q ||
      (mirror_write_commit && pending_bank_q));
  wire [AW-1:0] scan_index=scan_word_index[AW-1:0];
  (* ram_style="block" *) logic [47:0] shadow0 [0:WORDS-1];
  (* ram_style="block" *) logic [47:0] shadow1 [0:WORDS-1];
  logic [47:0] read0_q,read1_q;

  // Exactly one write port and one unconditional registered read port
  // per ECP5 RAM. Readout never consumes the producer's byte register bus.
  always_ff @(posedge clk)begin
    if(shadow0_we)shadow0[shadow_waddr]<=shadow_wdata;
    if(shadow1_we)shadow1[shadow_waddr]<=shadow_wdata;
    read0_q<=shadow0[scan_index];
    read1_q<=shadow1[scan_index];
  end

  a0_p208_frame_publication_fence #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) producer(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid && boot_ready_q && !pending_pub_q &&
      !mirror_fault_q),
    .host_write(host_write),.host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(low_ready),.host_rdata(low_rdata),
    .fault(low_fault),.busy(low_busy)
  );
  assign fault=mirror_fault_q || low_fault;
  assign busy=!boot_ready_q || low_busy || pending_pub_q;
  assign host_ready=rst_n && boot_ready_q && !pending_pub_q &&
     !mirror_fault_q && low_ready;
  assign host_rdata=low_rdata;
  assign scan_req_ready=rst_n && boot_ready_q && front_valid_q &&
     !pending_pub_q && !fault && scan_addr_ok;
  assign scan_rsp_pixel=scan_rsp_bank_q ? read1_q : read0_q;

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      mirror_fault_q<=0;mirror_scrub_q<=1;boot_ready_q<=0;
      scrub_idx_q<=0;host_bank_q<=0;op_write_q<=0;op_loaded_q<=0;
      staged_addr_q<=0;staged_pixel_q<=0;
      staged_addr_mask_q<=0;staged_pixel_mask_q<=0;
      pending_write_q<=0;pending_bank_q<=0;pending_index_q<=0;
      pending_pixel_q<=0;seen_done_q<=0;seen_ok_q<=0;
      pending_pub_q<=0;pending_pub_bank_q<=0;
      front_valid_q<=0;front_bank_q<=0;epoch_q<=0;
      scan_rsp_valid<=0;scan_rsp_bank_q<=0;scan_rsp_epoch<=0;
    end else begin
      scan_rsp_valid<=scan_req_valid && scan_req_ready;
      if(scan_req_valid && scan_req_ready)begin
        scan_rsp_bank_q<=front_bank_q;
        scan_rsp_epoch<=epoch_q;
      end
      if(mirror_scrub_q)begin
        if(scrub_idx_q==WORDS-1)mirror_scrub_q<=0;
        else scrub_idx_q<=scrub_idx_q+1'b1;
      end else if(!boot_ready_q && !low_busy && !low_fault)
        boot_ready_q<=1;
      if(pending_pub_q)begin
        pending_pub_q<=0;
        if(!low_fault && !mirror_fault_q)begin
          front_valid_q<=1;
          front_bank_q<=pending_pub_bank_q;
          if(epoch_q==32'hffff_ffff)mirror_fault_q<=1;
          else epoch_q<=epoch_q+32'd1;
        end
      end
      if(host_valid && !host_write && host_ready &&
         pending_write_q)begin
        if(host_addr==6'h01 && low_rdata[3] && !low_rdata[4])
          seen_done_q<=1;
        if(host_addr==6'h16 && seen_done_q && !low_rdata[0])
          seen_ok_q<=1;
      end
      if(host_valid && host_write && host_ready)begin
        if(host_addr==6'h30)begin
          if(host_wdata<=8'd1 && !low_busy && !pending_write_q)
            host_bank_q<=host_wdata[0];
        end else if(host_addr==6'h02)begin
          if(host_wdata>8'd1)mirror_fault_q<=1;
          op_write_q<=host_wdata[0];op_loaded_q<=1;
        end else if(host_addr>=6'h04 && host_addr<=6'h07)begin
          staged_addr_q[(host_addr-6'h04)*8+:8]<=host_wdata;
          staged_addr_mask_q[host_addr-6'h04]<=1;
        end else if(host_addr>=6'h08 && host_addr<=6'h0d)begin
          staged_pixel_q[(host_addr-6'h08)*8+:8]<=host_wdata;
          staged_pixel_mask_q[host_addr-6'h08]<=1;
        end else if(host_addr==6'h00 && host_wdata==8'h01)begin
          if(op_write_q)begin
            if(!op_loaded_q || pending_write_q ||
               staged_addr_mask_q!=4'hf ||
               staged_pixel_mask_q!=6'h3f || !selected_address_ok)
              mirror_fault_q<=1;
            else begin
              pending_write_q<=1;pending_bank_q<=host_bank_q;
              pending_index_q<=selected_index;
              pending_pixel_q<=staged_pixel_q;
              seen_done_q<=0;seen_ok_q<=0;
            end
          end
        end else if(host_addr==6'h00 && host_wdata==8'h02)begin
          if(pending_write_q &&
             (!seen_done_q || !seen_ok_q || pending_bank_q!=host_bank_q))
            mirror_fault_q<=1;
          pending_write_q<=0;seen_done_q<=0;seen_ok_q<=0;
          op_loaded_q<=0;op_write_q<=0;staged_addr_q<=0;
          staged_pixel_q<=0;staged_addr_mask_q<=0;
          staged_pixel_mask_q<=0;
        end else if(pub_fire)begin
          pending_pub_q<=1;pending_pub_bank_q<=host_bank_q;
        end
      end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       BASE_WORD_ADDR>32'hffff_ffff-2*WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P209 unsupported independent scanout geometry");
  end
endmodule
