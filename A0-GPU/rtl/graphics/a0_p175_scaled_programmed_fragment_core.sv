`timescale 1ns/1ps
// P168: P38 raster -> single shared P166 fast-affine/perspective UV -> P162 TEX shader
// -> real P144 depth/blend RGB BRAM. Sequential research renderer only.
// All 8 shader registers are initialized per covered pixel: R0 is signed
// screen Q8.8 texel coordinates, R1..R7 are user-defined draw seeds.
module a0_p175_scaled_programmed_fragment_core #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
  parameter bit TILED_SCREEN_UV=1'b0
)(
  input logic clk,rst_n,
  input logic seed_write_valid,
  output logic seed_write_ready,
  input logic [2:0] seed_write_index,
  input logic [31:0] seed_write_data,
  input logic insn_write_valid,
  output logic insn_write_ready,
  input logic [3:0] insn_write_index,
  input logic [24:0] insn_write_data,
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
  input logic affine_uv_enable,perspective_uv_enable,
  input logic signed [15:0] uv0_u,uv0_v,uv1_u,uv1_v,uv2_u,uv2_v,
  input logic [15:0] inv_w0,inv_w1,inv_w2,
  input logic [4:0] program_length,
  input logic [2:0] output_reg,
  output logic initialized,busy,fault,
  output logic [31:0] shaded_pixels,shader_instructions,texture_operations,
  output logic [23:0] last_shaded_rgb,
  input logic host_read_valid,
  output logic host_read_ready,
  input logic [15:0] host_read_x,host_read_y,
  output logic host_rsp_valid,host_rsp_error,
  output logic [23:0] host_rsp_color,host_rsp_depth
);
  localparam logic [3:0]
    IDLE=0,CLEAR_ISSUE=1,CLEAR_WAIT=2,SCAN=3,PREP_REG=4,
    LAUNCH_SHADER=5,WAIT_SHADER=6,WRITE_PIXEL=7,WAIT_WRITE=8,FAILED=9,
    UV_ISSUE=10,UV_WAIT=11;
  logic [3:0] state_q;
  logic initialized_q,fault_q;
  logic [$clog2(PIXELS+1)-1:0] clear_pos_q;
  logic [2:0] seed_ptr_q,output_reg_q;
  logic [31:0] seed_regs[0:7];
  logic [4:0] length_q;
  logic signed [15:0] uv_u_q,uv_v_q;
  logic [1:0] uv_mode_q;
  logic [15:0] iw0_q,iw1_q,iw2_q;
  logic signed [15:0] vx0_q,vy0_q,vx1_q,vy1_q,vx2_q,vy2_q;
  logic signed [15:0] vu0_q,vv0_q,vu1_q,vv1_q,vu2_q,vv2_q;
  logic signed [15:0] interpolated_u_q,interpolated_v_q;
  logic [7:0] uv_next_id_q,uv_expected_id_q,uv_wait_cycles_q;
  wire uv_req_ready,uv_rsp_valid,uv_rsp_error;
  // One hardware engine serves both interpolation modes. The all-one
  // inverse-W values select the exact 64-cycle-per-coordinate affine path;
  // perspective retains its signed 80-cycle path and immutable draw snapshot.
  wire [7:0] uv_rsp_id;
  wire signed [15:0] uv_rsp_u,uv_rsp_v;
  wire signed [16:0] uv_sum_u=$signed(uv_rsp_u)+$signed(uv_u_q);
  wire signed [16:0] uv_sum_v=$signed(uv_rsp_v)+$signed(uv_v_q);
  wire uv_sum_overflow=(uv_sum_u[16]!=uv_sum_u[15]) ||
                        (uv_sum_v[16]!=uv_sum_v[15]);
  logic [23:0] clear_rgb_q,clear_z_q,depth_q,color_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_q;
  logic [7:0] alpha_q;
  logic [15:0] px_q,py_q;
  // P171: coordinate mux is resolved at transaction boundaries, not in
  // the same cycle as the dual-bank framebuffer address arithmetic.
  logic [15:0] fb_x_q,fb_y_q;

  wire raster_ready,raster_pixel_valid,raster_done;
  wire [15:0] raster_x,raster_y;
  wire shader_ready,shader_busy,shader_done,shader_fault;
  wire [31:0] shader_data;
  wire [4:0] shader_retired,shader_tex_count;
  wire shader_tex_ready;
  wire rmw_ready,rmw_rsp_valid,rmw_rsp_error,rmw_host_ready;
  wire [1:0] rmw_written;
  wire mem_host_valid,mem_host_error;
  wire [23:0] mem_host_color,mem_host_depth;
  wire signed [15:0] uv_pixel_x=px_q,uv_pixel_y=py_q;
  wire signed [15:0] tex_u,tex_v,preload_tex_u,preload_tex_v;
  wire uv_preload_overflow;
  // P191: compile-time opt-in. Default 1..128 geometry preserves the
  // exact original nine-bit preload and registered R0 fallback topology.
  // In tile mode shader UV is local; framebuffer XY remains global.
  generate
    if(TILED_SCREEN_UV)begin: tiled_screen_uv
      wire signed [15:0] delayed_u,delayed_v;
      wire delayed_invalid;
      a0_p190_tiled_screen_uv uv_raster_converter(
        .pixel_x(raster_x),.pixel_y(raster_y),
        .offset_u(uv_u_q),.offset_v(uv_v_q),
        .tile_enable(1'b1),
        .tex_u(preload_tex_u),.tex_v(preload_tex_v),
        .invalid(uv_preload_overflow)
      );
      a0_p190_tiled_screen_uv uv_registered_converter(
        .pixel_x(px_q),.pixel_y(py_q),
        .offset_u(uv_u_q),.offset_v(uv_v_q),
        .tile_enable(1'b1),
        .tex_u(delayed_u),.tex_v(delayed_v),
        .invalid(delayed_invalid)
      );
      assign tex_u=uv_mode_q!=0 ? interpolated_u_q :
        (delayed_invalid ? 16'sd0 : delayed_u);
      assign tex_v=uv_mode_q!=0 ? interpolated_v_q :
        (delayed_invalid ? 16'sd0 : delayed_v);
    end else begin: legacy_screen_uv
      wire signed [8:0] preload_tex_u_integer_wide=
        $signed({2'b00,raster_x[6:0]})+
        $signed({uv_u_q[15],uv_u_q[15:8]});
      wire signed [8:0] preload_tex_v_integer_wide=
        $signed({2'b00,raster_y[6:0]})+
        $signed({uv_v_q[15],uv_v_q[15:8]});
      assign uv_preload_overflow=
        (preload_tex_u_integer_wide[8]!=preload_tex_u_integer_wide[7]) ||
        (preload_tex_v_integer_wide[8]!=preload_tex_v_integer_wide[7]);
      assign preload_tex_u=
        {preload_tex_u_integer_wide[7:0],uv_u_q[7:0]};
      assign preload_tex_v=
        {preload_tex_v_integer_wide[7:0],uv_v_q[7:0]};
      assign tex_u=uv_mode_q!=0 ? interpolated_u_q :
        ($signed(px_q <<< 8)+uv_u_q);
      assign tex_v=uv_mode_q!=0 ? interpolated_v_q :
        ($signed(py_q <<< 8)+uv_v_q);
    end
  endgenerate
  wire [31:0] shader_seed=seed_ptr_q==0 ?
    {tex_v,tex_u} : seed_regs[seed_ptr_q];
  wire preload_shader_uv=state_q==SCAN && raster_pixel_valid &&
    uv_mode_q==2'd0 && !uv_preload_overflow && shader_ready;
  wire [31:0] shader_write_data=preload_shader_uv ?
    {preload_tex_v,preload_tex_u} : shader_seed;
  wire clear_op=state_q==CLEAR_ISSUE;
  wire pixel_op=state_q==WRITE_PIXEL;
  wire config_attempt=seed_write_valid || insn_write_valid || tex_write_valid;
  wire config_busy=clear_valid || tri_valid || host_read_valid;
  assign initialized=initialized_q && !clear_op && state_q!=CLEAR_WAIT;
  assign fault=fault_q || shader_fault;
  assign busy=state_q!=IDLE;
  assign seed_write_ready=rst_n && state_q==IDLE && !fault &&
    seed_write_index!=0 && !insn_write_valid && !tex_write_valid &&
    !config_busy && shader_ready;
  assign insn_write_ready=rst_n && state_q==IDLE && !fault &&
    !seed_write_valid && !tex_write_valid && !config_busy && shader_ready;
  assign tex_write_ready=rst_n && state_q==IDLE && !fault &&
    !seed_write_valid && !insn_write_valid && !config_busy && shader_tex_ready;
  assign clear_ready=rst_n && state_q==IDLE && !fault &&
    !tri_valid && !host_read_valid && !config_attempt && rmw_ready && shader_ready;
  assign tri_ready=rst_n && state_q==IDLE && initialized && !fault &&
    program_length>=1 && program_length<=16 &&
    !clear_valid && !host_read_valid && !config_attempt &&
    raster_ready && rmw_ready && shader_ready &&
    (!perspective_uv_enable ||
       (inv_w0!=16'd0 && inv_w1!=16'd0 && inv_w2!=16'd0));
  assign host_read_ready=rst_n && state_q==IDLE && initialized && !fault &&
    !clear_valid && !tri_valid && !config_attempt && rmw_host_ready;
  assign host_rsp_valid=state_q==IDLE && mem_host_valid;
  assign host_rsp_error=state_q==IDLE && mem_host_error;
  assign host_rsp_color=host_rsp_valid?mem_host_color:24'd0;
  assign host_rsp_depth=host_rsp_valid?mem_host_depth:24'd0;

  a0_triangle_coverage_p38 #(.FRAME_WIDTH(FRAME_WIDTH),
     .FRAME_HEIGHT(FRAME_HEIGHT)) raster(
    .clk(clk),.rst_n(rst_n),
    .tri_valid(tri_valid && tri_ready),.tri_ready(raster_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(raster_pixel_valid),
    .pixel_ready(state_q==WAIT_WRITE && rmw_rsp_valid && !rmw_rsp_error),
    .pixel_x(raster_x),.pixel_y(raster_y),.done(raster_done)
  );
  a0_p166_perspective_vertex_uv shared_uv_interpolator(
    .clk(clk),.rst_n(rst_n),
    .req_valid(state_q==UV_ISSUE && uv_mode_q!=2'd0),
    .req_ready(uv_req_ready),
    .x0(vx0_q),.y0(vy0_q),.x1(vx1_q),.y1(vy1_q),
    .x2(vx2_q),.y2(vy2_q),
    .u0(vu0_q),.v0(vv0_q),.u1(vu1_q),.v1(vv1_q),
    .u2(vu2_q),.v2(vv2_q),
    .inv_w0(uv_mode_q==2'd1 ? 16'd1 : iw0_q),
    .inv_w1(uv_mode_q==2'd1 ? 16'd1 : iw1_q),
    .inv_w2(uv_mode_q==2'd1 ? 16'd1 : iw2_q),
    .pixel_x(uv_pixel_x),.pixel_y(uv_pixel_y),
    .req_id(uv_next_id_q),.rsp_valid(uv_rsp_valid),
    .rsp_ready(state_q==UV_WAIT),
    .rsp_id(uv_rsp_id),.rsp_u(uv_rsp_u),.rsp_v(uv_rsp_v),
    .rsp_error(uv_rsp_error)
  );
  a0_p162_textured_microprogram shader(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid((state_q==PREP_REG && shader_ready) ||
      preload_shader_uv),
    .reg_write_index(preload_shader_uv ? 3'd0 : seed_ptr_q),
    .reg_write_data(shader_write_data),
    .reg_read_index(output_reg_q),.reg_read_data(shader_data),
    .insn_write_valid(insn_write_valid && insn_write_ready),
    .insn_write_index(insn_write_index),.insn_write_data(insn_write_data),
    .texture_write_valid(tex_write_valid && tex_write_ready),
    .texture_write_ready(shader_tex_ready),
    .texture_write_x(tex_write_x),.texture_write_y(tex_write_y),
    .texture_write_rgba(tex_write_rgba),
    .start(state_q==LAUNCH_SHADER && shader_ready),
    .start_length(length_q),.ready(shader_ready),.busy(shader_busy),
    .done(shader_done),.fault(shader_fault),
    .retired_count(shader_retired),.texture_retired_count(shader_tex_count)
  );
  // This core blocks all reads/draws until its complete per-pixel clear
  // returns success. Only large shapes replace resettable validity bits
  // with a single frame-initialized guard; all standalone modules default off.
  a0_p144_dual_depth_blend_rmw #(.FRAME_WIDTH(FRAME_WIDTH),
     .FRAME_HEIGHT(FRAME_HEIGHT),.FULL_CLEAR_GUARD(PIXELS>=2048)) framebuffer(
    .clk(clk),.rst_n(rst_n),.frame_initialized(initialized_q),
    .op_valid(clear_op || pixel_op),.op_ready(rmw_ready),
    .op_clear(clear_op),
    .lane0_valid(1'b1),.lane1_valid(1'b0),
    .lane0_x(fb_x_q),
    .lane0_y(fb_y_q),
    .lane1_x(16'd0),.lane1_y(16'd0),
    .source_rgb(clear_op?clear_rgb_q:color_q),
    .source_depth(clear_op?clear_z_q:depth_q),
    .depth_compare_op(depth_op_q),.depth_write(depth_write_q),
    .blend_enable(blend_q),.source_alpha(alpha_q),
    .rsp_valid(rmw_rsp_valid),.rsp_error(rmw_rsp_error),
    .rsp_pixel_written(rmw_written),
    .host_read_valid(host_read_valid && state_q==IDLE &&
      !clear_valid && !tri_valid && !config_attempt),
    .host_read_ready(rmw_host_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(mem_host_valid),.host_rsp_error(mem_host_error),
    .host_rsp_color(mem_host_color),.host_rsp_depth(mem_host_depth)
  );

  integer i;
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;initialized_q<=0;fault_q<=0;
      clear_pos_q<=0;seed_ptr_q<=0;output_reg_q<=0;length_q<=0;
      uv_u_q<=0;uv_v_q<=0;uv_mode_q<=0;
      iw0_q<=0;iw1_q<=0;iw2_q<=0;
      vx0_q<=0;vy0_q<=0;vx1_q<=0;vy1_q<=0;vx2_q<=0;vy2_q<=0;
      vu0_q<=0;vv0_q<=0;vu1_q<=0;vv1_q<=0;vu2_q<=0;vv2_q<=0;
      interpolated_u_q<=0;interpolated_v_q<=0;
      uv_next_id_q<=0;uv_expected_id_q<=0;uv_wait_cycles_q<=0;
      clear_rgb_q<=0;clear_z_q<=0;depth_q<=0;color_q<=0;
      depth_op_q<=0;depth_write_q<=0;blend_q<=0;alpha_q<=0;
      px_q<=0;py_q<=0;fb_x_q<=0;fb_y_q<=0;
      shaded_pixels<=0;shader_instructions<=0;texture_operations<=0;
      last_shaded_rgb<=0;clear_done<=0;tri_done<=0;
      for(i=0;i<8;i=i+1)seed_regs[i]<=0;
    end else begin
      clear_done<=0;tri_done<=0;
      case(state_q)
        IDLE:begin
          // Fail closed on ambiguous simultaneous host control classes.
          if((seed_write_valid && (insn_write_valid || tex_write_valid || config_busy)) ||
             (insn_write_valid && (tex_write_valid || config_busy)) ||
             (tex_write_valid && config_busy) ||
             (clear_valid && (tri_valid || host_read_valid)) ||
             (tri_valid && host_read_valid))begin
            fault_q<=1;state_q<=FAILED;
          end else if(seed_write_valid && seed_write_index==0)begin
            fault_q<=1;state_q<=FAILED;
          end else if(seed_write_valid && seed_write_ready)begin
            seed_regs[seed_write_index]<=seed_write_data;
          end else if(clear_valid && clear_ready)begin
            clear_rgb_q<=clear_color;clear_z_q<=clear_depth;
            clear_pos_q<=0;initialized_q<=0;
            fb_x_q<=0;fb_y_q<=0;
            shaded_pixels<=0;shader_instructions<=0;texture_operations<=0;
            state_q<=CLEAR_ISSUE;
          end else if(tri_valid && program_length==0)begin
            fault_q<=1;state_q<=FAILED;
          end else if(tri_valid && tri_ready)begin
            depth_q<=tri_depth;depth_op_q<=depth_compare_op;
            depth_write_q<=depth_write;blend_q<=blend_enable;
            alpha_q<=source_alpha;
            uv_u_q<=uv_offset_u;uv_v_q<=uv_offset_v;
            uv_mode_q<=perspective_uv_enable ? 2'd2 :
              (affine_uv_enable ? 2'd1 : 2'd0);
            iw0_q<=inv_w0;iw1_q<=inv_w1;iw2_q<=inv_w2;
            vx0_q<=x0;vy0_q<=y0;vx1_q<=x1;vy1_q<=y1;
            vx2_q<=x2;vy2_q<=y2;
            vu0_q<=uv0_u;vv0_q<=uv0_v;
            vu1_q<=uv1_u;vv1_q<=uv1_v;
            vu2_q<=uv2_u;vv2_q<=uv2_v;
            uv_next_id_q<=0;uv_expected_id_q<=0;
            interpolated_u_q<=0;interpolated_v_q<=0;
            length_q<=program_length;output_reg_q<=output_reg;
            shaded_pixels<=0;shader_instructions<=0;texture_operations<=0;
            state_q<=SCAN;
          end
        end
        CLEAR_ISSUE:if(rmw_ready)state_q<=CLEAR_WAIT;
        CLEAR_WAIT:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin fault_q<=1;state_q<=FAILED;end
          else if(clear_pos_q==PIXELS-1)begin
            initialized_q<=1;clear_done<=1;state_q<=IDLE;
          end else begin
            clear_pos_q<=clear_pos_q+1'b1;
            fb_x_q<=16'((clear_pos_q+1'b1)%FRAME_WIDTH);
            fb_y_q<=16'((clear_pos_q+1'b1)/FRAME_WIDTH);
            state_q<=CLEAR_ISSUE;
          end
        end
        SCAN:begin
          if(raster_done)begin tri_done<=1;state_q<=IDLE;end
          else if(raster_pixel_valid)begin
            if(uv_mode_q==2'd0 && uv_preload_overflow)begin
              fault_q<=1;state_q<=FAILED;
            end else begin
              px_q<=raster_x;py_q<=raster_y;
              seed_ptr_q<=preload_shader_uv ? 3'd1 : 3'd0;
              state_q<=uv_mode_q!=0 ? UV_ISSUE : PREP_REG;
            end
          end
        end
        UV_ISSUE:if(uv_req_ready)begin
          uv_expected_id_q<=uv_next_id_q;
          uv_next_id_q<=uv_next_id_q+8'd1;
          uv_wait_cycles_q<=0;
          state_q<=UV_WAIT;
        end
        UV_WAIT:begin
          if(uv_rsp_valid)begin
            if(uv_rsp_error || uv_rsp_id!=uv_expected_id_q ||
               uv_sum_overflow)begin fault_q<=1;state_q<=FAILED;end
            else begin
              interpolated_u_q<=uv_sum_u[15:0];
              interpolated_v_q<=uv_sum_v[15:0];
              state_q<=PREP_REG;
            end
          end else if(uv_wait_cycles_q==8'd250)begin
            fault_q<=1;state_q<=FAILED;
          end else uv_wait_cycles_q<=uv_wait_cycles_q+8'd1;
        end
        PREP_REG:begin
          if(shader_fault)begin fault_q<=1;state_q<=FAILED;end
          else if(shader_ready)begin
            if(seed_ptr_q==3'd7)state_q<=LAUNCH_SHADER;
            else seed_ptr_q<=seed_ptr_q+3'd1;
          end
        end
        LAUNCH_SHADER:begin
          if(shader_fault)begin fault_q<=1;state_q<=FAILED;end
          else if(shader_ready)state_q<=WAIT_SHADER;
        end
        WAIT_SHADER:begin
          if(shader_fault)begin fault_q<=1;state_q<=FAILED;end
          else if(shader_done)begin
            if(shader_retired!=length_q)begin fault_q<=1;state_q<=FAILED;end
            else begin
              fb_x_q<=px_q;fb_y_q<=py_q;
              color_q<=shader_data[23:0];
              last_shaded_rgb<=shader_data[23:0];
              shader_instructions<=shader_instructions+32'(shader_retired);
              texture_operations<=texture_operations+32'(shader_tex_count);
              state_q<=WRITE_PIXEL;
            end
          end
        end
        WRITE_PIXEL:if(rmw_ready)state_q<=WAIT_WRITE;
        WAIT_WRITE:if(rmw_rsp_valid)begin
          if(rmw_rsp_error)begin fault_q<=1;state_q<=FAILED;end
          else begin
            shaded_pixels<=shaded_pixels+32'd1;
            state_q<=SCAN;
          end
        end
        FAILED:begin end
        default:begin fault_q<=1;state_q<=FAILED;end
      endcase
    end
  end
  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       (TILED_SCREEN_UV ? (FRAME_WIDTH>256 || FRAME_HEIGHT>256) :
         (FRAME_WIDTH>128 || FRAME_HEIGHT>128)) ||
       PIXELS!=FRAME_WIDTH*FRAME_HEIGHT || PIXELS<2 || PIXELS>65536)
      $fatal(1,"P163 framebuffer unsupported geometry");
  end
endmodule
