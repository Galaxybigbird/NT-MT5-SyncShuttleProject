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
input group    "==== DEMA-ATR Trailing ====";
input int      DEMA_ATR_Period = 14;       // Period for DEMA-ATR calculation
input double   DEMA_ATR_Multiplier = 1.5;  // ATR trailing distance multiplier
input double   TrailingActivationPercent = 1.0; // Activate trailing at this profit %
input bool     UseATRTrailing = true;      // Enable DEMA-ATR trailing stop
input int      TrailingButtonXDistance = 120; // X distance for trailing button position
input int      TrailingButtonYDistance = 20;  // Y distance for trailing button position

input group    "==== Visualization Settings ====";
input bool     ShowATRLevels = true;       // Show ATR levels on chart
input color    BuyLevelColor = clrDodgerBlue;  // Color for buy levels
input color    SellLevelColor = clrCrimson;    // Color for sell levels
input bool     ShowStatistics = true;      // Show statistics on chart
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
bool ShouldActivateTrailing(double entryPrice, double currentPrice, string orderType, double volume)
{
    if(!UseATRTrailing) return false;
    
    // Check if manual activation is enabled
    if(ManualTrailingActivated) return true;
    
    // Calculate profit metrics
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pipValue = tickValue * (pointValue / tickSize);
    
    // Calculate profit in account currency
    double priceDiff = (orderType == "BUY" ? currentPrice - entryPrice : entryPrice - currentPrice);
    double profitPoints = priceDiff / pointValue;
    double profitCurrency = profitPoints * pipValue * volume;
    
    // Calculate profit as percentage of account balance
    double profitPercent = (profitCurrency / accountBalance) * 100.0;
    
    // Print debug information
    if(profitPercent > 0)
    {
        Print("Profit metrics - Price Diff: ", priceDiff, ", Points: ", profitPoints,
              ", Currency: ", profitCurrency, ", Percent: ", profitPercent, "%");
    }
    
    // Check if profit percentage exceeds activation threshold
    // Add a small epsilon (0.0000001) to handle floating-point precision issues
    return (profitPercent >= (TrailingActivationPercent - 0.0000001));
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
    
    // If we have an original stop, only move in favorable direction
    if(originalStop > 0.0) 
    {
        // *** EXTREME VOLATILITY CHECK ***
        // Detect extreme volatility - when ATR is abnormally high (over 500 points)
        if(demaAtr/Point() > 500)
        {
            bool extremeVolatilityDetected = true;
            
            // During extreme volatility, always keep the more conservative stop
            if(orderType == "BUY" && originalStop > theoreticalStop)
            {
                return originalStop;
            }
            else if(orderType == "SELL" && originalStop < theoreticalStop)
            {
                return originalStop;
            }
        }
        
        // *** VERY DISTANT STOP CHECK ***
        // For stops that are already very far from current price (conservative stops)
        double entryPrice = 0; // We don't have entry price here, use current price as reference
        if(orderType == "BUY")
        {
            // If stop is more than 1500 points from current price, consider it a very distant stop
            if(MathAbs(originalStop - currentPrice)/Point() > 1500) 
            {
                // If the original stop is more conservative than theoretical stop
                if(originalStop < theoreticalStop) 
                {
                    return originalStop;
                }
            }
        }
        else if(orderType == "SELL")
        {
            // If stop is more than 1500 points from current price, consider it a very distant stop
            if(MathAbs(originalStop - currentPrice)/Point() > 1500) 
            {
                // If the original stop is more conservative than theoretical stop
                if(originalStop > theoreticalStop) 
                {
                    return originalStop;
                }
            }
        }
        
        // Normal direction checks
        if(orderType == "BUY")
        {
            // For buy positions, only move the stop up, never down
            if(theoreticalStop <= originalStop)
            {
                return originalStop;
            }
            
            // During extreme volatility, the stop might move too close to entry
            // If the original stop is very far (conservative), keep it
            if(MathAbs(currentPrice - theoreticalStop) < MathAbs(currentPrice - originalStop) * 0.5)
            {
                // If extreme volatility would make stop less conservative, keep original
                return originalStop;
            }
        }
        else if(orderType == "SELL")
        {
            // For sell positions, only move the stop down, never up
            if(theoreticalStop >= originalStop)
            {
                return originalStop;
            }
            
            // During extreme volatility, the stop might move too close to entry
            // If the original stop is very far (conservative), keep it
            if(MathAbs(currentPrice - theoreticalStop) < MathAbs(currentPrice - originalStop) * 0.5)
            {
                // If extreme volatility would make stop less conservative, keep original
                return originalStop;
            }
        }
    }
    
    // Return the new stop level
    return theoreticalStop;
}

//+------------------------------------------------------------------+
//| Update trailing stop for a position                              |
//+------------------------------------------------------------------+
bool UpdateTrailingStop(ulong ticket, double entryPrice, string orderType)
{
    // CRITICAL FIX: Force trailing to be active without checking settings
    bool forceTrailing = ManualTrailingActivated;
    if(!UseATRTrailing && !forceTrailing) 
    {
        return false;
    }
    
    // Get position information - try select by ticket first
    if(!PositionSelectByTicket(ticket))
    {
        Print("ERROR: Cannot select position ticket ", ticket, " - ", GetLastError());
        return false;
    }
    
    // Get current position data
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
    double currentTP = PositionGetDouble(POSITION_TP);
    
    // Calculate new trailing stop level
    double newSL = CalculateTrailingStop(orderType, currentPrice, currentSL);
    
    // AGGRESSIVE MANUAL TRAILING: Force it to move on manual activation
    if(ManualTrailingActivated)
    {
        double atrValue = CalculateDEMAATR();
        double trailingDistance = MathMax(atrValue * CurrentATRMultiplier, MinimumStopDistance * Point());
        
        if(orderType == "BUY")
        {
            // For BUY orders, consider a forced tighter stop when manually activated
            double forcedStop = currentPrice - trailingDistance * 0.8;  // 20% tighter
            
            // Only move stop up for BUY orders
            if(forcedStop > currentSL)
            {
                newSL = forcedStop;
                Print("MANUAL TRAILING FORCE: Moving BUY stop to ", newSL);
            }
            else
            {
                // If we can't move the stop favorably, avoid setting it to the raw ATR value
                // and simply maintain the current stop
                Print("MANUAL TRAILING: Cannot move BUY stop up further");
                return false;
            }
        }
        else if(orderType == "SELL")
        {
            // For SELL orders, consider a forced tighter stop when manually activated
            double forcedStop = currentPrice + trailingDistance * 0.8;  // 20% tighter
            
            // Only move stop down for SELL orders
            if(forcedStop < currentSL)
            {
                newSL = forcedStop;
                Print("MANUAL TRAILING FORCE: Moving SELL stop to ", newSL);
            }
            else
            {
                // If we can't move the stop favorably, avoid setting it to the raw ATR value
                // and simply maintain the current stop
                Print("MANUAL TRAILING: Cannot move SELL stop down further");
                return false;
            }
        }
    }
    
    // Only update if there's a meaningful change (more than 1 point)
    if(MathAbs(newSL - currentSL) < Point())
    {
        return false;
    }
    
    // Verify the stop is moving in the correct direction
    bool shouldUpdateStop = false;
    
    if(orderType == "BUY" && newSL > currentSL)
    {
        shouldUpdateStop = true;
        Print("Moving BUY stop up from ", currentSL, " to ", newSL);
    }
    else if(orderType == "SELL" && newSL < currentSL)
    {
        shouldUpdateStop = true;
        Print("Moving SELL stop down from ", currentSL, " to ", newSL);
    }
    
    // Only update if stop should move
    if(!shouldUpdateStop)
    {
        return false;
    }
    
    // Prepare the trade request
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.symbol = _Symbol;
    request.sl = newSL;
    request.tp = currentTP;  // Keep existing TP
    
    // Log the trade request
    Print("SENDING STOP UPDATE: Position ", ticket, ", New SL: ", newSL);
    
    // Send the request directly without additional checks
    if(!OrderSend(request, result))
    {
        Print("ERROR updating trailing stop: ", GetLastError(), " - ", 
              result.retcode, " ", result.comment);
        FailedTrailingUpdates++;
        return false;
    }
    
    // Success - log the update and update stats
    Print("✓ TRAILING STOP UPDATED: Position ", ticket, " - New SL: ", newSL, 
          ManualTrailingActivated ? " (Manual)" : " (Auto)");
    
    // Update statistics
    SuccessfulTrailingUpdates++;
    
    // Update tracking stats
    double potentialSlippage = MathAbs(currentPrice - newSL) / Point();
    if(potentialSlippage > WorstCaseSlippage)
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
    // Force return immediately, regardless of ShowATRLevels
    return; // Added this line to completely disable visualization
    
    if(!ShowATRLevels) return;
    
    // Clear previous objects
    ClearVisualization();
    
    // Draw current ATR trailing stop levels
    double atrValue = CalculateDEMAATR();
    double trailingDistance = MathMax(atrValue * CurrentATRMultiplier, MinimumStopDistance * Point());
    
    double buyTrailingLevel = SymbolInfoDouble(_Symbol, SYMBOL_BID) - trailingDistance;
    double sellTrailingLevel = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + trailingDistance;
    
    // Create objects for trailing levels
    string buyLevelName = "BuyTrailingLevel";
    string sellLevelName = "SellTrailingLevel";
    
    // Buy trailing level (blue horizontal line)
    ObjectCreate(0, buyLevelName, OBJ_HLINE, 0, 0, buyTrailingLevel);
    ObjectSetInteger(0, buyLevelName, OBJPROP_COLOR, BuyLevelColor);
    ObjectSetInteger(0, buyLevelName, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, buyLevelName, OBJPROP_WIDTH, 1);
    ObjectSetString(0, buyLevelName, OBJPROP_TOOLTIP, "Buy Trailing Level: " + DoubleToString(buyTrailingLevel, _Digits));
    
    // Sell trailing level (red horizontal line)
    ObjectCreate(0, sellLevelName, OBJ_HLINE, 0, 0, sellTrailingLevel);
    ObjectSetInteger(0, sellLevelName, OBJPROP_COLOR, SellLevelColor);
    ObjectSetInteger(0, sellLevelName, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, sellLevelName, OBJPROP_WIDTH, 1);
    ObjectSetString(0, sellLevelName, OBJPROP_TOOLTIP, "Sell Trailing Level: " + DoubleToString(sellTrailingLevel, _Digits));
    
    // Draw current ATR value as a label
    string atrLabelName = "ATRValueLabel";
    ObjectCreate(0, atrLabelName, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, atrLabelName, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, atrLabelName, OBJPROP_XDISTANCE, 150);
    ObjectSetInteger(0, atrLabelName, OBJPROP_YDISTANCE, 30);
    ObjectSetString(0, atrLabelName, OBJPROP_TEXT, "ATR: " + DoubleToString(atrValue, 5) + 
                   " | Distance: " + DoubleToString(trailingDistance, 5) + 
                   " | Multi: " + DoubleToString(CurrentATRMultiplier, 1) + "x");
    ObjectSetInteger(0, atrLabelName, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, atrLabelName, OBJPROP_BGCOLOR, clrDarkSlateGray);
    ObjectSetInteger(0, atrLabelName, OBJPROP_FONTSIZE, 9);
    
    // Draw statistics if enabled
    if(ShowStatistics)
    {
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
    }
    
    // If we have an open position, mark the active trailing stop level
    int totalPositions = PositionsTotal();
    for(int i = 0; i < totalPositions; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            double currentSL = PositionGetDouble(POSITION_SL);
            if(currentSL > 0)
            {
                string slLineName = "CurrentSL" + IntegerToString(ticket);
                ObjectCreate(0, slLineName, OBJ_HLINE, 0, 0, currentSL);
                
                // Different colors for different positions
                color slColor = (i == 0) ? clrGold : 
                              (i == 1) ? clrLightGoldenrod : 
                              (i == 2) ? clrPaleGoldenrod : clrGold;
                              
                ObjectSetInteger(0, slLineName, OBJPROP_COLOR, slColor);
                ObjectSetInteger(0, slLineName, OBJPROP_STYLE, STYLE_SOLID);
                ObjectSetInteger(0, slLineName, OBJPROP_WIDTH, 2);
                ObjectSetString(0, slLineName, OBJPROP_TOOLTIP, "Active SL [" + IntegerToString(ticket) + "]: " + 
                                DoubleToString(currentSL, _Digits));
            }
        }
    }
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Clear all visualization objects                                   |
//+------------------------------------------------------------------+
void ClearVisualization()
{
    // Basic visualization objects
    ObjectDelete(0, "BuyTrailingLevel");
    ObjectDelete(0, "SellTrailingLevel");
    ObjectDelete(0, "ATRValueLabel");
    ObjectDelete(0, "StatsLabel");
    
    // Delete all SL lines for positions
    for(int i = 0; i < 100; i++) // Increased to handle more positions
    {
        ObjectDelete(0, "CurrentSL" + IntegerToString(i));
    }
    
    // Delete any position-specific SL lines based on ticket
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0)
        {
            ObjectDelete(0, "CurrentSL" + IntegerToString(ticket));
        }
    }
    
    // Delete all visualization text labels
    for(int i = 0; i < ObjectsTotal(0); i++)
    {
        string objName = ObjectName(0, i);
        if(StringFind(objName, "Level") >= 0 || 
           StringFind(objName, "Label") >= 0 || 
           StringFind(objName, "ATR") >= 0 ||
           StringFind(objName, "SL") >= 0)
        {
            ObjectDelete(0, objName);
        }
    }
    
    ChartRedraw();
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
    
    // Update visualization if enabled
    if(ShowATRLevels)
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