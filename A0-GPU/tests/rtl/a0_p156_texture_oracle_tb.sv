`timescale 1ns/1ps
// P156 true RTL nearest-neighbor texture sampling vs independent scalar
// signed clamp/repeat oracle. Every RGBA bit and response ID checked.
module a0_p156_texture_oracle_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,write_valid=0,sample_valid=0,sample_repeat=0,rsp_ready=1;
  reg [3:0] write_x=0,write_y=0;
  reg [31:0] write_rgba=0;
  reg signed [15:0] sample_x=0,sample_y=0;
  reg [7:0] sample_id=0;
  wire write_ready,sample_ready,rsp_valid,rsp_present;
  wire [7:0] rsp_id;
  wire [31:0] rsp_rgba;
  reg [31:0] golden[0:255];
  reg [255:0] valid_golden=0;
  reg [40:0] expected[0:8191];
  integer sent=0,received=0,all_samples=0,all_writes=0;
  integer clamp_samples=0,repeat_samples=0,stalled_output=0;
  integer continuous_inputs=0,write_stalls=0,reset_masks=0;
  integer cycle=0;
  reg stall_mode=0;
  a0_p156_nearest_texture dut(
    .clk(clk),.rst_n(rst_n),
    .write_valid(write_valid),.write_ready(write_ready),
    .write_x(write_x),.write_y(write_y),.write_rgba(write_rgba),
    .sample_valid(sample_valid),.sample_ready(sample_ready),
    .sample_x(sample_x),.sample_y(sample_y),.sample_repeat(sample_repeat),
    .sample_id(sample_id),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_rgba(rsp_rgba),.rsp_present(rsp_present)
  );
  function automatic integer tex_index(
    input integer xx,yy,input reg repeat_uv
  );
    integer px,py;
    begin
      if(repeat_uv)begin
        px=xx & 15;py=yy & 15;
      end else begin
        px=xx<0?0:(xx>15?15:xx);
        py=yy<0?0:(yy>15?15:yy);
      end
      tex_index=py*16+px;
    end
  endfunction
  always @(posedge clk)begin
    cycle=cycle+1;
    if(!rst_n)begin
      sent=0;received=0;
      valid_golden='0;
    end else begin
      if(rsp_valid && !rsp_ready)stalled_output=stalled_output+1;
      if(rsp_valid && rsp_ready)begin
        if(received>=sent)$fatal(1,"P156 phantom texture response");
        if({rsp_id,rsp_present,rsp_rgba}!==expected[received])
          $fatal(1,"P156 wrong texture reply #%0d expected=%h actual=%h",
            received,expected[received],{rsp_id,rsp_present,rsp_rgba});
        received=received+1;
      end
      if(sample_valid && sample_ready)begin
        if(sent>=8191)$fatal(1,"P156 scoreboard exhausted");
        if(valid_golden[tex_index(int'(sample_x),int'(sample_y),sample_repeat)])
          expected[sent]={sample_id,1'b1,golden[tex_index(int'(sample_x),int'(sample_y),sample_repeat)]};
        else expected[sent]={sample_id,1'b0,32'd0};
        sent=sent+1;
        all_samples=all_samples+1;
        if(sample_repeat)repeat_samples=repeat_samples+1;
        else clamp_samples=clamp_samples+1;
      end
      if(write_valid && write_ready)begin
        golden[int'(write_y)*16+int'(write_x)]=write_rgba;
        valid_golden[int'(write_y)*16+int'(write_x)]=1;
        all_writes=all_writes+1;
      end
    end
  end
  always @(negedge clk)if(stall_mode)rsp_ready=(cycle%11>=4);

  task automatic write_texel(input integer xx,yy,input reg [31:0] value);
    integer tries;
    begin
      @(negedge clk);sample_valid=0;
      write_valid=1;write_x=4'(xx);write_y=4'(yy);write_rgba=value;
      tries=0;
      while(!write_ready)begin
        @(negedge clk);
        tries=tries+1;if(tries>400)$fatal(1,"P156 write starvation");
      end
      @(posedge clk);
      @(negedge clk);write_valid=0;
    end
  endtask
  task automatic sample_texel(
    input integer xx,yy,input reg repeat_uv,input reg [7:0] tag
  );
    integer tries;
    begin
      @(negedge clk);write_valid=0;
      sample_valid=1;sample_x=16'(xx);sample_y=16'(yy);
      sample_repeat=repeat_uv;sample_id=tag;
      #1;tries=0;
      while(!sample_ready)begin
        @(negedge clk);#1;
        tries=tries+1;if(tries>400)$fatal(1,"P156 sample starvation");
      end
      @(posedge clk);
      @(negedge clk);sample_valid=0;
    end
  endtask
  task automatic drain;
    integer tries;
    begin
      tries=0;
      while(received<sent)begin
        @(negedge clk);
        tries=tries+1;
        if(tries>400)$fatal(1,"P156 response not drained: %0d/%0d",received,sent);
      end
    end
  endtask
  reg [31:0] held_color;
  reg [7:0] held_tag;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    // Unwritten texture RAM remains undisclosed after reset.
    sample_texel(-1,-1,0,8'h11);
    drain();
    for(integer y=0;y<16;y=y+1)
      for(integer x=0;x<16;x=x+1)
        write_texel(x,y,32'hcf0b5923 ^ (32'(y)*32'h01020304) ^ (32'(x)*32'hde13a907));
    // 128 true consecutive accepted texture reads, one request/clock.
    sample_valid=1;rsp_ready=1;stall_mode=0;
    for(integer k=0;k<128;k=k+1)begin
      @(negedge clk);
      sample_id=8'(k);
      sample_x=16'(k*37-123);
      sample_y=16'(k*19-71);
      sample_repeat=1'(k);
      #1;
      if(!sample_ready)$fatal(1,"P156 lost 1/clk texture read");
      @(posedge clk);
      continuous_inputs=continuous_inputs+1;
    end
    @(negedge clk);sample_valid=0;
    drain();

    stall_mode=1;
    for(integer k=0;k<2048;k=k+1)
      sample_texel(k*313-25000,k*91-10000,1'(k>>1),8'(k+37));
    drain();
    stall_mode=0;
    @(negedge clk);rsp_ready=1;
    if(sent!=received)$fatal(1,"P156 lost randomized texture replies");

    // Sample wins same-cycle contention; the refused write must not
    // change the addressed texture cell. Then apply a legal write.
    @(negedge clk);
    sample_valid=1;sample_x=5;sample_y=7;sample_repeat=0;sample_id=8'h99;
    write_valid=1;write_x=5;write_y=7;write_rgba=32'hAABBCCDD;
    #1;if(!sample_ready || write_ready)
      $fatal(1,"P156 single-port sample/write arbitration broken");
    write_stalls=write_stalls+1;
    @(posedge clk);
    @(negedge clk);sample_valid=0;write_valid=0;
    drain();
    sample_texel(5,7,0,8'h9a);drain();
    write_texel(5,7,32'hAABBCCDD);
    sample_texel(5,7,0,8'h9b);drain();

    // Hold the output while host is unready, verify ID/data/present
    // are stable and input cannot overwrite it.
    @(negedge clk);rsp_ready=0;
    sample_texel(-33,111,1,8'he1);
    @(negedge clk);
    if(!rsp_valid)$fatal(1,"P156 no pending result for host stall");
    held_color=rsp_rgba;held_tag=rsp_id;
    sample_valid=1;sample_id=8'he2;
    repeat(20)begin
      @(negedge clk);#1;
      if(!rsp_valid || sample_ready || rsp_id!==held_tag ||
         rsp_rgba!==held_color || !rsp_present)
        $fatal(1,"P156 held texture response overwritten");
    end
    sample_valid=0;rsp_ready=1;drain();

    // Physical reset invalidates the texel-present bitmap and flushes
    // the pending response; no old RGBA bytes may be exposed.
    @(negedge clk);rsp_ready=0;
    sample_texel(5,7,0,8'he3);
    @(negedge clk);
    if(!rsp_valid)$fatal(1,"P156 missing held response before reset");
    rst_n=0;
    repeat(3)@(negedge clk);
    if(rsp_valid || sample_ready || write_ready)
      $fatal(1,"P156 reset leaked response or accepted request");
    rst_n=1;rsp_ready=1;
    sample_texel(5,7,0,8'he4);
    drain();
    reset_masks=reset_masks+1;
    write_texel(5,7,32'h12345678);
    sample_texel(5,7,1,8'he5);
    drain();
    if(all_samples<2170 || all_writes<257 || clamp_samples<1000 ||
       repeat_samples<1000 || continuous_inputs!=128 ||
       stalled_output<20 || write_stalls!=1 || reset_masks!=1)
      $fatal(1,"P156 insufficient sampling/arbiter/host-stall coverage samples=%0d writes=%0d clamp=%0d repeat=%0d stalled=%0d",
        all_samples,all_writes,clamp_samples,repeat_samples,stalled_output);
    $display("P156_TEXTURE_NEAREST_GOLDEN_PASS samples=%0d initialized_writes=%0d clamps=%0d repeats=%0d 1perclock_inputs=%0d held_response_cycles=%0d read_write_collisions=%0d reset_mask_checks=%0d",
      all_samples,all_writes,clamp_samples,repeat_samples,continuous_inputs,stalled_output,write_stalls,reset_masks);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P156 texture RTL watchdog");end
endmodule
