`timescale 1ns/1ps
module a0_p157_texture_alu_tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,write_valid=0,req_valid=0,rsp_ready=1;
reg [3:0] write_x=0,write_y=0;
reg [31:0] write_rgba=0,operand_b=0;
reg signed [15:0] sample_x=0,sample_y=0;
reg sample_repeat=0;
reg [7:0] req_id=0,alpha=0;
reg [2:0] opcode=0;
reg [3:0] lane_mask=0;
wire write_ready,req_ready,rsp_valid,rsp_present;
wire [7:0] rsp_id;
wire [31:0] rsp_rgba;
reg [31:0] golden[0:255];
reg valid_bit[0:255];
integer comparisons=0,stall_checks=0,missing=0;
a0_p157_texture_alu_link dut(
.clk(clk),.rst_n(rst_n),.write_valid(write_valid),
.write_ready(write_ready),.write_x(write_x),.write_y(write_y),
.write_rgba(write_rgba),.req_valid(req_valid),.req_ready(req_ready),
.sample_x(sample_x),.sample_y(sample_y),.sample_repeat(sample_repeat),
.req_id(req_id),.opcode(opcode),.operand_b(operand_b),
.alpha(alpha),.lane_mask(lane_mask),.rsp_valid(rsp_valid),
.rsp_ready(rsp_ready),.rsp_id(rsp_id),.rsp_rgba(rsp_rgba),
.rsp_present(rsp_present));
function automatic [31:0] oracle(input reg [2:0] op,
 input reg [31:0] a,b,input reg [7:0] al,input reg [3:0] mask);
integer lane,x,y,z;reg[31:0] out;
begin
out=0;
for(lane=0;lane<4;lane=lane+1)begin
x=(a>>(lane*8))&255;y=(b>>(lane*8))&255;z=x;
if(mask[lane])case(op)
0:z=x;1:z=y;2:z=((x+y)>255)?255:(x+y);
3:z=(x>=y)?x-y:0;4:z=(x*y+127)/255;
5:z=(x<y)?x:y;6:z=(x>y)?x:y;
7:z=(x*(255-int'(al))+y*int'(al)+127)/255;
endcase
out[lane*8+:8]=8'(z);
end
oracle=out;
end
endfunction
task automatic store(input integer xx,yy,input[31:0] data);
begin
@(negedge clk);write_x=4'(xx);write_y=4'(yy);
write_rgba=data;write_valid=1;
if(!write_ready)$fatal(1,"P157 texture write blocked");
@(negedge clk);write_valid=0;
golden[yy*16+xx]=data;valid_bit[yy*16+xx]=1;
end
endtask
task automatic sample(input integer sx,sy,rep,k,stall);
integer xx,yy,idx,n;
reg present;
reg[31:0] result,hold_data;
begin
@(negedge clk);
sample_x=16'(sx);sample_y=16'(sy);sample_repeat=1'(rep);
opcode=3'(k%8);lane_mask=4'((k*7)%16);
alpha=8'(k*13);operand_b=32'(32'h1539f0c7 ^ (k*32'h1234f));
req_id=8'(k);req_valid=1;
if(!req_ready)$fatal(1,"P157 sampler not ready");
@(negedge clk);req_valid=0;
xx=rep?(sx&15):((sx<0)?0:((sx>15)?15:sx));
yy=rep?(sy&15):((sy<0)?0:((sy>15)?15:sy));
idx=yy*16+xx;present=valid_bit[idx];
result=oracle(opcode,present?golden[idx]:0,operand_b,alpha,lane_mask);
n=0;
while(!rsp_valid)begin
@(negedge clk);n=n+1;
if(n>40)$fatal(1,"P157 texture/ALU response timeout");
end
if(rsp_id!==8'(k) || rsp_rgba!==result || rsp_present!==present)
$fatal(1,"P157 RGB mismatch request=%0d expected=%h got=%h",k,result,rsp_rgba);
if(!present)missing=missing+1;
if(stall)begin
rsp_ready=0;hold_data=rsp_rgba;
repeat(5)begin
@(negedge clk);
if(!rsp_valid || rsp_rgba!==hold_data || req_ready)
$fatal(1,"P157 stalled response changed");
stall_checks=stall_checks+1;
end
end
rsp_ready=1;
@(negedge clk);
comparisons=comparisons+1;
end
endtask
initial begin
for(integer i=0;i<256;i=i+1)begin golden[i]=0;valid_bit[i]=0;end
repeat(4)@(negedge clk);rst_n=1;
store(0,0,32'h10203040);
store(15,15,32'hff708010);
store(7,8,32'h7f01ffab);
for(integer i=0;i<192;i=i+1)
sample((i*17)%57-21,(i*29)%63-25,i%2,i,i%11==0);
rst_n=0;repeat(4)@(negedge clk);rst_n=1;
for(integer i=0;i<256;i=i+1)valid_bit[i]=0;
sample(0,0,0,240,1);
if(comparisons!=193 || missing<30 || stall_checks<90)
$fatal(1,"P157 insufficient test coverage");
$display("P157_TEXTURE_SIMD_ORACLE_PASS checked=%0d missing=%0d stall_cycles=%0d modes=8",comparisons,missing,stall_checks);
$finish;
end
initial begin #3000000;$fatal(1,"P157 timeout");end
endmodule
