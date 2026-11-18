`timescale 1ns / 1ps
// AXI4-Lite register file for the SFP+ PRBS tester (aclk = PS pl_clk0, 100 MHz).
//
//  0x00 ID          RO  0x50524253 ("PRBS")
//  0x04 VERSION     RO  0x00010000
//  0x08 CTRL        RW  [0] gt_reset_all   (level, 1 = hold the transceiver in reset)
//                       [1] counters_clear (level, 1 = clear counters + PRBS checker)
//                       [2] inject_toggle  (flip to inject one PRBS error on TX)
//                       [3] snap_toggle    (flip to latch counters; wait STATUS[5] == new value)
//  0x0C STATUS      RO  [0] gtpowergood  [1] reset_tx_done  [2] reset_rx_done
//                       [3] prbs_locked  [4] error_seen (sticky until clear)
//                       [5] snap_ack     [6] rx_cdr_stable  [7] userclk_tx_active
//                       [8] userclk_rx_active
//  0x10 LOCKED_LO   RO  RX user-clock cycles counted while the checker was locked (snapshot)
//  0x14 LOCKED_HI   RO  (bits checked = cycles * 64)
//  0x18 ERR_CYCLES  RO  RX user-clock cycles in which RXPRBSERR was set (snapshot)
//  0x1C INJECTED    RO  number of errors injected on TX since clear (snapshot)
module prbs_regs (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output reg  [31:0] ctrl,
    input  wire [31:0] status,        // already synchronised to aclk
    input  wire [63:0] snap_locked,   // quasi-static after snap_ack
    input  wire [31:0] snap_errs,
    input  wire [31:0] snap_injected
);
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // Write channel: accept address and data together
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            ctrl          <= 32'd0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
            if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
                if (s_axi_awaddr[7:2] == 6'h02 && s_axi_wstrb[0])
                    ctrl[7:0] <= s_axi_wdata[7:0];
            end
        end
    end

    // Read channel
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
        end else begin
            s_axi_arready <= 1'b0;
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                case (s_axi_araddr[7:2])
                    6'h00:   s_axi_rdata <= 32'h50524253;
                    6'h01:   s_axi_rdata <= 32'h00010000;
                    6'h02:   s_axi_rdata <= ctrl;
                    6'h03:   s_axi_rdata <= status;
                    6'h04:   s_axi_rdata <= snap_locked[31:0];
                    6'h05:   s_axi_rdata <= snap_locked[63:32];
                    6'h06:   s_axi_rdata <= snap_errs;
                    6'h07:   s_axi_rdata <= snap_injected;
                    default: s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end
        end
    end
endmodule
