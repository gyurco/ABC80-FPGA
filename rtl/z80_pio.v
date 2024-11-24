//============================================================================
// 
//  Z80 PIO
//  Copyright (C) 2024 Gyorgy Szombathelyi
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

// TODO: add IEI, IEO pins, bidirectional mode

module z80_pio (
	input         reset,
	input         clock,
	input         clock_ena,

	input   [7:0] din,
	output  [7:0] dout,
	input   [7:0] cpu_din, // mirror the input to the cpu, for RETI detection
	output        oe,

	input         ce_n,
	input         m1_n,
	input         iorq_n,
	input         rd_n,
	output        int_n,
	input         sel_ab,
	input         sel_cd,

	input   [7:0] pioa_in,
	output  [7:0] pioa_out,
	output        ardy,
	input         astrb_n,

	input   [7:0] piob_in,
	output  [7:0] piob_out,
	output        brdy,
	input         bstrb_n
);

wire        rd = !rd_n & !ce_n & !iorq_n & m1_n;
wire        wr =  rd_n & !ce_n & !iorq_n & m1_n;
wire        cpu_intack = !iorq_n & !m1_n;

assign      oe = (!rd_n & !ce_n & !iorq_n) | cpu_intack;

reg   [1:0] pio_int_ack_phase = 0;
always @(posedge clock) begin
	if (reset)
		pio_int_ack_phase <= 0;
	else if (clock_ena & !rd_n & !m1_n) begin
		// decode ED4D (reti)
		case (pio_int_ack_phase)
			2'b00: if (cpu_din == 8'hED) pio_int_ack_phase <= 2'b01;
			2'b01: if (cpu_din == 8'h4D) pio_int_ack_phase <= 2'b11; else if (cpu_din != 8'hED) pio_int_ack_phase <= 0;
			2'b11: if (cpu_din == 8'hED) pio_int_ack_phase <= 2'b01; else if (cpu_din != 8'h4D) pio_int_ack_phase <= 0;
			default: pio_int_ack_phase <= 0;
		endcase
	end
end

wire        pio_intack = pio_int_ack_phase == 2'b11;
wire  [1:0] port_irq;
reg   [1:0] in_service;
reg   [1:0] irq;

assign      int_n = ~|irq;

always @(posedge clock) begin
	reg cpu_intack_d, pio_intack_d;
	if (reset) begin
		in_service <= 0;
		irq <= 0;
	end else if (clock_ena) begin
		cpu_intack_d <= cpu_intack;
		pio_intack_d <= pio_intack;
		if (~cpu_intack_d & cpu_intack) begin
			if (irq[0]) begin in_service[0] <= 1; irq[0] <= 0; end
			else if (irq[1]) begin in_service[1] <= 1; irq[1] <= 0; end
		end
		if (~pio_intack_d & pio_intack) begin
			if (in_service[0]) in_service[0] <= 0;
			else if (in_service[1]) in_service[1] <= 0;
		end
		//if (m1_n) begin
			if (port_irq[0] & ~in_service[0]) irq[0] <= 1;
			else if (port_irq[1] & ~|in_service[1:0]) irq[1] <= 1;
		//end
	end
end

assign dout = cpu_intack ? (in_service[0] ? porta_vec : portb_vec) :
              sel_ab ? portb_dout : porta_dout;

wire  [7:0] porta_dout, porta_vec;

z80_pio_port porta (
	.reset(reset),
	.clock(clock),
	.clock_ena(clock_ena),
	.wr(wr & !sel_ab),
	.rd(rd & !sel_ab),
	.sel_cd(sel_cd),
	.din(din),
	.dout(porta_dout),
	.vec_out(porta_vec),
	.irq(port_irq[0]),

	.pio_din(pioa_in),
	.pio_dout(pioa_out),
	.rdy(ardy),
	.strb_n(astrb_n)
);

wire  [7:0] portb_dout, portb_vec;

z80_pio_port portb (
	.reset(reset),
	.clock(clock),
	.clock_ena(clock_ena),
	.wr(wr & sel_ab),
	.rd(rd & sel_ab),
	.sel_cd(sel_cd),
	.din(din),
	.dout(portb_dout),
	.vec_out(portb_vec),
	.irq(port_irq[1]),

	.pio_din(piob_in),
	.pio_dout(piob_out),
	.rdy(brdy),
	.strb_n(bstrb_n)
);

endmodule

module z80_pio_port (
	input         reset,
	input         clock,
	input         clock_ena,
	input         wr,
	input         rd,
	input         sel_cd,
	input   [7:0] din,
	output  [7:0] dout,
	output  [7:0] vec_out,
	output reg    irq,
	
	input   [7:0] pio_din,
	output  [7:0] pio_dout,
	output reg    rdy,
	input         strb_n
);

localparam MODE_OUTPUT=2'b00;
localparam MODE_INPUT =2'b01;
localparam MODE_BIDIR =2'b10;
localparam MODE_CTRL  =2'b11;

reg   [7:0] vec;
reg   [7:0] int_mask;
reg         int_en, int_op, int_pol, need_mask_word;
reg   [1:0] mode;
reg   [7:0] ctrl;
reg         need_ctrl_word;

reg   [7:0] ireg, oreg;

assign vec_out = vec;
assign pio_dout = oreg;
assign dout = mode == MODE_CTRL ? ((ctrl & ireg) | (~ctrl & oreg)) : 
                      MODE_OUTPUT ? oreg :
                                    ireg;
reg         int_match;
always @(*) begin
	if (int_op) begin
		// AND
		int_match = &((dout ^ {8{~int_pol}}) | int_mask);
	end else begin
		// OR
		int_match = |((dout ^ {8{~int_pol}}) & ~int_mask);
	end
end

always @(posedge clock) begin
	reg wr_d, strb_n_d, int_match_d;

	if (reset) begin
		mode <= 0;
		int_en <= 0;
		int_op <= 0;
		int_pol <= 0;
		ctrl <= 0;		
		need_mask_word <= 0;
		need_ctrl_word <= 0;
		rdy <= 0;
		irq <= 0;
	end else if (clock_ena) begin
		wr_d <= wr & sel_cd;
		strb_n_d <= strb_n;
		int_match_d <= int_match;

		if (~wr_d & wr & sel_cd) begin
			if (need_ctrl_word) begin
				ctrl <= din;
				need_ctrl_word <= 0;
			end else if (need_mask_word) begin
				int_mask <= din;
				need_mask_word <= 0;
			end else begin
				if (!din[0]) vec <= din;
				if (din[3:0] == 4'b0011) int_en <= din[7];
				if (din[3:0] == 4'b0111) {int_en, int_op, int_pol, need_mask_word} <= din[7:4];
				if (din[3:0] == 4'b1111) begin
					mode <= din[7:6];			
					case (din[7:6])
						MODE_OUTPUT: rdy <= 0;
						MODE_INPUT : rdy <= 1;
						MODE_CTRL  : {need_ctrl_word, rdy} <= 2'b10;
						default: ;
					endcase
				end
			end
		end

		irq <= 0;
		if (~wr_d & wr & !sel_cd) oreg <= din;
		case (mode)
			MODE_OUTPUT: begin
				if (wr_d & ~(wr & !sel_cd)) rdy <= 1;
				if (rdy & strb_n & ~strb_n_d) {irq, rdy} <= {int_en, 1'b0};
			end
			MODE_INPUT: begin
				if (~strb_n & strb_n_d) begin
					ireg <= pio_din;
					{irq, rdy} <= {int_en, 1'b0};
				end
				if (rd & !sel_cd) rdy <= 1;
			end
			MODE_BIDIR: begin
				// TODO
			end
			MODE_CTRL: begin
				if (~rd & ~wr) ireg <= pio_din;
				if (~int_match_d & int_match) irq <= int_en;
			end
			default: ;
		endcase
	end
end

endmodule
