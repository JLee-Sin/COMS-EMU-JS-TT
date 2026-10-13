// SPDX-License-Identifier: Apache-2.0
// Authors: Jayden Lee-Sin, Carlos Espinoza, Derrick Bassey, Mateo Nery
//
// protocol_mem.sv - the protocol memory: SRAM macro, port arbiter and
// address map (arch.md: Protocol Memory).
//
// Module: protocol_mem
//   One 512 x 16-bit single-port SRAM (RM_IHPSG13_1P_512x16_c2_bm_bist,
//   behavioural array under `ifdef SIM) holding four protocol slots of 112
//   words (TX program at +0x00, RX program at +0x38, 56 instructions each)
//   at 0x70*n, and eight 8-word templates at 0x1C0. Ten requesters share
//   the port through a round-robin arbiter:
//   requesters 0-7 are the sequencers (pinset p: 2p = TX, 2p+1 = RX),
//   8 is the Rewrite FSM, 9 is the Controller and the only writer. A
//   requester holds req and addr until its ack; read data is broadcast on
//   rdata and valid with the ack, two cycles after the grant. A sequencer
//   that stops before its ack removes its request and gets no ack.
//
//   The memory is not reset. The host loads the image after power-up.
//   Per-requester vectors are packed: bit r, or bits [9r+8:9r] for addr,
//   belong to requester r.

`default_nettype none

module protocol_mem (
    input  wire        clk,
    input  wire        rst_n,         // resets the arbiter only, not the array

    input  wire [9:0]  req,
    input  wire [89:0] addr,          // 10 x 9-bit word addresses
    input  wire        we,            // requester 9 only
    input  wire [15:0] wdata,         // requester 9 only
    output wire [15:0] rdata,         // broadcast
    output wire [9:0]  ack
);

	//State
	logic [3:0] 	rr_ptr; //Last requester granted
    	logic [9:0] 	pend;	//Bitmap for requester being granted
    	logic		s1_v;   //A request is in s1
	logic [3:0] 	s1_id;  //Who's request is in s1 
    	logic 		s1_we;  //High if write was requested
    	logic 		s2_v;	//A read has moved on to second stage pipeline
    	logic [3:0] 	s2_id;	//Who's request is in s2
    	logic [15:0] 	rdata_q;
	
	//Arbiter
    	logic [9:0] 	want;	//Bitmap for unserviced requesters
    	logic 		gnt_v;	//Grant occured this cycle
    	logic [3:0]	gnt_id;	//Requester being granted
    	logic 		gnt_we;	//Granted is a write
    	logic [9:0]	gnt_1h;	//Granted requester as a 1h signal
    	integer 	r;	

	//SRAM Port
	logic		sram_men;  //Memory enable
	logic		sram_wen;  //Write enable
	logic		sram_ren;  //Read enable
	logic [8:0]	sram_addr; //Address of granted request
	logic [15:0]    sram_din;  //Data in
	logic [15:0]	sram_dout; //Data out

	//Pipeline
	logic		live1; //Stage 1's owner has a req high
	logic		live2; //Stage 2's owner has a req high

	assign gnt_1h = gnt_v ? (10'd1 << gnt_id) : 10'd0;

	always @(posedge clk) begin
		if(!rst_n) begin
			rr_ptr	<= '0;
			pend	<= '0;
			s1_v	<= '0;
			s1_id	<= '0;
			s1_we	<= '0;
			s2_v	<= '0;
			s2_id	<= '0;
			rdata_q	<= '0;
		end else begin
			if(gnt_v) begin
				rr_ptr <= gnt_id;
			end

			pend <= (pend | gnt_1h) & ~(ack | ~req);

			s1_v  <= gnt_v;
			s1_id <= gnt_id;
			s1_we <= gnt_we;

			s2_v  <= live1 & ~s1_we;
			s2_id <= s1_id;

			if (live1 & ~s1_we) begin
				rdata_q <= sram_dout;
			end
		end
	end

	assign want  = req & ~pend;
	assign gnt_v = |want;

	always @(*) begin
		gnt_id = '0;

		for(r = 9; r >= 0; r = r-1) begin
			if(want[r]) begin
				gnt_id = r[3:0];
			end
		end

		for(r = 9; r >= 0; r = r-1) begin
			if(want[r] && (r > rr_ptr)) begin
				gnt_id = r[3:0];
			end
		end
	end

	assign gnt_we = gnt_v & (gnt_id == 4'd9) & we;

	assign sram_men  = gnt_v;
	assign sram_wen  = gnt_we;
	assign sram_ren  = gnt_v & ~gnt_we;
	assign sram_addr = addr[9*gnt_id +: 9];
	assign sram_din  = wdata;

	assign live1 = s1_v & req[s1_id];
	assign live2 = s2_v & req[s2_id];

	genvar g;
	generate
		for(g = 0; g < 10; g = g+1) begin : g_ack
			assign ack[g] = (live1 & s1_we & (s1_id == g)) | (live2 & (s2_id == g));
		end
	endgenerate

	assign rdata = rdata_q;

	//Storage for simulation
	`ifdef SIM
		reg [15:0] mem [0:511];

		always @(posedge clk) begin
			if(sram_men & sram_wen) begin
				mem[sram_addr] <= sram_din;
			end else if(sram_men & sram_ren) begin
				sram_dout <= mem[sram_addr];
			end
		end
	`else

	RM_IHPSG13_1P_512x16_c2_bm_bist u_sram (
		.A_CLK       (clk),
		.A_MEN       (sram_men),
		.A_WEN       (sram_wen),
		.A_REN       (sram_ren),
		.A_ADDR      (sram_addr),
		.A_DIN       (sram_din),
		.A_DLY       (1'b1),
		.A_DOUT      (sram_dout),
		.A_BM        (16'hFFFF),
		.A_BIST_CLK  (1'b0),
		.A_BIST_EN   (1'b0),
		.A_BIST_MEN  (1'b0),
		.A_BIST_WEN  (1'b0),
		.A_BIST_REN  (1'b0),
		.A_BIST_ADDR (9'd0),
		.A_BIST_DIN  (16'd0),
		.A_BIST_BM   (16'd0)
	);
`endif

endmodule
