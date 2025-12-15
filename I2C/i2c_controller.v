`timescale 1ns / 1ps


module i2c_controller(
	
	// Inputs/Outputs
	input wire clk, // Main system clock
	input wire rst, // Reset FSM
	input wire [6:0] addr, // 7 bit Slave address
	input wire [7:0] data_in, // Data to send
	input wire enable, // Start Communication
	input wire rw, // 0 = Write, 1 = Read

	output reg [7:0] data_out, // Data received from Slave 
	output wire ready, // Master ready for next transfer

	inout i2c_sda, // Serial clock (to Slave)
	inout wire i2c_scl // Serial data (to Slave)
	);

	// FSM States
	localparam IDLE = 0; // Waiting for enable
	localparam START = 1; // Pull SDA low, initiate transfer
	localparam ADDRESS = 2; // Send 7-bit address + R/W bit
	localparam READ_ACK = 3; // Master checks ACK from slave after sending address
	localparam WRITE_DATA = 4; // Master sends data byte
	localparam READ_ACK2 = 7; // Master checks ACK from slave after sending data
	localparam READ_DATA = 6; // Master reads data byte from slave
	localparam WRITE_ACK = 5; // Master sends ACK (optional for read)
	localparam STOP = 8; // Release SDA/SCL, end transaction

	/* Even though ACK comes from slave, the master must wait and check the line to know if the slave received the byte.
	READ_ACK: after sending address, check if slave ACKed
	READ_ACK2: after sending data, check if slave ACKed
	WRITE_ACK: during a read operation, master sends ACK/NACK after reading
	This is standard I²C protocol behavior.*/
	
	localparam DIVIDE_BY = 4; // clock division factor to slower clock as I2C operates slower

	// reg's - memory to store states for FSM 
	reg [7:0] state; // Keeps track of the current FSM state of the master.
	reg [7:0] saved_addr; // Stores the 7-bit slave address + R/W bit for transmission.
	reg [7:0] saved_data; // Stores the data byte to send to slave
	reg [7:0] counter; // Acts as bit counter for sending/receiving 8-bit address or data.
	reg [7:0] counter2 = 0; // Used for clock division, works with DIVIDE_BY
	reg write_enable; /* Controls whether master drives SDA or releases it (Z).
						Implements open-drain behavior:
						write_enable = 1 → drive SDA (0 or 1)
						write_enable = 0 → release SDA → slave can ACK 
						- write_enable decides when to actually drive the line */
	reg sda_out; // Holds the value that master wants to put on SDA when write_enable = 1 - sda_out is the “data we want to write”
	reg i2c_scl_enable = 0; /* Controls whether the I²C clock is active or idle.
								During START/STOP or IDLE states, the clock is kept HIGH (inactive).
								During ADDRESS/DATA transfers, it is enabled to toggle i2c_clk. */
	reg i2c_clk = 1; // This is the slow clock used for I²C communication. The FSM uses posedge and negedge of i2c_clk to sequence SDA bits properly.

	assign ready = ((rst == 0) && (state == IDLE)) ? 1 : 0; // The master is ready for a new transfer only when reset is inactive and FSM is in IDLE state.
	assign i2c_scl = (i2c_scl_enable == 0 ) ? 1 : i2c_clk; // Controls the SCL line, which is the clock for I²C communication. 
														   /* i2c_scl_enable == 0 → Clock disabled (during START, STOP, or IDLE)
															In I²C, SCL must stay HIGH during START and STOP
															So assign i2c_scl = 1 in those cases
															i2c_scl_enable == 1 → Clock enabled
															Then i2c_scl = i2c_clk → toggling slow clock driving the FSM transfer 
															In simple terms:
															During START/STOP/IDLE → keep clock HIGH
															During DATA/ADDRESS transfer → SCL follows the slow i2c_clk*/
	assign i2c_sda = (write_enable == 1) ? sda_out : 'bz; // Implements open-drain behavior for SDA (data line).
														  /* write_enable == 1 → Master wants to drive SDA
															Assign the value stored in sda_out to the line (0 or 1)
															write_enable == 0 → Master releases SDA
															Assign 'bz → high-impedance → slave can drive SDA for ACK/NACK
															Master only drives SDA when it’s sending bits; otherwise it lets the slave control SDA. 
															This is exactly how I²C allows bidirectional communication on a single wire. */

	// This block divides the fast system clock into a slower I²C clock (i2c_clk) for FSM timing
	always @(posedge clk) begin
		if (counter2 == (DIVIDE_BY/2) - 1) begin
			i2c_clk <= ~i2c_clk;
			counter2 <= 0;
		end
		else counter2 <= counter2 + 1;
	end 

	// This block enables/disables the clock depending on the FSM state to comply with I²C timing rules.
	/* I²C protocol requirement:
		START condition: SDA goes LOW while SCL is HIGH
		STOP condition: SDA goes HIGH while SCL is HIGH
		If clock toggled during START/STOP → violates protocol*/
	always @(negedge i2c_clk, posedge rst) begin
		if(rst == 1) begin
			i2c_scl_enable <= 0;
		end else begin
			if ((state == IDLE) || (state == START) || (state == STOP)) begin // When FSM is idle or generating START/STOP, the clock should not toggle.
				i2c_scl_enable <= 0;
			end 
			else begin
				i2c_scl_enable <= 1; // In all other FSM states (ADDRESS, WRITE_DATA, READ_DATA), we enable SCL toggling
			end
		end
	end

	// This block is the FSM (Finite State Machine) controller of the I²C master
	/* This FSM runs on the positive edge of the I²C clock and controls the transaction flow—START, ADDRESS, ACK checking, READ/WRITE, 
	and STOP—while SDA driving is handled separately on the negative edge to follow I²C timing */
	// FSM block → @(posedge i2c_clk)
	always @(posedge i2c_clk, posedge rst) begin
		if(rst == 1) begin
			state <= IDLE;
		end		
		else begin
			case(state)
			
				IDLE: begin
					if (enable) begin
						state <= START;
						saved_addr <= {addr, rw};
						saved_data <= data_in;
					end
					else state <= IDLE;
				end

				START: begin // Prepares to send 8 bits
					counter <= 7; // Counter initialized to MSB (bit 7)
					state <= ADDRESS;
				end

				ADDRESS: begin
					if (counter == 0) begin 
						state <= READ_ACK;
					end else counter <= counter - 1; // Counter goes: 7 → 0
				end

				READ_ACK: begin
					if (i2c_sda == 0) begin
						counter <= 7;
						if(saved_addr[0] == 0) state <= WRITE_DATA;
						else state <= READ_DATA;
					end else state <= STOP; // if NACK, Slave didn’t respond condition
				end

				// Master sends 8 data bits
				WRITE_DATA: begin
					if(counter == 0) begin
						state <= READ_ACK2;
					end else counter <= counter - 1;
				end
				
				READ_ACK2: begin
					if ((i2c_sda == 0) && (enable == 1)) state <= IDLE; // If enable still high → master ready again
					else state <= STOP;
				end

				// Master reads data bit by bit from slave
				READ_DATA: begin
					data_out[counter] <= i2c_sda;
					if (counter == 0) state <= WRITE_ACK;
					else counter <= counter - 1;
				end

				// During READ stage - Master sends ACK or NACK to slave
				WRITE_ACK: begin
					state <= STOP;
				end

				// SDA released HIGH while SCL HIGH. FSM returns to IDLE
				STOP: begin
					state <= IDLE;
				end
			endcase
		end
	end


	// SDA drive block → @(negedge i2c_clk)
	/* I²C rule:
		Data on SDA must change only when SCL is LOW
		Data must be stable when SCL is HIGH */
	always @(negedge i2c_clk, posedge rst) begin
		if(rst == 1) begin
			write_enable <= 1;
			sda_out <= 1;
		end else begin
			case(state)
				
				START: begin
					write_enable <= 1;
					sda_out <= 0;
				end

				// Master is sending address bits
				ADDRESS: begin
					sda_out <= saved_addr[counter];
				end
				
				READ_ACK: begin
					write_enable <= 0;
				end
				
				WRITE_DATA: begin 
					write_enable <= 1;
					sda_out <= saved_data[counter];
				end

				// During READ, the MASTER must ACK
				WRITE_ACK: begin
					write_enable <= 1;
					sda_out <= 0;
				end
				
				READ_DATA: begin
					write_enable <= 0;				
				end
				
				STOP: begin
					write_enable <= 1;
					sda_out <= 1;
				end
			endcase
		end
	end

	/*  FSM decides WHEN to do things
		This above block decides WHAT goes on SDA and WHO drives SDA*

		The FSM is split into two always blocks.
		The posedge block controls state transitions and samples SDA, while the negedge block drives SDA.
		This ensures SDA only changes when SCL is low and is stable when SCL is high, fully compliant with I²C timing.

		posedge block = What to do next
		negedge block = Physically do it on SDA
	/

endmodule
