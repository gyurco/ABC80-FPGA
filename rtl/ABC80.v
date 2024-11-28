//============================================================================
// 
//  Luxor ABC80 top level
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

module ABC80 (
	input         CLK12,
	input         RESET,
	output        HSYNC,
	output        VSYNC,
	output        HBLANK,
	output        VBLANK,
	output        VIDEO,
	output reg [13:0] AUDIO,
	input         CASS_IN,
	output        CASS_OUT,
	output        CASS_CTRL,
	input         XMEM,

	input         KEY_STROBE,
	input         KEY_PRESSED,
	input         KEY_EXTENDED,
	input   [7:0] KEY_CODE, // PS2 keycode
	output        UPCASE,

	// DMA bus
	input         DL,
	input         DL_ALT,
	input         DL_CLK,
	input  [15:0] DL_ADDR,
	input   [7:0] DL_DATA,
	input         DL_WE,
	input         DL_ROM
);

// clock enables
reg cen6, cen3;
reg [1:0] cnt;
always @(posedge CLK12) begin
	cnt <= cnt + 1'd1;
	cen6 <= cnt[0];
	cen3 <= cnt == 0;
end

// video circuit
reg   [3:0] cnt_h5;
reg   [5:0] hcnt; // k6
reg   [8:0] vcnt; // k3-k4
reg   [3:0] blink_cnt;
wire        blink_on = blink_cnt[3];

reg   [3:0] rom_k5[256];
reg   [3:0] rom_j3[256];
reg   [3:0] rom_e7[256];
reg   [3:0] rom_k1[512];
reg   [3:0] rom_k2[512];
reg   [3:0] rom_k5_q, rom_k1_q, rom_k2_q;
reg   [3:0] rom_j3_q;
reg   [7:0] charrom[1280];
reg   [7:0] charrom_q;

always @(posedge DL_CLK) begin
	if (DL_WE & DL_ROM & DL_ADDR[15:14] == 1) begin
		if      (DL_ADDR[13: 0] < 2560) begin if (DL_ADDR[13:0] < 1280) charrom[DL_ADDR[13:0]] <= DL_DATA; end
		else if (DL_ADDR[13: 0] < 3072) rom_k1[DL_ADDR[8:0]] <= DL_DATA[3:0];
		else if (DL_ADDR[13: 0] < 3584) rom_k2[DL_ADDR[8:0]] <= DL_DATA[3:0];
		else if (DL_ADDR[13: 0] < 3840) rom_k5[DL_ADDR[7:0]] <= DL_DATA[3:0];
		else if (DL_ADDR[13: 0] < 4096) rom_j3[DL_ADDR[7:0]] <= DL_DATA[3:0];
		else if (DL_ADDR[13: 0] < 4352) rom_e7[DL_ADDR[7:0]] <= DL_DATA[3:0];
	end
end

always @(posedge CLK12) begin
	rom_k5_q <= rom_k5[{2'b00, hcnt[5:0]}];
	rom_k1_q <= rom_k1[vcnt];
	rom_k2_q <= rom_k2[vcnt];
end

wire  [3:0] row_addr = rom_k1_q;

wire        cnt_clr = ~rom_k2_q[3];
wire        vram_vcnt_inc = rom_k2_q[2];
wire        vsync = rom_k2_q[0];
wire        vsync_d = rom_k2_q[1];

wire        hsync = rom_k5_q[0];
wire        hsync_d = rom_k5_q[1];
wire        vram_hcnt_clr = rom_k5_q[2];
wire        vram_hcnt_inc = rom_k5_q[3];

wire        chr_en = cnt_h5 == 15;

assign      HSYNC = hsync;
assign      VSYNC = vsync;

assign      HBLANK = hcnt <= 6'h10 || hcnt >= 6'h39;
assign      VBLANK = vcnt <= 9'h2f || vcnt >= 9'h120;

always @(posedge CLK12) begin
	reg cnt_clr_d;

	if (cen6) begin
		cnt_h5 <= cnt_h5 + 1'd1;
		if (chr_en) begin
			cnt_h5 <= 10;
			hcnt <= hcnt + 1'd1;
			if (hcnt[5:0] == 6'b111111) vcnt <= vcnt + 1'd1;
		end
		if (cnt_clr) begin
			hcnt <= 0;
			vcnt <= 0;
		end
	end
	
	cnt_clr_d <= cnt_clr;
	if (~cnt_clr_d & cnt_clr) blink_cnt <= blink_cnt + 1'd1;
end

reg   [7:0] vram[1024];
reg   [7:0] vram_dout, vram_dout_d;
reg   [5:0] vram_hcnt; // f4
reg   [4:0] vram_vcnt; // f2
wire  [3:0] vram_add = vram_hcnt[5:3] + {vram_vcnt[4], vram_vcnt[3], vram_vcnt[4], vram_vcnt[3]}; // f3
wire  [9:0] vram_addr = {vram_vcnt[2:0], vram_add, vram_hcnt[2:0]};

// VRAM test pattern
initial begin
	integer i,j;
	for (j=0;j<=80;j=j+40) begin
		for (i=0;i<40;i=i+1) begin
			vram[j+i] = 8'd65+i;
		end
	end
	vram[128] = 8'd23;
	vram[129] = 8'd35;
	vram[130] = 8'd60;
	vram[131] = 8'd54;
end

always @(posedge CLK12) begin : f2f4
	if (cen6) begin
		if (chr_en) begin
			if (vram_hcnt_inc) vram_hcnt <= vram_hcnt + 1'd1;
			if (vram_hcnt_clr) vram_hcnt <= 0;
			if (hcnt[5:0] == 6'b111111 && vram_vcnt_inc) vram_vcnt <= vram_vcnt + 1'd1;
		end
		if (cnt_clr) vram_vcnt <= 0;
	end
end

wire [10:0] charrom_addr = vram_dout_d[6:0] * 4'd10 + row_addr;
wire        sync_d = hsync_d & vsync_d;

always @(posedge CLK12) begin
	vram_dout <= vram[vram_addr];
	if (cen6 & chr_en) vram_dout_d <= vram_dout; // h1
	charrom_q <= charrom[charrom_addr];
	rom_j3_q <= rom_j3[{sync_d, vram_dout_d[6:0]}];
end

reg  [6:0] char_shift;
always @(posedge CLK12) begin : j1
	if (cen6) begin
		if (chr_en)
			char_shift <= {charrom_q[6:2], 2'd0};
		else
			char_shift <= {char_shift[5:0], 1'b0};
	end
end

// j2 - ls445 bcd decoder
wire        row0 = row_addr <= 2;
wire        row1 = row_addr >= 3 && row_addr <= 6;
wire        row2 = row_addr >= 7 && row_addr <= 9;

wire        pix1 = (row0 & vram_dout_d[0]) | (row1 & vram_dout_d[2]) | (row2 & vram_dout_d[4]);
wire        pix2 = (row0 & vram_dout_d[1]) | (row1 & vram_dout_d[3]) | (row2 & vram_dout_d[6]);

reg  [6:0] grph_shift;
always @(posedge CLK12) begin : j6
	if (cen6) begin
		if (chr_en)
			grph_shift <= {{3{pix1}}, {3{pix2}}, 1'b0};
		else
			grph_shift <= {grph_shift[5:0], 1'b0};
	end
end

wire        vid_en   = rom_j3_q[0];
wire        grph_on  = rom_j3_q[1];
wire        grph_off = rom_j3_q[2];
wire        grph_en  = rom_j3_q[3];

reg         grph, mode_grph, mode_blink, mode_vid_en;

always @(posedge CLK12) begin : j4j5k7
	if (cen6 & chr_en) begin
		if (grph_on & grph_off) grph <= ~grph;
		else if (grph_on) grph <= 1;
		else if (grph_off) grph <= 0;
	end
	if (vram_hcnt_clr) grph <= 0;

	if (cen6 & chr_en) begin
		mode_blink <= vram_dout_d[7];
		mode_vid_en <= vid_en;
		mode_grph <= grph & grph_en;
	end
end

wire        blink = blink_on & mode_blink; // k7;
wire        char_video = ~mode_grph & char_shift[6]; // h5
wire        grph_video =  mode_grph & grph_shift[6]; // h5
wire        video = (char_video | grph_video) ^ blink; // h4, g6
assign VIDEO = video & mode_vid_en; // g3

// sound
reg         ce_16us;
reg   [7:0] ce_16us_cnt;
always @(posedge CLK12) begin
	ce_16us_cnt <= ce_16us_cnt + 1'd1;
	ce_16us <= 0;
	if (ce_16us_cnt == 191) begin
		ce_16us_cnt <= 0;
		ce_16us <= 1;
	end
end

reg   [7:0] snd_latch;
wire        snd_sel = !cpu_addr[4] & cpu_addr[2:0] == 3'b110 & !wr_n & !iorq_n;

always @(posedge CLK12) begin
	if (RESET)
		snd_latch <= 0;
	else if (snd_sel)
		snd_latch <= cpu_dout;
end

wire [13:0] magnitude;
sound_generator sound_generator(
	.clk(CLK12),
	.stb_16us(ce_16us),
   
	.mixer_ctl({snd_latch[5], snd_latch[3], snd_latch[4]}),
	.vco_sel(snd_latch[2]),
	.vco_pitch(snd_latch[1]),
	.envsel(snd_latch[7:6]),
	.inhibit(!snd_latch[0]),

	.magnitude(magnitude)
);

always @(posedge CLK12) if (ce_16us) AUDIO <= magnitude;

// cpu
wire        int_n = pio_int_n;
wire        nmi_n = ~vsync;
wire [15:0] cpu_addr;
wire  [7:0] cpu_din;
wire  [7:0] cpu_dout;
wire        iorq_n;
wire        mreq_n;
wire        rfsh_n;
wire        rd_n;
wire        wr_n;
wire        m1_n;

T80s T80 (
	.RESET_n(~RESET),
	.CLK(CLK12),
	.CEN(cen3),
	.WAIT_n(~DL),
	.INT_n(int_n),
	.NMI_n(nmi_n),
	.BUSRQ_n(1'b1),
	.M1_n(m1_n),
	.RFSH_n(rfsh_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.A(cpu_addr),
	.DI(cpu_din),
	.DO(cpu_dout)
);

reg   [7:0] rom[16384];
reg   [7:0] rom_dout;
always @(posedge CLK12) begin : ROM
	rom_dout <= rom[cpu_addr[13:0]];
end
always @(posedge DL_CLK) begin : ROM_DL
	if (DL_WE & DL_ROM & DL_ADDR[15:14] == 0) rom[DL_ADDR[13:0]] <= DL_DATA;
end

reg   [7:0] ram[16384];
reg   [7:0] ram_dout;
wire        ram_we = rams & ~mreq_n & ~wr_n;
reg  [15:0] start_addr;

always @(posedge CLK12) begin : RAM
	ram_dout <= ram[cpu_addr[13:0]];
	if (ram_we) ram[cpu_addr[13:0]] <= cpu_dout;
end

always @(posedge CLK12) begin
	if (RESET)
		start_addr <= 16'hc000;
	else begin
		if (~mreq_n & ~wr_n & cpu_addr == 16'hfe1c) start_addr[ 7:0] <= cpu_dout;
		if (~mreq_n & ~wr_n & cpu_addr == 16'hfe1d) start_addr[15:8] <= cpu_dout;
	end
end

reg   [7:0] xram[16384];
reg   [7:0] xram_dout;
wire        xram_we = xrams & ~mreq_n & ~wr_n;
always @(posedge CLK12) begin : XRAM
	xram_dout <= xram[cpu_addr[13:0]];
	if (xram_we) xram[cpu_addr[13:0]] <= cpu_dout;
end

// BAC loading
localparam [15:0] EOFA = 16'hFE1E;
localparam [15:0] HEAD = 16'hFE20;

reg   [15:0] linepos;
reg          dl_allow, dl_skip;
reg   [15:0] wraddr, last_addr;
wire         dl_wr = DL_WE & !DL_ROM & DL_ADDR[15:14] == 0 & DL_ADDR != 0 & dl_allow & !dl_skip;
reg          inject;
reg    [1:0] inject_phase;
reg    [7:0] inject_data;
wire   [7:0] wr_data = DL ? DL_DATA : inject_data;

wire  [15:0] head_addr = last_addr + 1'd1;
always @(*) begin
	case (inject_phase)
		0: inject_data = last_addr[7:0];
		1: inject_data = last_addr[15:8];
		2: inject_data = head_addr[7:0];
		3: inject_data = head_addr[15:8];
	endcase
end

always @(posedge DL_CLK) begin : RAM_DL
	reg dl_d;
	dl_d <= DL;
	if (~dl_d & DL) begin
		linepos <= 1;
		dl_allow <= 1;
		wraddr <= start_addr;
		inject <= 0;
		dl_skip <= 0;
	end
	if (dl_wr | inject) begin
		if (wraddr[15:14] == 2'b11)  ram[wraddr[13:0]] <= wr_data;
		if (wraddr[15:14] == 2'b10) xram[wraddr[13:0]] <= wr_data;
		wraddr <= wraddr + 1'd1;
	end

	if (DL_WE & !DL_ROM & DL_ADDR == linepos & dl_skip) begin
		dl_skip <= 0;
		linepos <= linepos + 1'd1;
	end
	if (DL_WE & !DL_ROM & DL_ADDR == linepos & dl_allow & !dl_skip) begin
		linepos <= linepos + DL_DATA;
		if (DL_DATA == 1) begin
			dl_allow <= 0;
			last_addr <= wraddr;
		end
		if (DL_DATA == 0) begin
			if (linepos[7:0] == 8'hFF || DL_ALT)
				linepos <= linepos + 1'd1;
			else begin
				linepos <= {linepos[15:8], 8'hFF};
				dl_skip <= 1;
			end
			wraddr <= wraddr;
		end
	end
	if (!DL_ROM & ~DL & dl_d) begin
		inject_phase <= 0;
		inject <= 1;
		wraddr <= EOFA;
	end
	if (inject) begin
		inject_phase <= inject_phase + 1'd1;
		if (inject_phase == 3) inject <= 0;
	end
end
//

reg   [3:0] rom_e7_q;
always @(posedge CLK12) begin
	rom_e7_q <= rom_e7[{2'b01, cpu_addr[15:10]}];
end

wire        xrams = XMEM & !rom_e7_q[0];
wire        rams  = !rom_e7_q[3];
wire        vrams = rom_e7_q[2];
wire        roms  = !rom_e7_q[1];

reg   [7:0] vram_q;
always @(posedge CLK12) begin
	if (vrams & !mreq_n & !wr_n) vram[cpu_addr[9:0]] <= cpu_dout;
	vram_q <= vram[cpu_addr[9:0]];
end

wire  [7:0] pio_dout;
wire        pios = cpu_addr[4];
wire        pio_int_n;
wire        pio_oe;
wire  [7:0] piob_out;

assign      CASS_CTRL = piob_out[5];
assign      CASS_OUT = ~piob_out[6];
reg         tape_in;
always @(posedge CLK12) begin
	reg cass_in_d;
	cass_in_d <= CASS_IN;

	if (!piob_out[6])
		tape_in <= 1;
	else if (cass_in_d ^ CASS_IN)
		tape_in <= 0;
end

z80_pio z80_pio (
	.reset(RESET),
	.clock(CLK12),
	.clock_ena(cen3),
	.din(cpu_dout),
	.dout(pio_dout),
	.cpu_din(cpu_din),
	.oe(pio_oe),

	.ce_n(!pios),
	.m1_n(m1_n),
	.iorq_n(iorq_n),
	.rd_n(rd_n),
	.int_n(pio_int_n),
	.sel_ab(cpu_addr[1]),
	.sel_cd(cpu_addr[0]),

	.pioa_in({keydown, kcode}),
	.pioa_out(),
	.ardy(),
	.astrb_n(vcnt[0]), // strobe is connected but control mode is selected(?)

	.piob_in({tape_in, 7'h3f}),
	.piob_out(piob_out)
);

assign cpu_din = pio_oe ? pio_dout :
                 vrams ? vram_q :
                 roms  ? rom_dout :
					  rams  ? ram_dout :
					  xrams ? xram_dout :
					  8'h00;

// keyboard
reg         akd;
reg   [6:0] kcode;
reg         shift, ctrl, upcase;
reg         keydown;
reg  [23:0] keydown_cnt, keyrep_cnt;

always @(posedge CLK12) begin
	reg akd_d;
	akd_d <= akd;

	if (RESET) begin
		keydown <= 0;
		keydown_cnt <= 0;
		keyrep_cnt <= 0;
	end else begin
		if (|keydown_cnt)
			keydown_cnt <= keydown_cnt - 1'd1;
		else begin
			keydown_cnt <= 0;
			keydown <= 0;
		end

		if (~akd_d & akd) begin
			keydown <= 1;
			keyrep_cnt <= 24'd2_000_000;
			keydown_cnt <= 24'd300_000;
		end else if (|keyrep_cnt)
			keyrep_cnt <= keyrep_cnt - 1'd1;
		else if (akd) begin
			keyrep_cnt <= 24'd500_000;
			keydown_cnt <= 24'd300_000;
			keydown <= 1;
		end else begin
			keydown_cnt <= 0;
			keydown <= 0;
		end

	end
end

assign UPCASE = upcase;

always @(posedge CLK12) begin : KEYBOARD
	if (KEY_STROBE) begin
		casez ({ctrl, shift, KEY_EXTENDED, KEY_CODE})
			{2'b??, 9'h012}: shift <= KEY_PRESSED;
			{2'b??, 9'h059}: shift <= KEY_PRESSED;
			{2'b??, 9'h?14}: ctrl <= KEY_PRESSED;
			{2'b??, 9'h058}: if (KEY_PRESSED) upcase <= ~upcase;
			{2'b0?, 9'h01c}: begin akd <= KEY_PRESSED; kcode <= 7'h41 | {~(shift ^ upcase), 5'd0}; end //A
			{2'b0?, 9'h032}: begin akd <= KEY_PRESSED; kcode <= 7'h42 | {~(shift ^ upcase), 5'd0}; end //B
			{2'b0?, 9'h021}: begin akd <= KEY_PRESSED; kcode <= 7'h43 | {~(shift ^ upcase), 5'd0}; end //C
			{2'b0?, 9'h023}: begin akd <= KEY_PRESSED; kcode <= 7'h44 | {~(shift ^ upcase), 5'd0}; end //D
			{2'b0?, 9'h024}: begin akd <= KEY_PRESSED; kcode <= 7'h45 | {~(shift ^ upcase), 5'd0}; end //E
			{2'b0?, 9'h02B}: begin akd <= KEY_PRESSED; kcode <= 7'h46 | {~(shift ^ upcase), 5'd0}; end //F
			{2'b0?, 9'h034}: begin akd <= KEY_PRESSED; kcode <= 7'h47 | {~(shift ^ upcase), 5'd0}; end //G
			{2'b0?, 9'h033}: begin akd <= KEY_PRESSED; kcode <= 7'h48 | {~(shift ^ upcase), 5'd0}; end //H
			{2'b0?, 9'h043}: begin akd <= KEY_PRESSED; kcode <= 7'h49 | {~(shift ^ upcase), 5'd0}; end //I
			{2'b0?, 9'h03B}: begin akd <= KEY_PRESSED; kcode <= 7'h4a | {~(shift ^ upcase), 5'd0}; end //J
			{2'b0?, 9'h042}: begin akd <= KEY_PRESSED; kcode <= 7'h4b | {~(shift ^ upcase), 5'd0}; end //K
			{2'b0?, 9'h04B}: begin akd <= KEY_PRESSED; kcode <= 7'h4c | {~(shift ^ upcase), 5'd0}; end //L
			{2'b0?, 9'h03A}: begin akd <= KEY_PRESSED; kcode <= 7'h4d | {~(shift ^ upcase), 5'd0}; end //M
			{2'b0?, 9'h031}: begin akd <= KEY_PRESSED; kcode <= 7'h4e | {~(shift ^ upcase), 5'd0}; end //N
			{2'b0?, 9'h044}: begin akd <= KEY_PRESSED; kcode <= 7'h4f | {~(shift ^ upcase), 5'd0}; end //O
			{2'b0?, 9'h04D}: begin akd <= KEY_PRESSED; kcode <= 7'h50 | {~(shift ^ upcase), 5'd0}; end //P
			{2'b0?, 9'h015}: begin akd <= KEY_PRESSED; kcode <= 7'h51 | {~(shift ^ upcase), 5'd0}; end //Q
			{2'b0?, 9'h02D}: begin akd <= KEY_PRESSED; kcode <= 7'h52 | {~(shift ^ upcase), 5'd0}; end //R
			{2'b0?, 9'h01B}: begin akd <= KEY_PRESSED; kcode <= 7'h53 | {~(shift ^ upcase), 5'd0}; end //S
			{2'b0?, 9'h02C}: begin akd <= KEY_PRESSED; kcode <= 7'h54 | {~(shift ^ upcase), 5'd0}; end //T
			{2'b0?, 9'h03C}: begin akd <= KEY_PRESSED; kcode <= 7'h55 | {~(shift ^ upcase), 5'd0}; end //U
			{2'b0?, 9'h02A}: begin akd <= KEY_PRESSED; kcode <= 7'h56 | {~(shift ^ upcase), 5'd0}; end //V
			{2'b0?, 9'h01D}: begin akd <= KEY_PRESSED; kcode <= 7'h57 | {~(shift ^ upcase), 5'd0}; end //W
			{2'b0?, 9'h022}: begin akd <= KEY_PRESSED; kcode <= 7'h58 | {~(shift ^ upcase), 5'd0}; end //X
			{2'b0?, 9'h035}: begin akd <= KEY_PRESSED; kcode <= 7'h59 | {~(shift ^ upcase), 5'd0}; end //Y
			{2'b0?, 9'h01A}: begin akd <= KEY_PRESSED; kcode <= 7'h5a | {~(shift ^ upcase), 5'd0}; end //Z

			{2'b00, 9'h016}: begin akd <= KEY_PRESSED; kcode <= 7'h31; end //1
			{2'b00, 9'h01E}: begin akd <= KEY_PRESSED; kcode <= 7'h32; end //2
			{2'b00, 9'h026}: begin akd <= KEY_PRESSED; kcode <= 7'h33; end //3
			{2'b00, 9'h025}: begin akd <= KEY_PRESSED; kcode <= 7'h34; end //4
			{2'b00, 9'h02E}: begin akd <= KEY_PRESSED; kcode <= 7'h35; end //5
			{2'b00, 9'h036}: begin akd <= KEY_PRESSED; kcode <= 7'h36; end //6
			{2'b00, 9'h03D}: begin akd <= KEY_PRESSED; kcode <= 7'h37; end //7
			{2'b00, 9'h03E}: begin akd <= KEY_PRESSED; kcode <= 7'h38; end //8
			{2'b00, 9'h046}: begin akd <= KEY_PRESSED; kcode <= 7'h39; end //9
			{2'b00, 9'h045}: begin akd <= KEY_PRESSED; kcode <= 7'h30; end //0

			{2'b00, 9'h069}: begin akd <= KEY_PRESSED; kcode <= 7'h31; end //KP 1
			{2'b00, 9'h072}: begin akd <= KEY_PRESSED; kcode <= 7'h32; end //KP 2
			{2'b00, 9'h07A}: begin akd <= KEY_PRESSED; kcode <= 7'h33; end //KP 3
			{2'b00, 9'h06B}: begin akd <= KEY_PRESSED; kcode <= 7'h34; end //KP 4
			{2'b00, 9'h073}: begin akd <= KEY_PRESSED; kcode <= 7'h35; end //KP 5
			{2'b00, 9'h074}: begin akd <= KEY_PRESSED; kcode <= 7'h36; end //KP 6
			{2'b00, 9'h06C}: begin akd <= KEY_PRESSED; kcode <= 7'h37; end //KP 7
			{2'b00, 9'h075}: begin akd <= KEY_PRESSED; kcode <= 7'h38; end //KP 8
			{2'b00, 9'h07D}: begin akd <= KEY_PRESSED; kcode <= 7'h39; end //KP 9
			{2'b00, 9'h070}: begin akd <= KEY_PRESSED; kcode <= 7'h30; end //KP 0

			{2'b01, 9'h016}: begin akd <= KEY_PRESSED; kcode <= 7'h21; end //SHIFT+1
			{2'b01, 9'h01E}: begin akd <= KEY_PRESSED; kcode <= 7'h22; end //SHIFT+2
			{2'b01, 9'h026}: begin akd <= KEY_PRESSED; kcode <= 7'h23; end //SHIFT+3
			{2'b01, 9'h025}: begin akd <= KEY_PRESSED; kcode <= 7'h24; end //SHIFT+4
			{2'b01, 9'h02E}: begin akd <= KEY_PRESSED; kcode <= 7'h25; end //SHIFT+5
			{2'b01, 9'h036}: begin akd <= KEY_PRESSED; kcode <= 7'h26; end //SHIFT+6
			{2'b01, 9'h03D}: begin akd <= KEY_PRESSED; kcode <= 7'h27; end //SHIFT+7
			{2'b01, 9'h03E}: begin akd <= KEY_PRESSED; kcode <= 7'h28; end //SHIFT+8
			{2'b01, 9'h046}: begin akd <= KEY_PRESSED; kcode <= 7'h29; end //SHIFT+9
			{2'b01, 9'h045}: begin akd <= KEY_PRESSED; kcode <= 7'h3D; end //SHIFT+0

			{2'b00, 9'h?5A}: begin akd <= KEY_PRESSED; kcode <= 7'h0d; end //ENTER
			{2'b00, 9'h029}: begin akd <= KEY_PRESSED; kcode <= 7'h20; end //SPACE
			{2'b00, 9'h16B}: begin akd <= KEY_PRESSED; kcode <= 7'h08; end //LEFT
			{2'b00, 9'h066}: begin akd <= KEY_PRESSED; kcode <= 7'h08; end //BACKSPACE
			{2'b00, 9'h174}: begin akd <= KEY_PRESSED; kcode <= 7'h09; end //RIGHT
			{2'b10, 9'h021}: begin akd <= KEY_PRESSED; kcode <= 7'h03; end //CTRL+C
			{2'b10, 9'h022}: begin akd <= KEY_PRESSED; kcode <= 7'h18; end //CTRL+X

			{2'b00, 9'h041}: begin akd <= KEY_PRESSED; kcode <= 7'h2C; end // ,
			{2'b00, 9'h049}: begin akd <= KEY_PRESSED; kcode <= 7'h2E; end // .
			{2'b00, 9'h04A}: begin akd <= KEY_PRESSED; kcode <= 7'h2D; end // -
			{2'b00, 9'h04E}: begin akd <= KEY_PRESSED; kcode <= 7'h2B; end // +
			{2'b00, 9'h05D}: begin akd <= KEY_PRESSED; kcode <= 7'h27; end // //
			{2'b00, 9'h00E}: begin akd <= KEY_PRESSED; kcode <= 7'h3C; end // `

			{2'b01, 9'h041}: begin akd <= KEY_PRESSED; kcode <= 7'h3B; end // SHIFT + ,
			{2'b01, 9'h049}: begin akd <= KEY_PRESSED; kcode <= 7'h3A; end // SHIFT + .
			{2'b01, 9'h04A}: begin akd <= KEY_PRESSED; kcode <= 7'h5F; end // SHIFT + -
			{2'b01, 9'h04E}: begin akd <= KEY_PRESSED; kcode <= 7'h3F; end // SHIFT + +
			{2'b01, 9'h05D}: begin akd <= KEY_PRESSED; kcode <= 7'h2A; end // SHIFT + //
			{2'b01, 9'h00E}: begin akd <= KEY_PRESSED; kcode <= 7'h3E; end // SHIFT + `
			{2'b1?, 9'h00E}: begin akd <= KEY_PRESSED; kcode <= 7'h7F; end // CTRL + `

			{2'b0?, 9'h055}: begin akd <= KEY_PRESSED; kcode <= 7'h40 | {~(shift ^ upcase), 5'd0}; end // é
			{2'b0?, 9'h054}: begin akd <= KEY_PRESSED; kcode <= 7'h5D | {~(shift ^ upcase), 5'd0}; end // [
			{2'b0?, 9'h05B}: begin akd <= KEY_PRESSED; kcode <= 7'h5E | {~(shift ^ upcase), 5'd0}; end // ]
			{2'b0?, 9'h04C}: begin akd <= KEY_PRESSED; kcode <= 7'h5C | {~(shift ^ upcase), 5'd0}; end // ;
			{2'b0?, 9'h052}: begin akd <= KEY_PRESSED; kcode <= 7'h5B | {~(shift ^ upcase), 5'd0}; end // '

		endcase
	end
	if (RESET) upcase <= 0;
end

endmodule
