`timescale 1ns/1ps
// P152: first actual shader-program-to-triangle-raster color integration.
// The P151 8-register/16-insn P150 SIMD4 microprogram executes ONCE
// PER TRIANGLE; destination vector register 2 feeds the P145/P146
// real dual-bank depth/blend raster's source RGB. The P145 raster is
// independent and unchanged. This is triangle-constant color shading,
// NOT per-fragment invocation, vertex interpolation, shader compiler,
// FP32 programmable GPU, texture engine, or game-ready physical hardware.
module a0_p152_shaded_triangle_trial #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
)(
  input logic clk,rst_n,
  input logic clear_valid,
  output logic clear_ready,clear_done,
  input logic [23:0] clear_color,clear_depth,
  input logic tri_valid,
  output logic tri_ready,tri_done,
  input logic signed [15:0] x0,y0,x1,y1,x2,y2,
  input logic [23:0] tri_depth,
  input logic [1:0] depth_compare_op,
  input logic depth_write,blend_enable,
  input logic [7:0] source_alpha,
  input logic scissor_enable,
  input logic [15:0] scissor_x,scissor_y,scissor_w,scissor_h,
  input logic [4:0] shader_program_length,
  input logic shader_reg_write_valid,
  input logic [2:0] shader_reg_write_index,
  input logic [31:0] shader_reg_write_data,
  input logic shader_insn_write_valid,
  input logic [3:0] shader_insn_write_index,
  input logic [23:0] shader_insn_write_data,
  input logic [2:0] shader_debug_index,
  output logic [31:0] shader_debug_data,
  output logic shader_config_ready,shader_done,
  output logic [4:0] shader_retired_count,
  output logic [23:0] last_shaded_rgb,
  output logic initialized,busy,fault,
  output logic [1:0] pixel_writes,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  localparam logic [2:0]
    IDLE=3'd0,START_SHADER=3'd1,WAIT_SHADER=3'd2,
    ISSUE_RASTER=3'd3,WAIT_RASTER=3'd4,FAILED=3'd5;
  logic [2:0] state_q;
  logic local_fault_q;
  logic signed [15:0] vx0_q,vy0_q,vx1_q,vy1_q,vx2_q,vy2_q;
  logic [23:0] depth_q,color_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_enable_q,scissor_enable_q;
  logic [7:0] alpha_q;
  logic [15:0] sx_q,sy_q,sw_q,sh_q;
  logic [4:0] shader_length_q;
  wire shader_ready,shader_busy,shader_done_raw,shader_fault;
  wire [31:0] shader_data;
  wire [4:0] retired_raw;
  wire core_clear_ready,core_clear_done,core_tri_ready,core_tri_done;
  wire core_initialized,core_busy,core_fault;
  wire [1:0] core_pixel_writes;
  wire core_host_ready,core_host_rsp_valid,core_host_rsp_error;
  wire [23:0] core_host_rgb,core_host_depth;

  assign fault=local_fault_q || shader_fault || core_fault;
  assign initialized=core_initialized;
  assign busy=(state_q!=IDLE) || core_busy;
  assign shader_config_ready=rst_n && state_q==IDLE &&
                             shader_ready && !clear_valid && !tri_valid &&
                             !host_read_valid && !fault;
  wire shader_config_reg=shader_reg_write_valid && shader_config_ready;
  wire shader_config_insn=shader_insn_write_valid && shader_config_ready;
  assign tri_ready=rst_n && state_q==IDLE && shader_ready &&
                   core_tri_ready && core_initialized && !clear_valid &&
                   !host_read_valid && !shader_reg_write_valid &&
                   !shader_insn_write_valid && !fault;
  assign clear_ready=rst_n && state_q==IDLE && shader_ready &&
                     core_clear_ready && !tri_valid && !host_read_valid &&
                     !shader_reg_write_valid && !shader_insn_write_valid &&
                     !fault;
  wire raster_issue=(state_q==ISSUE_RASTER);
  // Register 2 is the documented shader COLOR0 output register.
  // During shader completion capture its *already retired* contents;
  // at idle the debug port may inspect any of the eight registers.
  wire [2:0] shader_read_index=
      (state_q==WAIT_SHADER)?3'd2:shader_debug_index;
  assign shader_debug_data=shader_data;
  assign shader_retired_count=retired_raw;
  a0_p151_unorm_microprogram shader(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid(shader_config_reg),
    .reg_write_index(shader_reg_write_index),
    .reg_write_data(shader_reg_write_data),
    .reg_read_index(shader_read_index),
    .reg_read_data(shader_data),
    .insn_write_valid(shader_config_insn),
    .insn_write_index(shader_insn_write_index),
    .insn_write_data(shader_insn_write_data),
    .start(state_q==START_SHADER),
    .start_length(shader_length_q),
    .ready(shader_ready),.busy(shader_busy),
    .done(shader_done_raw),.fault(shader_fault),
    .retired_count(retired_raw)
  );

  a0_p145_dual_raster_depth_blend_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) raster(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid && clear_ready),
    .clear_ready(core_clear_ready),.clear_done(core_clear_done),
    .clear_color(clear_color),.clear_depth(clear_depth),
    .tri_valid(raster_issue),.tri_ready(core_tri_ready),
    .tri_done(core_tri_done),
    .x0(vx0_q),.y0(vy0_q),.x1(vx1_q),.y1(vy1_q),
    .x2(vx2_q),.y2(vy2_q),
    .tri_color(color_q),.tri_depth(depth_q),
    .depth_compare_op(depth_op_q),
    .depth_write(depth_write_q),.blend_enable(blend_enable_q),
    .source_alpha(alpha_q),
    .scissor_enable(scissor_enable_q),
    .scissor_x(sx_q),.scissor_y(sy_q),
    .scissor_w(sw_q),.scissor_h(sh_q),
    .initialized(core_initialized),.busy(core_busy),
    .fault(core_fault),.pixel_writes(core_pixel_writes),
    .host_read_valid(host_read_valid && state_q==IDLE && !tri_valid &&
                     !clear_valid && !shader_reg_write_valid &&
                     !shader_insn_write_valid),
    .host_read_ready(core_host_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(core_host_rsp_valid),
    .host_rsp_error(core_host_rsp_error),
    .host_rsp_color(core_host_rgb),
    .host_rsp_depth(core_host_depth)
  );
  assign pixel_writes=core_pixel_writes;
  assign clear_done=core_clear_done;
  assign host_read_ready=rst_n && state_q==IDLE && !fault &&
                         !shader_reg_write_valid && !shader_insn_write_valid &&
                         core_host_ready;
  assign host_rsp_valid=core_host_rsp_valid;
  assign host_rsp_error=core_host_rsp_error;
  assign host_rsp_color=core_host_rgb;
  assign host_rsp_depth=core_host_depth;

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=IDLE;local_fault_q<=0;tri_done<=0;shader_done<=0;
      vx0_q<=0;vy0_q<=0;vx1_q<=0;vy1_q<=0;vx2_q<=0;vy2_q<=0;
      depth_q<=0;color_q<=0;last_shaded_rgb<=0;
      depth_op_q<=0;depth_write_q<=0;blend_enable_q<=0;
      scissor_enable_q<=0;alpha_q<=0;
      sx_q<=0;sy_q<=0;sw_q<=0;sh_q<=0;shader_length_q<=0;
    end else begin
      tri_done<=0;shader_done<=0;
      case(state_q)
        IDLE:begin
          if(tri_valid && tri_ready)begin
            vx0_q<=x0;vy0_q<=y0;vx1_q<=x1;vy1_q<=y1;
            vx2_q<=x2;vy2_q<=y2;
            depth_q<=tri_depth;
            depth_op_q<=depth_compare_op;
            depth_write_q<=depth_write;
            blend_enable_q<=blend_enable;
            alpha_q<=source_alpha;
            scissor_enable_q<=scissor_enable;
            sx_q<=scissor_x;sy_q<=scissor_y;
            sw_q<=scissor_w;sh_q<=scissor_h;
            shader_length_q<=shader_program_length;
            state_q<=START_SHADER;
          end
        end
        START_SHADER:begin
          // P151 detects bad lengths; never send any pixels if invalid.
          state_q<=WAIT_SHADER;
        end
        WAIT_SHADER:begin
          if(shader_fault)begin
            local_fault_q<=1;
            state_q<=FAILED;
          end else if(shader_done_raw)begin
            color_q<=shader_data[23:0];
            last_shaded_rgb<=shader_data[23:0];
            shader_done<=1;
            state_q<=ISSUE_RASTER;
          end
        end
        ISSUE_RASTER:begin
          if(core_fault)begin
            local_fault_q<=1;
            state_q<=FAILED;
          end else if(core_tri_ready)state_q<=WAIT_RASTER;
        end
        WAIT_RASTER:begin
          if(core_fault)begin
            local_fault_q<=1;
            state_q<=FAILED;
          end else if(core_tri_done)begin
            tri_done<=1;
            state_q<=IDLE;
          end
        end
        default:state_q<=FAILED;
      endcase
    end
  end
  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       FRAME_WIDTH*FRAME_HEIGHT<2 || FRAME_WIDTH*FRAME_HEIGHT>65536)
      $fatal(1,"P152 research framebuffer geometry unsupported");
  end
endmodule
