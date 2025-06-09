//+------------------------------------------------------------------+
//|                                                ATRtrailing.mqh |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023"
#property link      ""
#property version   "1.01"
#property strict

// Input parameters for DEMA-ATR trailing stop
input group    "=====DEMA-ATR Trailing=====";
input int      DEMA_ATR_Period = 14;       // Period for DEMA-ATR calculation
input double   DEMA_ATR_Multiplier = 1.5;  // DEMA-ATR trailing distance multiplier
input double   TrailingActivationPercent = 1.0; // Activate trailing at this profit %
input bool     UseATRTrailing = true;      // Enable DEMA-ATR trailing stop
// These are now set from the EA
int      TrailingButtonXDistance = 120; // X distance for trailing button position
int      TrailingButtonYDistance = 20;  // Y distance for trailing button position

input double   MinimumStopDistance = 400.0; // Minimum stop distance in points

// Global variables for button and manual activation
string         ButtonName = "StartTrailing";  // Unique name for the button
bool           ManualTrailingActivated = false;  // Flag for manual trailing activation
color          ButtonColorActive = clrLime;     // Button color when trailing is active
color          ButtonColorInactive = clrGray;   // Button color when trailing is inactive

// Buffers for DEMA ATR calculation
double AtrDEMA[], Ema1[], Ema2[];  // buffers for DEMA ATR, and intermediate EMAs

// Variables to store modifiable versions of input parameters
double CurrentATRMultiplier;            // Current ATR multiplier (can be modified)
int CurrentATRPeriod;                   // Current ATR period (can be modified)

// Statistics tracking
int SuccessfulTrailingUpdates = 0;
int FailedTrailingUpdates = 0;
double WorstCaseSlippage = 0;
double BestCaseProfit = 0;

//+------------------------------------------------------------------+
//| Clean up all objects when EA is removed                           |
//+------------------------------------------------------------------+
void CleanupATRTrailing()
{
    // Print final statistics
    if(SuccessfulTrailingUpdates > 0 || FailedTrailingUpdates > 0)
    {
        Print("=== ATR Trailing Summary ===");
        Print("Successful trailing updates: ", SuccessfulTrailingUpdates);
        Print("Failed trailing updates: ", FailedTrailingUpdates);
        
        if(SuccessfulTrailingUpdates > 0)
        {
            double successRate = 100.0 * SuccessfulTrailingUpdates / (SuccessfulTrailingUpdates + FailedTrailingUpdates);
            Print("Success rate: ", DoubleToString(successRate, 2), "%");
            Print("Worst-case slippage distance: ", DoubleToString(WorstCaseSlippage * Point(), _Digits), " points");
            Print("Best-case profit distance: ", DoubleToString(BestCaseProfit * Point(), _Digits), " points");
        }
        Print("==========================");
    }
    
    // Delete the trailing button
    ObjectDelete(0, ButtonName);
    
    // Clear all visualization
    ClearVisualization();
    
    // Delete ALL objects with our name prefixes to ensure complete cleanup
    int totalObjects = ObjectsTotal(0);
    for(int i = totalObjects - 1; i >= 0; i--)
    {
        string objName = ObjectName(0, i);
        
        // Check if this is one of our objects using more comprehensive criteria
        if(StringFind(objName, "ATR") >= 0 || 
           StringFind(objName, "Trailing") >= 0 ||
           StringFind(objName, "DEMA") >= 0 ||
           StringFind(objName, "Trail") >= 0 || 
           StringFind(objName, "SL") >= 0 || 
           StringFind(objName, "Test") >= 0 || 
           StringFind(objName, "Vol") >= 0 || 
           StringFind(objName, "Buy") >= 0 || 
           StringFind(objName, "Sell") >= 0 || 
           StringFind(objName, "Level") >= 0 || 
           StringFind(objName, "Label") >= 0 || 
           StringFind(objName, "Msg") >= 0 ||
           StringFind(objName, "Button") >= 0)
        {
            ObjectDelete(0, objName);
        }
    }
    
    // Also delete all test-specific objects and labels
    for(int i = 0; i <= 100; i++)
    {
        ObjectDelete(0, "TestLabel" + IntegerToString(i));
        ObjectDelete(0, "Test_" + IntegerToString(i));
        ObjectDelete(0, "TestResult" + IntegerToString(i));
    }
    
    // Clean all buttons
    for(int i = 0; i < ObjectsTotal(0); i++)
    {
        string objName = ObjectName(0, i);
        if(ObjectGetInteger(0, objName, OBJPROP_TYPE) == OBJ_BUTTON)
        {
            ObjectDelete(0, objName);
        }
    }
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Initialize DEMA-ATR arrays and settings                          |
//+------------------------------------------------------------------+
void InitDEMAATR()
{
    // Initialize working parameters with input values
    CurrentATRMultiplier = DEMA_ATR_Multiplier;
    CurrentATRPeriod = DEMA_ATR_Period;
    
    // Initialize arrays
    ArrayResize(AtrDEMA, 100);
    ArrayResize(Ema1, 100);
    ArrayResize(Ema2, 100);
    ArrayInitialize(AtrDEMA, 0);
    ArrayInitialize(Ema1, 0);
    ArrayInitialize(Ema2, 0);
    
    // Create the Start Trailing button in top-right corner
    ObjectCreate(0, ButtonName, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, ButtonName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
    ObjectSetInteger(0, ButtonName, OBJPROP_XDISTANCE, TrailingButtonXDistance);
    ObjectSetInteger(0, ButtonName, OBJPROP_YDISTANCE, TrailingButtonYDistance);
    ObjectSetInteger(0, ButtonName, OBJPROP_XSIZE, 100);
    ObjectSetInteger(0, ButtonName, OBJPROP_YSIZE, 20);
    ObjectSetString(0, ButtonName, OBJPROP_TEXT, "Start Trailing");
    ObjectSetInteger(0, ButtonName, OBJPROP_COLOR, ButtonColorInactive);
    ObjectSetInteger(0, ButtonName, OBJPROP_BGCOLOR, clrWhite);
    ObjectSetInteger(0, ButtonName, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, ButtonName, OBJPROP_FONTSIZE, 10);
    
    // Reset statistics
    ResetTrailingStats();
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Reset trailing stop statistics                                    |
//+------------------------------------------------------------------+
void ResetTrailingStats()
{
    SuccessfulTrailingUpdates = 0;
    FailedTrailingUpdates = 0;
    WorstCaseSlippage = 0;
    BestCaseProfit = 0;
}

//+------------------------------------------------------------------+
//| Calculate DEMA-ATR value for the current bar                     |
//+------------------------------------------------------------------+
double CalculateDEMAATR(int period = 0)
{
    int atrPeriod = (period > 0) ? period : CurrentATRPeriod;
    
    // Get price data for calculation
    MqlRates rates[];
    int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, atrPeriod + 1 + period, rates);
    
    if(copied < atrPeriod + 1 + period)
    {
        Print("Error copying rates data: ", GetLastError());
        return 0.0;
    }
    
    double alpha = 2.0 / (atrPeriod + 1);  // EMA smoothing factor for DEMA
    
    // Calculate initial ATR if needed
    if(Ema1[0] == 0)
    {
        double sumTR = 0.0;
        for(int j = 0; j < atrPeriod; j++)
        {
            int idx = copied - 1 - j;
            double trj;
            if(j == 0)
                trj = rates[idx].high - rates[idx].low;
            else
            {
                double tr1 = rates[idx].high - rates[idx].low;
                double tr2 = MathAbs(rates[idx].high - rates[idx+1].close);
                double tr3 = MathAbs(rates[idx].low - rates[idx+1].close);
                trj = MathMax(tr1, MathMax(tr2, tr3));
            }
            sumTR += trj;
        }
        double initialATR = sumTR / atrPeriod;
        Ema1[0] = initialATR;
        Ema2[0] = initialATR;
        AtrDEMA[0] = initialATR;
    }
    
    // Calculate current TR
    double TR_current;
    int current = copied - 1 - period;
    int prev = copied - 2 - period;
    
    if(prev < 0)
    {
        TR_current = rates[current].high - rates[current].low;
    }
    else
    {
        double tr1 = rates[current].high - rates[current].low;
        double tr2 = MathAbs(rates[current].high - rates[prev].close);
        double tr3 = MathAbs(rates[current].low - rates[prev].close);
        TR_current = MathMax(tr1, MathMax(tr2, tr3));
    }
    
    // Update EMA1, EMA2, and DEMA-ATR
    double ema1_current = Ema1[0] + alpha * (TR_current - Ema1[0]);
    double ema2_current = Ema2[0] + alpha * (ema1_current - Ema2[0]);
    double dema_atr = 2.0 * ema1_current - ema2_current;
    
    // Store values for next calculation
    Ema1[0] = ema1_current;
    Ema2[0] = ema2_current;
    AtrDEMA[0] = dema_atr;
    
    return dema_atr;
}

//+------------------------------------------------------------------+
//| Check if trailing stop should be activated                       |
//+------------------------------------------------------------------+

// WHACK-A-MOLE FIX: Cache trailing stop checks to prevent excessive logging
struct TrailingCheckCache {
    ulong ticket;
    datetime last_check_time;
    bool last_result;
    double last_price;
    double last_profit_percent;
};

static TrailingCheckCache g_trailing_cache[];
static int g_trailing_cache_size = 0;
static const int TRAILING_CHECK_INTERVAL = 5; // Check every 5 seconds max
static const double PRICE_CHANGE_THRESHOLD = 0.1; // Only recalculate if price changes by 0.1%

// Helper function to update cache
void UpdateTrailingCache(ulong ticket, datetime check_time, bool result, double price, double profit_percent)
{
    int cache_index = -1;

    // Find existing cache entry
    for(int i = 0; i < g_trailing_cache_size; i++) {
        if(g_trailing_cache[i].ticket == ticket) {
            cache_index = i;
            break;
        }
    }

    // Create new cache entry if not found
    if(cache_index < 0) {
        ArrayResize(g_trailing_cache, g_trailing_cache_size + 1);
        cache_index = g_trailing_cache_size;
        g_trailing_cache_size++;
    }

    // Update cache entry
    g_trailing_cache[cache_index].ticket = ticket;
    g_trailing_cache[cache_index].last_check_time = check_time;
    g_trailing_cache[cache_index].last_result = result;
    g_trailing_cache[cache_index].last_price = price;
    g_trailing_cache[cache_index].last_profit_percent = profit_percent;
}

bool ShouldActivateTrailing(ulong ticket, double entryPrice, double currentPrice, string orderType, double volume)
{
    if(!UseATRTrailing && !ManualTrailingActivated) // Also check manual activation here
    {
        // Only print this message once per minute to reduce spam
        static datetime last_disabled_message = 0;
        if(TimeCurrent() - last_disabled_message > 60) {
            PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Trailing disabled and not manually activated. Skipping.",
                        IntegerToString(ticket));
            last_disabled_message = TimeCurrent();
        }
        return false;
    }

    // WHACK-A-MOLE FIX: Check cache first
    datetime current_time = TimeCurrent();
    int cache_index = -1;

    // Find existing cache entry
    for(int i = 0; i < g_trailing_cache_size; i++) {
        if(g_trailing_cache[i].ticket == ticket) {
            cache_index = i;
            break;
        }
    }

    // Check if we can use cached result
    if(cache_index >= 0) {
        TrailingCheckCache cache_entry = g_trailing_cache[cache_index];
        double price_change_percent = MathAbs((currentPrice - cache_entry.last_price) / cache_entry.last_price) * 100.0;

        // Use cached result if:
        // 1. Not enough time has passed AND
        // 2. Price hasn't changed significantly
        if((current_time - cache_entry.last_check_time < TRAILING_CHECK_INTERVAL) &&
           (price_change_percent < PRICE_CHANGE_THRESHOLD)) {
            return cache_entry.last_result;
        }
    }

    // If manual activation is enabled, it should always activate if UseATRTrailing is true or if manual override is intended
    if(ManualTrailingActivated)
    {
        // Update cache and return true
        bool result = true;
        UpdateTrailingCache(ticket, current_time, result, currentPrice, 100.0); // 100% profit for manual mode

        // Only print this message occasionally to reduce spam
        static datetime last_manual_message = 0;
        if(TimeCurrent() - last_manual_message > 10) {
            PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Manual trailing is active. Activation TRUE.",
                        IntegerToString(ticket));
            last_manual_message = TimeCurrent();
        }
        return result;
    }

    // Calculate profit metrics
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    if (accountBalance == 0) // Avoid division by zero
    {
        bool result = false;
        UpdateTrailingCache(ticket, current_time, result, currentPrice, 0.0);
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - AccountBalance is zero. Cannot calculate profit percent. Activation FALSE.", IntegerToString(ticket));
        return result;
    }
    double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    if (pointValue == 0) // Avoid division by zero
    {
        bool result = false;
        UpdateTrailingCache(ticket, current_time, result, currentPrice, 0.0);
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - PointValue is zero. Cannot calculate profit points. Activation FALSE.", IntegerToString(ticket));
        return result;
    }
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pipValue = tickValue * (pointValue / tickSize); // This might be problematic if tickSize is 0, though unlikely for valid symbols

    // WHACK-A-MOLE FIX: Reduce initial logging spam - only log occasionally
    static datetime last_input_log = 0;
    if(TimeCurrent() - last_input_log > 60) { // Log inputs only once per minute
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Checking. OpenPrice: %s, CurrentPrice: %s, Type: %s, Volume: %s",
                    IntegerToString(ticket), DoubleToString(entryPrice, _Digits), DoubleToString(currentPrice, _Digits), orderType, DoubleToString(volume, 2));
        last_input_log = TimeCurrent();
    }

    // Calculate profit in account currency
    double priceDiff = 0;
    if(orderType == "BUY")
        priceDiff = currentPrice - entryPrice;
    else if(orderType == "SELL")
        priceDiff = entryPrice - currentPrice;
    else
    {
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Unknown order type '%s'. Activation FALSE.", IntegerToString(ticket), orderType);
        return false; // Unknown order type
    }

    double profitPoints = priceDiff / pointValue;
    double profitCurrency = profitPoints * pipValue * volume; // Note: Assumes volume is in base units for pipValue calc. Standard lots.
    
    // Calculate profit as percentage of account balance
    double profitPercent = (profitCurrency / accountBalance) * 100.0;

    // Check if profit percentage exceeds activation threshold
    bool activationMet = (profitPercent >= (TrailingActivationPercent - 0.0000001));

    // WHACK-A-MOLE FIX: Update cache with new result
    UpdateTrailingCache(ticket, current_time, activationMet, currentPrice, profitPercent);

    // WHACK-A-MOLE FIX: Only print detailed logs occasionally to reduce spam
    static datetime last_detailed_log = 0;
    bool should_log_details = (TimeCurrent() - last_detailed_log > 30) || activationMet; // Log every 30 seconds or when activated

    if(should_log_details) {
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Calculated Profit: Points: %s, Currency: %s, Percent: %s%%. Required Percent: %s%%.",
                    IntegerToString(ticket), DoubleToString(profitPoints, 2), DoubleToString(profitCurrency, 2),
                    DoubleToString(profitPercent, 4), DoubleToString(TrailingActivationPercent, 4));
        PrintFormat("TrailingStop::ShouldActivateTrailing (Ticket: %s) - Activation Condition Met: %s.",
                    IntegerToString(ticket), activationMet ? "TRUE" : "FALSE");

        if(!activationMet) {
            last_detailed_log = TimeCurrent();
        }
    }

    return activationMet;
}

//+------------------------------------------------------------------+
//| Calculate trailing stop level based on DEMA-ATR                  |
//+------------------------------------------------------------------+
double CalculateTrailingStop(string orderType, double currentPrice, double originalStop = 0.0)
{
    double demaAtr = CalculateDEMAATR();
    double trailingDistance = MathMax(demaAtr * CurrentATRMultiplier, MinimumStopDistance * Point());
    
    // Calculate theoretical trailing stop level based on order type
    double theoreticalStop;
    
    if(orderType == "BUY")
        theoreticalStop = currentPrice - trailingDistance;
    else
        theoreticalStop = currentPrice + trailingDistance;
    
    PrintFormat("DIAGNOSTIC::CalculateTrailingStop - Type: %s, CurrentPrice: %s, OriginalStop: %s, ATR: %s, TrailingDist: %s, TheoreticalStop: %s",
                orderType, DoubleToString(currentPrice, _Digits), DoubleToString(originalStop, _Digits),
                DoubleToString(demaAtr, _Digits), DoubleToString(trailingDistance, _Digits), DoubleToString(theoreticalStop, _Digits));
    
    // TEMPORARY FIX: Disable conservative checks to force trailing to work
    // If we have an original stop, only move in favorable direction
    if(originalStop > 0.0)
    {
        // *** EXTREME VOLATILITY CHECK - TEMPORARILY DISABLED ***
        // Detect extreme volatility - when ATR is abnormally high (over 500 points)
        if(false) // DISABLED: demaAtr/Point() > 500)
        {
            PrintFormat("DIAGNOSTIC::CalculateTrailingStop - EXTREME VOLATILITY DETECTED: ATR %s points > 500", DoubleToString(demaAtr/Point(), 2));
            bool extremeVolatilityDetected = true;
            
            // During extreme volatility, always keep the more conservative stop
            // Corrected logic: keep originalStop if it's more conservative
            if(orderType == "BUY" && originalStop < theoreticalStop) // originalStop is lower (more conservative for BUY)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - EXTREME VOLATILITY: Keeping original BUY stop %s (more conservative than theoretical %s)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                return originalStop;
            }
            else if(orderType == "SELL" && originalStop > theoreticalStop) // originalStop is higher (more conservative for SELL)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - EXTREME VOLATILITY: Keeping original SELL stop %s (more conservative than theoretical %s)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                return originalStop;
            }
        }
        
        // *** VERY DISTANT STOP CHECK - TEMPORARILY DISABLED ***
        // For stops that are already very far from current price (conservative stops)
        double stopDistancePoints = MathAbs(originalStop - currentPrice)/Point();
        PrintFormat("DIAGNOSTIC::CalculateTrailingStop - DISTANT STOP CHECK: Distance %s points (threshold: 1500) - CHECK DISABLED", DoubleToString(stopDistancePoints, 2));
        
        if(false) // DISABLED: orderType == "BUY")
        {
            // If stop is more than 1500 points from current price, consider it a very distant stop
            if(stopDistancePoints > 1500)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - BUY DISTANT STOP: %s points > 1500, checking conservatism", DoubleToString(stopDistancePoints, 2));
                // If the original stop is more conservative than theoretical stop
                if(originalStop < theoreticalStop)
                {
                    PrintFormat("DIAGNOSTIC::CalculateTrailingStop - BUY DISTANT STOP: Keeping original %s (more conservative than theoretical %s)",
                               DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                    return originalStop;
                }
            }
        }
        else if(false) // DISABLED: orderType == "SELL")
        {
            // If stop is more than 1500 points from current price, consider it a very distant stop
            if(stopDistancePoints > 1500)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - SELL DISTANT STOP: %s points > 1500, checking conservatism", DoubleToString(stopDistancePoints, 2));
                // If the original stop is more conservative than theoretical stop
                if(originalStop > theoreticalStop)
                {
                    PrintFormat("DIAGNOSTIC::CalculateTrailingStop - SELL DISTANT STOP: Keeping original %s (more conservative than theoretical %s)",
                               DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                    return originalStop;
                }
            }
        }
        
        // Normal direction checks
        if(orderType == "BUY")
        {
            // For buy positions, only move the stop up, never down
            // CORRECTED LOGIC: For BUY positions, we want to trail UP (higher stop values)
            // But the original logic was correct - we should only move if theoretical > original
            // The real issue might be that theoretical stop is always equal to original
            if(theoreticalStop <= originalStop)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - BUY DIRECTION CHECK: Keeping original stop %s (theoretical %s <= original)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                return originalStop;
            }
            
            // During extreme volatility, the stop might move too close to entry
            // If the original stop is very far (conservative), keep it
            double currentToTheoreticalDist = MathAbs(currentPrice - theoreticalStop);
            double currentToOriginalDist = MathAbs(currentPrice - originalStop);
            PrintFormat("DIAGNOSTIC::CalculateTrailingStop - BUY VOLATILITY CHECK: TheoreticalDist %s, OriginalDist %s, Ratio %s",
                       DoubleToString(currentToTheoreticalDist, _Digits), DoubleToString(currentToOriginalDist, _Digits),
                       DoubleToString(currentToTheoreticalDist / currentToOriginalDist, 4));
            if(false) // DISABLED: currentToTheoreticalDist < currentToOriginalDist * 0.5)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - BUY VOLATILITY CHECK: Keeping original stop %s (theoretical %s too close to price)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                // If extreme volatility would make stop less conservative, keep original
                return originalStop;
            }
        }
        else if(orderType == "SELL")
        {
            // For sell positions, only move the stop down, never up
            // For sell positions, only move the stop down. Allow equal to pass to next check.
            if(theoreticalStop > originalStop)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - SELL DIRECTION CHECK: Keeping original stop %s (theoretical %s would move stop UP)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                return originalStop;
            }
            
            // During extreme volatility, the stop might move too close to entry
            // If the original stop is very far (conservative), keep it
            double currentToTheoreticalDist = MathAbs(currentPrice - theoreticalStop);
            double currentToOriginalDist = MathAbs(currentPrice - originalStop);
            PrintFormat("DIAGNOSTIC::CalculateTrailingStop - SELL VOLATILITY CHECK: TheoreticalDist %s, OriginalDist %s, Ratio %s",
                       DoubleToString(currentToTheoreticalDist, _Digits), DoubleToString(currentToOriginalDist, _Digits),
                       DoubleToString(currentToTheoreticalDist / currentToOriginalDist, 4));
            if(false) // DISABLED: currentToTheoreticalDist < currentToOriginalDist * 0.5)
            {
                PrintFormat("DIAGNOSTIC::CalculateTrailingStop - SELL VOLATILITY CHECK: Keeping original stop %s (theoretical %s too close to price)",
                           DoubleToString(originalStop, _Digits), DoubleToString(theoreticalStop, _Digits));
                // If extreme volatility would make stop less conservative, keep original
                return originalStop;
            }
        }
    }
    
    // Return the new stop level
    PrintFormat("DIAGNOSTIC::CalculateTrailingStop - FINAL RESULT: Returning theoretical stop %s", DoubleToString(theoreticalStop, _Digits));
    return theoreticalStop;
}

//+------------------------------------------------------------------+
//| Update trailing stop for a position                              |
//+------------------------------------------------------------------+
bool UpdateTrailingStop(ulong ticket, double entryPrice, string orderType)
{
    PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Attempting to update.", IntegerToString(ticket));

    // CRITICAL FIX: Force trailing to be active without checking settings
    bool forceTrailing = ManualTrailingActivated;
    if(!UseATRTrailing && !forceTrailing)
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Trailing disabled and not manually activated. Skipping update.", IntegerToString(ticket));
        return false;
    }
    
    // Get position information - try select by ticket first
    if(!PositionSelectByTicket(ticket))
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - ERROR: Cannot select position. Error: %d", IntegerToString(ticket), GetLastError());
        return false;
    }
    
    // Get current position data
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
    double currentTP = PositionGetDouble(POSITION_TP);
    double positionOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN); // Use actual open price for logging consistency

    PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Position Open: %s, Current Price: %s, Current SL: %s, Current TP: %s, Type: %s",
                IntegerToString(ticket), DoubleToString(positionOpenPrice, _Digits), DoubleToString(currentPrice, _Digits),
                DoubleToString(currentSL, _Digits), DoubleToString(currentTP, _Digits), orderType);

    // Calculate new trailing stop level
    double demaAtr = CalculateDEMAATR(); // For logging ATR value
    
    // DIAGNOSTIC: Log detailed calculation steps
    double trailingDistance = MathMax(demaAtr * CurrentATRMultiplier, MinimumStopDistance * Point());
    double theoreticalStop;
    if(orderType == "BUY")
        theoreticalStop = currentPrice - trailingDistance;
    else
        theoreticalStop = currentPrice + trailingDistance;
    
    PrintFormat("DIAGNOSTIC::TrailingStop (Ticket: %s) - ATR: %s, Multiplier: %s, MinDist: %s points, TrailingDist: %s, TheoreticalStop: %s",
                IntegerToString(ticket), DoubleToString(demaAtr, _Digits), DoubleToString(CurrentATRMultiplier, 2),
                DoubleToString(MinimumStopDistance, 0), DoubleToString(trailingDistance, _Digits), DoubleToString(theoreticalStop, _Digits));
    
    double newSL = CalculateTrailingStop(orderType, currentPrice, currentSL);
    
    PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - ATR Value: %s, Calculated New SL: %s (after all checks)",
                IntegerToString(ticket), DoubleToString(demaAtr, _Digits), DoubleToString(newSL, _Digits));

    // AGGRESSIVE MANUAL TRAILING: Force it to move on manual activation
    if(ManualTrailingActivated)
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Manual trailing activated. Applying aggressive logic.", IntegerToString(ticket));
        // double atrValue = CalculateDEMAATR(); // Already calculated as demaAtr
        double trailingDistance = MathMax(demaAtr * CurrentATRMultiplier, MinimumStopDistance * Point());
        
        if(orderType == "BUY")
        {
            double forcedStop = currentPrice - trailingDistance * 0.8;  // 20% tighter
            PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Manual BUY. CurrentPrice: %s, TrailingDistance: %s, ForcedStop (0.8*Dist): %s",
                        IntegerToString(ticket), DoubleToString(currentPrice, _Digits), DoubleToString(trailingDistance, _Digits), DoubleToString(forcedStop, _Digits));
            if(forcedStop > currentSL || currentSL == 0.0) // Allow setting SL if currentSL is 0
            {
                newSL = forcedStop;
                PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - MANUAL TRAILING FORCE: Moving BUY stop to %s (was %s)",
                            IntegerToString(ticket), DoubleToString(newSL, _Digits), DoubleToString(currentSL, _Digits));
            }
            else
            {
                PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - MANUAL TRAILING: Cannot move BUY stop up further. ForcedStop %s <= CurrentSL %s.",
                            IntegerToString(ticket), DoubleToString(forcedStop, _Digits), DoubleToString(currentSL, _Digits));
                return false;
            }
        }
        else if(orderType == "SELL")
        {
            double forcedStop = currentPrice + trailingDistance * 0.8;  // 20% tighter
            PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Manual SELL. CurrentPrice: %s, TrailingDistance: %s, ForcedStop (0.8*Dist): %s",
                        IntegerToString(ticket), DoubleToString(currentPrice, _Digits), DoubleToString(trailingDistance, _Digits), DoubleToString(forcedStop, _Digits));
            if(forcedStop < currentSL || currentSL == 0.0) // Allow setting SL if currentSL is 0
            {
                newSL = forcedStop;
                PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - MANUAL TRAILING FORCE: Moving SELL stop to %s (was %s)",
                            IntegerToString(ticket), DoubleToString(newSL, _Digits), DoubleToString(currentSL, _Digits));
            }
            else
            {
                PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - MANUAL TRAILING: Cannot move SELL stop down further. ForcedStop %s >= CurrentSL %s.",
                            IntegerToString(ticket), DoubleToString(forcedStop, _Digits), DoubleToString(currentSL, _Digits));
                return false;
            }
        }
    }
    
    // Only update if there's a meaningful change (more than 1 point, or if currentSL is 0)
    if(MathAbs(newSL - currentSL) < Point() && currentSL != 0.0)
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - No meaningful change in SL. NewSL: %s, CurrentSL: %s. Skipping update.",
                    IntegerToString(ticket), DoubleToString(newSL, _Digits), DoubleToString(currentSL, _Digits));
        return false;
    }
    
    // Verify the stop is moving in the correct direction (or being set for the first time)
    bool shouldUpdateStop = false;
    if(orderType == "BUY" && (newSL > currentSL || currentSL == 0.0))
    {
        shouldUpdateStop = true;
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Moving BUY stop up from %s to %s.",
                    IntegerToString(ticket), DoubleToString(currentSL, _Digits), DoubleToString(newSL, _Digits));
    }
    else if(orderType == "SELL" && (newSL < currentSL || currentSL == 0.0))
    {
        shouldUpdateStop = true;
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Moving SELL stop down from %s to %s.",
                    IntegerToString(ticket), DoubleToString(currentSL, _Digits), DoubleToString(newSL, _Digits));
    }
    
    if(!shouldUpdateStop)
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Stop not moving in favorable direction or not initial setup. NewSL: %s, CurrentSL: %s, Type: %s. Skipping update.",
                    IntegerToString(ticket), DoubleToString(newSL, _Digits), DoubleToString(currentSL, _Digits), orderType);
        return false;
    }
    
    // Prepare the trade request
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.symbol = _Symbol;
    request.sl = NormalizeDouble(newSL, _Digits); // Normalize SL
    request.tp = currentTP;  // Keep existing TP
    
    PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - SENDING OrderModify. New SL: %s, Current TP: %s.",
                IntegerToString(ticket), DoubleToString(request.sl, _Digits), DoubleToString(request.tp, _Digits));
    
    // Send the request
    if(!OrderSend(request, result))
    {
        PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - ERROR updating trailing stop. OrderSend failed. Error: %d, Retcode: %d, Comment: %s",
                    IntegerToString(ticket), GetLastError(), result.retcode, result.comment);
        FailedTrailingUpdates++;
        return false;
    }
    
    // Success - log the update and update stats
    PrintFormat("TrailingStop::UpdateTrailingStop (Ticket: %s) - Trailing stop activated and SL modified for position %s to %s. Mode: %s. OrderSend Result Retcode: %d, Comment: %s",
                IntegerToString(ticket), IntegerToString(ticket), DoubleToString(request.sl, _Digits),
                ManualTrailingActivated ? "Manual" : "Auto", result.retcode, result.comment);
    
    SuccessfulTrailingUpdates++;
    
    // Update tracking stats
    double potentialSlippage = MathAbs(currentPrice - newSL) / Point(); // This is not really slippage, but distance to new SL
    if(potentialSlippage > WorstCaseSlippage) // This logic might need review for what it's tracking
        WorstCaseSlippage = potentialSlippage;
        
    double profitInPoints = MathAbs(currentPrice - entryPrice) / Point();
    if(profitInPoints > BestCaseProfit)
        BestCaseProfit = profitInPoints;
    
    return true;
}

//+------------------------------------------------------------------+
//| Update visualization of ATR trailing stop levels                  |
//+------------------------------------------------------------------+
void UpdateVisualization()
{
    // Clear previous statistics objects
    ObjectDelete(0, "StatsLabel");
    
    // Draw statistics (always enabled)
    string statsLabelName = "StatsLabel";
    ObjectCreate(0, statsLabelName, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, statsLabelName, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, statsLabelName, OBJPROP_XDISTANCE, 150);
    ObjectSetInteger(0, statsLabelName, OBJPROP_YDISTANCE, 60);
    
    string statsText = "Updates: " + IntegerToString(SuccessfulTrailingUpdates) +
                     " | Fails: " + IntegerToString(FailedTrailingUpdates);
                     
    // Calculate success rate if we have updates
    if(SuccessfulTrailingUpdates > 0 || FailedTrailingUpdates > 0)
    {
        double successRate = 100.0 * SuccessfulTrailingUpdates / (SuccessfulTrailingUpdates + FailedTrailingUpdates);
        statsText += " | Rate: " + DoubleToString(successRate, 1) + "%";
    }
                     
    ObjectSetString(0, statsLabelName, OBJPROP_TEXT, statsText);
    ObjectSetInteger(0, statsLabelName, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, statsLabelName, OBJPROP_BGCOLOR, clrDarkSlateBlue);
    ObjectSetInteger(0, statsLabelName, OBJPROP_FONTSIZE, 9);
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Clear all visualization objects                                   |
//+------------------------------------------------------------------+
void ClearVisualization()
{
    // Only clear statistics objects
    ObjectDelete(0, "StatsLabel");
}

//+------------------------------------------------------------------+
//| Set custom ATR parameters                                         |
//+------------------------------------------------------------------+
void SetATRParameters(double atrMultiplier, int atrPeriod)
{
    // Save original values to revert if needed
    double originalMultiplier = CurrentATRMultiplier;
    int originalPeriod = CurrentATRPeriod;
    
    // Update with new values
    CurrentATRMultiplier = atrMultiplier;
    CurrentATRPeriod = atrPeriod;
    
    // Reset ATR arrays when changing period
    if(originalPeriod != atrPeriod)
    {
        ArrayInitialize(AtrDEMA, 0);
        ArrayInitialize(Ema1, 0);
        ArrayInitialize(Ema2, 0);
    }
    
    Print("ATR Parameters updated - Multiplier: ", atrMultiplier, ", Period: ", atrPeriod);
    
    // Update visualization (statistics always enabled)
    UpdateVisualization();
}

//+------------------------------------------------------------------+
//| Utility function to get string order type from enum               |
//+------------------------------------------------------------------+
string OrderTypeToString(ENUM_ORDER_TYPE orderType)
{
    switch(orderType)
    {
        case ORDER_TYPE_BUY:
        case ORDER_TYPE_BUY_LIMIT:
        case ORDER_TYPE_BUY_STOP:
        case ORDER_TYPE_BUY_STOP_LIMIT:
            return "BUY";
        case ORDER_TYPE_SELL:
        case ORDER_TYPE_SELL_LIMIT:
        case ORDER_TYPE_SELL_STOP:
        case ORDER_TYPE_SELL_STOP_LIMIT:
            return "SELL";
        default:
            return "UNKNOWN";
    }
}