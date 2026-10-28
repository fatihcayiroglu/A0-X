`timescale 1ns/1ps
// P201: automated P199 stage/seal decisions around two ACTUAL P175 frames.
// P198 -> P195 -> P197 -> synthesizable P200 router -> P199.
// No testbench-generated stage_begin, stage_seal, or exporter start.
// Both 65,536-word backing banks are P196 SIMULATION-ONLY models.
module a0_p202_guarded_p175_epoch_tb #(
  parameter integer W=256,H=256
);
  localparam integer BASE_X=W>128 ? 128 : 0;
  localparam integer BASE_Y=H>128 ? 128 : 0;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,export_mode=0,capture_request=0;
  wire export_start,stage_begin,stage_seal;
  logic test_req_valid=0,test_req_write=0;
  logic [5:0] test_req_addr=0;
  logic [31:0] test_req_wdata=0;
  wire export_req_valid,export_req_write;
  wire [5:0] export_req_addr;
  wire [31:0] export_req_wdata;
  wire req_valid=export_mode ? export_req_valid : test_req_valid;
  wire req_write=export_mode ? export_req_write : test_req_write;
  wire [5:0] req_addr=export_mode ? export_req_addr : test_req_addr;
  wire [31:0] req_wdata=export_mode ? export_req_wdata : test_req_wdata;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  a0_p175_scaled_programmed_command_top #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H),.TILED_SCREEN_UV(1'b1)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),.req_ready(req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  wire export_busy,export_done,export_fault;
  wire export_pixel_valid,export_pixel_ready;
  wire [15:0] export_pixel_x,export_pixel_y;
  wire [47:0] export_pixel_data;
  wire [31:0] export_accepted;
  wire fifo_in_ready,fifo_reject,fifo_valid,fifo_ready;
  wire [31:0] fifo_addr;
  wire [47:0] fifo_data;
  wire [1:0] fifo_words;
  logic ext_read_valid=0;
  logic [31:0] ext_read_addr=0;
  wire ext_read_ready,ext_rsp_valid,ext_rsp_error;
  wire [47:0] ext_rsp_data;
  wire mem_cmd_valid,mem_cmd_ready,mem_cmd_write;
  wire [31:0] mem_cmd_addr;
  wire [47:0] mem_cmd_data;
  wire mem_rsp_valid,mem_rsp_error,read_pending,protocol_fault;
  wire [47:0] mem_rsp_data;
  wire mem_write_ready,mem_read_ready,mem_write_fault;
  wire write_fault;
  integer memory_cycle=0;
  wire allow_write=(memory_cycle%127)>=48;
  wire allow_read=(memory_cycle%7)!=0;
  always @(posedge clk)begin
    if(!rst_n)memory_cycle<=0;
    else memory_cycle<=memory_cycle+1;
  end

  a0_p198_p175_frame_snapshot_export #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H)
  ) exporter(
    .clk(clk),.rst_n(rst_n),.start(export_start),
    .busy(export_busy),.done(export_done),.fault(export_fault),
    .host_req_valid(export_req_valid),.host_req_write(export_req_write),
    .host_req_ready(req_ready),
    .host_req_addr(export_req_addr),.host_req_wdata(export_req_wdata),
    .host_rsp_valid(rsp_valid),.host_rsp_error(rsp_error),
    .host_rsp_rdata(rsp_rdata),
    .pixel_valid(export_pixel_valid),.pixel_ready(export_pixel_ready),
    .pixel_x(export_pixel_x),.pixel_y(export_pixel_y),
    .pixel_data(export_pixel_data),.queued_pixels(export_accepted)
  );
  assign export_pixel_ready=fifo_in_ready;
  a0_p195_external_pixel_write_queue #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H),.BASE_WORD_ADDR(32'h01000000)
  ) fifo(
    .clk(clk),.rst_n(rst_n),.in_valid(export_pixel_valid),
    .in_ready(fifo_in_ready),.in_x(export_pixel_x),.in_y(export_pixel_y),
    .in_pixel(export_pixel_data),.reject_valid(fifo_reject),
    .out_valid(fifo_valid),.out_ready(fifo_ready),
    .out_word_addr(fifo_addr),.out_pixel(fifo_data),
    .queued_words(fifo_words)
  );
  a0_p197_external_word_port_arbiter #(
    .FRAME_WORDS(W*H),.BASE_WORD_ADDR(32'h01000000)
  ) arbiter(
    .clk(clk),.rst_n(rst_n),
    .write_valid(fifo_valid),.write_ready(fifo_ready),
    .write_word_addr(fifo_addr),.write_pixel(fifo_data),
    .write_fault(write_fault),
    .read_valid(ext_read_valid),.read_ready(ext_read_ready),
    .read_word_addr(ext_read_addr),
    .read_rsp_valid(ext_rsp_valid),.read_rsp_error(ext_rsp_error),
    .read_rsp_pixel(ext_rsp_data),
    .mem_cmd_valid(mem_cmd_valid),.mem_cmd_ready(mem_cmd_ready),
    .mem_cmd_write(mem_cmd_write),.mem_cmd_word_addr(mem_cmd_addr),
    .mem_cmd_pixel(mem_cmd_data),
    .mem_rsp_valid(mem_rsp_valid),.mem_rsp_error(mem_rsp_error),
    .mem_rsp_pixel(mem_rsp_data),
    .read_pending(read_pending),.protocol_fault(protocol_fault)
  );
  // Logical P197 port is demultiplexed by actual synthesizable P200 RTL.
  // The two P196 memory banks below are strictly simulation-only backends.
  wire stage_bank,active_bank,active_valid,stage_active;
  wire write_permitted,read_permitted,read_leased,seal_pending,publish_pulse,epoch_fault;
  wire [31:0] committed_words,published_epochs;
  wire router_fault,router_pending,router_write_commit,router_read_accept,router_read_complete;
  wire guard0_fault,guard1_fault,guard0_pending,guard1_pending;
  wire bank0_cmd_valid,bank1_cmd_valid,bank0_cmd_write,bank1_cmd_write;
  wire [31:0] bank0_cmd_addr,bank1_cmd_addr;
  wire [47:0] bank0_cmd_data,bank1_cmd_data;
  wire bank0_cmd_ready,bank1_cmd_ready,bank0_rsp_valid,bank1_rsp_valid;
  wire bank0_rsp_error,bank1_rsp_error,bank0_write_ready,bank1_write_ready;
  wire bank0_read_ready,bank1_read_ready,bank0_write_fault,bank1_write_fault;
  wire [47:0] bank0_rsp_pixel,bank1_rsp_pixel;
  a0_p199_atomic_frame_bank_epoch #(
    .FRAME_WORDS(W*H),.BASE_WORD_ADDR(32'h01000000)
  ) epoch(
    .clk(clk),.rst_n(rst_n),.stage_begin(stage_begin),.stage_seal(stage_seal),
    .write_commit(router_write_commit),.write_word_addr(mem_cmd_addr),
    .read_accept(router_read_accept),.read_complete(router_read_complete),
    .stage_bank(stage_bank),.active_bank(active_bank),
    .active_valid(active_valid),.stage_active(stage_active),
    .write_permitted(write_permitted),.read_permitted(read_permitted),
    .read_leased(read_leased),.seal_pending(seal_pending),
    .publish_pulse(publish_pulse),.fault(epoch_fault),
    .committed_words(committed_words),.published_epochs(published_epochs)
  );
  wire coordinator_busy,coordinator_complete,coordinator_fault;
  wire [31:0] coordinator_epochs;
  a0_p201_automatic_frame_epoch_sequencer #(
    .FRAME_WORDS(W*H)
  ) coordinator(
    .clk(clk),.rst_n(rst_n),.capture_request(capture_request),
    .exporter_busy(export_busy),.exporter_done(export_done),
    .exporter_fault(export_fault),.exporter_queued_pixels(export_accepted),
    .fifo_queued_words(fifo_words),
    .stage_active(stage_active),.seal_pending(seal_pending),
    .active_valid(active_valid),.epoch_fault(epoch_fault),
    .router_fault(router_fault || guard0_fault || guard1_fault),.committed_words(committed_words),
    .published_epochs(published_epochs),
    .stage_begin(stage_begin),.export_start(export_start),
    .stage_seal(stage_seal),.busy(coordinator_busy),
    .complete_pulse(coordinator_complete),.fault(coordinator_fault),
    .completed_epochs(coordinator_epochs)
  );
  a0_p200_dual_bank_word_router #(
    .FRAME_WORDS(W*H),.BASE_WORD_ADDR(32'h01000000)
  ) router(
    .clk(clk),.rst_n(rst_n),
    .cmd_valid(mem_cmd_valid),.cmd_write(mem_cmd_write),
    .cmd_word_addr(mem_cmd_addr),.cmd_pixel(mem_cmd_data),
    .cmd_ready(mem_cmd_ready),
    .rsp_valid(mem_rsp_valid),.rsp_error(mem_rsp_error),.rsp_pixel(mem_rsp_data),
    .stage_bank(stage_bank),.active_bank(active_bank),
    .write_permitted(write_permitted),.read_permitted(read_permitted),
    .bank0_cmd_valid(bank0_cmd_valid),.bank1_cmd_valid(bank1_cmd_valid),
    .bank0_cmd_write(bank0_cmd_write),.bank1_cmd_write(bank1_cmd_write),
    .bank0_cmd_addr(bank0_cmd_addr),.bank1_cmd_addr(bank1_cmd_addr),
    .bank0_cmd_pixel(bank0_cmd_data),.bank1_cmd_pixel(bank1_cmd_data),
    .bank0_cmd_ready(bank0_cmd_ready),.bank1_cmd_ready(bank1_cmd_ready),
    .bank0_rsp_valid(bank0_rsp_valid),.bank1_rsp_valid(bank1_rsp_valid),
    .bank0_rsp_error(bank0_rsp_error),.bank1_rsp_error(bank1_rsp_error),
    .bank0_rsp_pixel(bank0_rsp_pixel),.bank1_rsp_pixel(bank1_rsp_pixel),
    .write_commit(router_write_commit),.read_accept(router_read_accept),
    .read_complete(router_read_complete),.fault(router_fault),
    .read_in_flight(router_pending)
  );
  // P202 synthesizable guards sit at the controller-facing boundary.
  // They enforce bank addresses and bounded transport responsiveness.
  // P196 below remains simulation-only; there is still no DDR or PHY.
  wire phy0_cmd_valid,phy1_cmd_valid,phy0_cmd_write,phy1_cmd_write;
  wire [31:0] phy0_cmd_addr,phy1_cmd_addr;
  wire [47:0] phy0_cmd_pixel,phy1_cmd_pixel;
  wire phy0_rsp_valid,phy1_rsp_valid,phy0_rsp_error,phy1_rsp_error;
  wire [47:0] phy0_rsp_pixel,phy1_rsp_pixel;
  a0_p202_bounded_bank_port_guard #(
    .FRAME_WORDS(W*H),.BANK_INDEX(0),.READ_TIMEOUT(1024),
    .CMD_STALL_LIMIT(1024)
  ) bank0_guard(
    .clk(clk),.rst_n(rst_n),
    .cmd_valid(bank0_cmd_valid),.cmd_write(bank0_cmd_write),
    .cmd_word_addr(bank0_cmd_addr),.cmd_pixel(bank0_cmd_data),
    .cmd_ready(bank0_cmd_ready),
    .rsp_valid(bank0_rsp_valid),.rsp_error(bank0_rsp_error),
    .rsp_pixel(bank0_rsp_pixel),
    .fault(guard0_fault),.read_pending(guard0_pending),
    .backend_cmd_valid(phy0_cmd_valid),
    .backend_cmd_write(phy0_cmd_write),
    .backend_cmd_word_addr(phy0_cmd_addr),
    .backend_cmd_pixel(phy0_cmd_pixel),
    .backend_cmd_ready(phy0_cmd_write ? bank0_write_ready : bank0_read_ready),
    .backend_rsp_valid(phy0_rsp_valid),.backend_rsp_error(phy0_rsp_error),
    .backend_rsp_pixel(phy0_rsp_pixel)
  );
  a0_p202_bounded_bank_port_guard #(
    .FRAME_WORDS(W*H),.BANK_INDEX(1),.READ_TIMEOUT(1024),
    .CMD_STALL_LIMIT(1024)
  ) bank1_guard(
    .clk(clk),.rst_n(rst_n),
    .cmd_valid(bank1_cmd_valid),.cmd_write(bank1_cmd_write),
    .cmd_word_addr(bank1_cmd_addr),.cmd_pixel(bank1_cmd_data),
    .cmd_ready(bank1_cmd_ready),
    .rsp_valid(bank1_rsp_valid),.rsp_error(bank1_rsp_error),
    .rsp_pixel(bank1_rsp_pixel),
    .fault(guard1_fault),.read_pending(guard1_pending),
    .backend_cmd_valid(phy1_cmd_valid),
    .backend_cmd_write(phy1_cmd_write),
    .backend_cmd_word_addr(phy1_cmd_addr),
    .backend_cmd_pixel(phy1_cmd_pixel),
    .backend_cmd_ready(phy1_cmd_write ? bank1_write_ready : bank1_read_ready),
    .backend_rsp_valid(phy1_rsp_valid),.backend_rsp_error(phy1_rsp_error),
    .backend_rsp_pixel(phy1_rsp_pixel)
  );
  a0_p196_external_word_memory_model #(
    .WORDS(W*H),.BASE_WORD_ADDR(32'h01000000)
  ) bank0(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(phy0_cmd_valid && phy0_cmd_write),
    .write_ready(bank0_write_ready),.write_word_addr(phy0_cmd_addr),
    .write_pixel(phy0_cmd_pixel),.write_fault(bank0_write_fault),
    .read_valid(phy0_cmd_valid && !phy0_cmd_write),
    .read_ready(bank0_read_ready),.read_word_addr(phy0_cmd_addr),
    .read_rsp_valid(phy0_rsp_valid),.read_rsp_error(phy0_rsp_error),
    .read_rsp_pixel(phy0_rsp_pixel)
  );
  a0_p196_external_word_memory_model #(
    .WORDS(W*H),.BASE_WORD_ADDR(32'h01010000)
  ) bank1(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(phy1_cmd_valid && phy1_cmd_write),
    .write_ready(bank1_write_ready),.write_word_addr(phy1_cmd_addr),
    .write_pixel(phy1_cmd_pixel),.write_fault(bank1_write_fault),
    .read_valid(phy1_cmd_valid && !phy1_cmd_write),
    .read_ready(bank1_read_ready),.read_word_addr(phy1_cmd_addr),
    .read_rsp_valid(phy1_rsp_valid),.read_rsp_error(phy1_rsp_error),
    .read_rsp_pixel(phy1_rsp_pixel)
  );

  logic [47:0] expected_export [0:2*W*H-1];
  integer accepted_export=0,committed_export=0,export_stalls=0;
  integer publications=0,old_reads=0,begins=0,seals=0,completions=0;
  always @(posedge clk)begin
    if(rst_n)begin
      if(guard0_pending && guard1_pending)
        $fatal(1,"P202 more than one bank read outstanding");
      if(export_fault)
        $display("P200 EXPORTER DEBUG state=%0d x=%0d y=%0d queued=%0d start=%b done=%b busy=%b host_req=%b host_ready=%b rsp_valid=%b rsp_error=%b",
          exporter.state_q,exporter.x_q,exporter.y_q,exporter.queued_q,
          export_start,export_done,export_busy,export_req_valid,req_ready,
          rsp_valid,rsp_error);
      if(export_fault || fifo_reject || write_fault ||
         bank0_write_fault || bank1_write_fault || protocol_fault ||
         router_fault || epoch_fault || coordinator_fault || guard0_fault || guard1_fault)
        $fatal(1,"P200 FIRST FAILURE export=%b fifo=%b write=%b bank0=%b bank1=%b protocol=%b router=%b epoch=%b accepted=%0d committed=%0d stage=%b bank=%b published=%0d epoch_commits=%0d mem_cmd_valid=%b write=%b addr=%h ready=%b rsp=%b",
          export_fault,fifo_reject,write_fault,bank0_write_fault,
          bank1_write_fault,protocol_fault,router_fault,epoch_fault,
          accepted_export,committed_export,stage_active,stage_bank,
          published_epochs,committed_words,mem_cmd_valid,mem_cmd_write,
          mem_cmd_addr,mem_cmd_ready,mem_rsp_valid);
      if(publish_pulse)publications=publications+1;
      if(stage_begin)begins=begins+1;
      if(coordinator_complete)completions=completions+1;
      if(stage_seal)begin
        seals=seals+1;
        if(committed_words!=W*H || fifo_words!=0 ||
           export_accepted!=W*H || !export_done)
          $fatal(1,"P201 premature seal commits=%0d fifo=%0d queued=%0d done=%b",
            committed_words,fifo_words,export_accepted,export_done);
      end
      if((published_epochs==1 && committed_export<W*H) ||
         (published_epochs==2 && committed_export<2*W*H))
        $fatal(1,"P201 partial frame published epoch=%0d committed=%0d",
          published_epochs,committed_export);
      if(export_pixel_valid && !export_pixel_ready)
        export_stalls=export_stalls+1;
      if(export_pixel_valid && export_pixel_ready)begin
        if(accepted_export>=2*W*H ||
           export_pixel_x!=(accepted_export%W) ||
           export_pixel_y!=((accepted_export%(W*H))/W))
          $fatal(1,"P198 incomplete/reordered host frame scan at %0d xy=%0d,%0d",
            accepted_export,export_pixel_x,export_pixel_y);
        expected_export[accepted_export]=export_pixel_data;
        accepted_export=accepted_export+1;
      end
      if(mem_cmd_valid && mem_cmd_ready && mem_cmd_write)begin
        if(committed_export>=accepted_export ||
           mem_cmd_addr!==(32'h01000000+32'(committed_export%(W*H))) ||
           mem_cmd_data!==expected_export[committed_export])
          $fatal(1,"P198 corrupted/reordered external snapshot commit at %0d",committed_export);
        committed_export=committed_export+1;
      end
    end
  end

  task automatic external_read_check(
    input logic [31:0] address,input logic [47:0] expected
  );
    integer n;
    logic accepted,responded;
    begin
      @(negedge clk);
      ext_read_valid=1;ext_read_addr=address;
      accepted=0;n=0;
      while(!accepted && n<20000)begin
        @(posedge clk);
        if(ext_read_ready)accepted=1;
        n=n+1;
      end
      if(!accepted)$fatal(1,"P198 external read handshake timeout");
      @(negedge clk);ext_read_valid=0;
      responded=0;n=0;
      while(!responded && n<20000)begin
        @(posedge clk);
        if(ext_rsp_valid)begin
          responded=1;
          if(ext_rsp_error || ext_rsp_data!==expected)
            $fatal(1,"P198 external pixel mismatch addr=%h got=%h expected=%h",
              address,ext_rsp_data,expected);
        end
        n=n+1;
      end
      if(!responded)$fatal(1,"P198 external response timeout");
    end
  endtask
  function automatic [24:0] alu_copy_r1;
    alu_copy_r1={1'b0,8'd0,4'hf,3'd0,3'd1,3'd1,3'd1};
  endfunction
  task automatic txn(input bit write_en,input logic [5:0] addr,
       input logic [31:0] data,output bit error,
       output logic [31:0] value);
    integer loops;
    bit seen;
    begin
      @(negedge clk);loops=0;
      while(!req_ready)begin
        @(negedge clk);loops=loops+1;
        if(loops>300)$fatal(1,"P194 bus not ready");
      end
      test_req_valid=1;test_req_write=write_en;test_req_addr=addr;test_req_wdata=data;
      @(posedge clk);#2;
      seen=rsp_valid;
      if(seen)begin error=rsp_error;value=rsp_rdata;end
      @(negedge clk);test_req_valid=0;
      loops=0;
      while(!seen)begin
        @(posedge clk);#2;
        if(rsp_valid)begin seen=1;error=rsp_error;value=rsp_rdata;end
        loops=loops+1;
        if(loops>500)$fatal(1,"P194 deferred response missing");
      end
    end
  endtask
  task automatic wr(input logic [5:0] addr,input logic [31:0] data);
    bit err;logic [31:0] val;
    begin
      txn(1,addr,data,err,val);
      if(err)$fatal(1,"P194 unexpected write rejection reg=%0d data=%h",addr,data);
    end
  endtask
  task automatic rd(input logic [5:0] addr,output logic [31:0] data);
    bit err;
    begin
      txn(0,addr,0,err,data);
      if(err)$fatal(1,"P194 unexpected read rejection reg=%0d",addr);
    end
  endtask
  task automatic poll(input integer bit_index);
    integer loops;
    logic [31:0] status;
    begin
      status=0;loops=0;
      while(!status[bit_index])begin
        rd(17,status);
        if(status[2])$fatal(1,"P194 core fault status=%h",status);
        loops=loops+1;
        if(loops>W*H*20+500)$fatal(1,"P194 draw/clear timeout bit=%0d",bit_index);
      end
    end
  endtask
  task automatic check_pixel(input integer x,y,
      input logic [23:0] expected_rgb,expected_z);
    logic [31:0] rgb,z;
    begin
      wr(15,{16'(y),16'(x)});
      wr(16,32'd3);
      rd(18,rgb);rd(19,z);
      if(rgb[23:0]!==expected_rgb || z[23:0]!==expected_z)
        $fatal(1,"P194 wrong global pixel %0d,%0d got %h/%h expected %h/%h",
          x,y,rgb[23:0],z[23:0],expected_rgb,expected_z);
    end
  endtask
  // Every clear transaction must write its unique global linear address.
  // This also checks the second full clear after reset, with no bypass.
  integer accepted_clear_writes=0;
  always @(posedge clk) begin
    if(!rst_n) accepted_clear_writes<=0;
    else if(dut.core.framebuffer.good_fire && dut.core.framebuffer.op_clear) begin
      if(accepted_clear_writes >= 2*W*H ||
         (int'(dut.core.fb_y_q)*W+int'(dut.core.fb_x_q)) != (accepted_clear_writes%(W*H)))
        $fatal(1,"P194 missing/reordered clear write: count=%0d xy=%0d,%0d",
          accepted_clear_writes,dut.core.fb_x_q,dut.core.fb_y_q);
      accepted_clear_writes<=accepted_clear_writes+1;
    end
  end
  bit err;
  logic [31:0] answer,insns,texops;
  initial begin
    if(W!=256 || H!=256)
      $fatal(1,"P194 test shape unsupported");
    repeat(4)@(negedge clk);rst_n=1;
    wr(0,32'h00112233);wr(1,32'h00ffffff);wr(2,32'h00000040);
    wr(3,{16'(BASE_Y),16'(BASE_X)});
    wr(4,{16'(BASE_Y),16'(BASE_X+4)});
    wr(5,{16'(BASE_Y+4),16'(BASE_X)});
    wr(6,32'd0);
    wr(7,{16'd0,8'd255,4'd0,1'b0,1'b1,2'd1});
    wr(11,32'd0);wr(12,{7'd0,alu_copy_r1()});
    wr(8,{24'd0,3'd0,5'd1}); // shader output R0, one unrelated ALU op
    wr(16,32'd1);poll(3);
    if(accepted_clear_writes!=W*H)
      $fatal(1,"P194 did not write all %0d global pixels: %0d",W*H,accepted_clear_writes);
    check_pixel(BASE_X+1,BASE_Y+1,24'h112233,24'hffffff);
    check_pixel(255,255,24'h112233,24'hffffff);
    check_pixel(0,0,24'h112233,24'hffffff);
    check_pixel(1,1,24'h112233,24'hffffff);
    // Illegal out-of-range host coordinate is rejected without corrupting the frame.
    wr(15,{16'd0,16'd256});
    txn(1,6'd16,32'd3,err,answer);
    if(!err)$fatal(1,"P194 out-of-bounds host read accepted");
    wr(16,32'd2);poll(4);
    check_pixel(BASE_X+1,BASE_Y+1,24'h000100,24'h000040);
    check_pixel(BASE_X+2,BASE_Y,24'h000200,24'h000040);
    check_pixel(1,1,24'h112233,24'hffffff);
    check_pixel(255,255,24'h112233,24'hffffff);
    rd(20,answer);rd(21,insns);rd(22,texops);
    if(answer==0 || insns!==answer || texops!==0)
      $fatal(1,"P194 first shader retirement mismatch shaded=%0d insns=%0d tex=%0d",
        answer,insns,texops);

    // Draw a second real high-corner triangle. Vertices deliberately cross
    // x/y=255; clipping must retain the 254/255 framebuffer pixels.
    // Tile-local shader R0 must distinguish 126 and 127 without wrapping.
    wr(3,{16'd252,16'd252});
    wr(4,{16'd252,16'd262});
    wr(5,{16'd262,16'd252});
    wr(16,32'd2);poll(4);
    check_pixel(254,255,24'h007e00,24'h000040);
    check_pixel(255,255,24'h007f00,24'h000040);
    check_pixel(129,129,24'h000100,24'h000040);
    check_pixel(1,1,24'h112233,24'hffffff);
    rd(20,answer);rd(21,insns);rd(22,texops);
    if(answer==0 || insns!==answer || texops!==0)
      $fatal(1,"P194 final pixel retirement mismatch shaded=%0d insns=%0d tex=%0d",
        answer,insns,texops);
    // Epoch 1: export the genuinely rendered P175 RGB+depth frame.
    if(active_valid || read_permitted)$fatal(1,"P200 zero-epoch visibility");
    @(negedge clk);capture_request=1;
    @(negedge clk);capture_request=0;export_mode=1;
    wait(stage_active);
    if(stage_bank!==1)$fatal(1,"P201 first staging bank");
    begin : first_export
      integer spins;
      spins=0;
      while((!export_done || committed_export<W*H) && spins<2000000)begin
        @(negedge clk);spins=spins+1;
      end
      if(!export_done || committed_export!=W*H ||
         accepted_export!=W*H || export_accepted!=W*H ||
         fifo_words!=0 || committed_words!=W*H || export_stalls==0)
        $fatal(1,"P200 incomplete first real export committed=%0d queued=%0d",committed_export,accepted_export);
    end
    if(active_valid || published_epochs!=0)
      $fatal(1,"P200 first frame visible before seal");
    begin : publish_one
      integer spins;
      spins=0;
      while(published_epochs!=1 && spins<10000)begin
        @(negedge clk);spins=spins+1;
      end
      if(published_epochs!=1 || active_bank!==1 || !active_valid)
        $fatal(1,"P200 first frame publication failed");
    end
    external_read_check(32'h01000000,48'h112233ffffff);
    external_read_check(32'h01000000+65535,48'h007f00000040);

    // The first published bank stays visible while P175 renders the next
    // scene into its own BRAM; the external staging bank is still untouched.
    @(negedge clk);export_mode=0;
    wr(0,32'h00556677);
    wr(1,32'h00ffffff);
    wr(16,32'd1);poll(3);
    if(accepted_clear_writes!=2*W*H)
      $fatal(1,"P200 second real P175 clear incomplete: %0d",accepted_clear_writes);
    check_pixel(0,0,24'h556677,24'hffffff);
    check_pixel(255,255,24'h556677,24'hffffff);
    external_read_check(32'h01000000,48'h112233ffffff);
    external_read_check(32'h01000000+65535,48'h007f00000040);

    // Epoch 2: the rearmed P198 exporter scans all 65,536 DIFFERENT real
    // P175 pixels into the opposite physical P196 simulation-only bank.
    @(negedge clk);capture_request=1;
    @(negedge clk);capture_request=0;export_mode=1;
    wait(stage_active);
    if(stage_bank!==0 || active_bank!==1)
      $fatal(1,"P201 second staging bank incorrect");
    fork
      begin : old_published_frame_reads
        integer k;
        wait(committed_export>W*H+20);
        for(k=0;k<200;k=k+1)begin
          if(k%2==0)
            external_read_check(32'h01000000,48'h112233ffffff);
          else
            external_read_check(32'h01000000+65535,48'h007f00000040);
          old_reads=old_reads+1;
        end
      end
      begin : second_export
        integer spins;
        spins=0;
        while((!export_done || committed_export<2*W*H) && spins<2000000)begin
          @(negedge clk);spins=spins+1;
        end
        if(!export_done || committed_export!=2*W*H ||
           accepted_export!=2*W*H || export_accepted!=W*H ||
           fifo_words!=0 || committed_words!=W*H)
          $fatal(1,"P200 incomplete second real export: committed=%0d accepted=%0d epoch=%0d",
            committed_export,accepted_export,committed_words);
      end
    join
    if(old_reads!=200)
      $fatal(1,"P201 did not verify 200 old-frame reads: %0d",old_reads);
    begin : publish_two
      integer spins;
      spins=0;
      while(published_epochs!=2 && spins<10000)begin
        @(negedge clk);spins=spins+1;
      end
      if(published_epochs!=2 || active_bank!==0 || !active_valid)
        $fatal(1,"P200 second frame publication failed");
    end
    external_read_check(32'h01000000,48'h556677ffffff);
    external_read_check(32'h01000000+257,48'h556677ffffff);
    external_read_check(32'h01000000+65535,48'h556677ffffff);
    if(publications!=2 || begins!=2 || seals!=2 ||
       coordinator_epochs!=2 || coordinator_busy || coordinator_fault ||
       router_pending || read_pending || epoch_fault || router_fault || guard0_fault || guard1_fault)
      $fatal(1,"P201 final orchestration/port fault publications=%0d begins=%0d seals=%0d completed=%0d",
        publications,begins,seals,coordinator_epochs);
    // Reset invalidates visibility even if P196 model banks retain contents.
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);rst_n=1;
    if(active_valid || published_epochs!=0 || stage_active || guard0_fault || guard1_fault)
      $fatal(1,"P200 frame lease survived reset");
    $display("P202_GUARDED_P175_EPOCH_PASS frame=256x256 epochs=2 exported=131072 old_reads=200 auto_begin=1 auto_seal=1 atomic_publish=1 reset_fail_closed=1");
    $finish;
  end
  initial begin #(W*H*1800+2000000); $fatal(1,"P201 automatic two-frame simulation timeout"); end
endmodule
