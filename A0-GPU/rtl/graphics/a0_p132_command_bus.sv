`timescale 1ns/1ps
// P132 single-clock 32-bit command/status adapter for the P102 research datapath.
// No CDC, PCIe, VRAM, physical-board or external I/O timing certification.
module a0_p132_command_bus #(
    parameter integer FRAME_WIDTH = 4,
    parameter integer FRAME_HEIGHT = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [7:0]  req_addr,
    input  wire [31:0] req_wdata,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_rdata,
    output reg         rsp_error
);
    reg [23:0] clear_color_reg, clear_depth_reg, tri_color_reg, tri_depth_reg;
    reg [31:0] v0_reg, v1_reg, v2_reg, mode_reg;
    reg [31:0] scissor_xy_reg, scissor_wh_reg, read_xy_reg;
    reg clear_done_sticky, tri_done_sticky, error_sticky;
    wire clear_ready, tri_ready, clear_done, tri_done, initialized, busy;
    wire read_valid, pixel_wrote;
    wire [23:0] read_color, read_depth;

    assign req_ready = rst_n && !rsp_valid;
    wire transfer = req_valid && req_ready;
    wire control_write = transfer && req_write && req_addr == 8'h08;
    wire control_reserved = (req_wdata[31:3] != 0 || req_wdata[1:0] == 2'b11);
    wire clear_start = control_write && !control_reserved && req_wdata[0] && clear_ready;
    wire tri_start = control_write && !control_reserved && req_wdata[1] && tri_ready;

    a0_triangle_scissor_depth_blend_p102 #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT)
    ) engine (
        .clk(clk), .rst_n(rst_n),
        .clear_valid(clear_start), .clear_ready(clear_ready),
        .clear_color(clear_color_reg), .clear_depth(clear_depth_reg),
        .clear_done(clear_done),
        .tri_valid(tri_start), .tri_ready(tri_ready),
        .x0(v0_reg[15:0]), .y0(v0_reg[31:16]),
        .x1(v1_reg[15:0]), .y1(v1_reg[31:16]),
        .x2(v2_reg[15:0]), .y2(v2_reg[31:16]),
        .tri_color(tri_color_reg), .tri_depth(tri_depth_reg),
        .depth_compare_op(mode_reg[1:0]),
        .depth_write(mode_reg[2]), .blend_enable(mode_reg[3]),
        .source_alpha(mode_reg[15:8]),
        .scissor_enable(mode_reg[16]),
        .scissor_x(scissor_xy_reg[15:0]), .scissor_y(scissor_xy_reg[31:16]),
        .scissor_w(scissor_wh_reg[15:0]), .scissor_h(scissor_wh_reg[31:16]),
        .tri_done(tri_done), .initialized(initialized), .busy(busy),
        .read_x(read_xy_reg[15:0]), .read_y(read_xy_reg[31:16]),
        .read_valid(read_valid), .read_color(read_color), .read_depth(read_depth),
        .pixel_wrote(pixel_wrote)
    );

    reg bad_request;
    reg [31:0] readback;
    always @* begin
        bad_request = 1'b0;
        readback = 32'b0;
        if (req_addr[1:0] != 2'b00) begin
            bad_request = 1'b1;
        end else if (req_write) begin
            case (req_addr)
                8'h08: if (control_reserved ||
                            (req_wdata[0] && !clear_ready) ||
                            (req_wdata[1] && !tri_ready))
                           bad_request = 1'b1;
                8'h0c,8'h10,8'h14,8'h18,8'h1c,
                8'h20,8'h24,8'h2c,8'h30,8'h34: ;
                8'h28: if ((req_wdata & 32'hfffe00f0) != 0)
                           bad_request = 1'b1;
                default: bad_request = 1'b1;
            endcase
        end else begin
            case (req_addr)
                8'h00: readback = 32'h41305832;
                8'h04: readback = {27'b0,error_sticky,tri_done_sticky,
                                   clear_done_sticky,busy,initialized};
                8'h0c: readback = {8'b0,clear_color_reg};
                8'h10: readback = {8'b0,clear_depth_reg};
                8'h14: readback = v0_reg;
                8'h18: readback = v1_reg;
                8'h1c: readback = v2_reg;
                8'h20: readback = {8'b0,tri_color_reg};
                8'h24: readback = {8'b0,tri_depth_reg};
                8'h28: readback = mode_reg;
                8'h2c: readback = scissor_xy_reg;
                8'h30: readback = scissor_wh_reg;
                8'h34: readback = read_xy_reg;
                8'h38: readback = {read_valid,7'b0,
                                   (read_valid ? read_color : 24'b0)};
                8'h3c: readback = {read_valid,7'b0,
                                   (read_valid ? read_depth : 24'b0)};
                default: bad_request = 1'b1;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            clear_color_reg <= 0;
            clear_depth_reg <= 0;
            tri_color_reg <= 0;
            tri_depth_reg <= 0;
            v0_reg <= 0;
            v1_reg <= 0;
            v2_reg <= 0;
            mode_reg <= 0;
            scissor_xy_reg <= 0;
            scissor_wh_reg <= 0;
            read_xy_reg <= 0;
            clear_done_sticky <= 0;
            tri_done_sticky <= 0;
            error_sticky <= 0;
            rsp_valid <= 0;
            rsp_rdata <= 0;
            rsp_error <= 0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;
            if (transfer) begin
                rsp_valid <= 1'b1;
                rsp_rdata <= bad_request ? 32'b0 : readback;
                rsp_error <= bad_request;
                if (bad_request)
                    error_sticky <= 1'b1;
                if (!bad_request && req_write) begin
                    case (req_addr)
                        8'h08: if (req_wdata[2]) begin
                            clear_done_sticky <= 1'b0;
                            tri_done_sticky <= 1'b0;
                            error_sticky <= 1'b0;
                        end
                        8'h0c: clear_color_reg <= req_wdata[23:0];
                        8'h10: clear_depth_reg <= req_wdata[23:0];
                        8'h14: v0_reg <= req_wdata;
                        8'h18: v1_reg <= req_wdata;
                        8'h1c: v2_reg <= req_wdata;
                        8'h20: tri_color_reg <= req_wdata[23:0];
                        8'h24: tri_depth_reg <= req_wdata[23:0];
                        8'h28: mode_reg <= req_wdata;
                        8'h2c: scissor_xy_reg <= req_wdata;
                        8'h30: scissor_wh_reg <= req_wdata;
                        8'h34: read_xy_reg <= req_wdata;
                        default: ;
                    endcase
                end
            end
            // Hardware completion wins over simultaneous software acknowledge.
            if (clear_done) clear_done_sticky <= 1'b1;
            if (tri_done) tri_done_sticky <= 1'b1;
        end
    end
endmodule
