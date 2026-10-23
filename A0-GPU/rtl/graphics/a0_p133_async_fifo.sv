`timescale 1ns/1ps
// P133 dual-clock FIFO candidate.
// Gray pointers cross only through two sequential synchronizers.
// Reset must be asserted globally to both domains (separate resets unsupported).
module a0_p133_async_fifo #(
  parameter integer WIDTH=41,
  parameter integer ADDR_BITS=2,
  parameter integer DEPTH=(1 << ADDR_BITS)
)(
  input wire wclk, wrst_n,
  input wire wvalid,
  output wire wready,
  input wire [WIDTH-1:0] wdata,
  input wire rclk, rrst_n,
  output wire rvalid,
  input wire rready,
  output wire [WIDTH-1:0] rdata
);
  localparam integer PTR_BITS = ADDR_BITS + 1;
  reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg [PTR_BITS-1:0] wbin, wgray, rbin, rgray;
  (* async_reg = "true" *) reg [PTR_BITS-1:0] rgray_wmeta, rgray_wsync;
  (* async_reg = "true" *) reg [PTR_BITS-1:0] wgray_rmeta, wgray_rsync;
  reg wfull, rempty;

  assign wready = wrst_n && !wfull;
  assign rvalid = rrst_n && !rempty;
  assign rdata = mem[rbin[ADDR_BITS-1:0]];
  wire wpush = wvalid && wready;
  wire rpop = rvalid && rready;
  wire [PTR_BITS-1:0] wbin_next = wbin + {{(PTR_BITS-1){1'b0}},wpush};
  wire [PTR_BITS-1:0] rbin_next = rbin + {{(PTR_BITS-1){1'b0}},rpop};
  wire [PTR_BITS-1:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
  wire [PTR_BITS-1:0] rgray_next = (rbin_next >> 1) ^ rbin_next;
  wire wfull_next =
      (wgray_next == {~rgray_wsync[PTR_BITS-1:PTR_BITS-2],
                       rgray_wsync[PTR_BITS-3:0]});
  wire rempty_next = (rgray_next == wgray_rsync);

  always @(posedge wclk) begin
    if (wpush)
      mem[wbin[ADDR_BITS-1:0]] <= wdata;
  end
  always @(posedge wclk or negedge wrst_n) begin
    if (!wrst_n) begin
      wbin <= 0; wgray <= 0; wfull <= 0;
      rgray_wmeta <= 0; rgray_wsync <= 0;
    end else begin
      rgray_wmeta <= rgray;
      rgray_wsync <= rgray_wmeta;
      wbin <= wbin_next;
      wgray <= wgray_next;
      wfull <= wfull_next;
    end
  end
  always @(posedge rclk or negedge rrst_n) begin
    if (!rrst_n) begin
      rbin <= 0; rgray <= 0; rempty <= 1;
      wgray_rmeta <= 0; wgray_rsync <= 0;
    end else begin
      wgray_rmeta <= wgray;
      wgray_rsync <= wgray_rmeta;
      rbin <= rbin_next;
      rgray <= rgray_next;
      rempty <= rempty_next;
    end
  end

  initial begin
    if (ADDR_BITS < 2 || DEPTH != (1 << ADDR_BITS) || WIDTH < 1)
      $fatal(1,"P133 FIFO requires power-of-two depth >=4 and positive width");
  end
endmodule
