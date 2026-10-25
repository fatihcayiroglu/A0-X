`timescale 1ns/1ps
// P160: first real texture -> shader arithmetic -> pixel framebuffer path.
// P38 covered fragment -> P158/P159 bilinear P156 BRAM -> P150 UNORM ALU
// -> P144/P139/P138 RGB/depth BRAM, with raster release after RMW completion.
// Screen-space Q8.8 UV offsets are uniform per draw. This is NOT vertex UV
// interpolation, a programmable TEX ISA, a PCIe GPU, or physical hardware.
module a0_p160_textured_fragment_trial #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
)(
  input logic clk,rst_n,
  input logic tex_write_valid,
  output logic tex_write_ready,
  input logic [3:0] tex_write_x,tex_write_y,
  input logic [31:0] tex_write_rgba,
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
  input logic signed [15:0] uv_offset_u,uv_offset_v,
  input logic sample_repeat,
  input logic [2:0] shader_opcode,
  input logic [31:0] shader_operand_b,
  input logic [7:0] shader_alpha,
  input logic [3:0] shader_lane_mask,
  output logic initialized,busy,fault,
  output logic [15:0] shaded_pixels,
  output logic [23:0] last_shaded_rgb,
  output logic [1:0] pixel_writes,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  localparam logic [3:0] IDLE=0,CLEAR_ISSUE=1,CLEAR_WAIT=2,SCAN=3,
    TEX_ISSUE=4,TEX_WAIT=5,ALU_ISSUE=6,ALU_WAIT=7,
    WRITE_PIXEL=8,WAIT_WRITE=9,FAILED=10;
  logic [3:0] state_q;
  logic initialized_q,fault_q;
  logic [$clog2(PIXELS+1)-1:0] clear_pos_q;
  logic [23:0] clear_rgb_q,clear_z_q,depth_q,color_q;
  logic [1:0] depth_op_q;
  logic write_z_q,blend_q,repeat_q;
  logic [7:0] alpha_q,shader_alpha_q;
  logic signed [15:0] uv_u_q,uv_v_q;
  logic [2:0] shader_op_q;
  logic [3:0] shader_mask_q;
  logic [31:0] shader_other_q,sampled_rgba_q;
  logic [15:0] px_q,py_q;
  wire raster_ready,raster_pixel_valid,raster_done;
  wire [15:0] raster_x,raster_y;
  wire texture_write_ready,texture_ready,texture_valid,texture_present;
  wire [7:0] texture_id;
  wire [31:0] texture_rgba;
  wire alu_ready,alu_valid;
  wire [7:0] alu_id;
  wire [31:0] alu_data;
  wire rmw_ready,rmw_rsp_valid,rmw_rsp_error,rmw_host_ready;
  wire [1:0] rmw_written;
  wire mem_host_valid,mem_host_error;
  wire [23:0] mem_host_color,mem_host_depth;
  wire [15:0] clear_x=16'(clear_pos_q%FRAME_WIDTH);
  wire [15:0] clear_y=16'(clear_pos_q/FRAME_WIDTH);
  wire [7:0] fragment_id=px_q[7:0]^py_q[7:0];
  wire signed [15:0] tex_u=$signed(px_q <<< 8)+uv_u_q;
  wire signed [15:0] tex_v=$signed(py_q <<< 8)+uv_v_q;
  wire clear_op=state_q==CLEAR_ISSUE;
  wire pixel_op=state_q==WRITE_PIXEL;
  assign fault=fault_q;
  assign busy=state_q!=IDLE;
  assign initialized=initialized_q && !clear_op && state_q!=CLEAR_WAIT;
  assign pixel_writes=rmw_written;
  assign tex_write_ready=rst_n && state_q==IDLE && !fault &&
    !clear_valid && !tri_valid && !host_read_valid && texture_write_ready;
  assign clear_ready=rst_n && state_q==IDLE && !fault && rmw_ready &&
    texture_ready && alu_ready && !tex_write_valid && !tri_valid &&
    !host_read_valid;
  assign tri_ready=rst_n && state_q==IDLE && initialized && !fault &&
    raster_ready && texture_ready && alu_ready && rmw_ready &&
    !clear_valid && !tex_write_valid && !host_read_valid;
  assign host_read_ready=rst_n && state_q==IDLE && initialized && !fault &&
    !clear_valid && !tri_valid && !tex_write_valid && rmw_host_ready;
  assign host_rsp_valid=state_q==IDLE && mem_host_valid;
  assign host_rsp_error=state_q==IDLE && mem_host_error;
  assign host_rsp_color=host_rsp_valid?mem_host_color:24'd0;
  assign host_rsp_depth=host_rsp_valid?mem_host_depth:24'd0;

  a0_triangle_coverage_p38 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) raster(
    .clk(clk),.rst_n(rst_n),
    .tri_valid(tri_valid && tri_ready),.tri_ready(raster_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(raster_pixel_valid),
    .pixel_ready(state_q==WAIT_WRITE && rmw_rsp_valid && !rmw_rsp_error),
    .pixel_x(raster_x),.pixel_y(raster_y),.done(raster_done)
  );
  a0_p158_bilinear_texture texture(
    .clk(clk),.rst_n(rst_n),
    .write_valid(tex_write_valid && tex_write_ready),
    .write_ready(texture_write_ready),
    .write_x(tex_write_x),.write_y(tex_write_y),
    .write_rgba(tex_write_rgba),
    .sample_valid(state_q==TEX_ISSUE),.sample_ready(texture_ready),
    .sample_u(tex_u),.sample_v(tex_v),.sample_repeat(repeat_q),
    .sample_id(fragment_id),
    .rsp_valid(texture_valid),.rsp_ready(state_q==TEX_WAIT),
    .rsp_id(texture_id),.rsp_rgba(texture_rgba),
    .rsp_present(texture_present)
  );
  a0_p150_unorm_simd4_alu shader(
    .clk(clk),.rst_n(rst_n),
    .req_valid(state_q==ALU_ISSUE),.req_ready(alu_ready),
    .req_id(fragment_id),.opcode(shader_op_q),
    .operand_a(sampled_rgba_q),.operand_b(shader_other_q),
    .uniform_alpha(shader_alpha_q),.lane_mask(shader_mask_q),
    .rsp_valid(alu_valid),.rsp_ready(state_q==ALU_WAIT),
    .rsp_id(alu_id),.rsp_data(alu_data)
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
    .host_read_valid(host_read_valid && state_q==IDLE &&
      !clear_valid && !tri_valid && !tex_write_valid),
    .host_read_ready(rmw_host_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(mem_host_valid),.host_rsp_error(mem_host_error),
    .host_rsp_color(mem_host_color),.host_rsp_depth(mem_host_depth)
  );
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;initialized_q<=0;fault_q<=0;
      clear_pos_q<=0;clear_rgb_q<=0;clear_z_q<=0;
      depth_q<=0;color_q<=0;depth_op_q<=0;write_z_q<=0;
      blend_q<=0;alpha_q<=0;repeat_q<=0;
      uv_u_q<=0;uv_v_q<=0;shader_op_q<=0;shader_mask_q<=0;
      shader_alpha_q<=0;shader_other_q<=0;sampled_rgba_q<=0;
      px_q<=0;py_q<=0;shaded_pixels<=0;last_shaded_rgb<=0;
      clear_done<=0;tri_done<=0;
    end else begin
      clear_done<=0;tri_done<=0;
      case(state_q)
        IDLE:begin
          if(clear_valid && clear_ready)begin
            clear_rgb_q<=clear_color;clear_z_q<=clear_depth;
            clear_pos_q<=0;initialized_q<=0;shaded_pixels<=0;
            state_q<=CLEAR_ISSUE;
          end else if(tri_valid && tri_ready)begin
            depth_q<=tri_depth;depth_op_q<=depth_compare_op;
            write_z_q<=depth_write;blend_q<=blend_enable;
            alpha_q<=source_alpha;repeat_q<=sample_repeat;
            uv_u_q<=uv_offset_u;uv_v_q<=uv_offset_v;
            shader_op_q<=shader_opcode;
            shader_other_q<=shader_operand_b;
            shader_alpha_q<=shader_alpha;shader_mask_q<=shader_lane_mask;
            shaded_pixels<=0;state_q<=SCAN;
          end
        end
        CLEAR_ISSUE:if(rmw_ready)state_q<=CLEAR_WAIT;
        CLEAR_WAIT:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin state_q<=FAILED;fault_q<=1;end
          else if(clear_pos_q==PIXELS-1)begin
            initialized_q<=1;clear_done<=1;state_q<=IDLE;
          end else begin clear_pos_q<=clear_pos_q+1'b1;state_q<=CLEAR_ISSUE;end
        end
        SCAN:begin
          if(raster_done)begin tri_done<=1;state_q<=IDLE;end
          else if(raster_pixel_valid)begin
            px_q<=raster_x;py_q<=raster_y;
            state_q<=TEX_ISSUE;
          end
        end
        TEX_ISSUE:if(texture_ready)state_q<=TEX_WAIT;
        TEX_WAIT:if(texture_valid)begin
          if(texture_id!=fragment_id || !texture_present)begin
            fault_q<=1;state_q<=FAILED;
          end else begin
            sampled_rgba_q<=texture_rgba;state_q<=ALU_ISSUE;
          end
        end
        ALU_ISSUE:if(alu_ready)state_q<=ALU_WAIT;
        ALU_WAIT:if(alu_valid)begin
          if(alu_id!=fragment_id)begin fault_q<=1;state_q<=FAILED;end
          else begin
            color_q<=alu_data[23:0];last_shaded_rgb<=alu_data[23:0];
            state_q<=WRITE_PIXEL;
          end
        end
        WRITE_PIXEL:if(rmw_ready)state_q<=WAIT_WRITE;
        WAIT_WRITE:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin fault_q<=1;state_q<=FAILED;end
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
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_WIDTH>128 ||
       FRAME_HEIGHT>128 || PIXELS!=FRAME_WIDTH*FRAME_HEIGHT || PIXELS<2)
      $fatal(1,"P160 signed Q8.8 screen-space framebuffer unsupported");
  end
endmodule
