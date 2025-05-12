#property link      ""
#property version   "1.27"
#property strict
#property description "Hedge Receiver EA for Go bridge server with Asymmetrical Compounding"

// Include the asymmetrical compounding functionality
#include "ACFunctions.mqh"
#include "ATRtrailing.mqh"
#include "StatusIndicator.mqh"
#include <Trade/Trade.mqh>
CTrade trade;

// Error code constant for hedging-related errors
#define ERR_TRADE_NOT_ALLOWED           4756  // Trading is prohibited

//+------------------------------------------------------------------+
//| Connection Settings                                             |
//+------------------------------------------------------------------+
input group    "===== Connections Settings =====";
input string    BridgeURL = "http://127.0.0.1:5000";  // Bridge Server URL - Connection point to Go bridge
const int      PollInterval = 1;     // Frequency of checking for new trades (in seconds)
const bool     VerboseMode = false;  // Show all polling messages in Experts tab

//+------------------------------------------------------------------+
//| Trading Settings                                                |
//+------------------------------------------------------------------+
input group    "===== Trading Settings =====";
input bool      UseACRiskManagement = false; // Enable Asymmetrical Compounding Risk Management?
input bool      EnableHedging = true;   // Enable hedging? (false = copy direction)
input double    DefaultLot = 5.0;     // Default lot size if not specified - Base multiplier for trade volumes
input int       Slippage  = 200;       // Slippage
input int       MagicNumber = 12345;  // MagicNumber for trades
const string    CommentPrefix = "NT_Hedge_";  // Prefix for hedge order comments

//+------------------------------------------------------------------+
//| Risk Management - Asymmetrical Compounding                       |
//+------------------------------------------------------------------+
// Note: AC Risk Management and ATR Stop Loss parameters
// are defined and read from included files:
// ACFunctions.mqh and ATRtrailing.mqh
// Global variable to track the aggregated net futures position from NT trades.
// A Buy increases the net position; a Sell reduces it.
double globalFutures = 0.0;
string lastTradeTime = "";  // Track the last processed trade time
string lastTradeId = "";  // Track the last processed trade ID

// Add new struct for TP/SL measurements
struct TPSLMeasurement {
    string baseTradeId;
    string orderType;  // "TP" or "SL"
    int pips;
    double rawMeasurement;
};

// Add global variables for measurements
TPSLMeasurement lastTPSL;

// Dynamic‑hedge state
double g_highWaterEOD = 0.0;  // highest *settled* balance
const  double CUSHION_BAND = 120.0;   // *** NEW ***
double g_lastOHF      = 0.05; // last over‑hedge factor

// Add these global variables at the top with other globals
// Instead of struct array, use separate arrays for each field
string g_baseIds[];           // Array of base trade IDs
int g_totalQuantities[];      // Array of total quantities
int g_processedQuantities[];  // Array of processed quantities
string g_actions[];           // Array of trade actions
bool g_isComplete[];          // Array of completion flags

// Function to find or create trade group
int FindOrCreateTradeGroup(string baseId, int totalQty, string action)
{
    // First try to find an existing group with this base ID
    int arraySize = ArraySize(g_baseIds);
    for(int i = 0; i < arraySize; i++)
    {
        if(g_baseIds[i] == baseId && !g_isComplete[i])
        {
            // Found existing group - don't update global futures position again
            Print("DEBUG: Found existing trade group at index ", i, " for base ID: ", baseId);
            return i;
        }
    }
    
    // Create new group if not found
    int newIndex = arraySize;
    ArrayResize(g_baseIds, newIndex + 1);
    ArrayResize(g_totalQuantities, newIndex + 1);
    ArrayResize(g_processedQuantities, newIndex + 1);
    ArrayResize(g_actions, newIndex + 1);
    ArrayResize(g_isComplete, newIndex + 1);
    
    g_baseIds[newIndex] = baseId;
    g_totalQuantities[newIndex] = totalQty;  // Use the total quantity from the message
    g_processedQuantities[newIndex] = 0;
    g_actions[newIndex] = action;
    g_isComplete[newIndex] = false;
    
    // Update global futures position based on total quantity
    if(action == "Buy" || action == "BuyToCover")
        globalFutures += 1;  // Add one contract at a time
    else if(action == "Sell" || action == "SellShort")
        globalFutures -= 1;  // Subtract one contract at a time
        
    Print("DEBUG: New trade group created. Base ID: ", baseId, 
          ", Total Qty: ", totalQty,
          ", Action: ", action,
          ", Updated Global Futures: ", globalFutures);
    
    return newIndex;
}

// Function to clean up completed trade groups
void CleanupTradeGroups()
{
    int arraySize = ArraySize(g_baseIds);
    if(arraySize == 0) return;  // Nothing to clean up
    
    int activeCount = 0;
    for(int i = 0; i < arraySize; i++)
    {
        if(!g_isComplete[i])
            activeCount++;
    }
    
    if(activeCount < arraySize)
    {
        string tempBaseIds[];
        int tempTotalQty[];
        int tempProcessedQty[];
        string tempActions[];
        bool tempComplete[];
        
        if(activeCount > 0)
        {
            ArrayResize(tempBaseIds, activeCount);
            ArrayResize(tempTotalQty, activeCount);
            ArrayResize(tempProcessedQty, activeCount);
            ArrayResize(tempActions, activeCount);
            ArrayResize(tempComplete, activeCount);
            
            int newIndex = 0;
            for(int i = 0; i < arraySize; i++)
            {
                if(!g_isComplete[i])
                {
                    tempBaseIds[newIndex] = g_baseIds[i];
                    tempTotalQty[newIndex] = g_totalQuantities[i];
                    tempProcessedQty[newIndex] = g_processedQuantities[i];
                    tempActions[newIndex] = g_actions[i];
                    tempComplete[newIndex] = g_isComplete[i];
                    newIndex++;
                }
            }
        }
        
        ArrayFree(g_baseIds);
        ArrayFree(g_totalQuantities);
        ArrayFree(g_processedQuantities);
        ArrayFree(g_actions);
        ArrayFree(g_isComplete);
        
        if(activeCount > 0)
        {
            ArrayCopy(g_baseIds, tempBaseIds);
            ArrayCopy(g_totalQuantities, tempTotalQty);
            ArrayCopy(g_processedQuantities, tempProcessedQty);
            ArrayCopy(g_actions, tempActions);
            ArrayCopy(g_isComplete, tempComplete);
        }
        else
        {
            // If no active trades, initialize arrays with size 0
            ArrayResize(g_baseIds, 0);
            ArrayResize(g_totalQuantities, 0);
            ArrayResize(g_processedQuantities, 0);
            ArrayResize(g_actions, 0);
            ArrayResize(g_isComplete, 0);
        }
    }
}

// Add this new function after CleanupTradeGroups()
void ResetTradeGroups()
{
    Print("DEBUG: Resetting all trade group arrays");
    // Initialize arrays with size 0
    ArrayResize(g_baseIds, 0);
    ArrayResize(g_totalQuantities, 0);
    ArrayResize(g_processedQuantities, 0);
    ArrayResize(g_actions, 0);
    ArrayResize(g_isComplete, 0);
    globalFutures = 0.0;  // Reset global futures counter
    g_highWaterEOD  = 0.0;      // <<< NEW – restart trailing‑dd calc
    Print("DEBUG: Trade groups reset complete. Global futures: ", globalFutures);
}

//+------------------------------------------------------------------+
//| Simple JSON parser class for processing bridge messages            |
//+------------------------------------------------------------------+
class JSONParser
{
private:
    string json_str;    // Stores the JSON string to be parsed
    int    pos;         // Current position in the JSON string during parsing
    
public:
    // Constructor initializes parser with JSON string
    JSONParser(string js) { json_str = js; pos = 0; }
    
    // Utility function to skip whitespace characters
    void SkipWhitespace()
    {
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            // Skip spaces, tabs, newlines, and carriage returns
            if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                break;
            pos++;
        }
    }
    
    // Parse a JSON string value enclosed in quotes
    bool ParseString(string &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Verify string starts with quote
        if(StringGetCharacter(json_str, pos) != '"')
            return false;
        pos++;
        
        // Build string until closing quote
        value = "";
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch == '"')
            {
                pos++;
                return true;
            }
            value += CharToString((uchar)ch);
            pos++;
        }
        return false;
    }
    
    // Parse a numeric value (integer or decimal)
    bool ParseNumber(double &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        string num = "";
        bool hasDecimal = false;
        
        // Handle negative numbers
        if(StringGetCharacter(json_str, pos) == '-')
        {
            num += "-";
            pos++;
        }
        
        // Build number string including decimal point if present
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch >= '0' && ch <= '9')
            {
                num += CharToString((uchar)ch);
            }
            else if(ch == '.' && !hasDecimal)
            {
                num += ".";
                hasDecimal = true;
            }
            else
                break;
            pos++;
        }
        
        // Convert string to double
        value = StringToDouble(num);
        return true;
    }
    
    // Parse boolean true/false values
    bool ParseBool(bool &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Check for "true" literal
        if(pos + 4 <= StringLen(json_str) && StringSubstr(json_str, pos, 4) == "true")
        {
            value = true;
            pos += 4;
            return true;
        }
        
        // Check for "false" literal
        if(pos + 5 <= StringLen(json_str) && StringSubstr(json_str, pos, 5) == "false")
        {
            value = false;
            pos += 5;
            return true;
        }
        
        return false;
    }
    
    // Skip over any JSON value without parsing it
    void SkipValue()
    {
        SkipWhitespace();
        
        if(pos >= StringLen(json_str)) return;
        
        ushort ch = StringGetCharacter(json_str, pos);
        
        // Handle different value types
        if(ch == '"')  // Skip string
        {
            pos++;
            while(pos < StringLen(json_str))
            {
                if(StringGetCharacter(json_str, pos) == '"')
                {
                    pos++;
                    break;
                }
                pos++;
            }
        }
        else if(ch == '{')  // Skip object
        {
            int depth = 1;
            pos++;
            while(pos < StringLen(json_str) && depth > 0)
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == '{') depth++;
                if(ch == '}') depth--;
                pos++;
            }
        }
        else if(ch == '[')  // Skip array
        {
            int depth = 1;
            pos++;
            while(pos < StringLen(json_str) && depth > 0)
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == '[') depth++;
                if(ch == ']') depth--;
                pos++;
            }
        }
        else if(ch == 't' || ch == 'f')  // Skip boolean
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
        else if(ch == 'n')  // Skip null
        {
            pos += 4;
        }
        else  // Skip number
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
    }
    
    // Parse a complete trade object from JSON
    bool ParseObject(string &type, double &volume, double &price, string &executionId, bool &isExit, int &measurementPips, string &orderType)
    {
        // Skip any leading whitespace and ensure object starts with '{'
        SkipWhitespace();
        if(StringGetCharacter(json_str, pos) != '{')
            return false;
        pos++; // skip '{'

        // Initialize defaults
        type = "";
        volume = 0.0;
        price = 0.0;
        executionId = "";
        isExit = false;
        measurementPips = 0;
        orderType = "";

        // Loop through key/value pairs
        while(true)
        {
            SkipWhitespace();
            if(pos >= StringLen(json_str))
                return false;

            ushort ch = StringGetCharacter(json_str, pos);
            // End of object
            if(ch == '}')
            {
                pos++; // skip '}'
                break;
            }
            
            // Parse the key
            string key = "";
            if(!ParseString(key))
                return false;
            
            SkipWhitespace();
            if(StringGetCharacter(json_str, pos) != ':')
                return false;
            pos++; // skip ':'
            SkipWhitespace();
            
            // Parse the value based on the key. Note the new checks.
            if(key=="action" || key=="type")
            {
                if(!ParseString(type))
                    return false;
            }
            else if(key=="quantity" || key=="volume")
            {
                if(!ParseNumber(volume))
                    return false;
            }
            else if(key=="price")
            {
                if(!ParseNumber(price))
                    return false;
            }
            else if(key=="executionId")
            {
                if(!ParseString(executionId))
                    return false;
            }
            else if(key=="isExit" || key=="is_close")
            {
                if(!ParseBool(isExit))
                    return false;
            }
            else if(key=="measurement_pips")
            {
                double pipValue;
                if(!ParseNumber(pipValue))
                    return false;
                measurementPips = (int)pipValue;
            }
            else if(key=="order_type")
            {
                if(!ParseString(orderType))
                    return false;
            }
            else if(key=="base_id")
            {
                if(!ParseString(executionId))  // Store base_id in executionId
                    return false;
            }
            else
            {
                // For any unknown key, just skip its value
                SkipValue();
            }
            
            SkipWhitespace();
            // If there's a comma, continue parsing the next pair.
            if(pos < StringLen(json_str) && StringGetCharacter(json_str, pos)==',')
            {
                pos++; // skip comma
                continue;
            }
            // End of the object
            if(pos < StringLen(json_str) && StringGetCharacter(json_str, pos)=='}')
            {
                pos++; // skip closing brace
                break;
            }
        }
        return true;
    }
};

//──────────────────────────────────────────────────────────────────────────────
//  Dynamic‑hedge helper functions
//──────────────────────────────────────────────────────────────────────────────
//   Cushion above the $2 000 trailing drawdown line
//──────────────────────────────────────────────────────────────────────────────
double GetCushion()
{
   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double eodHigh = MathMax(g_highWaterEOD, bal);      // keep high-water
   g_highWaterEOD = eodHigh;

   // “freeboard” above the trailing-drawdown line
   double cushion = bal - (eodHigh - CUSHION_BAND);    // 120 = 40 % of $300
   return cushion;                                     // <<< fixed
}

// Map cushion → OHF  (for a ≈$300 hedge account)
//  Cushion ≥ 120       → 0.05
//          80 – 119    → 0.10
//          50 – 79     → 0.15
//          25 – 49     → 0.20
//          ≤ 24        → 0.25
//  Always floor at 0.05

//──────────────────────────────────────────────────────────────────────────────
double SelectOHF(double cushion)
{
    if(cushion <= 24)   return 0.25;
    if(cushion <= 49)   return 0.20;
    if(cushion <= 79)   return 0.15;
    if(cushion <= 119)  return 0.10;
    return 0.05;

}

// Scale the supplied lot according to live OHF – used ONLY when
// asym‑comp OFF && hedging ON.
//──────────────────────────────────────────────────────────────────────────────
double CalcHedgeLot(double baseLot)
{
   // If not in dynamic‑hedge mode, leave untouched
   if(UseACRiskManagement || !EnableHedging)
      return baseLot;

   double cushion = GetCushion();
   g_lastOHF       = SelectOHF(cushion);
   return baseLot * g_lastOHF;
}

//+------------------------------------------------------------------+
//| Expert initialization function - Called when EA is first loaded    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Reset trade groups on startup
   ResetTradeGroups();
   
   // Initialize the asymmetrical compounding risk management (reads inputs from ACFunctions.mqh)
   InitializeACRiskManagement();
   trade.SetExpertMagicNumber(MagicNumber); // Set MagicNumber for CTrade
   // Note: ATR settings (ATRPeriod, ATRMultiplier, MaxStopLossDistance) are also initialized within ACFunctions.mqh or ATRTrailing.mqh
   
   // Verify automated trading is enabled in MT5
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      MessageBox("Please enable automated trading in MT5 settings!", "Error", MB_OK|MB_ICONERROR);
      return INIT_FAILED;
   }
   
   // Check account type and warn if hedging is not available
   ENUM_ACCOUNT_MARGIN_MODE margin_mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Warning: Account does not support hedging. Operating in netting mode.");
      Print("Current margin mode: ", margin_mode);
   }
   
   Print("Testing connection to bridge server...");
   
   // Test bridge connection with health check
   char tmp[];
   string headers = "";
   string response_headers;
   
   if(!WebRequest("GET", BridgeURL + "/health?source=hedgebot", headers, 0, tmp, tmp, response_headers))
   {
      int error = GetLastError();
      if(error == ERR_FUNCTION_NOT_ALLOWED)
      {
         MessageBox("Please allow WebRequest for " + BridgeURL, "Error", MB_OK|MB_ICONERROR);
         string terminal_data_path = TerminalInfoString(TERMINAL_DATA_PATH);
         string filename = terminal_data_path + "\\MQL5\\config\\terminal.ini";
         Print("Add the following URLs to " + filename + " in [WebRequest] section:");
         Print(BridgeURL + "/mt5/get_trade");
         Print(BridgeURL + "/mt5/trade_result");
         Print(BridgeURL + "/health");
         return INIT_FAILED;
      }
      Print("ERROR: Could not connect to bridge server!");
      Print("Make sure the bridge server is running and accessible at: ", BridgeURL);
      return INIT_FAILED;
   }
   
   Print("=================================");
   Print("✓ Bridge server connection test passed");
   Print("✓ HedgeReceiver EA initialized successfully");
   Print("✓ Connected to bridge server at: ", BridgeURL);
   if(UseACRiskManagement) // Use variable from ACFunctions.mqh
      Print("✓ Asymmetrical Compounding enabled with base risk: ", AC_BaseRisk, "%");
   Print("✓ Monitoring for trades...");
   Print("=================================");
   
   // Initialize DEMA-ATR for trailing stop functionality
   if(UseATRTrailing)
   {
      InitDEMAATR();
      Print("✓ DEMA-ATR trailing stop initialized");
   }
   
   // Initialize status indicator
   InitStatusIndicator();
   Print("✓ Status indicator initialized");
   
   // Set up timer for periodic trade checks
   EventSetMillisecondTimer(PollInterval * 100);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function - Cleanup when EA is removed      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Stop the timer to prevent further trade checks
   EventKillTimer();
   
   // Delete the trailing button
   ObjectDelete(0, ButtonName);
   
   // Remove the status indicator
   RemoveStatusIndicator();
   
   Print("EA removed from chart - all objects cleaned up");
}

//+------------------------------------------------------------------+
//| ChartEvent function - Handle button clicks                         |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Check if this is a button click event
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // Check if our trailing button was clicked
      if(sparam == ButtonName)
      {
         // Toggle manual trailing activation
         ManualTrailingActivated = !ManualTrailingActivated;
         
         // Update button color and text based on state
         ObjectSetInteger(0, ButtonName, OBJPROP_COLOR, 
                         ManualTrailingActivated ? ButtonColorActive : ButtonColorInactive);
         ObjectSetString(0, ButtonName, OBJPROP_TEXT, 
                        ManualTrailingActivated ? "Trailing Active" : "Start Trailing?");
         
         // Print status message
         Print(ManualTrailingActivated ? "Manual trailing activation enabled" : "Manual trailing activation disabled");
         
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| Helper function to extract a double value from a JSON string for |
//| a given key                                                      |
//+------------------------------------------------------------------+
double GetJSONDouble(string json, string key)
{
   string searchKey = "\"" + key + "\"";
   int keyPos = StringFind(json, searchKey);
   if(keyPos == -1)
      return 0.0;
      
   int colonPos = StringFind(json, ":", keyPos);
   if(colonPos == -1)
      return 0.0;
      
   int start = colonPos + 1;
   // Skip whitespace characters
   while(start < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, start);
      if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
         break;
      start++;
   }
   
   // Build the numeric string
   string numStr = "";
   while(start < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, start);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-')
      {
         numStr += CharToString((uchar)ch);
         start++;
      }
      else
         break;
   }
   
   return StringToDouble(numStr);
}

// ---------------------------------------------------------------
// Count open hedge positions that belong to this EA and whose
// comment starts with "NT_Hedge_<origin>".
// Works for both hedging and copy modes because it ignores
// POSITION_TYPE.
// ---------------------------------------------------------------
int CountHedgePositions(string hedgeOrigin)
{
   int count = 0;
   string searchStr = CommentPrefix + hedgeOrigin;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                    continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)   != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)   != MagicNumber) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, searchStr) != -1)
      {
         count++;
         Print("DEBUG: CountHedgePositions – matched ticket ", ticket,
               "  comment=", comment);
      }
   }

   Print("DEBUG: Total ", hedgeOrigin, " hedge positions found: ", count);
   return count;
}


// ------------------------------------------------------------------
// Close one hedge position that matches the given origin (“Buy”|"Sell")
// and (optionally) a specificTradeId found in the comment.
// Returns true when a position is closed.
// ------------------------------------------------------------------
bool CloseOneHedgePosition(string hedgeOrigin, string specificTradeId = "")
{
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)                    continue;           // safety
      if(!PositionSelectByTicket(ticket)) continue;          

      if(PositionGetString(POSITION_SYMBOL)   != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)   != MagicNumber) continue;

      string comment   = PositionGetString(POSITION_COMMENT);
      string searchStr = CommentPrefix + hedgeOrigin;

      // optional filter by trade-id
      if(specificTradeId != "" && StringFind(comment, specificTradeId) == -1)
         continue;

      if(StringFind(comment, searchStr) == -1)
         continue;  // comment didn’t match – skip

      // ----- we have a matching hedge position -----
      double volumeToClose = PositionGetDouble(POSITION_VOLUME);

      Print(StringFormat(
            "DEBUG: Closing hedge position via CTrade – Ticket:%I64u  Vol:%.2f  Comment:%s",
            ticket, volumeToClose, comment));

      bool closed = trade.PositionClose(ticket, Slippage);

      if(closed)
      {
         Print("DEBUG: PositionClose succeeded. Order:", trade.ResultOrder(),
               "  Deal:", trade.ResultDeal());

         // extract trade-id (portion after the final ‘_’)
         string closedTradeId = "";
         int idStart = StringFind(comment, "_", StringFind(comment, hedgeOrigin)) + 1;
         if(idStart > 0)  closedTradeId = StringSubstr(comment, idStart);

         // asymmetrical-compounding bookkeeping
         if(UseACRiskManagement)
         {
            double closeProfit = PositionGetDouble(POSITION_PROFIT);  // may be zero immediately
            ProcessTradeResult(closeProfit > 0, closedTradeId, closeProfit);
         }

         SendTradeResult(volumeToClose, trade.ResultOrder(), true, closedTradeId);
         return true;
      }
      else
      {
         Print(StringFormat("ERROR: PositionClose failed for ticket %I64u – %d / %s",
               ticket, trade.ResultRetcode(), trade.ResultComment()));
         return false;
      }
   }
   return false;  // no matching position found
}


//+------------------------------------------------------------------+
//| Timer function - Called periodically to check for new trades     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Get any pending trades from the bridge.
   string response = GetTradeFromBridge();
   if(response == "") return;
   
   Print("DEBUG: Received trade response: ", response);
   
   // Check for duplicate trade based on trade ID
   string tradeId = "";
   int idPos = StringFind(response, "\"id\":\"");
   if(idPos >= 0)
   {
       idPos += 6;  // Length of "\"id\":\""
       int idEndPos = StringFind(response, "\"", idPos);
       if(idEndPos > idPos)
       {
           tradeId = StringSubstr(response, idPos, idEndPos - idPos);
           Print("DEBUG: Found trade ID: ", tradeId);
           if(tradeId == lastTradeId)
           {
               Print("DEBUG: Ignoring duplicate trade with ID: ", tradeId);
               return;
           }
           lastTradeId = tradeId;
       }
   }
   
   Print("Processing trade response...");
   
   // Parse trade information from the JSON response.
   JSONParser parser(response);
   string type = "";
   double volume = 0.0, price = 0.0;
   string executionId = "";
   bool isExit = false;
   int measurementPips = 0;
   string orderType = "";
   
   if(!parser.ParseObject(type, volume, price, executionId, isExit, measurementPips, orderType))
   {
      Print("DEBUG: Failed to parse JSON response: ", response);
      return;
   }
   
   // Extract base_id from response
   string baseId = "";
   int baseIdPos = StringFind(response, "\"base_id\":\"");
   if(baseIdPos >= 0)
   {
       baseIdPos += 11;  // Length of "\"base_id\":\""
       int baseIdEndPos = StringFind(response, "\"", baseIdPos);
       if(baseIdEndPos > baseIdPos)
       {
           baseId = StringSubstr(response, baseIdPos, baseIdEndPos - baseIdPos);
           Print("DEBUG: Found base ID: ", baseId);
       }
   }
   
   // Extract total_quantity from response
   int totalQty = 1;  // Default to 1 if not found
   int totalQtyPos = StringFind(response, "\"total_quantity\":");
   if(totalQtyPos >= 0)
   {
       string totalQtyStr = "";
       totalQtyPos += 16;  // Length of "\"total_quantity\":"
       
       // Skip whitespace
       while(totalQtyPos < StringLen(response) && 
             (StringGetCharacter(response, totalQtyPos) == ' ' || 
              StringGetCharacter(response, totalQtyPos) == '\t'))
       {
           totalQtyPos++;
       }
       
       // Build number string
       while(totalQtyPos < StringLen(response))
       {
           ushort ch = StringGetCharacter(response, totalQtyPos);
           if(ch >= '0' && ch <= '9')
           {
               totalQtyStr += CharToString((uchar)ch);
               totalQtyPos++;
           }
           else
               break;
       }
       
       if(totalQtyStr != "")
       {
           totalQty = (int)StringToInteger(totalQtyStr);
           Print("DEBUG: Found total quantity: ", totalQty);
       }
   }
   
   // If the response contains a "quantity" field, override the parsed volume.
   if(StringFind(response, "\"quantity\"") != -1)
   {
       double qty = GetJSONDouble(response, "quantity");
       Print("DEBUG: Found 'quantity' field in JSON, overriding parsed volume with value: ", qty);
       volume = qty;
   }
   
   // Calculate lot size based on quantity
   double lotSize = DefaultLot;  // Use fixed lot size for each hedge order
   Print("DEBUG: Using lot size for hedge orders: ", lotSize);

   // Update the global futures position based on trade type
   double prevFutures = globalFutures;
   
   // Find or create trade group using the base_id and total_quantity from the message
   int groupIndex = -1;
   
   // First try to find an existing group with this base ID
   for(int i = 0; i < ArraySize(g_baseIds); i++)
   {
       if(g_baseIds[i] == baseId)
       {
           groupIndex = i;
           Print("DEBUG: Found existing trade group at index ", i, " for base ID: ", baseId);
           break;
       }
   }
   
   // Create new group if not found
   if(groupIndex == -1)
   {
       groupIndex = ArraySize(g_baseIds);
       ArrayResize(g_baseIds, groupIndex + 1);
       ArrayResize(g_totalQuantities, groupIndex + 1);
       ArrayResize(g_processedQuantities, groupIndex + 1);
       ArrayResize(g_actions, groupIndex + 1);
       ArrayResize(g_isComplete, groupIndex + 1);
       
       g_baseIds[groupIndex] = baseId;
       g_totalQuantities[groupIndex] = totalQty;  // Use the total quantity from the message
       g_processedQuantities[groupIndex] = 0;
       g_actions[groupIndex] = type;
       g_isComplete[groupIndex] = false;
       
       // Update global futures position based on total quantity
       if(type == "Buy" || type == "BuyToCover")
           globalFutures += 1;  // Add one contract at a time
       else if(type == "Sell" || type == "SellShort")
           globalFutures -= 1;  // Subtract one contract at a time
           
       Print("DEBUG: New trade group created. Base ID: ", baseId, 
             ", Total Qty: ", totalQty,
             ", Action: ", type,
             ", Updated Global Futures: ", globalFutures);
   }
   // No 'else' block needed here - globalFutures is only updated for NEW groups.
   
   // Update processed quantity for this contract
   g_processedQuantities[groupIndex]++;
   
   Print("DEBUG: Trade group processing. Base ID: ", baseId, 
         ", Total Qty: ", g_totalQuantities[groupIndex],
         ", Processed: ", g_processedQuantities[groupIndex],
         ", Global Futures: ", globalFutures);

   // Check if group is complete
   if(g_processedQuantities[groupIndex] >= g_totalQuantities[groupIndex])
   {
       g_isComplete[groupIndex] = true;
       Print("DEBUG: Complete trade group processed. Global futures: ", globalFutures, ", Desired hedge count: ", MathAbs(globalFutures));
       
       // Handle hedging based on complete group
       if(globalFutures == 0)
       {
           Print("DEBUG: Net futures position is zero. Initiating closure of all hedge orders.");
           
           // First close all hedge orders
           int hedgeCountBuy = CountHedgePositions("Buy");
           int hedgeCountSell = CountHedgePositions("Sell");
           
           bool allClosed = true;
           
           // Close Buy positions
           while(hedgeCountBuy > 0)
           {
               if(!CloseOneHedgePosition("Buy"))
               {
                   allClosed = false;
                   break;
               }
               Sleep(500);
               hedgeCountBuy = CountHedgePositions("Buy");
           }
           
           // Close Sell positions
           while(hedgeCountSell > 0)
           {
               if(!CloseOneHedgePosition("Sell"))
               {
                   allClosed = false;
                   break;
               }
               Sleep(500);
               hedgeCountSell = CountHedgePositions("Sell");
           }
           
           // Only reset if all positions are closed
           if(allClosed && hedgeCountBuy == 0 && hedgeCountSell == 0)
           {
               Print("DEBUG: All hedge orders closed, resetting trade groups");
               ResetTradeGroups();
               return;  // Exit to prevent further array access
           }
       }
       else
       {
           string hedgeOrigin = globalFutures > 0 ? "Buy" : "Sell";
           Print("DEBUG: Hedge Origin: ", hedgeOrigin);
           
           int currentHedgeCount = CountHedgePositions(hedgeOrigin);
           Print("DEBUG: Current hedge count (", hedgeOrigin, "): ", currentHedgeCount);
           
           int desiredHedgeCount = (int)MathAbs(globalFutures);
           
           if(currentHedgeCount > desiredHedgeCount)
           {
               // Close excess hedge positions
               int toClose = currentHedgeCount - desiredHedgeCount;
               for(int i = 0; i < toClose; i++)
               {
                   Print("DEBUG: Closing excess hedge position. Current: ", currentHedgeCount, ", Desired: ", desiredHedgeCount);
                   if(!CloseOneHedgePosition(hedgeOrigin))
                       break;
                   currentHedgeCount = CountHedgePositions(hedgeOrigin);
               }
           }
           else if(currentHedgeCount < desiredHedgeCount)
           {
               // Add new hedge positions
               for(int i = currentHedgeCount; i < desiredHedgeCount; i++)
               {
                   Print("DEBUG: Adding new hedge position. Current: ", i, ", Desired: ", desiredHedgeCount);
                   if(!OpenNewHedgeOrder(hedgeOrigin, baseId))
                       break;
               }
           }
       }
       
       // Clean up completed trade groups periodically
       CleanupTradeGroups();
   }
}

//+------------------------------------------------------------------+
//| Expert tick function - Not used in this EA                       |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update trailing stops for all open positions
   for(int i = 0; i < PositionsTotal(); i++)
   {
       if(PositionSelectByTicket(PositionGetTicket(i)))
       {
           if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
           {
               string orderType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
               double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               UpdateTrailingStop(PositionGetTicket(i), entryPrice, orderType);
           }
       }
   }
   
   // Trading logic is handled in OnTimer instead
}

// Send trade execution result back to bridge
bool SendTradeResult(double volume, ulong ticket, bool is_close, string tradeId="")
{
   // Format result as JSON
   string result;
   if(tradeId != "")
      result = StringFormat("{\"status\":\"success\",\"ticket\":%I64u,\"volume\":%.2f,\"is_close\":%s,\"id\":\"%s\"}",
                           ticket, volume, is_close ? "true" : "false", tradeId);
   else
      result = StringFormat("{\"status\":\"success\",\"ticket\":%I64u,\"volume\":%.2f,\"is_close\":%s}",
                           ticket, volume, is_close ? "true" : "false");
   
   Print("Preparing to send result: ", result);
   
   // Prepare data for web request
   char result_data[];
   StringToCharArray(result, result_data);
   
   string headers = "Content-Type: application/json\r\n";
   char response_data[];
   string response_headers;
   
   // Send result to bridge
   int res = WebRequest("POST", BridgeURL + "/mt5/trade_result", headers, 0, result_data, response_data, response_headers);
   
   if(res == -1)
   {
      Print("Error in WebRequest. Error code: ", GetLastError());
      return false;
   }
   
   Print("Result sent to bridge successfully");
   
   return true;
}

// Get pending trades from bridge server
string GetTradeFromBridge()
{
   // Initialize request variables
   char response_data[];
   string headers = "";
   string response_headers;
   
   // Send request to bridge
   int web_result = WebRequest("GET", BridgeURL + "/mt5/get_trade", headers, 0, response_data, response_data, response_headers);
   
   if(web_result == -1)
   {
      int error = GetLastError();
      Print("Error in WebRequest. Error code: ", error);
      if(error == ERR_WEBREQUEST_INVALID_ADDRESS) Print("Invalid URL. Check BridgeURL setting.");
      if(error == ERR_WEBREQUEST_CONNECT_FAILED) Print("Connection failed. Check if Bridge server is running.");
      return "";
   }
   
   // Convert response to string
   string response_str = CharArrayToString(response_data);
   
   // Only print response if it's not "no_trade" or if verbose mode is on
   if(VerboseMode || StringFind(response_str, "no_trade") < 0)
   {
      Print("Response: ", response_str);
   }
   
   // Check if response is HTML (indicates error page)
   if(StringFind(response_str, "<!doctype html>") >= 0 || StringFind(response_str, "<html") >= 0)
   {
      Print("Received HTML error page instead of JSON");
      return "";
   }
   
   // Check for no trades
   if(StringFind(response_str, "no_trade") >= 0)
   {
      return "";
   }
   
   // Validate JSON response
   if(StringFind(response_str, "{") < 0 || StringFind(response_str, "}") < 0)
   {
      Print("Invalid JSON response");
      return "";
   }
   
   return response_str;
}

// Helper function to close a hedge position matching the provided hedge origin.
// Returns true if a hedge position is closed successfully.
bool CloseHedgePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
   {
      Print("ERROR: Hedge position not found for ticket ", ticket);
      return false;
   }
   string sym = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   long pos_type = PositionGetInteger(POSITION_TYPE); // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   ENUM_ORDER_TYPE closing_order_type;
   if(pos_type == POSITION_TYPE_BUY)
       closing_order_type = ORDER_TYPE_SELL;
   else if(pos_type == POSITION_TYPE_SELL)
       closing_order_type = ORDER_TYPE_BUY;
   else
   {
      Print("ERROR: Unknown position type for hedge ticket ", ticket);
      return false;
   }
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = sym;
   request.volume    = volume;
   request.magic     = MagicNumber;
   request.deviation = Slippage;
   request.comment   = "NT_Hedge_Close";
   request.type      = closing_order_type;
   request.price     = SymbolInfoDouble(sym, (request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID));
   
   Print(StringFormat("DEBUG: Closing hedge position - Ticket: %I64u, Volume: %.2f", ticket, volume));
   if(OrderSend(request, result))
   {
      Print("DEBUG: Hedge position closed successfully. Ticket: ", result.order);
      SendTradeResult(volume, result.order, true);
      return true;
   }
   else
   {
      Print("ERROR: Failed to close hedge position. Error: ", GetLastError());
      return false;
   }
}

// Helper function to find position by trade ID
ulong FindPositionByTradeId(string tradeId)
{
    int total = PositionsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        
        if(!PositionSelectByTicket(ticket)) continue;
        
        string comment = PositionGetString(POSITION_COMMENT);
        if(StringFind(comment, tradeId) >= 0)
            return ticket;
    }
    return 0;
}

//+------------------------------------------------------------------+
//| Close all hedge orders of both Buy and Sell types                  |
//+------------------------------------------------------------------+
void CloseAllHedgeOrders()
    { // Start of CloseAllHedgeOrders body
        Print("DEBUG: Starting CORRECTED simplified closure of all hedge orders");
        bool allClosed = true; // Flag to track if all closures were successful

        int total = PositionsTotal();
        Print("DEBUG: Found ", total, " total open positions to check.");

        // Loop backward through positions
        for(int i = total - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0) continue;

            // Select position without checking return value here, CTrade handles errors
            PositionSelectByTicket(ticket);

            // Check if the position matches the EA's Symbol and MagicNumber
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            long posMagic = PositionGetInteger(POSITION_MAGIC);

            // Add extra check for symbol validity before comparing
            if(posSymbol == "" || posMagic == 0)
            {
                 Print("DEBUG: Skipping position with invalid data - Ticket: ", ticket);
                 continue;
            }


            if(posSymbol == _Symbol && posMagic == MagicNumber)
            {
                Print("DEBUG: Found matching position. Attempting to close ticket: ", ticket, ", Symbol: ", posSymbol, ", Magic: ", posMagic);
                if(!trade.PositionClose(ticket, Slippage))
                {
                    Print("ERROR: Failed to close position ticket: ", ticket, ". Result Code: ", trade.ResultRetcode(), ", Comment: ", trade.ResultComment());
                    allClosed = false; // Mark failure if any close fails
                }
                else
                {
                    Print("DEBUG: Successfully closed position ticket: ", ticket, ". Result Code: ", trade.ResultRetcode(), ", Comment: ", trade.ResultComment());
                }
                Sleep(250); // Slightly increased sleep
            }
            else
            {
                 // Optional: Log why a position was skipped
                 // Print("DEBUG: Skipping position ticket: ", ticket, ", Symbol: ", posSymbol, ", Magic: ", posMagic);
            }
        }

        Print("DEBUG: Finished CORRECTED simplified closure attempt.");

        // Check remaining positions specifically for this EA
        int remainingEaPositions = 0;
        total = PositionsTotal();
         for(int i = total - 1; i >= 0; i--)
         {
             ulong ticket = PositionGetTicket(i);
             if(ticket <= 0) continue;
             PositionSelectByTicket(ticket);
             if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
             {
                 remainingEaPositions++;
             }
         }

        // Only reset trade groups if all targeted positions were closed successfully AND no EA positions remain
        if(allClosed && remainingEaPositions == 0)
        {
             Print("DEBUG: All hedge orders appear closed, resetting trade groups.");
             ResetTradeGroups();
        }
        else if (!allClosed)
        {
             Print("WARNING: Not all hedge positions could be closed. Trade groups not reset.");
        }
         else
        {
             Print("WARNING: EA positions might still exist (", remainingEaPositions, "). Trade groups not reset.");
        }
    } // End of CloseAllHedgeOrders body

// Function to calculate the take profit distance based on reward target
double GetTakeProfitDistance(double volume)
{
    // Get point value for the current symbol
    double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    // Get account balance
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    
    // Calculate target profit in money terms (e.g., 3% of balance)
    double targetProfit = balance * AC_BaseReward / 100.0; // Use variable from ACFunctions.mqh
    
    // Special handling for USTECH/NAS100
    if(StringFind(_Symbol, "USTECH") >= 0 || StringFind(_Symbol, "NAS100") >= 0)
    {
        // For USTECH, we need a much more conservative value estimation
        // Based on the screenshot, 145 points is only giving $0.29 profit with 0.01 lot
        // So the actual value is approximately $0.002 per point for 0.01 lot
        double pointCostPerLotUStech = 0.002;  // USD per point for 0.01 lot
        
        // Calculate point cost for our volume
        double pointCost = pointCostPerLotUStech * (volume / 0.01);
        
        // Calculate required points for target profit
        double requiredPoints = targetProfit / pointCost;
        
        // Ensure minimum take profit distance is sensible
        if(requiredPoints < 1000)
            requiredPoints = 1000;  // Absolute minimum safety
            
        double takeProfitDistance = requiredPoints * pointValue;
        
        Print("===== TAKE PROFIT CALCULATION (USTECH) =====");
        Print("Account balance: $", balance);
        Print("Target profit (", AC_BaseReward, "% of balance): $", targetProfit); // Use variable from ACFunctions.mqh
        Print("Current volume: ", volume);
        Print("Using much lower value estimate per point: $", pointCost);
        Print("Required points to reach target profit: ", requiredPoints);
        Print("Take profit distance in price: ", takeProfitDistance);
        Print("==================================");
        
        return takeProfitDistance;
    }
    
    // For other instruments, use the standard calculation
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    
    // Calculate how much each point is worth with the current volume
    double pointCost = (tickValue / tickSize) * volume;
    
    // Calculate how many points needed to reach target profit
    double requiredPoints = 0;
    if(pointCost > 0)
        requiredPoints = targetProfit / pointCost;
    else
        return 100 * pointValue; // Fallback if calculation fails
    
    // Convert to price distance
    double takeProfitDistance = requiredPoints * pointValue;
    
    Print("===== TAKE PROFIT CALCULATION =====");
    Print("Account balance: $", balance);
    Print("Target profit (", AC_BaseReward, "% of balance): $", targetProfit); // Use variable from ACFunctions.mqh
    Print("Current volume: ", volume);
    Print("Value per point: $", pointCost);
    Print("Required points to reach target profit: ", requiredPoints);
    Print("Take profit distance in price: ", takeProfitDistance);
    Print("==================================");
    
    return takeProfitDistance;
}

//+------------------------------------------------------------------+
//| Open a new hedge order – AC-aware + dynamic elastic hedging      |
//+------------------------------------------------------------------+
bool OpenNewHedgeOrder(string hedgeOrigin, string tradeId)
{
   /*----------------------------------------------------------------
     0.  Generic request skeleton
   ----------------------------------------------------------------*/
   MqlTradeRequest request = {};
   MqlTradeResult  result  = {};
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = _Symbol;
   request.magic     = MagicNumber;
   request.deviation = Slippage;

   /*----------------------------------------------------------------
     1.  Symbol limits
   ----------------------------------------------------------------*/
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   /*----------------------------------------------------------------
     2.  Stop-loss distance (ATR-based)
   ----------------------------------------------------------------*/
   double slDist = GetStopLossDistance();
   if(slDist <= 0)
   {
      Print("ERROR – SL distance not available, aborting order.");
      return false;
   }
   double slPoints = slDist / SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   /*----------------------------------------------------------------
     3.  Lot-size calculation – same core logic as MainACAlgo
   ----------------------------------------------------------------*/
   double volume = DefaultLot;                 // fallback (AC off)

   if(UseACRiskManagement)
   {
      // —— asym-comp sizing ——————————
      double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount  = equity * (currentRisk / 100.0);

      double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double onePointVal = tickValue * (point / tickSize);

      volume = riskAmount / (slPoints * onePointVal);
      volume = MathFloor(volume / lotStep) * lotStep;
      volume = MathMax(volume, minLot);
      volume = MathMin(volume, maxLot);
   }
   else
   {
      // —— fixed size, but respect broker limits ——
      volume = MathMax(DefaultLot, minLot);
      volume = MathMin(volume,     maxLot);
      volume = MathFloor(volume / lotStep) * lotStep;
   }

   if(volume < minLot - 1e-8)
   {
      Print("ERROR – calculated lot below broker minimum.");
      return false;
   }

   /*----------------------------------------------------------------
     4.  Elastic-hedge adjustment (only when AC off + hedging on)
   ----------------------------------------------------------------*/
   double finalVol = volume;
   if(!UseACRiskManagement && EnableHedging)
      finalVol = CalcHedgeLot(volume);   // <-- dynamic 5-25 % factor

   request.volume = finalVol;            // ← the size that will go out

   /*----------------------------------------------------------------
     5.  Order side & comment
   ----------------------------------------------------------------*/
   if(EnableHedging)
        request.type = (hedgeOrigin == "Buy") ? ORDER_TYPE_SELL
                                              : ORDER_TYPE_BUY;
   else  request.type = (hedgeOrigin == "Buy") ? ORDER_TYPE_BUY
                                               : ORDER_TYPE_SELL;

   request.comment = StringFormat("%s%s_%s",
                                  CommentPrefix, hedgeOrigin, tradeId);
   request.price   = SymbolInfoDouble(_Symbol,
                   (request.type == ORDER_TYPE_BUY) ? SYMBOL_ASK
                                                    : SYMBOL_BID);

   /*----------------------------------------------------------------
     6.  SL / TP
   ----------------------------------------------------------------*/
   double slPrice = (request.type == ORDER_TYPE_BUY)
                    ? request.price - slDist
                    : request.price + slDist;

   double tpPrice = 0.0;
   if(UseACRiskManagement)
   {
      double rr       = currentReward / currentRisk;     // e.g. 3 : 1
      double tpPoints = slPoints * rr;
      double tpDist   = tpPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      tpPrice = (request.type == ORDER_TYPE_BUY)
                ? request.price + tpDist
                : request.price - tpDist;
   }

   /*----------------------------------------------------------------
     7.  Send via CTrade
   ----------------------------------------------------------------*/
   bool sent = (request.type == ORDER_TYPE_BUY)
               ? trade.Buy (finalVol, _Symbol, request.price,
                            slPrice, tpPrice, request.comment)
               : trade.Sell(finalVol, _Symbol, request.price,
                            slPrice, tpPrice, request.comment);

   if(!sent)
   {
      PrintFormat("ERROR – CTrade %s failed (%d / %s)",
                  (request.type == ORDER_TYPE_BUY ? "Buy" : "Sell"),
                  trade.ResultRetcode(), trade.ResultComment());
      return false;
   }

   ulong deal = trade.ResultDeal();
   PrintFormat("INFO  – hedge %s %.2f lots  SL %.1f  TP %.1f  deal %I64u",
               (request.type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               finalVol, slPrice, tpPrice, deal);

   SendTradeResult(finalVol, deal, false, tradeId);
   return true;
}


// Removed SetTPSLLevels function as SL/TP are now set directly in trade.Buy/Sell

// Add this function after SendTradeResult function
void ProcessTradeResult(bool isWin, string tradeId, double profit = 0.0)
{
    if(UseACRiskManagement) // Use variable from ACFunctions.mqh
    {
        Print("DEBUG: ProcessTradeResult - IsWin: ", isWin, ", TradeId: ", tradeId, ", Profit: ", profit);
        UpdateRiskBasedOnResult(isWin, MagicNumber);
        Print("DEBUG: Updated asymmetrical compounding after trade result. New risk: ", 
              currentRisk, "%, Consecutive wins: ", consecutiveWins);
    }
}