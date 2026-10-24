`timescale 1ns/1ps
// P152: 76-pin research bus to real P151 shader microprogram and P145
// dual-bank raster. Shader output register 2 supplies triangle RGB.
// Deliberately not PCIe, AXI, clock-domain crossing or physical pinout.
// Accepted requests receive one response; host pixel reads wait for the
// actual registered BRAM response. Clear/draw are asynchronous commands:
// caller polls sticky completion/status, never assumes response==draw done.
module a0_p152_packed_shaded_command_top #(
  parameter integer FRAME_WIDTH=4, FRAME_HEIGHT=4
)(
  input  logic clk, rst_n,
  input  logic req_valid, req_write,
  output logic req_ready,
  input  logic [4:0] req_addr,
  input  logic [31:0] req_wdata,
  output logic rsp_valid, rsp_error,
  output logic [31:0] rsp_rdata
);
  localparam logic [4:0]
    REG_CLEAR_RGB=5'd0, REG_CLEAR_DEPTH=5'd1,
    REG_TRI_RGB=5'd2, REG_TRI_DEPTH=5'd3,
    REG_V0=5'd4, REG_V1=5'd5, REG_V2=5'd6,
    REG_SCISSOR_XY=5'd7, REG_SCISSOR_WH=5'd8,
    REG_MODE=5'd9, REG_READ_XY=5'd10,
    REG_COMMAND=5'd11, REG_STATUS=5'd12,
    REG_PIXEL_RGB=5'd13, REG_PIXEL_DEPTH=5'd14,
    REG_IDENT=5'd15,
    REG_SHADER_SELECT=5'd16, REG_SHADER_REG_DATA=5'd17,
    REG_SHADER_INSN_DATA=5'd18, REG_SHADER_LENGTH=5'd19,
    REG_SHADER_VECTOR=5'd20, REG_SHADED_RGB=5'd21,
    REG_SHADER_RETIRED=5'd22;
  localparam logic [31:0] DEVICE_ID=32'hA0152001;

  logic [23:0] clear_rgb_q,clear_depth_q,tri_depth_q;
  logic [2:0] selected_reg_q;
  logic [3:0] selected_insn_q;
  logic [4:0] shader_len_q;
  wire [31:0] shader_dbg_data;
  wire [23:0] last_shaded_rgb;
  wire [4:0] shader_retired;
  wire shader_cfg_ready,shader_done;
  logic signed [15:0] x0_q,y0_q,x1_q,y1_q,x2_q,y2_q;
  logic [15:0] scissor_x_q,scissor_y_q,scissor_w_q,scissor_h_q;
  logic [15:0] host_x_q,host_y_q;
  logic [1:0] depth_op_q;
  logic depth_write_q,blend_q,scissor_enable_q;
  logic [7:0] alpha_q;
  logic [23:0] pixel_rgb_q,pixel_depth_q;
  logic pixel_cached_q, read_pending_q;
  logic clear_done_sticky_q,tri_done_sticky_q,shader_done_sticky_q;

  wire core_clear_ready,core_clear_done,core_tri_ready,core_tri_done;
  wire core_initialized,core_busy,core_fault;
  wire [1:0] core_pixel_writes;
  wire core_host_ready,core_host_valid,core_host_error;
  wire [23:0] core_host_color,core_host_depth;

  assign req_ready=rst_n && !rsp_valid && !read_pending_q;
  wire fire=req_valid && req_ready;
  wire write_cmd=fire && req_write && req_addr==REG_COMMAND;
  wire clear_request=write_cmd && req_wdata==32'd1;
  wire tri_request=write_cmd && req_wdata==32'd2;
  wire host_request=write_cmd && req_wdata==32'd3;
  wire clear_launch=clear_request && core_clear_ready;
  wire tri_launch=tri_request && core_tri_ready;
  wire host_launch=host_request && core_host_ready;

  a0_p152_shaded_triangle_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) full_16bit_raster(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_launch),.clear_ready(core_clear_ready),
    .clear_color(clear_rgb_q),.clear_depth(clear_depth_q),
    .clear_done(core_clear_done),
    .tri_valid(tri_launch),.tri_ready(core_tri_ready),
    .tri_done(core_tri_done),
    .x0(x0_q),.y0(y0_q),.x1(x1_q),.y1(y1_q),.x2(x2_q),.y2(y2_q),
    .tri_depth(tri_depth_q),
    .shader_program_length(shader_len_q),
    .shader_reg_write_valid(fire && req_write &&
                            req_addr==REG_SHADER_REG_DATA),
    .shader_reg_write_index(selected_reg_q),
    .shader_reg_write_data(req_wdata),
    .shader_insn_write_valid(fire && req_write &&
                             req_addr==REG_SHADER_INSN_DATA &&
                             req_wdata[31:24]==0),
    .shader_insn_write_index(selected_insn_q),
    .shader_insn_write_data(req_wdata[23:0]),
    .shader_debug_index(selected_reg_q),.shader_debug_data(shader_dbg_data),
    .shader_config_ready(shader_cfg_ready),.shader_done(shader_done),
    .shader_retired_count(shader_retired),.last_shaded_rgb(last_shaded_rgb),
    .depth_compare_op(depth_op_q),.depth_write(depth_write_q),
    .blend_enable(blend_q),.source_alpha(alpha_q),
    .scissor_enable(scissor_enable_q),
    .scissor_x(scissor_x_q),.scissor_y(scissor_y_q),
    .scissor_w(scissor_w_q),.scissor_h(scissor_h_q),
    .initialized(core_initialized),.busy(core_busy),.fault(core_fault),
    .pixel_writes(core_pixel_writes),
    .host_read_valid(host_launch),.host_read_ready(core_host_ready),
    .host_read_x(host_x_q),.host_read_y(host_y_q),
    .host_rsp_valid(core_host_valid),.host_rsp_error(core_host_error),
    .host_rsp_color(core_host_color),.host_rsp_depth(core_host_depth)
  );

  always_ff @(posedge clk) begin
    if(!rst_n) begin
      clear_rgb_q<=0;clear_depth_q<=0;tri_depth_q<=0;
      selected_reg_q<=0;selected_insn_q<=0;shader_len_q<=0;
      shader_done_sticky_q<=0;
      x0_q<=0;y0_q<=0;x1_q<=0;y1_q<=0;x2_q<=0;y2_q<=0;
      scissor_x_q<=0;scissor_y_q<=0;scissor_w_q<=0;scissor_h_q<=0;
      host_x_q<=0;host_y_q<=0;
      depth_op_q<=0;depth_write_q<=0;blend_q<=0;
      scissor_enable_q<=0;alpha_q<=0;
      pixel_rgb_q<=0;pixel_depth_q<=0;pixel_cached_q<=0;
      read_pending_q<=0;
      clear_done_sticky_q<=0;tri_done_sticky_q<=0;
      rsp_valid<=0;rsp_error<=0;rsp_rdata<=0;
    end else begin
      // Registered one-beat bus reply; no unacknowledged reply is dropped
      // because no new request may be accepted while rsp_valid is high.
      rsp_valid<=0;
      rsp_error<=0;
      rsp_rdata<=0;
      if(core_clear_done) clear_done_sticky_q<=1;
      if(core_tri_done) tri_done_sticky_q<=1;
      if(shader_done)shader_done_sticky_q<=1;
      if(read_pending_q && core_host_valid) begin
        read_pending_q<=0;
        pixel_rgb_q<=core_host_error ? 24'd0 : core_host_color;
        pixel_depth_q<=core_host_error ? 24'd0 : core_host_depth;
        pixel_cached_q<=!core_host_error;
        rsp_valid<=1;
        rsp_error<=core_host_error;
      end else if(fire) begin
        if(req_write) begin
          // All configuration writes are atomic, even while the core is
          // busy; core samples a complete command snapshot on launch.
          rsp_valid<=1;
          case(req_addr)
            REG_CLEAR_RGB:clear_rgb_q<=req_wdata[23:0];
            REG_CLEAR_DEPTH:clear_depth_q<=req_wdata[23:0];
            REG_TRI_RGB:rsp_error<=1; // Triangle RGB now comes from shader R2.
            REG_TRI_DEPTH:tri_depth_q<=req_wdata[23:0];
            REG_V0:begin x0_q<=req_wdata[15:0];y0_q<=req_wdata[31:16];end
            REG_V1:begin x1_q<=req_wdata[15:0];y1_q<=req_wdata[31:16];end
            REG_V2:begin x2_q<=req_wdata[15:0];y2_q<=req_wdata[31:16];end
            REG_SCISSOR_XY:begin
              scissor_x_q<=req_wdata[15:0];scissor_y_q<=req_wdata[31:16];
            end
            REG_SCISSOR_WH:begin
              scissor_w_q<=req_wdata[15:0];scissor_h_q<=req_wdata[31:16];
            end
            REG_MODE:begin
              if(req_wdata[31:16]!=16'd0 || req_wdata[7:5]!=3'd0)
                rsp_error<=1;
              else begin
                depth_op_q<=req_wdata[1:0];
                depth_write_q<=req_wdata[2];
                blend_q<=req_wdata[3];
                scissor_enable_q<=req_wdata[4];
                alpha_q<=req_wdata[15:8];
              end
            end
            REG_READ_XY:begin
              host_x_q<=req_wdata[15:0];host_y_q<=req_wdata[31:16];
            end
            REG_SHADER_SELECT:begin
              if(!shader_cfg_ready || req_wdata[31:7]!=0)
                rsp_error<=1;
              else begin
                selected_reg_q<=req_wdata[6:4];
                selected_insn_q<=req_wdata[3:0];
              end
            end
            REG_SHADER_REG_DATA:if(!shader_cfg_ready)rsp_error<=1;
            REG_SHADER_INSN_DATA:begin
              if(!shader_cfg_ready || req_wdata[31:24]!=0)rsp_error<=1;
            end
            REG_SHADER_LENGTH:begin
              if(!shader_cfg_ready || req_wdata[31:5]!=0 ||
                 req_wdata[4:0]==0 || req_wdata[4:0]>16)
                rsp_error<=1;
              else shader_len_q<=req_wdata[4:0];
            end
            REG_COMMAND:begin
              if(clear_launch)begin
                clear_done_sticky_q<=0;
                pixel_cached_q<=0;
              end else if(tri_launch)begin
                tri_done_sticky_q<=0;
                shader_done_sticky_q<=0;
              end else if(host_launch)begin
                read_pending_q<=1;
                pixel_cached_q<=0;
                rsp_valid<=0; // Reply deferred to real BRAM response.
              end else rsp_error<=1; // Busy, invalid or unknown command.
            end
            default:rsp_error<=1; // No writes to status, results or ID.
          endcase
        end else begin
          rsp_valid<=1;
          case(req_addr)
            REG_CLEAR_RGB:rsp_rdata<={8'd0,clear_rgb_q};
            REG_CLEAR_DEPTH:rsp_rdata<={8'd0,clear_depth_q};
            REG_TRI_RGB:rsp_error<=1;
            REG_TRI_DEPTH:rsp_rdata<={8'd0,tri_depth_q};
            REG_V0:rsp_rdata<={y0_q,x0_q};
            REG_V1:rsp_rdata<={y1_q,x1_q};
            REG_V2:rsp_rdata<={y2_q,x2_q};
            REG_SCISSOR_XY:rsp_rdata<={scissor_y_q,scissor_x_q};
            REG_SCISSOR_WH:rsp_rdata<={scissor_h_q,scissor_w_q};
            REG_MODE:rsp_rdata<={16'd0,alpha_q,3'd0,scissor_enable_q,
                                    blend_q,depth_write_q,depth_op_q};
            REG_READ_XY:rsp_rdata<={host_y_q,host_x_q};
            REG_STATUS:rsp_rdata<={22'd0,shader_done_sticky_q,core_host_ready,core_tri_ready,
                                  core_clear_ready,pixel_cached_q,
                                  tri_done_sticky_q,clear_done_sticky_q,
                                  core_fault,core_busy,core_initialized};
            REG_PIXEL_RGB:begin
              if(pixel_cached_q) rsp_rdata<={8'd0,pixel_rgb_q};
              else rsp_error<=1;
            end
            REG_PIXEL_DEPTH:begin
              if(pixel_cached_q) rsp_rdata<={8'd0,pixel_depth_q};
              else rsp_error<=1;
            end
            REG_IDENT:rsp_rdata<=DEVICE_ID;
            REG_SHADER_SELECT:rsp_rdata<={25'd0,selected_reg_q,selected_insn_q};
            REG_SHADER_LENGTH:rsp_rdata<={27'd0,shader_len_q};
            REG_SHADER_VECTOR:begin
              if(!shader_cfg_ready)rsp_error<=1;
              else rsp_rdata<=shader_dbg_data;
            end
            REG_SHADED_RGB:rsp_rdata<={8'd0,last_shaded_rgb};
            REG_SHADER_RETIRED:rsp_rdata<={27'd0,shader_retired};
            default:rsp_error<=1;
          endcase
        end
      end
    end
  end

  initial begin
    if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 ||
       FRAME_WIDTH*FRAME_HEIGHT<2 || FRAME_WIDTH*FRAME_HEIGHT>65536)
      $fatal(1,"P147 bounded geometry required");
  end
endmodule
