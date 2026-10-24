`timescale 1ns/1ps
// P153 first real per-COVERED-FRAGMENT shader research path:
// P38 stallable triangle coverage -> for each covered pixel load its
// coordinates as SIMD input R0 -> run real P151/P150 shader program
// -> take result R2 RGB -> P144/P139/P138 genuine BRAM depth/RGB RMW
// -> assert P38 pixel_ready ONLY after successful BRAM completion.
// Intentionally one pixel at a time. NO 2-fragment/clock claim,
// interpolation, textures, shader compiler, FP32, PCIe or board.
module a0_p153_fragment_shader_trial #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
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
  output logic [15:0] shaded_pixels,
  output logic initialized,busy,fault,
  output logic [1:0] pixel_writes,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  localparam logic [3:0] IDLE=0,CLEAR_ISSUE=1,CLEAR_WAIT=2,SCAN=3,
    LOAD_PIXEL=4,START_SHADER=5,WAIT_SHADER=6,
    WRITE_PIXEL=7,WAIT_WRITE=8,FAILED=9;
  logic [3:0] state_q;
  logic local_fault_q;
  logic [$clog2(PIXELS+1)-1:0] clear_pos_q;
  logic [23:0] clear_rgb_q,clear_z_q,depth_q,color_q;
  logic [1:0] depth_op_q;
  logic write_z_q,blend_q;
  logic [7:0] alpha_q;
  logic [4:0] program_len_q;
  logic [15:0] px_q,py_q;
  logic [15:0] pixel_count_q;
  wire shader_ready,shader_busy,shader_done_raw,shader_fault;
  wire [31:0] shader_data;
  wire [4:0] shader_retired;
  wire raster_tri_ready,raster_pixel_valid,raster_done;
  wire [15:0] raster_x,raster_y;
  wire rmw_ready,rmw_rsp_valid,rmw_rsp_error;
  wire [1:0] rmw_written;
  wire rmw_host_ready;
  wire [$clog2(PIXELS+1)-1:0] clear_next=clear_pos_q+1'b1;
  wire [15:0] clear_x=16'(clear_pos_q%FRAME_WIDTH);
  wire [15:0] clear_y=16'(clear_pos_q/FRAME_WIDTH);
  assign fault=local_fault_q || shader_fault;
  assign busy=state_q!=IDLE;
  assign shader_config_ready=rst_n && state_q==IDLE && shader_ready &&
                             !clear_valid && !tri_valid && !host_read_valid && !fault;
  assign initialized=(state_q!=CLEAR_ISSUE && state_q!=CLEAR_WAIT) &&
                     initialized_q;
  logic initialized_q;
  assign clear_ready=rst_n && state_q==IDLE && rmw_ready && shader_ready &&
                     !tri_valid && !host_read_valid &&
                     !shader_reg_write_valid && !shader_insn_write_valid && !fault;
  assign tri_ready=rst_n && state_q==IDLE && initialized && raster_tri_ready &&
                   rmw_ready && shader_ready && !clear_valid && !host_read_valid &&
                   !shader_reg_write_valid && !shader_insn_write_valid && !fault;
  assign pixel_writes=rmw_written;
  wire clear_op=(state_q==CLEAR_ISSUE);
  wire pixel_op=(state_q==WRITE_PIXEL);
  assign host_read_ready=rst_n && state_q==IDLE && initialized && !fault &&
                         !clear_valid && !tri_valid && !shader_reg_write_valid &&
                         !shader_insn_write_valid && rmw_host_ready;

  a0_triangle_coverage_p38 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) raster(
    .clk(clk),.rst_n(rst_n),
    .tri_valid(tri_valid && tri_ready),.tri_ready(raster_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(raster_pixel_valid),
    .pixel_ready(state_q==WAIT_WRITE && rmw_rsp_valid && !rmw_rsp_error),
    .pixel_x(raster_x),.pixel_y(raster_y),.done(raster_done)
  );
  // Host config allowed only while idle, whereas every covered pixel
  // independently updates R0 with {255, y[7:0], x[7:0], 64}.
  wire [2:0] read_reg=(state_q==WAIT_SHADER)?3'd2:shader_debug_index;
  assign shader_debug_data=shader_data;
  assign shader_retired_count=shader_retired;
  a0_p151_unorm_microprogram shader(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid((state_q==LOAD_PIXEL) ||
                     (shader_config_ready && shader_reg_write_valid)),
    .reg_write_index((state_q==LOAD_PIXEL)?3'd0:shader_reg_write_index),
    .reg_write_data((state_q==LOAD_PIXEL)?
                    {8'hff,py_q[7:0],px_q[7:0],8'h40}:shader_reg_write_data),
    .reg_read_index(read_reg),.reg_read_data(shader_data),
    .insn_write_valid(shader_config_ready && shader_insn_write_valid),
    .insn_write_index(shader_insn_write_index),
    .insn_write_data(shader_insn_write_data),
    .start(state_q==START_SHADER),.start_length(program_len_q),
    .ready(shader_ready),.busy(shader_busy),.done(shader_done_raw),
    .fault(shader_fault),.retired_count(shader_retired)
  );
  a0_p144_dual_depth_blend_rmw #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) memory(
    .clk(clk),.rst_n(rst_n),
    .op_valid(clear_op || pixel_op),.op_ready(rmw_ready),
    .op_clear(clear_op),
    .lane0_valid(1'b1),.lane1_valid(1'b0),
    .lane0_x(clear_op?clear_x:px_q),
    .lane0_y(clear_op?clear_y:py_q),
    .lane1_x(16'd0),.lane1_y(16'd0),
    .source_rgb(clear_op?clear_rgb_q:color_q),
    .source_depth(clear_op?clear_z_q:depth_q),
    .depth_compare_op(depth_op_q),.depth_write(write_z_q),
    .blend_enable(blend_q),.source_alpha(alpha_q),
    .rsp_valid(rmw_rsp_valid),.rsp_error(rmw_rsp_error),
    .rsp_pixel_written(rmw_written),
    .host_read_valid(host_read_valid && state_q==IDLE && !tri_valid && !clear_valid),
    .host_read_ready(rmw_host_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;initialized_q<=0;local_fault_q<=0;
      clear_pos_q<=0;clear_rgb_q<=0;clear_z_q<=0;
      depth_q<=0;color_q<=0;depth_op_q<=0;write_z_q<=0;
      blend_q<=0;alpha_q<=0;program_len_q<=0;
      px_q<=0;py_q<=0;pixel_count_q<=0;
      shaded_pixels<=0;last_shaded_rgb<=0;
      clear_done<=0;tri_done<=0;shader_done<=0;
    end else begin
      clear_done<=0;tri_done<=0;shader_done<=0;
      case(state_q)
        IDLE:begin
          if(clear_valid && clear_ready)begin
            clear_rgb_q<=clear_color;clear_z_q<=clear_depth;
            clear_pos_q<=0;initialized_q<=0;
            shaded_pixels<=0;state_q<=CLEAR_ISSUE;
          end else if(tri_valid && tri_ready)begin
            depth_q<=tri_depth;
            depth_op_q<=depth_compare_op;
            write_z_q<=depth_write;
            blend_q<=blend_enable;
            alpha_q<=source_alpha;
            program_len_q<=shader_program_length;
            shaded_pixels<=0;
            state_q<=SCAN;
          end
        end
        CLEAR_ISSUE:if(rmw_ready)state_q<=CLEAR_WAIT;
        CLEAR_WAIT:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin
            state_q<=FAILED;local_fault_q<=1;
          end else if(clear_pos_q==$clog2(PIXELS+1)'(PIXELS-1))begin
            initialized_q<=1;clear_done<=1;state_q<=IDLE;
          end else begin
            clear_pos_q<=clear_next;
            state_q<=CLEAR_ISSUE;
          end
        end
        SCAN:begin
          if(raster_done)begin tri_done<=1;state_q<=IDLE;end
          else if(raster_pixel_valid)begin
            px_q<=raster_x;py_q<=raster_y;
            state_q<=LOAD_PIXEL;
          end
        end
        LOAD_PIXEL:state_q<=START_SHADER;
        START_SHADER:state_q<=WAIT_SHADER;
        WAIT_SHADER:begin
          if(shader_fault)begin state_q<=FAILED;local_fault_q<=1;end
          else if(shader_done_raw)begin
            color_q<=shader_data[23:0];
            last_shaded_rgb<=shader_data[23:0];
            shader_done<=1;
            state_q<=WRITE_PIXEL;
          end
        end
        WRITE_PIXEL:if(rmw_ready)state_q<=WAIT_WRITE;
        WAIT_WRITE:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin state_q<=FAILED;local_fault_q<=1;end
          else begin
            shaded_pixels<=shaded_pixels+16'd1;
            state_q<=SCAN;
          end
        end
        default:state_q<=FAILED;
      endcase
    end
  end
  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       PIXELS!=FRAME_WIDTH*FRAME_HEIGHT || PIXELS<2 || PIXELS>65536)
      $fatal(1,"P153 unsupported research framebuffer geometry");
  end
endmodule
