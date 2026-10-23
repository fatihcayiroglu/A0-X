`timescale 1ns/1ps
module a0_mc_noc_sliced_l2_store_order_subsystem_tb;
  localparam integer C=2, U=1, M=2, W=4, S=2, SETS=8, MISSES=4, LANES=2;
  localparam integer CLTW=2, NTW=3, LAW=30;
  logic clk; always #5 clk=~clk; logic rst_n;
  logic [C-1:0] rv, rr, re; logic [CLTW-1:0] rt[0:C-1]; logic [LAW-1:0] ra[0:C-1];
  logic [C-1:0] pv, pr; logic [CLTW-1:0] pt[0:C-1]; logic [LAW-1:0] pa[0:C-1]; logic pf[0:C-1]; logic [31:0] pd[0:C-1][0:W-1];
  logic store_v; logic [LANES-1:0] store_m; logic [31:0] store_a[0:LANES-1];
  logic [C-1:0] ne; logic [S-1:0] se; logic [C-1:0] nre;
  logic [S-1:0] mv, mr; logic [NTW-1:0] mt[0:S-1]; logic [LAW-1:0] ma[0:S-1];
  logic [S-1:0] bv; logic [NTW-1:0] bt[0:S-1]; logic [LAW-1:0] ba[0:S-1]; logic bf[0:S-1]; logic [31:0] bd[0:S-1][0:W-1];
  integer i,j; integer response_count; integer backend_count; logic last_sl; logic [NTW-1:0] last_tag; logic [LAW-1:0] last_addr; logic watch_stale1;

  a0_mc_noc_sliced_l2_store_order_subsystem #(.CLUSTER_COUNT(C),.CUS_PER_CLUSTER(U),.MSHR_COUNT(M),.LINE_WORDS(W),.L2_SLICE_COUNT(S),.L2_SET_COUNT_PER_SLICE(SETS),.L2_MISS_COUNT_PER_SLICE(MISSES),.STORE_LANES(LANES)) dut(
    .clk(clk),.rst_n(rst_n),.cluster_local_req_valid_i(rv),.cluster_local_req_ready_o(rr),.cluster_local_req_tag_i(rt),.cluster_local_req_line_addr_i(ra),.cluster_local_req_tag_error_o(re),
    .cluster_local_resp_valid_o(pv),.cluster_local_resp_ready_i(pr),.cluster_local_resp_tag_o(pt),.cluster_local_resp_line_addr_o(pa),.cluster_local_resp_fault_o(pf),.cluster_local_resp_data_o(pd),
    .global_store_valid_i(store_v),.global_store_lane_mask_i(store_m),.global_store_word_addr_i(store_a),.noc_req_tag_error_o(ne),.slice_resp_protocol_error_o(se),.noc_resp_tag_error_o(nre),
    .line_mem_req_valid_o(mv),.line_mem_req_ready_i(mr),.line_mem_req_network_tag_o(mt),.line_mem_req_line_addr_o(ma),.line_mem_resp_valid_i(bv),.line_mem_resp_network_tag_i(bt),.line_mem_resp_line_addr_i(ba),.line_mem_resp_fault_i(bf),.line_mem_resp_data_i(bd));

  always @(posedge clk) begin
    if (!rst_n) begin response_count <= 0; backend_count <= 0; last_sl <= 0; last_tag <= '0; last_addr <= '0; end
    else begin
      if (watch_stale1 && pv[1] && pd[1][0]==32'hAAAA0000) $fatal(1,"same-cycle stale escaped");
      if (pv[0]||pv[1]) response_count <= response_count+1;
      if (mv[0]&&mr[0]) begin backend_count<=backend_count+1; last_sl<=0; last_tag<=mt[0]; last_addr<=ma[0]; end
      else if (mv[1]&&mr[1]) begin backend_count<=backend_count+1; last_sl<=1; last_tag<=mt[1]; last_addr<=ma[1]; end
    end
  end

  task automatic issue_req(input logic c, input logic [CLTW-1:0] tag, input logic [LAW-1:0] addr);
    begin rv[c]=1; rt[c]=tag; ra[c]=addr; do @(posedge clk); while(!rr[c]); #1 rv[c]=0; end
  endtask
  task automatic wait_backend(output logic sl, output logic [NTW-1:0] tag, output logic [LAW-1:0] addr);
    integer k; begin
      sl=1'b0; for(k=0;k<80;k=k+1) begin @(posedge clk); #1; if(mv[0]||mv[1]) begin sl=mv[0]?0:1; tag=mt[sl]; addr=ma[sl]; k=80; end end
      if(!(mv[0]||mv[1])) $fatal(1,"P4 backend request timeout");
    end
  endtask
  task automatic send_resp(input logic sl,input logic [NTW-1:0] tag,input logic [LAW-1:0] addr,input logic fault,input logic [31:0] base,input logic same_store);
    begin
      @(negedge clk); bv[sl]=1; bt[sl]=tag; ba[sl]=addr; bf[sl]=fault; for(j=0;j<W;j=j+1) bd[sl][j]=base+j;
      if(same_store) begin store_v=1; store_m='0; store_m[0]=1; store_a[0]={addr,{2{1'b0}}}; end
      @(posedge clk); #1; bv[sl]=0; store_v=0; store_m='0;
    end
  endtask

  initial begin
    clk=0; rst_n=0; response_count=0; backend_count=0; last_sl=0; last_tag='0; last_addr='0; watch_stale1=0; rv='0; pr='1; store_v=0; store_m='0; mr='1; bv='0;
    for(i=0;i<C;i=i+1) begin rt[i]='0; ra[i]='0; end
    for(i=0;i<LANES;i=i+1) store_a[i]='0;
    for(i=0;i<S;i=i+1) begin bt[i]='0; ba[i]='0; bf[i]=0; for(j=0;j<W;j=j+1) bd[i][j]='0; end
    repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

    begin logic sl; logic [NTW-1:0] tag; logic [LAW-1:0] addr; integer snap;
      issue_req(0,2'b01,30'd6); wait_backend(sl,tag,addr); if(addr!=30'd6) $fatal(1,"initial addr");
      @(negedge clk); store_v=1; store_m=2'b01; store_a[0]=32'd24; @(posedge clk); #1; store_v=0; store_m='0;
      snap=response_count; i=backend_count; send_resp(sl,tag,addr,0,32'hDEAD0000,0); repeat(8) @(posedge clk); #1; if(response_count!=snap) $fatal(1,"stale response escaped");
      $display("PROD_SEAM_P4_STALE_RESPONSE_SQUASH=PASS");
      if(backend_count<=i || last_tag[CLTW-1:0]!=2'b01 || last_addr!=30'd6) $fatal(1,"retry identity mismatch");
      $display("PROD_SEAM_P4_REQUESTER_IDENTITY_PRESERVED=PASS");
      sl=last_sl; tag=last_tag; addr=last_addr; send_resp(sl,tag,addr,0,32'hBEEF0000,0);
      repeat(20) begin @(posedge clk); #1; if(pv[0]) begin if(pt[0]!=2'b01||pa[0]!=30'd6||pf[0]||pd[0][0]!=32'hBEEF0000) $fatal(1,"fresh completion mismatch"); $display("PROD_SEAM_P4_RETRY_FRESH_COMPLETION=PASS"); break; end end
    end

    begin logic sl; logic [NTW-1:0] tag; logic [LAW-1:0] addr;
      issue_req(1,2'b00,30'd9); wait_backend(sl,tag,addr); i=backend_count; watch_stale1=1; send_resp(sl,tag,addr,0,32'hAAAA0000,1); repeat(8) @(posedge clk); #1; watch_stale1=0;
      $display("PROD_SEAM_P4_SAME_CYCLE_STORE_REFILL=PASS");
      if(backend_count<=i || last_addr!=30'd9) $fatal(1,"samecycle retry missing"); sl=last_sl; tag=last_tag; addr=last_addr; send_resp(sl,tag,addr,0,32'hCCCC0000,0);
      repeat(20) begin @(posedge clk); #1; if(pv[1]) begin if(pd[1][0]!=32'hCCCC0000||pf[1]) $fatal(1,"samecycle retry completion"); break; end end
    end

    begin logic sl; logic [NTW-1:0] tag; logic [LAW-1:0] addr;
      issue_req(0,2'b00,30'd12); wait_backend(sl,tag,addr); send_resp(sl,tag,addr,1,32'h12340000,0);
      repeat(20) begin @(posedge clk); #1; if(pv[0]) begin if(!pf[0]) $fatal(1,"fault provenance lost"); $display("PROD_SEAM_P4_FAULT_PROVENANCE_DISTINCT=PASS"); break; end end
    end
    if(|re|| |ne|| |se|| |nre) $fatal(1,"diagnostic error");
    $display("PROD_SEAM_P4_BEHAVIOR=PASS"); $finish;
  end
endmodule
