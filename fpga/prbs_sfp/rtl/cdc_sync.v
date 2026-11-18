`timescale 1ns / 1ps
// Two-flop synchroniser for single-bit levels or toggles.
// The first stage is named "meta" so the XDC can false-path into it.
module cdc_sync #(
    parameter WIDTH = 1
) (
    input  wire             clk,
    input  wire [WIDTH-1:0] d,
    output wire [WIDTH-1:0] q
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] meta = {WIDTH{1'b0}};
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync = {WIDTH{1'b0}};

    always @(posedge clk) begin
        meta <= d;
        sync <= meta;
    end

    assign q = sync;
endmodule
