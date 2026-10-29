`timescale 1ns/1ps
// P235 experimental: 32x24 *real writable BRAM* color tiles enlarged to
// fixed VGA/SVGA timings. This does NOT store full-resolution video frames.
// Host-side writes share the external pixel clock; a host CDC/PCIe/VRAM
// path and external pixel clock generator are intentionally not implemented.
//
// Two 768x24 BRAM banks; write only the non-front bank in monotonically
// increasing index order, commit exactly 768 words, publish on a complete
// frame wrap. No reads from a bank being written and no partial publication.
// P234 is the actual HS/VS/DE timing source. A local identical position
// counter predicts the next synchronous BRAM read address one clock early.
module a0_p235_scaled_bram_rgb #(
  parameter integer MODE=0  // 0: 640x480/25.175MHz; 1:800x600/40MHz
)(
  input  wire        pixel_clk,
  input  wire        raw_rst_n,
  input  wire        clock_locked,
  input  wire        load_valid,
  input  wire [9:0]  load_index,
  input  wire [23:0] load_rgb,
  output wire        load_ready,
  input  wire        commit_valid,
  output wire        commit_ready,
  output wire        load_fault,
  output wire [23:0] rgb888,
  output wire        video_de,
  output wire        video_hsync,
  output wire        video_vsync
);
  localparam integer HA = (MODE==0)?640:800;
  localparam integer HF = (MODE==0)?16:40;
  localparam integer HS = (MODE==0)?96:128;
  localparam integer HB = (MODE==0)?48:88;
  localparam integer VA = (MODE==0)?480:600;
  localparam integer VF = (MODE==0)?10:1;
  localparam integer VS = (MODE==0)?2:4;
  localparam integer VB = (MODE==0)?33:23;
  localparam integer HT = HA+HF+HS+HB;
  localparam integer VT = VA+VF+VS+VB;
  localparam integer SCALE = MODE==0?20:25;
  localparam integer TILE_W=32,TILE_H=24,TILE_WORDS=768;
  localparam logic HS_IDLE = MODE==0?1'b1:1'b0;
  localparam logic VS_IDLE = MODE==0?1'b1:1'b0;

  wire safe_rst_n=raw_rst_n && clock_locked;
  logic [1:0] released_q=0;
  logic [10:0] h_q=0;
  logic [9:0] v_q=0;
  logic front_valid_q=0,front_bank_q=0,stage_valid_q=0,fault_q=0;
  logic [9:0] load_count_q=0;
  logic [23:0] read0_q=0,read1_q=0;
  (* ram_style="block" *) logic [23:0] bank0 [0:TILE_WORDS-1];
  (* ram_style="block" *) logic [23:0] bank1 [0:TILE_WORDS-1];
  wire [23:0] ignored_pattern;
  wire timing_de,timing_hs,timing_vs;
  a0_p234_parallel_rgb_timing #(.MODE(MODE)) timing(
    .pixel_clk(pixel_clk),
    .raw_rst_n(raw_rst_n && !fault_q),
    .clock_locked(clock_locked),
    .rgb888(ignored_pattern),
    .video_de(timing_de),
    .video_hsync(timing_hs),
    .video_vsync(timing_vs)
  );
  // Timing producer and tiled-address predictor share the same clock and
  // exactly the same two-edge local reset/clock-lock release.
  wire enabled=safe_rst_n && released_q[1] && !fault_q;
  wire frame_wrap=enabled && h_q==11'(HT-1) && v_q==10'(VT-1);
  wire [10:0] next_h = !released_q[1] || h_q==11'(HT-1) ?
                       11'd0 : h_q+11'd1;
  wire [9:0] next_v = !released_q[1] ? 10'd0 :
                      h_q==11'(HT-1) ?
                      (v_q==10'(VT-1) ? 10'd0 : v_q+10'd1) : v_q;
  wire next_active=(next_h<HA && next_v<VA);
  wire [9:0] read_index=10'(((next_v/SCALE)*TILE_W)+(next_h/SCALE));
  wire read_bank= (frame_wrap && stage_valid_q) ? !front_bank_q : front_bank_q;
  wire read_en=enabled && next_active &&
               (front_valid_q || (frame_wrap && stage_valid_q));

  assign load_fault=fault_q;
  assign load_ready=enabled && !stage_valid_q &&
                    load_count_q<TILE_WORDS && !commit_valid;
  assign commit_ready=enabled && !stage_valid_q &&
                      load_count_q==TILE_WORDS && !load_valid;

  wire write_fire=load_valid && load_ready && load_index==load_count_q;
  wire write_bank=!front_bank_q;
  wire write0=write_fire && !write_bank;
  wire write1=write_fire && write_bank;
  wire read0=read_en && !read_bank;
  wire read1=read_en && read_bank;

  // The opposite bank is immutable while scanned. Read data is synchronous
  // and corresponds to *next* VGA/SVGA pixel coordinate after the edge.
  always_ff @(posedge pixel_clk) begin
    if(write0)bank0[load_count_q]<=load_rgb;
    if(write1)bank1[load_count_q]<=load_rgb;
    if(read0)read0_q<=bank0[read_index];
    if(read1)read1_q<=bank1[read_index];
  end

  always_ff @(posedge pixel_clk or negedge safe_rst_n) begin
    if(!safe_rst_n) begin
      released_q<=0;
      h_q<=0;v_q<=0;
      load_count_q<=0;
      front_valid_q<=0;front_bank_q<=0;stage_valid_q<=0;
      fault_q<=0;
    end else begin
      released_q<={released_q[0],1'b1};
      if(!released_q[1]) begin
        h_q<=0;v_q<=0;
      end else if(h_q==11'(HT-1)) begin
        h_q<=0;
        if(v_q==10'(VT-1))v_q<=0;
        else v_q<=v_q+10'd1;
      end else h_q<=h_q+11'd1;
      if(enabled) begin
        // Error is sticky until asynchronous board reset or lock loss.
        // An incomplete frame cannot be published.
        if(load_valid && commit_valid)fault_q<=1;
        if(load_valid && load_ready && load_index!=load_count_q)
          fault_q<=1;
        if(commit_valid && !commit_ready)fault_q<=1;
        if(write_fire)load_count_q<=load_count_q+10'd1;
        if(commit_valid && commit_ready)stage_valid_q<=1;
        // Front swap only at the wrap after the last VBlank pixel.
        if(frame_wrap && stage_valid_q) begin
          front_bank_q<=!front_bank_q;
          front_valid_q<=1;
          stage_valid_q<=0;
          load_count_q<=0;
        end
      end
    end
  end

  // The clock generator's outputs are *not* affected by load payloads.
  // Without a fully committed initial tile, DE remains dark. Both stale
  // BRAM data and unrelated video wires are masked on fault/lock loss.
  wire visible=safe_rst_n && !fault_q && front_valid_q && timing_de;
  assign rgb888=visible ? (front_bank_q ? read1_q : read0_q) : 24'd0;
  assign video_de=visible;
  assign video_hsync=safe_rst_n && !fault_q ? timing_hs : HS_IDLE;
  assign video_vsync=safe_rst_n && !fault_q ? timing_vs : VS_IDLE;

  initial begin
    if(MODE!=0 && MODE!=1)
      $fatal(1,"P235 unsupported compile-time video mode");
  end
endmodule
