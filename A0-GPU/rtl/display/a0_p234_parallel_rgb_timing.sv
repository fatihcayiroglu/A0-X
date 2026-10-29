`timescale 1ns/1ps
// P234: parallel RGB888 timing / color-bar test source, NOT the P233 EBR
// framebuffer. Requires a genuine external pixel clock at the selected
// mode rate. No PLL, serializer, EDID, hotplug, pins or video PHY.
module a0_p234_parallel_rgb_timing #(
    parameter integer MODE=0 // 0=640x480 nominal 25.175 MHz; 1=800x600 at 40MHz
)(
    input  wire pixel_clk,
    input  wire raw_rst_n,
    input  wire clock_locked,
    output wire [23:0] rgb888,
    output wire video_de,
    output wire video_hsync,
    output wire video_vsync
);
    localparam integer H_ACTIVE = MODE==0 ? 640 : 800;
    localparam integer H_FRONT  = MODE==0 ? 16  : 40;
    localparam integer H_SYNC   = MODE==0 ? 96  : 128;
    localparam integer H_BACK   = MODE==0 ? 48  : 88;
    localparam integer V_ACTIVE = MODE==0 ? 480 : 600;
    localparam integer V_FRONT  = MODE==0 ? 10  : 1;
    localparam integer V_SYNC   = MODE==0 ? 2   : 4;
    localparam integer V_BACK   = MODE==0 ? 33  : 23;
    localparam integer H_TOTAL=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
    localparam integer V_TOTAL=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;
    localparam integer BAR_W=H_ACTIVE/8;
    localparam logic HS_IDLE=MODE==0 ? 1'b1 : 1'b0;
    localparam logic VS_IDLE=MODE==0 ? 1'b1 : 1'b0;

    logic [10:0] h_q=0;
    logic [9:0] v_q=0;
    // Hold all pins fail-closed when either raw reset or external pixel
    // clock lock is low. Deassertion is locally qualified for two edges.
    logic [1:0] released_q=0;
    wire active=raw_rst_n && clock_locked && released_q[1];
    wire in_view=(h_q<H_ACTIVE && v_q<V_ACTIVE);
    wire h_pulse=(h_q>=H_ACTIVE+H_FRONT &&
                  h_q<H_ACTIVE+H_FRONT+H_SYNC);
    wire v_pulse=(v_q>=V_ACTIVE+V_FRONT &&
                  v_q<V_ACTIVE+V_FRONT+V_SYNC);
    function automatic [23:0] bar(input logic [10:0] x);
        begin
            if (x<BAR_W)         bar=24'hffffff; // white
            else if (x<2*BAR_W)  bar=24'hffff00; // yellow
            else if (x<3*BAR_W)  bar=24'h00ffff; // cyan
            else if (x<4*BAR_W)  bar=24'h00ff00; // green
            else if (x<5*BAR_W)  bar=24'hff00ff; // magenta
            else if (x<6*BAR_W)  bar=24'hff0000; // red
            else if (x<7*BAR_W)  bar=24'h0000ff; // blue
            else                 bar=24'h000000; // black
        end
    endfunction
    assign video_de=active && in_view;
    assign rgb888=video_de ? bar(h_q) : 24'd0;
    assign video_hsync=active ? (MODE==0 ? !h_pulse : h_pulse) : HS_IDLE;
    assign video_vsync=active ? (MODE==0 ? !v_pulse : v_pulse) : VS_IDLE;

    always_ff @(posedge pixel_clk or negedge raw_rst_n or negedge clock_locked) begin
        if(!raw_rst_n || !clock_locked) begin
            released_q<=0;
            h_q<=0; v_q<=0;
        end else begin
            released_q<={released_q[0],1'b1};
            if(!released_q[1]) begin
                h_q<=0;v_q<=0;
            end else if(h_q==11'(H_TOTAL-1)) begin
                h_q<=0;
                if(v_q==10'(V_TOTAL-1)) v_q<=0;
                else v_q<=v_q+10'd1;
            end else h_q<=h_q+11'd1;
        end
    end
    initial begin
        if (MODE!=0 && MODE!=1) $fatal(1,"P234 unsupported fixed video timing mode");
    end
endmodule
