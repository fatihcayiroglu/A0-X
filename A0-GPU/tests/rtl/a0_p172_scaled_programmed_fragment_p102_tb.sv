`timescale 1ns/1ps
// P172: independently prove 8x8 and 16x16 full-frame shader/raster against P102.
// Derived from the P163 host-level oracle with geometry parameterization.
// P163 full 77-pin host-programmable real raster -> P162 TEX/ALU program
// -> P144 framebuffer, independently compared with P102 coverage/depth and
// scalar image arithmetic. Missing texels and invalid bus writes fail closed.
module a0_p172_scaled_programmed_fragment_p102_tb #(
  parameter integer W=8,H=8
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0;
  reg [5:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  reg signed [15:0] x0=-257,y0=-257,x1=1024,y1=-257,x2=-257,y2=1024;
  reg signed [15:0] uv_u=-384,uv_v=3904;
  reg [15:0] ref_x=0,ref_y=0;
  reg [23:0] clear_rgb=24'h112233,clear_z=24'hffffff,tri_z=24'h000040;
  reg [31:0] seed_b=32'h10203040,seed_mix=32'hb0806020,
             seed_tex_dst=32'h09080706;
  reg [7:0] mix_alpha=121;
  integer shader_case=0,repeat_mode=0;
  localparam [23:0] MARKER=24'hbadace;
  wire rc_ready,rc_done,rt_ready,rt_done,ref_init,ref_busy,ref_wrote;
  wire ref_read_valid;
  wire [23:0] ref_color,ref_depth;
  wire command_fire=req_valid&&req_ready&&req_write&&req_addr==6'd16;
  wire clear_fire=command_fire&&req_wdata==32'd1;
  wire draw_fire=command_fire&&req_wdata==32'd2;
  integer txns=0,errors=0,texwrites=0,insn_writes=0,seed_writes=0;
  integer clears=0,draws=0,pixels=0,covered=0;
  integer busy_denials=0,missing_faults=0;
  // P173: instrument actual core command-accept to raster completion latency.
  // The monitor never drives the DUT or reference; measurements exclude host
  // framebuffer readback and include the real shader/RMW work for each draw.
  reg [63:0] measured_clock_cycles=0, accepted_draw_cycle=0;
  reg [63:0] completed_draw_cycles [0:1];
  integer measured_draw_count=0;
  always @(posedge clk) begin
    measured_clock_cycles <= measured_clock_cycles+64'd1;
    if(draw_fire)accepted_draw_cycle<=measured_clock_cycles;
    if(dut.core_tri_done && measured_draw_count<2)begin
      completed_draw_cycles[measured_draw_count]<=measured_clock_cycles-accepted_draw_cycle;
      measured_draw_count<=measured_draw_count+1;
    end
  end

  a0_p163_packed_programmed_command_top #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),.req_ready(req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H)
  ) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_fire),.clear_ready(rc_ready),
    .clear_color(clear_rgb),.clear_depth(clear_z),.clear_done(rc_done),
    .tri_valid(draw_fire),.tri_ready(rt_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(MARKER),.tri_depth(tri_z),
    .depth_compare_op(2'd1),.depth_write(1'b1),
    .blend_enable(1'b0),.source_alpha(8'd255),
    .scissor_enable(1'b0),.scissor_x(16'd0),.scissor_y(16'd0),
    .scissor_w(16'd0),.scissor_h(16'd0),
    .tri_done(rt_done),.initialized(ref_init),.busy(ref_busy),
    .read_x(ref_x),.read_y(ref_y),
    .read_valid(ref_read_valid),.read_color(ref_color),
    .read_depth(ref_depth),.pixel_wrote(ref_wrote)
  );

  function automatic [31:0] texel(input integer x,y);
    texel=32'h6e93c527 ^ (32'(x)*32'h13375111) ^
          (32'(y)*32'h37d52a07);
  endfunction
  function automatic integer tex_addr(input integer x,y,rep);
    integer xx,yy;
    begin
      xx=rep?(x&15):(x<0?0:(x>15?15:x));
      yy=rep?(y&15):(y<0?0:(y>15?15:y));
      tex_addr=yy*16+xx;
    end
  endfunction
  function automatic [31:0] bilinear(input integer xx,yy,rep);
    integer u,v,bx,by,fx,fy,k0,k1,k2,k3;
    integer lane,a,b,c,d,t0,t1,res;
    reg [31:0] rgba;
    begin
      u=xx*256+int'(uv_u);v=yy*256+int'(uv_v);
      bx=u>>>8;by=v>>>8;fx=u&255;fy=v&255;
      k0=tex_addr(bx,by,rep);k1=tex_addr(bx+1,by,rep);
      k2=tex_addr(bx,by+1,rep);k3=tex_addr(bx+1,by+1,rep);
      rgba=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=(texel(k0&15,k0>>4)>>(lane*8))&255;
        b=(texel(k1&15,k1>>4)>>(lane*8))&255;
        c=(texel(k2&15,k2>>4)>>(lane*8))&255;
        d=(texel(k3&15,k3>>4)>>(lane*8))&255;
        t0=(a*(256-fx)+b*fx+128)/256;
        t1=(c*(256-fx)+d*fx+128)/256;
        res=(t0*(256-fy)+t1*fy+128)/256;
        rgba[lane*8+:8]=8'(res);
      end
      bilinear=rgba;
    end
  endfunction
  function automatic [31:0] math_model(
    input integer op,input reg [31:0] a,b,
    input integer alpha,mask
  );
    integer lane,v1,v2,n,k;
    reg [31:0] result;
    begin
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        v1=(a>>(lane*8))&255;v2=(b>>(lane*8))&255;k=v1;
        if((mask>>lane)&1)begin
          case(op)
            0:k=v1;
            1:k=v2;
            2:begin n=v1+v2;k=n>255?255:n;end
            3:k=v1>=v2?v1-v2:0;
            4:k=(v1*v2+127)/255;
            5:k=v1<v2?v1:v2;
            6:k=v1>v2?v1:v2;
            7:k=(v1*(255-alpha)+v2*alpha+127)/255;
          endcase
        end
        result[lane*8+:8]=8'(k);
      end
      math_model=result;
    end
  endfunction
  function automatic [31:0] shader_oracle(input integer xx,yy);
    reg [31:0] sample,added,mixed,masked;
    begin
      sample=bilinear(xx,yy,repeat_mode);
      if(shader_case==0)begin
        added=math_model(2,sample,seed_b,0,15);
        mixed=math_model(7,added,seed_mix,mix_alpha,4'hb);
        masked=seed_tex_dst;
        for(integer lane=0;lane<4;lane=lane+1)
          if(4'h5&(1<<lane))masked[lane*8+:8]=sample[lane*8+:8];
        shader_oracle=math_model(4,mixed,masked,0,15);
      end else begin
        added=math_model(7,sample,seed_b,173,15);
        shader_oracle=math_model(5,added,seed_mix,0,15);
      end
    end
  endfunction
  function automatic [24:0] mk_alu(
    input integer op,dst,sa,sb,mask,alpha
  );
    mk_alu={1'b0,8'(alpha),4'(mask),3'(op),3'(dst),3'(sa),3'(sb)};
  endfunction
  function automatic [24:0] mk_tex(
    input integer dst,sa,mask,rep
  );
    mk_tex={1'b1,7'd0,1'(rep),4'(mask),3'd0,
            3'(dst),3'(sa),3'd0};
  endfunction

  task automatic txn(input reg wr,input reg [5:0] addr,
    input reg [31:0] data,output reg err,output reg [31:0] value);
    integer loops;reg seen;
    begin
      @(negedge clk);loops=0;
      while(!req_ready)begin
        @(negedge clk);loops=loops+1;
        if(loops>400)$fatal(1,"P163 packed bus failed to accept request");
      end
      req_valid=1;req_write=wr;req_addr=addr;req_wdata=data;
      @(posedge clk);#2;
      seen=rsp_valid;if(seen)begin err=rsp_error;value=rsp_rdata;end
      @(negedge clk);req_valid=0;
      loops=0;
      while(!seen)begin
        @(posedge clk);#2;
        if(rsp_valid)begin seen=1;err=rsp_error;value=rsp_rdata;end
        loops=loops+1;
        if(loops>500)$fatal(1,"P163 missing deferred host response");
      end
      txns=txns+1;if(err)errors=errors+1;
    end
  endtask
  task automatic wr(input reg [5:0] addr,input reg [31:0] data);
    reg err;reg [31:0] v;
    begin
      txn(1,addr,data,err,v);
      if(err)$fatal(1,"P163 rejected valid write addr=%0d data=%h",addr,data);
    end
  endtask
  task automatic rd(input reg [5:0] addr,output reg [31:0] value);
    reg err;
    begin
      txn(0,addr,0,err,value);
      if(err)$fatal(1,"P163 rejected valid read addr=%0d",addr);
    end
  endtask
  task automatic reject(input reg wr_mode,input reg [5:0] addr,
    input reg [31:0] data);
    reg err;reg [31:0] v;
    begin
      txn(wr_mode,addr,data,err,v);
      if(!err)$fatal(1,"P163 accepted invalid transaction addr=%0d",addr);
    end
  endtask
  task automatic poll_done(input integer bit_index);
    integer loops;reg [31:0] status;
    begin
      status=0;loops=0;
      while(!status[bit_index])begin
        rd(17,status);loops=loops+1;
        if(status[2])$fatal(1,"P163 core unexpectedly faulted: %h",status);
        if(loops>500+W*H*96)
          $fatal(1,"P172 scaled frame poll deadline shape=%0dx%0d bit=%0d loops=%0d status=%h core_state=%0d",
            W,H,bit_index,loops,status,dut.core.state_q);
      end
    end
  endtask
  task automatic upload_insn(input integer idx,input reg [24:0] word);
    begin wr(11,32'(idx));wr(12,{7'd0,word});insn_writes=insn_writes+1;end
  endtask
  task automatic upload_seed(input integer idx,input reg [31:0] value);
    begin wr(9,32'(idx));wr(10,value);seed_writes=seed_writes+1;end
  endtask
  task automatic program_shader;
    begin
      upload_seed(1,seed_b);
      upload_seed(5,seed_mix);
      upload_seed(6,seed_tex_dst);
      if(shader_case==0)begin
        upload_insn(0,mk_tex(2,0,15,repeat_mode));
        upload_insn(1,mk_alu(2,3,2,1,15,0));
        upload_insn(2,mk_alu(7,4,3,5,11,mix_alpha));
        upload_insn(3,mk_tex(6,0,5,repeat_mode));
        upload_insn(4,mk_alu(4,4,4,6,15,0));
        wr(8,{24'd0,3'd4,5'd5});
      end else begin
        upload_insn(0,mk_tex(2,0,15,repeat_mode));
        upload_insn(1,mk_alu(7,3,2,1,15,173));
        upload_insn(2,mk_alu(5,3,3,5,15,0));
        wr(8,{24'd0,3'd3,5'd3});
      end
    end
  endtask
  task automatic upload_texture;
    begin
      for(integer y=0;y<16;y=y+1)
        for(integer x=0;x<16;x=x+1)begin
          wr(13,32'((y<<4)|x));wr(14,texel(x,y));texwrites=texwrites+1;
        end
    end
  endtask
  task automatic read_pixel(input integer xx,yy,drawn);
    reg [31:0] color,z,shaded;
    reg [23:0] expected;
    begin
      ref_x=16'(xx);ref_y=16'(yy);
      wr(15,{16'(yy),16'(xx)});wr(16,3);
      rd(18,color);rd(19,z);
      shaded=drawn?shader_oracle(xx,yy):0;
      expected=(drawn && ref_color==MARKER)?shaded[23:0]:clear_rgb;
      if(!ref_read_valid || color[23:0]!==expected || z[23:0]!==ref_depth)
        $fatal(1,"P163 real programmed framebuffer mismatch xy=%0d,%0d case=%0d got=%h/%h expected=%h/%h",
          xx,yy,shader_case,color[23:0],z[23:0],expected,ref_depth);
      pixels=pixels+1;
      if(drawn && ref_color==MARKER)covered=covered+1;
    end
  endtask
  task automatic check_frame(input integer drawn);
    begin
      for(integer y=0;y<H;y=y+1)
        for(integer x=0;x<W;x=x+1)read_pixel(x,y,drawn);
    end
  endtask
  task automatic clear_frame;
    begin
      wr(16,1);poll_done(3);clears=clears+1;
      if(!ref_init)$fatal(1,"P163 P102 did not finish clearing framebuffer");
      check_frame(0);
    end
  endtask
  task automatic draw_frame;
    reg [31:0] count,insns,texops;
    integer prior,frame_covered;
    begin
      prior=covered;
      wr(16,2);poll_done(4);draws=draws+1;
      check_frame(1);
      frame_covered=covered-prior;
      rd(20,count);rd(21,insns);rd(22,texops);
      if(count!==32'(frame_covered) ||
         insns!==32'(frame_covered*(shader_case==0?5:3)) ||
         texops!==32'(frame_covered*(shader_case==0?2:1)))
        $fatal(1,"P163 per-pixel instruction/TEX retirement mismatch count=%0d insns=%0d TEX=%0d covered=%0d",
          count,insns,texops,frame_covered);
    end
  endtask

  reg [31:0] response,status;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    rd(24,response);
    if(response!==32'hA0163001)$fatal(1,"P163 device identity mismatch");
    reject(1,8,32'd0);
    reject(1,8,32'd17);
    reject(1,9,32'd0);
    reject(1,12,32'h80000000);
    reject(1,13,32'h00000100);
    reject(1,16,32'd99);
    reject(0,18,0);
    upload_texture();
    wr(0,{8'd0,clear_rgb});wr(1,{8'd0,clear_z});
    wr(2,{8'd0,tri_z});
    wr(3,{y0,x0});wr(4,{y1,x1});wr(5,{y2,x2});
    wr(7,{16'd0,8'd255,4'd0,1'b0,1'b1,2'd1});

    shader_case=0;repeat_mode=0;
    wr(6,{uv_v,uv_u});program_shader();
    clear_frame();
    // A busy shader cannot admit a new seed value; rejected host writes
    // must not mutate the seeds for any future fragment.
    wr(16,2);
    reject(1,10,32'hdeadbeef);busy_denials=busy_denials+1;
    poll_done(4);draws=draws+1;
    check_frame(1);
    rd(20,response);
    if(response!==32'(covered))$fatal(1,"P163 first fragment count mismatch");
    rd(21,response);
    if(response!==32'(covered*5))$fatal(1,"P163 first instruction count mismatch");
    rd(22,response);
    if(response!==32'(covered*2))$fatal(1,"P163 first TEX count mismatch");

    shader_case=1;repeat_mode=1;
    uv_u=16'sd95;uv_v=-16'sd417;
    wr(6,{uv_v,uv_u});program_shader();
    clear_frame();draw_frame();
    if(draws!=2 || clears!=2 || pixels!=4*W*H || covered!=2*W*H ||
       texwrites!=256 || busy_denials!=1 || errors<8)
      $fatal(1,"P163 insufficient real coverage draws=%0d clears=%0d pixels=%0d covered=%0d tex=%0d errors=%0d",
             draws,clears,pixels,covered,texwrites,errors);
    if(measured_draw_count!=2 ||
       completed_draw_cycles[0]<W*H || completed_draw_cycles[1]<W*H ||
       completed_draw_cycles[0]>W*H*500 || completed_draw_cycles[1]>W*H*500)
      $fatal(1,"P173 draw timing missing/implausible shape=%0dx%0d done=%0d first=%0d second=%0d",W,H,
        measured_draw_count,completed_draw_cycles[0],completed_draw_cycles[1]);
    $display("P173_DRAW_TIMING_PASS shape=%0dx%0d first_cycles=%0d second_cycles=%0d pixels_each=%0d",W,H,
      completed_draw_cycles[0],completed_draw_cycles[1],W*H);
    rd(25,response);if(response!==32'd256)$fatal(1,"P163 host texture telemetry mismatch");
    rd(26,response);if(response!==32'(insn_writes))$fatal(1,"P163 instruction upload count mismatch");
    rd(27,response);if(response!==32'(seed_writes))$fatal(1,"P163 seed upload count mismatch");

    // After reset BRAM validity bits are all false. Texture fetch into a
    // half-texel coordinate must fault before any framebuffer pixel write.
    @(negedge clk);rst_n=0;
    repeat(4)@(negedge clk);rst_n=1;
    shader_case=1;repeat_mode=0;
    uv_u=16'sd128;uv_v=16'sd128;
    wr(0,{8'd0,clear_rgb});wr(1,{8'd0,clear_z});
    wr(2,{8'd0,tri_z});
    wr(3,{y0,x0});wr(4,{y1,x1});wr(5,{y2,x2});
    wr(6,{uv_v,uv_u});program_shader();
    wr(13,0);wr(14,32'hffffffff);
    clear_frame();
    wr(16,2);
    status=0;
    for(integer k=0;k<350 && !status[2];k=k+1)rd(17,status);
    if(!status[2] || status[4] || status[7] || status[11])
      $fatal(1,"P163 missing weighted texture tap not fail-closed status=%h",status);
    missing_faults=missing_faults+1;
    $display("P172_SCALED_PROGRAMMED_P102_PASS shape=%0dx%0d txns=%0d tex_writes=%0d insn_writes=%0d seed_writes=%0d clears=%0d draws=%0d full_frame_pixels=%0d covered=%0d host_rejections=%0d busy_denials=%0d missing_faults=%0d",
      W,H,txns,texwrites,insn_writes,seed_writes,clears,draws,pixels,
      covered,errors,busy_denials,missing_faults);
    $finish;
  end
  initial begin #300000000;$fatal(1,"P163 global watchdog");end
endmodule
