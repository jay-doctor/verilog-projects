`timescale 1ns / 1ps

/* The I²C slave does NOT generate clock.
It only:
- Detects START / STOP
- Listens to SCL
- Samples SDA on SCL ↑
- Drives SDA on SCL ↓ (ACK or data)
So the slave is reactive, not controlling. */

module i2c_slave_controller(
	inout sda, // bidirectional data line
	inout scl // clock from master
	);
	
	localparam ADDRESS = 7'b0101010; // fixed slave address, Slave responds only if master sends this address
	
	localparam READ_ADDR = 0; // Receive address + R/W bit
	localparam SEND_ACK = 1; //Acknowledge address
	localparam READ_DATA = 2; // Receive data from master
	localparam WRITE_DATA = 3; // Send data to master
	localparam SEND_ACK2 = 4; // Acknowledge received data
	
	reg [7:0] addr; // store received address byte
	reg [7:0] counter; // bit counter (7 → 0, MSB first)
	reg [7:0] state = 0; // FSM current state
	reg [7:0] data_in = 0; // data written by master
	reg [7:0] data_out = 8'b11001100; // data sent to master during read
	reg sda_out = 0; //
	reg sda_in = 0; //
	reg start = 0; //
	reg write_enable = 0; //

	/* write_enable = 1 → slave drives SDA
	write_enable = 0 → slave releases SDA
	Implements open-drain behavior
	This allows master and slave to share SDA safely */
	assign sda = (write_enable == 1) ? sda_out : 'bz;
	
	always @(negedge sda) begin
		if ((start == 0) && (scl == 1)) begin // START = SDA goes HIGH → LOW while SCL is HIGH
			start <= 1;	
			counter <= 7;
		end
	end
	
	always @(posedge sda) begin
		if ((start == 1) && (scl == 1)) begin
			state <= READ_ADDR;
			start <= 0;
			write_enable <= 0;
		end
	end


	/* Rule of I²C
	Data is sampled on SCL rising edge
	So slave reads SDA only on posedge scl  */
	always @(posedge scl) begin
		if (start == 1) begin
			case(state)
				READ_ADDR: begin
					addr[counter] <= sda;
					if(counter == 0) state <= SEND_ACK;
					else counter <= counter - 1;					
				end
				
				SEND_ACK: begin
					if(addr[7:1] == ADDRESS) begin
						counter <= 7;
						if(addr[0] == 0) begin 
							state <= READ_DATA;
						end
						else state <= WRITE_DATA;
					end
				end
				
				READ_DATA: begin
					data_in[counter] <= sda;
					if(counter == 0) begin
						state <= SEND_ACK2;
					end else counter <= counter - 1;
				end
				
				SEND_ACK2: begin
					state <= READ_ADDR;					
				end
				
				WRITE_DATA: begin
					if(counter == 0) state <= READ_ADDR;
					else counter <= counter - 1;		
				end
				
			endcase
		end
	end
	
	always @(negedge scl) begin
		case(state)
			
			READ_ADDR: begin
				write_enable <= 0;			
			end
			
			SEND_ACK: begin
				sda_out <= 0;
				write_enable <= 1;	
			end
			
			READ_DATA: begin
				write_enable <= 0;
			end
			
			WRITE_DATA: begin
				sda_out <= data_out[counter];
				write_enable <= 1;
			end
			
			SEND_ACK2: begin
				sda_out <= 0;
				write_enable <= 1;
			end
		endcase
	end

	/* 
	Slave reads data on SCL rising edge and drives data or ACK on SCL falling edge to follow I²C timing rules.
	Master decides what to do on posedge and changes SDA on negedge so data is stable when SCL goes high.
	*/
	
endmodule
