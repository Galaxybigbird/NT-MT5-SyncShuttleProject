//+------------------------------------------------------------------+
//| StatusOverlay.mqh                                                |
//| Elastic Hedging Telemetry Overlay                               |
//+------------------------------------------------------------------+

// Global variables for overlay
string g_overlayPrefix = "ElasticOverlay_";
int g_overlayX = 10;
int g_overlayY = 50;
color g_overlayTextColor = clrWhite;
color g_overlayBackColor = clrDarkBlue;
int g_overlayFontSize = 9;
string g_overlayFont = "Consolas";

// Cushion band colors (adjusted for $300 account)
color GetCushionColor(double cushion)
{
    if(cushion >= 73) return clrLimeGreen;      // SAFE
    if(cushion >= 55) return clrYellow;         // LOW RISK
    if(cushion >= 37) return clrOrange;         // MEDIUM RISK
    if(cushion >= 19) return clrRed;            // HIGH RISK
    return clrDarkRed;                          // DANGER
}

// Initialize the status overlay
void InitStatusOverlay()
{
    // Create background rectangle
    string bgName = g_overlayPrefix + "Background";
    ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, g_overlayX);
    ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, g_overlayY);
    ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 300);
    ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 200);
    ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, g_overlayBackColor);
    ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, bgName, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, bgName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
    ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, bgName, OBJPROP_SELECTED, false);
    ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
    
    Print("StatusOverlay: Initialized background");
}

// Create or update a text label
void CreateOrUpdateLabel(string name, string text, int yOffset, color textColor = clrWhite)
{
    string fullName = g_overlayPrefix + name;
    
    if(ObjectFind(0, fullName) < 0)
    {
        ObjectCreate(0, fullName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, fullName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, fullName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
        ObjectSetInteger(0, fullName, OBJPROP_BACK, false);
        ObjectSetInteger(0, fullName, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, fullName, OBJPROP_SELECTED, false);
        ObjectSetInteger(0, fullName, OBJPROP_HIDDEN, true);
        ObjectSetString(0, fullName, OBJPROP_FONT, g_overlayFont);
        ObjectSetInteger(0, fullName, OBJPROP_FONTSIZE, g_overlayFontSize);
    }
    
    ObjectSetInteger(0, fullName, OBJPROP_XDISTANCE, g_overlayX + 5);
    ObjectSetInteger(0, fullName, OBJPROP_YDISTANCE, g_overlayY + yOffset);
    ObjectSetInteger(0, fullName, OBJPROP_COLOR, textColor);
    ObjectSetString(0, fullName, OBJPROP_TEXT, text);
}

// Global variables for caching overlay calculations
static double g_cached_next_lot_est = 0.0;
static datetime g_last_calculation_time = 0;
static double g_last_balance_for_calc = 0.0;
static double g_last_global_futures_for_calc = 0.0;
static bool g_force_recalculation = false;

// WHACK-A-MOLE FIX: Enhanced state tracking for better change detection
static double g_last_cushion_for_calc = 0.0;
static double g_last_ohf_for_calc = 0.0;
static double g_last_nt_balance_for_overlay = 0.0;
static double g_last_nt_daily_pnl_for_overlay = 0.0;
static string g_last_nt_result_for_overlay = "";
static int g_last_nt_session_trades_for_overlay = 0;
static datetime g_last_forced_recalc_time = 0;

// WHACK-A-MOLE DEBUG: Flag to enable/disable debug logging for overlay calculations
static bool g_overlay_debug_enabled = false; // Disable after fixing whack-a-mole issue

// Minimum time between forced recalculations (prevent spam)
const int MIN_FORCED_RECALC_INTERVAL = 30; // 30 seconds

// Force recalculation on next overlay update (call this when state changes)
void ForceOverlayRecalculation()
{
    // WHACK-A-MOLE FIX: Throttle forced recalculations to prevent spam
    datetime current_time = TimeCurrent();
    if(current_time - g_last_forced_recalc_time < MIN_FORCED_RECALC_INTERVAL)
    {
        if(g_overlay_debug_enabled) {
            Print("OVERLAY_THROTTLE: Ignoring forced recalculation request (too soon). Last: ",
                  TimeToString(g_last_forced_recalc_time), ", Current: ", TimeToString(current_time));
        }
        return;
    }

    g_force_recalculation = true;
    g_last_forced_recalc_time = current_time;

    if(g_overlay_debug_enabled) {
        Print("OVERLAY_FORCE: Forced recalculation scheduled at ", TimeToString(current_time));
    }
}

// Update the status overlay with current data
void UpdateStatusOverlay()
{
    // Only show overlay when in Elastic Hedging mode
    if(LotSizingMode != Elastic_Hedging)
    {
        RemoveStatusOverlay();
        return;
    }

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double cushion = g_lastCushion;
    double ohf = g_lastOHF;
    string mode = EnumToString(LotSizingMode);

    // WHACK-A-MOLE FIX: Enhanced change detection with more state variables
    bool balance_changed = (MathAbs(balance - g_last_balance_for_calc) > 0.01);
    bool futures_changed = (MathAbs(globalFutures - g_last_global_futures_for_calc) > 0.01);
    bool cushion_changed = (MathAbs(cushion - g_last_cushion_for_calc) > 0.01);
    bool ohf_changed = (MathAbs(ohf - g_last_ohf_for_calc) > 0.01);
    bool nt_data_changed = (MathAbs(g_lastNTBalance - g_last_nt_balance_for_overlay) > 0.01) ||
                          (MathAbs(g_ntDailyPnL - g_last_nt_daily_pnl_for_overlay) > 0.01) ||
                          (g_lastNTTradeResult != g_last_nt_result_for_overlay) ||
                          (g_ntSessionTrades != g_last_nt_session_trades_for_overlay);
    bool time_expired = (TimeCurrent() - g_last_calculation_time > 300); // 5 minutes max

    bool need_recalculation = g_force_recalculation || balance_changed || futures_changed ||
                             cushion_changed || ohf_changed || nt_data_changed || time_expired;

    double nextLotEst;
    if(need_recalculation)
    {
        if(g_overlay_debug_enabled) {
            Print("OVERLAY_CALC: Recalculation triggered - Force:", g_force_recalculation,
                  " Balance:", balance_changed, " Futures:", futures_changed,
                  " Cushion:", cushion_changed, " OHF:", ohf_changed,
                  " NT:", nt_data_changed, " Time:", time_expired);
        }

        // Only call CalcHedgeLot when state has actually changed
        nextLotEst = CalcHedgeLot(DefaultLot);

        // Update all cached values
        g_cached_next_lot_est = nextLotEst;
        g_last_calculation_time = TimeCurrent();
        g_last_balance_for_calc = balance;
        g_last_global_futures_for_calc = globalFutures;
        g_last_cushion_for_calc = cushion;
        g_last_ohf_for_calc = ohf;
        g_last_nt_balance_for_overlay = g_lastNTBalance;
        g_last_nt_daily_pnl_for_overlay = g_ntDailyPnL;
        g_last_nt_result_for_overlay = g_lastNTTradeResult;
        g_last_nt_session_trades_for_overlay = g_ntSessionTrades;
        g_force_recalculation = false;

        if(g_overlay_debug_enabled) {
            Print("OVERLAY_CALC: Recalculated lot estimate: ", nextLotEst,
                  " (Balance: $", balance, ", Futures: ", globalFutures,
                  ", Cushion: $", cushion, ", OHF: ", ohf, ")");
        }
    }
    else
    {
        // Use cached value to avoid triggering whack-a-mole calculations
        nextLotEst = g_cached_next_lot_est;

        if(g_overlay_debug_enabled && (TimeCurrent() % 60 == 0)) { // Log once per minute when using cache
            Print("OVERLAY_CACHE: Using cached lot estimate: ", nextLotEst, " (no state changes detected)");
        }
    }

    // Count hedge positions
    int openHedgeCount = CountAllHedgePositions();
    
    color cushionColor = GetCushionColor(cushion);
    
    // Create title
    CreateOrUpdateLabel("Title", "=== ELASTIC HEDGING TELEMETRY ===", 5, clrCyan);
    
    // Balance
    CreateOrUpdateLabel("Balance", StringFormat("Balance:        $%.2f", balance), 25);
    
    // EOD High
    CreateOrUpdateLabel("EODHigh", StringFormat("EOD High:       $%.2f", g_highWaterEOD), 40);
    
    // Cushion with color coding
    CreateOrUpdateLabel("Cushion", StringFormat("Cushion:        $%.2f", cushion), 55, cushionColor);
    
    // OHF
    CreateOrUpdateLabel("OHF", StringFormat("OHF:            %.3f", ohf), 70);
    
    // Mode
    CreateOrUpdateLabel("Mode", StringFormat("Mode:           %s", mode), 85);
    
    // Next lot estimate
    CreateOrUpdateLabel("NextLot", StringFormat("Next Lot (est): %.2f", nextLotEst), 100);
    
    // Global Futures
    CreateOrUpdateLabel("GlobalFutures", StringFormat("Global Futures: %.0f", globalFutures), 115);
    
    // Desired hedges
    CreateOrUpdateLabel("DesiredHedges", StringFormat("Desired Hedges: %.0f", MathAbs(globalFutures)), 130);
    
    // Open hedge count
    CreateOrUpdateLabel("OpenHedges", StringFormat("Open Hedges:    %d", openHedgeCount), 145);
    
    // Cushion band description
    string bandDesc = "";
    if(cushion >= 120) bandDesc = "SAFE";
    else if(cushion >= 80) bandDesc = "LOW RISK";
    else if(cushion >= 50) bandDesc = "MEDIUM RISK";
    else if(cushion >= 25) bandDesc = "HIGH RISK";
    else bandDesc = "DANGER";
    
    CreateOrUpdateLabel("BandDesc", StringFormat("Risk Level:     %s", bandDesc), 160, cushionColor);
    
    // Last update time
    CreateOrUpdateLabel("LastUpdate", StringFormat("Updated:        %s", TimeToString(TimeCurrent(), TIME_SECONDS)), 175, clrGray);
}

// Count current hedge positions (all types)
int CountAllHedgePositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0)
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                string comment = PositionGetString(POSITION_COMMENT);
                if(StringFind(comment, CommentPrefix) >= 0)
                {
                    count++;
                }
            }
        }
    }
    return count;
}

// Remove the status overlay
void RemoveStatusOverlay()
{
    string objects[] = {
        "Background", "Title", "Balance", "EODHigh", "Cushion", "OHF", 
        "Mode", "NextLot", "GlobalFutures", "DesiredHedges", "OpenHedges", 
        "BandDesc", "LastUpdate"
    };
    
    for(int i = 0; i < ArraySize(objects); i++)
    {
        string fullName = g_overlayPrefix + objects[i];
        if(ObjectFind(0, fullName) >= 0)
        {
            ObjectDelete(0, fullName);
        }
    }
}
