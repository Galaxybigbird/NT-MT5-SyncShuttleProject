#property link      ""
#property version   "2.05"
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
int g_mt5HedgesOpenedCount[]; // NEW: Count of MT5 hedges opened for this group
int g_mt5HedgesClosedCount[]; // NEW: Count of MT5 hedges closed for this group
bool g_isMT5Opened[];         // NEW: Flag if MT5 hedge has been opened for this group
bool g_isMT5Closed[];         // NEW: Flag if all MT5 hedges for this group are closed

CHashMap<long, CString*> *g_map_position_id_to_base_id = NULL; // Map PositionID (long) to original base_id (CString*)
// CHashMap for PositionTradeDetails removed.
// New parallel arrays for MT5 position details will be added here.
long g_open_mt5_pos_ids[];       // Stores MT5 Position IDs
string g_open_mt5_base_ids[];    // Stores corresponding NT Base IDs
string g_open_mt5_nt_symbols[];  // Stores corresponding NT Instrument Symbols
string g_open_mt5_nt_accounts[]; // Stores corresponding NT Account Names
string g_open_mt5_actions[];     // NEW: Stores the MT5 position type ("buy" or "sell") for open positions
string g_open_mt5_original_nt_actions[];    // NEW: Stores original NT action for rehydrated open MT5 positions
int    g_open_mt5_original_nt_quantities[]; // NEW: Stores original NT quantity for rehydrated open MT5 positions

// Mutex-like mechanism to prevent concurrent array modifications
bool g_array_modification_in_progress = false;
datetime g_last_array_modification_time = 0;
const int ARRAY_MODIFICATION_TIMEOUT_SECONDS = 30; // Maximum time to wait for array modification to complete

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
    Print("ACHM_DIAG: [CleanupTradeGroups] Starting cleanup. Current g_baseIds size: ", ArraySize(g_baseIds));
    int arraySize = ArraySize(g_baseIds);
    if(arraySize == 0) return;  // Nothing to clean up

    int keepCount = 0;
    bool groupsToKeep[]; // Temp array to mark groups to keep
    if(arraySize > 0) ArrayResize(groupsToKeep, arraySize); // Resize only if arraySize > 0

    for(int i = 0; i < arraySize; i++)
    {
        bool nt_fills_complete = g_isComplete[i];
        // Ensure index is valid for new arrays before accessing
        bool mt5_hedges_opened_exist = (i < ArraySize(g_mt5HedgesOpenedCount) && g_mt5HedgesOpenedCount[i] > 0);
        bool all_mt5_hedges_closed = (i < ArraySize(g_mt5HedgesClosedCount) && i < ArraySize(g_mt5HedgesOpenedCount) &&
                                      g_mt5HedgesClosedCount[i] >= g_mt5HedgesOpenedCount[i]);

        // A group is kept if:
        // 1. NT fills are NOT YET complete OR
        // 2. NT fills ARE complete, BUT (EITHER no MT5 hedges were ever opened for it OR (MT5 hedges were opened AND NOT ALL of them are closed yet)).
        // Simplified: Keep if NT not complete, OR if NT is complete but MT5 side is not fully resolved.
        if (!nt_fills_complete || (nt_fills_complete && mt5_hedges_opened_exist && !all_mt5_hedges_closed) ) {
            groupsToKeep[i] = true;
            keepCount++;
            Print("ACHM_DIAG: [CleanupTradeGroups] KEEPING group with base_id: '", g_baseIds[i], "' at index ", i,
                  ". NT_Complete: ", nt_fills_complete,
                  ", MT5_Opened_Exist: ", mt5_hedges_opened_exist,
                  ", MT5_All_Closed: ", all_mt5_hedges_closed,
                  ", Opened: ", (i < ArraySize(g_mt5HedgesOpenedCount) ? (string)g_mt5HedgesOpenedCount[i] : "N/A"),
                  ", Closed: ", (i < ArraySize(g_mt5HedgesClosedCount) ? (string)g_mt5HedgesClosedCount[i] : "N/A"));
        } else {
            groupsToKeep[i] = false; // Mark for removal
            Print("ACHM_DIAG: [CleanupTradeGroups] Eligible for REMOVAL group with base_id: '", g_baseIds[i], "' at index ", i,
                  ". NT_Complete: ", nt_fills_complete,
                  ", MT5_Opened_Exist: ", mt5_hedges_opened_exist,
                  ", MT5_All_Closed: ", all_mt5_hedges_closed,
                  ", Opened: ", (i < ArraySize(g_mt5HedgesOpenedCount) ? (string)g_mt5HedgesOpenedCount[i] : "N/A"),
                  ", Closed: ", (i < ArraySize(g_mt5HedgesClosedCount) ? (string)g_mt5HedgesClosedCount[i] : "N/A"));
        }
    }

    if(keepCount < arraySize) // If there are groups to remove
    {
        string tempBaseIds[];
        int tempTotalQty[];
        int tempProcessedQty[];
        string tempActions[];
        bool tempComplete[];
        string tempNtSymbols[];
        string tempNtAccounts[];
        int tempMt5Opened[];
        int tempMt5Closed[];
        bool tempIsMT5Opened[];
        bool tempIsMT5Closed[];

        if(keepCount > 0)
        {
            ArrayResize(tempBaseIds, keepCount);
            ArrayResize(tempTotalQty, keepCount);
            ArrayResize(tempProcessedQty, keepCount);
            ArrayResize(tempActions, keepCount);
            ArrayResize(tempComplete, keepCount);
            ArrayResize(tempNtSymbols, keepCount);
            ArrayResize(tempNtAccounts, keepCount);
            ArrayResize(tempMt5Opened, keepCount);
            ArrayResize(tempMt5Closed, keepCount);
            ArrayResize(tempIsMT5Opened, keepCount);
            ArrayResize(tempIsMT5Closed, keepCount);

            int newIndex = 0;
            for(int i = 0; i < arraySize; i++)
            {
                if(groupsToKeep[i]) // If marked to keep
                {
                    tempBaseIds[newIndex] = g_baseIds[i];
                    tempTotalQty[newIndex] = g_totalQuantities[i];
                    tempProcessedQty[newIndex] = g_processedQuantities[i];
                    tempActions[newIndex] = g_actions[i];
                    tempComplete[newIndex] = g_isComplete[i];
                    if (i < ArraySize(g_ntInstrumentSymbols)) tempNtSymbols[newIndex] = g_ntInstrumentSymbols[i]; else tempNtSymbols[newIndex] = "";
                    if (i < ArraySize(g_ntAccountNames)) tempNtAccounts[newIndex] = g_ntAccountNames[i]; else tempNtAccounts[newIndex] = "";
                    if (i < ArraySize(g_mt5HedgesOpenedCount)) tempMt5Opened[newIndex] = g_mt5HedgesOpenedCount[i]; else tempMt5Opened[newIndex] = 0;
                    if (i < ArraySize(g_mt5HedgesClosedCount)) tempMt5Closed[newIndex] = g_mt5HedgesClosedCount[i]; else tempMt5Closed[newIndex] = 0;
                    if (i < ArraySize(g_isMT5Opened)) tempIsMT5Opened[newIndex] = g_isMT5Opened[i]; else tempIsMT5Opened[newIndex] = false; // Default to false if out of bounds
                    if (i < ArraySize(g_isMT5Closed)) tempIsMT5Closed[newIndex] = g_isMT5Closed[i]; else tempIsMT5Closed[newIndex] = false; // Default to false if out of bounds
                    newIndex++;
                } else {
                     // This log was already printed above when eligibility was determined
                    // Print("ACHM_DIAG: [CleanupTradeGroups] Removing group with base_id: '", g_baseIds[i], "' at index ", i);
                }
            }
        }

        ArrayFree(g_baseIds);
        ArrayFree(g_totalQuantities);
        ArrayFree(g_processedQuantities);
        ArrayFree(g_actions);
        ArrayFree(g_isComplete);
        ArrayFree(g_ntInstrumentSymbols);
        ArrayFree(g_ntAccountNames);
        ArrayFree(g_mt5HedgesOpenedCount);
        ArrayFree(g_mt5HedgesClosedCount);
        ArrayFree(g_isMT5Opened);
        ArrayFree(g_isMT5Closed);

        if(keepCount > 0)
        {
            ArrayCopy(g_baseIds, tempBaseIds);
            ArrayCopy(g_totalQuantities, tempTotalQty);
            ArrayCopy(g_processedQuantities, tempProcessedQty);
            ArrayCopy(g_actions, tempActions);
            ArrayCopy(g_isComplete, tempComplete);
            ArrayCopy(g_ntInstrumentSymbols, tempNtSymbols);
            ArrayCopy(g_ntAccountNames, tempNtAccounts);
            ArrayCopy(g_mt5HedgesOpenedCount, tempMt5Opened);
            ArrayCopy(g_mt5HedgesClosedCount, tempMt5Closed);
            ArrayCopy(g_isMT5Opened, tempIsMT5Opened);
            ArrayCopy(g_isMT5Closed, tempIsMT5Closed);
        }
        else // No groups to keep, so resize all to 0
        {
            ArrayResize(g_baseIds, 0);
            ArrayResize(g_totalQuantities, 0);
            ArrayResize(g_processedQuantities, 0);
            ArrayResize(g_actions, 0);
            ArrayResize(g_isComplete, 0);
            ArrayResize(g_ntInstrumentSymbols, 0);
            ArrayResize(g_ntAccountNames, 0);
            ArrayResize(g_mt5HedgesOpenedCount, 0);
            ArrayResize(g_mt5HedgesClosedCount, 0);
            ArrayResize(g_isMT5Opened, 0);
            ArrayResize(g_isMT5Closed, 0);
        }
    } else {
         Print("ACHM_DIAG: [CleanupTradeGroups] No groups eligible for removal based on new criteria. Current count: ", arraySize);
    }
    if(arraySize > 0) ArrayFree(groupsToKeep); // Free the temporary boolean array
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
    ArrayResize(g_mt5HedgesOpenedCount, 0); // NEW: Reset MT5 opened hedges count array
    ArrayResize(g_mt5HedgesClosedCount, 0); // NEW: Reset MT5 closed hedges count array
    ArrayResize(g_isMT5Opened, 0);          // NEW: Reset MT5 opened flag array
    ArrayResize(g_isMT5Closed, 0);          // NEW: Reset MT5 closed flag array
    globalFutures = 0.0;  // Reset global futures counter
    g_highWaterEOD  = 0.0;      // <<< NEW – restart trailing‑dd calc
    Print("ACHM_DIAG: [ResetTradeGroups] Trade groups reset complete. Global futures: ", globalFutures);
}

//+------------------------------------------------------------------+
//| Removes a specific trade group by index from all tracking arrays |
//+------------------------------------------------------------------+
void FinalizeAndRemoveTradeGroup(int remove_idx)
{
    int arraySize = ArraySize(g_baseIds);
    if(remove_idx < 0 || remove_idx >= arraySize)
    {
        Print("ACHM_ERROR: [FinalizeAndRemoveTradeGroup] Invalid index ", remove_idx, " for removal. Array size: ", arraySize);
        return;
    }

    Print("ACHM_LOG: [FinalizeAndRemoveTradeGroup] Removing trade group at index ", remove_idx, " with base_id: '", (remove_idx < ArraySize(g_baseIds) ? g_baseIds[remove_idx] : "N/A_OOB"), "'. Current array size: ", arraySize);

    // Create temporary arrays for all but the element to remove
    int newSize = arraySize - 1;
    if (newSize < 0) newSize = 0;

    string tempBaseIds[];
    int    tempTotalQuantities[];
    int    tempProcessedQuantities[];
    string tempActions[];
    bool   tempIsComplete[];
    string tempNtInstrumentSymbols[];
    string tempNtAccountNames[];
    int    tempMt5HedgesOpenedCount[];
    int    tempMt5HedgesClosedCount[];
    bool   tempIsMT5Opened[];
    bool   tempIsMT5Closed[];

    if (newSize > 0)
    {
        ArrayResize(tempBaseIds, newSize);
        ArrayResize(tempTotalQuantities, newSize);
        ArrayResize(tempProcessedQuantities, newSize);
        ArrayResize(tempActions, newSize);
        ArrayResize(tempIsComplete, newSize);
        ArrayResize(tempNtInstrumentSymbols, newSize);
        ArrayResize(tempNtAccountNames, newSize);
        ArrayResize(tempMt5HedgesOpenedCount, newSize);
        ArrayResize(tempMt5HedgesClosedCount, newSize);
        ArrayResize(tempIsMT5Opened, newSize);
        ArrayResize(tempIsMT5Closed, newSize);
    }

    int current_temp_idx = 0;
    for(int i = 0; i < arraySize; i++)
    {
        if(i == remove_idx)
        {
            // Skip the element to be removed
            continue;
        }
        if (current_temp_idx < newSize) // Boundary check for temp arrays
        {
            if (i < ArraySize(g_baseIds)) tempBaseIds[current_temp_idx] = g_baseIds[i]; else tempBaseIds[current_temp_idx] = "";
            if (i < ArraySize(g_totalQuantities)) tempTotalQuantities[current_temp_idx] = g_totalQuantities[i]; else tempTotalQuantities[current_temp_idx] = 0;
            if (i < ArraySize(g_processedQuantities)) tempProcessedQuantities[current_temp_idx] = g_processedQuantities[i]; else tempProcessedQuantities[current_temp_idx] = 0;
            if (i < ArraySize(g_actions)) tempActions[current_temp_idx] = g_actions[i]; else tempActions[current_temp_idx] = "";
            if (i < ArraySize(g_isComplete)) tempIsComplete[current_temp_idx] = g_isComplete[i]; else tempIsComplete[current_temp_idx] = false;
            if (i < ArraySize(g_ntInstrumentSymbols)) tempNtInstrumentSymbols[current_temp_idx] = g_ntInstrumentSymbols[i]; else tempNtInstrumentSymbols[current_temp_idx] = "";
            if (i < ArraySize(g_ntAccountNames)) tempNtAccountNames[current_temp_idx] = g_ntAccountNames[i]; else tempNtAccountNames[current_temp_idx] = "";
            if (i < ArraySize(g_mt5HedgesOpenedCount)) tempMt5HedgesOpenedCount[current_temp_idx] = g_mt5HedgesOpenedCount[i]; else tempMt5HedgesOpenedCount[current_temp_idx] = 0;
            if (i < ArraySize(g_mt5HedgesClosedCount)) tempMt5HedgesClosedCount[current_temp_idx] = g_mt5HedgesClosedCount[i]; else tempMt5HedgesClosedCount[current_temp_idx] = 0;
            if (i < ArraySize(g_isMT5Opened)) tempIsMT5Opened[current_temp_idx] = g_isMT5Opened[i]; else tempIsMT5Opened[current_temp_idx] = false;
            if (i < ArraySize(g_isMT5Closed)) tempIsMT5Closed[current_temp_idx] = g_isMT5Closed[i]; else tempIsMT5Closed[current_temp_idx] = false;
            current_temp_idx++;
        } else if (newSize > 0) {
             Print("ACHM_ERROR: [FinalizeAndRemoveTradeGroup] current_temp_idx ", current_temp_idx, " exceeded newSize ", newSize, " during copy.");
        }
    }

    // Free old arrays
    ArrayFree(g_baseIds);
    ArrayFree(g_totalQuantities);
    ArrayFree(g_processedQuantities);
    ArrayFree(g_actions);
    ArrayFree(g_isComplete);
    ArrayFree(g_ntInstrumentSymbols);
    ArrayFree(g_ntAccountNames);
    ArrayFree(g_mt5HedgesOpenedCount);
    ArrayFree(g_mt5HedgesClosedCount);
    ArrayFree(g_isMT5Opened);
    ArrayFree(g_isMT5Closed);

    // Copy from temp arrays or resize to 0 if newSize is 0
    if (newSize > 0)
    {
        ArrayCopy(g_baseIds, tempBaseIds);
        ArrayCopy(g_totalQuantities, tempTotalQuantities);
        ArrayCopy(g_processedQuantities, tempProcessedQuantities);
        ArrayCopy(g_actions, tempActions);
        ArrayCopy(g_isComplete, tempIsComplete);
        ArrayCopy(g_ntInstrumentSymbols, tempNtInstrumentSymbols);
        ArrayCopy(g_ntAccountNames, tempNtAccountNames);
        ArrayCopy(g_mt5HedgesOpenedCount, tempMt5HedgesOpenedCount);
        ArrayCopy(g_mt5HedgesClosedCount, tempMt5HedgesClosedCount);
        ArrayCopy(g_isMT5Opened, tempIsMT5Opened);
        ArrayCopy(g_isMT5Closed, tempIsMT5Closed);

        ArrayFree(tempBaseIds);
        ArrayFree(tempTotalQuantities);
        ArrayFree(tempProcessedQuantities);
        ArrayFree(tempActions);
        ArrayFree(tempIsComplete);
        ArrayFree(tempNtInstrumentSymbols);
        ArrayFree(tempNtAccountNames);
        ArrayFree(tempMt5HedgesOpenedCount);
        ArrayFree(tempMt5HedgesClosedCount);
        ArrayFree(tempIsMT5Opened);
        ArrayFree(tempIsMT5Closed);
    }
    else
    {
        ArrayResize(g_baseIds, 0);
        ArrayResize(g_totalQuantities, 0);
        ArrayResize(g_processedQuantities, 0);
        ArrayResize(g_actions, 0);
        ArrayResize(g_isComplete, 0);
        ArrayResize(g_ntInstrumentSymbols, 0);
        ArrayResize(g_ntAccountNames, 0);
        ArrayResize(g_mt5HedgesOpenedCount, 0);
        ArrayResize(g_mt5HedgesClosedCount, 0);
        ArrayResize(g_isMT5Opened, 0);
        ArrayResize(g_isMT5Closed, 0);
    }
    Print("ACHM_LOG: [FinalizeAndRemoveTradeGroup] Trade group removal complete. New array size: ", ArraySize(g_baseIds));
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
                                datetime timestamp_dt, // Expects datetime
                                string closure_reason) // NEW: Reason for closure
{
    string timestamp_str = FormatUTCTimestamp(timestamp_dt); // Format internally

    string payload = "{";
    payload += "\"event_type\":\"hedge_close_notification\","; // Moved event_type up for clarity
    payload += "\"base_id\":\"" + base_id + "\",";
    payload += "\"nt_instrument_symbol\":\"" + nt_instrument_symbol + "\",";
    payload += "\"nt_account_name\":\"" + nt_account_name + "\",";
    // Ensure proper formatting for double, considering symbol's digits for volume
    // SymbolInfoInteger returns long, DoubleToString expects int for digits.
    // This conversion is safe as symbol digits will not exceed int max.
    payload += "\"closed_hedge_quantity\":" + DoubleToString(closed_hedge_quantity, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) + ",";
    payload += "\"closed_hedge_action\":\"" + closed_hedge_action + "\",";
    payload += "\"timestamp\":\"" + timestamp_str + "\",";
    payload += "\"closure_reason\":\"" + closure_reason + "\""; // Added closure_reason
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
   // Also initialize new g_open_mt5_ parallel arrays
   ArrayResize(g_open_mt5_original_nt_actions, 0);
   ArrayResize(g_open_mt5_original_nt_quantities, 0);

   // Initialize the asymmetrical compounding risk management (reads inputs from ACFunctions.mqh)
   InitializeACRiskManagement(); // This also initializes currentRisk, etc.
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
      Print("=================================");
      Print("✓ Bridge server connection test passed (Status Code: ", health_check_result, ")");
      g_bridgeConnected = true;
      g_loggedDisconnect = false; // Ensure logged flag is reset on success
      UpdateStatusIndicator("Connected", clrGreen); // Update indicator
   }

   // --- STATE RECOVERY LOGIC ---
   Print("ACHM_RECOVERY: Starting state recovery for existing MT5 positions...");
   int total_positions = PositionsTotal();
   int rehydrated_count = 0;
   double recovered_global_futures_adjustment = 0.0;

   for(int i = 0; i < total_positions; i++) {
       ulong mt5_ticket = PositionGetTicket(i);
       if(mt5_ticket == 0) continue;
       if(!PositionSelectByTicket(mt5_ticket)) continue;

       if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
           string comment = PositionGetString(POSITION_COMMENT);
           long mt5_pos_id = (long)PositionGetInteger(POSITION_IDENTIFIER); // Same as mt5_ticket for MT5 positions
           ENUM_POSITION_TYPE mt5_pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
           double mt5_pos_volume = PositionGetDouble(POSITION_VOLUME);

           Print("ACHM_RECOVERY: Checking EA position. Ticket: ", mt5_ticket, ", Comment: '", comment, "', Type: ", EnumToString(mt5_pos_type), ", Vol: ", mt5_pos_volume);

           // Parse comment: "AC_HEDGE;BID:{base_id};NTA:{NT_ACTION};NTQ:{NT_QTY};MTA:{MT5_ACTION}"
           string base_id_str = ExtractBaseIdFromComment(comment);

           if (base_id_str != "") {
               Print("ACHM_RECOVERY: Extracted BaseID='", base_id_str, "' from comment '", comment, "' for PosID ", mt5_pos_id);

               // 1. Re-populate g_map_position_id_to_base_id (Primary Goal)
               if(CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) {
                   CString *s_base_id_obj = new CString();
                   s_base_id_obj.Assign(base_id_str);
                   if(!g_map_position_id_to_base_id.Add(mt5_pos_id, s_base_id_obj)) {
                       Print("ACHM_RECOVERY_ERROR: Failed to add to g_map_position_id_to_base_id for PosID ", mt5_pos_id, " with base_id '", base_id_str, "'");
                       delete s_base_id_obj;
                   } else {
                        Print("ACHM_RECOVERY: Re-mapped g_map_position_id_to_base_id: MT5 PosID ", mt5_pos_id, " -> base_id '", base_id_str, "'");
                   }
               }

               // Attempt to parse other parts for more complete rehydration
               string nt_action_str = "";
               int nt_qty_val = 0;
               string mt5_action_str = ""; // This is the MT5 hedge's action (Buy/Sell)

               string parts[];
               int num_parts = StringSplit(comment, ';', parts);

               if (num_parts > 0 && parts[0] == "AC_HEDGE") {
                   // NTA:{NT_ACTION} - Original NT Action (parts[2])
                   if (num_parts > 2 && StringFind(parts[2], "NTA:", 0) == 0) {
                       string nta_part[]; StringSplit(parts[2], ':', nta_part);
                       if(ArraySize(nta_part) == 2) nt_action_str = nta_part[1];
                   }
                   // NTQ:{NT_QTY} - Original NT Quantity (parts[3])
                   if (num_parts > 3 && StringFind(parts[3], "NTQ:", 0) == 0) {
                       string ntq_part[]; StringSplit(parts[3], ':', ntq_part);
                       if(ArraySize(ntq_part) == 2) nt_qty_val = (int)StringToInteger(ntq_part[1]);
                   }
                   // MTA:{MT5_ACTION} - MT5 Hedge Action (parts[4])
                   if (num_parts > 4 && StringFind(parts[4], "MTA:", 0) == 0) {
                       string mta_part[]; StringSplit(parts[4], ':', mta_part);
                       if(ArraySize(mta_part) == 2) mt5_action_str = mta_part[1];
                   }
                   Print("ACHM_RECOVERY: Attempted parsing NTA/NTQ/MTA from '", comment, "': NT_Action='", nt_action_str, "', NT_Qty=", nt_qty_val, ", MT5_Action='", mt5_action_str, "'");
               } else {
                   Print("ACHM_RECOVERY_INFO: Comment '", comment, "' for PosID ", mt5_pos_id, " did not start with AC_HEDGE or was too short for full NTA/NTQ/MTA parsing after splitting by ';'. BaseID '", base_id_str, "' was still extracted.");
               }

               // Proceed with full rehydration if all essential parts were parsed
               if(nt_action_str != "" && nt_qty_val > 0 && mt5_action_str != "") {
                   Print("ACHM_RECOVERY: All parts parsed for full rehydration. Ticket ", mt5_ticket, ": BaseID='", base_id_str, "', NT_Action='", nt_action_str, "', NT_Qty=", nt_qty_val, ", MT5_Action='", mt5_action_str, "'");

                   // 2. Re-create Trade Group Entry
                   int group_idx = -1;
                   for(int k=0; k < ArraySize(g_baseIds); k++) {
                       if(g_baseIds[k] == base_id_str) {
                           group_idx = k;
                           Print("ACHM_RECOVERY: Found existing (potentially incomplete) trade group for base_id '", base_id_str, "' at index ", group_idx);
                           break;
                       }
                   }
                   if(group_idx == -1) { // Create new if not found
                       group_idx = ArraySize(g_baseIds);
                       ArrayResize(g_baseIds, group_idx + 1);
                       ArrayResize(g_totalQuantities, group_idx + 1);
                       ArrayResize(g_processedQuantities, group_idx + 1);
                       ArrayResize(g_actions, group_idx + 1);
                       ArrayResize(g_isComplete, group_idx + 1);
                       ArrayResize(g_ntInstrumentSymbols, group_idx + 1);
                       ArrayResize(g_ntAccountNames, group_idx + 1);
                       ArrayResize(g_mt5HedgesOpenedCount, group_idx + 1);
                       ArrayResize(g_mt5HedgesClosedCount, group_idx + 1);
                       ArrayResize(g_isMT5Opened, group_idx + 1);
                       ArrayResize(g_isMT5Closed, group_idx + 1);
                       Print("ACHM_RECOVERY: Creating new trade group for rehydrated base_id '", base_id_str, "' at index ", group_idx);
                   }

                   g_baseIds[group_idx] = base_id_str;
                   g_actions[group_idx] = nt_action_str;
                   g_totalQuantities[group_idx] = nt_qty_val;
                   g_processedQuantities[group_idx] = nt_qty_val;
                   g_isComplete[group_idx] = true;
                   
                   g_mt5HedgesOpenedCount[group_idx] = 1;
                   g_mt5HedgesClosedCount[group_idx] = 0;
                   g_isMT5Opened[group_idx] = true;
                   g_isMT5Closed[group_idx] = false;
                   
                   g_ntInstrumentSymbols[group_idx] = PositionGetString(POSITION_SYMBOL);
                   g_ntAccountNames[group_idx] = AccountInfoString(ACCOUNT_NAME);

                   // 3. Re-populate g_open_mt5_pos_ids and parallel arrays
                   int open_mt5_idx = ArraySize(g_open_mt5_pos_ids);
                   ArrayResize(g_open_mt5_pos_ids, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_base_ids, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_nt_symbols, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_nt_accounts, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_original_nt_actions, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_original_nt_quantities, open_mt5_idx + 1);
                   ArrayResize(g_open_mt5_actions, open_mt5_idx + 1); // <<< ADDED FOR MT5 ACTION RECOVERY

                   g_open_mt5_pos_ids[open_mt5_idx] = mt5_pos_id;
                   g_open_mt5_base_ids[open_mt5_idx] = base_id_str;
                   g_open_mt5_nt_symbols[open_mt5_idx] = PositionGetString(POSITION_SYMBOL);
                   g_open_mt5_nt_accounts[open_mt5_idx] = AccountInfoString(ACCOUNT_NAME);
                   g_open_mt5_original_nt_actions[open_mt5_idx] = nt_action_str;
                   g_open_mt5_original_nt_quantities[open_mt5_idx] = nt_qty_val;
                   g_open_mt5_actions[open_mt5_idx] = mt5_action_str; // <<< ADDED FOR MT5 ACTION RECOVERY
                   Print("ACHM_RECOVERY: Added to g_open_mt5_ arrays. PosID:", mt5_pos_id, " BaseID:", base_id_str, " NT_Action:'", nt_action_str, "', NT_Qty:", nt_qty_val, ", MT5_Action:'", mt5_action_str, "'"); // <<< UPDATED LOG

                   // 4. Adjust globalFutures
                   if (mt5_pos_type == POSITION_TYPE_BUY) {
                       recovered_global_futures_adjustment -= nt_qty_val;
                       Print("ACHM_RECOVERY: MT5 BUY hedge (for NT SELL) rehydrated. Adjusting globalFutures by -", nt_qty_val);
                   } else if (mt5_pos_type == POSITION_TYPE_SELL) {
                       recovered_global_futures_adjustment += nt_qty_val;
                       Print("ACHM_RECOVERY: MT5 SELL hedge (for NT BUY) rehydrated. Adjusting globalFutures by +", nt_qty_val);
                   }
                   rehydrated_count++;
                   Print("ACHM_RECOVERY: Successfully rehydrated state for MT5 PositionID ", mt5_pos_id, " (Ticket: ", mt5_ticket, ")");
               } else {
                   Print("ACHM_RECOVERY_WARN: Base_id '", base_id_str, "' extracted, but other parts (NTA/NTQ/MTA) for full rehydration are missing/invalid from comment '", comment, "'. PosID ", mt5_pos_id, " was mapped, but group/globalFutures rehydration might be incomplete for this specific position.");
               }
           } else { // base_id_str is empty
               Print("ACHM_RECOVERY_FAIL: Failed to extract a valid base_id from comment '", comment, "' for position ticket ", mt5_ticket, ". Cannot rehydrate this position's state.");
           }
       }
   }
   globalFutures += recovered_global_futures_adjustment; // Apply the total adjustment
   Print("ACHM_RECOVERY: State recovery complete. Rehydrated ", rehydrated_count, " positions. Total adjustment to globalFutures: ", recovered_global_futures_adjustment, ". New globalFutures: ", globalFutures);
   // --- END STATE RECOVERY LOGIC ---
   
   Print("=================================");
   Print("✓ HedgeReceiver EA initialized successfully");
   Print("✓ Connected to bridge server at: ", BridgeURL);
   if(UseACRiskManagement)
      Print("✓ Asymmetrical Compounding enabled with base risk: ", AC_BaseRisk, "%");
   Print("✓ Monitoring for trades...");
   Print("=================================");
   
   if(UseATRTrailing)
   {
      InitDEMAATR();
      Print("✓ DEMA-ATR trailing stop initialized");
   }
   
   InitStatusIndicator();
   Print("✓ Status indicator initialized");
   
   EventSetMillisecondTimer(200);
   g_timerCounter = 0;
   
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

   // --- Periodic Array Integrity Check (every 30 seconds) ---
   if(g_timerCounter % 30 == 0)
   {
      if(!ValidateArrayIntegrity(true)) {
         PrintFormat("CRITICAL_ARRAY_CORRUPTION: Array integrity check failed in OnTimer at counter %d", g_timerCounter);
         PrintFormat("CRITICAL_ARRAY_CORRUPTION: This indicates the array corruption bug may still be present or has occurred.");
      }
   }

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
   
   Print("ACHM_LOG: [OnTimer] Processing NT message. Base_ID='", baseIdFromJson, "', Action='", incomingNtAction, "', Qty=", incomingNtQuantity, ", TotalQtyForBaseID=", totalQtyForBaseId, ", NT_Inst='", ntInstrument, "', NT_Acc='", ntAccount, "'");

   // --- Partial Fill Aggregation Logic ---
   int groupIndex = -1;
   // Try to find an existing, active (not yet complete for hedging) group for this base_id
   for(int i = 0; i < ArraySize(g_baseIds); i++) {
       if(g_baseIds[i] == baseIdFromJson && !g_isComplete[i]) { // g_isComplete now tracks if hedging action was taken for full order
           groupIndex = i;
           Print("ACHM_LOG: [PartialFill] Found existing active group for base_id '", baseIdFromJson, "' at index ", i, ". Processed: ", g_processedQuantities[i], ", Expected: ", g_totalQuantities[i]);
           // Potentially update g_totalQuantities[i] if totalQtyForBaseId from this message is different and more up-to-date?
           // For now, assume totalQtyForBaseId from first message is authoritative for the group.
           break;
       }
   }

   if(groupIndex == -1) {
       // If no active group, check if this base_id was already completed and processed to avoid duplicate full processing.
       for(int i = 0; i < ArraySize(g_baseIds); i++) {
           if(g_baseIds[i] == baseIdFromJson && g_isComplete[i]) {
                Print("ACHM_WARN: [PartialFill] Received message for already COMPLETED and PROCESSED base_id '", baseIdFromJson, "'. Qty: ", incomingNtQuantity, ". Ignoring for globalFutures/hedge update.");
                CleanupTradeGroups(); // Still run cleanup
                return;
           }
       }
       // If truly new or a previous instance was fully cleaned up.
       groupIndex = ArraySize(g_baseIds);
       ArrayResize(g_baseIds, groupIndex + 1);
       ArrayResize(g_totalQuantities, groupIndex + 1);
       ArrayResize(g_processedQuantities, groupIndex + 1);
       ArrayResize(g_actions, groupIndex + 1);
       ArrayResize(g_isComplete, groupIndex + 1); // This flag now means "hedging action taken for full order"
       ArrayResize(g_ntInstrumentSymbols, groupIndex + 1);
       ArrayResize(g_ntAccountNames, groupIndex + 1);
       ArrayResize(g_mt5HedgesOpenedCount, groupIndex + 1);
       ArrayResize(g_mt5HedgesClosedCount, groupIndex + 1);
       ArrayResize(g_isMT5Opened, groupIndex + 1);
       ArrayResize(g_isMT5Closed, groupIndex + 1);

       g_baseIds[groupIndex] = baseIdFromJson;
       g_totalQuantities[groupIndex] = totalQtyForBaseId; // Expected total for this base_id
       g_processedQuantities[groupIndex] = 0;             // Initialize processed quantity
       g_actions[groupIndex] = incomingNtAction;          // Action from the first fill determines overall order action
       g_isComplete[groupIndex] = false;                  // Not yet processed for full hedging
       g_ntInstrumentSymbols[groupIndex] = ntInstrument;
       g_ntAccountNames[groupIndex] = ntAccount;
       g_mt5HedgesOpenedCount[groupIndex] = 0;
       g_mt5HedgesClosedCount[groupIndex] = 0;
       g_isMT5Opened[groupIndex] = false;
       g_isMT5Closed[groupIndex] = false;
       Print("ACHM_LOG: [PartialFill] Created NEW group for base_id '", baseIdFromJson, "' at index ", groupIndex, ". Expected TotalQty: ", totalQtyForBaseId, ", Action: ", incomingNtAction);
   }

   // If group was found/created and is not yet marked as fully processed for hedging
   if (groupIndex != -1 && !g_isComplete[groupIndex]) {
       g_processedQuantities[groupIndex] += (int)incomingNtQuantity;
       Print("ACHM_LOG: [PartialFill] Updated processed qty for group '", g_baseIds[groupIndex], "' by ", (int)incomingNtQuantity,
             ". New processed: ", g_processedQuantities[groupIndex], ", Expected Total: ", g_totalQuantities[groupIndex]);

       // Check if all parts of the order for this base_id have been received
       if (g_processedQuantities[groupIndex] >= g_totalQuantities[groupIndex]) {
           // Ensure total processed doesn't exceed expected due to any bridge message issues.
           if (g_processedQuantities[groupIndex] > g_totalQuantities[groupIndex]) {
               Print("ACHM_WARN: [PartialFill] Processed quantity (", g_processedQuantities[groupIndex], ") for base_id '", g_baseIds[groupIndex],
                     "' exceeds expected total (", g_totalQuantities[groupIndex], "). Clamping to expected total for hedge calculation.");
               // g_processedQuantities[groupIndex] = g_totalQuantities[groupIndex]; // Or use g_totalQuantities directly for update
           }
           
           g_isComplete[groupIndex] = true; // Mark as "hedging action to be taken / has been taken"
           Print("ACHM_LOG: [PartialFill] Order for base_id '", g_baseIds[groupIndex], "' is now COMPLETE. Processed: ", g_processedQuantities[groupIndex], ", Total: ", g_totalQuantities[groupIndex]);
           Print("ACHM_DIAG: [PartialFill] Triggering globalFutures update and hedge adjustment for COMPLETED base_id '", g_baseIds[groupIndex], "'");

           double globalFuturesBeforeNtOrder = globalFutures;
           double totalOrderQuantityForUpdate = g_totalQuantities[groupIndex]; // Use the definitive total for the order
           string orderActionForUpdate = g_actions[groupIndex]; // Use action from the group

           Print("ACHM_LOG: [OnTimerPF] Processing COMPLETED NT order. Base_ID='", g_baseIds[groupIndex], "', Action='", orderActionForUpdate, "', TotalOrderQty=", totalOrderQuantityForUpdate, ". globalFutures BEFORE this order: ", globalFuturesBeforeNtOrder);

           // Update globalFutures based on the TOTAL aggregated quantity for this completed base_id
           if(orderActionForUpdate == "Buy" || orderActionForUpdate == "BuyToCover") {
               globalFutures += totalOrderQuantityForUpdate;
           } else if(orderActionForUpdate == "Sell" || orderActionForUpdate == "SellShort") {
               globalFutures -= totalOrderQuantityForUpdate;
           }
           Print("ACHM_LOG: [OnTimerPF] globalFutures AFTER completed order '", g_baseIds[groupIndex], "': ", globalFutures, " (updated by ", (orderActionForUpdate == "Buy" || orderActionForUpdate == "BuyToCover" ? totalOrderQuantityForUpdate : -totalOrderQuantityForUpdate), ")");

           // Determine if this completed NT order was a reducing trade or flipped the sign
           bool isReducingNtOrder = false;
           if ((orderActionForUpdate == "Buy" || orderActionForUpdate == "BuyToCover") && globalFuturesBeforeNtOrder < 0 && globalFutures > globalFuturesBeforeNtOrder) {
               isReducingNtOrder = true;
           } else if ((orderActionForUpdate == "Sell" || orderActionForUpdate == "SellShort") && globalFuturesBeforeNtOrder > 0 && globalFutures < globalFuturesBeforeNtOrder) {
               isReducingNtOrder = true;
           } else if (globalFutures != 0 && globalFuturesBeforeNtOrder != 0 && MathAbs(globalFutures) < MathAbs(globalFuturesBeforeNtOrder)) {
               isReducingNtOrder = true;
           } else if (globalFutures == 0 && globalFuturesBeforeNtOrder != 0) {
               isReducingNtOrder = true;
           }
           if(isReducingNtOrder) Print("ACHM_LOG: [OnTimerPF] Completed NT order '", g_baseIds[groupIndex], "' was REDUCING globalFutures magnitude.");

           bool signFlippedByOrder = (globalFuturesBeforeNtOrder > 0 && globalFutures < 0) || (globalFuturesBeforeNtOrder < 0 && globalFutures > 0);
           if (signFlippedByOrder) {
               Print("ACHM_LOG: [OnTimerPF] Completed NT order '", g_baseIds[groupIndex], "' FLIPPED globalFutures sign. From ", globalFuturesBeforeNtOrder, " to ", globalFutures);
           }

           // If globalFutures is now zero after this completed order, close all hedges.
           if(globalFutures == 0.0) {
               Print("ACHM_LOG: [OnTimerPF] globalFutures is zero after completed order '", g_baseIds[groupIndex], "'. Closing all hedge orders.");
               bool resetHappened = CloseAllHedgeOrders();
               if (resetHappened) {
                   Print("ACHM_LOG: [OnTimerPF] ResetTradeGroups was called by CloseAllHedgeOrders. Skipping further processing for this tick to prevent array errors.");
                   return; // Exit OnTimer immediately
               }
               // The CleanupTradeGroups at the end of OnTimer will handle group removal if not returned early.
           } else {
               // --- Overall Hedge Adjustment Logic (now conditional on order completion) ---
               Print("ACHM_DIAG: [OnTimerPF] Adjusting hedges based on new globalFutures=", globalFutures, " for completed base_id '", g_baseIds[groupIndex], "'");
               // First, determine current MT5 positions for this symbol and magic number
               int currentMt5BuyPositions = 0;
               int currentMt5SellPositions = 0;
               for(int i = 0; i < PositionsTotal(); i++) {
                   if(PositionSelectByTicket(PositionGetTicket(i))) {
                       if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                           if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) currentMt5BuyPositions++;
                           else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) currentMt5SellPositions++;
                       }
                   }
               }
               Print("ACHM_LOG: [HedgeAdjustPF] Current MT5 Hedges: Buy=", currentMt5BuyPositions, ", Sell=", currentMt5SellPositions);

               // Initialize desiredNet hedges to current state. They will be adjusted based on the incremental NT trade.
               int desiredNetBuyHedges = currentMt5BuyPositions;
               int desiredNetSellHedges = currentMt5SellPositions;

               double ntTradeVolume = globalFutures - globalFuturesBeforeNtOrder; // Actual volume of the completed NT trade
               int tradeAbsQuantity = (ntTradeVolume == 0) ? 0 : (int)MathRound(MathAbs(ntTradeVolume));

               if (tradeAbsQuantity > 0) { // Only adjust if there was a non-zero NT trade
                   if (EnableHedging) {
                       if (ntTradeVolume > 0) { // NT Bought (e.g., +2 lots)
                           // NT's position became more long or less short.
                           if (globalFutures > 0) { // NT's final state is Long. MT5 target is Short.
                               desiredNetSellHedges = currentMt5SellPositions + tradeAbsQuantity;
                               desiredNetBuyHedges = 0; // Ensure no opposing long hedge
                           } else if (globalFutures < 0) { // NT's final state is still Short (but less short). MT5 target is Long (but less long).
                               desiredNetBuyHedges = currentMt5BuyPositions - tradeAbsQuantity;
                               desiredNetSellHedges = 0; // Ensure no opposing short hedge
                           }
                           // Note: if globalFutures == 0, this block is skipped due to earlier check (line 1706).
                       } else { // ntTradeVolume < 0: NT Sold (e.g., -2 lots)
                           // NT's position became more short or less long.
                           if (globalFutures < 0) { // NT's final state is Short. MT5 target is Long.
                               desiredNetBuyHedges = currentMt5BuyPositions + tradeAbsQuantity;
                               desiredNetSellHedges = 0; // Ensure no opposing short hedge
                           } else if (globalFutures > 0) { // NT's final state is still Long (but less long). MT5 target is Short (but less short).
                               desiredNetSellHedges = currentMt5SellPositions - tradeAbsQuantity;
                               desiredNetBuyHedges = 0; // Ensure no opposing long hedge
                           }
                           // Note: if globalFutures == 0, this block is skipped.
                       }
                   } else { // Copying NT's trade direction
                       if (ntTradeVolume > 0) { // NT Bought, MT5 Buys
                           desiredNetBuyHedges = currentMt5BuyPositions + tradeAbsQuantity;
                       } else { // NT Sold, MT5 Sells
                           desiredNetSellHedges = currentMt5SellPositions + tradeAbsQuantity;
                       }
                   }
               }
               
               // Ensure desired positions are not negative
               desiredNetBuyHedges = MathMax(0, desiredNetBuyHedges);
               desiredNetSellHedges = MathMax(0, desiredNetSellHedges);

               Print("ACHM_LOG: [HedgeAdjustPF] Calculated Target Hedges (after incremental adjust): Buy=", desiredNetBuyHedges, ", Sell=", desiredNetSellHedges, " (EnableHedging=", EnableHedging, ", ntTradeVolume=", ntTradeVolume, ")");
               
               // Adjust Sell Hedges
               // The existing logic for sellHedgesToAdjust and buyHedgesToAdjust will now use the incrementally adjusted desiredNet values,
               // correctly reflecting the delta needed for this specific trade.
               int sellHedgesToAdjust = desiredNetSellHedges - currentMt5SellPositions;
               if (sellHedgesToAdjust > 0) {
                   Print("ACHM_LOG: [HedgeAdjustPF] Need to OPEN ", sellHedgesToAdjust, " SELL hedges for base_id '", g_baseIds[groupIndex], "'");
                   for (int h = 0; h < sellHedgesToAdjust; h++) {
                       if (!OpenNewHedgeOrder("Sell", g_baseIds[groupIndex], g_ntInstrumentSymbols[groupIndex], g_ntAccountNames[groupIndex])) {
                           Print("ERROR: [HedgeAdjustPF] Failed to open new SELL hedge #", h+1, ". Breaking.");
                           break;
                       }
                   }
               } else if (sellHedgesToAdjust < 0) {
                   int sellHedgesToClose = MathAbs(sellHedgesToAdjust);
                   Print("ACHM_LOG: [HedgeAdjustPF] Need to CLOSE ", sellHedgesToClose, " SELL hedges.");
                   for (int h = 0; h < sellHedgesToClose; h++) {
                       if (!CloseOneHedgePosition("Sell")) { // CloseOneHedgePosition might need base_id if specific closure is required
                           Print("ERROR: [HedgeAdjustPF] Failed to close existing SELL hedge #", h+1, ". Breaking.");
                           break;
                       }
                   }
               }

               // Adjust Buy Hedges
               int buyHedgesToAdjust = desiredNetBuyHedges - currentMt5BuyPositions;
               if (buyHedgesToAdjust > 0) {
                   Print("ACHM_LOG: [HedgeAdjustPF] Need to OPEN ", buyHedgesToAdjust, " BUY hedges for base_id '", g_baseIds[groupIndex], "'");
                   for (int h = 0; h < buyHedgesToAdjust; h++) {
                       if (!OpenNewHedgeOrder("Buy", g_baseIds[groupIndex], g_ntInstrumentSymbols[groupIndex], g_ntAccountNames[groupIndex])) {
                           Print("ERROR: [HedgeAdjustPF] Failed to open new BUY hedge #", h+1, ". Breaking.");
                           break;
                       }
                   }
               } else if (buyHedgesToAdjust < 0) {
                   int buyHedgesToClose = MathAbs(buyHedgesToAdjust);
                   Print("ACHM_LOG: [HedgeAdjustPF] Need to CLOSE ", buyHedgesToClose, " BUY hedges.");
                   for (int h = 0; h < buyHedgesToClose; h++) {
                       if (!CloseOneHedgePosition("Buy")) { // CloseOneHedgePosition might need base_id
                           Print("ERROR: [HedgeAdjustPF] Failed to close existing BUY hedge #", h+1, ". Breaking.");
                           break;
                       }
                   }
               }
           }
           // "ManageTradeGroupOnNTFill()" logic from prompt:
           // The primary aspects (updating processed qty, marking complete for hedging) are handled.
           // The old block (1415-1469) had specific logic for "opening or flipping" trades.
           // If any distinct record-keeping or actions are needed for such trades *after* globalFutures/hedges are set,
           // that would be an addition here. For now, the core request is met.
           Print("ACHM_LOG: [OnTimerPF] Completed processing for fully filled order base_id '", g_baseIds[groupIndex], "'");

       } else { // Partial fill, not yet complete for this base_id
           Print("ACHM_LOG: [PartialFill] Partial fill received for base_id '", g_baseIds[groupIndex], "'. Processed: ", g_processedQuantities[groupIndex], "/", g_totalQuantities[groupIndex], ". Deferring globalFutures update and hedge adjustment.");
       }
   } else if (groupIndex != -1 && g_isComplete[groupIndex]) {
       // This case means g_isComplete was true, indicating hedging action was already taken for this base_id.
       // This could be a late/duplicate fill message after completion.
       Print("ACHM_WARN: [PartialFill] Received additional fill for base_id '", g_baseIds[groupIndex], "' which was already processed for completion. Qty: ", incomingNtQuantity, ". No further globalFutures/hedge action taken for this fill.");
   }
   // If groupIndex remained -1 (e.g., error in logic or unexpected scenario), it will just fall through.
   
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
       ulong ticket = PositionGetTicket(i); // Get ticket once
       if(ticket == 0) continue; // Skip if ticket is invalid

       if(PositionSelectByTicket(ticket))
       {
           if(PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) // Also check symbol
           {
               string orderTypeString = "";
               ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               if(positionType == POSITION_TYPE_BUY) orderTypeString = "BUY";
               else if(positionType == POSITION_TYPE_SELL) orderTypeString = "SELL";
               else continue; // Skip if not BUY or SELL

               double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
               double volume = PositionGetDouble(POSITION_VOLUME);

               // Check if trailing stop should be activated
               // Signature: bool ShouldActivateTrailing(ulong ticket, double entryPrice, double currentPrice, string orderType, double volume)
               if(ShouldActivateTrailing(ticket, entryPrice, currentPrice, orderTypeString, volume))
               {
                   // Signature: bool UpdateTrailingStop(ulong ticket, double entryPrice, string orderType)
                   UpdateTrailingStop(ticket, entryPrice, orderTypeString);
               }
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
//| Helper to extract Base ID from MT5 Position Comment              |
//| Comment format: "AC_HEDGE;BID:{base_id};NTA:..."               |
//+------------------------------------------------------------------+
string ExtractBaseIdFromComment(string comment_str)
{
    string base_id = "";
    if (comment_str == NULL || StringLen(comment_str) == 0) return "";

    string bid_marker = "BID:";
    int bid_marker_len = StringLen(bid_marker);
    int start_pos = StringFind(comment_str, bid_marker, 0);

    if(start_pos != -1)
    {
        int value_start_pos = start_pos + bid_marker_len;
        // Ensure value_start_pos is within bounds of the comment string
        if (value_start_pos < StringLen(comment_str))
        {
            int end_pos = StringFind(comment_str, ";", value_start_pos);
            if(end_pos != -1)
            {
                // Found a semicolon after BID:value
                base_id = StringSubstr(comment_str, value_start_pos, end_pos - value_start_pos);
            }
            else
            {
                // No semicolon after BID:value, take the rest of the string
                // This handles cases where the comment might be truncated after the base_id
                base_id = StringSubstr(comment_str, value_start_pos);
            }
        }
    }

    int id_len = StringLen(base_id);
    // Adjusted length check for typical UUIDs (32-36 chars), allowing some flexibility.
    // Log warnings only for comments that appear to be AC_HEDGE related to reduce noise.
    if (StringFind(comment_str, "AC_HEDGE", 0) != -1) { // Check if it's likely one of our comments
        if (id_len > 0 && (id_len < 32 || id_len > 36) && base_id != "TEST_BASE_ID_RECOVERY") { // Allow specific test IDs
             Print("ACHM_PARSE_WARN: ExtractBaseIdFromComment - Extracted base_id '", base_id, "' from '", comment_str, "' has unusual length: ", id_len);
        } else if (id_len == 0 && StringFind(comment_str, "BID:", 0) != -1) {
            // If it's an AC_HEDGE comment and contains BID: but we got no base_id, that's a specific failure.
            Print("ACHM_PARSE_FAIL: ExtractBaseIdFromComment - Failed to extract base_id from AC_HEDGE comment containing BID: '", comment_str, "'");
        }
    }
    
    return base_id;
}


//+------------------------------------------------------------------+
//| Close all hedge orders of both Buy and Sell types                  |
//+------------------------------------------------------------------+
bool CloseAllHedgeOrders() // Corresponds to CloseAllHedgeOrdersCorrected from prompt
    { // Start of CloseAllHedgeOrders body
        Print("DEBUG: Starting CORRECTED simplified closure of all hedge orders");
        bool allClosedOverall = true; // Flag to track if all closures were successful
        bool resetOccurred = false; // Flag to indicate if ResetTradeGroups was called

        // Determine reason for closure based on globalFutures status at the beginning
        string determined_closure_reason = "EA_ADJUSTMENT_CLOSE"; // Default if not specifically for globalFutures zero
        if (globalFutures == 0.0) {
            determined_closure_reason = "EA_GLOBALFUTURES_ZERO_CLOSE";
        }
        Print("DEBUG: CloseAllHedgeOrders called. Reason determined as: ", determined_closure_reason, " (globalFutures=", globalFutures, ")");

        int total_positions_to_check = PositionsTotal();
        Print("DEBUG: Found ", total_positions_to_check, " total open positions to check.");

        // Loop backward through positions
        for(int i = total_positions_to_check - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket <= 0) continue;

            if(!PositionSelectByTicket(ticket)) {
                 Print("WARN: CloseAllHedgeOrders - Could not select position by ticket ", ticket, " for pre-close checks. Skipping.");
                 continue;
            }

            string posSymbol = PositionGetString(POSITION_SYMBOL);
            long posMagic = PositionGetInteger(POSITION_MAGIC);
            string posComment = PositionGetString(POSITION_COMMENT); // Get comment before potential close
            double posVolume = PositionGetDouble(POSITION_VOLUME);   // Get volume before potential close
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE); // Get type before potential close


            if(posSymbol == "" || posMagic == 0)
            {
                 Print("DEBUG: Skipping position with invalid data - Ticket: ", ticket);
                 continue;
            }

            if(posSymbol == _Symbol && posMagic == MagicNumber)
            {
                Print("DEBUG: Found matching position. Attempting to close ticket: ", ticket, ", Symbol: ", posSymbol, ", Magic: ", posMagic, ", Comment: '", posComment, "'");
                
                if(!trade.PositionClose(ticket, Slippage))
                {
                    Print("ERROR: Failed to close position ticket: ", ticket, ". Result Code: ", trade.ResultRetcode(), ", Comment: ", trade.ResultComment());
                    allClosedOverall = false;
                }
                else
                {
                    Print("DEBUG: Successfully closed position ticket: ", ticket, ". Result Code: ", trade.ResultRetcode(), ", Comment: ", trade.ResultComment());
                    // Position is closed, now send notification
                    string base_id_closed = ExtractBaseIdFromComment(posComment);
                    string nt_symbol_closed = "UNKNOWN";
                    string nt_account_closed = "UNKNOWN";

                    if(base_id_closed != "") {
                        // Find in parallel arrays to get NT details
                        for(int k=0; k < ArraySize(g_open_mt5_base_ids); k++) {
                            // Note: g_open_mt5_pos_ids stores the MT5 position ID. We have 'ticket' which is the MT5 pos ID.
                            // We need to find the entry that *had* this ticket.
                            // Since the position is now closed, it might have been removed from g_open_mt5_pos_ids by OnTradeTransaction already.
                            // The comment's base_id is more reliable here if OnTradeTransaction hasn't processed it yet.
                            // Let's search g_open_mt5_base_ids for base_id_closed.
                            if (k < ArraySize(g_open_mt5_base_ids) && g_open_mt5_base_ids[k] == base_id_closed) {
                                 // Check if this slot in parallel arrays still corresponds to the *ticket* we just closed.
                                 // This is tricky because OnTradeTransaction might have already removed it.
                                 // For now, if base_id matches, we'll use the NT details from that slot.
                                 // A more robust way would be if OpenNewHedgeOrder stored NT details directly in comment, or if
                                 // CloseAllHedgeOrders had access to the original mapping for the 'ticket'.
                                 // Given current structure, using base_id from comment to find in parallel arrays is the best bet.
                                if (k < ArraySize(g_open_mt5_nt_symbols)) nt_symbol_closed = g_open_mt5_nt_symbols[k];
                                if (k < ArraySize(g_open_mt5_nt_accounts)) nt_account_closed = g_open_mt5_nt_accounts[k];
                                Print("DEBUG: CloseAllHedgeOrders - Found NT details for base_id '", base_id_closed, "' from parallel arrays: Symbol='", nt_symbol_closed, "', Account='", nt_account_closed, "'");
                                break;
                            }
                        }
                         if(nt_symbol_closed == "UNKNOWN") Print("WARN: CloseAllHedgeOrders - Could not find NT Symbol/Account in parallel arrays for base_id '", base_id_closed, "' from closed position comment '", posComment, "'. Using UNKNOWN.");
                    } else {
                        Print("WARN: CloseAllHedgeOrders - Could not extract base_id from comment '", posComment, "' for notification.");
                    }

                    string closed_hedge_action_str = (posType == POSITION_TYPE_BUY) ? "buy" : "sell"; // Action of the position that was closed

                    if(base_id_closed != "") { // Only send if we have a base_id
                        Print("DEBUG: CloseAllHedgeOrders - Sending notification for closed ticket ", ticket, " (BaseID: ", base_id_closed, ") with reason: ", determined_closure_reason);
                        SendHedgeCloseNotification(base_id_closed,
                                                   nt_symbol_closed,
                                                   nt_account_closed,
                                                   posVolume, // Volume of the position that was closed
                                                   closed_hedge_action_str, // The action that closed it
                                                   TimeCurrent(),
                                                   determined_closure_reason);
                    } else {
                        Print("WARN: CloseAllHedgeOrders - Notification NOT sent for closed ticket ", ticket, " because base_id could not be determined from comment '", posComment, "'.");
                    }
                }
                Sleep(250);
            }
            else
            {
                 // Optional: Log why a position was skipped
            }
        }

        Print("DEBUG: Finished CORRECTED simplified closure attempt.");

        // Check remaining positions specifically for this EA
        int remainingEaPositions = 0;
        int total = 0;
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
        if(allClosedOverall && remainingEaPositions == 0)
        {
             Print("DEBUG: All hedge orders appear closed, resetting trade groups.");
             ResetTradeGroups();
             resetOccurred = true;
        }
        else if (!allClosedOverall)
        {
             Print("WARNING: Not all hedge positions could be closed. Trade groups not reset.");
        }
         else
        {
             Print("WARNING: EA positions might still exist (", remainingEaPositions, "). Trade groups not reset.");
        }
        return resetOccurred;
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

   // Determine original NT action and quantity for the comment
   string original_nt_action_for_comment = "N/A";
   int original_nt_qty_for_comment = 0;
   int group_idx_for_comment = -1;
   for(int k=0; k < ArraySize(g_baseIds); k++) {
       if(g_baseIds[k] == tradeId) { // tradeId is base_id
           group_idx_for_comment = k;
           break;
       }
   }
   if(group_idx_for_comment != -1) {
       if(group_idx_for_comment < ArraySize(g_actions)) original_nt_action_for_comment = g_actions[group_idx_for_comment];
       if(group_idx_for_comment < ArraySize(g_totalQuantities)) original_nt_qty_for_comment = g_totalQuantities[group_idx_for_comment];
   } else {
       Print("WARN: OpenNewHedgeOrder - Could not find trade group for base_id '", tradeId, "' to create detailed comment. Using N/A.");
   }

   // Format comment: "AC_HEDGE;BID:{base_id};NTA:{NT_ACTION};NTQ:{NT_QTY}"
   // hedgeOrigin is the MT5 action (Buy/Sell)
   // original_nt_action_for_comment is the original NT action (Buy/Sell/BuyToCover/SellShort)
   // original_nt_qty_for_comment is the original NT quantity
   request.comment = StringFormat("AC_HEDGE;BID:%s;NTA:%s;NTQ:%d;MTA:%s", // Added MTA for MT5 Action
                                  tradeId,
                                  original_nt_action_for_comment,
                                  original_nt_qty_for_comment,
                                  hedgeOrigin); // hedgeOrigin is the MT5 action

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
   if(sent && deal_ticket_for_map > 0) // Check if 'sent' is true (trade.Buy/Sell succeeded)
   {
       // Increment MT5 hedges opened count for this base_id's group
       // 'tradeId' parameter in OpenNewHedgeOrder is the base_id
       int groupIdxOpen = -1;
       for(int i = 0; i < ArraySize(g_baseIds); i++) {
           if(g_baseIds[i] == tradeId) { // tradeId is the base_id here
               groupIdxOpen = i;
               break;
           }
       }
       if(groupIdxOpen != -1 && groupIdxOpen < ArraySize(g_mt5HedgesOpenedCount)) {
           g_mt5HedgesOpenedCount[groupIdxOpen]++;
           Print("ACHM_DIAG: [OpenNewHedgeOrder] Incremented g_mt5HedgesOpenedCount for base_id '", tradeId, "' (index ", groupIdxOpen, ") to ", g_mt5HedgesOpenedCount[groupIdxOpen]);
       } else {
           Print("ACHM_DIAG: [OpenNewHedgeOrder] WARNING - Could not find group for base_id '", tradeId, "' to increment g_mt5HedgesOpenedCount. ArraySize(g_baseIds): ", ArraySize(g_baseIds), ", ArraySize(g_mt5HedgesOpenedCount): ", ArraySize(g_mt5HedgesOpenedCount));
       }
   }

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
               // Validate array integrity before adding new position
               if(!ValidateArrayIntegrity()) {
                   PrintFormat("CRITICAL_ARRAY_ERROR: Array integrity check failed BEFORE adding new position. Aborting position addition.");
                   return false;
               }
               
               int current_array_size = ArraySize(g_open_mt5_pos_ids);
               PrintFormat("ARRAY_ADD: Adding new position at index %d. Current array size: %d", current_array_size, current_array_size);
               
               // Perform atomic array resizing
               ArrayResize(g_open_mt5_pos_ids, current_array_size + 1);
               ArrayResize(g_open_mt5_base_ids, current_array_size + 1);
               ArrayResize(g_open_mt5_nt_symbols, current_array_size + 1);
               ArrayResize(g_open_mt5_nt_accounts, current_array_size + 1);
               ArrayResize(g_open_mt5_actions, current_array_size + 1);
               ArrayResize(g_open_mt5_original_nt_actions, current_array_size + 1);
               ArrayResize(g_open_mt5_original_nt_quantities, current_array_size + 1);
               
               // Validate that all arrays were resized correctly
               if(ArraySize(g_open_mt5_pos_ids) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_base_ids) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_nt_symbols) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_nt_accounts) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_actions) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_original_nt_actions) != current_array_size + 1 ||
                  ArraySize(g_open_mt5_original_nt_quantities) != current_array_size + 1) {
                   
                   PrintFormat("CRITICAL_ARRAY_ERROR: Array resize failed during position addition. Expected size: %d", current_array_size + 1);
                   PrintFormat("CRITICAL_ARRAY_ERROR: Actual sizes - pos_ids=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, actions=%d, orig_actions=%d, orig_qty=%d",
                              ArraySize(g_open_mt5_pos_ids), ArraySize(g_open_mt5_base_ids), ArraySize(g_open_mt5_nt_symbols),
                              ArraySize(g_open_mt5_nt_accounts), ArraySize(g_open_mt5_actions), ArraySize(g_open_mt5_original_nt_actions),
                              ArraySize(g_open_mt5_original_nt_quantities));
                   return false;
               }

              g_open_mt5_pos_ids[current_array_size] = (long)new_mt5_position_id;
              g_open_mt5_base_ids[current_array_size] = tradeId; // 'tradeId' parameter is the base_id
              g_open_mt5_nt_symbols[current_array_size] = nt_instrument_symbol;
              g_open_mt5_nt_accounts[current_array_size] = nt_account_name;
              g_open_mt5_actions[current_array_size] = hedgeOrigin; // Store the MT5 action
              PrintFormat("DEBUG_STORE: g_open_mt5_actions size after resize for index %d: %d. Value set: '%s'", current_array_size, ArraySize(g_open_mt5_actions), g_open_mt5_actions[current_array_size]);
               
               // For new positions, the "original NT action/qty" for the g_open_mt5_ arrays
               // are sourced from the trade group this MT5 hedge belongs to.
               string original_nt_action_for_open_mt5 = "";
               int original_nt_qty_for_open_mt5 = 0;
               int group_idx_for_open_mt5 = -1;
               for(int k=0; k < ArraySize(g_baseIds); k++) {
                   if(g_baseIds[k] == tradeId) { // tradeId is base_id
                       group_idx_for_open_mt5 = k;
                       break;
                   }
               }
               if(group_idx_for_open_mt5 != -1) {
                   if(group_idx_for_open_mt5 < ArraySize(g_actions)) original_nt_action_for_open_mt5 = g_actions[group_idx_for_open_mt5];
                   if(group_idx_for_open_mt5 < ArraySize(g_totalQuantities)) original_nt_qty_for_open_mt5 = g_totalQuantities[group_idx_for_open_mt5];
               } else {
                   Print("WARN: OpenNewHedgeOrder - Could not find trade group for base_id '", tradeId, "' to populate g_open_mt5_original_nt_action/qty.");
               }
               g_open_mt5_original_nt_actions[current_array_size] = original_nt_action_for_open_mt5;
               g_open_mt5_original_nt_quantities[current_array_size] = original_nt_qty_for_open_mt5;
               
               Print("DEBUG: Stored details in parallel arrays for PosID ", (long)new_mt5_position_id, " at index ", current_array_size,
                     ". BaseID: ", tradeId, ", NT Symbol: ", nt_instrument_symbol, ", NT Account: ", nt_account_name,
                     ", MT5 Action: ", hedgeOrigin, // Added MT5 Action to log
                     ", Orig NT Action: ", original_nt_action_for_open_mt5, ", Orig NT Qty: ", original_nt_qty_for_open_mt5);
               
               // Final validation after position addition
               if(!ValidateArrayIntegrity()) {
                   PrintFormat("CRITICAL_ARRAY_ERROR: Array integrity check failed AFTER adding new position at index %d", current_array_size);
                   PrintFormat("CRITICAL_ARRAY_ERROR: This indicates the array addition process may have corrupted the arrays.");
                   return false;
               } else {
                   PrintFormat("ARRAY_ADD_SUCCESS: Position added successfully at index %d. All arrays remain synchronized.", current_array_size);
               }

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
                           Print("ACHM_DIAG: [OpenNewHedgeOrder] Mapped OLD g_map_position_id_to_base_id: MT5 PosID ", (long)new_mt5_position_id, " -> base_id '", s_base_id_obj.Str(), "'");
                       }
                   }
               } else {
                   Print("ERROR: OpenNewHedgeOrder - g_map_position_id_to_base_id (template) is not initialized. Cannot store mapping.");
               }
                Print("ACHM_DIAG: [OpenNewHedgeOrder] Mapped PARALLEL arrays: MT5 PosID ", (long)new_mt5_position_id, " -> base_id '", tradeId, "', NT Symbol: '", nt_instrument_symbol, "', NT Account: '", nt_account_name, "' at index ", current_array_size);
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
//| Safely removes an element from a string array.                   |
//| Returns true if successful, false otherwise.                     |
//+------------------------------------------------------------------+
bool SafeRemoveStringFromArray(string &arr[], int index_to_remove, string array_name_for_log)
{
    int size = ArraySize(arr);
    if (index_to_remove < 0 || index_to_remove >= size)
    {
        PrintFormat("ERROR: SafeRemoveStringFromArray - Invalid index %d for array '%s' (size %d).", index_to_remove, array_name_for_log, size);
        return false;
    }

    if (size == 1 && index_to_remove == 0) // Removing the only element
    {
        ArrayResize(arr, 0);
    }
    else
    {
        // Shift elements after the removed one
        for (int i = index_to_remove; i < size - 1; i++)
        {
            arr[i] = arr[i + 1];
        }
        if(ArrayResize(arr, size - 1) == -1)
        {
            PrintFormat("ERROR: SafeRemoveStringFromArray - ArrayResize failed for array '%s' after attempting to remove index %d.", array_name_for_log, index_to_remove);
            return false; // Resize failed, array might be in a bad state
        }
    }
    // PrintFormat("DEBUG: SafeRemoveStringFromArray - Successfully removed index %d from '%s'. New size: %d", index_to_remove, array_name_for_log, ArraySize(arr));
    return true;
}

//+------------------------------------------------------------------+
//| Remove an element from all parallel MT5 position tracking arrays |
//+------------------------------------------------------------------+
// Safer string array element removal function to prevent memory corruption
bool SafeRemoveStringArrayElement(string &array[], int index_to_remove, string array_name)
{
    int array_size = ArraySize(array);
    
    if(index_to_remove < 0 || index_to_remove >= array_size) {
        PrintFormat("SAFE_REMOVE_ERROR: Index %d out of bounds for %s (size %d)", index_to_remove, array_name, array_size);
        return false;
    }
    
    if(array_size <= 0) {
        PrintFormat("SAFE_REMOVE_ERROR: Array %s is empty (size %d)", array_name, array_size);
        return false;
    }
    
    // Element-by-element copying to avoid ArrayCopy memory corruption
    for(int i = index_to_remove; i < array_size - 1; i++) {
        array[i] = array[i + 1];
    }
    
    // Clear the last element and resize
    array[array_size - 1] = "";
    int new_size = ArrayResize(array, array_size - 1);
    
    if(new_size != array_size - 1) {
        PrintFormat("SAFE_REMOVE_ERROR: ArrayResize failed for %s. Expected size %d, got %d", array_name, array_size - 1, new_size);
        return false;
    }
    
    PrintFormat("SAFE_REMOVE_SUCCESS: Removed element at index %d from %s. New size: %d", index_to_remove, array_name, new_size);
    return true;
}

// Process all pending closures atomically to prevent array index desynchronization
void ProcessPendingClosuresBatch()
{
    int num_closures = ArraySize(g_pending_closures);
    if(num_closures == 0) {
        return; // No closures to process
    }
    
    PrintFormat("BATCH_PROCESSING: Starting atomic processing of %d pending closures", num_closures);
    
    // Validate array integrity before processing any closures
    if(!ValidateArrayIntegrity()) {
        PrintFormat("CRITICAL_BATCH_ERROR: Array integrity check failed before batch processing. Aborting to prevent further corruption.");
        ArrayResize(g_pending_closures, 0); // Clear pending closures to prevent retry
        return;
    }
    
    // --- PHASE 1: Send all notifications first (without modifying arrays) ---
    for(int i = 0; i < num_closures; i++) {
        PositionClosureData closure = g_pending_closures[i];
        
        // Determine closure reason
        string closure_reason = "UNKNOWN_MT5_CLOSE";
        if(closure.base_id != "") {
            if(closure.found_in_arrays) {
                closure_reason = "EA_PARALLEL_ARRAY_CLOSE";
            } else {
                closure_reason = "EA_COMMENT_BASED_CLOSE";
            }
        }
        
        // Send notification if we have valid data
        if(closure.base_id != "" && closure.mt5_action != "unknown" && closure.mt5_action != "" && closure.deal_volume > 0) {
            PrintFormat("BATCH_PROCESSING: Sending notification[%d] for PosID %I64u - BaseID='%s', Action='%s', Volume=%f",
                       i, closure.position_id, closure.base_id, closure.mt5_action, closure.deal_volume);
            
            SendHedgeCloseNotification(closure.base_id, closure.nt_symbol, closure.nt_account,
                                     closure.deal_volume, closure.mt5_action, TimeCurrent(), closure_reason);
        } else {
            PrintFormat("BATCH_PROCESSING: Skipping notification[%d] for PosID %I64u - Invalid data: BaseID='%s', Action='%s', Volume=%f",
                       i, closure.position_id, closure.base_id, closure.mt5_action, closure.deal_volume);
        }
    }
    
    // --- PHASE 2: Sort indices in descending order to prevent index invalidation during removal ---
    int removal_indices[];
    int removal_count = 0;
    
    for(int i = 0; i < num_closures; i++) {
        if(g_pending_closures[i].found_in_arrays && g_pending_closures[i].array_index >= 0) {
            ArrayResize(removal_indices, removal_count + 1);
            removal_indices[removal_count] = g_pending_closures[i].array_index;
            removal_count++;
        }
    }
    
    // Sort indices in descending order (highest first) to prevent index shifting issues
    for(int i = 0; i < removal_count - 1; i++) {
        for(int j = i + 1; j < removal_count; j++) {
            if(removal_indices[i] < removal_indices[j]) {
                int temp = removal_indices[i];
                removal_indices[i] = removal_indices[j];
                removal_indices[j] = temp;
            }
        }
    }
    
    PrintFormat("BATCH_PROCESSING: Sorted %d removal indices in descending order for atomic removal", removal_count);
    
    // --- PHASE 3: Remove elements from arrays in descending index order ---
    for(int i = 0; i < removal_count; i++) {
        int index_to_remove = removal_indices[i];
        PrintFormat("BATCH_PROCESSING: Removing array element at index %d (step %d of %d)", index_to_remove, i + 1, removal_count);
        RemoveFromOpenMT5Arrays(index_to_remove);
    }
    
    // --- PHASE 4: Update group counters and handle reconciliation ---
    for(int i = 0; i < num_closures; i++) {
        PositionClosureData closure = g_pending_closures[i];
        
        if(closure.base_id != "") {
            // Increment MT5 hedges closed count for this base_id's group
            int groupIdx = -1;
            for(int k = 0; k < ArraySize(g_baseIds); k++) {
                if(g_baseIds[k] == closure.base_id) {
                    groupIdx = k;
                    break;
                }
            }
            
            if(groupIdx != -1 && groupIdx < ArraySize(g_mt5HedgesClosedCount)) {
                g_mt5HedgesClosedCount[groupIdx]++;
                PrintFormat("BATCH_PROCESSING: Incremented g_mt5HedgesClosedCount for base_id '%s' (index %d) to %d",
                           closure.base_id, groupIdx, g_mt5HedgesClosedCount[groupIdx]);
                
                // Check for group reconciliation
                bool nt_fills_complete = (groupIdx < ArraySize(g_isComplete)) ? g_isComplete[groupIdx] : false;
                int opened_count = (groupIdx < ArraySize(g_mt5HedgesOpenedCount)) ? g_mt5HedgesOpenedCount[groupIdx] : 0;
                bool mt5_hedges_opened = (opened_count > 0);
                int closed_count = g_mt5HedgesClosedCount[groupIdx];
                bool all_mt5_hedges_closed = (closed_count >= opened_count);
                
                if(nt_fills_complete && mt5_hedges_opened && all_mt5_hedges_closed) {
                    PrintFormat("BATCH_PROCESSING: Trade group '%s' (index %d) is fully reconciled. Removing.", closure.base_id, groupIdx);
                    FinalizeAndRemoveTradeGroup(groupIdx);
                }
            }
        }
    }
    
    // --- PHASE 5: Final validation and cleanup ---
    if (!ValidateArrayIntegrity()) {
        PrintFormat("BATCH_PROCESSING_ERROR: Final validation failed after processing %d closures. Arrays may be corrupted.", num_closures);
    } else {
        PrintFormat("BATCH_PROCESSING_SUCCESS: Final validation passed after processing %d closures. Arrays remain synchronized.", num_closures);
    }
    
    ArrayResize(g_pending_closures, 0);
    PrintFormat("BATCH_PROCESSING: Completed atomic processing of %d closures. Cleared pending array.", num_closures);
}

// Atomic array element removal functions for different data types
// These ensure consistent behavior across all parallel arrays

bool AtomicRemoveArrayElement(string &array[], int index_to_remove, string array_name)
{
    int array_size = ArraySize(array);
    
    // Validate index bounds
    if(index_to_remove < 0 || index_to_remove >= array_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Index %d out of bounds for %s (size %d)", index_to_remove, array_name, array_size);
        return false;
    }
    
    if(array_size <= 0) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Array %s is empty (size %d)", array_name, array_size);
        return false;
    }
    
    // Create new array with reduced size
    string temp_array[];
    int new_size = array_size - 1;
    
    if(new_size > 0) {
        ArrayResize(temp_array, new_size);
        
        // Copy elements before the removal index
        for(int i = 0; i < index_to_remove; i++) {
            temp_array[i] = array[i];
        }
        
        // Copy elements after the removal index (shifted down by 1)
        for(int i = index_to_remove + 1; i < array_size; i++) {
            temp_array[i - 1] = array[i];
        }
    }
    
    // Replace original array with new array
    ArrayFree(array);
    if(new_size > 0) {
        ArrayCopy(array, temp_array);
        ArrayFree(temp_array);
    } else {
        ArrayResize(array, 0);
    }
    
    // Validate final size
    int final_size = ArraySize(array);
    if(final_size != new_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Size validation failed for %s. Expected %d, got %d", array_name, new_size, final_size);
        return false;
    }
    
    PrintFormat("ATOMIC_REMOVE_SUCCESS: Removed element at index %d from %s. New size: %d", index_to_remove, array_name, final_size);
    return true;
}

bool AtomicRemoveArrayElement(long &array[], int index_to_remove, string array_name)
{
    int array_size = ArraySize(array);
    
    // Validate index bounds
    if(index_to_remove < 0 || index_to_remove >= array_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Index %d out of bounds for %s (size %d)", index_to_remove, array_name, array_size);
        return false;
    }
    
    if(array_size <= 0) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Array %s is empty (size %d)", array_name, array_size);
        return false;
    }
    
    // Create new array with reduced size
    long temp_array[];
    int new_size = array_size - 1;
    
    if(new_size > 0) {
        ArrayResize(temp_array, new_size);
        
        // Copy elements before the removal index
        for(int i = 0; i < index_to_remove; i++) {
            temp_array[i] = array[i];
        }
        
        // Copy elements after the removal index (shifted down by 1)
        for(int i = index_to_remove + 1; i < array_size; i++) {
            temp_array[i - 1] = array[i];
        }
    }
    
    // Replace original array with new array
    ArrayFree(array);
    if(new_size > 0) {
        ArrayCopy(array, temp_array);
        ArrayFree(temp_array);
    } else {
        ArrayResize(array, 0);
    }
    
    // Validate final size
    int final_size = ArraySize(array);
    if(final_size != new_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Size validation failed for %s. Expected %d, got %d", array_name, new_size, final_size);
        return false;
    }
    
    PrintFormat("ATOMIC_REMOVE_SUCCESS: Removed element at index %d from %s. New size: %d", index_to_remove, array_name, final_size);
    return true;
}

bool AtomicRemoveArrayElement(int &array[], int index_to_remove, string array_name)
{
    int array_size = ArraySize(array);
    
    // Validate index bounds
    if(index_to_remove < 0 || index_to_remove >= array_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Index %d out of bounds for %s (size %d)", index_to_remove, array_name, array_size);
        return false;
    }
    
    if(array_size <= 0) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Array %s is empty (size %d)", array_name, array_size);
        return false;
    }
    
    // Create new array with reduced size
    int temp_array[];
    int new_size = array_size - 1;
    
    if(new_size > 0) {
        ArrayResize(temp_array, new_size);
        
        // Copy elements before the removal index
        for(int i = 0; i < index_to_remove; i++) {
            temp_array[i] = array[i];
        }
        
        // Copy elements after the removal index (shifted down by 1)
        for(int i = index_to_remove + 1; i < array_size; i++) {
            temp_array[i - 1] = array[i];
        }
    }
    
    // Replace original array with new array
    ArrayFree(array);
    if(new_size > 0) {
        ArrayCopy(array, temp_array);
        ArrayFree(temp_array);
    } else {
        ArrayResize(array, 0);
    }
    
    // Validate final size
    int final_size = ArraySize(array);
    if(final_size != new_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Size validation failed for %s. Expected %d, got %d", array_name, new_size, final_size);
        return false;
    }
    
    PrintFormat("ATOMIC_REMOVE_SUCCESS: Removed element at index %d from %s. New size: %d", index_to_remove, array_name, final_size);
    return true;
}

void RemoveFromOpenMT5Arrays(int index_to_remove)
{
    // === CONCURRENT ACCESS PROTECTION ===
    // Check if another modification is in progress
    if(g_array_modification_in_progress) {
        datetime current_time = TimeCurrent();
        int wait_time = (int)(current_time - g_last_array_modification_time);
        
        if(wait_time < ARRAY_MODIFICATION_TIMEOUT_SECONDS) {
            PrintFormat("ATOMIC_REMOVE_WAIT: Another array modification in progress. Waiting... (elapsed: %d seconds)", wait_time);
            return; // Exit and let the next call handle this
        } else {
            PrintFormat("ATOMIC_REMOVE_TIMEOUT: Array modification timeout exceeded (%d seconds). Forcing unlock.", wait_time);
            g_array_modification_in_progress = false; // Force unlock after timeout
        }
    }
    
    // Lock the arrays for modification
    g_array_modification_in_progress = true;
    g_last_array_modification_time = TimeCurrent();
    
    // === ATOMIC ARRAY REMOVAL IMPLEMENTATION ===
    // This function ensures ALL parallel arrays are updated atomically to prevent corruption
    
    // Get current array sizes for validation
    int pos_ids_size = ArraySize(g_open_mt5_pos_ids);
    int actions_size = ArraySize(g_open_mt5_actions);
    int base_ids_size = ArraySize(g_open_mt5_base_ids);
    int nt_symbols_size = ArraySize(g_open_mt5_nt_symbols);
    int nt_accounts_size = ArraySize(g_open_mt5_nt_accounts);
    int orig_nt_actions_size = ArraySize(g_open_mt5_original_nt_actions);
    int orig_nt_qty_size = ArraySize(g_open_mt5_original_nt_quantities);
    
    // --- ENTRY DIAGNOSTICS ---
    PrintFormat("ATOMIC_REMOVE: ENTRY - index_to_remove=%d", index_to_remove);
    PrintFormat("ATOMIC_REMOVE: BEFORE - Array sizes: pos_ids=%d, actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, orig_actions=%d, orig_qty=%d",
               pos_ids_size, actions_size, base_ids_size, nt_symbols_size, nt_accounts_size, orig_nt_actions_size, orig_nt_qty_size);
    
    // Log element being removed for tracking
    if(index_to_remove >= 0 && index_to_remove < pos_ids_size) {
        long pos_id = g_open_mt5_pos_ids[index_to_remove];
        string action = (index_to_remove < actions_size) ? g_open_mt5_actions[index_to_remove] : "OUT_OF_BOUNDS";
        string base_id = (index_to_remove < base_ids_size) ? g_open_mt5_base_ids[index_to_remove] : "OUT_OF_BOUNDS";
        PrintFormat("ATOMIC_REMOVE: Removing element[%d] - PosID=%I64d, Action='%s', BaseID='%s'",
                   index_to_remove, pos_id, action, base_id);
    }
    
    // === VALIDATION PHASE ===
    // Check if index is valid for the primary reference array
    if(index_to_remove < 0 || index_to_remove >= pos_ids_size) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Invalid index %d for primary array g_open_mt5_pos_ids (size %d). Aborting to prevent corruption.",
                   index_to_remove, pos_ids_size);
        g_array_modification_in_progress = false; // Unlock before returning
        return;
    }
    
    // Check for array size inconsistencies BEFORE attempting removal
    if(actions_size != pos_ids_size || base_ids_size != pos_ids_size ||
       nt_symbols_size != pos_ids_size || nt_accounts_size != pos_ids_size ||
       orig_nt_actions_size != pos_ids_size || orig_nt_qty_size != pos_ids_size) {
        
        PrintFormat("ATOMIC_REMOVE_ERROR: Array size mismatch detected BEFORE removal. Cannot proceed safely.");
        PrintFormat("ATOMIC_REMOVE_ERROR: Expected all arrays to have size %d, but found: actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, orig_actions=%d, orig_qty=%d",
                   pos_ids_size, actions_size, base_ids_size, nt_symbols_size, nt_accounts_size, orig_nt_actions_size, orig_nt_qty_size);
        g_array_modification_in_progress = false; // Unlock before returning
        return;
    }
    
    // === ATOMIC REMOVAL PHASE ===
    // Create backup copies of all arrays for potential rollback
    long backup_pos_ids[];
    string backup_actions[];
    string backup_base_ids[];
    string backup_nt_symbols[];
    string backup_nt_accounts[];
    string backup_orig_nt_actions[];
    int backup_orig_nt_qty[];
    
    // Copy current state for rollback capability
    ArrayCopy(backup_pos_ids, g_open_mt5_pos_ids);
    ArrayCopy(backup_actions, g_open_mt5_actions);
    ArrayCopy(backup_base_ids, g_open_mt5_base_ids);
    ArrayCopy(backup_nt_symbols, g_open_mt5_nt_symbols);
    ArrayCopy(backup_nt_accounts, g_open_mt5_nt_accounts);
    ArrayCopy(backup_orig_nt_actions, g_open_mt5_original_nt_actions);
    ArrayCopy(backup_orig_nt_qty, g_open_mt5_original_nt_quantities);
    
    bool removal_success = true;
    string failed_arrays = "";
    
    // Perform atomic removal using consistent method for ALL arrays
    if(!AtomicRemoveArrayElement(g_open_mt5_pos_ids, index_to_remove, "g_open_mt5_pos_ids")) {
        removal_success = false;
        failed_arrays += "pos_ids ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_actions, index_to_remove, "g_open_mt5_actions")) {
        removal_success = false;
        failed_arrays += "actions ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_base_ids, index_to_remove, "g_open_mt5_base_ids")) {
        removal_success = false;
        failed_arrays += "base_ids ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_nt_symbols, index_to_remove, "g_open_mt5_nt_symbols")) {
        removal_success = false;
        failed_arrays += "nt_symbols ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_nt_accounts, index_to_remove, "g_open_mt5_nt_accounts")) {
        removal_success = false;
        failed_arrays += "nt_accounts ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_original_nt_actions, index_to_remove, "g_open_mt5_original_nt_actions")) {
        removal_success = false;
        failed_arrays += "orig_nt_actions ";
    }
    
    if(!AtomicRemoveArrayElement(g_open_mt5_original_nt_quantities, index_to_remove, "g_open_mt5_original_nt_quantities")) {
        removal_success = false;
        failed_arrays += "orig_nt_qty ";
    }
    
    // === VALIDATION AND ROLLBACK PHASE ===
    if(!removal_success) {
        PrintFormat("ATOMIC_REMOVE_ERROR: Removal failed for arrays: %s. Performing rollback...", failed_arrays);
        
        // Rollback all arrays to their original state
        ArrayCopy(g_open_mt5_pos_ids, backup_pos_ids);
        ArrayCopy(g_open_mt5_actions, backup_actions);
        ArrayCopy(g_open_mt5_base_ids, backup_base_ids);
        ArrayCopy(g_open_mt5_nt_symbols, backup_nt_symbols);
        ArrayCopy(g_open_mt5_nt_accounts, backup_nt_accounts);
        ArrayCopy(g_open_mt5_original_nt_actions, backup_orig_nt_actions);
        ArrayCopy(g_open_mt5_original_nt_quantities, backup_orig_nt_qty);
        
        PrintFormat("ATOMIC_REMOVE_ERROR: Rollback completed. All arrays restored to original state.");
        g_array_modification_in_progress = false; // Unlock before returning
        return;
    }
    
    // Final validation - ensure all arrays have the same size after removal
    int final_pos_ids_size = ArraySize(g_open_mt5_pos_ids);
    int final_actions_size = ArraySize(g_open_mt5_actions);
    int final_base_ids_size = ArraySize(g_open_mt5_base_ids);
    int final_nt_symbols_size = ArraySize(g_open_mt5_nt_symbols);
    int final_nt_accounts_size = ArraySize(g_open_mt5_nt_accounts);
    int final_orig_nt_actions_size = ArraySize(g_open_mt5_original_nt_actions);
    int final_orig_nt_qty_size = ArraySize(g_open_mt5_original_nt_quantities);
    
    int expected_final_size = pos_ids_size - 1;
    
    if(final_pos_ids_size != expected_final_size || final_actions_size != expected_final_size ||
       final_base_ids_size != expected_final_size || final_nt_symbols_size != expected_final_size ||
       final_nt_accounts_size != expected_final_size || final_orig_nt_actions_size != expected_final_size ||
       final_orig_nt_qty_size != expected_final_size) {
        
        PrintFormat("ATOMIC_REMOVE_ERROR: Post-removal size validation failed. Expected all arrays to have size %d", expected_final_size);
        PrintFormat("ATOMIC_REMOVE_ERROR: Actual sizes: pos_ids=%d, actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, orig_actions=%d, orig_qty=%d",
                   final_pos_ids_size, final_actions_size, final_base_ids_size, final_nt_symbols_size,
                   final_nt_accounts_size, final_orig_nt_actions_size, final_orig_nt_qty_size);
        
        // Perform emergency rollback
        PrintFormat("ATOMIC_REMOVE_ERROR: Performing emergency rollback due to size validation failure...");
        ArrayCopy(g_open_mt5_pos_ids, backup_pos_ids);
        ArrayCopy(g_open_mt5_actions, backup_actions);
        ArrayCopy(g_open_mt5_base_ids, backup_base_ids);
        ArrayCopy(g_open_mt5_nt_symbols, backup_nt_symbols);
        ArrayCopy(g_open_mt5_nt_accounts, backup_nt_accounts);
        ArrayCopy(g_open_mt5_original_nt_actions, backup_orig_nt_actions);
        ArrayCopy(g_open_mt5_original_nt_quantities, backup_orig_nt_qty);
        
        PrintFormat("ATOMIC_REMOVE_ERROR: Emergency rollback completed.");
        g_array_modification_in_progress = false; // Unlock before returning
        return;
    }
    
    // === SUCCESS LOGGING ===
    PrintFormat("ATOMIC_REMOVE_SUCCESS: Element at index %d removed successfully from all parallel arrays", index_to_remove);
    PrintFormat("ATOMIC_REMOVE_SUCCESS: AFTER - All arrays now have size %d (reduced from %d)", expected_final_size, pos_ids_size);
    
    // Log first few remaining elements for verification
    for(int i = 0; i < MathMin(3, final_pos_ids_size); i++) {
        PrintFormat("ATOMIC_REMOVE_SUCCESS: Remaining[%d] - PosID=%I64d, Action='%s', BaseID='%s'",
                   i, g_open_mt5_pos_ids[i], g_open_mt5_actions[i], g_open_mt5_base_ids[i]);
    }
    
    // Clean up backup arrays
    ArrayFree(backup_pos_ids);
    ArrayFree(backup_actions);
    ArrayFree(backup_base_ids);
    ArrayFree(backup_nt_symbols);
    ArrayFree(backup_nt_accounts);
    ArrayFree(backup_orig_nt_actions);
    ArrayFree(backup_orig_nt_qty);
    
    // === UNLOCK AND EXIT ===
    g_array_modification_in_progress = false; // Unlock arrays after successful completion
    PrintFormat("ATOMIC_REMOVE_SUCCESS: Array modification lock released. Operation completed successfully.");
}

//+------------------------------------------------------------------+
//| Array Integrity Validation Function                             |
//| Checks if all parallel arrays are synchronized                  |
//+------------------------------------------------------------------+
bool ValidateArrayIntegrity(bool log_details = false)
{
    int pos_ids_size = ArraySize(g_open_mt5_pos_ids);
    int actions_size = ArraySize(g_open_mt5_actions);
    int base_ids_size = ArraySize(g_open_mt5_base_ids);
    int nt_symbols_size = ArraySize(g_open_mt5_nt_symbols);
    int nt_accounts_size = ArraySize(g_open_mt5_nt_accounts);
    int orig_nt_actions_size = ArraySize(g_open_mt5_original_nt_actions);
    int orig_nt_qty_size = ArraySize(g_open_mt5_original_nt_quantities);
    
    bool integrity_ok = true;
    
    if(log_details) {
        PrintFormat("ARRAY_INTEGRITY_CHECK: Array sizes - pos_ids=%d, actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, orig_actions=%d, orig_qty=%d",
                   pos_ids_size, actions_size, base_ids_size, nt_symbols_size, nt_accounts_size, orig_nt_actions_size, orig_nt_qty_size);
    }
    
    // Check if all arrays have the same size
    if(actions_size != pos_ids_size || base_ids_size != pos_ids_size ||
       nt_symbols_size != pos_ids_size || nt_accounts_size != pos_ids_size ||
       orig_nt_actions_size != pos_ids_size || orig_nt_qty_size != pos_ids_size) {
        
        integrity_ok = false;
        PrintFormat("ARRAY_INTEGRITY_ERROR: Size mismatch detected! Expected all arrays to have size %d", pos_ids_size);
        PrintFormat("ARRAY_INTEGRITY_ERROR: Actual sizes - actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d, orig_actions=%d, orig_qty=%d",
                   actions_size, base_ids_size, nt_symbols_size, nt_accounts_size, orig_nt_actions_size, orig_nt_qty_size);
    }
    
    // Check for empty action strings which indicate corruption
    for(int i = 0; i < MathMin(pos_ids_size, actions_size); i++) {
        if(g_open_mt5_actions[i] == "") {
            integrity_ok = false;
            PrintFormat("ARRAY_INTEGRITY_ERROR: Empty action string found at index %d (PosID=%I64d)", i,
                       (i < pos_ids_size) ? g_open_mt5_pos_ids[i] : -1);
        }
    }
    
    if(log_details && integrity_ok) {
        PrintFormat("ARRAY_INTEGRITY_CHECK: All arrays are properly synchronized (size=%d)", pos_ids_size);
    }
    
    return integrity_ok;
}

//+------------------------------------------------------------------+
//| TradeTransaction event handler                                   |
//+------------------------------------------------------------------+
// Structure to hold position closure data for batch processing
struct PositionClosureData
{
    ulong position_id;
    ulong deal_ticket;
    double deal_volume;
    string base_id;
    string nt_symbol;
    string nt_account;
    string mt5_action;
    string closure_reason;
    int array_index;
    bool found_in_arrays;
};

// Global array to collect position closures for batch processing
PositionClosureData g_pending_closures[];

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
  // --- DIAGNOSTIC LOGGING FOR CONCURRENT PROCESSING INVESTIGATION ---
  static int transaction_counter = 0;
  transaction_counter++;
  PrintFormat("ARRAY_CORRUPTION_DIAG: OnTradeTransaction ENTRY #%d - Type=%s, Deal=%I64u, Order=%I64u, Position=%I64u",
             transaction_counter, EnumToString(trans.type), trans.deal, trans.order, trans.position);
  PrintFormat("ARRAY_CORRUPTION_DIAG: Current array sizes at transaction start: pos_ids=%d, actions=%d, base_ids=%d",
             ArraySize(g_open_mt5_pos_ids), ArraySize(g_open_mt5_actions), ArraySize(g_open_mt5_base_ids));

  Print("DEBUG_HEDGE_CLOSURE: OnTradeTransaction fired. Type: ", EnumToString(trans.type), ", Deal: ", trans.deal, ", Order: ", trans.order, ", Pos: ", trans.position);
  Print("ACHM_DIAG: [OnTradeTransaction] Entry. trans.type=", EnumToString(trans.type), ", trans.deal=", trans.deal, ", trans.position=", trans.position);

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

        // Variables for SendHedgeCloseNotification
        double notification_deal_volume = 0.0;
        string notification_hedge_action = "unknown"; // Action of the MT5 deal that closed the hedge
        ulong current_deal_ticket_for_notification = trans.deal;

        if(HistoryDealSelect(current_deal_ticket_for_notification)) {
            notification_deal_volume = HistoryDealGetDouble(current_deal_ticket_for_notification, DEAL_VOLUME);
        } else {
            Print("ERROR: OnTradeTransaction - Could not select deal ", current_deal_ticket_for_notification, " to get volume/action for notification. PosID: ", closing_deal_position_id);
        }

        // --- Determine if the position is fully closed ---
        CPositionInfo posInfo;
        bool is_position_closed = true; // Assume closed unless found open
        string closed_position_comment = ""; // Store comment of the closing position

        // Check if the position still exists to determine if it's fully closed
        if(posInfo.SelectByTicket(closing_deal_position_id)) {
            closed_position_comment = posInfo.Comment(); // Get comment BEFORE checking volume
            if(posInfo.Volume() > 0) {
                is_position_closed = false;
                Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " is NOT fully closed yet. Volume: ", posInfo.Volume(), ", Comment: '", closed_position_comment, "'");
            } else {
                Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " selected and has 0 volume. Comment: '", closed_position_comment, "'");
            }
        } else {
            // If SelectByTicket fails, it implies the position no longer exists, so it's closed.
            Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " not found by SelectByTicket. Assuming fully closed.");
            // Attempt to get comment from the order that led to this deal, if possible, as a last resort for comment.
            ulong order_ticket_of_closing_deal = HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
            if (order_ticket_of_closing_deal > 0 && HistoryOrderSelect(order_ticket_of_closing_deal)) {
                closed_position_comment = HistoryOrderGetString(order_ticket_of_closing_deal, ORDER_COMMENT);
                Print("DEBUG_HEDGE_CLOSURE: Fallback - Got comment '", closed_position_comment, "' from order #", order_ticket_of_closing_deal, " associated with closing deal.");
            }
        }

        // Variables for prioritized Base ID and MT5 Action Retrieval
        string notify_base_id = "";
        string notify_nt_symbol = "UNKNOWN_SYMBOL"; // Default
        string notify_nt_account = "UNKNOWN_ACCOUNT"; // Default
        string stored_mt5_action = "unknown"; // Default
        bool details_found_from_parallel_arrays = false;
        int removal_index = -1;

        if(is_position_closed) {
            Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " is considered fully closed.");

            // --- BATCH PROCESSING APPROACH: Collect closure data without immediate array modification ---
            PrintFormat("BATCH_PROCESSING: Collecting closure data for PosID %I64u", closing_deal_position_id);
            
            // --- DIAGNOSTIC LOGGING FOR ARRAY CORRUPTION INVESTIGATION ---
            PrintFormat("ARRAY_CORRUPTION_DIAG: BEFORE lookup - Array sizes: pos_ids=%d, actions=%d, base_ids=%d, nt_symbols=%d, nt_accounts=%d",
                       ArraySize(g_open_mt5_pos_ids), ArraySize(g_open_mt5_actions), ArraySize(g_open_mt5_base_ids),
                       ArraySize(g_open_mt5_nt_symbols), ArraySize(g_open_mt5_nt_accounts));
            
            // Print first few elements for corruption detection
            for(int debug_i = 0; debug_i < MathMin(3, ArraySize(g_open_mt5_pos_ids)); debug_i++) {
                string debug_action = (debug_i < ArraySize(g_open_mt5_actions)) ? g_open_mt5_actions[debug_i] : "OUT_OF_BOUNDS";
                string debug_base_id = (debug_i < ArraySize(g_open_mt5_base_ids)) ? g_open_mt5_base_ids[debug_i] : "OUT_OF_BOUNDS";
                PrintFormat("ARRAY_CORRUPTION_DIAG: Index[%d] - PosID=%I64d, Action='%s', BaseID='%s'",
                           debug_i, g_open_mt5_pos_ids[debug_i], debug_action, debug_base_id);
            }

            // --- Prioritized Base ID and MT5 Action Retrieval for Notification ---
            // 1. Try to find details in parallel arrays using the PositionID
            Print("DEBUG_HEDGE_CLOSURE: Attempting lookup in g_open_mt5_pos_ids for PosID ", closing_deal_position_id);
            for(int i = 0; i < ArraySize(g_open_mt5_pos_ids); i++) {
                PrintFormat("ARRAY_CORRUPTION_DIAG: Checking index[%d] - PosID=%I64d vs target=%I64u",
                           i, g_open_mt5_pos_ids[i], closing_deal_position_id);
                           
                if(g_open_mt5_pos_ids[i] == (long)closing_deal_position_id) {
                    PrintFormat("ARRAY_CORRUPTION_DIAG: MATCH found at index[%d] for PosID=%I64u", i, closing_deal_position_id);
                    
                    // Bounds checking before accessing parallel arrays
                    if(i >= ArraySize(g_open_mt5_base_ids)) {
                        PrintFormat("ARRAY_CORRUPTION_ERROR: Index[%d] out of bounds for g_open_mt5_base_ids (size=%d)", i, ArraySize(g_open_mt5_base_ids));
                        break;
                    }
                    if(i >= ArraySize(g_open_mt5_nt_symbols)) {
                        PrintFormat("ARRAY_CORRUPTION_ERROR: Index[%d] out of bounds for g_open_mt5_nt_symbols (size=%d)", i, ArraySize(g_open_mt5_nt_symbols));
                        break;
                    }
                    if(i >= ArraySize(g_open_mt5_nt_accounts)) {
                        PrintFormat("ARRAY_CORRUPTION_ERROR: Index[%d] out of bounds for g_open_mt5_nt_accounts (size=%d)", i, ArraySize(g_open_mt5_nt_accounts));
                        break;
                    }
                    
                    notify_base_id = g_open_mt5_base_ids[i];
                    notify_nt_symbol = g_open_mt5_nt_symbols[i];
                    notify_nt_account = g_open_mt5_nt_accounts[i];
                    
                    // Critical diagnostic for g_open_mt5_actions access
                    PrintFormat("ARRAY_CORRUPTION_DIAG: For PosID %I64u, found_index=%d. ArraySize(g_open_mt5_actions)=%d. Attempting to read g_open_mt5_actions[found_index].", closing_deal_position_id, i, ArraySize(g_open_mt5_actions));
                    if (i >= 0 && i < ArraySize(g_open_mt5_actions)) {
                        stored_mt5_action = g_open_mt5_actions[i];
                        PrintFormat("ARRAY_CORRUPTION_DIAG: Successfully read g_open_mt5_actions[%d]='%s'", i, stored_mt5_action);
                    } else {
                        PrintFormat("ARRAY_CORRUPTION_ERROR: Invalid index %d for g_open_mt5_actions (size %d) for PosID %I64u. Setting action to empty.", i, ArraySize(g_open_mt5_actions), closing_deal_position_id);
                        stored_mt5_action = "";
                    }
                    
                    details_found_from_parallel_arrays = true;
                    removal_index = i;
                    PrintFormat("ARRAY_CORRUPTION_DIAG: Found details in parallel arrays for PosID %I64u at index %d. BaseID='%s', MT5_Action='%s'", closing_deal_position_id, i, notify_base_id, stored_mt5_action);
                    break;
                }
            }
            
            if(!details_found_from_parallel_arrays) {
                PrintFormat("ARRAY_CORRUPTION_DIAG: NO MATCH found in parallel arrays for PosID=%I64u. Array size was %d", closing_deal_position_id, ArraySize(g_open_mt5_pos_ids));
            }

            // 2. If not found in parallel arrays, try to extract base_id from the closed position's comment (fallback for older positions or recovery)
            if (!details_found_from_parallel_arrays && closed_position_comment != "") {
                notify_base_id = ExtractBaseIdFromComment(closed_position_comment);
                if (notify_base_id != "") {
                    Print("DEBUG_HEDGE_CLOSURE: Details not found in parallel arrays. Successfully extracted notify_base_id='", notify_base_id, "' from closed position comment '", closed_position_comment, "' as fallback.");
                    // We don't have the stored MT5 action in this fallback case, it remains "unknown".
                    // NT Symbol/Account also remain UNKNOWN unless we parse comment further (which ExtractBaseIdFromComment doesn't do).
                } else {
                    Print("DEBUG_HEDGE_CLOSURE: Details not found in parallel arrays. Failed to extract notify_base_id from closed position comment '", closed_position_comment, "' as fallback.");
                }
            } else if (!details_found_from_parallel_arrays && closed_position_comment == "") {
                 Print("DEBUG_HEDGE_CLOSURE: Details not found in parallel arrays and closed position comment is empty. Cannot determine notify_base_id.");
            }
            
            // --- COLLECT CLOSURE DATA FOR BATCH PROCESSING ---
            // Instead of immediately processing and modifying arrays, collect all closure data first
            int closure_index = ArraySize(g_pending_closures);
            ArrayResize(g_pending_closures, closure_index + 1);
            
            g_pending_closures[closure_index].position_id = closing_deal_position_id;
            g_pending_closures[closure_index].deal_ticket = current_deal_ticket_for_notification;
            g_pending_closures[closure_index].deal_volume = notification_deal_volume;
            g_pending_closures[closure_index].base_id = notify_base_id;
            g_pending_closures[closure_index].nt_symbol = notify_nt_symbol;
            g_pending_closures[closure_index].nt_account = notify_nt_account;
            g_pending_closures[closure_index].mt5_action = stored_mt5_action;
            g_pending_closures[closure_index].array_index = removal_index;
            g_pending_closures[closure_index].found_in_arrays = details_found_from_parallel_arrays;
            
            PrintFormat("BATCH_PROCESSING: Collected closure data[%d] for PosID %I64u - BaseID='%s', Action='%s', ArrayIndex=%d",
                       closure_index, closing_deal_position_id, notify_base_id, stored_mt5_action, removal_index);
            
            // --- PROCESS ALL PENDING CLOSURES ATOMICALLY ---
            // This prevents array index invalidation during iteration
            ProcessPendingClosuresBatch();
            
            return; // Skip the old immediate processing logic below

            // Use the stored MT5 action if found, otherwise use the default "unknown"
            notification_hedge_action = stored_mt5_action;
            Print("DEBUG_HEDGE_CLOSURE: Final notification_hedge_action determined as: '", notification_hedge_action, "'");

            // --- Actual Notification Sending & State Update ---
            // notify_base_id is now populated from the best available source (parallel arrays or comment fallback)
            // notify_nt_symbol and notify_nt_account are populated if found via parallel arrays, otherwise "UNKNOWN..."
            // notification_hedge_action is populated from parallel arrays if found, otherwise "unknown"

            // Increment MT5 hedges closed count for this base_id's group
            int groupIdxClosed = -1;
            if (notify_base_id != "") { // Only if we have a base_id to look up the group
                for(int k = 0; k < ArraySize(g_baseIds); k++) {
                    if(g_baseIds[k] == notify_base_id) {
                        groupIdxClosed = k;
                        break;
                    }
                }
                if(groupIdxClosed != -1 && groupIdxClosed < ArraySize(g_mt5HedgesClosedCount)) {
                    g_mt5HedgesClosedCount[groupIdxClosed]++;
                    Print("ACHM_DIAG: [OnTradeTransaction] Incremented g_mt5HedgesClosedCount for base_id '", notify_base_id, "' (index ", groupIdxClosed, ") to ", g_mt5HedgesClosedCount[groupIdxClosed]);

                    // ---- GROUP REMOVAL LOGIC ----
                    bool nt_fills_are_complete = (groupIdxClosed < ArraySize(g_isComplete)) ? g_isComplete[groupIdxClosed] : false;
                    int opened_count_for_group = (groupIdxClosed < ArraySize(g_mt5HedgesOpenedCount)) ? g_mt5HedgesOpenedCount[groupIdxClosed] : 0;
                    bool mt5_hedges_opened_for_group = (opened_count_for_group > 0);
                    int closed_count_for_group = g_mt5HedgesClosedCount[groupIdxClosed]; // Already incremented
                    bool all_mt5_hedges_are_closed = (closed_count_for_group >= opened_count_for_group);

                    Print("ACHM_DIAG: [OnTradeTransaction] Reconciliation check for base_id '", notify_base_id, "' (index ", groupIdxClosed, "): NT_Complete=", nt_fills_are_complete,
                          ", MT5_Opened_Exist=", mt5_hedges_opened_for_group, ", MT5_All_Closed=", all_mt5_hedges_are_closed,
                          ", ExpectedOpenedCount=", opened_count_for_group,
                          ", ActualClosedCount=", closed_count_for_group);

                    if (nt_fills_are_complete && mt5_hedges_opened_for_group && all_mt5_hedges_are_closed) {
                        Print("ACHM_LOG: [OnTradeTransaction] Trade group '", notify_base_id, "' (index ", groupIdxClosed, ") is fully reconciled. Removing.");
                        FinalizeAndRemoveTradeGroup(groupIdxClosed);
                    } else {
                         Print("ACHM_DIAG: [OnTradeTransaction] Trade group '", notify_base_id, "' (index ", groupIdxClosed, ") NOT yet fully reconciled.");
                    }
                } else if (notify_base_id != "") { // Has base_id, but group not found
                    Print("ACHM_DIAG: [OnTradeTransaction] WARNING - Could not find group for base_id '", notify_base_id, "' to increment g_mt5HedgesClosedCount or perform reconciliation.");
                }
            }

            string closure_reason = "UNKNOWN_MT5_CLOSE"; // Default
            // Determine a more specific closure reason based on how we found the base_id and if the group was reconciled
            if (notify_base_id != "") {
                 if (groupIdxClosed != -1) { // Group was found for the notify_base_id
                     bool is_nt_complete_for_group = (groupIdxClosed < ArraySize(g_isComplete) && g_isComplete[groupIdxClosed]);
                     bool all_mt5_closed_for_group = (groupIdxClosed < ArraySize(g_mt5HedgesOpenedCount) && g_mt5HedgesClosedCount[groupIdxClosed] >= g_mt5HedgesOpenedCount[groupIdxClosed]);
                     if (is_nt_complete_for_group && all_mt5_closed_for_group) {
                         closure_reason = "EA_RECONCILED_AND_CLOSED";
                     } else if (details_found_from_parallel_arrays) {
                         closure_reason = "EA_PARALLEL_ARRAY_CLOSE";
                     } else if (closed_position_comment != "" && ExtractBaseIdFromComment(closed_position_comment) == notify_base_id){
                         closure_reason = "EA_COMMENT_BASED_CLOSE";
                     }
                } else if (details_found_from_parallel_arrays) { // Base_id from parallel arrays but no group (should be rare if group logic is sound)
                    closure_reason = "EA_PARALLEL_ARRAY_ORPHAN_CLOSE";
                } else if (closed_position_comment != "" && ExtractBaseIdFromComment(closed_position_comment) == notify_base_id){ // Base_id from comment, but no group
                     closure_reason = "EA_COMMENT_ORPHAN_CLOSE";
                } else if (CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) { // Check if old map was the source
                    CString *temp_check_ptr = NULL;
                    if(g_map_position_id_to_base_id.TryGetValue((long)closing_deal_position_id, temp_check_ptr) && temp_check_ptr != NULL && temp_check_ptr.Str() == notify_base_id) {
                        closure_reason = "EA_OLD_MAP_FALLBACK_CLOSE";
                    }
                }
            }
            Print("ACHM_DIAG: [OnTradeTransaction] Determined closure_reason: '", closure_reason, "' for notify_base_id: '", notify_base_id, "'");


            if (notify_base_id != "" && notification_hedge_action != "unknown" && notification_deal_volume > 0) {
                Print("DEBUG_HEDGE_CLOSURE: Sending hedge close notification for base_id: ", notify_base_id,
                      ", NT Symbol: ", notify_nt_symbol, ", NT Account: ", notify_nt_account,
                      ", Closed Vol: ", notification_deal_volume, ", Closed Action: ", notification_hedge_action,
                      ", Reason: ", closure_reason);
                SendHedgeCloseNotification(notify_base_id, notify_nt_symbol, notify_nt_account, notification_deal_volume, notification_hedge_action, TimeCurrent(), closure_reason);
                PrintFormat("DEBUG_HEDGE_CLOSURE: Successfully sent hedge close notification for PosID %d. BaseID: %s. Reason: %s", (long)closing_deal_position_id, notify_base_id, closure_reason);

                if(removal_index != -1) { // If found and removed from parallel arrays
                    RemoveFromOpenMT5Arrays(removal_index);
                    Print("ACHM_DIAG: [OnTradeTransaction] Called RemoveFromOpenMT5Arrays for index ", removal_index, " (PosID ", (long)closing_deal_position_id, ")");
                }
                
                // Clean up old map if this PosID was the source of the base_id AND it was from the old map
                if (closure_reason == "EA_OLD_MAP_FALLBACK_CLOSE" && CheckPointer(g_map_position_id_to_base_id) == POINTER_DYNAMIC) {
                    CString *removed_val = NULL;
                    // TryGetValue again to get the pointer for deletion, then Remove.
                    if(g_map_position_id_to_base_id.TryGetValue((long)closing_deal_position_id, removed_val)){
                        if(g_map_position_id_to_base_id.Remove((long)closing_deal_position_id)){
                            Print("DEBUG_HEDGE_CLOSURE: Removed PosID ", (long)closing_deal_position_id, " from OLD map after using it for fallback notification.");
                            if(CheckPointer(removed_val) == POINTER_DYNAMIC) delete removed_val;
                        } else {
                            Print("DEBUG_HEDGE_CLOSURE: Failed to remove PosID ", (long)closing_deal_position_id, " from OLD map even after TryGetValue succeeded.");
                        }
                    }
                }
            } else { // notify_base_id is empty OR other details missing for notification
                PrintFormat("DEBUG_HEDGE_CLOSURE: ERROR - Cannot send notification for PosID %d. notify_base_id='%s', deal_volume=%f, hedge_action='%s'.", (long)closing_deal_position_id, notify_base_id, notification_deal_volume, notification_hedge_action);
                // Orphan logic below might still attempt globalFutures adjustment if comment is parsable
            }
            // --- END HEDGE CLOSURE NOTIFICATION LOGIC ---
 
            // --- AC ADJUSTMENT LOGIC (uses base_id_for_prefix which should be same as notify_base_id if found) ---
            // Note: base_id_for_prefix is now populated from the same logic as notify_base_id
            string base_id_for_ac_adj = notify_base_id; // Use the same base_id found for notification

            if(base_id_for_ac_adj != "") {
                int groupIndexAC = -1;
                for(int i = 0; i < ArraySize(g_baseIds); i++) {
                    if(g_baseIds[i] == base_id_for_ac_adj) { // Check if group still exists
                        groupIndexAC = i;
                        break;
                    }
                }

                if(groupIndexAC != -1) { // Group for base_id_for_ac_adj exists
                    string nt_instr_ac = (groupIndexAC < ArraySize(g_ntInstrumentSymbols)) ? g_ntInstrumentSymbols[groupIndexAC] : "";
                    string nt_acc_ac = (groupIndexAC < ArraySize(g_ntAccountNames)) ? g_ntAccountNames[groupIndexAC] : "";
                    Print("DEBUG_HEDGE_CLOSURE: Found trade group for AC base_id '", base_id_for_ac_adj, "' at index ", groupIndexAC);

                    if(HistoryDealSelect(trans.deal)) {
                        double deal_vol_ac = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
                        double deal_pnl_ac = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                        if(UseACRiskManagement) {
                           HandleACAdjustmentOnHedgeClosure(base_id_for_ac_adj, deal_vol_ac, deal_pnl_ac);
                           Print("DEBUG_HEDGE_CLOSURE: Called HandleACAdjustmentOnHedgeClosure for PosID ", closing_deal_position_id, " (base_id '", base_id_for_ac_adj, "') with PnL: ", deal_pnl_ac);
                        }
                        // Mark the trade group (found by base_id_for_ac_adj) as complete if it's not already.
                        // This part is a bit redundant if the new reconciliation logic already handled it via notify_base_id.
                        // However, base_id_for_ac_adj might be from a very old position not in parallel arrays.
                        if (groupIndexAC < ArraySize(g_isComplete) && !g_isComplete[groupIndexAC]) {
                             g_isComplete[groupIndexAC] = true;
                             Print("DEBUG_HEDGE_CLOSURE: Marked trade group (for AC) at index ", groupIndexAC, " (base_id: ", base_id_for_ac_adj, ") as complete.");
                        }
                    } else {
                        Print("ERROR: Could not select closing deal #", trans.deal, " for AC adjustment for base_id '", base_id_for_ac_adj, "'");
                    }
                } else {
                    Print("DEBUG_HEDGE_CLOSURE: No trade group found for AC base_id '", base_id_for_ac_adj, "'. Skipping AC adjustment.");
                }
            }
            // --- END AC ADJUSTMENT LOGIC ---

        } else { // Position is NOT fully closed by this deal
             Print("DEBUG_HEDGE_CLOSURE: Position #", closing_deal_position_id, " was affected by deal ", deal_ticket, " but is NOT fully closed. Volume remaining: ", (posInfo.SelectByTicket(closing_deal_position_id) ? posInfo.Volume() : -1.0), ". No full closure processing.");
        }
        // If !is_position_closed, the deal was a partial close or the position is still open for other reasons.

        // --- FALLBACK FOR ORPHANED HEDGES (if notify_base_id is still empty after all attempts) ---
        // This block is now only for globalFutures adjustment if no base_id was found for notification/AC logic.
        // The notification logic above is the primary path.
        if(is_position_closed && notify_base_id == "") { // Check if position is closed AND we failed to find base_id via primary methods
            Print("ACHM_ORPHAN: Position ", closing_deal_position_id, " closed, but notify_base_id is empty. Attempting fallback globalFutures adjustment from position/order comment.");
            
            string comment_for_orphan_parsing = closed_position_comment; // From earlier CPositionInfo attempt
            if (comment_for_orphan_parsing == "") { // If CPositionInfo failed to get it
                 ulong order_ticket_for_closing_deal = HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
                 if(order_ticket_for_closing_deal > 0 && HistoryOrderSelect(order_ticket_for_closing_deal)){ // Check if order_ticket is valid
                     comment_for_orphan_parsing = HistoryOrderGetString(order_ticket_for_closing_deal, ORDER_COMMENT);
                     Print("ACHM_ORPHAN: Using comment from closing order ", order_ticket_for_closing_deal, ": '", comment_for_orphan_parsing, "'");
                 }
            }
            // string notify_base_id; // Removed redundant local declaration, outer scope variable will be used.

            if(comment_for_orphan_parsing != "") {
                string fb_base_id_str = ExtractBaseIdFromComment(comment_for_orphan_parsing); // Use enhanced extractor
                string fb_nt_action_str = "";
                int fb_nt_qty_val = 0;
                string fb_mt5_action_str = "";

                string fallback_parts[];
                int fallback_num_parts = StringSplit(comment_for_orphan_parsing, ';', fallback_parts);

                if(fallback_num_parts > 0 && fallback_parts[0] == "AC_HEDGE") {
                    // Attempt to parse NTA, NTQ, MTA if available
                    if (fallback_num_parts > 2 && StringFind(fallback_parts[2], "NTA:", 0) == 0) {
                        string nta_part[]; StringSplit(fallback_parts[2], ':', nta_part);
                        if(ArraySize(nta_part) == 2) fb_nt_action_str = nta_part[1];
                    }
                    if (fallback_num_parts > 3 && StringFind(fallback_parts[3], "NTQ:", 0) == 0) {
                        string ntq_part[]; StringSplit(fallback_parts[3], ':', ntq_part);
                        if(ArraySize(ntq_part) == 2) fb_nt_qty_val = (int)StringToInteger(ntq_part[1]);
                    }
                    if (fallback_num_parts > 4 && StringFind(fallback_parts[4], "MTA:", 0) == 0) {
                        string mta_part[]; StringSplit(fallback_parts[4], ':', mta_part);
                        if(ArraySize(mta_part) == 2) fb_mt5_action_str = mta_part[1];
                    }
                } else {
                    Print("ACHM_ORPHAN_WARN: Fallback comment '", comment_for_orphan_parsing, "' does not start with AC_HEDGE. Cannot reliably parse NTA/NTQ/MTA.");
                }

                // We need at least the MT5 action and NT quantity for globalFutures adjustment.
                // Base ID and NT Action are good for logging/completeness.
                if(fb_mt5_action_str != "" && fb_nt_qty_val > 0) { // fb_base_id_str and fb_nt_action_str are optional for this specific adjustment
                    Print("ACHM_ORPHAN: Parsed from orphan comment '", comment_for_orphan_parsing, "': BaseID='", fb_base_id_str, "', Orig_NT_Action='", fb_nt_action_str, "', Orig_NT_Qty=", fb_nt_qty_val, ", MT5_Hedge_Action='", fb_mt5_action_str, "'");
                    
                    double adjustment = 0;
                    if (fb_mt5_action_str == "Buy") { // MT5 Buy hedge closed (was hedging NT Sell)
                        adjustment = fb_nt_qty_val; // globalFutures should increase (become less negative or more positive)
                        globalFutures += adjustment;
                        Print("ACHM_ORPHAN: Closed MT5 BUY hedge (was for NT SELL). globalFutures adjusted by +", adjustment, ". New globalFutures: ", globalFutures);
                    } else if (fb_mt5_action_str == "Sell") { // MT5 Sell hedge closed (was hedging NT Buy)
                        adjustment = -fb_nt_qty_val; // globalFutures should decrease (become less positive or more negative)
                        globalFutures += adjustment;
                        Print("ACHM_ORPHAN: Closed MT5 SELL hedge (was for NT BUY). globalFutures adjusted by ", adjustment, ". New globalFutures: ", globalFutures);
                    } else {
                         Print("ACHM_ORPHAN_WARN: Parsed MT5 action '", fb_mt5_action_str, "' is not Buy/Sell. No globalFutures adjustment from orphan logic.");
                    }
                } else {
                    Print("ACHM_ORPHAN_WARN: Could not parse essential components (MT5_Action, NT_Qty) from orphan comment '", comment_for_orphan_parsing, "'. No globalFutures adjustment. MTA='", fb_mt5_action_str, "', NTQ=", fb_nt_qty_val);
                }
            } else {
                 Print("ACHM_ORPHAN_WARN: Could not retrieve any comment for fallback adjustment for closed position related to deal ", deal_ticket, " (PosID: ", closing_deal_position_id, ")");
            }
        }
    } // End of if(deal_entry == DEAL_ENTRY_OUT || deal_entry == DEAL_ENTRY_INOUT)
    else // Deal is not a closing type
    {
        Print("DEBUG_HEDGE_CLOSURE: Deal ", deal_ticket, " (Entry: ", EnumToString(deal_entry),
              ") is not a closing type (DEAL_ENTRY_OUT or DEAL_ENTRY_INOUT). Skipping hedge closure notification logic and orphan fallback.");
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