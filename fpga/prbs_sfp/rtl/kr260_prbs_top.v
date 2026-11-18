`timescale 1ns / 1ps
// KR260 SFP+ PRBS31 tester at 10.3125 Gb/s, built from free IP only
// (GT Wizard + Zynq PS block design, no IBERT/ILA/VIO).
//
//   SFP+ cage -> GTHE4_CHANNEL_X0Y6 (quad 224 lane 2), refclk U90 156.25 MHz on Y6/Y5
//   The GTH's built-in PRBS-31 generator drives TX; its built-in checker verifies RX.
//   Counters run in the RX user-clock domain (161.13 MHz = 10.3125G / 64) and are
//   read from Linux through an AXI4-Lite register file at 0xA000_0000 (HPM0_FPD).
//
//   sfp_led[0] = PRBS checker locked, sfp_led[1] = error seen since clear
//   led[0]     = heartbeat (pl_clk0),  led[1]     = transceiver reset sequence done
module kr260_prbs_top (
    input  wire       sfp_mgt_refclk_p,
    input  wire       sfp_mgt_refclk_n,
    input  wire       sfp_rx_p,
    input  wire       sfp_rx_n,
    output wire       sfp_tx_p,
    output wire       sfp_tx_n,
    output wire       sfp_tx_disable,
    output wire [1:0] sfp_led,
    output wire [1:0] led
);
    localparam [3:0] PRBS31 = 4'b0101;

    // ------------------------------------------------------------------ PS
    wire        aclk;
    wire        aresetn;
    wire [31:0] m_axi_awaddr, m_axi_araddr, m_axi_wdata, m_axi_rdata;
    wire [2:0]  m_axi_awprot, m_axi_arprot;
    wire [3:0]  m_axi_wstrb;
    wire [1:0]  m_axi_bresp, m_axi_rresp;
    wire        m_axi_awvalid, m_axi_awready, m_axi_wvalid, m_axi_wready;
    wire        m_axi_bvalid, m_axi_bready, m_axi_arvalid, m_axi_arready;
    wire        m_axi_rvalid, m_axi_rready;

    ps_bd_wrapper u_ps (
        .pl_clk0         (aclk),
        .aresetn         (aresetn),
        .M_AXI_awaddr    (m_axi_awaddr),
        .M_AXI_awprot    (m_axi_awprot),
        .M_AXI_awvalid   (m_axi_awvalid),
        .M_AXI_awready   (m_axi_awready),
        .M_AXI_wdata     (m_axi_wdata),
        .M_AXI_wstrb     (m_axi_wstrb),
        .M_AXI_wvalid    (m_axi_wvalid),
        .M_AXI_wready    (m_axi_wready),
        .M_AXI_bresp     (m_axi_bresp),
        .M_AXI_bvalid    (m_axi_bvalid),
        .M_AXI_bready    (m_axi_bready),
        .M_AXI_araddr    (m_axi_araddr),
        .M_AXI_arprot    (m_axi_arprot),
        .M_AXI_arvalid   (m_axi_arvalid),
        .M_AXI_arready   (m_axi_arready),
        .M_AXI_rdata     (m_axi_rdata),
        .M_AXI_rresp     (m_axi_rresp),
        .M_AXI_rvalid    (m_axi_rvalid),
        .M_AXI_rready    (m_axi_rready)
    );

    // ------------------------------------------------------------------ registers
    wire [31:0] ctrl;
    wire [31:0] status_aclk;
    reg  [63:0] snap_locked   = 64'd0;
    reg  [31:0] snap_errs     = 32'd0;
    reg  [31:0] snap_injected = 32'd0;

    prbs_regs u_regs (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axi_awaddr  (m_axi_awaddr[11:0]),
        .s_axi_awvalid (m_axi_awvalid),
        .s_axi_awready (m_axi_awready),
        .s_axi_wdata   (m_axi_wdata),
        .s_axi_wstrb   (m_axi_wstrb),
        .s_axi_wvalid  (m_axi_wvalid),
        .s_axi_wready  (m_axi_wready),
        .s_axi_bresp   (m_axi_bresp),
        .s_axi_bvalid  (m_axi_bvalid),
        .s_axi_bready  (m_axi_bready),
        .s_axi_araddr  (m_axi_araddr[11:0]),
        .s_axi_arvalid (m_axi_arvalid),
        .s_axi_arready (m_axi_arready),
        .s_axi_rdata   (m_axi_rdata),
        .s_axi_rresp   (m_axi_rresp),
        .s_axi_rvalid  (m_axi_rvalid),
        .s_axi_rready  (m_axi_rready),
        .ctrl          (ctrl),
        .status        (status_aclk),
        .snap_locked   (snap_locked),
        .snap_errs     (snap_errs),
        .snap_injected (snap_injected)
    );

    // ------------------------------------------------------------------ transceiver
    wire refclk;
    IBUFDS_GTE4 #(
        .REFCLK_EN_TX_PATH  (1'b0),
        .REFCLK_HROW_CK_SEL (2'b00),
        .REFCLK_ICNTL_RX    (2'b00)
    ) u_refclk_buf (
        .I     (sfp_mgt_refclk_p),
        .IB    (sfp_mgt_refclk_n),
        .CEB   (1'b0),
        .O     (refclk),
        .ODIV2 ()
    );

    wire tx_usrclk2, rx_usrclk2;
    wire userclk_tx_active, userclk_rx_active;
    wire reset_tx_done, reset_rx_done, rx_cdr_stable;
    wire gtpowergood, txpmaresetdone, rxpmaresetdone;
    wire rxprbserr, rxprbslocked;
    wire txprbsforceerr;
    wire rx_clear;

    gt_sfp u_gt (
        .gtwiz_userclk_tx_reset_in          (~txpmaresetdone),
        .gtwiz_userclk_tx_srcclk_out        (),
        .gtwiz_userclk_tx_usrclk_out        (),
        .gtwiz_userclk_tx_usrclk2_out       (tx_usrclk2),
        .gtwiz_userclk_tx_active_out        (userclk_tx_active),
        .gtwiz_userclk_rx_reset_in          (~rxpmaresetdone),
        .gtwiz_userclk_rx_srcclk_out        (),
        .gtwiz_userclk_rx_usrclk_out        (),
        .gtwiz_userclk_rx_usrclk2_out       (rx_usrclk2),
        .gtwiz_userclk_rx_active_out        (userclk_rx_active),
        .gtwiz_reset_clk_freerun_in         (aclk),
        .gtwiz_reset_all_in                 (ctrl[0] | ~aresetn),
        .gtwiz_reset_tx_pll_and_datapath_in (1'b0),
        .gtwiz_reset_tx_datapath_in         (1'b0),
        .gtwiz_reset_rx_pll_and_datapath_in (1'b0),
        .gtwiz_reset_rx_datapath_in         (1'b0),
        .gtwiz_reset_rx_cdr_stable_out      (rx_cdr_stable),
        .gtwiz_reset_tx_done_out            (reset_tx_done),
        .gtwiz_reset_rx_done_out            (reset_rx_done),
        .gtwiz_userdata_tx_in               (64'd0),
        .gtwiz_userdata_rx_out              (),
        .gtrefclk00_in                      (refclk),
        .qpll0outclk_out                    (),
        .qpll0outrefclk_out                 (),
        .gthrxn_in                          (sfp_rx_n),
        .gthrxp_in                          (sfp_rx_p),
        .rxprbscntreset_in                  (rx_clear),
        .rxprbssel_in                       (PRBS31),
        .txprbsforceerr_in                  (txprbsforceerr),
        .txprbssel_in                       (PRBS31),
        .gthtxn_out                         (sfp_tx_n),
        .gthtxp_out                         (sfp_tx_p),
        .gtpowergood_out                    (gtpowergood),
        .rxpmaresetdone_out                 (rxpmaresetdone),
        .rxprbserr_out                      (rxprbserr),
        .rxprbslocked_out                   (rxprbslocked),
        .txpmaresetdone_out                 (txpmaresetdone)
    );

    assign sfp_tx_disable = 1'b0;

    // ------------------------------------------------------------------ TX domain: error injection
    wire inject_tog_tx, clear_tx;
    cdc_sync #(.WIDTH(2)) u_sync_tx (.clk(tx_usrclk2), .d({ctrl[2], ctrl[1]}), .q({inject_tog_tx, clear_tx}));

    reg        inject_tog_tx_d = 1'b0;
    reg        force_err       = 1'b0;
    reg [31:0] injected        = 32'd0;
    always @(posedge tx_usrclk2) begin
        inject_tog_tx_d <= inject_tog_tx;
        force_err       <= inject_tog_tx ^ inject_tog_tx_d;
        if (clear_tx)
            injected <= 32'd0;
        else if (force_err)
            injected <= injected + 1'b1;
    end
    assign txprbsforceerr = force_err;

    // ------------------------------------------------------------------ RX domain: counters
    wire snap_tog_rx;
    cdc_sync #(.WIDTH(2)) u_sync_rx (.clk(rx_usrclk2), .d({ctrl[3], ctrl[1]}), .q({snap_tog_rx, rx_clear}));

    reg        snap_tog_rx_d = 1'b0;
    reg [47:0] locked_cycles = 48'd0;
    reg [31:0] err_cycles    = 32'd0;
    reg        err_seen      = 1'b0;
    always @(posedge rx_usrclk2) begin
        snap_tog_rx_d <= snap_tog_rx;
        if (rx_clear) begin
            locked_cycles <= 48'd0;
            err_cycles    <= 32'd0;
            err_seen      <= 1'b0;
        end else if (rxprbslocked) begin
            locked_cycles <= locked_cycles + 1'b1;
            if (rxprbserr) begin
                err_cycles <= err_cycles + 1'b1;
                err_seen   <= 1'b1;
            end
        end
        if (snap_tog_rx ^ snap_tog_rx_d) begin
            snap_locked   <= {16'd0, locked_cycles};
            snap_errs     <= err_cycles;
            snap_injected <= injected;   // TX counter: quasi-static, read only for reporting
        end
    end

    // ------------------------------------------------------------------ status -> aclk
    wire [8:0] status_sync;
    cdc_sync #(.WIDTH(9)) u_sync_status (
        .clk (aclk),
        .d   ({userclk_rx_active, userclk_tx_active, rx_cdr_stable, snap_tog_rx_d,
               err_seen, rxprbslocked, reset_rx_done, reset_tx_done, gtpowergood}),
        .q   (status_sync)
    );
    assign status_aclk = {23'd0, status_sync};

    // ------------------------------------------------------------------ LEDs
    reg [26:0] hb = 27'd0;
    always @(posedge aclk) hb <= hb + 1'b1;

    assign led[0]     = hb[26];
    assign led[1]     = status_sync[2];
    assign sfp_led[0] = rxprbslocked;
    assign sfp_led[1] = err_seen;
endmodule
