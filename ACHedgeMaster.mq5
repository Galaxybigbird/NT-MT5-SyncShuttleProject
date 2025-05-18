#property link      ""
#property version   "1.85"
#property strict
#property description "Hedge Receiver EA for Go bridge server with Asymmetrical Compounding"

// Include the asymmetrical compounding functionality
#include "ACFunctions.mqh"
#include "ATRtrailing.mqh"
#include "StatusIndicator.mqh"
#include <Trade/Trade.mqh>
#include <Generic/HashMap.mqh> // Use standard template HashMap
#include <Strings/String.mqh>   // << NEW
#include <Trade/DealInfo.mqh> // For CDealInfo
#include <Trade/PositionInfo.mqh> // If CPositionInfo is used
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
const string    EA_COMMENT_PREFIX_BUY = CommentPrefix + "BUY_"; // Specific prefix for EA BUY hedges
const string    EA_COMMENT_PREFIX_SELL = CommentPrefix + "SELL_"; // Specific prefix for EA SELL hedges

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

// PositionTradeDetails class removed

// Dynamic‑hedge state
double g_highWaterEOD = 0.0;  // highest *settled* balance
const  double CUSHION_BAND = 120.0;   // *** NEW ***
double g_lastOHF      = 0.05; // last over‑hedge factor
 
 // Bridge connection status
 bool g_bridgeConnected = true;
 bool g_loggedDisconnect = false; // To prevent spamming logs
 int  g_timerCounter = 0;     // Counter for periodic tasks in OnTimer
 
 // Add these global variables at the top with other globals
 // Instead of struct array, use separate arrays for each field
string g_baseIds[];           // Array of base trade IDs
int g_totalQuantities[];      // Array of total quantities
int g_processedQuantities[];  // Array of processed quantities
string g_actions[];           // Array of trade actions
bool g_isComplete[];          // Array of completion flags
string g_ntInstrumentSymbols[]; // Array of NT instrument symbols
string g_ntAccountNames[];    // Array of NT account names
CHashMap<long, CString*> *g_map_position_id_to_base_id = NULL; // Map PositionID (long) to original base_id (CString*)
// CHashMap for PositionTradeDetails removed.
// New parallel arrays for MT5 position details will be added here.
long g_open_mt5_pos_ids[];       // Stores MT5 Position IDs
string g_open_mt5_base_ids[];    // Stores corresponding NT Base IDs
string g_open_mt5_nt_symbols[];  // Stores corresponding NT Instrument Symbols
string g_open_mt5_nt_accounts[]; // Stores corresponding NT Account Names

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
    ArrayResize(g_ntInstrumentSymbols, 0); // Initialize new array
    ArrayResize(g_ntAccountNames, 0);    // Initialize new array
    globalFutures = 0.0;  // Reset global futures counter
    g_highWaterEOD  = 0.0;      // <<< NEW – restart trailing‑dd calc
    Print("DEBUG: Trade groups reset complete. Global futures: ", globalFutures);
}

//+------------------------------------------------------------------+
//| Formats a datetime object into a UTC timestamp string            |
//| Example: 2023-10-27T10:30:00Z                                    |
//+------------------------------------------------------------------+
string FormatUTCTimestamp(datetime dt)
{
    MqlDateTime tm_struct;
    TimeToStruct(dt, tm_struct);
    return StringFormat("%04u-%02u-%02uT%02u:%02u:%02uZ",
                        tm_struct.year,
                        tm_struct.mon,
                        tm_struct.day,
                        tm_struct.hour,
                        tm_struct.min,
                        tm_struct.sec);
}

//+------------------------------------------------------------------+
//| Sends a notification about a hedge closure                       |
//+------------------------------------------------------------------+
void SendHedgeCloseNotification(string base_id,
                                string nt_instrument_symbol,
                                string nt_account_name,
                                double closed_hedge_quantity,
                                string closed_hedge_action,
                                datetime timestamp_dt) // Expects datetime
{
    string timestamp_str = FormatUTCTimestamp(timestamp_dt); // Format internally

    string payload = "{";
    payload += "\"base_id\":\"" + base_id + "\",";
    payload += "\"nt_instrument_symbol\":\"" + nt_instrument_symbol + "\",";
    payload += "\"nt_account_name\":\"" + nt_account_name + "\",";
    // Ensure proper formatting for double, considering symbol's digits for volume
    // SymbolInfoInteger returns long, DoubleToString expects int for digits.
    // This conversion is safe as symbol digits will not exceed int max.
    payload += "\"closed_hedge_quantity\":" + DoubleToString(closed_hedge_quantity, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) + ",";
    payload += "\"closed_hedge_action\":\"" + closed_hedge_action + "\",";
    payload += "\"timestamp\":\"" + timestamp_str + "\",";
    payload += "\"event_type\":\"hedge_close_notification\"";
    payload += "}";

    string url = BridgeURL + "/notify_hedge_close";
    char post_data[];
    char result_data[];
    string result_headers;
    int timeout = 5000; // 5 seconds

    int payload_len = StringToCharArray(payload, post_data, 0, WHOLE_ARRAY, CP_UTF8) - 1;
    if(payload_len < 0) payload_len = 0; // Ensure non-negative length
    ArrayResize(post_data, payload_len);

    ResetLastError();
    int res = WebRequest("POST", url, "Content-Type: application/json\r\n", timeout, post_data, result_data, result_headers);

    if(res == -1)
    {
        Print("Error in WebRequest for hedge close notification: ", GetLastError(), ". URL: ", url, ". Payload: ", payload);
    }
    else
    {
        string response_text = CharArrayToString(result_data);
        if(VerboseMode || res != 200)
        {
            Print("Hedge close notification sent. URL: ", url, ". Payload: ", payload, ". Response code: ", res, ". Response: ", response_text);
        }
        else if (VerboseMode)
        {
             Print("Hedge close notification sent successfully. Payload: ", payload, ". Response code: ", res, ". Response: ", response_text);
        }
    }
}

//+------------------------------------------------------------------+
//| Simple JSON parser class for processing bridge messages            |
//+------------------------------------------------------------------+
// Helper function to extract a string value from a JSON string given a key
string GetJSONStringValue(string json_string, string key_with_quotes)
{
    // The key_with_quotes parameter is expected to be like "\"nt_instrument_symbol\""
    // So, we search for key_with_quotes + ":" + "\"" 
    // e.g., "\"nt_instrument_symbol\":\""
    string search_pattern = StringSubstr(key_with_quotes, 1, StringLen(key_with_quotes) - 2); // Remove outer quotes from key_with_quotes
    search_pattern = "\"" + search_pattern + "\":\"";


    int key_pos = StringFind(json_string, search_pattern, 0);
    if(key_pos == -1)
    {
        // Fallback: Try key without quotes around it in the JSON, if the provided key_with_quotes was just the key name
        // This case might occur if the user passes "nt_instrument_symbol" instead of "\"nt_instrument_symbol\""
        // However, the original call passes "\"nt_instrument_symbol\"", so this fallback might not be strictly needed
        // but can add robustness if the input 'key_with_quotes' format varies.
        string plain_key = StringSubstr(key_with_quotes, 1, StringLen(key_with_quotes) - 2);
        search_pattern = plain_key + ":\""; 
        key_pos = StringFind(json_string, search_pattern, 0);
        if(key_pos == -1) return ""; // Key not found
    }

    int value_start_pos = key_pos + StringLen(search_pattern);
    int value_end_pos = StringFind(json_string, "\"", value_start_pos);

    if(value_end_pos == -1) return ""; // Closing quote not found for the value

    return StringSubstr(json_string, value_start_pos, value_end_pos - value_start_pos);
}
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
   ResetTradeGroups(); // This already resets g_baseIds etc. to 0 or an initial state.

   if(g_map_position_id_to_base_id == NULL) {
       // The template CHashMap might require an IEqualityComparer for long.
       // Let's try the default constructor first, assuming it handles 'long' or uses a default.
       // If not, we'll need: IEqualityComparer<long>* comparer = new CDefaultEqualityComparer<long>();
       // and then: new CHashMap<long, CString*>(comparer); and manage comparer's deletion.
       g_map_position_id_to_base_id = new CHashMap<long, CString*>();
       if(CheckPointer(g_map_position_id_to_base_id) == POINTER_INVALID) {
           Print("FATAL ERROR: Failed to new CHashMap<long, CString*>()!");
           g_map_position_id_to_base_id = NULL;
           return(INIT_FAILED);
       }
       Print("g_map_position_id_to_base_id (template CHashMap<long, CString*>) initialized.");
       // NOTE: This template version does NOT have SetFreeObjects. Manual deletion of CString* is required.
   }

   // Removed initialization for g_map_position_id_to_details
   
   // Initialize new global arrays for NT instrument and account names
   ArrayResize(g_ntInstrumentSymbols, 0);
   ArrayResize(g_ntAccountNames, 0);
   
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
   
   int health_check_result = WebRequest("GET", BridgeURL + "/health?source=hedgebot", headers, 0, tmp, tmp, response_headers);
   if(health_check_result < 0) // Use integer result code check
   {
      int error = GetLastError();
      if(error == ERR_FUNCTION_NOT_ALLOWED)
      {
         MessageBox("Please allow WebRequest for " + BridgeURL + " in MT5 Options -> Expert Advisors", "Error: WebRequest Not Allowed", MB_OK|MB_ICONERROR);
         // Removed detailed file path instructions as the MessageBox is clearer for users
         return INIT_FAILED;
      }
      // Log warning but allow initialization to continue, rely on OnTimer retry logic
      Print("WARNING: Initial bridge health check failed! Error: ", error, ". EA will attempt to connect periodically.");
      g_bridgeConnected = false;
      g_loggedDisconnect = true; // Log disconnect once initially
      UpdateStatusIndicator("Disconnected", clrRed); // Update indicator
   }
   else // health_check_result >= 0
   {
      // Success: WebRequest returned a non-negative code.
      // No need to check response body for a simple health ping.
      Print("=================================");
      Print("✓ Bridge server connection test passed (Status Code: ", health_check_result, ")");
      g_bridgeConnected = true;
      g_loggedDisconnect = false; // Ensure logged flag is reset on success
      UpdateStatusIndicator("Connected", clrGreen); // Update indicator
   }
   
   Print("=================================");
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
   
   // Set up timer for periodic tasks (trade checks and health pings) - every 1 second
   // EventSetTimer(1); // Triggers OnTimer every second
   EventSetMillisecondTimer(200); // Triggers OnTimer every 200 milliseconds
   g_timerCounter = 0; // Initialize timer counter
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function - Cleanup when EA is removed      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Stop the timer to prevent further trade checks
   // EventKillTimer();
   EventKillTimer();
   
   // Delete the trailing button
   ObjectDelete(0, ButtonName);
   
   // Remove the status indicator
   RemoveStatusIndicator();

   if(CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) {
       Print("Deinitializing g_map_position_id_to_base_id (template). Count: ", g_map_position_id_to_base_id.Count());
       long keys[];
       CString *values_ptr[];
       int count = g_map_position_id_to_base_id.CopyTo(keys, values_ptr);

       for(int i = 0; i < count; i++) {
           if(CheckPointer(values_ptr[i]) == POINTER_DYNAMIC) {
               Print("OnDeinit: Deleting CString for key ", keys[i], ". Value: '", values_ptr[i].Str(), "'");
               delete values_ptr[i]; // Delete the CString object
           }
       }
       g_map_position_id_to_base_id.Clear();
       delete g_map_position_id_to_base_id;
       g_map_position_id_to_base_id = NULL;
       Print("g_map_position_id_to_base_id (template) deinitialized and CStrings deleted.");
   }

   // Removed deinitialization for g_map_position_id_to_details
   
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

// Helper function to extract an integer value from a JSON string for a given key
// Returns the extracted integer.
// Returns defaultValue if key not found, or if value is not a valid integer.
int GetJSONIntValue(string json, string key, int defaultValue)
{
  string searchKey = "\"" + key + "\"";
  int keyPos = StringFind(json, searchKey);
  if(keyPos == -1) {
     // Print("DEBUG: GetJSONIntValue - Key '", key, "' not found. Returning default: ", defaultValue);
     return defaultValue;
  }

  // Search for colon *after* the key itself to avoid matching colons in preceding values
  int colonPos = StringFind(json, ":", keyPos + StringLen(searchKey));
  if(colonPos == -1) {
     // Print("DEBUG: GetJSONIntValue - Colon not found after key '", key, "'. Returning default: ", defaultValue);
     return defaultValue;
  }

  int start = colonPos + 1;
  // Skip whitespace characters
  while(start < StringLen(json))
  {
     ushort ch = StringGetCharacter(json, start);
     if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
        break;
     start++;
  }

  if(start >= StringLen(json)) { // Reached end of string while skipping whitespace
       // Print("DEBUG: GetJSONIntValue - End of string reached while skipping whitespace for key '", key, "'. Returning default: ", defaultValue);
       return defaultValue;
  }

  // Build the numeric string
  string numStr = "";
  // Assuming total_quantity is always positive, no explicit '-' check.
  // If negative numbers were possible for other int fields, a check for '-' would be needed here.

  while(start < StringLen(json))
  {
     ushort ch = StringGetCharacter(json, start);
     if(ch >= '0' && ch <= '9') // Only digits for an integer
     {
        numStr += CharToString((uchar)ch);
        start++;
     }
     else
        break;
  }

  if(numStr == "") {
     // Print("DEBUG: GetJSONIntValue - No digits found for key '", key, "'. Returning default: ", defaultValue);
     return defaultValue; // No digits found after key and colon, or value was not a number
  }
  
  int result = (int)StringToInteger(numStr);
  // Print("DEBUG: GetJSONIntValue - Key '", key, "', RawStr '", numStr, "', Parsed Int: ", result);
  return result;
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


// Returns ticket number (as long) or 0 if not found.
// ------------------------------------------------------------------
long FindOldestHedgeToCloseTicket(string hedgeOrigin)
{
   int total = PositionsTotal();
   string searchStr = CommentPrefix + hedgeOrigin;

   for(int i = 0; i < total; i++)
   {
      ulong ticket_ulong = PositionGetTicket(i);
      if(ticket_ulong == 0)                    continue;
      if(!PositionSelectByTicket(ticket_ulong)) continue;

      if(PositionGetString(POSITION_SYMBOL)   != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)   != MagicNumber) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, searchStr) != -1)
      {
         Print("DEBUG: FindOldestHedgeToCloseTicket – found ticket ", (long)ticket_ulong, " for origin ", hedgeOrigin);
         return (long)ticket_ulong; // Found a matching hedge position
      }
   }
   Print("DEBUG: FindOldestHedgeToCloseTicket – no ticket found for origin ", hedgeOrigin);
   return 0; // No matching position found
}

// ------------------------------------------------------------------
// Close one hedge position that matches the given origin (“Buy”|"Sell")
// and (optionally) a specificTradeId found in the comment.
// Returns true when a position is closed.
// THIS FUNCTION IS NOW LESS USED INTERNALLY due to loop refactor in OnTimer,
// but kept for potential external calls or other logic.
// ------------------------------------------------------------------
bool CloseOneHedgePosition(string hedgeOrigin, string specificTradeId = "")
{
   long ticket_to_close_long = 0;

   if (specificTradeId != "") {
       // If specificTradeId is provided, prioritize finding by it + origin
       int total = PositionsTotal();
       for(int i = 0; i < total; i++) {
           ulong current_ticket_ulong = PositionGetTicket(i);
           if(current_ticket_ulong == 0) continue;
           if(!PositionSelectByTicket(current_ticket_ulong)) continue;

           if(PositionGetString(POSITION_SYMBOL)   != _Symbol)     continue;
           if(PositionGetInteger(POSITION_MAGIC)   != MagicNumber) continue;
           
           string comment = PositionGetString(POSITION_COMMENT);
           string originSearchStr = CommentPrefix + hedgeOrigin;

           if (StringFind(comment, originSearchStr) != -1 && StringFind(comment, specificTradeId) != -1) {
               ticket_to_close_long = (long)current_ticket_ulong;
               Print("DEBUG: CloseOneHedgePosition - Found specific ticket ", ticket_to_close_long, " matching ID ", specificTradeId, " and origin ", hedgeOrigin);
               break;
           }
       }
       if (ticket_to_close_long == 0) {
           Print("DEBUG: CloseOneHedgePosition - No ticket found matching specificTradeId '", specificTradeId, "' and origin '", hedgeOrigin, "'");
           return false; // If specific ID was given but not found with origin, fail.
       }
   } else {
       // If no specificTradeId, find by origin only
       ticket_to_close_long = FindOldestHedgeToCloseTicket(hedgeOrigin);
       if (ticket_to_close_long == 0) {
           Print("DEBUG: CloseOneHedgePosition - No ticket found by origin '", hedgeOrigin, "' (no specificTradeId provided).");
           return false;
       }
   }
   
   ulong ticket_to_close = (ulong)ticket_to_close_long;
   
   // Select again to be sure, especially if found via specificTradeId loop
   if(!PositionSelectByTicket(ticket_to_close)) {
       Print("ERROR: CloseOneHedgePosition - Failed to select ticket ", (long)ticket_to_close, " before closing.");
       return false;
   }
   
   double volumeToClose = PositionGetDouble(POSITION_VOLUME);
   string originalComment = PositionGetString(POSITION_COMMENT); // Get comment before close

   Print(StringFormat(
         "DEBUG: Closing hedge position via CTrade (CloseOneHedgePosition) – Ticket:%I64u  Vol:%.2f  Comment:%s",
         ticket_to_close, volumeToClose, originalComment));

   bool closed = trade.PositionClose(ticket_to_close, Slippage);

   if(closed)
   {
      Print("DEBUG: PositionClose succeeded (via CloseOneHedgePosition). Order:", trade.ResultOrder(),
            "  Deal:", trade.ResultDeal());

      string closedTradeId = "";
      // Extract trade-id (portion after the origin part in the comment)
      int originMarkerEnd = StringFind(originalComment, hedgeOrigin);
      if(originMarkerEnd != -1) originMarkerEnd += StringLen(hedgeOrigin);
      
      int idStart = -1;
      if(originMarkerEnd != -1 && originMarkerEnd < StringLen(originalComment)) {
          idStart = StringFind(originalComment, "_", originMarkerEnd) + 1;
      }

      if(idStart > 0 && idStart < StringLen(originalComment)) { // Check idStart validity
          closedTradeId = StringSubstr(originalComment, idStart);
      } else {
          // Fallback or log if ID extraction is not as expected
          Print("DEBUG: CloseOneHedgePosition - Could not reliably extract closedTradeId from comment: '", originalComment, "' for origin '", hedgeOrigin, "'");
      }


      if(UseACRiskManagement)
      {
         double closeProfit = 0;
         if(trade.ResultDeal() > 0) closeProfit = HistoryDealGetDouble(trade.ResultDeal(), DEAL_PROFIT);
         ProcessTradeResult(closeProfit > 0, closedTradeId, closeProfit);
      }

      SendTradeResult(volumeToClose, trade.ResultOrder(), true, closedTradeId);
      return true;
   }
   else
   {
      Print(StringFormat("ERROR: PositionClose failed (via CloseOneHedgePosition) for ticket %I64u – %d / %s",
            ticket_to_close, trade.ResultRetcode(), trade.ResultComment()));
      return false;
   }
}


//+------------------------------------------------------------------+
//| Timer function - Called periodically to check for new trades     |
//+------------------------------------------------------------------+
void OnTimer()
{
   g_timerCounter++; // Increment counter each second

   // --- Periodic Health Ping (e.g., every 15 seconds) ---
   if(g_timerCounter % 15 == 0)
   {
      char ping_tmp[];
      string ping_headers = "";
      string ping_response_headers;
      int ping_result = WebRequest("GET", BridgeURL + "/health?source=hedgebot", ping_headers, 3000, ping_tmp, ping_tmp, ping_response_headers); // 3 sec timeout
      
      if(ping_result < 0)
      {
         // Log ping failure, but don't change g_bridgeConnected here.
         // Let GetTradeFromBridge handle the main connection status logic.
         Print("WARNING: Periodic health ping failed. Error: ", GetLastError());
      }
      else
      {
         // Optional: Log successful ping
         // Print("DEBUG: Periodic health ping successful (Status Code: ", ping_result, ")");
      }
   }

   // --- Get any pending trades from the bridge (every second) ---
   string response = GetTradeFromBridge();
   if(response == "") return;
   
   // Print("DEBUG: Received trade response: ", response); // Commented out for reduced logging on empty polls
   
   // Check for duplicate trade based on trade ID
   string tradeId = ""; // This is the unique ID from the bridge message, not base_id
   int idPos = StringFind(response, "\"id\":\"");
   if(idPos >= 0)
   {
       idPos += 6;  // Length of "\"id\":\""
       int idEndPos = StringFind(response, "\"", idPos);
       if(idEndPos > idPos)
       {
           tradeId = StringSubstr(response, idPos, idEndPos - idPos);
           // Print("DEBUG: Found message ID: ", tradeId); // Less verbose
           if(tradeId == lastTradeId)
           {
               Print("ACHM_LOG: [OnTimer] Ignoring duplicate message with ID: ", tradeId);
               return;
           }
           lastTradeId = tradeId;
       }
   }
   
   // Parse trade information from the JSON response.
   JSONParser parser(response);
   string incomingNtAction = ""; // Was 'type'
   double incomingNtQuantity = 0.0; // Was 'volume'
   double price = 0.0;
   string baseIdFromJson = ""; // Was 'executionId' when parsing "base_id", now explicitly 'baseIdFromJson'
   bool isExit = false;
   int measurementPips = 0;
   string orderType = "";
   
   // Note: parser.ParseObject now uses baseIdFromJson to store the "base_id" field from JSON.
   // 'type' field from JSON is stored in incomingNtAction.
   // 'volume' or 'quantity' field from JSON is stored in incomingNtQuantity.
   if(!parser.ParseObject(incomingNtAction, incomingNtQuantity, price, baseIdFromJson, isExit, measurementPips, orderType))
   {
      Print("ACHM_LOG: [OnTimer] Failed to parse JSON response: ", response);
      return;
   }
   
   // If "base_id" was not parsed by ParseObject (e.g. if it used "executionId" as fallback), try to get it directly.
   if (baseIdFromJson == "") {
       int tempBaseIdPos = StringFind(response, "\"base_id\":\"");
       if(tempBaseIdPos >= 0) {
           tempBaseIdPos += 11;
           int tempBaseIdEndPos = StringFind(response, "\"", tempBaseIdPos);
           if(tempBaseIdEndPos > tempBaseIdPos) {
               baseIdFromJson = StringSubstr(response, tempBaseIdPos, tempBaseIdEndPos - tempBaseIdPos);
           }
       }
   }
   Print("ACHM_LOG: [OnTimer] Parsed NT base_id: '", baseIdFromJson, "', Action: '", incomingNtAction, "', Qty: ", incomingNtQuantity);

   // Parse nt_instrument_symbol and nt_account_name
   string ntInstrument = GetJSONStringValue(response, "\"nt_instrument_symbol\"");
   string ntAccount = GetJSONStringValue(response, "\"nt_account_name\"");
   // Print("DEBUG: Parsed nt_instrument_symbol: ", ntInstrument); // Less verbose
   // Print("DEBUG: Parsed nt_account_name: ", ntAccount);
   
   // Extract total_quantity from response using the helper function (for the specific base_id)
   int totalQtyForBaseId = GetJSONIntValue(response, "total_quantity", 1);
   // Print("DEBUG: OnTimer - total_quantity for base_id '", baseIdFromJson, "' parsed as: ", totalQtyForBaseId);
   
   // Ensure incomingNtQuantity reflects "quantity" if present, otherwise it's already set by ParseObject from "volume"
   if(StringFind(response, "\"quantity\":") != -1) { // More specific check for "quantity":
       double qty_field = GetJSONDouble(response, "quantity");
       if (qty_field != 0) { // Check if GetJSONDouble returned a valid number
            // Print("DEBUG: Found 'quantity' field in JSON (", qty_field, "), potentially overriding parsed volume (", incomingNtQuantity, ")");
            incomingNtQuantity = qty_field;
       }
   }
   
   // Store globalFutures before this specific NT trade's impact
   double globalFuturesBeforeNtTrade = globalFutures;
   Print("ACHM_LOG: [OnTimer] Processing NT trade. Base_ID='", baseIdFromJson, "', Action='", incomingNtAction, "', Qty=", incomingNtQuantity, ", TotalQtyForBaseID=", totalQtyForBaseId, ". globalFutures BEFORE this trade: ", globalFuturesBeforeNtTrade);

   // Update globalFutures based on THIS incoming NT trade's action and quantity
   if(incomingNtAction == "Buy" || incomingNtAction == "BuyToCover") {
       globalFutures += incomingNtQuantity;
   } else if(incomingNtAction == "Sell" || incomingNtAction == "SellShort") {
       globalFutures -= incomingNtQuantity;
   }
   Print("ACHM_LOG: [OnTimer] globalFutures AFTER this trade: ", globalFutures);

   // Determine if this NT trade was a reducing trade
   bool isReducingNtTrade = false;
   if ((incomingNtAction == "Buy" || incomingNtAction == "BuyToCover") && globalFuturesBeforeNtTrade < 0 && globalFutures > globalFuturesBeforeNtTrade) {
       isReducingNtTrade = true;
       Print("ACHM_LOG: [OnTimer] NT trade '", baseIdFromJson, "' is REDUCING (Buy reducing short).");
   } else if ((incomingNtAction == "Sell" || incomingNtAction == "SellShort") && globalFuturesBeforeNtTrade > 0 && globalFutures < globalFuturesBeforeNtTrade) {
       isReducingNtTrade = true;
       Print("ACHM_LOG: [OnTimer] NT trade '", baseIdFromJson, "' is REDUCING (Sell reducing long).");
   } else if (globalFutures != 0 && globalFuturesBeforeNtTrade != 0 && MathAbs(globalFutures) < MathAbs(globalFuturesBeforeNtTrade)) {
        isReducingNtTrade = true;
        Print("ACHM_LOG: [OnTimer] NT trade '", baseIdFromJson, "' is REDUCING (magnitude reduced towards zero).");
   } else if (globalFutures == 0 && globalFuturesBeforeNtTrade != 0) {
       isReducingNtTrade = true; // Explicitly mark as reducing if it brings futures to zero
       Print("ACHM_LOG: [OnTimer] NT trade '", baseIdFromJson, "' is REDUCING (brought globalFutures to zero).");
   }
   
   bool signFlipped = (globalFuturesBeforeNtTrade > 0 && globalFutures < 0) || (globalFuturesBeforeNtTrade < 0 && globalFutures > 0);
   if (signFlipped) {
       Print("ACHM_LOG: [OnTimer] NT trade '", baseIdFromJson, "' FLIPPED globalFutures sign. From ", globalFuturesBeforeNtTrade, " to ", globalFutures);
   }
   
   // If globalFutures is now zero, close all hedges and reset.
   if(globalFutures == 0.0)
   {
       Print("ACHM_LOG: [OnTimer] globalFutures is zero. Closing all hedge orders.");
       CloseAllHedgeOrders();
       if (PositionsTotal() == 0 && ArraySize(g_baseIds) == 0) {
            Print("ACHM_LOG: [OnTimer] All positions closed and trade groups reset. Exiting OnTimer cycle.");
            return;
       } else {
            Print("ACHM_LOG: [OnTimer] globalFutures is zero, CloseAllHedgeOrders called, but positions/groups might remain. Proceeding to CleanupTradeGroups.");
       }
       CleanupTradeGroups();
       return;
   }

   // --- Overall Hedge Adjustment Logic ---
   int desiredNetBuyHedges = 0;
   int desiredNetSellHedges = 0;

   if (globalFutures > 0) { // NT is Net Long
       if (EnableHedging) { // MT5 should be Net Short
           desiredNetSellHedges = (int)MathRound(MathAbs(globalFutures)); // Round to nearest int
       } else { // MT5 copies NT, should be Net Long
           desiredNetBuyHedges = (int)MathRound(MathAbs(globalFutures));
       }
   } else if (globalFutures < 0) { // NT is Net Short
       if (EnableHedging) { // MT5 should be Net Long
           desiredNetBuyHedges = (int)MathRound(MathAbs(globalFutures));
       } else { // MT5 copies NT, should be Net Short
           desiredNetSellHedges = (int)MathRound(MathAbs(globalFutures));
       }
   }
   Print("ACHM_LOG: [HedgeAdjust] Desired Hedges: Buy=", desiredNetBuyHedges, ", Sell=", desiredNetSellHedges, " (Based on globalFutures=", globalFutures, ", EnableHedging=", EnableHedging, ")");

   int currentMt5BuyPositions = 0;
   int currentMt5SellPositions = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
       if(PositionSelectByTicket(PositionGetTicket(i))) {
           if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
               if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                   currentMt5BuyPositions++;
               } else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                   currentMt5SellPositions++;
               }
           }
       }
   }
   Print("ACHM_LOG: [HedgeAdjust] Current MT5 Hedges: Buy=", currentMt5BuyPositions, ", Sell=", currentMt5SellPositions);

   // Adjust Sell Hedges
   int sellHedgesToAdjust = desiredNetSellHedges - currentMt5SellPositions;
   if (sellHedgesToAdjust > 0) {
       Print("ACHM_LOG: [HedgeAdjust] Need to OPEN ", sellHedgesToAdjust, " SELL hedges. Triggering base_id: '", baseIdFromJson, "'");
       for (int h = 0; h < sellHedgesToAdjust; h++) {
           if (!OpenNewHedgeOrder("Sell", baseIdFromJson, ntInstrument, ntAccount)) {
               Print("ERROR: [HedgeAdjust] Failed to open new SELL hedge #", h+1, ". Breaking.");
               break;
           }
       }
   } else if (sellHedgesToAdjust < 0) {
       int sellHedgesToClose = MathAbs(sellHedgesToAdjust);
       Print("ACHM_LOG: [HedgeAdjust] Need to CLOSE ", sellHedgesToClose, " SELL hedges.");
       for (int h = 0; h < sellHedgesToClose; h++) {
           if (!CloseOneHedgePosition("Sell")) {
               Print("ERROR: [HedgeAdjust] Failed to close existing SELL hedge #", h+1, ". Breaking.");
               break;
           }
       }
   }

   // Adjust Buy Hedges
   int buyHedgesToAdjust = desiredNetBuyHedges - currentMt5BuyPositions;
   if (buyHedgesToAdjust > 0) {
       Print("ACHM_LOG: [HedgeAdjust] Need to OPEN ", buyHedgesToAdjust, " BUY hedges. Triggering base_id: '", baseIdFromJson, "'");
       for (int h = 0; h < buyHedgesToAdjust; h++) {
           if (!OpenNewHedgeOrder("Buy", baseIdFromJson, ntInstrument, ntAccount)) {
               Print("ERROR: [HedgeAdjust] Failed to open new BUY hedge #", h+1, ". Breaking.");
               break;
           }
       }
   } else if (buyHedgesToAdjust < 0) {
       int buyHedgesToClose = MathAbs(buyHedgesToAdjust);
       Print("ACHM_LOG: [HedgeAdjust] Need to CLOSE ", buyHedgesToClose, " BUY hedges.");
       for (int h = 0; h < buyHedgesToClose; h++) {
           if (!CloseOneHedgePosition("Buy")) {
               Print("ERROR: [HedgeAdjust] Failed to close existing BUY hedge #", h+1, ". Breaking.");
               break;
           }
       }
   }
   
   // --- Trade Group Management (g_baseIds, etc.) ---
   // This logic is now conditional: only for opening trades or trades that flip the sign,
   // not for purely reducing trades whose effect is already handled by globalFutures adjustment.
   if (!isReducingNtTrade || signFlipped) {
       Print("ACHM_LOG: [TradeGroup] NT trade '", baseIdFromJson, "' is OPENING or FLIPPING. Managing trade group.");
       int groupIndex = -1;
       for(int i = 0; i < ArraySize(g_baseIds); i++) {
           if(g_baseIds[i] == baseIdFromJson) {
               groupIndex = i;
               Print("ACHM_LOG: [TradeGroup] Found existing group for base_id '", baseIdFromJson, "' at index ", i);
               break;
           }
       }

       if(groupIndex == -1) { // New opening base_id
           groupIndex = ArraySize(g_baseIds);
           ArrayResize(g_baseIds, groupIndex + 1);
           ArrayResize(g_totalQuantities, groupIndex + 1);
           ArrayResize(g_processedQuantities, groupIndex + 1);
           ArrayResize(g_actions, groupIndex + 1);
           ArrayResize(g_isComplete, groupIndex + 1);
           ArrayResize(g_ntInstrumentSymbols, groupIndex + 1);
           ArrayResize(g_ntAccountNames, groupIndex + 1);

           g_baseIds[groupIndex] = baseIdFromJson;
           g_totalQuantities[groupIndex] = totalQtyForBaseId;
           g_processedQuantities[groupIndex] = 0; // Will be updated below
           g_actions[groupIndex] = incomingNtAction;
           g_isComplete[groupIndex] = false;
           g_ntInstrumentSymbols[groupIndex] = ntInstrument;
           g_ntAccountNames[groupIndex] = ntAccount;
           Print("ACHM_LOG: [TradeGroup] Created NEW group for base_id '", baseIdFromJson, "' at index ", groupIndex, ". TotalQtyForGroup: ", totalQtyForBaseId, ", Action: ", incomingNtAction);
       }

       if (groupIndex != -1) { // Ensure groupIndex is valid
           g_processedQuantities[groupIndex] += (int)incomingNtQuantity;
           Print("ACHM_LOG: [TradeGroup] Updated processed qty for group '", baseIdFromJson, "' by ", (int)incomingNtQuantity,
                 ". New processed: ", g_processedQuantities[groupIndex], ", Total for group: ", g_totalQuantities[groupIndex]);

           if (!g_isComplete[groupIndex] && g_processedQuantities[groupIndex] >= g_totalQuantities[groupIndex]) {
               g_isComplete[groupIndex] = true;
               Print("ACHM_LOG: [TradeGroup] Group for base_id '", baseIdFromJson, "' is now COMPLETE. Processed: ", g_processedQuantities[groupIndex], ", Total: ", g_totalQuantities[groupIndex]);
           }
       }
   } else {
       Print("ACHM_LOG: [TradeGroup] NT trade '", baseIdFromJson, "' is REDUCING and NOT flipping. NOT creating/updating specific trade group. Its effect was handled by globalFutures adjustment.");
   }
   
   CleanupTradeGroups();
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
   
   // Send result to bridge with retry logic
   int res = WebRequest("POST", BridgeURL + "/mt5/trade_result", headers, 5000, result_data, response_data, response_headers); // Added 5 sec timeout
   
   if(res < 0) // Check integer return code
   {
      int error = GetLastError();
      Print("Error sending trade result via WebRequest. Error code: ", error, ". Retrying in 5 seconds...");
      if(!g_loggedDisconnect) // Log disconnect only once per disconnect period
      {
          Print("Bridge connection lost (SendTradeResult).");
          g_loggedDisconnect = true;
          UpdateStatusIndicator("Disconnected", clrRed); // Update indicator
      }
      g_bridgeConnected = false;
      Sleep(5000); // Wait before returning false
      return false;
   }
   
   // Optional: Check response_data for confirmation from bridge if needed
   string response_str = CharArrayToString(response_data);
   if(StringFind(response_str, "success") < 0) // Example check
   {
       Print("Warning: Bridge acknowledged trade result POST, but response was unexpected: ", response_str);
       // Decide if this constitutes a failure or just a warning
   }
   
   if(!g_bridgeConnected) // Log reconnection if previously disconnected
   {
       Print("Reconnected to bridge successfully (SendTradeResult).");
       g_loggedDisconnect = false;
       UpdateStatusIndicator("Connected", clrGreen); // Update indicator
   }
   g_bridgeConnected = true;
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
   
   // Send request to bridge with retry logic
   int web_result = WebRequest("GET", BridgeURL + "/mt5/get_trade", headers, 5000, response_data, response_data, response_headers); // Added 5 sec timeout
   
   // --- Error Handling & Retry Logic ---
   if(web_result < 0) // Check integer return code for errors
   {
      int error = GetLastError();
      if(!g_loggedDisconnect) // Log disconnect only once per disconnect period
      {
          Print("Bridge connection failed (GetTradeFromBridge). Error: ", error, ". Retrying in 10 seconds...");
          g_loggedDisconnect = true;
          UpdateStatusIndicator("Disconnected", clrRed); // Update indicator
      }
      g_bridgeConnected = false;
      Sleep(10000); // Wait 10 seconds before next attempt (via OnTimer)
      return ""; // Return empty, OnTimer will call again
   }
   
   // Convert response to string
   string response_str = CharArrayToString(response_data);
   
   // Check for empty response or HTML error page
   if(response_str == "" || StringFind(response_str, "<!doctype html>") >= 0 || StringFind(response_str, "<html") >= 0)
   {
      if(!g_loggedDisconnect) // Log disconnect only once per disconnect period
      {
          Print("Received empty or HTML error response from bridge. Retrying in 10 seconds...");
          g_loggedDisconnect = true;
          UpdateStatusIndicator("Invalid Resp", clrOrange); // Update indicator
      }
      g_bridgeConnected = false;
      Sleep(10000); // Wait 10 seconds
      return ""; // Return empty
   }
   
   // --- Success / Reconnection Logic ---
   if(!g_bridgeConnected) // Log successful reconnection if previously disconnected
   {
       Print("Reconnected to bridge successfully (GetTradeFromBridge).");
       g_loggedDisconnect = false;
       UpdateStatusIndicator("Connected", clrGreen); // Update indicator
   }
   g_bridgeConnected = true; // Mark as connected
   
   // --- Original Logic for Valid Response ---
   
   // Only print response if it's not "no_trade" or if verbose mode is on
   if(VerboseMode || StringFind(response_str, "no_trade") < 0)
   {
      // Print("Response: ", response_str); // Commented out for reduced logging on empty polls
   }
   
   // Check for no trades (valid response, just no action needed)
   if(StringFind(response_str, "no_trade") >= 0)
   {
      return ""; // Return empty, signifies no trade action
   }
   
   // Basic JSON validation (already somewhat covered by empty check)
   if(StringFind(response_str, "{") < 0 || StringFind(response_str, "}") < 0)
   {
      // This case might indicate a non-JSON valid response, log it but maybe treat as disconnect?
      if(!g_loggedDisconnect)
      {
          Print("Received non-JSON response from bridge: ", response_str, ". Retrying in 10 seconds...");
          g_loggedDisconnect = true;
          UpdateStatusIndicator("Invalid Resp", clrOrange); // Update indicator
      }
      g_bridgeConnected = false;
      Sleep(10000);
      return "";
   }
   
   // If we reach here, the response is likely a valid JSON trade instruction
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
bool OpenNewHedgeOrder(string hedgeOrigin, string tradeId, string nt_instrument_symbol, string nt_account_name)
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
   // hedgeOrigin is the intended MT5 action ("Buy" or "Sell") determined in OnTimer.
   // If EnableHedging is true, OnTimer sets hedgeOrigin to the OPPOSITE of the NT action.
   // If EnableHedging is false (copying), OnTimer sets hedgeOrigin to the SAME as the NT action.
   // Therefore, OpenNewHedgeOrder simply executes the action specified by hedgeOrigin.
   if (hedgeOrigin == "Buy") {
       request.type = ORDER_TYPE_BUY;
   } else if (hedgeOrigin == "Sell") {
       request.type = ORDER_TYPE_SELL;
   } else {
       Print("ERROR: OpenNewHedgeOrder - Invalid hedgeOrigin '", hedgeOrigin, "'. Cannot determine order type.");
       // It's crucial to return or handle this error to prevent unintended trades.
       // Depending on desired behavior, could default or simply fail.
       // For safety, returning false to prevent order placement.
       return false;
   }

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
   Print("INFO: OpenNewHedgeOrder: Placing MT5 Order. Determined MT5 Action (from hedgeOrigin param): '", hedgeOrigin, "', Actual MqlTradeRequest.type: ", EnumToString(request.type), ", Comment: '", request.comment, "', Volume: ", finalVol, " for base_id: '", tradeId, "'"); // Added Logging
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

   ulong deal_ticket_for_map = trade.ResultDeal();
   PrintFormat("INFO  – hedge %s %.2f lots  SL %.1f  TP %.1f  deal %I64u",
               (request.type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               finalVol, slPrice, tpPrice, deal_ticket_for_map);

   if(deal_ticket_for_map > 0)
   {
       if(HistoryDealSelect(deal_ticket_for_map))
       {
           ulong new_mt5_position_id = HistoryDealGetInteger(deal_ticket_for_map, DEAL_POSITION_ID);
           if(new_mt5_position_id > 0)
           {
               // --- Store details in new parallel arrays ---
               int current_array_size = ArraySize(g_open_mt5_pos_ids);
               ArrayResize(g_open_mt5_pos_ids, current_array_size + 1);
               ArrayResize(g_open_mt5_base_ids, current_array_size + 1);
               ArrayResize(g_open_mt5_nt_symbols, current_array_size + 1);
               ArrayResize(g_open_mt5_nt_accounts, current_array_size + 1);

               g_open_mt5_pos_ids[current_array_size] = (long)new_mt5_position_id;
               g_open_mt5_base_ids[current_array_size] = tradeId; // 'tradeId' parameter is the base_id
               g_open_mt5_nt_symbols[current_array_size] = nt_instrument_symbol;
               g_open_mt5_nt_accounts[current_array_size] = nt_account_name;
               Print("DEBUG: Stored details in parallel arrays for PosID ", (long)new_mt5_position_id, " at index ", current_array_size,
                     ". BaseID: ", tradeId, ", NT Symbol: ", nt_instrument_symbol, ", NT Account: ", nt_account_name);

               // --- Existing logic for g_map_position_id_to_base_id (can be reviewed for removal later if redundant) ---
               string original_base_id_from_nt = tradeId; // 'tradeId' param is the base_id
               if(CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) {
                   CString *s_base_id_obj = new CString();
                   if(CheckPointer(s_base_id_obj) == POINTER_INVALID){
                       Print("ERROR: OpenNewHedgeOrder - Failed to create CString object for base_id '", original_base_id_from_nt, "'");
                   } else {
                       s_base_id_obj.Assign(original_base_id_from_nt);
                       if(!g_map_position_id_to_base_id.Add((long)new_mt5_position_id, s_base_id_obj)) { // TValue is CString*
                           Print("ERROR: OpenNewHedgeOrder - Failed to Add base_id '", original_base_id_from_nt, "' to g_map_position_id_to_base_id for PositionID ", new_mt5_position_id, ". Deleting CString.");
                           delete s_base_id_obj;
                       } else {
                           Print("DEBUG_HEDGE_CLOSURE: Stored mapping for MT5 PosID ", (long)new_mt5_position_id, " to base_id '", s_base_id_obj.Str(), "' in g_map_position_id_to_base_id.");
                       }
                   }
               } else {
                   Print("ERROR: OpenNewHedgeOrder - g_map_position_id_to_base_id (template) is not initialized. Cannot store mapping.");
               }
           }
           else
           {
               Print("DEBUG_HEDGE_OPEN: OpenNewHedgeOrder - Could not get PositionID from deal ", deal_ticket_for_map, " for mapping.");
           }
       }
       else
       {
           Print("DEBUG_HEDGE_OPEN: OpenNewHedgeOrder - Could not select deal ", deal_ticket_for_map, " for mapping.");
       }
   }

   SendTradeResult(finalVol, deal_ticket_for_map, false, tradeId);
   return true; // Ensure all paths return a value
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

//+------------------------------------------------------------------+
//| Helper function to create ISO 8601 UTC timestamp                 |
//+------------------------------------------------------------------+
string GetISOUtcTimestamp()
{
    MqlDateTime dt_struct;
    TimeToStruct(TimeGMT(), dt_struct); // Use TimeGMT() for UTC
    return StringFormat("%04u-%02u-%02uT%02u:%02u:%02uZ",
                        dt_struct.year, dt_struct.mon, dt_struct.day,
                        dt_struct.hour, dt_struct.min, dt_struct.sec);
}

//+------------------------------------------------------------------+
//| Send Hedge Close Notification to BridgeApp                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| GetCommentPrefixForOriginalHedge                                 |
//| Determines the expected comment prefix of an MT5 hedge order     |
//| based on the original NinjaTrader action stored for its base_id. |
//+------------------------------------------------------------------+
string GetCommentPrefixForOriginalHedge(string base_id) // Parameter name changed
{
    string determined_prefix = "";
    string original_nt_action_log = "N/A";

    if (base_id == NULL || StringLen(base_id) == 0) {
        Print("DEBUG_HEDGE_CLOSURE: GetCommentPrefix - base_id is empty. Cannot determine prefix.");
        // Log before returning
        Print("DEBUG_HEDGE_CLOSURE: GetCommentPrefix - base_id: ", base_id, ", nt_action: ", original_nt_action_log, ", determined_prefix: ", determined_prefix);
        return determined_prefix;
    }

    int groupIndex = -1;
    int g_baseIds_array_size = ArraySize(g_baseIds);
    for(int i = 0; i < g_baseIds_array_size; i++)
    {
        if(g_baseIds[i] != NULL && g_baseIds[i] == base_id)
        {
            groupIndex = i;
            break;
        }
    }

    if(groupIndex != -1)
    {
        if (groupIndex < ArraySize(g_actions) && g_actions[groupIndex] != NULL) {
            string original_nt_action = g_actions[groupIndex];
            original_nt_action_log = original_nt_action; // For logging

            string mt5_action_for_hedge = original_nt_action;
            if(EnableHedging)
            {
                if(original_nt_action == "Buy" || original_nt_action == "BuyToCover")
                {
                    mt5_action_for_hedge = "Sell";
                }
                else if(original_nt_action == "Sell" || original_nt_action == "SellShort")
                {
                    mt5_action_for_hedge = "Buy";
                }
            }
            // If not hedging, mt5_action_for_hedge remains original_nt_action

            if(mt5_action_for_hedge == "Buy")
            {
                determined_prefix = EA_COMMENT_PREFIX_BUY;
            }
            else if(mt5_action_for_hedge == "Sell")
            {
                determined_prefix = EA_COMMENT_PREFIX_SELL;
            }
            // No else needed, determined_prefix remains "" if no match, handled by log.
        } else {
             original_nt_action_log = "Trade group action not found or NULL";
        }
    }
    else
    {
        original_nt_action_log = "Trade group not found for base_id";
    }
    
    Print("DEBUG_HEDGE_CLOSURE: GetCommentPrefix - base_id: ", base_id, ", nt_action: ", original_nt_action_log, ", determined_prefix: '", determined_prefix, "'");
    return determined_prefix;
}

//+------------------------------------------------------------------+
//| Handle Asymmetrical Compounding Adjustments on Hedge Closure     |
//+------------------------------------------------------------------+
void HandleACAdjustmentOnHedgeClosure(string base_trade_id, double closed_volume, double pnl)
{
    Print("DEBUG: HandleACAdjustmentOnHedgeClosure called for base_trade_id: ", base_trade_id,
          ", Closed Volume: ", closed_volume, ", PnL: ", pnl);

    // Example: If using AC, you might update some AC-specific state here.
    // This is highly dependent on your AC logic.
    if(UseACRiskManagement)
    {
        // This is where you'd integrate with ACFunctions.mqh if needed
        // For example, if closing a hedge impacts the "bankroll" or "kelly fraction"
        // used by AC for subsequent trades.
        // UpdateACStateOnHedgeClosure(base_trade_id, pnl); // Hypothetical function
        Print("AC is enabled. Further AC-specific logic for hedge closure would go here.");
        // Potentially use ProcessTradeResult or similar logic from ACFunctions.mqh
        // For example, if pnl > 0 it's a win, if pnl < 0 it's a loss for the hedge.
        // This depends on how PnL is reported for the hedge and how it affects overall strategy.
        // bool isHedgeWin = (pnl > 0); // Simplified: actual win/loss might be more complex
        // UpdateRiskBasedOnResult(isHedgeWin, MagicNumber); // Example call
    }
}

//+------------------------------------------------------------------+
//| Remove an element from all four parallel MT5 position tracking arrays |
//+------------------------------------------------------------------+
void RemoveFromOpenMT5Arrays(int index_to_remove)
{
    int array_size = ArraySize(g_open_mt5_pos_ids); // Assuming all parallel arrays have the same size
    if(index_to_remove < 0 || index_to_remove >= array_size)
    {
        Print("ERROR: RemoveFromOpenMT5Arrays - Invalid index: ", index_to_remove, ". Array size: ", array_size);
        return;
    }

    Print("DEBUG: RemoveFromOpenMT5Arrays - Removing element at index ", index_to_remove, " from parallel arrays. Current size: ", array_size);

    // Shift elements for g_open_mt5_pos_ids
    for(int j = index_to_remove; j < array_size - 1; j++)
    {
        g_open_mt5_pos_ids[j] = g_open_mt5_pos_ids[j+1];
    }
    // Shift elements for g_open_mt5_base_ids
    for(int j = index_to_remove; j < array_size - 1; j++)
    {
        g_open_mt5_base_ids[j] = g_open_mt5_base_ids[j+1];
    }
    // Shift elements for g_open_mt5_nt_symbols
    for(int j = index_to_remove; j < array_size - 1; j++)
    {
        g_open_mt5_nt_symbols[j] = g_open_mt5_nt_symbols[j+1];
    }
    // Shift elements for g_open_mt5_nt_accounts
    for(int j = index_to_remove; j < array_size - 1; j++)
    {
        g_open_mt5_nt_accounts[j] = g_open_mt5_nt_accounts[j+1];
    }

    // Resize all arrays
    int new_size = array_size - 1;
    if (new_size < 0) new_size = 0; // Ensure size doesn't go negative, though logic should prevent this.

    ArrayResize(g_open_mt5_pos_ids, new_size);
    ArrayResize(g_open_mt5_base_ids, new_size);
    ArrayResize(g_open_mt5_nt_symbols, new_size);
    ArrayResize(g_open_mt5_nt_accounts, new_size);
    
    Print("DEBUG: RemoveFromOpenMT5Arrays - Arrays resized to ", new_size);
}

//+------------------------------------------------------------------+
//| TradeTransaction event handler                                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    Print("DEBUG_HEDGE_CLOSURE: OnTradeTransaction fired. Type: ", EnumToString(trans.type), ", Deal: ", trans.deal, ", Order: ", trans.order, ", Pos: ", trans.position);

    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
    {
        Print("DEBUG_HEDGE_CLOSURE: Not a DEAL_ADD transaction. Skipping.");
        return;
    }

    ulong deal_ticket = trans.deal;
    if(deal_ticket == 0)
    {
        Print("DEBUG_HEDGE_CLOSURE: Deal ticket is 0. Skipping.");
        return;
    }

    if(!HistoryDealSelect(deal_ticket))
    {
        Print("ERROR: OnTradeTransaction - Could not select deal ", deal_ticket, " from history.");
        return;
    }
    Print("DEBUG_HEDGE_CLOSURE: Successfully selected deal ", deal_ticket, " for processing.");

    ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
    ulong closing_deal_position_id = trans.position; // This is the PositionID of the position being affected by the transaction.
    // ulong original_deal_position_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID); // PositionID from the deal itself, keep if needed for other logic
    long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC); // Magic of the deal itself

    Print("DEBUG_HEDGE_CLOSURE: Deal ", deal_ticket, " - Entry: ", EnumToString(deal_entry),
          ", Trans.PositionID (for map key): ", closing_deal_position_id,
          // ", Deal.PositionID (from history): ", original_deal_position_id,
          ", DealMagic: ", deal_magic);

    // We are interested in position closures or reductions
    if(deal_entry == DEAL_ENTRY_OUT || deal_entry == DEAL_ENTRY_INOUT)
    {
        Print("DEBUG_HEDGE_CLOSURE: Processing closing deal ", deal_ticket, " for Trans.PositionID ", closing_deal_position_id, ", Entry: ", EnumToString(deal_entry));

        if(closing_deal_position_id == 0) // Use the PositionID from the transaction
        {
            Print("DEBUG_HEDGE_CLOSURE: Transaction PositionID is 0 for closing deal ", deal_ticket, ". Cannot trace origin. Skipping further processing.");
            return;
        }

        // Declare details_for_notification here to be in scope for later Print statements (e.g. line 2316+)
        // PositionTradeDetails *details_for_notification = NULL; // Removed

        // Variables for SendHedgeCloseNotification, populated before TryGetValue
        double notification_deal_volume = 0.0;
        string notification_hedge_action = "unknown";
        ulong current_deal_ticket_for_notification = trans.deal; // Use the current transaction's deal ticket

        if(HistoryDealSelect(current_deal_ticket_for_notification))
        {
            notification_deal_volume = HistoryDealGetDouble(current_deal_ticket_for_notification, DEAL_VOLUME);
            ENUM_DEAL_TYPE deal_type_for_notification = (ENUM_DEAL_TYPE)HistoryDealGetInteger(current_deal_ticket_for_notification, DEAL_TYPE);
            
            // The 'closed_hedge_action' for the notification is the action of the deal that closed the hedge.
            if(deal_type_for_notification == DEAL_TYPE_SELL) notification_hedge_action = "sell";
            else if(deal_type_for_notification == DEAL_TYPE_BUY) notification_hedge_action = "buy";
            // else it remains "unknown"
            PrintFormat("DEBUG_HEDGE_ACTION: Closing Deal Ticket: %I64u, Deal Type for Notification: %s (%d), Determined Notification Hedge Action: %s", current_deal_ticket_for_notification, EnumToString(deal_type_for_notification), deal_type_for_notification, notification_hedge_action);
        }
        else
        {
            Print("ERROR: OnTradeTransaction - Could not select deal ", current_deal_ticket_for_notification, " to get volume/action for notification. PosID: ", closing_deal_position_id);
            // Notification might not be sendable or will have default/unknown values if this fails
        }

        // Removed old g_map_position_id_to_details lookup logic.
        // New parallel array lookup will be done inside if(is_position_closed) block.

        // --- Existing logic to retrieve base_id_for_prefix for AC Adjustment (remains for now) ---
        string base_id_for_prefix = ""; // This is for AC adjustment logic later
        if(CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) {
            CString *retrieved_s_base_id_ptr = NULL;
            if(g_map_position_id_to_base_id.TryGetValue((long)closing_deal_position_id, retrieved_s_base_id_ptr)) {
                if(CheckPointer(retrieved_s_base_id_ptr) == POINTER_DYNAMIC) {
                    base_id_for_prefix = retrieved_s_base_id_ptr.Str();
                    Print("DEBUG_HEDGE_CLOSURE: For AC - Retrieved base_id '", base_id_for_prefix, "' from OLD map for position_id ", (long)closing_deal_position_id, ".");
                } else {
                     Print("DEBUG_HEDGE_CLOSURE: For AC - Retrieved NULL CString* from OLD g_map_position_id_to_base_id for PositionID ", closing_deal_position_id);
                }
            } else {
                 Print("DEBUG_HEDGE_CLOSURE: For AC - Could not find key (PositionID ", closing_deal_position_id, ") in OLD g_map_position_id_to_base_id. Map count: ", g_map_position_id_to_base_id.Count());
            }
        } else {
            Print("ERROR: OnTradeTransaction - OLD g_map_position_id_to_base_id is not initialized. Cannot retrieve mapping for PositionID ", closing_deal_position_id);
        }
        // Note: base_id_for_prefix is used by AC logic later. If it's empty, that logic might be affected.
        // The notification logic below will rely on notification_base_id.

        // Now, check if this position (closing_deal_position_id) is fully closed.
        CPositionInfo posInfo;
        bool is_position_closed = true; // Assume closed unless found open

        if(posInfo.SelectByTicket(closing_deal_position_id))
        {
            if(posInfo.Volume() > 0)
            {
                is_position_closed = false; // Still has volume
                Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " is NOT fully closed yet. Volume: ", posInfo.Volume());
            }
        }
        else
        {
            Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " not found by SelectByTicket. Assuming closed.");
        }

        if(is_position_closed)
        {
            Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " is now fully closed.");

            // --- BEGIN HEDGE CLOSURE NOTIFICATION LOGIC (using parallel arrays) ---
            string notify_base_id = "";
            string notify_nt_symbol = "";
            string notify_nt_account = "";
            bool details_found = false;
            int removal_index = -1; // To store the index for removal from parallel arrays

            for(int i = 0; i < ArraySize(g_open_mt5_pos_ids); i++) {
                if(g_open_mt5_pos_ids[i] == (long)closing_deal_position_id) { // closing_deal_position_id is trans.position
                    notify_base_id = g_open_mt5_base_ids[i];
                    notify_nt_symbol = g_open_mt5_nt_symbols[i];
                    notify_nt_account = g_open_mt5_nt_accounts[i];
                    details_found = true;
                    removal_index = i; // Store the index for later removal
                    Print("DEBUG: Found details in parallel arrays for closed PosID ", (long)closing_deal_position_id, " at index ", i,
                          ". BaseID: ", notify_base_id, ", NT Symbol: ", notify_nt_symbol, ", NT Account: ", notify_nt_account);
                    break;
                }
            }

            if(details_found) {
                // notification_deal_volume and notification_hedge_action were sourced earlier in OnTradeTransaction
                // from the current deal (trans.deal details).
                if (notification_hedge_action != "unknown" && notification_deal_volume > 0) {
                    SendHedgeCloseNotification(
                        notify_base_id,
                        notify_nt_symbol,
                        notify_nt_account,
                        notification_deal_volume,    // Sourced from trans.deal's volume
                        notification_hedge_action, // Sourced from trans.deal's type
                        TimeGMT()
                    );
                    PrintFormat("DEBUG_HEDGE_CLOSURE: Successfully sent hedge close notification via parallel arrays for PosID %d. BaseID: %s", (long)closing_deal_position_id, notify_base_id);

                    // Clean up the parallel arrays now that the notification is sent and details were found
                    if(removal_index != -1) {
                        RemoveFromOpenMT5Arrays(removal_index);
                    } else {
                        // This case should ideally not be reached if details_found is true
                        Print("ERROR: OnTradeTransaction - removal_index was not set despite details_found being true. Cannot clean up parallel arrays for PosID ", (long)closing_deal_position_id);
                    }
                } else {
                    PrintFormat("DEBUG_HEDGE_CLOSURE: ERROR - Cannot send notification for PosID %d (found in parallel arrays) due to invalid deal details. Volume: %f, Action: %s. Arrays not cleaned.", (long)closing_deal_position_id, notification_deal_volume, notification_hedge_action);
                }
            } else {
                Print("ERROR: Could not find details in parallel arrays for closed PosID ", (long)closing_deal_position_id, ". Notification not sent, arrays not cleaned.");
            }
            // --- END HEDGE CLOSURE NOTIFICATION LOGIC (using parallel arrays) ---

            // Parameters for HandleACAdjustmentOnHedgeClosure (existing logic, uses base_id_for_prefix from old map g_map_position_id_to_base_id and g_baseIds array)
            ulong ac_closing_deal_ticket = trans.deal; // Can re-use trans.deal or use notify_closing_deal_ticket
            double ac_closing_deal_volume = 0;
            double ac_closing_deal_price = 0; // Not used by HandleACAdjustmentOnHedgeClosure
            string nt_instrument_symbol_for_ac = "";
            string nt_account_name_for_ac = "";
            int groupIndex = -1; // To find active NT details for AC

            for(int i = 0; i < ArraySize(g_baseIds); i++)
            {
                // This loop specifically looks for an *active* (not complete) trade group for AC
                if(g_baseIds[i] == base_id_for_prefix && (i < ArraySize(g_isComplete) && !g_isComplete[i]))
                {
                    groupIndex = i;
                    if(groupIndex < ArraySize(g_ntInstrumentSymbols)) nt_instrument_symbol_for_ac = g_ntInstrumentSymbols[groupIndex];
                    if(groupIndex < ArraySize(g_ntAccountNames)) nt_account_name_for_ac = g_ntAccountNames[groupIndex];
                    break;
                }
            }

            if(groupIndex != -1)
            {
                Print("DEBUG_HEDGE_CLOSURE: Found trade group for base_id '", base_id_for_prefix, "' at index ", groupIndex,
                      ". NT Symbol: '", nt_instrument_symbol_for_ac, "', NT Account: '", nt_account_name_for_ac, "'");
                
                // Send notification (existing logic can be adapted or used if SendHedgeCloseNotification is suitable)
                string notification_message = "Hedge position for " + base_id_for_prefix +
                                              " (" + nt_instrument_symbol_for_ac + ", " + nt_account_name_for_ac + ")" +
                                              " on MT5 PositionID " + (string)closing_deal_position_id + " has been closed.";
                Print(notification_message);

                if(nt_instrument_symbol_for_ac == "" || nt_account_name_for_ac == "") {
                     Print("ERROR: Could not find TradeGroup details (NT Symbol/Account) for base_id '", base_id_for_prefix, "' for AC Adjustment. Skipping HandleACAdjustmentOnHedgeClosure.");
                } else {
                    // Declare variables for closing deal details that were previously undeclared.
                    // These are needed to fetch information about the deal that closed the hedge position.
                    ulong  closing_deal_ticket;
                    double closing_deal_volume;
                    double closing_deal_price;

                    // Obtain the deal ticket from the 'trans' object (type MqlTradeTransaction),
                    // which is assumed to be an argument to the OnTradeTransaction event handler.
                    // The 'trans.deal' property provides the ticket of the deal associated with this transaction.
                    closing_deal_ticket = trans.deal; // 'trans' is the MqlTradeTransaction object

                    // Proceed only if a valid deal ticket was obtained from the transaction.
                    if(closing_deal_ticket > 0 && HistoryDealSelect(closing_deal_ticket)) {
                        // Assign values to the now-declared variables
                        closing_deal_volume = HistoryDealGetDouble(closing_deal_ticket, DEAL_VOLUME);
                        closing_deal_price = HistoryDealGetDouble(closing_deal_ticket, DEAL_PRICE); // Price is still useful for logging or other logic
                        double deal_pnl = HistoryDealGetDouble(closing_deal_ticket, DEAL_PROFIT);
                        
                        if(UseACRiskManagement)
                        {
                           HandleACAdjustmentOnHedgeClosure(base_id_for_prefix, closing_deal_volume, deal_pnl); // Pass actual PnL
                           Print("DEBUG_HEDGE_CLOSURE: Called HandleACAdjustmentOnHedgeClosure for PositionID ", closing_deal_position_id, " with PnL: ", deal_pnl);
                        }
                    } else {
                        // Log an error if the deal ticket is invalid or the deal cannot be selected.
                        if (closing_deal_ticket == 0) {
                             PrintFormat("ERROR: Failed to get a valid closing_deal_ticket from transaction for PositionID %s, base_id '%s'. AC adjustment cannot proceed.", (string)closing_deal_position_id, base_id_for_prefix);
                        } else {
                             PrintFormat("ERROR: Could not select closing deal #%s (for PositionID: %s, base_id: '%s') to get volume/price for AC adjustment. Error code: %d",
                                        (string)closing_deal_ticket, (string)closing_deal_position_id, base_id_for_prefix, GetLastError());
                        }
                    }
                }
                // Mark the trade group as complete
                g_isComplete[groupIndex] = true;
                Print("DEBUG_HEDGE_CLOSURE: Marked trade group at index ", groupIndex, " (base_id: ", base_id_for_prefix, ") as complete.");
            }
            else
            {
                Print("DEBUG_HEDGE_CLOSURE: Could not find active trade group for base_id '", base_id_for_prefix, "' (from PositionID ", closing_deal_position_id, "). Cannot complete AC adjustment or mark group complete.");
            }
        }
        // If !is_position_closed, the deal was a partial close or the position is still open for other reasons.
        // No specific action for this case based on the prompt's focus on full closure.
    }
    else
    {
        Print("DEBUG_HEDGE_CLOSURE: Deal ", deal_ticket, " (Entry: ", EnumToString(deal_entry),
              ") is not a closing type (DEAL_ENTRY_OUT or DEAL_ENTRY_INOUT). Skipping hedge closure notification logic.");
    }
}

// Make sure to include ACFunctions.mqh if it's not already. It is on line 7.
// Make sure to include Trade.mqh if it's not already. It is on line 10.

//+------------------------------------------------------------------+
//| Counts open hedge positions for a specific base_id and MT5 action|
//+------------------------------------------------------------------+
int CountHedgePositionsForBaseId(string baseIdToCount, string mt5HedgeAction)
{
   int count = 0;
   // Construct the specific comment we're looking for.
   // OpenNewHedgeOrder uses: StringFormat("%s%s_%s", CommentPrefix, hedgeOrigin, tradeId)
   // where hedgeOrigin is the mt5HedgeAction and tradeId is the baseIdToCount.
   string specificCommentSearch = StringFormat("%s%s_%s", CommentPrefix, mt5HedgeAction, baseIdToCount);

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)   != _Symbol)     continue;
      if(PositionGetInteger(POSITION_MAGIC)   != MagicNumber) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == specificCommentSearch)
      {
         count++;
         Print("DEBUG: CountHedgePositionsForBaseId – Matched ticket ", ticket,
               " for baseId '", baseIdToCount, "' with MT5 action '", mt5HedgeAction, "'. Comment: '", comment, "'");
      }
   }
   Print("DEBUG: CountHedgePositionsForBaseId – Found ", count, " hedge(s) for baseId '", baseIdToCount,
         "' and MT5 action '", mt5HedgeAction, "' (Comment searched: '", specificCommentSearch, "')");
   return count;
}