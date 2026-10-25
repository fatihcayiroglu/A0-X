`timescale 1ns/1ps
// P161: real 76-pin register/command interface to the FULL P160 trial.
// Host explicitly programs texels, triangle/UV coordinates, shader operands,
// depth/blend modes and reads the real P144 framebuffer asynchronously.
// Not PCIe, AXI, a CDC boundary, an OS driver or a physical board pinout.
module a0_p161_packed_textured_command_top #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
)(
  input logic clk,rst_n,
  input logic req_valid,req_write,
  output logic req_ready,
  input logic [4:0] req_addr,
  input logic [31:0] req_wdata,
  output logic rsp_valid,rsp_error,
  output logic [31:0] rsp_rdata
);
  localparam logic [4:0]
    REG_CLEAR_RGB=0,REG_CLEAR_DEPTH=1,REG_TRI_DEPTH=2,
    REG_V0=3,REG_V1=4,REG_V2=5,
    REG_UV_OFFSET=6,REG_SHADER_B=7,REG_SHADER_MODE=8,
    REG_FB_MODE=9,REG_READ_XY=10,REG_TEXTURE_XY=11,
    REG_TEXTURE_RGBA=12,REG_COMMAND=13,REG_STATUS=14,
    REG_PIXEL_RGB=15,REG_PIXEL_DEPTH=16,REG_IDENT=17,
    REG_SHADED_COUNT=18,REG_LAST_RGB=19,REG_TEX_WRITES=20;
  localparam logic [31:0] DEVICE_ID=32'hA0161001;
  logic [23:0] clear_rgb_q,clear_z_q,tri_z_q;
  logic signed [15:0] x0_q,y0_q,x1_q,y1_q,x2_q,y2_q;
  logic signed [15:0] uv_u_q,uv_v_q;
  logic [31:0] shader_b_q,texture_rgba_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_q,repeat_q;
  logic [7:0] blend_alpha_q,shader_alpha_q;
  logic [2:0] shader_op_q;
  logic [3:0] shader_mask_q;
  logic [3:0] texture_x_q,texture_y_q;
  logic [15:0] read_x_q,read_y_q,texture_writes_q;
  logic [23:0] pixel_rgb_q,pixel_depth_q;
  logic pixel_cached_q,read_pending_q;
  logic clear_done_q,tri_done_q;
  wire core_tex_ready,core_clear_ready,core_clear_done;
  wire core_tri_ready,core_tri_done;
  wire core_initialized,core_busy,core_fault;
  wire [15:0] shaded_count;
  wire [23:0] last_rgb;
  wire core_host_ready,core_host_valid,core_host_error;
  wire [23:0] core_host_rgb,core_host_depth;
  assign req_ready=rst_n && !rsp_valid && !read_pending_q;
  wire fire=req_valid && req_ready;
  wire reg_write=fire && req_write;
  wire command_write=reg_write && req_addr==REG_COMMAND;
  wire clear_request=command_write && req_wdata==32'd1;
  wire tri_request=command_write && req_wdata==32'd2;
  wire host_request=command_write && req_wdata==32'd3;
  wire texture_request=reg_write && req_addr==REG_TEXTURE_RGBA;
  wire clear_launch=clear_request && core_clear_ready;
  wire tri_launch=tri_request && core_tri_ready;
  wire host_launch=host_request && core_host_ready;
  wire texture_launch=texture_request && core_tex_ready;

  a0_p160_textured_fragment_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) core(
    .clk(clk),.rst_n(rst_n),
    .tex_write_valid(texture_request),.tex_write_ready(core_tex_ready),
    .tex_write_x(texture_x_q),.tex_write_y(texture_y_q),
    .tex_write_rgba(req_wdata),
    .clear_valid(clear_request),.clear_ready(core_clear_ready),
    .clear_done(core_clear_done),
    .clear_color(clear_rgb_q),.clear_depth(clear_z_q),
    .tri_valid(tri_request),.tri_ready(core_tri_ready),
    .tri_done(core_tri_done),
    .x0(x0_q),.y0(y0_q),.x1(x1_q),.y1(y1_q),.x2(x2_q),.y2(y2_q),
    .tri_depth(tri_z_q),.depth_compare_op(depth_op_q),
    .depth_write(depth_write_q),.blend_enable(blend_q),
    .source_alpha(blend_alpha_q),
    .uv_offset_u(uv_u_q),.uv_offset_v(uv_v_q),
    .sample_repeat(repeat_q),
    .shader_opcode(shader_op_q),.shader_operand_b(shader_b_q),
    .shader_alpha(shader_alpha_q),.shader_lane_mask(shader_mask_q),
    .initialized(core_initialized),.busy(core_busy),.fault(core_fault),
    .shaded_pixels(shaded_count),.last_shaded_rgb(last_rgb),
    .pixel_writes(),
    .host_read_valid(host_request),.host_read_ready(core_host_ready),
    .host_read_x(read_x_q),.host_read_y(read_y_q),
    .host_rsp_valid(core_host_valid),.host_rsp_error(core_host_error),
    .host_rsp_color(core_host_rgb),.host_rsp_depth(core_host_depth)
  );

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      clear_rgb_q<=0;clear_z_q<=0;tri_z_q<=0;
      x0_q<=0;y0_q<=0;x1_q<=0;y1_q<=0;x2_q<=0;y2_q<=0;
      uv_u_q<=0;uv_v_q<=0;shader_b_q<=0;texture_rgba_q<=0;
      depth_op_q<=0;depth_write_q<=0;blend_q<=0;repeat_q<=0;
      blend_alpha_q<=0;shader_alpha_q<=0;
      shader_op_q<=0;shader_mask_q<=0;
      texture_x_q<=0;texture_y_q<=0;texture_writes_q<=0;
      read_x_q<=0;read_y_q<=0;
      pixel_rgb_q<=0;pixel_depth_q<=0;pixel_cached_q<=0;
      read_pending_q<=0;clear_done_q<=0;tri_done_q<=0;
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
    end else begin
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
      if(core_clear_done)clear_done_q<=1;
      if(core_tri_done)tri_done_q<=1;
      if(read_pending_q && core_host_valid)begin
        read_pending_q<=0;
        pixel_rgb_q<=core_host_error?24'd0:core_host_rgb;
        pixel_depth_q<=core_host_error?24'd0:core_host_depth;
        pixel_cached_q<=!core_host_error;
        rsp_valid<=1;rsp_error<=core_host_error;
      end else if(fire)begin
        rsp_valid<=1;
        if(req_write)begin
          case(req_addr)
            REG_CLEAR_RGB:clear_rgb_q<=req_wdata[23:0];
            REG_CLEAR_DEPTH:clear_z_q<=req_wdata[23:0];
            REG_TRI_DEPTH:tri_z_q<=req_wdata[23:0];
            REG_V0:begin x0_q<=req_wdata[15:0];y0_q<=req_wdata[31:16];end
            REG_V1:begin x1_q<=req_wdata[15:0];y1_q<=req_wdata[31:16];end
            REG_V2:begin x2_q<=req_wdata[15:0];y2_q<=req_wdata[31:16];end
            REG_UV_OFFSET:begin
              uv_u_q<=req_wdata[15:0];uv_v_q<=req_wdata[31:16];
            end
            REG_SHADER_B:shader_b_q<=req_wdata;
            REG_SHADER_MODE:begin
              if(req_wdata[31] || req_wdata[7:5]!=0)rsp_error<=1;
              else begin
                depth_op_q<=req_wdata[1:0];
                depth_write_q<=req_wdata[2];blend_q<=req_wdata[3];
                repeat_q<=req_wdata[4];
                blend_alpha_q<=req_wdata[15:8];
                shader_op_q<=req_wdata[18:16];
                shader_mask_q<=req_wdata[22:19];
                shader_alpha_q<=req_wdata[30:23];
              end
            end
            REG_FB_MODE:rsp_error<=1; // Future control extension reserved.
            REG_READ_XY:begin
              read_x_q<=req_wdata[15:0];read_y_q<=req_wdata[31:16];
            end
            REG_TEXTURE_XY:begin
              if(req_wdata[31:8]!=0)rsp_error<=1;
              else begin
                texture_x_q<=req_wdata[3:0];
                texture_y_q<=req_wdata[7:4];
              end
            end
            REG_TEXTURE_RGBA:begin
              if(texture_launch)begin
                texture_rgba_q<=req_wdata;
                texture_writes_q<=texture_writes_q+1'b1;
              end else rsp_error<=1;
            end
            REG_COMMAND:begin
              if(clear_launch)begin
                clear_done_q<=0;pixel_cached_q<=0;
              end else if(tri_launch)begin
                tri_done_q<=0;
              end else if(host_launch)begin
                read_pending_q<=1;pixel_cached_q<=0;
                rsp_valid<=0; // Real framebuffer read responds later.
              end else rsp_error<=1;
            end
            default:rsp_error<=1;
          endcase
        end else begin
          case(req_addr)
            REG_CLEAR_RGB:rsp_rdata<={8'd0,clear_rgb_q};
            REG_CLEAR_DEPTH:rsp_rdata<={8'd0,clear_z_q};
            REG_TRI_DEPTH:rsp_rdata<={8'd0,tri_z_q};
            REG_V0:rsp_rdata<={y0_q,x0_q};
            REG_V1:rsp_rdata<={y1_q,x1_q};
            REG_V2:rsp_rdata<={y2_q,x2_q};
            REG_UV_OFFSET:rsp_rdata<={uv_v_q,uv_u_q};
            REG_SHADER_B:rsp_rdata<=shader_b_q;
            REG_SHADER_MODE:rsp_rdata<=
              {1'b0,shader_alpha_q,shader_mask_q,shader_op_q,
               blend_alpha_q,3'd0,repeat_q,blend_q,depth_write_q,depth_op_q};
            REG_READ_XY:rsp_rdata<={read_y_q,read_x_q};
            REG_TEXTURE_XY:rsp_rdata<={24'd0,texture_y_q,texture_x_q};
            REG_TEXTURE_RGBA:rsp_rdata<=texture_rgba_q;
            REG_STATUS:rsp_rdata<={21'd0,read_pending_q,core_host_ready,
              core_tex_ready,core_tri_ready,core_clear_ready,
              pixel_cached_q,tri_done_q,clear_done_q,
              core_fault,core_busy,core_initialized};
            REG_PIXEL_RGB:begin
              if(pixel_cached_q)rsp_rdata<={8'd0,pixel_rgb_q};
              else rsp_error<=1;
            end
            REG_PIXEL_DEPTH:begin
              if(pixel_cached_q)rsp_rdata<={8'd0,pixel_depth_q};
              else rsp_error<=1;
            end
            REG_IDENT:rsp_rdata<=DEVICE_ID;
            REG_SHADED_COUNT:rsp_rdata<={16'd0,shaded_count};
            REG_LAST_RGB:rsp_rdata<={8'd0,last_rgb};
            REG_TEX_WRITES:rsp_rdata<={16'd0,texture_writes_q};
            default:rsp_error<=1;
          endcase
        end
      end
    end
  end
endmodule
