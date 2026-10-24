`timescale 1ns/1ps
// P135: independent legacy /255 oracle against real optimized P70 RTL.
module a0_p135_div255_equivalence_tb;
  reg [23:0] source_rgb=0, destination_rgb=0;
  reg [7:0] source_alpha=0;
  reg blend_enable=0;
  wire [23:0] output_rgb;
  integer a,i;
  reg [23:0] expected_rgb;

  a0_p70_rgb_blend dut(
    .source_rgb(source_rgb),.destination_rgb(destination_rgb),
    .source_alpha(source_alpha),.blend_enable(blend_enable),
    .output_rgb(output_rgb)
  );

  function automatic [7:0] reference_channel(
      input reg [7:0] src,dst,alpha
  );
    reg [16:0] original_acc;
    begin
      original_acc = (src*alpha)+(dst*(8'd255-alpha))+17'd127;
      reference_channel = 8'(original_acc / 17'd255);
    end
  endfunction

  task automatic check_exact;
    begin
      expected_rgb = blend_enable ? {
        reference_channel(source_rgb[23:16],destination_rgb[23:16],source_alpha),
        reference_channel(source_rgb[15:8],destination_rgb[15:8],source_alpha),
        reference_channel(source_rgb[7:0],destination_rgb[7:0],source_alpha)
      } : source_rgb;
      if(output_rgb !== expected_rgb)
        $fatal(1,"P135 BLEND MISMATCH alpha=%0d src=%h dst=%h actual=%h expected=%h",
          source_alpha,source_rgb,destination_rgb,output_rgb,expected_rgb);
    end
  endtask

  initial begin
    for(a=0;a<256;a=a+1) begin
      source_alpha=8'(a);
      blend_enable=1;
      for(i=0;i<256;i=i+1) begin
        // Cover each possible alpha; every 8-bit source red sample,
        // complementary red destination and differing green/blue patterns.
        source_rgb={8'(i),8'(i*53+a),8'(i*3+7*a)};
        destination_rgb={8'(255-i),8'(i*17+5*a),8'(i*31+2*a)};
        #1;
        check_exact();
      end
      // Explicit extreme endpoints, all RGB channels.
      source_rgb=24'h000000;
      destination_rgb=24'hffffff;
      #1;
      check_exact();
      source_rgb=24'hffffff;
      destination_rgb=24'h000000;
      #1;
      check_exact();
      blend_enable=0;
      #1;
      check_exact();
    end
    $display("P135_RGB_DIV255_EQUIVALENCE_PASS 65536 patterns + 768 edge/bypass cases");
    $finish;
  end
  initial begin
    #200000;
    $fatal(1,"P135 exhaustive alpha simulation watchdog");
  end
endmodule
