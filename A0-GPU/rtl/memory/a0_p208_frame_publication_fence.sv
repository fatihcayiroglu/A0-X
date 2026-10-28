`timescale 1ns/1ps
// P208: synthesizable, fail-closed per-word commit coverage and atomic
// *publication metadata* for the two actual P207/P206/P205/P203 EBR banks.
// No independent scanout/read DMA exists yet; published front is write-locked.
module a0_p208_frame_publication_fence #(
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
  output logic fault,busy
);
  localparam integer AW=$clog2(WORDS);
  logic local_fault_q,host_bank_q,staged_q,write_op_q;
  logic front_valid_q,front_bank_q;
  logic pending_write_q,pending_bank_q,seen_done_q,seen_ok_q;
  logic [AW-1:0] pending_index_q;
  logic [31:0] staged_addr_q,epoch_q;
  logic [3:0] staged_addr_mask_q;
  logic [WORDS-1:0] committed0_q,committed1_q;
  wire [7:0] lower_rdata;
  wire lower_ready,lower_fault,lower_busy;
  wire meta=(host_addr>=6'h31 && host_addr<=6'h37);
  wire any_fault=local_fault_q || lower_fault;
  wire blocked_front=host_write && front_valid_q &&
    host_bank_q==front_bank_q &&
    ((host_addr==6'h02 && host_wdata[0]) ||
     (host_addr>=6'h08 && host_addr<=6'h0d));
  wire [31:0] selected_base=BASE_WORD_ADDR+
    (host_bank_q ? 32'(WORDS) : 32'd0);
  wire [31:0] selected_offset=staged_addr_q-selected_base;
  wire addr_ok=staged_addr_q>=selected_base && selected_offset<WORDS;
  wire [AW-1:0] selected_index=selected_offset[AW-1:0];
  wire complete_selected=host_bank_q ? (&committed1_q) : (&committed0_q);

  a0_p207_two_bram_banks #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) banks(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid && !meta && !local_fault_q && !blocked_front),
    .host_write(host_write),.host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(lower_ready),.host_rdata(lower_rdata),
    .fault(lower_fault),.busy(lower_busy)
  );
  assign fault=any_fault;
  assign busy=lower_busy || pending_write_q;
  assign host_ready=rst_n && !any_fault && (meta ? 1'b1 : lower_ready);
  always_comb begin
    if(!meta)host_rdata=lower_rdata;
    else case(host_addr)
      6'h32:host_rdata={4'd0,complete_selected,
                        staged_q,front_bank_q,front_valid_q};
      6'h33:host_rdata={7'd0,host_bank_q};
      6'h34:host_rdata=epoch_q[7:0];
      6'h35:host_rdata=epoch_q[15:8];
      6'h36:host_rdata=epoch_q[23:16];
      6'h37:host_rdata=epoch_q[31:24];
      default:host_rdata=8'd0;
    endcase
  end
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      local_fault_q<=0;host_bank_q<=0;staged_q<=0;write_op_q<=0;
      front_valid_q<=0;front_bank_q<=0;epoch_q<=0;
      pending_write_q<=0;pending_bank_q<=0;pending_index_q<=0;
      seen_done_q<=0;seen_ok_q<=0;staged_addr_q<=0;
      staged_addr_mask_q<=0;
      committed0_q<='0;committed1_q<='0;
    end else begin
      if(host_valid && !host_write && host_ready && !meta &&
         pending_write_q)begin
        if(host_addr==6'h01 && lower_rdata[3] && !lower_rdata[4])
          seen_done_q<=1;
        if(host_addr==6'h16 && seen_done_q && !lower_rdata[0])
          seen_ok_q<=1;
      end
      if(host_valid && host_write && host_ready)begin
        if(meta)begin
          if(host_addr==6'h31 && host_wdata==8'h01)begin
            if(staged_q || pending_write_q || lower_busy ||
               !complete_selected || epoch_q==32'hffff_ffff ||
               (front_valid_q && host_bank_q==front_bank_q))
              local_fault_q<=1;
            else begin
              front_valid_q<=1;front_bank_q<=host_bank_q;
              epoch_q<=epoch_q+32'd1;
              // Retired old front becomes an unverified new back.
              if(host_bank_q)committed0_q<='0;
              else committed1_q<='0;
            end
          end else local_fault_q<=1;
        end else if(host_addr==6'h30)begin
          if(host_wdata<=8'd1 && !staged_q && !lower_busy &&
             !pending_write_q)
            host_bank_q<=host_wdata[0];
        end else if(blocked_front)begin
          // No P207 write reaches the published immutable front.
          local_fault_q<=1;
        end else if(host_addr==6'h02)begin
          staged_q<=1;write_op_q<=host_wdata[0];
          if(host_wdata>8'd1)local_fault_q<=1;
        end else if(host_addr>=6'h04 && host_addr<=6'h07)begin
          staged_q<=1;
          staged_addr_q[(host_addr-6'h04)*8+:8]<=host_wdata;
          staged_addr_mask_q[host_addr-6'h04]<=1;
        end else if(host_addr>=6'h08 && host_addr<=6'h0d)begin
          staged_q<=1;
        end else if(host_addr==6'h00 && host_wdata==8'h01)begin
          if(write_op_q)begin
            if(!staged_q || pending_write_q ||
               staged_addr_mask_q!=4'hf || !addr_ok ||
               (front_valid_q && host_bank_q==front_bank_q))
              local_fault_q<=1;
            else begin
              pending_write_q<=1;
              pending_bank_q<=host_bank_q;
              pending_index_q<=selected_index;
              seen_done_q<=0;seen_ok_q<=0;
            end
          end
        end else if(host_addr==6'h00 && host_wdata==8'h02)begin
          if(pending_write_q)begin
            if(!seen_done_q || !seen_ok_q || lower_fault ||
               pending_bank_q!=host_bank_q)
              local_fault_q<=1;
            else if(pending_bank_q)
              committed1_q[pending_index_q]<=1;
            else committed0_q[pending_index_q]<=1;
          end
          pending_write_q<=0;seen_done_q<=0;seen_ok_q<=0;
          staged_q<=0;write_op_q<=0;staged_addr_q<=0;
          staged_addr_mask_q<=0;
        end
      end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       BASE_WORD_ADDR>32'hffff_ffff-2*WORDS ||
       RESPONSE_TIMEOUT<64)
      $fatal(1,"P208 unsupported publication geometry");
  end
endmodule
