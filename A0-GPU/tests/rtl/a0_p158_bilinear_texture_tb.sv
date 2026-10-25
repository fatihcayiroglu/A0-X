`timescale 1ns/1ps
// Independent integer Q8.8/two-stage rounding oracle for four real P156
// synchronous BRAM reads. No internal DUT data is used as expected output.
module a0_p158_bilinear_texture_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,write_valid=0,sample_valid=0,sample_repeat=0,rsp_ready=1;
  reg [3:0] write_x=0,write_y=0;
  reg [31:0] write_rgba=0;
  reg signed [15:0] sample_u=0,sample_v=0;
  reg [7:0] sample_id=0;
  wire write_ready,sample_ready,rsp_valid,rsp_present;
  wire [7:0] rsp_id;
  wire [31:0] rsp_rgba;
  reg [31:0] golden[0:255];
  reg [255:0] initialized=0;
  integer checked=0,missing=0,stalled=0,clamped=0,repeated=0;
  integer writes=0,contentions=0,resets=0;
  a0_p158_bilinear_texture dut(
    .clk(clk),.rst_n(rst_n),
    .write_valid(write_valid),.write_ready(write_ready),
    .write_x(write_x),.write_y(write_y),.write_rgba(write_rgba),
    .sample_valid(sample_valid),.sample_ready(sample_ready),
    .sample_u(sample_u),.sample_v(sample_v),
    .sample_repeat(sample_repeat),.sample_id(sample_id),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_rgba(rsp_rgba),.rsp_present(rsp_present)
  );

  function automatic integer index_xy(input integer x,y,rep);
    integer xx,yy;
    begin
      xx=rep?(x&15):(x<0?0:(x>15?15:x));
      yy=rep?(y&15):(y<0?0:(y>15?15:y));
      index_xy=yy*16+xx;
    end
  endfunction
  function automatic integer channel(input integer idx,lane);
    begin
      channel=initialized[idx]?((golden[idx]>>(8*lane))&255):0;
    end
  endfunction
  function automatic [31:0] expected_color(input integer u,v,rep);
    integer x,y,fx,fy,i0,i1,i2,i3,lane,a,b,c,d,h0,h1;
    reg [31:0] result;
    begin
      x=u>>>8;y=v>>>8;fx=u&255;fy=v&255;
      i0=index_xy(x,y,rep);i1=index_xy(x+1,y,rep);
      i2=index_xy(x,y+1,rep);i3=index_xy(x+1,y+1,rep);
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=channel(i0,lane);b=channel(i1,lane);
        c=channel(i2,lane);d=channel(i3,lane);
        h0=(a*(256-fx)+b*fx+128)/256;
        h1=(c*(256-fx)+d*fx+128)/256;
        result[8*lane+:8]=8'((h0*(256-fy)+h1*fy+128)/256);
      end
      expected_color=result;
    end
  endfunction
  function automatic expected_present(input integer u,v,rep);
    integer x,y,fx,fy,i0,i1,i2,i3;
    begin
      x=u>>>8;y=v>>>8;fx=u&255;fy=v&255;
      i0=index_xy(x,y,rep);i1=index_xy(x+1,y,rep);
      i2=index_xy(x,y+1,rep);i3=index_xy(x+1,y+1,rep);
      expected_present=initialized[i0] &&
        (fx==0 || initialized[i1]) &&
        (fy==0 || initialized[i2]) &&
        (fx==0 || fy==0 || initialized[i3]);
    end
  endfunction

  task automatic store(input integer x,y,input [31:0] rgba);
    begin
      @(negedge clk);write_valid=1;
      write_x=4'(x);write_y=4'(y);write_rgba=rgba;
      #1;if(!write_ready)$fatal(1,"P158 idle write refused");
      @(negedge clk);write_valid=0;
      golden[y*16+x]=rgba;initialized[y*16+x]=1;
      writes=writes+1;
    end
  endtask
  task automatic sample(input integer u,v,rep,k,hold);
    integer cycles;
    reg [31:0] expected,held_rgba;
    reg present,held_present;
    reg [7:0] held_id;
    begin
      @(negedge clk);
      sample_u=16'(u);sample_v=16'(v);sample_repeat=1'(rep);
      sample_id=8'(k);sample_valid=1;
      expected=expected_color(u,v,rep);
      present=expected_present(u,v,rep);
      #1;if(!sample_ready)$fatal(1,"P158 idle sampler refused");
      @(negedge clk);sample_valid=0;
      cycles=0;
      while(!rsp_valid)begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>30)$fatal(1,"P158 4-tap timeout");
      end
      if(rsp_id!==8'(k) || rsp_rgba!==expected || rsp_present!==present)
        $fatal(1,"P158 oracle mismatch k=%0d uv=%0d,%0d repeat=%0d expected=%h/%b got=%h/%b id=%h",
          k,u,v,rep,expected,present,rsp_rgba,rsp_present,rsp_id);
      if(hold)begin
        rsp_ready=0;held_rgba=rsp_rgba;
        held_id=rsp_id;held_present=rsp_present;
        // Other clients may request while output is stalled, but cannot
        // overwrite the response or write into its source texture.
        sample_valid=1;write_valid=1;
        repeat(6)begin
          @(negedge clk);#1;
          if(!rsp_valid || sample_ready || write_ready ||
             rsp_rgba!==held_rgba || rsp_id!==held_id ||
             rsp_present!==held_present)
            $fatal(1,"P158 stalled response was changed or overwritten");
          stalled=stalled+1;
        end
        sample_valid=0;write_valid=0;
      end
      rsp_ready=1;
      @(negedge clk);
      checked=checked+1;
      if(!present)missing=missing+1;
      if(rep)repeated=repeated+1;else clamped=clamped+1;
    end
  endtask

  initial begin
    for(integer i=0;i<256;i=i+1)golden[i]=0;
    repeat(4)@(negedge clk);rst_n=1;
    sample(0,0,0,0,1);
    store(0,0,32'h11223344);
    store(15,15,32'hf0a05010);
    store(3,7,32'hff00aa55);
    // When fx=fy=0, absent zero-weight neighbors do not affect presence.
    sample(0,0,0,1,0);
    sample(128,64,0,2,1);
    sample(-256,-256,1,3,0);
    sample(15*256+255,15*256+255,1,4,1);
    // A sample always takes priority over a simultaneous write request.
    @(negedge clk);sample_u=0;sample_v=0;sample_id=8'hba;
    sample_repeat=0;sample_valid=1;
    write_x=0;write_y=0;write_rgba=32'h87654321;write_valid=1;
    #1;if(!sample_ready || write_ready)
      $fatal(1,"P158 read/write contention priority invalid");
    @(negedge clk);sample_valid=0;write_valid=0;
    repeat(30)begin
      @(negedge clk);
      if(rsp_valid)begin
        if(rsp_rgba!==32'h11223344 || rsp_id!==8'hba || !rsp_present)
          $fatal(1,"P158 contested sample result changed");
        contentions=contentions+1;
      end
    end
    if(contentions!=1)$fatal(1,"P158 collision sample not observed exactly once");
    sample(0,0,0,5,0);

    // Fill all 256 cells with unique values; compare both boundary modes.
    for(integer y=0;y<16;y=y+1)
      for(integer x=0;x<16;x=x+1)
        store(x,y,32'hbf631927 ^ (32'(x)*32'h10203047) ^
                  (32'(y)*32'hd735a139));
    for(integer k=0;k<320;k=k+1)
      sample((k*509)%61000-31000,(k*991)%62000-31000,
             k%2,k+6,k%9==0);
    // Reset must flush the response and invalidate the P156 RAM bitmap.
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);
    if(rsp_valid || sample_ready || write_ready)
      $fatal(1,"P158 reset exposed a response or accepted a request");
    initialized=0;resets=resets+1;
    rst_n=1;
    sample(3*256+63,7*256+191,0,240,1);
    store(3,7,32'h01020304);
    sample(3*256,7*256,0,241,1);
    if(checked<325 || clamped<160 || repeated<160 ||
       missing<4 || stalled<200 || writes<258 ||
       contentions!=1 || resets!=1)
      $fatal(1,"P158 coverage insufficient checked=%0d clamp=%0d repeat=%0d missing=%0d stalls=%0d writes=%0d",
        checked,clamped,repeated,missing,stalled,writes);
    $display("P158_BILINEAR_BRAM_ORACLE_PASS checked=%0d clamp=%0d repeat=%0d missing=%0d stalled_cycles=%0d writes=%0d collisions=%0d resets=%0d",
      checked,clamped,repeated,missing,stalled,writes,contentions,resets);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P158 RTL global watchdog");end
endmodule
