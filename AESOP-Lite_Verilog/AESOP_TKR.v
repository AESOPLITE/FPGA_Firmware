// Spartan-6 FPGA code for the AESOP tracker board.
// Robert P. Johnson    June 29, 2015
//
// Reading registers: only 1 board may be addressed, no wildcard.  
//
// V20 Added TOT output for calibration.  March 14, 2016
// V23 Added trigger command.  April 1, 2016
// V24 Added notification of trigger via UART.  April 13, 2016
// V25 Added debugging output.  May 12, 2016
// V27 Try to make calibration events work with more than one layer in the system.  May 28, 2016
// V35 Added ASIC auto initialization
// V38 Protect against read commands being sent with no prior trigger.  August 3, 2016
// V46 Added timeout in the trigger logic
// V47 Initialize ASICs automatically whenever an ASIC reset occurs, and force Trigger to be 1 clock cycle long.  November 1, 2016
// V49 Added a board identifier that can be read back, to verify programming of the ASIC default configuration.  November 23, 2016
// V50 Modified FPGA and ASIC defaults per Brian's suggestions.  January 5, 2017
// V51 Major revision to triggering to add TrigSrc=4, which waits for a GO following a tracker internal trigger. January 29, 2017
// V52 Added the redundant trigger and trigger word.  February 9, 2017
// V65 Communication of buffer status from all layers to make trigger source 4 operation work
// V76 First version in which trigger source 4 operation works without hanging
// V77 Add 3 zeroes at the beginning of the FPGA data header
// V78 Add measurement of the internal single-layer trigger rate
// V79 Modify default settings
// V80 Remove timeouts in the trigger state machine
// V81 Add choice (command x6E) for what trigger to count (for debugging work)
// V82 Change board not used in trigger to be address 5 (last in bending plane)
// V85 Hold the trigger information for an additional clock cycle so that it is never missed by the latch
// V86 Modified the Master only to save the trigger information before the trigger delay is implemented
// V87 Increased ASIC I/O current to setting-3 and modified timing to receive ASIC data in FPGA (inverted clock)

 module AESOP_TKR (Debug1, Debug2, Debug3, Debug4, Debug5, Debug6, ResetExt, SysCLK, TxD_start, TxD_data, TxD_busy, RxD_data_ready, RxD_data,
          TrigExt, TrigNextLyr, BrdAddress, ASICpower, CmdIn, CmdNextLyr, DataIn1, DataOut,
          ASICdata, TReq, TrigPrimIn1, TrigPrimIn2, TrigPrimOut, HardReset, CmdASIC, Tack, SDAin, SDAout, SDAen, SCLout, SCLen);

input SysCLK;               // 10 MHz system clock
input TxD_busy;             // Signal from the UART transmitter to wait to go low before sending another byte
output TxD_start;           // Signal that a byte of data is ready in TxD_data
output [7:0] TxD_data;      // Byte of data to send by UART
input RxD_data_ready;       // Signal that a byte of data is available in RxD_data from the UART receiver
input [7:0] RxD_data;       // Byte of incoming data from the UART
input TrigExt;              // Trigger signal received from the experiment trigger logic and clock aligned.
                            // For slave boards it is received from the previous board.
output TrigNextLyr;         // Trigger acknowlege going out to the next board up
input ResetExt;             // 1-Clock cycle reset signal, affects only the command decoder (not used, except in simulation)
input [3:0] BrdAddress;     // bits 2:0 are address of this tracker board, bit 3 indicates master         
output ASICpower;           // Power on/off for the ASIC analog section
input CmdIn;                // Command stream sent from the previous board (if not Master)
output CmdNextLyr;          // Command stream going to the next higher board
input  DataIn1;             // Serial data stream from the next higher board
output DataOut;             // Serial data stream to the next lower board (if this is not the master)
input [11:0] ASICdata;      // Serial data streams from the board's 12 ASICs
input [11:0] TReq;          // Trigger FAST-OR primitives from the 12 ASICs
output TrigPrimOut;         // Output trigger primitive to next layer down
input TrigPrimIn1;          // Input trigger primitive from previous layer up
input TrigPrimIn2;          // Second trigger from a previous layer (used by the Master only)
output HardReset;           // Hard reset pulse going out to the 12 ASICs
output CmdASIC;             // Serial command stream going out to the 12 ASICs
output Tack;                // Trigger 3-bit signals going out to the 12 ASICs
input SDAin;                // i2c data coming in from the monitoring chips
output SDAout;              // i2c commands going out to the monitoring chips
output SDAen;               // set high to enable SDAout
output SCLout;              // i2c clock going out to the monitoring chips
output SCLen;                // enable for SCLout
output Debug1, Debug2, Debug3, Debug4;
input  Debug5, Debug6;

parameter [7:0] Version = 8'd87;  // !!!Check whether the ASIC initialization routine is engaged!!!!

reg TxD_start;
reg [7:0] TxD_data;
reg ASICpower;                 
reg HardReset;
reg Trigger;                   // Combined trigger
reg randomTrig;                // Trigger by command, for noise occupancy measurements
reg ResetLocal;                // Reset the FPGA state machines, except command decoder
reg TOTdata;
reg [7:0] TrgDly;              // Delay in clock periods of output trigger pulse   

reg [2:0] NBfull;              // Count of the number of ASIC buffers full
reg [7:0] NBufOverFlow;
reg [7:0] NBufFill;

// Buffer management check for debugging only
always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        NBfull <= 0;
        NBufOverFlow <= 0;
        NBufFill <= 0;
    end else begin
        if ((StateTg == TackTg && CntTag == 3) && !BufClr) begin
            NBfull <= NBfull + 1;
            $display("%g\t AESOP_TKR %h: ASIC buffer count increases to %d",$time,BrdAddress,NBfull+1);
            if (NBfull == 3) NBufFill <= NBufFill + 1;
            if (NBfull == 4) NBufOverFlow <= NBufOverFlow + 1;    // This should never increment
        end
        if (BufClr && !(StateTg == TackTg && CntTag == 3)) begin
            NBfull <= NBfull - 1;
            $display("%g\t AESOP_TKR %h: ASIC buffer count decreases to %d",$time,BrdAddress,NBfull-1);
        end
    end
end

// Keep track of whether dumping of an event is still in progress
reg DmpPending;
always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        DmpPending <= 1'b0;
    end else begin
        if (DmpTheEvent) DmpPending <= 1'b1;
        if (EvtDumped) DmpPending <= 1'b0;
    end
end

wire [7:0] LclConfig;          // Local configuration register
                               //     Bit-0 = ASICpower
                               //     Bit-1 = Trigger type
                               //     Bit-2 = Trigger mask
                               //     Bit-3 = Trigger enable
                               //     Bit-4 = end status (is this board the end of the trigger chain?)
                               //     Bit-5 = dual trigger (are both trigger-primitive inputs used?).  Only relevant for the master board
							   //     Bit-6 = choice of trigger to count for command x6C

assign LclConfig[0] = ASICpower;
assign LclConfig[1] = TrgLogic;
assign LclConfig[2] = TrgMask;
assign LclConfig[3] = trgEnable;
assign LclConfig[4] = endStatus;
assign LclConfig[5] = dualTrig;
assign LclConfig[6] = trgCntrChoice;

wire Master;
assign Master = BrdAddress[3];      // Set true if the code is running in the master FPGA

reg DataOut;
reg [15:0] CmdCount;

// Make sure the inputs of the top board are not undefined
reg DataIn, TrigPrimInSafe;
always @ (DataIn1 or TrigPrimIn1 or TrgLogic or BrdAddress or NTkrLyr or endStatus) begin
    if (endStatus) begin
        if (TrgLogic) begin
            TrigPrimInSafe = 1'b0;   // OR logic
        end else begin
            TrigPrimInSafe = 1'b1;   // AND logic
        end
     end else begin
        TrigPrimInSafe = TrigPrimIn1;
     end
    if (BrdAddress[2:0] == (NTkrLyr[2:0]-1)) begin
        DataIn = 1'b0;
    end else begin
        DataIn = DataIn1;
    end
end

always @ (posedge TrigPrimIn1) $display("%g\t AESOP_TKR %h: TrigPrimIn1 fires.",$time,BrdAddress);
always @ (posedge TrigPrimInSafe) $display("%g\t AESOP_TKR %h: TrigPrimInSafe fires.",$time,BrdAddress);
always @ (posedge TrigPrimIn2) $display("%g\t AESOP_TKR %h: TrigPrimIn2 fires.",$time,BrdAddress);
always @ (posedge TrigPrimOut) $display("%g\t AESOP_TKR %h: TrigPrimOut fires.",$time,BrdAddress);

reg [3:0] nRegData;
reg [7:0] RegData[0:10];
reg [3:0] lenData;
reg ConfigReset;

// Multiplex the command output
reg CmdNextLyr;
always @ (CmdRepeat or Master or CmdIn or CmdUp or StateTg or TrigSrc) begin
    if (Master) begin
        if (TrigSrc == 4 && (StateTg == WtGoTg || StateTg == SnRdTg || StateTg == DpEvTg)) CmdNextLyr = CmdUp[16];
        else CmdNextLyr = CmdRepeat;
    end else CmdNextLyr = CmdIn;
end

// State machines to handle the incoming trigger signal

reg [7:0] TrigDly;             // Global trigger delay, in clock cycles
reg [7:0] TrigLen;             // Always set to unity now. Do not change.

// Delay (from command x06) and clipping of the external trigger signal (GO signal)
TrgStretch TrgStrchGLB(.Clock(SysCLK),.Reset(ResetLocal),.TReqIn(TrigExt),.TrgPls(TrigStrch),.TrgLen(TrigLen),.TrgDly(TrigDly),.Address(BrdAddress));
assign GoSignal = TrigStrch; 

// Clip the local trigger to one clock cycle and delay it by a programmed amount (from command x61) in just the master board (slaves should not use TrgPrmOutClip)
TrgStretch TrgStrchLCL(.Clock(SysCLK), .Reset(ResetLocal), .TReqIn(TrigPrimOut), .TrgPls(TrgPrmOutClip), .TrgLen(TrigLen), .TrgDly(TrgDly), .Address(BrdAddress));

reg trgCntrChoice;
reg trgToCnt;
always @ (trgCntrChoice or TrgPrmOutClip or TrgStrch) begin
	if (trgCntrChoice) begin
		trgToCnt = TrgPrmOutClip;
	end else begin
		trgToCnt = TrgStrch;
	end
end

reg [7:0] TrigSrc;
always @ (Master or TrigExt or trgEnable or TrigStrch or TrigSrc or TrgPrmOutClip) begin
    if (Master) begin
        if (TrigSrc == 0) Trigger = TrigStrch & trgEnable;
        else if (TrigSrc == 1) Trigger = (TrigStrch & TrgPrmOutClip) & trgEnable;
        else if (TrigSrc == 2) Trigger = (TrigStrch | TrgPrmOutClip) & trgEnable;
        else Trigger = TrgPrmOutClip & trgEnable;  // for TrigSrc==3 or TrigSrc==4
    end else begin
       Trigger = TrigExt & trgEnable;
    end  
end
always @ (TrigStrch or Master or BrdAddress) begin
    if (Master) $display("%g\t AESOP_TKR %h: external trigger = %b",$time,BrdAddress,TrigStrch);
end
always @ (posedge TrigExt) if (Master) $display("%g\t AESOP_TKR master: raw external trigger received.",$time,BrdAddress);
always @ (posedge Trigger) $display("%g\t AESOP_TKR %h: main trigger fires. TrigExt=%b, StateTg=%b",$time,BrdAddress,TrigExt,StateTg);

// State machine to save the trigger bits for readout in the event header (Master only)
parameter [2:0] WaitTt = 3'b001;    // Wait for the trigger signal
parameter [2:0] DoItTt = 3'b010;    // Wait for the trigger signal to go low again
parameter [2:0] HoldTt = 3'b100;    // Hold the data until read out
reg [1:0] StateTt, NextStateTt;
reg [1:0] TrgWord;
reg TrigPrimIn1allOld;
reg TrigPrimIn2Old;

always @ (StateTt or trgEnable or Master or TrigPrimOut or doneRdEvt or TrigSrc or StateTg) begin
	case (StateTt)
	    WaitTt: begin
		            if (Master & trgEnable & TrigPrimOut) NextStateTt = DoItTt;
					else NextStateTt = WaitTt;
		        end
		DoItTt: begin
		            if (TrigPrimOut) NextStateTt = DoItTt;
					else begin
					    if (TrigSrc == 3 || TrigSrc == 4) NextStateTt = HoldTt;
						NextStateTt = WaitTt;
					end
		        end
		HoldTt: begin
					if (doneRdEvt || StateTg == DpEvTg) NextStateTt = WaitTt;
					else NextStateTt = HoldTt;
		        end
	    default: NextStateTt = WaitTt;
	endcase
end

always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        StateTt <= WaitTt;
		TrgWord <= 2'b00;
    end else begin    
	    StateTt <= NextStateTt;
		TrigPrimIn1allOld <= TrigPrimIn1all;  // Make sure that the trigger status gets held onto for one more clock cycle, to give us time to latch it
		TrigPrimIn2Old <= TrigPrimIn2;
		case (StateTt)
			WaitTt: begin
						if (NextStateTt == DoItTt) begin
                            TrgWord[1] <= TrigPrimIn1all | TrigPrimIn1allOld;    // Save the status of the two redundant tracker triggers
                            TrgWord[0] <= TrigPrimIn2 | TrigPrimIn2Old;
						end
			        end
			DoItTt: begin
						TrgWord[1] <= TrigPrimIn1all | TrigPrimIn1allOld | TrgWord[1];  // Keep looking, in case one rises later than the other
						TrgWord[0] <= TrigPrimIn2 | TrigPrimIn2Old | TrgWord[0];
			        end
		endcase
	end
end


// State machine to send the trigger acknowledge signals out to the 12 ASICs on each layer

parameter [9:0] WaitTg = 10'b0000000001;      //Wait for the trigger signal
parameter [9:0] DlayTg = 10'b0000000010;      //Delay according to board address, to line up all triggers in time
parameter [9:0] TackTg = 10'b0000000100;      //Shift out the 3-bit trigger code to the ASICs
parameter [9:0] BusyTg = 10'b0000001000;      //Wait for UART not to be busy (only for trigger source 3)
parameter [9:0] UartTg = 10'b0000010000;      //Notify the computer that a trigger occured (only for trigger source 3)
parameter [9:0] WtGoTg = 10'b0000100000;      //Wait around for a tardy GO signal (external trigger) for trigger source 4
parameter [9:0] SnRdTg = 10'b0001000000;      //Send a read command to ASICs if the GO signal never arrived
parameter [9:0] DpEvTg = 10'b0010000000;      //Delete the event data if the GO signal never arrived, by sending a dump command to TkrDataMerge
parameter [9:0] WtRdTg = 10'b0100000000;      //Wait for a free ASIC buffer before re-enabling the trigger after the GO signal failed to arrive
parameter [9:0] DeadTg = 10'b1000000000;      //Wait for the readout to be completed
reg [9:0] StateTg, NextStateTg;
reg [2:0] CntTg, TackReg;
reg [1:0] TrgTag, CntTag;
wire [1:0] TrgTagP1;
assign TrgTagP1 = TrgTag + 1;
reg Tack;
reg [7:0] NMissedTg;                  //Count missed triggers 
reg [15:0] NMissedGo;                 //Count missed GO signals for trigsrc=4
reg [15:0] TriggerCnt;                //Count of internal triggers
reg TrigNextLyr;
reg trgEnable;
reg TxD_startTg;
parameter [7:0] TxD_dataTg = 8'b10101011;
reg [1:0] CntDlyTg;

reg readoutPending;
reg readCMDseen;
reg [6:0] CntGo;
reg [6:0] MxWaitGO;

always @ (StateTg or GO or Both or CntGo or MxWaitGO or GoSignal or RxD_data_ready or TrigSrc or State or CntDlyTg or CntTg or TxD_busy or Trigger or randomTrig or BrdAddress or Master or TackReg or StateEv or doneRdEvt or CntTag) begin
    case (StateTg) 
        WaitTg: begin
                    if (Trigger | randomTrig) begin 
                        NextStateTg = DlayTg;
                    end else NextStateTg = WaitTg;
                    Tack = 1'b0;
                    TrigNextLyr = Trigger | randomTrig;  // The next layer will latch this trigger on the following clock cycle
                end
        DlayTg: begin  //Delay trigger one less clock cycle for each layer going up, to compensate for clock delays
                    if (CntTg == BrdAddress[2:0]) NextStateTg = TackTg;
                    else NextStateTg = DlayTg;
                    Tack = 1'b0;
                    TrigNextLyr = 1'b0;
                end
        TackTg: begin
                    if (CntTag == 3) begin
                        if (Master) begin
                            if (TrigSrc == 3) NextStateTg = BusyTg;
                            else if (TrigSrc == 4) begin
                                if (GO | GoSignal) NextStateTg = DeadTg;
                                else NextStateTg = WtGoTg;
                            end else NextStateTg = DeadTg;
                        end else NextStateTg = WaitTg;
                    end else NextStateTg = TackTg;
                    Tack = TackReg[2];
                    TrigNextLyr = 1'b0;
                end
        BusyTg: begin   // Don't send the trigger byte to the UART if it is busy in any way (internal test trigger)
                    if (TxD_busy || !(State == Wait || State == RdEv) || RxD_data_ready) NextStateTg = BusyTg;
                    else NextStateTg = UartTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        UartTg: begin
                    if (CntDlyTg == 3) NextStateTg = DeadTg;
                    else NextStateTg = UartTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        WtGoTg: begin
                    if (GoSignal) NextStateTg = DeadTg;
                    else if (CntGo > MxWaitGO) NextStateTg = SnRdTg;
                    else NextStateTg = WtGoTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        SnRdTg: begin
                    if (CntGo == 106) NextStateTg = DpEvTg;    // Send a read signal to all ASICs if no GO signal ever showed up
                    else NextStateTg = SnRdTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        DpEvTg: begin   // Dump the event from this layer and send command to the other layers to do the same
                    if (CntGo == 20) NextStateTg = WtRdTg;
                    else NextStateTg = DpEvTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        WtRdTg: begin   // Make sure that the ASICs are ready for another trigger before reenabling the trigger
                    if (Both == 2'b11) NextStateTg = WaitTg;
                    else NextStateTg = WtRdTg;
                    TrigNextLyr = 1'b0;
                    Tack = 1'b0;
                end
        DeadTg: begin
                    if (doneRdEvt) NextStateTg = WaitTg;
                    else NextStateTg = DeadTg;
                    Tack = 1'b0;
                    TrigNextLyr = 1'b0;   // Master blocks trigger from next layers while awaiting readout completion
                end
        default: begin
                     NextStateTg = WaitTg;
                     Tack = 1'b0;
                     TrigNextLyr = 1'b0;
                 end
    endcase
end

reg GO, MstrDmpEv;
reg [12:0] CmdRd;
reg [16:0] CmdUp;
reg [15:0] countGos;
reg [15:0] CntDump;
reg [15:0] nEvent;
reg [1:0] Both;
reg [15:0] CntDump2;
always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        StateTg <= WaitTg;
        TrgTag <= 2'b11;
        TriggerCnt <= 0;
        readoutPending <= 1'b0;
        GO <= 1'b0;
        MstrDmpEv <= 1'b0;
        NMissedTg <= 0;
        NMissedGo <= 0;
        countGos <= 0;
        CntDump <= 0;
    end else begin    
        if (Trigger) $display("time StateTg CntTg TackReg TrgTag Tack CntGo GO GoSignal     CmdRd      CmdUp NBfull DataIn");
        if (Master && StateTg != WaitTg && !(StateTg == DeadTg && NextStateTg==DeadTg)) $display("%g\t %b %h      %b      %h     %b  %d %b  %b    %b %b %d   %b",$time,StateTg,CntTg,TackReg,TrgTag,Tack,CntGo,GO,GoSignal,CmdRd,CmdUp,NBfull,DataIn);
        StateTg <= NextStateTg;
        if (GoSignal) countGos <= countGos + 1;
        if (StateTg == WaitTg && NextStateTg == DlayTg) readoutPending <= 1'b1;
        else if (readCMDseen) readoutPending <= 1'b0;
        case (StateTg)
            WaitTg: begin
                        TxD_startTg <= 1'b0;
                        CntGo <= 0;
                        CntTg <= 3'b111;
                        CntTag <= 2'b00;
                        if (NextStateTg == DlayTg) begin
                            TackReg <= {1'b1,TrgTagP1};
                            TriggerCnt <= TriggerCnt + 1;
                            if (GoSignal) GO <= 1'b1;
                            $display("%g\t AESOP_TKR %h: Trigger state machine received a trigger; going to state DlayTg. TrigNextLyr=%b",$time,BrdAddress,TrigNextLyr);
                            $display("%g\t AESOP_TKR %h: Trigger word is %b%b",$time,BrdAddress,TrigPrimIn1all,TrigPrimIn2);
                            TrgTag <= TrgTagP1;
                        end else begin
                            GO <= 1'b0;
                            if (GoSignal) NMissedGo <= NMissedGo + 1;
                        end
                    end
            DlayTg: begin
                        CntTg <= CntTg - 1;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        if (GoSignal) GO <= 1'b1;
                    end
            TackTg: begin
                        if (CntTag == 0) $display("%g\t AESOP_TKR %h: send trigger %b to ASICs",$time,BrdAddress,TackReg);
                        CntTag <= CntTag + 1;
                        TackReg <= {TackReg[1:0],1'b0};
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        CntDlyTg <= 0;
                        if (GoSignal) GO <= 1'b1;
                    end
            BusyTg: begin
                        if (NextStateTg == UartTg) TxD_startTg <= 1'b1;
                    end
            UartTg: begin
                        CntDlyTg <= CntDlyTg + 1;
                    end
            WtGoTg: begin                    
                        if (NextStateTg == SnRdTg) begin
                            CmdRd <= {10'b1111110010,TrgTag[0]^TrgTag[1],TrgTag};  // Load up the Read command for the master board
                            CmdUp <= 17'b10111000000010001;  // Load up a serial Read command for the boards up above (data byte is all zeros, so not included) 
                            CntGo <= 1'b0;
                        end else CntGo <= CntGo +1;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        if (GoSignal) $display("%g\t AESOP_TKR %h: Go signal received in time.",$time,BrdAddress);
                    end
            SnRdTg: begin
                        CmdRd <= {CmdRd[11:0],1'b0};   // Shift a Read command to the ASICs of the master board
                        CmdUp <= {CmdUp[15:0],1'b0};
                        if (NextStateTg == DpEvTg) begin
                            CntDump <= CntDump + 1;
                            MstrDmpEv <= 1'b1;
                            CmdUp <= 17'b10111010100110000;  // Load up a serial command to the upper layers to delete the event; no data bytes
                            CntGo <= 0;
                        end else CntGo <= CntGo + 1;
                        if (GoSignal) NMissedGo <= NMissedGo + 1;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        Both <= 2'b00;
                    end
            DpEvTg: begin
                        MstrDmpEv <= 1'b0;
                        CmdUp <= {CmdUp[15:0],1'b0};   // Shift a command out to the upper layers to delete the event
                        CntGo <= CntGo + 1;
                        if (GoSignal) NMissedGo <= NMissedGo + 1;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        if (DataIn | NTkrLyr[2:0]==1) Both[1] <= 1'b1;   // Signal from the layer above
                    end
            WtRdTg: begin   // Make sure that the ASICs are ready for another trigger before reenabling the trigger
                        if (DataIn | NTkrLyr[2:0]==1) Both[1] <= 1'b1;
                        if (!DmpPending) Both[0] <= 1'b1;
                        if (GoSignal) NMissedGo <= NMissedGo + 1;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                    end
            DeadTg: begin                        
                        TxD_startTg <= 1'b0;
                        if (Trigger) NMissedTg <= NMissedTg + 1;
                        if (GoSignal) NMissedGo <= NMissedGo + 1;                         
                    end
        endcase
    end
end

// Merge the data flowing from the 12 ASICs using code from the pCT system
wire [15:0] NevtMerge;
wire [47:0] MergeErrors;
reg [11:0] ASICmask;
wire [15:0] ASICdataMSK, TReqMSK;
reg [11:0] DataToMerge;
reg SendEvt;
assign ASICdataMSK[11:0] = ASICdata & ASICmask;
assign TReqMSK = TReq & ASICmask;
assign DmpTheEvent = MstrDmpEv | LclDmpEvt;
wire [3:0] ErrorCode1;
TkrDataMerge TkrDataMerge_U(.ErrorOut(MergeError),.Nevent(NevtMerge),.MergeDataOut(MergedData),.BufClrAll(BufClr),.ErrBuf(MergeErrors),
                            .Clock(SysCLK),.Reset(ResetLocal),.DataIn(DataToMerge),.Address(BrdAddress),.SendEvt(SendEvt),.DumpEvt(DmpTheEvent),.Mask(ASICmask),.DmpEvt(EvtDumped),.ErrCode(ErrorCode1[3:0]));            
                            
// Trigger logic for forming the output trigger primitive                            
reg TrgLogic;          // 0 for AND logic, 1 for OR logic between this layer and the layers above
reg TrgMask;           // 1 to include this layer in the trigger primitive
reg [7:0] TrgLen;      // Length of output trigger pulse
reg endStatus;         // 1 if this board starts the trigger logic chain, 0 otherwise

// Logical OR of the trigger request signals from all 12 chips                         
assign TriggerOR = TReqMSK[0] | TReqMSK[1] | TReqMSK[2] | TReqMSK[3] | TReqMSK[4] | TReqMSK[5] | TReqMSK[6] | TReqMSK[7] | TReqMSK[8] | TReqMSK[9] | TReqMSK[10] | TReqMSK[11];    
always @ (posedge TriggerOR) $display("%g\t AESOP_TKR %h: trigger-OR primitive, TReqMSK=%b",$time,BrdAddress,TReqMSK);

// Stretch the trigger primitive in preparation for boolean logic, but do not delay it                      
TrgStretch TrgStrchOR(.Clock(SysCLK),.Reset(ResetLocal),.TReqIn(TriggerOR),.TrgPls(TrgStrch),.TrgLen(TrgLen),.TrgDly(8'h00),.Address(BrdAddress));                            

// Combine the trigger from the layer above with the trigger from this layer, and pass it to the layer below
reg TrigPrimOut, TrigPrimIn1all;
reg dualTrig;
always @ (TrgStrch or TrigPrimInSafe or TrgLogic or TrgMask or TrigPrimIn2 or Master or dualTrig) begin
    if (TrgLogic) begin
        TrigPrimIn1all = (TrgStrch & TrgMask) | TrigPrimInSafe;
    end else begin
        TrigPrimIn1all = (TrgStrch | !TrgMask) & TrigPrimInSafe;
    end
    if (Master) begin
        if (dualTrig) TrigPrimOut = TrigPrimIn1all | TrigPrimIn2;     // OR of the two redundant triggers
        else TrigPrimOut = TrigPrimIn1all;
    end else TrigPrimOut = TrigPrimIn1all;
end 
//always @ (posedge TriggerOR) begin
//    $display("%g\t AESOP_TKR %h: internal TriggerOR fires.",$time,BrdAddress);
//end
//always @ (posedge TrgStrch) begin
//	$display("%g\t AESOP_TKR %h: TrgStrch fires.",$time,BrdAddress);
//end
//always @ (posedge TrigPrimIn1all) $display("%g\t AESOP_TKR %h: TrigPrimIn1all fires.",$time,BrdAddress);

// Register to hold an ASIC command to be shifted out to the chips
// Bits 74:64 are start, address, command, parity
// Bits 63:56 are the first data byte
// Bits 55:48 are the second data byte
// etc.
reg [74:0] CmdStrng;         

// Multiplex the UART transmitter signals
reg TxD_startEcho;  
reg [7:0] TxD_dataEcho;
always @ (TxD_startEv or TxD_dataEv or TxD_startEcho or TxD_dataEcho or StateEv or State or TxD_startRAM or TxD_dataRAM or TrigSrc or StateTg or TxD_startTg) begin
    if (TrigSrc == 3 && (StateTg == UartTg || StateTg == BusyTg)) begin   
        TxD_start = TxD_startTg;
        TxD_data = TxD_dataTg;
    end else if (StateEv == ChCkEv || StateEv == HeadEv) begin
        TxD_start = TxD_startEv;
        TxD_data = TxD_dataEv;
    end else if (State == Echo || State == Ech1) begin
        TxD_start = TxD_startEcho;
        TxD_data = TxD_dataEcho;
    end else begin
        TxD_start = TxD_startRAM;
        TxD_data = TxD_dataRAM;
    end
end

// This routine will send a sequence of commands to the ASICs to set their default register values following a reset
reg GoInitialize;
wire [7:0] BoardID;
//assign DoneInit = 1'b1;   // TEMPORARY FOR DEBUGGING!!!!!!!!!!!!!!!! So simulations don't take forever.
//TKRinitial InitializeASICS(.Clock(SysCLK), .Reset(ResetLocal), .Go(1'b0), .CMD(CMDinit), .Done(DoneDummy), .Version(BoardID));
TKRinitial InitializeASICS(.Clock(SysCLK), .Reset(ResetLocal), .Go(GoInitialize), .CMD(CMDinit), .Done(DoneInit), .Version(BoardID));
// State machine to receive the command stream and decode the commands sent to the Master board by the UART interface

parameter [30:0] Wait = 31'b0000000000000000000000000000001;        // Wait for the first Byte of command data (address)
parameter [30:0] GtB2 = 31'b0000000000000000000000000000010;        // Get the second Byte of command data (command code)
parameter [30:0] GtB3 = 31'b0000000000000000000000000000100;        // Get the third Byte of command data (number of data Bytes)
parameter [30:0] GtDB = 31'b0000000000000000000000000001000;        // Get the N data Bytes from the command stream
parameter [30:0] Deco = 31'b0000000000000000000000000010000;        // Decode the command and execute the requested action
parameter [30:0] ACmd = 31'b0000000000000000000000000100000;        // Shift a command out to the ASICs
parameter [30:0] RegO = 31'b0000000000000000000000001000000;        // Output register information
parameter [30:0] RegT = 31'b0000000000000000000000010000000;        // Fill in type of register output
parameter [30:0] RegD = 31'b0000000000000000000000100000000;        // Fill in the register output data
parameter [30:0] Cnfg = 31'b0000000000000000000001000000000;        // Fill data into the ASIC configuration register
parameter [30:0] RdEv = 31'b0000000000000000000010000000000;        // Send out an event upon read command
parameter [30:0] Mask = 31'b0000000000000000000100000000000;        // Load ASIC mask registers
parameter [30:0] AddR = 31'b0000000000000000001000000000000;        // Shift in the command address from serial stream
parameter [30:0] CmdR = 31'b0000000000000000010000000000000;        // Shift in the command bits
parameter [30:0] NbyT = 31'b0000000000000000100000000000000;        // Read in the number of bytes
parameter [30:0] DatI = 31'b0000000000000001000000000000000;        // Read in the data bytes
parameter [30:0] LstD = 31'b0000000000000010000000000000000;        // Store the last data byte
parameter [30:0] CmdO = 31'b0000000000000100000000000000000;        // Start outputing a serial command stream from the master
parameter [30:0] Shft = 31'b0000000000001000000000000000000;        // Shift out the address, command, and number of data bytes
parameter [30:0] DatO = 31'b0000000000010000000000000000000;        // Shift out the data bytes
parameter [30:0] DUMP = 31'b0000000000100000000000000000000;        // Master dump data to the UART
parameter [30:0] AsRg = 31'b0000000001000000000000000000000;        // Receive register data from an ASIC
parameter [30:0] Buss = 31'b0000000010000000000000000000000;        // Hold the data output active while data are reading out
parameter [30:0] Echo = 31'b0000000100000000000000000000000;        // Echo the command
parameter [30:0] Ech1 = 31'b0000001000000000000000000000000;        // Echo the command
parameter [30:0] Scnd = 31'b0000010000000000000000000000000;        // Get the second command data byte
parameter [30:0] InaS = 31'b0000100000000000000000000000000;        // Send a command to an ina226 monitoring chip
parameter [30:0] InaR = 31'b0001000000000000000000000000000;        // Send a command to read an ina226 register
parameter [30:0] InSh = 31'b0010000000000000000000000000000;        // Shift out the i2c data
parameter [30:0] ACfg = 31'b0100000000000000000000000000000;        // Default initialization of ASICs
parameter [30:0] Evcl = 31'b1000000000000000000000000000000;        // Wait for ASIC buffers to be cleared when dumping an event

reg [30:0] State, NextState;
reg [23:0] CntTime;
reg [3:0] Address;
reg [7:0] Command;
reg [3:0] Ndata;
reg [6:0] CntZ;
reg [7:0] Cnt;
reg [3:0] ByteCnt;
reg [7:0] CmdData[0:15];
reg [4:0] ASICaddress;
reg [2:0] ToTFPGA;
reg [7:0] DatByte, NTkrLyr;
reg DataFlg;
reg StartRead;                 // Signal to start reading out event data 
wire doneRdEvt;                // Signal that event readout has completed
wire doneRdReg;                // Signal that register readout has completed
reg RegOut;                    // Signal to send out register information
reg CmdRepeat;                 // Serial repetition of the incoming UART command stream
reg CmdASIC, Prty, DOutMux;
reg DMPStart;
reg SendEvtThis;
reg [3:0] CntEcho;
reg StrobeIna;
reg [7:0] i2cAddr;                // Bits 6:0 are the i2c chip addres.  Bit 7 is not used.
reg [23:0] i2cData;
reg [17:0] i2cResults;
reg i2cRdCmd, ResetI2c;                    

assign doneRdEvt = (StateEv == DoneEv);
assign doneRdReg = (StateRg == WtDnRg && NextStateRg == WaitRg);

//always @ (posedge SysCLK) begin    
    //if (ASICdata != 0) $display("%g\t %d ASICdata=%b",$time,BrdAddress,ASICdata);
    //if (BrdAddress==1 && State == Wait && NextState == GtB2) $display("time AESOP_TKR:    Addr        State            CmdIn RxD_data_ready RxD_data Cnt Command Address Ndata This ByteCnt DatByte CmdRepeat  Address  Command   Ndata CmdASIC ASICdata DataOut DataIn CntZ CmdNextLyr DataToMerge TxD_start TxD_data");
    //if (BrdAddress==1 && State != Wait) $display("%g\t AESOP_TKR: %h   %b  %b      %b             %h   %d    %h       %h      %h    %b    %h   %b     %b        %b %b %b     %b %b    %b       %b  %d      %b          %b   %b      %b",$time,BrdAddress,State,CmdIn,RxD_data_ready,
    //                                        RxD_data,Cnt,Command,Address,Ndata,This,ByteCnt,DatByte,CmdRepeat,Address,Command,Ndata,CmdASIC,ASICdata,DataOut,DataIn,CntZ,CmdNextLyr,DataToMerge,TxD_start,TxD_data);
//end 

always @ (State or SgnlDmp or StateTg or CmdRd or StateTOT or ToTFPGA or ByteCnt or DMPDone or TOTdata or DataDone or ASICaddress or StrobeOutIna or i2cResults or CntEcho or TxD_busy or DatByte or DataFlg or CmdData[2]
                or BrdAddress or Address or CmdCount or CmdEv or MstrDataEv or RxD_data_ready or CntTime or Command or doneRdEvt or Cnt or This or lenData or RxD_data 
                or DoneInit or Ndata or doneRdReg or CmdIn or Master or CmdStrng or RegOutPut or All or DataIn or CntZ or ASICdataMSK or MergedData or CMDinit) begin
    if (State == ACmd && (This | All)) CmdASIC = CmdStrng[74];
    else begin
        if (State == ACfg && (This | All)) CmdASIC = CMDinit;  // Multiplex the command stream to the ASICs
        else if (StateTg == SnRdTg) CmdASIC = CmdRd[12];
        else CmdASIC = 1'b0;
    end
    case (State)
        Wait: begin    // Look for either the start of a UART transmission on RxD or the start of a serial bit stream on CmdIn
                  CmdRepeat = 1'b0;     // Serial command going to the next layer up, for master only (other layers just pass command in to command out)
                  DOutMux = 1'b0;       // Data streaming into the RAM buffer (master only)
                  DataOut = DataIn;     // Serial data going to the next layer down
                  DataToMerge = ASICdataMSK[11:0];      // 12 serial data streams going from ASICs to the merging program
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (RxD_data_ready) NextState = GtB2;
                      else NextState = Wait;
                  end else begin
                      if (CmdIn) NextState = AddR;
                      else NextState = Wait;
                  end
              end
        AddR: begin                          // State sequence for receiving synchronous serial command input
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;            // Format is start bit, 4 bits address, 8 bits command, 4 bits # data bytes, data bytes. . .
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt == 3) NextState = CmdR;
                  else NextState = AddR;
              end
        CmdR: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt == 11) NextState = NbyT;
                  else NextState = CmdR;
              end
        NbyT: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt == 15) begin
                      if (Ndata[2:0] == 3'b000 && CmdIn == 1'b0) NextState = Deco;
                      else NextState = DatI;
                  end else NextState = NbyT;
              end
        DatI: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt == 7 && ByteCnt == Ndata-1) NextState = LstD;
                  else NextState = DatI;
              end
        LstD: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  NextState = Deco;
              end
        GtB2: begin             // State sequence for receiving the UART command input (master only)
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (CntTime >= 65535) NextState = Wait;   // 6.6 ms timeout
                  else if (RxD_data_ready) NextState = GtB3;
                  else NextState = GtB2;
              end
        GtB3: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (CntTime == 65535) NextState = Wait;
                  else if (RxD_data_ready) begin
                      if (RxD_data[3:0] == 0) begin
					      if (Command == 8'h57) NextState = Deco;     // Don't repeat these commands to the non-master boards
						  else NextState = CmdO;					
                      end else NextState = GtDB;
                  end else NextState = GtB3;
              end
        GtDB: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (CntTime == 65535) NextState = Wait;
                  else if (RxD_data_ready) begin
                      if (Cnt == Ndata-1) begin
					      NextState = CmdO;
                      end else NextState = GtDB;
                  end else NextState = GtDB;
              end
        CmdO: begin
                  NextState = Shft;
                  CmdRepeat = 1'b1;    // Start bit for the outgoing command stream
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
              end
        Shft: begin
                  CmdRepeat = Address[3];     
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt == 15) begin
                      if (DataFlg) NextState = DatO;
                      else NextState = Deco;
                  end else NextState = Shft;
              end
        DatO: begin
                  CmdRepeat = DatByte[7];
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (ByteCnt == Ndata && Cnt == 7) NextState = Deco;
                  else NextState = DatO;
              end
        Echo: begin
                  case (CntEcho)
                      4'h1: TxD_dataEcho = 8'h4;
                      4'h2: TxD_dataEcho = 8'b11110001;
                      4'h3: TxD_dataEcho = CmdCount[15:8];
                      4'h4: TxD_dataEcho = CmdCount[7:0];
                      4'h5: TxD_dataEcho = Command;                      
                      default: TxD_dataEcho = 8'h3;
                  endcase
                  if (TxD_busy) NextState = Echo;
                  else begin                      
                      if (CntEcho == 5) begin
                          case (Command)
                              8'h05:  NextState = ACfg;
                              8'h0c:  NextState = ACmd;
                              8'h45:  NextState = InaS;
                              8'h10:  NextState = ACmd;
                              8'h11:  NextState = ACmd;
                              8'h12:  NextState = Cnfg;
                              8'h13:  NextState = Mask;
                              8'h14:  NextState = Mask;
                              8'h15:  NextState = Mask;
                              8'h26:  NextState = ACfg;
                              default: NextState = Wait;                                     
                          endcase
                      end else begin
                          NextState = Ech1;
                      end
                  end
                  DOutMux = 1'b0;
                  CmdRepeat = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
              end
        Ech1: begin
                  case (CntEcho)
                      4'h1: TxD_dataEcho = 8'h4;
                      4'h2: TxD_dataEcho = 8'b11110001;
                      4'h3: TxD_dataEcho = CmdCount[15:8];
                      4'h4: TxD_dataEcho = CmdCount[7:0];
                      4'h5: TxD_dataEcho = Command;                      
                      default: TxD_dataEcho = 8'h3;
                  endcase
                  if (Cnt == 3) NextState = Echo;
                  else NextState = Ech1;
                  DOutMux = 1'b0;
                  CmdRepeat = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
              end
        Deco: begin                   // Command input complete; now decode the command
                  CmdRepeat = 1'b0;
                  if ((This | All) && Command == 8'h02) begin
                      if (Master) begin
                          if (ToTFPGA==BrdAddress[2:0]) DOutMux = TOTdata;
                          else DOutMux = DataIn;
                          DataOut = DataIn;
                      end else begin
                          DOutMux = 1'b0;
                          if (ToTFPGA==BrdAddress[2:0]) DataOut = TOTdata;
                          else DataOut = DataIn;
                      end
                  end else begin
                      DOutMux = 1'b0;
                      DataOut = DataIn;
                  end
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  case (Command) 
                      8'h01:  begin     // Read Event:  wait until the event readout is complete; eventually go to passthrough mode if not addressed
                                  if (This | All) NextState = ACmd;  // Immediately send the read commands to the ASICs
                                  else NextState = Wait;     
                              end
                      8'h02:  NextState = ACmd;
                      8'h06:  NextState = Scnd;
                      8'h07:  NextState = RegT;
                      8'h0a:  NextState = RegT;
                      8'h0b:  NextState = RegT;
                      8'h0d:  begin
                                  if (Master & This) NextState = DUMP;
                                  else NextState = Wait;
                              end
                      8'h0e:  NextState = Scnd;
                      8'h1e:  NextState = RegT;
                      8'h1f:  NextState = RegT;
                      8'h20:  NextState = ACmd;
                      8'h21:  NextState = ACmd;
                      8'h22:  NextState = ACmd;
                      8'h23:  NextState = ACmd;
                      8'h24:  NextState = ACmd;
                      8'h25:  NextState = ACmd;
                      8'h46:  NextState = InaR;
                      8'h48:  NextState = RegT;
                      8'h52:  begin
                                  if (Master | !This) NextState = Wait; // This internal command should not be sent to the master!!
                                  else NextState = Buss;
                              end
                      8'h53:  NextState = Evcl;   // This is an internal command and should not produce an echo
                      8'h54:  NextState = RegT;
                      8'h55:  NextState = RegT;
                      8'h57:  NextState = RegT;
                      8'h58:  NextState = RegT;
                      8'h59:  NextState = RegT;
                      8'h5C:  NextState = RegT;
                      8'h60:  NextState = RegT;
                      8'h61:  NextState = Scnd;
                      8'h67:  NextState = Wait;   // The trigger command has no echo, to avoid making noise
                      8'h68:  NextState = RegT;
                      8'h69:  NextState = RegT;
                      8'h6A:  NextState = RegT;
                      8'h6B:  NextState = RegT;
					  8'h6C:  NextState = Wait;  // This command has no echo, to avoid making noise
					  8'h6D:  NextState = RegT;
                      8'h71:  NextState = RegT;
                      8'h73:  NextState = RegT;
                      8'h74:  NextState = RegT;
                      8'h75:  NextState = RegT;
                      8'h76:  NextState = RegT;
                      8'h77:  NextState = RegT;
					  8'h78:  NextState = RegT;
                      default: begin
                                   NextState = Echo;
                               end
                  endcase
              end
        Evcl: begin
                  if (SgnlDmp || CntTime == 24'h00ffff) NextState = Wait;
                  else NextState = Evcl;
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = SgnlDmp;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
              end
        ACfg: begin
                  if (DoneInit || CntTime == 24'hffffff) NextState = Wait;
                  else NextState = ACfg;
                  CmdRepeat = 1'b0;     // Serial command going to the next layer up, for master only (other layers just pass command in to command out)
                  DOutMux = 1'b0;       // Data streaming into the RAM buffer (master only)
                  DataOut = DataIn;     // Serial data going to the next layer down
                  DataToMerge = ASICdataMSK[11:0];      // 12 serial data streams going from ASICs to the merging program
                  TxD_dataEcho = 8'h3;
              end
        InaR: begin
                  if (StrobeOutIna || CntTime >= 65535) NextState = InSh;
                  else NextState = InaR;
                  CmdRepeat = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (This) DOutMux = 1'b0;
                      else DOutMux = DataIn;
                  end else DOutMux = 1'b0;
              end
        InaS: begin
                  if (CntTime == 4992) begin
                      NextState = Wait;  // Give anough time for the i2c operation to complete
                  end else NextState = InaS;
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
              end
        InSh: begin
                  if (Cnt == 255 || DataDone) begin
                      if (Master) NextState = DUMP;  // Allow enough time for the trailer to complete
                      else NextState = Wait;
                  end else NextState = InSh;
                  CmdRepeat = 1'b0;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (This) DOutMux = i2cResults[17];
                      else DOutMux = DataIn;
                      DataOut = 1'b0;
                  end else begin
                      if (This) DataOut = i2cResults[17];
                      else DataOut = DataIn;
                      DOutMux = 1'b0;
                  end
              end
        Scnd: begin
                  NextState = Echo;
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
              end
        Buss: begin
                  CmdRepeat = 1'b0;
                  DataOut = MergedData;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  DOutMux = 1'b0;
                  if (CntZ > 80 || CntTime == 24'h00ffff) NextState = Wait;
                  else NextState = Buss;
              end
        AsRg: begin
                  if (CntZ == 127 || DataDone || CntTime > 511) begin
                      if (Master) NextState = DUMP;
                      else NextState = Wait;
                  end else NextState = AsRg;
                  CmdRepeat = 1'b0;
                  DataToMerge = 0;
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (This | All) begin 
                          if (Command == 8'h02) begin
                              if (ToTFPGA==BrdAddress[2:0]) DOutMux = TOTdata;
                              else DOutMux = DataIn;
                          end else begin
                              if (This && (ASICaddress != 5'b11111)) DOutMux = ASICdataMSK[ASICaddress[3:0]];
                              else DOutMux = DataIn;
                          end
                      end else DOutMux = DataIn;
                      DataOut = 1'b0;
                  end else begin
                      if (This | All) begin 
                         if (Command == 8'h02) begin
                             if (ToTFPGA==BrdAddress[2:0]) DataOut = TOTdata;
                             else DataOut = DataIn;
                         end else begin
                             if (This && (ASICaddress != 5'b11111)) DataOut = ASICdataMSK[ASICaddress[3:0]];
                             else DataOut = DataIn;
                         end
                      end else DataOut = DataIn;
                      DOutMux = 1'b0;
                  end
              end
        RdEv: begin
                  CmdRepeat = CmdEv;
                  DOutMux = MstrDataEv;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (CntTime == 24'hffffff) NextState = Wait;
                  else if (doneRdEvt) NextState = Wait;
                  else NextState = RdEv;
              end
        ACmd: begin
                  CmdRepeat = 1'b0;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (Command == 8'h01) begin
                          DOutMux = MstrDataEv;
                      end else if (Command == 8'h02) begin
                          if (ToTFPGA==BrdAddress[2:0]) DOutMux = TOTdata;   // Send calibration TOT (trigger) data only from the selected FPGA
                          else DOutMux = DataIn;
                      end else begin
                          if (This && ASICaddress != 5'b11111) DOutMux = ASICdataMSK[ASICaddress[3:0]];
                          else DOutMux = DataIn;
                      end
                      DataOut = 1'b0;
                  end else begin
                      if (Command == 8'h01) begin
                          DataOut = DataIn;
                      end else if (Command == 8'h02) begin
                          if (ToTFPGA==BrdAddress[2:0]) DataOut = TOTdata;
                          else DataOut = DataIn;
                      end else begin
                          if (This && ASICaddress != 5'b11111) DataOut = ASICdataMSK[ASICaddress[3:0]];
                          else DataOut = DataIn;
                      end
                      DOutMux = 1'b0;
                  end
                  if (Cnt == 74) begin
                      case (Command)
                          8'h01: if (Master) NextState = RdEv; else NextState = Wait;
                          8'h02: NextState = AsRg;
                          8'h0C: if (All && (ASICaddress==5'b11111)) NextState = ACfg; else NextState = Wait; // For the ASIC soft reset, go on here to reload the registers with the defaults
                          8'h20: NextState = AsRg;
                          8'h21: NextState = AsRg;
                          8'h22: NextState = AsRg;
                          8'h23: NextState = AsRg;
                          8'h24: NextState = AsRg;
                          8'h25: NextState = AsRg;
                          default: NextState = Wait;
                      endcase
                  end
                  else NextState = ACmd;
              end
        RegT: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  DataOut = DataIn;
                  if (Cnt == 3) NextState = RegD;
                  else NextState = RegT;
              end
        RegD: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  DataOut = DataIn;
                  if (Cnt[3:0] == lenData-1) NextState = RegO;
                  else NextState = RegD;
              end
        RegO: begin
                  CmdRepeat = 1'b0;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Master) begin
                      if (This) DOutMux = RegOutPut;
                      else DOutMux = DataIn;
                      DataOut = DataIn;
                  end else begin
                      DOutMux = 1'b0;
                      if (This) DataOut = RegOutPut;
                      else DataOut = DataIn;
                  end
                  if (CntTime == 24'hffffff) NextState = Wait;
                  else if (doneRdReg) begin
                      if (Master) NextState = DUMP;
                      else NextState = Wait;
                  end else NextState = RegO;
              end
        DUMP: begin
                  if (DMPDone || CntTime == 24'hffffff) NextState = Wait;
                  else NextState = DUMP;
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
              end                  
        Cnfg: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt[1:0]==2'b01) NextState = ACmd;
                  else NextState = Cnfg;
              end
        Mask: begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  if (Cnt[2:0] == 3'b110) NextState = ACmd;
                  else NextState = Mask;
              end                  
    default:  begin
                  CmdRepeat = 1'b0;
                  DOutMux = 1'b0;
                  DataOut = DataIn;
                  DataToMerge = ASICdataMSK[11:0];
                  TxD_dataEcho = 8'h3;
                  NextState = Wait;
              end
    endcase
end

assign All = (Address[2:0] == 7);  // Assume that the Master always has address 0, other boards 1 through 6
assign This = (BrdAddress[2:0] == Address[2:0]);

reg CalStrobe;
reg FrstBt;
reg [7:0] cntError1;
reg [7:0] cntError2;
reg [7:0] cntError3;
reg [7:0] cntError4;
reg [7:0] cntError8;
reg [7:0] cntError9;
reg [7:0] cntErrorA;
reg [7:0] errSel;
reg [3:0] ErrorCode2;
reg [7:0] SaveCmd;
reg LclDmpEvt;
reg SgnlDmp;             // Signal that the event deletion is complete for this layer and all layers acknowlege
reg [1:0] Cndn;          // Two conditions for event deletion to be complete for command 53
reg [15:0] nEvSent;      // Count of events send down to the master
reg [23:0] trgCntrTime;  // Clock counter for measuring the trigger OR rate
reg [15:0] trgCntr;      // Trigger rate counter
reg enableTrgCnt;        // Set to start counting internal trigger ORs
reg trgOrPrev;           // Internal trigger OR at the previous clock cycle
always @ (posedge SysCLK) begin
    if (ResetExt) begin
        State <= Wait;
        ConfigReset <= 1'b1;
    end else if (ConfigReset) begin
        nEvSent <= 0;
        CmdCount <= 0;
        ConfigReset <= 1'b0;
        TrigDly <= 8'd10;   // Global trigger delay, in clock cycles
        TrigLen <= 8'd1;   // Global trigger stretch, must always be set to 1!!!
        TrigSrc <= 8'd4;   // Default trigger is internal with wait for GO
        ASICpower <= 1'b0; // ASIC power is off at startup
        ResetLocal <= 1'b1;
        RegOut <= 1'b0;
        StartRead <= 1'b0;
        ASICmask <= 12'b111111111111;   // By default all of the ASICs are enabled
        NTkrLyr <= 8'd7;                // The default system has 7 layers
        TrgLen <= 8'h7;      // Length of the output trigger primitive, in clock cycles
        TrgDly <= 8'h1;      // Delay of the internal trigger
		trgCntrChoice <= 1'b0;    
        if (BrdAddress != 4'h5) TrgMask <= 1'b1;
		else TrgMask <= 1'b0;
        TrgLogic <= 1'b0;    // Default to AND logic for the output trigger primitive
        trgEnable <= 1'b0;   // The trigger is disabled at startup
        if (BrdAddress == 4'h5 || BrdAddress == 4'h6) endStatus <= 1'b1;
        else endStatus <= 1'b0;
        cntError1 <= 0;
        cntError2 <= 0;
        cntError3 <= 0;
        cntError8 <= 0;
        cntError9 <= 0;
        cntErrorA <= 0;
        GoInitialize <= 1'b0;
        ToTFPGA <= 3'b000;
        LclDmpEvt <= 1'b0;
        MxWaitGO <= 45;
        dualTrig <= 1'b1;
        CntDump2 <= 0;
        nEvent <= 0;
		ErrorCode2[3:0] <= 0;
		SaveCmd <= 0;
		enableTrgCnt <= 1'b0;
    end else begin
        if (State != Wait && NextState == Wait) $display("%g\t AESOP_TKR %h: command decoder returning to the Wait state.",$time,BrdAddress);
        State <= NextState;
		trgOrPrev <= trgToCnt;
		if (trgToCnt & !trgOrPrev) begin   // Count just rising edges of the trigger OR
			if (enableTrgCnt && trgCntr != 24'hffffff) trgCntr <= trgCntr + 1;
		end
		if (enableTrgCnt) begin
			trgCntrTime <= trgCntrTime + 1;
			if (trgCntrTime == 24'b100110001001011010000000) enableTrgCnt <= 1'b0;
		end
        if (MergeError) cntErrorA <= cntErrorA + 1;
		if (NBfull > 1) ErrorCode2[0] <= 1'b1;
		if (CmdIn==1'b1 && !(State==Wait || State==AddR || State==CmdR || State==NbyT || State==DatI)) begin
		    ErrorCode2[1] <= 1'b1;
	        $display("%g\t AESOP_TKR %h: serial command bit seen when not ready, State=%b, Command=%h",$time,BrdAddress,State,Command);
			SaveCmd <= Command;
		end
		if (RxD_data_ready==1'b1 && !(State==Wait || State==GtB2 || State==GtB3 || State==GtDB)) begin
		    ErrorCode2[2] <= 1'b1;
			$display("%g\t AESOP_TKR %h: UART byte seen when not ready, State=%b, Command=%h, UART data=%h %b",$time,BrdAddress,State,Command,RxD_data,RxD_data);
			SaveCmd <= Command;
		end
        case (State)
            Wait: begin
                     SgnlDmp <= 1'b0;
                     readCMDseen <= 1'b0;
                     CalStrobe <= 1'b0;
                     ResetI2c <= 1'b0;
                     i2cRdCmd <= 1'b0;
                     StrobeIna <= 1'b0;
                     randomTrig <= 1'b0;
                     TxD_startEcho <= 1'b0;
                     Address <= RxD_data[3:0];
                     CntTime <= 0;
                     Cnt <= 0;
                     StartRead <= 1'b0;
                     ResetLocal <= 1'b0;
                     HardReset <= 1'b0;
                     ConfigReset <= 1'b0;
                     RegData[0] <= 8'b11000111;
                     RegOut <= 1'b0;
                     ByteCnt <= 0;
                     Prty <= 1'b1;
                     DMPStart <= 1'b0;
                     SendEvtThis <= 1'b0;
                     CmdStrng <= {1'b1,5'b11111,4'b0000,~1'b0,64'd0};   // NOOP to all 12 chips
                  end
            AddR: begin     //Start of input sequence for serial commands sent from the master board
                     Cnt <= Cnt + 1;
                     Address <= {Address[2:0],CmdIn};
                  end
            CmdR: begin
                     Cnt <= Cnt + 1;
                     Command <= {Command[6:0],CmdIn};
                  end
            NbyT: begin
                     if (Cnt == 15) Cnt <= 0;
                     else Cnt <= Cnt + 1;
                     Ndata <= {Ndata[2:0],CmdIn};
                  end
            DatI: begin
                     if (Cnt == 7) begin
                         Cnt <= 0;
                         ByteCnt <= ByteCnt + 1;
                     end else begin 
                         Cnt <= Cnt + 1;
                         if (Cnt == 0  && ByteCnt > 0) begin
                             CmdData[ByteCnt-1] <= DatByte;
                             if (ByteCnt == 1) ASICaddress <= DatByte[4:0];
                             if (ByteCnt == 3) ToTFPGA <= DatByte[2:0];
                         end
                     end
                     DatByte <= {DatByte[6:0],CmdIn};
                     Prty <= Prty^CmdIn;
                  end
            LstD: begin
                      CmdData[ByteCnt-1] <= DatByte;
                      if (ByteCnt == 1) ASICaddress <= DatByte[4:0];
                      if (ByteCnt == 3) ToTFPGA <= DatByte[2:0];
                  end
            GtB2: begin          // Start of input sequence for commands received from the UART
                     if (RxD_data_ready) begin
                         CntTime <= 0;
                         Command <= RxD_data;
                     end else CntTime <= CntTime + 1;
                  end            
            GtB3: begin                     
                     if (RxD_data_ready) begin
					 	 if (Command == 8'h57) $display("%g\t AESOP_TKR %h, in state GtB3 with Command=%h, RxD_data=%b, Cnt=%d",$time,BrdAddress,Command,RxD_data,Cnt);
                         CntTime <= 0;
                         Ndata <= RxD_data[3:0];
                     end else CntTime <= CntTime + 1;
                  end
            GtDB: begin
                      if (RxD_data_ready) begin
                          CmdData[Cnt] <= RxD_data;
                          Prty <= Prty^RxD_data[0]^RxD_data[1]^RxD_data[2]^RxD_data[3]^RxD_data[4]^RxD_data[5]^RxD_data[6]^RxD_data[7];
                          if (Cnt == 0) ASICaddress <= RxD_data[4:0];
                          else begin
                            if (ASICaddress > 11 && ASICaddress != 5'b11111) ASICaddress <= 0;
                            if (Cnt == 2) ToTFPGA <= RxD_data[2:0];
                          end
                          Cnt <= Cnt + 1;
                          CntTime <= 0;
                      end else CntTime <= CntTime + 1;
                  end
            CmdO: begin
                      Cnt <= 0;
                      DatByte <= CmdData[0];
                      ByteCnt <= 1;
                      DataFlg = (Ndata>0);
                  end
            Shft: begin
                      Cnt <= Cnt + 1;
                      Address <= {Address[2:0], Command[7]};
                      Command <= {Command[6:0], Ndata[3]};
                      Ndata <= {Ndata[2:0], Address[3]};
                      if (NextState == DatO) Cnt <= 0;
                  end
            DatO: begin
                      DatByte <= {DatByte[6:0], 1'b0};
                      if (Cnt == 7) begin
                          Cnt <= 0;
                          DatByte <= CmdData[ByteCnt];
                          ByteCnt <= ByteCnt + 1;
                      end else Cnt <= Cnt + 1;
                  end
            Echo: begin
                      Cnt <= 0;
                      TxD_startEcho <= 1'b0;
                      ResetI2c <= 1'b0;
                      HardReset <= 1'b0;
                      if (!TxD_busy) begin
                          CntEcho <= CntEcho + 1;
                          if (CntEcho == 5) begin
                              case (Command)
                                  8'h03:  begin
                                              if (This | All) begin
                                                  ConfigReset <= 1'b1;
                                                  $display("%g\t AESOP_TKR %d:  FPGA configuration reset",$time,BrdAddress);
                                              end
                                          end
                                  8'h04:  begin
                                              if (This | All) begin
                                                  ResetLocal <= 1'b1;
                                                  $display("%g\t AESOP_TKR %d:  FPGA logic reset",$time,BrdAddress);
                                              end
                                          end
                                  8'h05:  begin
                                              GoInitialize <= 1'b1;
                                          end
                                  8'h26:  begin
                                              GoInitialize <= 1'b1;
                                              //if (This | All) $display("%g\t AESOP_TKR: CmdASIC=%b State=%b GoInitialize=%b",$time,CmdASIC,State,GoInitialize);
                                          end
                              endcase
                          end
                      end
                  end
            Ech1: begin
                      Cnt <= Cnt + 1;
                      if (Master) begin
                          TxD_startEcho <= 1'b1;        
                          if (Cnt == 0) $display("%g\t AESOP_TKR state Ech1: sending TxD_start signal, CntEcho=%h, TxD_dataEcho=%b",$time,CntEcho,TxD_dataEcho);
                      end
                  end
            Deco: begin
                      CntTime <= 0;
                      Cnt <= 0;
                      CntZ <= 0;
                      CmdCount <= CmdCount + 1;
                      CntEcho <= 0;
                      FrstBt <= 1'b0;
                      if (Address>7) cntError9 <= cntError9 + 1;
                      case (Command) 
                          8'h01:  begin    // Read Event Command
                                      if (This | All) begin
                                          $display("%g\t AESOP_TKR %h: Read event command received. Data=%b, Tag=%b",$time,BrdAddress,CmdData[0],TrgTag);
                                          nEvent <= nEvent + 1;
                                          if (CmdData[0] == 0) begin   // Read a real event
                                              if (!readoutPending) cntError3 <= cntError3 + 1;
                                              CmdStrng <= {10'b1111110010,TrgTag[0]^TrgTag[1],TrgTag,62'd0};
                                          end else begin               // Read a calibration event
                                              CmdStrng <= {10'b1111110010,ASICaddress[0]^ASICaddress[1],ASICaddress[1:0],62'd0};
                                          end                                                        
                                      end else begin
                                          $display("%g\t AESOP_TKR %d:  Read event command encountered but not addressed.",$time,BrdAddress);
                                      end
                                      readCMDseen <= 1'b1;
                                  end
                          8'h02:  begin    // ASIC calibration strobe
                                      if (This | All) begin
                                          CalStrobe <= 1'b1;                                          
                                          CmdStrng <= {1'b1,ASICaddress,4'b1111,~(Prty^ToTFPGA[0]^ToTFPGA[1]^ToTFPGA[2]),CmdData[1],56'd0};
                                          $display("%g\t AESOP_TKR %d:  Calibration strobe for chip %h, setting=%b",$time,BrdAddress,ASICaddress,CmdData[1]);
                                      end
                                  end
                          8'h03:  begin
                                  end
                          8'h04:  begin
                                  end
                          8'h05:  begin
                                      if (This | All) begin
                                          HardReset <= 1'b1;
                                          $display("%g\t AESOP_TKR %d:  Resetting the ASICs (hard reset)",$time,BrdAddress);
                                      end
                                  end
                          8'h06:  begin
                                      if (This | All) begin
                                          TrigDly <= CmdData[0];
                                          $display("%g\t AESOP_TKR %d:  Setting the trigger delay to %d",$time,BrdAddress,CmdData[0]);
                                      end
                                  end
                          8'h07:  begin                                          
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end
                          8'h08:  begin
                                      if (This | All) begin
                                          ASICpower <= 1'b1;
                                          $display("%g\t AESOP_TKR %d:  turning on the analog power to the ASICs",$time,BrdAddress);
                                      end
                                  end
                          8'h09:  begin
                                      if (This | All) begin
                                          ASICpower <= 1'b0;
                                          $display("%g\t AESOP_TKR %d:  turning off the analog power to the ASICs",$time,BrdAddress);
                                      end
                                  end
                          8'h0a:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h0b:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h0c:  begin
                                      if (This | All) begin
                                          CmdStrng <= {1'b1,ASICaddress,4'b0001,Prty,64'd0};
                                          $display("%g\t AESOP_TKR %d:  send a soft RESET to ASIC address %h",$time,BrdAddress,ASICaddress);
                                      end
                                  end
                          8'h0d:  begin
                                      if (Master & This) begin
                                          DMPStart <= 1'b1;
                                          $display("%g\t AESOP_TKR %d:  dumping the RAM buffer to the UART",$time,BrdAddress);
                                      end
                                  end 
                          8'h0e:  begin
                                      if (This | All) begin
                                          ASICmask[11:8] <= CmdData[0];
                                      end
                                  end
                          8'h0f:  begin
                                      if (This | All) begin
                                          NTkrLyr <= CmdData[0];
                                          $display("%g\t AESOP_TKR %d:  setting the number of tracker layers to %d",$time,BrdAddress,CmdData[0]);
                                      end
                                  end
                          8'h10:  begin
                                      if (This | All) begin
                                          CmdStrng <= {1'b1,ASICaddress,4'b1001,~Prty,CmdData[1],56'd0};
                                          $display("%g\t AESOP_TKR %d:  loading the Calibration DAC for ASIC %d with %b",$time,BrdAddress,ASICaddress,CmdData[1]);
                                      end
                                  end
                          8'h11:  begin
                                      if (This | All) begin
                                          CmdStrng <= {1'b1,ASICaddress,4'b1010,~Prty,CmdData[1],56'd0};
                                          $display("%g\t AESOP_TKR %d:  loading the Threshold DAC for ASIC %d with %b",$time,BrdAddress,ASICaddress,CmdData[1]);
                                      end                                          
                                  end
                          8'h12:  begin
                                      CmdStrng <= {1'b1,ASICaddress,4'b1011,Prty,CmdData[1],56'd0};
                                      $display("%g\t AESOP_TKR %d:  load ASIC configuration for ASIC %d with %b%b%b",$time,BrdAddress,ASICaddress,CmdData[1],CmdData[2],CmdData[3]);
                                  end
                          8'h13:  begin
                                      CmdStrng[74:56] <= {1'b1,ASICaddress,4'b1100,~Prty,CmdData[1]};
                                  end
                          8'h14:  begin
                                      CmdStrng[74:56] <= {1'b1,ASICaddress,4'b1101,Prty,CmdData[1]};
                                  end
                          8'h15:  begin
                                      CmdStrng[74:56] <= {1'b1,ASICaddress,4'b1110,Prty,CmdData[1]};
                                  end
                          8'h1e:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end
                          8'h1f:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end                                             
                          8'h20:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b0011,~Prty,64'd0};
                                  end
                          8'h21:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b0100,Prty,64'd0};
                                  end
                          8'h22:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b0101,~Prty,64'd0};
                                  end
                          8'h23:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b0110,~Prty,64'd0};
                                  end        
                          8'h24:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b0111,Prty,64'd0};
                                  end        
                          8'h25:  begin
                                      if (This) CmdStrng <= {1'b1,ASICaddress,4'b1000,Prty,64'd0};
                                  end
                          8'h26:  begin
                                  end
                          8'h45:  begin          // Load an i2c register
                                      i2cAddr <= CmdData[0];
                                      if (This | All) $display("%g\t AESOP_TKR %h: load i2c register for i2c address %b",$time,BrdAddress,CmdData[0]);
                                  end
                          8'h46:  begin
                                      i2cAddr <= CmdData[0];   // Read whatever i2c register is being pointed to
                                      i2cRdCmd <= 1'b1;
                                      if (This) $display("%g\t AESOP_TKR %h: read i2c register from i2c address %b",$time,BrdAddress,CmdData[0]);
                                  end
                          8'h48:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h49:  begin
                                      ResetI2c <= 1'b1;
                                  end
                          8'h52:  begin
                                      if (!Master & This) begin
                                          SendEvtThis <= 1'b1;
                                          nEvSent <= nEvSent + 1;
                                          $display("%g\t AESOP_TKR %h Send event request received for address %h",$time,BrdAddress,Address);
                                      end
                                  end 
                          8'h53:  begin
                                      LclDmpEvt <= 1'b1;
                                      SgnlDmp <= 1'b0;
                                      Cndn <= 2'b00;
                                      CntDump2 <= CntDump2 + 1;
                                  end                    
                          8'h54:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h55:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end         
                          8'h56:  begin
                                      if (This | All) begin
                                          MxWaitGO <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set MxWaitGO to %d",$time,BrdAddress,CmdData[0]);
                                      end    
                                  end                                      
                          8'h57:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end            
                          8'h58:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;    
                                  end     
                          8'h59:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end       
                          8'h5A:  begin
                                      if (This) begin
                                          endStatus <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set trigger logic end status to to %h",$time,BrdAddress,CmdData[0]);
                                      end
                                  end   
                          8'h5B:  begin
                                      if (This) begin
                                          dualTrig <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set dual trigger to %h",$time,BrdAddress,CmdData[0]);
                                      end
                                  end           
                          8'h5C:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end                         
                          8'h60:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end    
                          8'h61:  begin
                                      if (This | All) begin
                                          TrgLen <= CmdData[0];
                                      end
                                  end  
                          8'h62:  begin
                                      if (This | All) begin
                                          TrgMask <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set trigger mask to %h",$time,BrdAddress,CmdData[0]);
                                      end
                                  end
                          8'h63:  begin
                                      if (This | All) begin
                                          TrgLogic <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set trigger logic type to %h",$time,BrdAddress,CmdData[0]);
                                      end
                                  end
                          8'h64:  begin
                                      if (This | All) begin
                                          TrigSrc <= CmdData[0];
                                          $display("%g\t AESOP_TKR %h Set trigger source to %h",$time,BrdAddress,CmdData[0]);
                                      end
                                  end           
                          8'h65:  begin
                                      if (This | All) begin
                                          trgEnable <= 1'b1;
                                          $display("%g\t AESOP_TKR %h: enabling the trigger.",$time,BrdAddress);
                                      end
                                  end            
                          8'h66:  begin
                                      if (This | All) trgEnable <= 1'b0;
                                  end                                    
                          8'h67:  begin
                                      randomTrig <= 1'b1;
                                  end
                          8'h68:  begin                                          
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end    
                          8'h69:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end   
                          8'h6A:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end  
                          8'h6B:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end   
						  8'h6C:  begin
									  if (This | All) begin									  	
										enableTrgCnt <= 1'b1;
										if (!enableTrgCnt) begin
											trgCntrTime <= 0;
											trgCntr <= 0;
										end
									  end
						          end
						  8'h6D:  begin
									  RegData[1] <= 8'd3;
									  lenData <= 4'd3;
						          end
						  8'h6E:  begin
						              if (This | All) begin
                                          trgCntrChoice <= CmdData[0];
                                      end
						          end
                          8'h71:  begin
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end
                          8'h73:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end                                  
                          8'h74:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h75:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                  end
                          8'h76:  begin                                          
                                      RegData[1] <= 8'd3;
                                      lenData <= 4'd3;
                                  end
                          8'h77:  begin
                                      RegData[1] <= 8'd2;
                                      lenData <= 4'd2;
                                      errSel <= CmdData[0];
                                  end
						  8'h78:  begin
						              RegData[1] <= 8'd3;
									  lenData <= 4'd3;
								  end
                          default: begin
                                       cntError9 <= cntError9 + 1;     // Unrecognized command
                                   end
                      endcase
                  end
            Evcl: begin
                      LclDmpEvt <= 1'b0;
                      if (DataIn | BrdAddress[2:0] == (NTkrLyr[2:0]-1)) begin
                          Cndn[1] <= 1'b1;
                          if (!Cndn[1]) $display("%g\t AESOP_TKR %h: State Evcl, 2nd condition met, DataIn=%b, Cndn=%b",$time,BrdAddress,DataIn,Cndn);
                      end
                      if (!DmpPending) begin
                          Cndn[0] <= 1'b1;
                          if (!Cndn[0]) $display("%g\t AESOP_TKR %h: State Evcl, 1st condition met, BufClr=%b, Cndn=%b",$time,BrdAddress,BufClr,Cndn);
                      end
                      if (Cndn == 2'b11) SgnlDmp <= 1'b1;
                      CntTime <= CntTime + 1;
                      if (CntTime == 24'h00ffff) cntError8 <= cntError8 + 1;
                  end
            ACfg: begin
                      CntTime <= CntTime + 1;
                      GoInitialize <= 1'b0;
                      if (CntTime == 24'hffffff) cntError2 <= cntError2 + 1;
                      //if (This | All) $display("%g\t AESOP_TKR: CmdASIC=%b State=%b GoInitialize=%b",$time,CmdASIC,State,GoInitialize);
                  end
            InaR: begin
                      if (StrobeOutIna) begin
                          i2cResults <= {1'b1,i2cRegOut,1'b1};
                          $display("$g\t AESOP_TKR %h: receiving i2c results %b",$time,BrdAddress,i2cRegOut);
                      end
                      CntTime <= CntTime + 1;
                      i2cRdCmd <= 1'b0;
                  end
            InSh: begin
                      Cnt <= Cnt + 1;
                      if (NextState == DUMP) DMPStart <= 1'b1;
                      i2cResults <= {i2cResults[16:0],1'b0};
                  end
            InaS: begin
                     CntTime <= CntTime + 1;
                     $display("%g\t AESOP_TKR %h: state InaS, Cnt=%d, CntTime=%d",$time,BrdAddress,Cnt,CntTime);
                     if (Cnt < 127) Cnt <= Cnt + 1;
                     case (Cnt)
                        7'd0: i2cData[23:16] <= CmdData[1];  
                        7'd1: i2cData[15:8] <= CmdData[2];
                        7'd2: i2cData[7:0] <= CmdData[3];
                        7'd3: if (This | All) begin
                                 StrobeIna <= 1'b1;
                                 $display("%g\t AESOP_TKR %h: send i2c command %b%b",$time,BrdAddress,i2cData[7:0],CmdData[2]);
                              end
                        7'd4: StrobeIna <= 1'b0;
                     endcase
                  end
            Scnd: begin
                      case (Command)
                          8'h06: begin
                                     if (This | All) begin
                                         TrigLen <= 8'd1;  //CmdData[1];
                                         $display("%g\t AESOP_TKR %d:  setting the trigger stretch length to %d",$time,BrdAddress,CmdData[1]);
                                     end
                                 end
                          8'h0e: begin
                                     if (This | All) begin
                                         ASICmask[7:0] <= CmdData[1];
                                         $display("%g\t AESOP_TKR %d:  setting the ASIC mask to %b",$time,BrdAddress,{ASICmask[11:8],CmdData[1]});
                                     end
                                 end
                          8'h61: begin
                                      if (This | All) begin
                                          TrgDly <= CmdData[1];
                                          $display("%g\t AESOP_TKR %h Set trigger length to %d and trigger delay to %d",$time,BrdAddress,TrgLen,CmdData[1]);
                                      end
                                 end
                      endcase
                  end
            Buss: begin
                      CntTime <= CntTime + 1;
                      if (CntTime == 24'h00ffff) cntError2 <= cntError2 + 1;
                      if (MergedData) FrstBt <= 1'b1;
                      SendEvtThis <= 1'b0;
                      if (FrstBt && MergedData == 0) CntZ <= CntZ + 1;
                      else CntZ <= 0;
                  end
            AsRg: begin
                      if (Command == 8'h02) begin
                          if (TOTdata || (StateTOT == SEndTOT)) FrstBt <= 1'b1;
                          if (FrstBt && !TOTdata) CntZ <= CntZ + 1;
                          else CntZ <= 0;
                      end else begin
                          if (ASICdataMSK[ASICaddress[3:0]]) FrstBt <= 1'b1;
                          if (ASICaddress==5'b11111 || (FrstBt && !ASICdataMSK[ASICaddress[3:0]])) CntZ <= CntZ + 1;
                          else CntZ <= 0;
                      end
                      if (NextState == DUMP) DMPStart <= 1'b1;
                      CntTime <= CntTime + 1;
                  end
            RdEv: begin
                      CntTime <= CntTime + 1;
                      if (CntTime == 24'hffffff) cntError1 <= cntError1 + 1;
                      StartRead <= 1'b0;
                      //$display("%g\t RdEv, CmdEv=%b",$time,CmdEv);
                  end
            ACmd: begin
                      readCMDseen <= 1'b0;
                      CalStrobe <= 1'b0;
                      if (Cnt == 0) $display("%g\t AESOP_TKR %h: Sending command to ASICs: %b",$time,BrdAddress,CmdStrng);
                      Cnt <= Cnt + 1;
                      CmdStrng <= {CmdStrng[73:0],1'b0};  // Shift out the command to the ASICs
                      if (NextState == RdEv) begin
                          StartRead <= 1'b1;
                      end else begin
                          FrstBt <= 1'b0;                          
                      end           
                      if (NextState == ACfg && All && (ASICaddress==5'b11111)) GoInitialize <= 1'b1;                      
                  end
            RegT: begin
                      case (Cnt) 
                        7'd0: begin
                                  RegData[2] <= CmdCount[15:8];
                                  Cnt <= Cnt + 1;
                              end
                        7'd1: begin
                                  RegData[3] <= CmdCount[7:0];
                                  Cnt <= Cnt + 1;
                              end
                        7'd2: begin
                                  RegData[4] <= BrdAddress;
                                  Cnt <= Cnt + 1;
                              end
                        7'd3: begin
                                  RegData[5] <= Command;
                                  Cnt <= 0;
                              end
                      endcase
                  end
            RegD: begin
                      Cnt <= Cnt + 1;
                      if (Cnt == 0) begin
                          case (Command)
                              8'h07: RegData[6] <= TrigDly;
                              8'h0a: RegData[6] <= Version;
                              8'h0b: RegData[6] <= LclConfig;
                              8'h1e: RegData[6] <= {4'h0,ASICmask[11:8]};
                              8'h1f: RegData[6] <= NTkrLyr;
                              8'h48: RegData[6] <= {5'b10000,i2cError};
                              8'h54: RegData[6] <= NBufFill;
                              8'h55: RegData[6] <= NBufOverFlow;
                              8'h57: begin
							             $display("%g\t AESOP_TKR %h: command 57 received. StateTg=%b",$time,BrdAddress,StateTg);
                                         if (StateTg == DeadTg) RegData[6] <= 8'h59;
                                         else RegData[6] <= 8'h4E;
                                     end
                              8'h58: RegData[6] <= NMissedGo[15:8];
                              8'h59: RegData[6] <= {1'b0,MxWaitGO}; 
                              8'h5C: RegData[6] <= nEvSent[15:8];                             
                              8'h60: RegData[6] <= CmdCount[15:8];
                              8'h68: RegData[6] <= TriggerCnt[15:8];
                              8'h69: RegData[6] <= countGos[15:8];
                              8'h6A: if (Master) RegData[6] <= CntDump[15:8];
                                     else RegData[6] <= CntDump2[15:8];
                              8'h6B: RegData[6] <= nEvent[15:8];
							  8'h6D: RegData[6] <= trgCntr[15:8];
                              8'h71: RegData[6] <= TrgLen;
                              8'h73: RegData[6] <= BoardID;
                              8'h74: RegData[6] <= TrigSrc;
                              8'h75: RegData[6] <= NMissedTg;
                              8'h76: RegData[6] <= EncStates1;      //First Byte of state machine status
                              8'h77: begin
                                        case (errSel)
                                           8'h01: RegData[6] <= cntError1;    // Timeout in RdEv
                                           8'h02: RegData[6] <= cntError2;    // Timeout in RegO or DUMP or Buss
                                           8'h03: RegData[6] <= cntError3;    // Received a read command with no trigger ready
                                           8'h04: RegData[6] <= cntError4;    // Timeout in Master event output
                                           8'h05: RegData[6] <= cntError5;    // Overflow in RAM buffer
                                           8'h06: RegData[6] <= 8'h0;         // Timeout of the trigger logic
                                           8'h07: RegData[6] <= 8'h0;         // Timeout in sending trigger notice
                                           8'h08: RegData[6] <= cntError8;    // Timeout in Evcl
                                           8'h09: RegData[6] <= cntError9;    // Corrupt command strings received
                                           8'h0A: RegData[6] <= cntErrorA;    // Error detected in data merging routine
                                           default: RegData[6] <= 0;
                                        endcase
                                     end
							  8'h78: RegData[6] <= {ErrorCode2,ErrorCode1};
                          endcase
                      end else if (Cnt == 1) begin
                          case (Command)
                              8'h07: RegData[7] <= TrigLen;
                              8'h0a: RegData[7] <= 8'h0f;
                              8'h0b: RegData[7] <= 8'h0f;
                              8'h1e: RegData[7] <= ASICmask[7:0];
                              8'h1f: RegData[7] <= 8'h0f;
                              8'h48: RegData[7] <= 8'h0f;
                              8'h54: RegData[7] <= 8'h0f;
                              8'h55: RegData[7] <= 8'h0f;
                              8'h57: RegData[7] <= 8'h0f;
                              8'h58: RegData[7] <= NMissedGo[7:0];
                              8'h59: RegData[7] <= 8'h0f;
                              8'h5C: RegData[7] <= nEvSent[7:0];
                              8'h60: RegData[7] <= CmdCount[7:0];
                              8'h68: RegData[7] <= TriggerCnt[7:0];
                              8'h69: RegData[7] <= countGos[7:0];
                              8'h6A: if (Master) RegData[7] <= CntDump[7:0];
                                     else RegData[7] <= CntDump2[7:0];
                              8'h6B: RegData[7] <= nEvent[7:0];
							  8'h6D: RegData[7] <= trgCntr[7:0];
                              8'h71: RegData[7] <= TrgDly;
                              8'h73: RegData[7] <= 8'h0f;
                              8'h74: RegData[7] <= 8'h0f;
                              8'h75: RegData[7] <= 8'h0f;
                              8'h76: RegData[7] <= EncStates2;      //Second Byte of state machine status
                              8'h77: RegData[7] <= 8'h0f;
							  8'h78: RegData[7] <= SaveCmd;
                          endcase
                      end else if (Cnt == 2) begin
                          case (Command)
                              8'h07: RegData[8] <= 8'h0f;
                              8'h1e: RegData[8] <= 8'h0f;
                              8'h58: RegData[8] <= 8'h0f;
                              7'h5C: RegData[8] <= 8'h0f;
                              8'h60: RegData[8] <= 8'h0f;
                              8'h68: RegData[8] <= 8'h0f;
                              8'h69: RegData[8] <= 8'h0f;
                              8'h6A: RegData[8] <= 8'h0f;
                              8'h6B: RegData[8] <= 8'h0f;
							  8'h6D: RegData[8] <= 8'h0f;
                              8'h71: RegData[8] <= 8'h0f;
                              8'h76: RegData[8] <= 8'h0f;
							  8'h78: RegData[8] <= 8'h0f;
                          endcase
                      end
                      if (NextState == RegO) RegOut <= 1'b1;
                  end
            RegO: begin
                      RegOut <= 1'b0;
                      if (CntTime == 24'hffffff) cntError2 <= cntError2 + 1;
                      CntTime <= CntTime + 1;
                      if (NextState == DUMP) DMPStart <= 1'b1;
                  end
            DUMP: begin
                      if (DMPStart) $display("%g\t AESOP_TKR %h: Starting dump to the UART.",$time,BrdAddress);
                      if (CntTime == 24'hffffff) cntError2 <= cntError2 + 1;
                      CntTime <= CntTime + 1;
                      DMPStart <= 1'b0;
                  end
            Cnfg: begin
                      if (Cnt[1:0] == 2'b01) Cnt <= 0; else Cnt <= Cnt + 1;
                      case(Cnt[1:0])
                          2'b00: CmdStrng[55:48] <= CmdData[2];
                          2'b01: CmdStrng[47:40] <= CmdData[3];
                      endcase
                  end
            Mask: begin
                      if (Cnt[2:0] == 3'b110) Cnt <= 0; else Cnt <= Cnt + 1;
                      case(Cnt[2:0])
                          3'b000: CmdStrng[55:48] <= CmdData[2];
                          3'b001: CmdStrng[47:40] <= CmdData[3];
                          3'b010: CmdStrng[39:32] <= CmdData[4];
                          3'b011: CmdStrng[31:24] <= CmdData[5];
                          3'b100: CmdStrng[23:16] <= CmdData[6];
                          3'b101: CmdStrng[15:8] <= CmdData[7];
                          3'b110: CmdStrng[7:0] <= CmdData[8];
                      endcase
                  end
        endcase
    end
end

// Encode the state vectors for debugging
wire [7:0] EncStates1;
wire [7:0] EncStates2;
reg [3:0] EncStateEv;
reg [3:0] EncStateRg;
reg [3:0] EncStateToT;
reg [3:0] EncStateTg;
assign EncStates1 = {EncStateEv,EncStateRg};
assign EncStates2 = {EncStateTg,EncStateToT};
always @ (StateEv) begin
    case (StateEv) 
        8'b00000001: EncStateEv = 4'h1;
        8'b00000010: EncStateEv = 4'h2;
        8'b00000100: EncStateEv = 4'h3;
        8'b00001000: EncStateEv = 4'h4;
        8'b00010000: EncStateEv = 4'h5;
        8'b00100000: EncStateEv = 4'h6;
        8'b01000000: EncStateEv = 4'h7;
        8'b10000000: EncStateEv = 4'h8;
        default: EncStateEv = 4'h0;
    endcase
end
always @ (StateRg) begin
    case (StateRg)
        5'b00001: EncStateRg = 4'h1;
        5'b00010: EncStateRg = 4'h2;
        5'b00100: EncStateRg = 4'h3;
        5'b01000: EncStateRg = 4'h4;
        5'b10000: EncStateRg = 4'h5;
        default: EncStateRg = 4'h0;
    endcase
end
always @ (StateTOT) begin
    case (StateTOT)
        10'b0000000001: EncStateToT = 4'h1;
        10'b0000000010: EncStateToT = 4'h2;
        10'b0000000100: EncStateToT = 4'h3;
        10'b0000001000: EncStateToT = 4'h4;
        10'b0000010000: EncStateToT = 4'h5;
        10'b0000100000: EncStateToT = 4'h6;
        10'b0001000000: EncStateToT = 4'h7;
        10'b0010000000: EncStateToT = 4'h8;
        10'b0100000000: EncStateToT = 4'h9;
        10'b1000000000: EncStateToT = 4'ha;
        default: EncStateToT = 4'h0;
    endcase
end
always @ (StateTg) begin
   case(StateTg)
      10'b0000000001: EncStateTg = 4'h1;
      10'b0000000010: EncStateTg = 4'h2;
      10'b0000000100: EncStateTg = 4'h3;
      10'b0000001000: EncStateTg = 4'h4;
      10'b0000010000: EncStateTg = 4'h5;
      10'b0000100000: EncStateTg = 4'h6;
      10'b0001000000: EncStateTg = 4'h7;
      10'b0010000000: EncStateTg = 4'h8;
      10'b0100000000: EncStateTg = 4'h9;
      10'b1000000000: EncStateTg = 4'ha;        
      default: EncStateTg = 4'h0;      
   endcase
end   

// Master-only State Machine to Read (Send Out) Event Data.  Start by sending data from the master, and then cycle through
// the other NTkrLyr layers.  End of transmission from a given layer is detected by a string of 9 zero bytes.

parameter [7:0] WaitEv = 8'b00000001;      // Wait for the start signal
parameter [7:0] ChCkEv = 8'b00000010;
parameter [7:0] HeadEv = 8'b00000100;      
parameter [7:0] MstrEv = 8'b00001000;      // Request the Master board (this board) to send its data to the RAM
parameter [7:0] DMP2Ev = 8'b00010000;      // Wait for the RAM to dump to the UART
parameter [7:0] SendEv = 8'b00100000;      // Request the next board to send its data to the RAM
parameter [7:0] DMP3Ev = 8'b01000000;      // Wait for the RAM to dump to the UART
parameter [7:0] DoneEv = 8'b10000000;

reg [7:0] StateEv, NextStateEv;
reg [7:0] Ident;
reg [6:0] CntEv;
reg [2:0] CntLyr;
reg MstrDataEv, CmdEv, SendEvtLcl, FirstBit;
reg [12:0] CmdOutEv;
reg [7:0] TxD_dataEv;
reg [1:0] CntDlyEv;
reg TxD_startEv;
reg [23:0] CntTmOut;
wire [7:0] Byte5;

assign Byte5 = {TrgWord,NTkrLyr[5:0]};

always @ (StateEv or StateTg or Byte5 or DataDone or CntDlyEv or CntTmOut or SendEvtThis or CmdCount or TriggerCnt or SendEvtLcl or CntEv or StartRead or DataIn or CmdOutEv or NTkrLyr or CntLyr or DMPDone or MergedData or TxD_busy) begin
    case (StateEv)
        WaitEv: begin
                   CmdEv = 1'b0;             // Command stream going to the slave layers
                   SendEvt = SendEvtThis;    // Signal to start sending out merged data (Slave boards should never leave this state)
                   if (StartRead) begin
                       NextStateEv = ChCkEv;    
                   end else begin
                       NextStateEv = WaitEv;
                   end
                   MstrDataEv = 1'b0;
                   TxD_dataEv = Byte5;
                end
        ChCkEv: begin
                   MstrDataEv = 1'b0;
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   if (TxD_busy) NextStateEv = ChCkEv;
                   else begin
                         if (CntEv == 6) begin
                             NextStateEv = MstrEv;
                         end else NextStateEv = HeadEv;
                   end
                   case (CntEv)
                       1: begin
                              TxD_dataEv = 8'h05;
                          end
                       2: begin
                              TxD_dataEv = 8'b11010011;
                          end
                       3: begin
                              TxD_dataEv = TriggerCnt[15:8];
                          end
                       4: begin
                              TxD_dataEv = TriggerCnt[7:0];
                          end
                       5: begin
                              TxD_dataEv = CmdCount[7:0];
                          end
                       default: begin
                                     TxD_dataEv = Byte5;
                                end
                   endcase
                end
        HeadEv: begin
                   MstrDataEv = 1'b0;
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   if (CntDlyEv == 2'b11) NextStateEv = ChCkEv;
                   else NextStateEv = HeadEv;
                   case (CntEv)
                       1: begin
                              TxD_dataEv = 8'h05;
                          end
                       2: begin
                              TxD_dataEv = 8'b11010011;
                          end
                       3: begin
                              TxD_dataEv = TriggerCnt[15:8];
                          end
                       4: begin
                              TxD_dataEv = TriggerCnt[7:0];
                          end
                       5: begin
                              TxD_dataEv = CmdCount[7:0];
                          end
                       default: begin
                                     TxD_dataEv = Byte5;
                                end
                   endcase                                
                end
        MstrEv: begin
                   MstrDataEv = MergedData;     // Data coming from the master board ASICs
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   if (CntEv == 127 || DataDone || CntTmOut==24'hffffff) NextStateEv = DMP2Ev;   // Detecting the 8-zero-byte trailer from the master board data merger
                   else NextStateEv = MstrEv;
                   TxD_dataEv = Byte5;
                end
        DMP2Ev: begin
                   MstrDataEv = 1'b0;
                   if (DMPDone || CntTmOut==24'hffffff) begin
                       if (NTkrLyr == 1) NextStateEv = DoneEv;
                       else NextStateEv = SendEv;
                   end else NextStateEv = DMP2Ev;
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   TxD_dataEv = Byte5;
                end
        SendEv: begin
                   MstrDataEv = DataIn;
                   CmdEv = CmdOutEv[12];  // Sending commands to the upper layers to send their data to the master
                   SendEvt = SendEvtLcl;
                   if (CntEv == 127 || DataDone || CntTmOut==24'hffffff) begin
                       NextStateEv = DMP3Ev;
                   end else begin
                       NextStateEv = SendEv;
                   end
                   TxD_dataEv = Byte5;
                end
        DMP3Ev: begin
                   MstrDataEv = 1'b0;
                   if (DMPDone || CntTmOut==24'hffffff) begin
                       if (CntLyr == NTkrLyr) NextStateEv = DoneEv;
                       else NextStateEv = SendEv;
                   end else NextStateEv = DMP3Ev;
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   TxD_dataEv = Byte5;
                end                
        DoneEv: begin
                   CmdEv = 1'b0;
                   SendEvt = SendEvtLcl;
                   MstrDataEv = 1'b0;
                   if (StateTg == WaitTg || CntTmOut==24'hffffff) NextStateEv = WaitEv;
                   else NextStateEv = DoneEv;
                   TxD_dataEv = Byte5;
                end
        default: begin
                     MstrDataEv = 1'b0;
                     CmdEv = 1'b0;
                     SendEvt = SendEvtThis;
                     NextStateEv = WaitEv;
                     TxD_dataEv = Byte5;
                 end
    endcase
end

reg DMPStart2;
always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        StateEv <= WaitEv;
        DMPStart2 <= 1'b0;
        cntError4 <= 0;
    end else begin 
        //if (StartRead) $display(" time    SendEvt  StateEv   Header    TriggerCnt     CntEv MstrDataEv SendEvt CmdEv DataIn FirstBit CntLyr DMPStart2 TxD_data TxD_start");
        if (StateEv != WaitEv) begin
            //$display("%g\t SendEvt %b %b %b %d      %b          %b      %b     %b       %b      %d       %b       %b    %b",$time,StateEv,NTkrLyr,TriggerCnt,CntEv,MstrDataEv,SendEvt,CmdEv,DataIn,FirstBit,CntLyr,DMPStart2,TxD_data,TxD_start);
        end
        StateEv <= NextStateEv;
        case (StateEv)
            WaitEv: begin
                        CntEv <= 0;
                        CntLyr <= 1;
                        CntTmOut <= 0;
                        Ident <= 8'b11010011;
                        SendEvtLcl <= 1'b0;
                        FirstBit <= 1'b0;
                        TxD_startEv <= 1'b0;
                    end
            ChCkEv: begin
                        TxD_startEv <= 1'b0;
                        CntDlyEv <= 2'b00;
                        if (NextStateEv == MstrEv) begin   
                            SendEvtLcl <= 1'b1;
                
                        end else begin
                            if (!TxD_busy) CntEv <= CntEv + 1;
                        end
                    end
            HeadEv: begin
                        TxD_startEv <= 1'b1;
                        CntDlyEv <= CntDlyEv + 1;
                    end
            MstrEv: begin
                        SendEvtLcl <= 1'b0;
                        CntTmOut <= CntTmOut + 1;
                        if (CntTmOut==24'hffffff) begin
                            cntError4 <= cntError4 + 1;
                        end
                        if (MergedData) FirstBit <= 1'b1;
                        if (NextStateEv == DMP2Ev) begin
                            DMPStart2 <= 1'b1;
                            CntTmOut <= 0;
                        end else begin
                            if (!MergedData & FirstBit) CntEv <= CntEv + 1;  // Count 72 consecutive zeros before going to the next layer
                            else CntEv <= 0;
                        end
                    end
            DMP2Ev: begin
                        DMPStart2 <= 1'b0;
                        FirstBit <= 1'b0;
                        CntTmOut <= CntTmOut + 1;
                        CntEv <= 0;
                        if (NextStateEv == SendEv) begin
                            CmdOutEv <= {2'b10,CntLyr,8'b01010010};  // Command 52 to send to the next board up
                            CntTmOut <= 0;
                        end
                        if (CntTmOut==24'hffffff) begin
                            cntError4 <= cntError4 + 1;
                        end
                    end
            SendEv: begin
                        if (DataIn) FirstBit <= 1'b1;   // Look for a trailer only after seeing the packet start bit
                        if (NextStateEv == DMP3Ev) begin
                            DMPStart2 <= 1'b1;
                            CntLyr <= CntLyr + 1;
                            CntTmOut <= 0;
                        end else begin
                            if (!DataIn & FirstBit) CntEv <= CntEv + 1;  // Count 72 consecutive zeros before going to the next layer
                            else CntEv <= 0;
                            //$display("%g\t         CntEv=%h, CmdOutEv=%b",$time,CntEv,CmdOutEv);
                            CmdOutEv <= {CmdOutEv[11:0],1'b0};   // Shift out the command string to the appropriate layer
                        end
                        CntTmOut <= CntTmOut + 1;
                        if (CntTmOut==24'hffffff) begin
                            cntError4 <= cntError4 + 1;
                        end
                    end
            DMP3Ev: begin
                        DMPStart2 <= 1'b0;
                        CntEv <= 0;
                        FirstBit <= 1'b0;
                        if (NextStateEv == SendEv) begin
                            CmdOutEv <= {2'b10,CntLyr,8'b01010010};  // Command 52 to send to the next board up                        
                        end
                        if (CntTmOut==24'hffffff) begin
                            cntError4 <= cntError4 + 1;
                        end
                        if (NextStateEv != DMP3Ev) begin
                            CntTmOut <= 0;
                        end else begin
                            CntTmOut <= CntTmOut + 1;
                        end
                    end
            DoneEv: begin
                        DMPStart2 <= 1'b0;
                        CntTmOut <= CntTmOut + 1;
                        if (CntTmOut==24'hffffff) cntError4 <= cntError4 + 1;
                    end
        endcase
    end
end

// State Machine to Read Out Local Registers

parameter [4:0] WaitRg = 5'b00001;         
parameter [4:0] ReadRg = 5'b00010;        
parameter [4:0] SendRg = 5'b00100;
parameter [4:0] DoneRg = 5'b01000;
parameter [4:0] WtDnRg = 5'b10000;

reg [4:0] StateRg, NextStateRg;
reg [5:0] CntRg;
reg [2:0] CntDly2;
reg [7:0] RegShift;
reg [3:0] NByteRg;
reg RegOutPut;

always @ (posedge SysCLK) begin
//    if (StateRg == WaitRg && RegOut) $display("Time  BrdAddress StateRg-StateRg     CntRg CntDly2 RegShift RegOutPut NByteRg DOutMux");
//    if (!Master && StateRg != WaitRg) $display("%g\t    %h     StateRg=%b         %d      %d       %b     %b    %d     %b",$time,BrdAddress,StateRg,CntRg,CntDly2,RegShift,RegOutPut,NByteRg,DOutMux);
end 

always @ (StateRg or RegOut or CntDly2 or RegShift[7] or CntRg or NByteRg or DataDone or This) begin
    case(StateRg)
        WaitRg:  begin
                     if (RegOut) NextStateRg = ReadRg;
                     else NextStateRg = WaitRg;
                     RegOutPut = 1'b0;
                 end
        ReadRg:  begin
                     NextStateRg = SendRg;
                     RegOutPut = 1'b1;
                 end
        SendRg:  begin
                     if (CntDly2 == 3'b111 && CntRg == NByteRg) NextStateRg = DoneRg;
                     else NextStateRg = SendRg;
                     RegOutPut = RegShift[7];
                 end
        DoneRg:  begin
                     NextStateRg = WtDnRg;
                     RegOutPut = RegShift[7];
                 end        
        WtDnRg:  begin
                     RegOutPut = 1'b0;
                     if (DataDone || CntRg > NByteRg + 7) NextStateRg = WaitRg;
                     else NextStateRg = WtDnRg;
                 end
        default: begin
                     NextStateRg = WaitRg;
                     RegOutPut = 1'b0;
                 end
    endcase
end

always @ (posedge SysCLK) begin
    if (ResetLocal) begin
        StateRg <= WaitRg;
    end else begin
        StateRg <= NextStateRg;
        case (StateRg)
            WaitRg: begin
                        CntRg <= 0;
                        NByteRg <= 6;
                    end
            ReadRg:  begin
                         RegShift <= RegData[CntRg];
                         CntDly2 <= 0;
                         CntRg <= CntRg + 1;
                     end
            SendRg:  begin
                         CntDly2 <= CntDly2 + 1;
                         if (CntDly2 == 3'b111) begin
                             if (CntRg == 1) NByteRg <= RegData[CntRg] + 6;
                             if (CntRg < NByteRg) begin
                                 RegShift <= RegData[CntRg];
                                 CntRg <= CntRg + 1;
                             end else begin
                                 RegShift <= 8'b00000000;
                             end
                         end else begin
                             RegShift <= {RegShift[6:0],1'b0};
                         end
                     end
            DoneRg:  begin
                         CntDly2 <= CntDly2 + 1;
                     end
            WtDnRg:  begin
                         CntDly2 <= CntDly2 + 1;
                         if (CntDly2 == 3'b111) begin
                             CntRg <= CntRg + 1;
                         end
                     end
        endcase
    end
end

// This data buffer is used only by the master board to buffer data and register/i2c information before sending it out to the UART
assign StartSgnl = DMPStart | DMPStart2;
wire [7:0] TxD_dataRAM;
wire [2:0] cntError5;
DataRAMbufferAESOP RamBuffer(.TxD_start(TxD_startRAM), .TxD_data(TxD_dataRAM), .TxD_busy(TxD_busy), .DMPDone(DMPDone), .DMPStart(StartSgnl), 
                             .SerialData(DOutMux), .Clock(SysCLK), .Reset(ResetLocal), .Done(DataDone), .Error(cntError5));

// i2c interface
wire [15:0] i2cRegOut;
wire [2:0] i2cError;
LoadIna226 LoadIna226_U(.Error(i2cError),.RegOut(i2cRegOut),.StrobeOut(StrobeOutIna),.SCL(SCLout),.SCLen(SCLen),.SDAout(SDAout),.SDAen(SDAen),.SDAin(SDAin),
                               .RegIn(i2cData),.Address(i2cAddr[6:0]),.StrobeIn(StrobeIna),.ReadCmd(i2cRdCmd),.Clock(SysCLK),.RstCmd(ResetI2c),.Reset(ResetLocal));                             

//State machine to insert TOT events into the output stream when the calibration strobe is used
//Some care by the user must be taken not to send a Read command too soon after the strobe, so that this does
//not conflict with the normal event output.

parameter [10:0] WaitTOT= 11'b00000000001; //Wait for a signal that a calibration strobe is starting
parameter [10:0] TReqTOT= 11'b00000000010; //Count until the TReq goes high
parameter [10:0] CTOTTOT= 11'b00000000100; //Count the TOT, until TReq goes low
parameter [10:0] SOutTOT= 11'b00000001000; //Initialize the output sequence, taking over the data output line
parameter [10:0] SHdrTOT= 11'b00000010000; //Shift out a 6-bit event header
parameter [10:0] SCluTOT= 11'b00000100000; //Shift out 6-bit cluster number, with exactly two "clusters" plus bit 4 set 
parameter [10:0] STrtTOT= 11'b00001000000; //Shift out the 12 bit start counter
parameter [10:0] STOTTOT= 11'b00010000000; //Shift out the 12 bit TOT counter.  Zero means that no TReq was encountered.  
parameter [10:0] SHitTOT= 11'b00100000000; //Shift out the 12-bit hit pattern.
parameter [10:0] SEndTOT= 11'b01000000000; //Tack a 1 bit onto the end of the stream
parameter [10:0] TailTOT= 11'b10000000000; //Add a trailer to the output
reg [10:0] StateTOT, NextStateTOT;
reg [11:0] CntStrt, CntTOT;
reg [11:0] TOTNclus;
reg [17:0] TOTHeader;
reg [6:0] CntShft;
parameter [11:0] MaxCnt= 12'd255;   //Maximum count allowed; careful with everyplace this is used if made larger than 255
reg [11:0] TReqLatch;               //Bit pattern of ASIC TReq signals received

always @ (StateTOT or CntStrt or CntTOT or CntShft or TOTHeader or TOTNclus or CalStrobe or TriggerOR or TReqLatch or MaxCnt)
begin
    case (StateTOT)
        WaitTOT:     begin
                        TOTdata = 1'b0;
                        if (CalStrobe) NextStateTOT = TReqTOT;
                        else NextStateTOT = WaitTOT;
                    end
        TReqTOT:    begin
                        TOTdata = 1'b0;
                        if (CntStrt == MaxCnt) NextStateTOT = SOutTOT;  //No TReq found; Send out empty event
                        else if (TriggerOR) NextStateTOT = CTOTTOT;
                        else NextStateTOT = TReqTOT;
                    end
        CTOTTOT:    begin
                        TOTdata = 1'b0;
                        if (!TriggerOR || CntTOT == MaxCnt) NextStateTOT = SOutTOT;
                        else NextStateTOT = CTOTTOT;
                    end
        SOutTOT:    begin
                        TOTdata = 1'b0;
                        NextStateTOT = SHdrTOT;
                    end
        SHdrTOT:    begin
                        if (CntShft == 17) begin
                            NextStateTOT = SCluTOT;
                        end else begin
                            NextStateTOT = SHdrTOT;
                        end
                        TOTdata = TOTHeader[17];
                    end
        SCluTOT:    begin
                        if (CntShft == 29) begin
                            NextStateTOT = STrtTOT;
                        end else begin
                            NextStateTOT = SCluTOT;
                        end
                        TOTdata = TOTNclus[11];
                    end
        STrtTOT:    begin
                        if (CntShft == 41) begin
                            NextStateTOT = STOTTOT;
                        end else begin
                            NextStateTOT = STrtTOT;
                        end
                        TOTdata = CntStrt[11];
                    end
        STOTTOT:    begin
                        if (CntShft == 53) begin
                            NextStateTOT = SHitTOT;
                        end else begin
                            NextStateTOT = STOTTOT;
                        end
                        TOTdata = CntTOT[11];
                    end
        SHitTOT:    begin
                        if (CntShft == 65) NextStateTOT = SEndTOT;
                        else NextStateTOT = SHitTOT;
                        TOTdata = TReqLatch[11];
                    end
        SEndTOT:    begin
                        NextStateTOT = TailTOT;
                        TOTdata = 1'b1;
                    end
        TailTOT:    begin
                        TOTdata = 1'b0;
                        if (CntShft == 127) NextStateTOT = WaitTOT;
                        else NextStateTOT = TailTOT;
                    end
        default:    begin
                        TOTdata = 1'b0;
                        NextStateTOT = WaitTOT;
                    end
    endcase
end

always @ (posedge SysCLK)
begin
    if (ResetLocal) begin
        StateTOT <= WaitTOT;
    end else begin
        StateTOT <= NextStateTOT;
        if (StateTOT == TReqTOT || StateTOT == CTOTTOT) begin
            if (TReqMSK[0]) TReqLatch[0] <= 1'b1;
            if (TReqMSK[1]) TReqLatch[1] <= 1'b1;
            if (TReqMSK[2]) TReqLatch[2] <= 1'b1;
            if (TReqMSK[3]) TReqLatch[3] <= 1'b1;
            if (TReqMSK[4]) TReqLatch[4] <= 1'b1;
            if (TReqMSK[5]) TReqLatch[5] <= 1'b1;
            if (TReqMSK[6]) TReqLatch[6] <= 1'b1;
            if (TReqMSK[7]) TReqLatch[7] <= 1'b1;
            if (TReqMSK[8]) TReqLatch[8] <= 1'b1;
            if (TReqMSK[9]) TReqLatch[9] <= 1'b1;
            if (TReqMSK[10]) TReqLatch[10] <= 1'b1;
            if (TReqMSK[11]) TReqLatch[11] <= 1'b1;                                    
        end
        if (BrdAddress == 8 && (StateTOT != WaitTOT || CalStrobe)) $display("%g\t StateTOT=%b, CmdData[2]=%d, CntStrt=%b, CntTOT=%b, TOTdata=%b, DOutMux=%b, CntShft=%d, TOTHeader=%b, TOTNclus=%b, TReqLatch=%b, TReq=%b",$time,StateTOT,CmdData[2],CntStrt,CntTOT,TOTdata,DOutMux,CntShft,TOTHeader,TOTNclus,TReqLatch,TReq); 
        case (StateTOT)
            WaitTOT:     begin
                            CntStrt <= 0;
                            CntTOT <= 0;
                            TReqLatch <= 0;
                        end
            TReqTOT:    begin
                            CntStrt <= CntStrt + 1;                
                        end
            CTOTTOT:    begin
                            CntTOT <= CntTOT + 1;
                        end
            SOutTOT:    begin
                            TOTNclus  <= 12'b010011001111;
                            TOTHeader <= {2'b11,BrdAddress,12'b111111100001};
                            CntShft <= 0;
                        end
            SHdrTOT:    begin
                            TOTHeader <= {TOTHeader[16:0],1'b0};
                            CntShft <= CntShft + 1;
                        end
            SCluTOT:    begin
                            TOTNclus <= {TOTNclus[10:0],1'b0};
                            CntShft <= CntShft + 1;
                        end
            STrtTOT:    begin
                            CntStrt <= {CntStrt[10:0],1'b0};
                            CntShft <= CntShft + 1;
                        end
            STOTTOT:    begin
                            CntTOT <= {CntTOT[10:0],1'b0};
                            CntShft <= CntShft + 1;
                        end
            SHitTOT:    begin
                            CntShft <= CntShft + 1;
                            TReqLatch <= {TReqLatch[10:0],1'b0};
                        end
            SEndTOT:    begin
                            CntShft <= 0;
                        end
            TailTOT:    begin
                            CntShft <= CntShft + 1;
                        end
        endcase
    end
end

// Keep these Debug outputs quiet when not needed, as they put CMOS signals out onto the PCB!  
// Note that none of these is currently connected to an output pin.                             
assign Debug1 = 1'b0; //GoInitialize;
assign Debug2 = 1'b0; //CMDinit;
assign Debug3 = 1'b0;
assign Debug4 = 1'b0;

 
endmodule
