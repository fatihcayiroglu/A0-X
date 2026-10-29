`timescale 1ns/1ps
// P226: remove valid-to-zero data mux after P224 registered pixel ingress;
// reset asserts asynchronously,
// but each domain releases *its own*
// reset on a local rising edge, after synchronizing remote two-edge ready.
// Cross-domain ready is a one-way sticky level, not a clock/data path. The
// AND-combined status is NEVER fed into domain sequential logic.
module a0_p226_split_reset_supervisor(
  input logic host_clk,pixel_clk,raw_rst_n,
  output wire host_rst_n,pixel_rst_n,
  output wire both_released
);
  (* async_reg="true" *) logic [1:0] host_ready_q,pixel_ready_q;
  (* async_reg="true" *) logic pixel_ready_meta_h_q,pixel_ready_sync_h_q;
  (* async_reg="true" *) logic host_ready_meta_p_q,host_ready_sync_p_q;
  logic host_up_q,pixel_up_q;
  always_ff @(posedge host_clk or negedge raw_rst_n)begin
    if(!raw_rst_n)begin
      host_ready_q<=0;pixel_ready_meta_h_q<=0;pixel_ready_sync_h_q<=0;
      host_up_q<=0;
    end else begin
      host_ready_q<={host_ready_q[0],1'b1};
      pixel_ready_meta_h_q<=pixel_ready_q[1];
      pixel_ready_sync_h_q<=pixel_ready_meta_h_q;
      if(host_ready_q[1] && pixel_ready_sync_h_q)host_up_q<=1;
    end
  end
  always_ff @(posedge pixel_clk or negedge raw_rst_n)begin
    if(!raw_rst_n)begin
      pixel_ready_q<=0;host_ready_meta_p_q<=0;host_ready_sync_p_q<=0;
      pixel_up_q<=0;
    end else begin
      pixel_ready_q<={pixel_ready_q[0],1'b1};
      host_ready_meta_p_q<=host_ready_q[1];
      host_ready_sync_p_q<=host_ready_meta_p_q;
      if(pixel_ready_q[1] && host_ready_sync_p_q)pixel_up_q<=1;
    end
  end
  assign host_rst_n=raw_rst_n && host_up_q;
  assign pixel_rst_n=raw_rst_n && pixel_up_q;
  assign both_released=host_rst_n && pixel_rst_n;
endmodule

// Same exact 83 top-level I/O bits as P215. No shared deasserted reset
// drives both domains; the combined status is for diagnostics/tests only.
module a0_p226_domain_local_reset_raster #(
  parameter integer H_ACTIVE=32,V_ACTIVE=32,
  parameter integer H_FRONT=8,H_SYNC=4,H_BACK=8,
  parameter integer V_FRONT=2,V_SYNC=2,V_BACK=2,
  parameter integer PIXEL_DIV=64,FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic host_clk,pixel_clk,rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic host_fault,host_busy,pixel_fault,
  output logic pixel_ce,video_de,video_hsync,video_vsync,
  output logic [47:0] video_pixel
);
  wire host_rst_n,pixel_rst_n,fabric_rst_n;
  a0_p226_split_reset_supervisor reset_guard(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.raw_rst_n(rst_n),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .both_released(fabric_rst_n)
  );
  a0_p226_split_domain_raster #(
    .H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),
    .H_FRONT(H_FRONT),.H_SYNC(H_SYNC),.H_BACK(H_BACK),
    .V_FRONT(V_FRONT),.V_SYNC(V_SYNC),.V_BACK(V_BACK),
    .PIXEL_DIV(PIXEL_DIV),.FIFO_ADDR_BITS(FIFO_ADDR_BITS),
    .BASE_WORD_ADDR(BASE_WORD_ADDR),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) raster(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .host_fault(host_fault),.host_busy(host_busy),
    .pixel_fault(pixel_fault),.pixel_ce(pixel_ce),
    .video_de(video_de),.video_hsync(video_hsync),
    .video_vsync(video_vsync),.video_pixel(video_pixel)
  );
endmodule

`timescale 1ns/1ps
// P212 independent-clock, power-of-two ready/valid FIFO.
// CDC: Gray-coded read/write pointers, *two clocked sync flops per direction*.
// External reset assertion reaches both domains; each domain-local release
// follows its own clock and FIFO's own two-cycle release pipeline. BRAM payload is never read across domains without a pointer
// handshake. A prefetched output register remains stable under backpressure.
// This is a simulation/FPGA implementation, NOT a proof of metastability MTBF.
module a0_p226_split_reset_fifo #(
  parameter integer WIDTH=92,
  parameter integer ADDR_BITS=6
)(
  input logic wr_clk,rd_clk,wr_rst_n,rd_rst_n,
  input logic wr_valid,
  output logic wr_ready,
  input logic [WIDTH-1:0] wr_data,
  output logic rd_valid,
  input logic rd_ready,
  output logic [WIDTH-1:0] rd_data
);
  localparam integer DEPTH=(1<<ADDR_BITS);
  // P236 ECP5 integration: require a real dual-clock EBR rather than
  // distributed LUT RAM when instantiated as the upload CDC FIFO.
  (* ram_style="block" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR_BITS:0] wbin_q=0,wgray_q=0,rbin_q=0,rgray_q=0;
  (* async_reg = "true" *) logic [ADDR_BITS:0] w_rgray_meta_q=0,w_rgray_sync_q=0;
  (* async_reg = "true" *) logic [ADDR_BITS:0] r_wgray_meta_q=0,r_wgray_sync_q=0;
  (* async_reg = "true" *) logic w_release_meta_q=0,w_release_q=0;
  (* async_reg = "true" *) logic r_release_meta_q=0,r_release_q=0;
  logic rd_valid_q;
  logic [WIDTH-1:0] rd_data_q;
  function automatic [ADDR_BITS:0] gray(input logic [ADDR_BITS:0] binary);
    gray=(binary>>1)^binary;
  endfunction
  wire [ADDR_BITS:0] wbin_next=wbin_q+1'b1;
  wire [ADDR_BITS:0] wgray_next=gray(wbin_next);
  wire full=(wgray_q==
      {~w_rgray_sync_q[ADDR_BITS:ADDR_BITS-1],
        w_rgray_sync_q[ADDR_BITS-2:0]});
  wire empty=(rgray_q==r_wgray_sync_q);
  wire write_fire=wr_valid && wr_ready;
  // P223: refill the registered EBR output on the *same* edge that the
  // previous ready/valid beat is accepted. Keep the head unchanged on stall.
  // rgray_q already points beyond the prefetched word, so !empty guards
  // the next, not the current, unread RAM entry. No speculative empty read.
  wire consume=rd_valid && rd_ready;
  wire prefetch=r_release_q && !empty && (!rd_valid_q || consume);
  assign wr_ready=wr_rst_n && w_release_q && !full;
  assign rd_valid=rd_rst_n && r_release_q && rd_valid_q;
  // P226 second physical-area iteration: FIFO payload is defined only when
  // rd_valid is asserted. The downstream pixel pipeline captures data solely
  // on valid, so a 92-bit zero-on-invalid mux is not an observable contract.
  assign rd_data=rd_data_q;
  always_ff @(posedge wr_clk or negedge wr_rst_n)begin
    if(!wr_rst_n)begin
      wbin_q<=0;wgray_q<=0;
      w_rgray_meta_q<=0;w_rgray_sync_q<=0;
      w_release_meta_q<=0;w_release_q<=0;
    end else begin
      w_release_meta_q<=1;
      w_release_q<=w_release_meta_q;
      w_rgray_meta_q<=rgray_q;
      w_rgray_sync_q<=w_rgray_meta_q;
      if(write_fire)begin wbin_q<=wbin_next;wgray_q<=wgray_next;end
    end
  end
  always_ff @(posedge wr_clk)if(write_fire)
    mem[wbin_q[ADDR_BITS-1:0]]<=wr_data;
  always_ff @(posedge rd_clk or negedge rd_rst_n)begin
    if(!rd_rst_n)begin
      rbin_q<=0;rgray_q<=0;rd_valid_q<=0;
      r_wgray_meta_q<=0;r_wgray_sync_q<=0;
      r_release_meta_q<=0;r_release_q<=0;
    end else begin
      r_release_meta_q<=1;
      r_release_q<=r_release_meta_q;
      r_wgray_meta_q<=wgray_q;
      r_wgray_sync_q<=r_wgray_meta_q;
      if(prefetch)begin
        rbin_q<=rbin_q+1'b1;
        rgray_q<=gray(rbin_q+1'b1);
        rd_valid_q<=1;
      end else if(rd_valid_q && rd_ready)rd_valid_q<=0;
    end
  end
  // Registered read enables inference of real dual-clock block RAM.
  always_ff @(posedge rd_clk)if(prefetch)
    rd_data_q<=mem[rbin_q[ADDR_BITS-1:0]];
  initial begin
    if(WIDTH<1 || ADDR_BITS<2 || ADDR_BITS>10)
      $fatal(1,"P212 unsupported asynchronous FIFO dimensions");
  end
endmodule


`timescale 1ns/1ps
// P212: bridge unchanged P210 frame-fenced physical EBR producer to a
// separately clocked pixel consumer through a lossless Gray-pointer FIFO.
// The P210 final-pixel fence now means FIFO *enqueue*, not sink consumption.
// Every pixel is tagged with its 10-bit index and 32-bit epoch so downstream
// can detect frame boundaries without mixing generations.
module a0_p226_split_reset_queue #(
  parameter integer WORDS=1024,
  parameter integer FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic host_clk,pixel_clk,host_rst_n,pixel_rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic fault,busy,
  input logic pixel_ready,
  output logic pixel_valid,pixel_fault,
  output logic [47:0] pixel_data,
  output logic [9:0] pixel_index,
  output logic [31:0] pixel_epoch,
  output logic frame_start,frame_end
);
  wire source_fault,source_busy,source_valid,queue_wr_ready;
  wire [47:0] source_data;
  wire [9:0] source_index;
  wire [31:0] source_epoch;
  wire source_start,source_end;
  wire [91:0] fifo_data;
  wire fifo_valid;
  (* async_reg="true" *) logic pix_fault_meta_q,pix_fault_q;
  assign fault=source_fault;
  assign busy=source_busy || !queue_wr_ready;
  assign pixel_fault=pix_fault_q;
  assign pixel_valid=fifo_valid && !pix_fault_q;
  assign {frame_end,frame_start,pixel_epoch,pixel_index,pixel_data}=
    fifo_data; // Validity remains in pixel_valid; no invalid payload may be consumed.
  a0_p210_frame_boundary_stream #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR),
    .RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) source(
    .clk(host_clk),.rst_n(host_rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(source_fault),.busy(source_busy),
    .pixel_ready(queue_wr_ready),.pixel_valid(source_valid),
    .pixel_data(source_data),.pixel_index(source_index),
    .pixel_epoch(source_epoch),.frame_start(source_start),
    .frame_end(source_end)
  );
  a0_p226_split_reset_fifo #(.WIDTH(92),.ADDR_BITS(FIFO_ADDR_BITS)) queue(
    .wr_clk(host_clk),.rd_clk(pixel_clk),
    .wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n),
    .wr_valid(source_valid && !source_fault),
    .wr_ready(queue_wr_ready),
    .wr_data({source_end,source_start,source_epoch,source_index,source_data}),
    .rd_valid(fifo_valid),.rd_ready(pixel_ready && !pix_fault_q),
    .rd_data(fifo_data)
  );
  always_ff @(posedge pixel_clk or negedge pixel_rst_n)begin
    if(!pixel_rst_n)begin pix_fault_meta_q<=0;pix_fault_q<=0;end
    else begin pix_fault_meta_q<=source_fault;pix_fault_q<=pix_fault_meta_q;end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0))
      $fatal(1,"P212 unsupported frame words");
  end
endmodule


`timescale 1ns/1ps
// P214: reset-scrubbed pixel-clock 2-bank staging + atomic VBlank
// display publication. Full frame transport comes from the P212 Gray FIFO.
// Duplicate COMPLETE source epochs are drained without being displayed
// multiple times; only a completely received new epoch can swap at VBlank.
// Still a clock-enable raster, NOT HDMI/DP or an independent pixel PLL.
module a0_p226_split_domain_raster #(
  parameter integer H_ACTIVE=32,V_ACTIVE=32,
  parameter integer H_FRONT=8,H_SYNC=4,H_BACK=8,
  parameter integer V_FRONT=2,V_SYNC=2,V_BACK=2,
  parameter integer PIXEL_DIV=64,FIFO_ADDR_BITS=6,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer RESPONSE_TIMEOUT=1024
)(
  input logic host_clk,pixel_clk,host_rst_n,pixel_rst_n,
  input logic host_valid,host_write,
  input logic [5:0] host_addr,
  input logic [7:0] host_wdata,
  output logic host_ready,
  output logic [7:0] host_rdata,
  output logic host_fault,host_busy,pixel_fault,
  output logic pixel_ce,video_de,video_hsync,video_vsync,
  output logic [47:0] video_pixel
);
  localparam integer WORDS=H_ACTIVE*V_ACTIVE;
  localparam integer HT=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
  localparam integer VT=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
  // These are pixel-clock-local BRAM frame images; no reset data dependency.
  (* ram_style = "block" *) logic [47:0] frame0 [0:WORDS-1];
  (* ram_style = "block" *) logic [47:0] frame1 [0:WORDS-1];
  logic [47:0] front_read0_q,front_read1_q;
  wire [47:0] front_read_word=front_bank_q ? front_read1_q : front_read0_q;
  logic [15:0] h_q,v_q,div_q;
  logic run_q,front_valid_q,front_bank_q,stage_valid_q,stage_bank_q;
  logic [31:0] front_epoch_q,stage_epoch_q;
  logic [9:0] ingest_index_q;
  logic [31:0] ingest_epoch_q;
  logic ingest_skip_q,ingest_bank_q,local_fault_q;
  logic [15:0] duplicate_frames_q;
  logic [9:0] scrub_addr_q;
  logic scrub_done_q;
  wire bank_scrub_write=!scrub_done_q;
  wire bank0_write=bank_scrub_write ||
       (consume && !bad_sample && !skip_ingest && !target_bank);
  wire bank1_write=bank_scrub_write ||
       (consume && !bad_sample && !skip_ingest && target_bank);
  wire [9:0] bank_write_addr=bank_scrub_write ? scrub_addr_q : src_index;
  wire [47:0] bank_write_data=bank_scrub_write ? 48'd0 : src_data;
  // P224: a one-pixel-clock valid/data register cuts the long path from
  // the P223 FIFO's physical EBR output to epoch comparison and bank write.
  // The upstream FIFO remains zero-bubble; this is a full-throughput one
  // beat per pixel edge register stage, without speculative dequeue.
  wire queue_valid,queue_fault,queue_start,queue_end;
  wire [47:0] queue_data;
  wire [9:0] queue_index;
  wire [31:0] queue_epoch;
  logic pipe_valid_q;
  logic [91:0] pipe_packet_q;
  wire src_valid=pipe_valid_q;
  wire src_fault=queue_fault;
  wire src_start,src_end;
  wire [47:0] src_data;
  wire [9:0] src_index;
  wire [31:0] src_epoch;
  // P226: use raw, pixel-clock-registered EBR data. Each consuming action
  // is explicitly guarded by 'consume' (which requires pipe_valid_q).
  // The old per-bit valid-to-zero mux formed 92 LUT paths before the
  // 32-bit epoch checks; removing it does NOT bypass any write/error gate.
  // Reset still clears both validity and payload asynchronously.
  assign {src_end,src_start,src_epoch,src_index,src_data}=pipe_packet_q;
  always_ff @(posedge pixel_clk or negedge pixel_rst_n)begin
    if(!pixel_rst_n)begin
      pipe_valid_q<=0;
      pipe_packet_q<=0;
    end else if(pixel_stream_ready)begin
      // source uses this same ready for its posedge handshake.
      // Processing sees the previous packet at this posedge.
      pipe_valid_q<=queue_valid;
      if(queue_valid)
        pipe_packet_q<={queue_end,queue_start,queue_epoch,queue_index,queue_data};
    end
  end
  wire consume=src_valid && scrub_done_q && !local_fault_q && !src_fault;
  wire first_ingest=(ingest_index_q==10'd0);
  wire last_ingest=(ingest_index_q==10'(WORDS-1));
  wire duplicate_start=
    (front_valid_q && src_epoch==front_epoch_q) ||
    (stage_valid_q && src_epoch==stage_epoch_q);
  wire skip_ingest=first_ingest ? duplicate_start : ingest_skip_q;
  wire target_bank=first_ingest ?
      (front_valid_q ? !front_bank_q : 1'b0) : ingest_bank_q;
  wire bad_index=src_index!=ingest_index_q;
  wire bad_marker=src_start!=first_ingest || src_end!=last_ingest;
  wire bad_epoch=src_epoch==32'd0 ||
      (!first_ingest && src_epoch!=ingest_epoch_q) ||
      (first_ingest && front_valid_q && src_epoch<front_epoch_q) ||
      (first_ingest && stage_valid_q && src_epoch<stage_epoch_q);
  wire bad_sample=bad_index || bad_marker || bad_epoch;
  wire discard_stage=consume && first_ingest && !bad_sample && !skip_ingest;
  wire active=(h_q<H_ACTIVE && v_q<V_ACTIVE);
  wire tick=run_q && div_q==16'(PIXEL_DIV-1);
  // P233: 2-cycle scanout is valid: prefetch on div=0, consume on div=1.
  // DIV=1 still needs an anticipatory next-address prefetch and stays illegal.
  wire prefetch=run_q && div_q==16'(PIXEL_DIV-2) &&
       active && !pixel_fault;
  wire [9:0] display_index=10'(v_q*H_ACTIVE+h_q);
  wire frame_boundary=tick && h_q==16'(HT-1) && v_q==16'(VT-1);
  wire pixel_stream_ready=scrub_done_q && !local_fault_q && !src_fault;
  assign pixel_fault=local_fault_q || src_fault;
  a0_p226_split_reset_queue #(
    .WORDS(WORDS),.FIFO_ADDR_BITS(FIFO_ADDR_BITS),
    .BASE_WORD_ADDR(BASE_WORD_ADDR),.RESPONSE_TIMEOUT(RESPONSE_TIMEOUT)
  ) source(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(host_fault),.busy(host_busy),
    .pixel_ready(pixel_stream_ready),
    .pixel_valid(queue_valid),.pixel_fault(queue_fault),
    .pixel_data(queue_data),.pixel_index(queue_index),
    .pixel_epoch(queue_epoch),.frame_start(queue_start),
    .frame_end(queue_end)
  );
  // Explicit dual-port same-pixel-clock RAM semantics: write the staging
  // bank while displaying the immutable opposite front bank.
  always_ff @(posedge pixel_clk)begin
    if(bank0_write)frame0[bank_write_addr]<=bank_write_data;
    if(bank1_write)frame1[bank_write_addr]<=bank_write_data;
    if(prefetch && front_bank_q)front_read1_q<=frame1[display_index];
    if(prefetch && !front_bank_q)front_read0_q<=frame0[display_index];
  end
  always_ff @(posedge pixel_clk or negedge pixel_rst_n)begin
    if(!pixel_rst_n)begin
      h_q<=0;v_q<=0;div_q<=0;run_q<=0;
      front_valid_q<=0;front_bank_q<=0;front_epoch_q<=0;
      stage_valid_q<=0;stage_bank_q<=0;stage_epoch_q<=0;
      ingest_index_q<=0;ingest_epoch_q<=0;
      ingest_skip_q<=0;ingest_bank_q<=0;
      local_fault_q<=0;duplicate_frames_q<=0;
      scrub_addr_q<=0;scrub_done_q<=0;
      pixel_ce<=0;video_de<=0;video_hsync<=1;video_vsync<=1;
      video_pixel<=0;
    end else begin
      pixel_ce<=0;
      if(!scrub_done_q)begin
        if(scrub_addr_q==10'(WORDS-1))scrub_done_q<=1;
        else scrub_addr_q<=scrub_addr_q+10'd1;
      end
      if(src_fault)local_fault_q<=1;
      if(consume)begin
        if(bad_sample)local_fault_q<=1;
        else begin
          if(first_ingest)begin
            ingest_epoch_q<=src_epoch;
            ingest_skip_q<=skip_ingest;
            ingest_bank_q<=target_bank;
            if(!skip_ingest)stage_valid_q<=0;
          end
          if(last_ingest)begin
            ingest_index_q<=0;
            if(skip_ingest)duplicate_frames_q<=duplicate_frames_q+16'd1;
            else begin
              stage_valid_q<=1;
              stage_bank_q<=target_bank;
              stage_epoch_q<=src_epoch;
            end
          end else ingest_index_q<=ingest_index_q+10'd1;
        end
      end
      if(!run_q)begin
        if(stage_valid_q && !discard_stage && !pixel_fault)begin
          front_valid_q<=1;front_bank_q<=stage_bank_q;
          front_epoch_q<=stage_epoch_q;stage_valid_q<=0;
          h_q<=0;v_q<=0;div_q<=0;run_q<=1;
        end
      end else begin
        if(tick)begin
          div_q<=0;pixel_ce<=1;
          video_hsync<=!(h_q>=H_ACTIVE+H_FRONT &&
                          h_q<H_ACTIVE+H_FRONT+H_SYNC);
          video_vsync<=!(v_q>=V_ACTIVE+V_FRONT &&
                          v_q<V_ACTIVE+V_FRONT+V_SYNC);
          video_de<=active && front_valid_q && !pixel_fault;
          video_pixel<=(active && front_valid_q && !pixel_fault) ?
                         front_read_word : 48'd0;
          if(h_q==16'(HT-1))begin
            h_q<=0;
            if(v_q==16'(VT-1))v_q<=0;
            else v_q<=v_q+16'd1;
          end else h_q<=h_q+16'd1;
          if(frame_boundary && stage_valid_q && !discard_stage &&
             !pixel_fault)begin
            front_bank_q<=stage_bank_q;front_epoch_q<=stage_epoch_q;
            stage_valid_q<=0;
          end
        end else div_q<=div_q+16'd1;
      end
      if(local_fault_q || src_fault)begin
        video_de<=0;video_pixel<=0;
      end
    end
  end
  initial begin
    if(WORDS<4 || WORDS>1024 || ((WORDS & (WORDS-1))!=0) ||
       H_ACTIVE<2 || V_ACTIVE<2 ||
       H_FRONT<1 || H_SYNC<1 || H_BACK<1 ||
       V_FRONT<1 || V_SYNC<1 || V_BACK<1 ||
       HT>65535 || VT>65535 || PIXEL_DIV<2 || PIXEL_DIV>65535 ||
       FIFO_ADDR_BITS<2 || FIFO_ADDR_BITS>10)
      $fatal(1,"P213 unsupported pixel-local raster geometry");
  end
endmodule
