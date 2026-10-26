`timescale 1ns/1ps
// P167: programmable TEX/ALU, affine + perspective UV, real raster and
// framebuffer behind one 77-bit research host bus (not PCIe/AXI).
module a0_p175_scaled_programmed_command_top #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
)(
  input logic clk,rst_n,
  input logic req_valid,req_write,
  output logic req_ready,
  input logic [5:0] req_addr,
  input logic [31:0] req_wdata,
  output logic rsp_valid,rsp_error,
  output logic [31:0] rsp_rdata
);
  localparam logic [5:0] CLEAR_RGB=0,CLEAR_DEPTH=1,TRI_DEPTH=2,
    V0=3,V1=4,V2=5,UV_OFFSET=6,FB_MODE=7,SHADER_CFG=8,
    SEED_INDEX=9,SEED_DATA=10,INSN_INDEX=11,INSN_DATA=12,
    TEXTURE_XY=13,TEXTURE_RGBA=14,READ_XY=15,COMMAND=16,
    STATUS=17,PIXEL_RGB=18,PIXEL_DEPTH=19,SHADED_COUNT=20,
    SHADER_INSNS=21,TEXTURE_OPS=22,LAST_RGB=23,IDENT=24,
    TEX_WRITES=25,INSN_WRITES=26,SEED_WRITES=27,
    AFFINE_MODE=28,UV0=29,UV1=30,UV2=31,
    INV_W0=32,INV_W1=33,INV_W2=34,PERSPECTIVE_ENABLE=35;
  localparam logic [31:0] DEVICE_ID=32'hA0163001;

  logic [23:0] clear_rgb_q,clear_z_q,tri_z_q;
  logic signed [15:0] x0_q,y0_q,x1_q,y1_q,x2_q,y2_q;
  logic signed [15:0] uv_u_q,uv_v_q;
  logic affine_enable_q,perspective_enable_q;
  logic [15:0] inv_w0_q,inv_w1_q,inv_w2_q;
  logic signed [15:0] uv0_u_q,uv0_v_q,uv1_u_q,uv1_v_q,uv2_u_q,uv2_v_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_q;
  logic [7:0] alpha_q;
  logic [4:0] shader_length_q;
  logic [2:0] shader_output_q,seed_index_q;
  logic [3:0] insn_index_q,tex_x_q,tex_y_q;
  logic [15:0] read_x_q,read_y_q;
  logic [31:0] seed_data_q,insn_data_q,tex_data_q;
  logic [15:0] tex_writes_q,insn_writes_q,seed_writes_q;
  logic [23:0] cached_rgb_q,cached_z_q;
  logic pixel_cached_q,read_pending_q,clear_done_q,tri_done_q;
  wire core_seed_ready,core_insn_ready,core_tex_ready;
  wire core_clear_ready,core_clear_done,core_tri_ready,core_tri_done;
  wire core_initialized,core_busy,core_fault;
  wire [15:0] shaded_count,shader_insns,texture_ops;
  wire [23:0] last_rgb;
  wire core_host_ready,core_host_valid,core_host_error;
  wire [23:0] core_host_rgb,core_host_z;
  assign req_ready=rst_n && !rsp_valid && !read_pending_q;
  wire fire=req_valid && req_ready;
  wire write_fire=fire && req_write;
  wire command_write=write_fire && req_addr==COMMAND;
  wire clear_request=command_write && req_wdata==32'd1;
  wire tri_request=command_write && req_wdata==32'd2;
  wire host_request=command_write && req_wdata==32'd3;
  wire seed_request=write_fire && req_addr==SEED_DATA;
  wire insn_request=write_fire && req_addr==INSN_DATA &&
    req_wdata[31:25]==0;
  wire tex_request=write_fire && req_addr==TEXTURE_RGBA;
  wire clear_launch=clear_request && core_clear_ready;
  wire tri_launch=tri_request && core_tri_ready;
  wire host_launch=host_request && core_host_ready;

  a0_p175_scaled_programmed_fragment_core #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) core(
    .clk(clk),.rst_n(rst_n),
    .seed_write_valid(seed_request),.seed_write_ready(core_seed_ready),
    .seed_write_index(seed_index_q),.seed_write_data(req_wdata),
    .insn_write_valid(insn_request),.insn_write_ready(core_insn_ready),
    .insn_write_index(insn_index_q),.insn_write_data(req_wdata[24:0]),
    .tex_write_valid(tex_request),.tex_write_ready(core_tex_ready),
    .tex_write_x(tex_x_q),.tex_write_y(tex_y_q),
    .tex_write_rgba(req_wdata),
    .clear_valid(clear_request),.clear_ready(core_clear_ready),
    .clear_done(core_clear_done),
    .clear_color(clear_rgb_q),.clear_depth(clear_z_q),
    .tri_valid(tri_request),.tri_ready(core_tri_ready),.tri_done(core_tri_done),
    .x0(x0_q),.y0(y0_q),.x1(x1_q),.y1(y1_q),.x2(x2_q),.y2(y2_q),
    .tri_depth(tri_z_q),.depth_compare_op(depth_op_q),
    .depth_write(depth_write_q),.blend_enable(blend_q),
    .source_alpha(alpha_q),.uv_offset_u(uv_u_q),.uv_offset_v(uv_v_q),
    .affine_uv_enable(affine_enable_q),
    .perspective_uv_enable(perspective_enable_q),
    .inv_w0(inv_w0_q),.inv_w1(inv_w1_q),.inv_w2(inv_w2_q),
    .uv0_u(uv0_u_q),.uv0_v(uv0_v_q),
    .uv1_u(uv1_u_q),.uv1_v(uv1_v_q),
    .uv2_u(uv2_u_q),.uv2_v(uv2_v_q),
    .program_length(shader_length_q),.output_reg(shader_output_q),
    .initialized(core_initialized),.busy(core_busy),.fault(core_fault),
    .shaded_pixels(shaded_count),.shader_instructions(shader_insns),
    .texture_operations(texture_ops),.last_shaded_rgb(last_rgb),
    .host_read_valid(host_request),.host_read_ready(core_host_ready),
    .host_read_x(read_x_q),.host_read_y(read_y_q),
    .host_rsp_valid(core_host_valid),.host_rsp_error(core_host_error),
    .host_rsp_color(core_host_rgb),.host_rsp_depth(core_host_z)
  );

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      clear_rgb_q<=0;clear_z_q<=0;tri_z_q<=0;
      x0_q<=0;y0_q<=0;x1_q<=0;y1_q<=0;x2_q<=0;y2_q<=0;
      uv_u_q<=0;uv_v_q<=0;affine_enable_q<=0;
      perspective_enable_q<=0;
      inv_w0_q<=0;inv_w1_q<=0;inv_w2_q<=0;
      uv0_u_q<=0;uv0_v_q<=0;uv1_u_q<=0;uv1_v_q<=0;
      uv2_u_q<=0;uv2_v_q<=0;
      depth_op_q<=1;depth_write_q<=1;blend_q<=0;alpha_q<=255;
      shader_length_q<=0;shader_output_q<=2;
      seed_index_q<=1;insn_index_q<=0;tex_x_q<=0;tex_y_q<=0;
      read_x_q<=0;read_y_q<=0;seed_data_q<=0;insn_data_q<=0;
      tex_data_q<=0;tex_writes_q<=0;insn_writes_q<=0;seed_writes_q<=0;
      cached_rgb_q<=0;cached_z_q<=0;
      pixel_cached_q<=0;read_pending_q<=0;
      clear_done_q<=0;tri_done_q<=0;
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
    end else begin
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
      if(core_clear_done)clear_done_q<=1;
      if(core_tri_done)tri_done_q<=1;
      if(read_pending_q && core_host_valid)begin
        read_pending_q<=0;
        cached_rgb_q<=core_host_error?24'd0:core_host_rgb;
        cached_z_q<=core_host_error?24'd0:core_host_z;
        pixel_cached_q<=!core_host_error;
        rsp_valid<=1;rsp_error<=core_host_error;
      end else if(fire)begin
        rsp_valid<=1;
        if(req_write)begin
          case(req_addr)
            CLEAR_RGB:clear_rgb_q<=req_wdata[23:0];
            CLEAR_DEPTH:clear_z_q<=req_wdata[23:0];
            TRI_DEPTH:tri_z_q<=req_wdata[23:0];
            V0:begin x0_q<=req_wdata[15:0];y0_q<=req_wdata[31:16];end
            V1:begin x1_q<=req_wdata[15:0];y1_q<=req_wdata[31:16];end
            V2:begin x2_q<=req_wdata[15:0];y2_q<=req_wdata[31:16];end
            UV_OFFSET:begin uv_u_q<=req_wdata[15:0];uv_v_q<=req_wdata[31:16];end
            FB_MODE:begin
              if(req_wdata[31:16]!=0 || req_wdata[7:4]!=0)rsp_error<=1;
              else begin
                depth_op_q<=req_wdata[1:0];depth_write_q<=req_wdata[2];
                blend_q<=req_wdata[3];alpha_q<=req_wdata[15:8];
              end
            end
            SHADER_CFG:begin
              if(req_wdata[31:8]!=0 || req_wdata[4:0]==0 ||
                 req_wdata[4:0]>16)rsp_error<=1;
              else begin shader_length_q<=req_wdata[4:0];
                         shader_output_q<=req_wdata[7:5];end
            end
            SEED_INDEX:begin
              if(req_wdata[31:3]!=0 || req_wdata[2:0]==0)rsp_error<=1;
              else seed_index_q<=req_wdata[2:0];
            end
            SEED_DATA:begin
              if(core_seed_ready)begin
                seed_data_q<=req_wdata;seed_writes_q<=seed_writes_q+1'b1;
              end else rsp_error<=1;
            end
            INSN_INDEX:begin
              if(req_wdata[31:4]!=0)rsp_error<=1;
              else insn_index_q<=req_wdata[3:0];
            end
            INSN_DATA:begin
              if(core_insn_ready && req_wdata[31:25]==0)begin
                insn_data_q<=req_wdata;insn_writes_q<=insn_writes_q+1'b1;
              end else rsp_error<=1;
            end
            TEXTURE_XY:begin
              if(req_wdata[31:8]!=0)rsp_error<=1;
              else begin tex_x_q<=req_wdata[3:0];tex_y_q<=req_wdata[7:4];end
            end
            TEXTURE_RGBA:begin
              if(core_tex_ready)begin
                tex_data_q<=req_wdata;tex_writes_q<=tex_writes_q+1'b1;
              end else rsp_error<=1;
            end
            READ_XY:begin read_x_q<=req_wdata[15:0];read_y_q<=req_wdata[31:16];end
            AFFINE_MODE:begin
              if(req_wdata[31:1]!=0)rsp_error<=1;
              else affine_enable_q<=req_wdata[0];
            end
            UV0:begin uv0_u_q<=req_wdata[15:0];uv0_v_q<=req_wdata[31:16];end
            UV1:begin uv1_u_q<=req_wdata[15:0];uv1_v_q<=req_wdata[31:16];end
            UV2:begin uv2_u_q<=req_wdata[15:0];uv2_v_q<=req_wdata[31:16];end
            INV_W0:begin
              if(req_wdata[31:16]!=0)rsp_error<=1;
              else inv_w0_q<=req_wdata[15:0];
            end
            INV_W1:begin
              if(req_wdata[31:16]!=0)rsp_error<=1;
              else inv_w1_q<=req_wdata[15:0];
            end
            INV_W2:begin
              if(req_wdata[31:16]!=0)rsp_error<=1;
              else inv_w2_q<=req_wdata[15:0];
            end
            PERSPECTIVE_ENABLE:begin
              if(req_wdata[31:1]!=0)rsp_error<=1;
              else perspective_enable_q<=req_wdata[0];
            end
            COMMAND:begin
              if(clear_launch)begin
                clear_done_q<=0;pixel_cached_q<=0;
              end else if(tri_launch)begin
                tri_done_q<=0;
              end else if(host_launch)begin
                read_pending_q<=1;pixel_cached_q<=0;rsp_valid<=0;
              end else rsp_error<=1;
            end
            default:rsp_error<=1;
          endcase
        end else begin
          case(req_addr)
            CLEAR_RGB:rsp_rdata<={8'd0,clear_rgb_q};
            CLEAR_DEPTH:rsp_rdata<={8'd0,clear_z_q};
            TRI_DEPTH:rsp_rdata<={8'd0,tri_z_q};
            V0:rsp_rdata<={y0_q,x0_q};
            V1:rsp_rdata<={y1_q,x1_q};
            V2:rsp_rdata<={y2_q,x2_q};
            UV_OFFSET:rsp_rdata<={uv_v_q,uv_u_q};
            FB_MODE:rsp_rdata<={16'd0,alpha_q,4'd0,blend_q,depth_write_q,depth_op_q};
            SHADER_CFG:rsp_rdata<={24'd0,shader_output_q,shader_length_q};
            SEED_INDEX:rsp_rdata<={29'd0,seed_index_q};
            SEED_DATA:rsp_rdata<=seed_data_q;
            INSN_INDEX:rsp_rdata<={28'd0,insn_index_q};
            INSN_DATA:rsp_rdata<=insn_data_q;
            TEXTURE_XY:rsp_rdata<={24'd0,tex_y_q,tex_x_q};
            TEXTURE_RGBA:rsp_rdata<=tex_data_q;
            READ_XY:rsp_rdata<={read_y_q,read_x_q};
            STATUS:rsp_rdata<={19'd0,read_pending_q,core_host_ready,
              core_insn_ready,core_seed_ready,core_tex_ready,
              core_tri_ready,core_clear_ready,pixel_cached_q,
              tri_done_q,clear_done_q,core_fault,core_busy,core_initialized};
            PIXEL_RGB:begin
              if(pixel_cached_q)rsp_rdata<={8'd0,cached_rgb_q};
              else rsp_error<=1;
            end
            PIXEL_DEPTH:begin
              if(pixel_cached_q)rsp_rdata<={8'd0,cached_z_q};
              else rsp_error<=1;
            end
            SHADED_COUNT:rsp_rdata<={16'd0,shaded_count};
            SHADER_INSNS:rsp_rdata<={16'd0,shader_insns};
            TEXTURE_OPS:rsp_rdata<={16'd0,texture_ops};
            LAST_RGB:rsp_rdata<={8'd0,last_rgb};
            IDENT:rsp_rdata<=DEVICE_ID;
            TEX_WRITES:rsp_rdata<={16'd0,tex_writes_q};
            INSN_WRITES:rsp_rdata<={16'd0,insn_writes_q};
            SEED_WRITES:rsp_rdata<={16'd0,seed_writes_q};
            AFFINE_MODE:rsp_rdata<={31'd0,affine_enable_q};
            UV0:rsp_rdata<={uv0_v_q,uv0_u_q};
            UV1:rsp_rdata<={uv1_v_q,uv1_u_q};
            UV2:rsp_rdata<={uv2_v_q,uv2_u_q};
            INV_W0:rsp_rdata<={16'd0,inv_w0_q};
            INV_W1:rsp_rdata<={16'd0,inv_w1_q};
            INV_W2:rsp_rdata<={16'd0,inv_w2_q};
            PERSPECTIVE_ENABLE:rsp_rdata<={31'd0,perspective_enable_q};
            default:rsp_error<=1;
          endcase
        end
      end
    end
  end
endmodule
