// -----------------------------------------------------------------------
//
//   Copyright 2003-2015 H. Peter Anvin - All Rights Reserved
//
//   This program is free software; you can redistribute it and/or modify
//   it under the terms of the GNU General Public License as published by
//   the Free Software Foundation, Inc., 53 Temple Place Ste 330,
//   Bostom MA 02111-1307, USA; either version 2 of the License, or
//   (at your option) any later version; incorporated herein by reference.
//
// -----------------------------------------------------------------------

//
// Sound controller for ABC80
//
// This attempts to simulate the SN76477 sound generator
// *as used in ABC80*.
//
// ABC80 has the following (approximate) parameters:
//
// SLF          = 2.9 Hz
// VCOmin       = 640 Hz
// Noise cutoff =  10 kHz
// Attack       =  22 ms
// Decay        = 470 ms


`define vco_min  14'd1024
`define vco_max  14'd12499

// Model the 76477 SLF.  This returns a "sawtooth" value
// between (approximately) [1024,12499] which gives about
// the 10:1 range needed by the VCO.

module slf(
	   input clk,		// 16 MHz
	   input clk_en,	// One pulse every 16 us (62.5 kHz)
	   output slf,		// SLF squarewave
	   output [13:0] saw	// Sawtooth magnitude
	   );
   reg 			 up  = 1;
   reg [13:0] 		 ctr = `vco_min;

   assign      slf = up;
   assign      saw = ctr;

   always @(posedge clk)
     if ( clk_en )
       begin
	  if ( ctr == `vco_max )
	    up <= 0;
	  else if ( ctr == `vco_min )
	    up <= 1;
	  
	  if ( up )
	    ctr <= ctr + 1;
	  else
	    ctr <= ctr - 1;
       end // if ( clk_en )
endmodule // slf

//
// The VCO.  The output frequency = clk/pitch/2.
//
module vco(
	   input clk,		// 16 MHz
	   input [13:0] pitch,	// Pitch control
	   output vco,		// VCO squarewave output
	   output vco2		// VCO output with every other pulse suppressed
	   );
   reg [13:0] 	  ctr = 0;
   reg [1:0] 	  cycle;

   assign 	  vco  = cycle[0];
   assign 	  vco2 = cycle[0] & cycle[1];
   
   always @(posedge clk)
     begin
	if ( ctr == 0 )
	  begin
	     ctr   <= pitch;
	     cycle <= cycle + 1;
	  end
	else
	  ctr <= ctr - 1;
     end // always @ (posedge clk)
endmodule // vco

//
// Noise (e.g. random number) generator.  The periodicity is ~2 Hz,
// which should be inaudible.
// 
module noise(
	     input clk,    // 16 MHz
	     input clk_en, // One pulse every 16 us (62.5 kHz)
	     output noise
	     );
   reg [15:0] 	    lfsr = ~16'h0; // Must be nonzero

   assign 	    noise = lfsr[15];

   wire 	    lfsr_zero = (lfsr == 0);
   
   always @(posedge clk)
     if ( clk_en )
       lfsr <= { lfsr[14:0], lfsr_zero } ^ (lfsr[15] ? 16'h54b9 : 16'h0);
endmodule // noise

//
// Mixer
//
module mixer(
	     input slf,
	     input vco,
	     input noise,
	     input envelope,
	     input [2:0] mixer_ctl,
	     output mixer_out
	     );
   reg 		    out;
   
   assign 	    mixer_out = out;
   
   always @(*)
     case ( mixer_ctl )
       3'b000:
	 out <= vco;
       3'b001:
	 out <= slf;
       3'b010:
	 out <= noise;
       3'b011:
	 out <= vco & noise;
       3'b100:
	 out <= slf & noise;
       3'b101:
	 out <= slf & vco & noise;
       3'b110:
	 out <= slf & vco;
       3'b111:
	 // This doesn't match the documentation, but if the documentation
	 // is followed and this is out <= 1, then "out 6,255" is silent,
	 // which it definitely wasn't on real hardware.
	 out <= envelope;       
     endcase // case( mixer_ctl )
endmodule // mixer

//
// Envelope generator, consisting of one-shot generator,
// envelope select, and envelope generation (attack/decay.)
// Output is parallel digital.
//
module oneshot(
	       input clk,    // 16 MHz
	       input clk_en, // One pulse every 16 us (62.5 kHz)
	       input inhibit,
	       output reg oneshot
	       );
   reg 		      out = 0;
   reg 		      inhibit1 = 0;
   reg [10:0] 	      ctr = 0;

   wire 	      ctr_or = |ctr;
      
   always @(posedge clk)
     begin
	inhibit1 <= inhibit;
	oneshot  <= ctr_or;
	  
	if ( ~inhibit & inhibit1 )
	  ctr <= 11'd1624;	// ~26 ms
	else if ( ctr_or & clk_en )
	  ctr <= ctr - 1;
     end
endmodule // oneshot

module envelope_select(
		       input [1:0] envsel,
		       input oneshot,
		       input vco,
		       input vco2,
		       output reg envelope
		       );
   
   always @(*)
     begin
	case ( envsel )
	  2'b00:
	    envelope <= vco;
	  2'b01:
	    envelope <= 1;
	  2'b10:
	    envelope <= oneshot;
	  2'b11:
	    envelope <= vco2;
	endcase // case( envsel )
     end // always @ (*)
endmodule // envelope_select

module envelope_shape(
		      input clk,    // 16 MHz
		      input clk_en, // One pulse every 16 us (62.5 kHz)
		      input envelope,
		      output reg [13:0] env_mag
		      );

   always @(posedge clk)
     if ( clk_en )
       begin
	  if ( envelope )
	    begin
	       if ( env_mag[13:11] != 3'b111 )
		 env_mag <= env_mag + 20;
	    end
	  else
	    begin
	       if ( |env_mag )
		 env_mag <= env_mag - 1;
	    end
       end // if ( clk_en )
endmodule // envelope_shape

//
// Putting it all together...
//
module sound_generator(
		       input clk,
		       input stb_16us,

		       input [2:0] mixer_ctl,
		       input vco_sel,
		       input vco_pitch,
		       input [1:0] envsel,
		       input inhibit,

		       output [13:0] magnitude
		       );
   wire        w_slf;
   wire [13:0] saw;
   wire [13:0] vco_level;
   wire        w_vco;
   wire        w_vco2;
   wire        w_envelope;
   wire        w_noise;
   wire        w_oneshot;
   wire        w_mixer_out;
   
   wire [13:0] env_mag;
   wire        signal_on;

   wire        clk_en = stb_16us;
   
   slf slf ( .clk (clk),
	     .clk_en (clk_en),
	     .saw (saw),
	     .slf (w_slf) );

   assign vco_level = vco_sel ? saw : vco_pitch ? `vco_max : `vco_min;
   
   vco vco ( .clk (clk),
	     .pitch (vco_level),
	     .vco (w_vco),
	     .vco2 (w_vco2) );

   noise noise ( .clk (clk),
		 .clk_en (clk_en),
		 .noise (w_noise) );

   
   mixer mixer ( .slf (w_slf),
		 .vco (w_vco),
		 .noise (w_noise),
		 .envelope (w_envelope),
		 .mixer_ctl (mixer_ctl),
		 .mixer_out (w_mixer_out) );

   
   oneshot oneshot ( .clk (clk),
		     .clk_en (clk_en),
		     .inhibit (inhibit),
		     .oneshot (w_oneshot) );

   envelope_select envelope_select ( .envsel (envsel),
				     .oneshot (w_oneshot),
				     .vco (w_vco),
				     .vco2 (w_vco2),
				     .envelope (w_envelope) );

   envelope_shape envelope_shape ( .clk (clk),
				   .clk_en (clk_en),
				   .envelope (w_envelope),
				   .env_mag (env_mag) );


   assign signal_on = ~inhibit & w_mixer_out;
   assign magnitude = env_mag & {14{signal_on}};

endmodule // sound_generator

//
// I2S output module - outputs 256 clocks/frame
//
module sound_i2s(
		 input        i2s_clk,	// 16 MHz
		 
		 input  [2:0] mixer_ctl,
		 input        vco_sel,
		 input        vco_pitch,
		 input  [1:0] envsel,
		 input        inhibit,

		 output       i2s_dat,
		 output       i2s_lrck
		 );

   reg   [7:0] ctr;
   wire [13:0] magnitude;
   reg  [13:0] sample;
   reg  [13:0] serial_out;
   
   wire        stb_16us = &ctr;
   
   assign     i2s_dat = serial_out[13];
   assign    i2s_lrck = ctr[7];

   always @(posedge i2s_clk)
     ctr <= ctr + 1;

   always @(posedge i2s_clk)
     if (stb_16us)
       sample <= magnitude;

   // We load serial_out after clock 1, which means each frame has two
   // zero padding bits at the front.  Bit 0 is required by I2S standard
   // format, and bit 1 means our unsigned output is always in the positive
   // half of the signed number space.
   always @(posedge i2s_clk)
     if (ctr[6:0] == 7'h01)
       serial_out <= sample;
     else
       serial_out <= { serial_out[12:0], 1'b0 };

   sound_generator sound_generator (
				    .clk (i2s_clk),
				    .stb_16us (stb_16us),

				    .mixer_ctl (mixer_ctl),
				    .vco_sel (vco_sel),
				    .vco_pitch (vco_pitch),
				    .envsel (envsel),
				    .inhibit (inhibit),

				    .magnitude (magnitude)
				    );
   
endmodule // sound_i2s
