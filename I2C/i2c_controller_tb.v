/* 
The testbench instantiates both I²C master and slave, generates clock and reset, 
applies write stimulus, and allows verification of SDA/SCL behavior in simulation.
*/

`timescale 1ns / 1ps

module i2c_controller_tb;

	// Inputs - These represent what a CPU or firmware would control in real hardware:
	reg clk; // System clock
	reg rst; // Reset
	reg [6:0] addr; // Slave address
	reg [7:0] data_in; // Data to write
	reg enable; // Start transaction
	reg rw; // Read / Write selection

	// Outputs - These are observed, not driven
	wire [7:0] data_out; // Data received from slave
	wire ready; // Master is idle / ready

	// Bidirs - Bidirectional I²C Lines, Shared between master and slave	
	wire i2c_sda; // 
	wire i2c_scl; // 

	/* Instantiate the Master - Unit Under Test (UUT), 
	Connects it to TB-driven signals, Shares SDA/SCL with slave */
	i2c_controller master (
		.clk(clk), 
		.rst(rst), 
		.addr(addr), 
		.data_in(data_in), 
		.enable(enable), 
		.rw(rw), 
		.data_out(data_out), 
		.ready(ready), 
		.i2c_sda(i2c_sda), 
		.i2c_scl(i2c_scl)
	);
	
	// Slave Instantiation
	/* 
	Places slave device on same I²C bus
	No clock/reset needed → slave reacts only to SDA/SCL
	*/
	i2c_slave_controller slave (
    .sda(i2c_sda), 
    .scl(i2c_scl)
    );

	// Clock Generator Block
	// Generates continuous system clock, as Master logic depends on clk
	initial begin
		clk = 0;
		forever begin
			clk = #1 ~clk;
		end		
	end

	initial begin
		// Initialize Inputs
		clk = 0;
		rst = 1;

		// Wait 100 ns for global reset to finish
		#100;
        
		// Add stimulus here
		rst = 0; // Allows system to initialize cleanly
		rw = 0; // Master will WRITE
		addr = 7'b0101010; // Select slave
		data_in = 8'b10101010; // Data to send
		enable = 1; // Start I²C
		#10;
		enable = 0; // Let FSM proceed
				
		#500
		$finish; // Stops simulation cleanly
		
	end      
endmodule
