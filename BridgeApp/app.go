package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// App struct
type App struct {
	ctx                  context.Context
	tradeQueue           chan Trade
	queueMux             sync.Mutex
	netNT                int
	hedgeLot             float64
	bridgeActive         bool
	addonConnected       bool
	tradeHistory         []Trade
	server               *http.Server
	hedgebotActive       bool
	tradeLogSenderActive bool

	// Addon connection tracking
	lastAddonRequestTime time.Time
	addonStatusMux       sync.Mutex
	// HedgeBot connection tracking
	hedgebotStatusMux sync.Mutex // Protects hedgebotActive and hedgebotLastPing
	hedgebotLastPing  time.Time  // Timestamp of the last successful ping from Hedgebot
}

type Trade struct {
	ID              string    `json:"id"`      // Unique trade identifier
	BaseID          string    `json:"base_id"` // Base ID for multi-contract trades
	Time            time.Time `json:"time"`
	Action          string    `json:"action"`                     // Buy/Sell
	Quantity        float64   `json:"quantity"`                   // Always 1 for individual contracts
	Price           float64   `json:"price"`                      // Entry price
	TotalQuantity   int       `json:"total_quantity"`             // Total contracts in this trade
	ContractNum     int       `json:"contract_num"`               // Which contract this is (1-based)
	OrderType       string    `json:"order_type,omitempty"`       // ENTRY, TP, or SL
	MeasurementPips int       `json:"measurement_pips,omitempty"` // Measurement in pips
	RawMeasurement  float64   `json:"raw_measurement,omitempty"`  // Raw measurement value
	Instrument      string    `json:"instrument_name,omitempty"`  // Original NinjaTrader instrument symbol
	AccountName     string    `json:"account_name,omitempty"`     // Original NinjaTrader account name

	// Enhanced NT Performance Data for Elastic Hedging
	NTBalance       float64 `json:"nt_balance,omitempty"`        // NT account balance
	NTDailyPnL      float64 `json:"nt_daily_pnl,omitempty"`      // NT daily P&L
	NTTradeResult   string  `json:"nt_trade_result,omitempty"`   // "win", "loss", or "pending"
	NTSessionTrades int     `json:"nt_session_trades,omitempty"` // Number of trades in current session
}

// HedgeCloseNotification struct mirrors the JSON structure for hedge close notifications
type HedgeCloseNotification struct {
	EventType           string  `json:"event_type"`
	BaseID              string  `json:"base_id"`
	NTInstrumentSymbol  string  `json:"nt_instrument_symbol"`
	NTAccountName       string  `json:"nt_account_name"`
	ClosedHedgeQuantity float64 `json:"closed_hedge_quantity"`
	ClosedHedgeAction   string  `json:"closed_hedge_action"`
	Timestamp           string  `json:"timestamp"`
	ClosureReason       string  `json:"closure_reason"` // Added missing field
}

// MT5TradeResult struct mirrors the JSON payload from MT5 EA trade execution results
type MT5TradeResult struct {
	Status  string  `json:"status"`
	Ticket  uint64  `json:"ticket"` // ulong in MQL5 is usually uint64
	Volume  float64 `json:"volume"`
	IsClose bool    `json:"is_close"`
	ID      string  `json:"id"`
}

// NewApp creates a new App application struct
func NewApp() *App {
	fmt.Println("DEBUG: app.go - In NewApp") // Added for debug
	return &App{
		tradeQueue:     make(chan Trade, 100),
		hedgebotActive: false, // Initialize HedgeBot as inactive
		// addonConnected defaults to false - UNCHANGED
		tradeLogSenderActive: false,
	}
}

// startup is called when the app starts. The context is saved
// so we can call the runtime methods
func (a *App) startup(ctx context.Context) {
	fmt.Println("DEBUG: app.go - In startup") // Added for debug
	a.ctx = ctx

	// Start background goroutine to monitor addon connection status
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			<-ticker.C
			a.addonStatusMux.Lock()
			// If lastAddonRequestTime is zero, never set to true yet
			// if !a.lastAddonRequestTime.IsZero() && time.Since(a.lastAddonRequestTime) > 60*time.Second {
			// 	if a.addonConnected {
			// 		log.Println("DEBUG: Timeout - Setting addonConnected to false")
			// 		a.addonConnected = false
			// 		log.Printf("Addon/Transmitter connection timed out (no /log_trade in 60s)")
			// 	}
			// }
			a.addonStatusMux.Unlock()
		}
	}()

	a.startServer()
}

// StartServer starts the HTTP server
func (a *App) startServer() {
	fmt.Println("DEBUG: app.go - In startServer") // Added for debug
	mux := http.NewServeMux()
	mux.HandleFunc("/log_trade", a.logTradeHandler)
	mux.HandleFunc("/mt5/get_trade", a.getTradeHandler)
	mux.HandleFunc("/health", a.healthHandler)
	mux.HandleFunc("/notify_hedge_close", a.handleNotifyMT5HedgeClosure) // FROM MT5 TO NT
	mux.HandleFunc("/nt_close_hedge", a.handleNTCloseHedgeRequest)       // FROM NT TO MT5 - NEW
	mux.HandleFunc("/mt5/trade_result", a.handleMT5TradeResult)          // New route for MT5 trade results

	a.server = &http.Server{
		Addr:    "127.0.0.1:5000",
		Handler: mux,
	}

	go func() {
		log.Printf("=== Bridge Server Starting ===")
		log.Printf("Initial state:")
		log.Printf("Net position: %d", a.netNT)
		log.Printf("Hedge size: %.2f", a.hedgeLot)
		log.Printf("Queue size: %d", len(a.tradeQueue))
		log.Printf("Listening on 127.0.0.1:5000")

		a.bridgeActive = true

		fmt.Println("DEBUG: app.go - Before ListenAndServe") // Added for debug
		if err := a.server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
			a.bridgeActive = false
		}
	}()
}

// logTradeHandler handles incoming trades
func (a *App) logTradeHandler(w http.ResponseWriter, r *http.Request) {
	log.Println("DEBUG: Entered logTradeHandler")
	// --- Addon connection tracking (MOVED TO TOP) ---
	// This ensures that any request to /log_trade updates the addon connection status,
	// even if the request body (trade data) is malformed or processing fails later.
	a.addonStatusMux.Lock()
	a.lastAddonRequestTime = time.Now() // Always update last seen time

	previouslyConnected := a.addonConnected
	a.addonConnected = true // Crucial: set to true because a request was received on this endpoint
	log.Printf("DEBUG: logTradeHandler - addonConnected JUST SET to: true, lastAddonRequestTime updated")

	if !previouslyConnected {
		log.Printf("Addon/Transmitter connection established via /log_trade endpoint.")
	} else {
		log.Printf("Addon/Transmitter connection refreshed via /log_trade endpoint (was already connected).")
	}
	// log.Printf("DEBUG: logTradeHandler: addonConnected is now %v. lastAddonRequestTime updated to: %s", a.addonConnected, a.lastAddonRequestTime.Format(time.RFC3339)) // Original debug log, can be removed or kept
	a.addonStatusMux.Unlock()
	// --- End Addon connection tracking ---

	var trade Trade
	if err := json.NewDecoder(r.Body).Decode(&trade); err != nil {
		log.Printf("ERROR: Failed to decode trade data from /log_trade: %v. Addon connection status was updated prior to this error.", err)
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Set time if not provided
	if trade.Time.IsZero() {
		trade.Time = time.Now()
	}

	log.Printf("=== Received New Trade (after addon status update) ===")
	log.Printf("ID: %s, Base ID: %s", trade.ID, trade.BaseID)
	log.Printf("Action: %s, Quantity: %.2f", trade.Action, trade.Quantity)
	log.Printf("Contract: %d of %d", trade.ContractNum, trade.TotalQuantity)
	log.Printf("Price: %.2f", trade.Price)

	// Add to history
	a.tradeHistory = append(a.tradeHistory, trade)

	// Handle measurement data for TP/SL orders
	if trade.OrderType == "TP" || trade.OrderType == "SL" {
		log.Printf("Processing %s measurement:", trade.OrderType)
		log.Printf("Raw measurement: %.2f", trade.RawMeasurement)
		log.Printf("Converted to pips: %d", trade.MeasurementPips)

		// Send to MT5 EA queue
		select {
		case a.tradeQueue <- trade:
			log.Printf("Measurement queued successfully")
			w.Write([]byte(`{"status":"success", "measurement_processed":true}`))
		default:
			log.Printf("ERROR: Queue full, measurement not processed")
			http.Error(w, "queue full", http.StatusServiceUnavailable)
		}
		return
	}

	// Handle regular trade data
	select {
	case a.tradeQueue <- trade:
		// Update hedging state using actual quantity
		a.queueMux.Lock()
		oldNT := a.netNT
		oldHedge := a.hedgeLot

		// Check if this is a position closure
		if (trade.Action == "Sell" && oldNT > 0) || (trade.Action == "Buy" && oldNT < 0) {
			// For closing trades, respect the original quantity
			log.Printf("Partial position closure detected. Closing quantity: %.2f", trade.Quantity)
		}

		// Update net position
		if trade.Action == "Buy" {
			a.netNT += int(trade.Quantity)
			log.Printf("Adding %.0f long contracts. Net position: %d → %d", trade.Quantity, oldNT, a.netNT)
		} else if trade.Action == "Sell" {
			a.netNT -= int(trade.Quantity)
			log.Printf("Adding %.0f short contracts. Net position: %d → %d", trade.Quantity, oldNT, a.netNT)
		}

		// No lot multiplier needed - pass through actual position size
		desiredHedgeLot := float64(a.netNT)
		if a.hedgeLot != desiredHedgeLot {
			log.Printf("=== Hedge Position Update ===")
			log.Printf("Previous hedge size: %.2f", oldHedge)
			log.Printf("New hedge size: %.2f", desiredHedgeLot)
			log.Printf("Change triggered by: %s %.2f", trade.Action, trade.Quantity)
			a.hedgeLot = desiredHedgeLot
		}
		a.queueMux.Unlock()

		log.Printf("Trade queued successfully")
		log.Printf("Current queue size: %d", len(a.tradeQueue))
		w.Write([]byte(`{"status":"success"}`))
	default:
		log.Printf("ERROR: Queue full, trade not processed")
		http.Error(w, "queue full", http.StatusServiceUnavailable)
	}
}

// getTradeHandler sends trades to MT5
func (a *App) getTradeHandler(w http.ResponseWriter, r *http.Request) {
	select {
	case trade := <-a.tradeQueue:
		log.Printf("=== Sending Trade to MT5 ===")
		log.Printf("ID: %s, Base ID: %s", trade.ID, trade.BaseID)
		log.Printf("Action: %s, Quantity: %.2f", trade.Action, trade.Quantity)
		log.Printf("Contract: %d of %d", trade.ContractNum, trade.TotalQuantity)

		// Special logging for closure requests
		if trade.Action == "CLOSE_HEDGE" {
			log.Printf("CLOSURE_BRIDGE_TO_MT5: Sending CLOSE_HEDGE request to MT5. BaseID: %s, Quantity: %.2f, OrderType: %s",
				trade.BaseID, trade.Quantity, trade.OrderType)
		}

		// NOTE: hedgebotConnected field removed. Status tracked via /health pings.

		// Construct the payload for the EA
		eaPayload := map[string]interface{}{
			"id":                   trade.ID,
			"base_id":              trade.BaseID,
			"time":                 trade.Time,
			"action":               trade.Action,
			"quantity":             trade.Quantity,
			"price":                trade.Price,
			"total_quantity":       trade.TotalQuantity,
			"contract_num":         trade.ContractNum,
			"order_type":           trade.OrderType,
			"measurement_pips":     trade.MeasurementPips,
			"raw_measurement":      trade.RawMeasurement,
			"nt_instrument_symbol": trade.Instrument,  // Added new field
			"nt_account_name":      trade.AccountName, // Added new field

			// Enhanced NT Performance Data for Elastic Hedging
			"nt_balance":        trade.NTBalance,
			"nt_daily_pnl":      trade.NTDailyPnL,
			"nt_trade_result":   trade.NTTradeResult,
			"nt_session_trades": trade.NTSessionTrades,
		}

		// CRITICAL_DEBUG: Log JSON string before sending
		jsonBytes, err := json.Marshal(eaPayload)
		if err != nil {
			log.Printf("CRITICAL_DEBUG: Error marshaling trade to JSON for debug: %v", err)
		} else {
			log.Printf("CRITICAL_DEBUG: JSON string to be sent to EA: %s", string(jsonBytes))
		}

		// Ensure Content-Type is set
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(eaPayload)
	default:
		w.Header().Set("Content-Type", "application/json") // Also set for "no_trade" for consistency
		w.Write([]byte(`{"status":"no_trade"}`))
	}
}

// handleNotifyMT5HedgeClosure handles hedge closure notifications from MT5 EA
func (a *App) handleNotifyMT5HedgeClosure(w http.ResponseWriter, r *http.Request) {
	log.Println("DEBUG: Entered handleNotifyMT5HedgeClosure")

	if r.Method != http.MethodPost {
		log.Printf("ERROR: Invalid request method for /notify_mt5_hedge_closure: %s", r.Method)
		http.Error(w, "Invalid request method. Only POST is allowed.", http.StatusMethodNotAllowed)
		return
	}

	// Read the raw body first to forward it later
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("ERROR: Failed to read request body from /notify_mt5_hedge_closure: %v", err)
		http.Error(w, "Failed to read request body", http.StatusInternalServerError)
		return
	}
	defer r.Body.Close() // Close the original body

	// Now unmarshal from the read bytes for validation and logging
	var notification HedgeCloseNotification
	if err := json.Unmarshal(bodyBytes, &notification); err != nil {
		log.Printf("ERROR: Failed to decode JSON from /notify_mt5_hedge_closure: %v. Body: %s", err, string(bodyBytes))
		http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
		return
	}

	// Basic Validation
	if notification.EventType != "hedge_close_notification" {
		log.Printf("ERROR: Invalid notification type: %s. Expected 'hedge_close_notification'. Body: %s", notification.EventType, string(bodyBytes))
		http.Error(w, "Invalid notification type", http.StatusBadRequest)
		return
	}
	if notification.BaseID == "" {
		log.Printf("ERROR: Missing base_id in hedge_close_notification. Body: %s", string(bodyBytes))
		http.Error(w, "Missing base_id", http.StatusBadRequest)
		return
	}

	// MISSING_DATA_FIX: Validate and clean base_id before processing
	originalBaseID := notification.BaseID
	if len(notification.BaseID) > 50 {
		log.Printf("WARNING: BaseID appears truncated or corrupted: '%s' (length: %d). Attempting to clean...", notification.BaseID, len(notification.BaseID))
		// Keep only the first 36 characters if it looks like a GUID
		if len(notification.BaseID) >= 36 {
			notification.BaseID = notification.BaseID[:36]
			log.Printf("MISSING_DATA_FIX: Cleaned BaseID from '%s' to '%s'", originalBaseID, notification.BaseID)
		}
	}

	log.Printf("=== Received hedge_close_notification ===")
	log.Printf("Base ID: %s, EventType: %s, Symbol: %s, Account: %s", notification.BaseID, notification.EventType, notification.NTInstrumentSymbol, notification.NTAccountName)
	log.Printf("Closed Quantity: %.2f, Closed Action: %s, Timestamp: %s", notification.ClosedHedgeQuantity, notification.ClosedHedgeAction, notification.Timestamp)

	// Update bridge state based on hedge closure
	a.queueMux.Lock()
	oldHedge := a.hedgeLot

	// FIXED: MT5 hedge closure should NOT affect NT net position
	// The net position is only managed by NT trade notifications
	// MT5 hedge closures are just confirmations that the hedge was closed
	log.Printf("MT5 closed %.2f %s hedge contracts. Net position remains: %d (unchanged)",
		notification.ClosedHedgeQuantity, notification.ClosedHedgeAction, a.netNT)

	// Update hedge size to match the current net position (should already be correct)
	desiredHedgeLot := float64(a.netNT)
	if a.hedgeLot != desiredHedgeLot {
		log.Printf("=== Hedge Position Update (from MT5 closure notification) ===")
		log.Printf("Previous hedge size: %.2f", oldHedge)
		log.Printf("New hedge size: %.2f", desiredHedgeLot)
		log.Printf("SYNC_FIX: Correcting hedge size to match net position after MT5 closure")
		a.hedgeLot = desiredHedgeLot
	}
	a.queueMux.Unlock()

	// Emit event to UI to update displayed position/hedge size
	runtime.EventsEmit(a.ctx, "positionUpdated", map[string]interface{}{"net_position": a.netNT, "hedge_size": a.hedgeLot})

	// Forward to NinjaTrader Addon with retry logic
	ntAddonURL := "http://localhost:8081/notify_hedge_closed" // As per specification

	// Enhanced retry logic for critical closure notifications
	maxRetries := 3
	var lastErr error
	var resp *http.Response

	for attempt := 1; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequest(http.MethodPost, ntAddonURL, bytes.NewBuffer(bodyBytes))
		if err != nil {
			log.Printf("ERROR: Failed to create request to NinjaTrader Addon on attempt %d/%d: %v", attempt, maxRetries, err)
			lastErr = err
			continue
		}
		req.Header.Set("Content-Type", "application/json")

		// Progressive timeout increase
		timeout := time.Duration(5+attempt*2) * time.Second
		client := &http.Client{Timeout: timeout}

		log.Printf("MT5_TO_NT_BRIDGE: Attempt %d/%d forwarding closure notification for BaseID '%s' to NT (timeout: %v)",
			attempt, maxRetries, notification.BaseID, timeout)

		resp, err = client.Do(req)
		if err != nil {
			log.Printf("MT5_TO_NT_BRIDGE: Attempt %d/%d failed for BaseID '%s': %v", attempt, maxRetries, notification.BaseID, err)
			lastErr = err

			if attempt < maxRetries {
				// Progressive backoff: 500ms, 1000ms, 1500ms
				backoffDuration := time.Duration(500*attempt) * time.Millisecond
				log.Printf("MT5_TO_NT_BRIDGE: Retrying in %v...", backoffDuration)
				time.Sleep(backoffDuration)
			}
			continue
		}

		// Success - break out of retry loop
		log.Printf("MT5_TO_NT_BRIDGE: SUCCESS - Forwarded closure notification for BaseID '%s' on attempt %d", notification.BaseID, attempt)
		break
	}

	if resp == nil {
		log.Printf("MT5_TO_NT_BRIDGE: CRITICAL FAILURE - Failed to forward closure notification for BaseID '%s' after %d attempts. Last error: %v",
			notification.BaseID, maxRetries, lastErr)
		// Return error to MT5 so it knows the notification failed
		http.Error(w, fmt.Sprintf("Failed to forward to NinjaTrader after %d attempts: %v", maxRetries, lastErr), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Check response status and validate response
	if resp.StatusCode == http.StatusOK {
		// Read and validate the response from NinjaTrader
		respBody, err := io.ReadAll(resp.Body)
		if err != nil {
			log.Printf("MT5_TO_NT_BRIDGE: ERROR - Failed to read response from NinjaTrader Addon for BaseID '%s': %v", notification.BaseID, err)
			http.Error(w, "Failed to read NinjaTrader response", http.StatusBadGateway)
			return
		}

		// Parse response to ensure it's valid JSON (optional validation)
		var ntResponse map[string]interface{}
		if err := json.Unmarshal(respBody, &ntResponse); err != nil {
			log.Printf("MT5_TO_NT_BRIDGE: WARNING - NinjaTrader response is not valid JSON for BaseID '%s': %s", notification.BaseID, string(respBody))
			// Still consider it success if we got HTTP 200, but log the issue
		}

		// Success - send proper success response to MT5
		log.Printf("MT5_TO_NT_BRIDGE: SUCCESS - Forwarded hedge_close_notification for BaseID '%s' to NinjaTrader Addon. Status: %s",
			notification.BaseID, resp.Status)

		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{
			"status":    "success",
			"message":   "Hedge closure notification processed and forwarded successfully",
			"base_id":   notification.BaseID,
			"nt_status": resp.Status,
		})
	} else {
		body, _ := io.ReadAll(resp.Body)
		log.Printf("MT5_TO_NT_BRIDGE: ERROR - NinjaTrader Addon returned non-200 status: %s for BaseID '%s'. Response: %s",
			resp.Status, notification.BaseID, string(body))
		// Return error to MT5 so it knows the notification failed
		http.Error(w, fmt.Sprintf("NinjaTrader Addon rejected notification with status %s", resp.Status), http.StatusBadGateway)
	}
}

// handleNTCloseHedgeRequest handles hedge closure requests from NinjaTrader
// This is the reverse flow: NT -> Bridge -> MT5
func (a *App) handleNTCloseHedgeRequest(w http.ResponseWriter, r *http.Request) {
	log.Println("DEBUG: Entered handleNTCloseHedgeRequest")

	if r.Method != http.MethodPost {
		log.Printf("ERROR: Invalid request method for /nt_close_hedge: %s", r.Method)
		http.Error(w, "Invalid request method. Only POST is allowed.", http.StatusMethodNotAllowed)
		return
	}

	// Read the request body
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("ERROR: Failed to read request body from /nt_close_hedge: %v", err)
		http.Error(w, "Failed to read request body", http.StatusInternalServerError)
		return
	}
	defer r.Body.Close()

	// Parse the hedge closure notification from NinjaTrader
	var notification HedgeCloseNotification
	if err := json.Unmarshal(bodyBytes, &notification); err != nil {
		log.Printf("ERROR: Failed to decode JSON from /nt_close_hedge: %v. Body: %s", err, string(bodyBytes))
		http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
		return
	}

	// Validate the notification
	if notification.EventType != "hedge_close_notification" {
		log.Printf("ERROR: Invalid notification type: %s. Expected 'hedge_close_notification'. Body: %s", notification.EventType, string(bodyBytes))
		http.Error(w, "Invalid notification type", http.StatusBadRequest)
		return
	}
	if notification.BaseID == "" {
		log.Printf("ERROR: Missing base_id in NT hedge_close_notification. Body: %s", string(bodyBytes))
		http.Error(w, "Missing base_id", http.StatusBadRequest)
		return
	}

	log.Printf("=== Received NT hedge_close_notification ===")
	log.Printf("Base ID: %s, EventType: %s, Symbol: %s, Account: %s", notification.BaseID, notification.EventType, notification.NTInstrumentSymbol, notification.NTAccountName)
	log.Printf("Closed Quantity: %.2f, Closed Action: %s, Timestamp: %s", notification.ClosedHedgeQuantity, notification.ClosedHedgeAction, notification.Timestamp)
	log.Printf("Closure Reason: %s", notification.ClosureReason)

	// Update bridge state based on NT closure
	a.queueMux.Lock()
	oldNT := a.netNT
	oldHedge := a.hedgeLot

	// Update net position based on the NT closure action
	// When NT closes a position, we need to close the corresponding hedge
	if notification.ClosedHedgeAction == "sell" { // NT sold (closed long), so reduce net long position
		a.netNT -= int(notification.ClosedHedgeQuantity)
		log.Printf("NT closed %.2f long contracts. Net position: %d → %d", notification.ClosedHedgeQuantity, oldNT, a.netNT)
	} else if notification.ClosedHedgeAction == "buy" || notification.ClosedHedgeAction == "buytocover" { // NT bought to cover (closed short), so reduce net short position
		a.netNT += int(notification.ClosedHedgeQuantity)
		log.Printf("NT closed %.2f short contracts. Net position: %d → %d", notification.ClosedHedgeQuantity, oldNT, a.netNT)
	}

	// Update hedge size to match the new net position
	desiredHedgeLot := float64(a.netNT)
	if a.hedgeLot != desiredHedgeLot {
		log.Printf("=== Hedge Position Update (from NT closure) ===")
		log.Printf("Previous hedge size: %.2f", oldHedge)
		log.Printf("New hedge size: %.2f", desiredHedgeLot)
		a.hedgeLot = desiredHedgeLot
	}
	a.queueMux.Unlock()

	// Emit event to UI to update displayed position/hedge size
	runtime.EventsEmit(a.ctx, "positionUpdated", map[string]interface{}{"net_position": a.netNT, "hedge_size": a.hedgeLot})

	// Add a special message to the trade queue so MT5 can pick it up and close hedges
	closureTradeMessage := Trade{
		ID:            fmt.Sprintf("nt_close_%s_%d", notification.BaseID, time.Now().Unix()),
		BaseID:        notification.BaseID,
		Time:          time.Now(),
		Action:        "CLOSE_HEDGE", // Special action to indicate hedge closure
		Quantity:      notification.ClosedHedgeQuantity,
		Price:         0, // Not relevant for closures
		TotalQuantity: int(notification.ClosedHedgeQuantity),
		ContractNum:   1,
		Instrument:    notification.NTInstrumentSymbol,
		AccountName:   notification.NTAccountName,
		OrderType:     "NT_CLOSE",
	}

	log.Printf("CLOSURE_DEBUG: Attempting to queue CLOSE_HEDGE message for MT5. BaseID: %s, Action: %s, Quantity: %.2f",
		notification.BaseID, closureTradeMessage.Action, closureTradeMessage.Quantity)

	select {
	case a.tradeQueue <- closureTradeMessage:
		log.Printf("CLOSURE_SUCCESS: NT hedge closure request queued for MT5. BaseID: %s, Queue size now: %d",
			notification.BaseID, len(a.tradeQueue))
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "success", "message": "NT closure request queued for MT5"})
	default:
		log.Printf("CLOSURE_ERROR: Queue full, NT closure request not processed for BaseID: %s. Current queue size: %d",
			notification.BaseID, len(a.tradeQueue))
		http.Error(w, "queue full", http.StatusServiceUnavailable)
	}
}

// handleMT5TradeResult handles trade execution results from MT5 EA
func (a *App) handleMT5TradeResult(w http.ResponseWriter, r *http.Request) {
	log.Println("DEBUG: Entered handleMT5TradeResult")

	if r.Method != http.MethodPost {
		log.Printf("ERROR: Invalid request method for /mt5/trade_result: %s. Expected POST.", r.Method)
		http.Error(w, "Invalid request method. Only POST is allowed.", http.StatusMethodNotAllowed)
		return
	}
	defer r.Body.Close() // Ensure the request body is closed

	var tradeResult MT5TradeResult
	// It's good practice to limit the size of the request body to prevent potential DoS attacks.
	// For example: r.Body = http.MaxBytesReader(w, r.Body, 1024*10) // 10KB limit

	// Decode the JSON payload
	err := json.NewDecoder(r.Body).Decode(&tradeResult)
	if err != nil {
		// If decoding fails, the body might have already been partially read or be in an error state.
		log.Printf("ERROR: Failed to decode JSON from /mt5/trade_result: %v. Check incoming payload.", err)
		http.Error(w, "Invalid JSON payload", http.StatusBadRequest)
		return
	}

	log.Printf("Received MT5 Trade Result: Status: '%s', Ticket: %d, Volume: %.2f, IsClose: %t, ID: '%s'",
		tradeResult.Status, tradeResult.Ticket, tradeResult.Volume, tradeResult.IsClose, tradeResult.ID)

	// Respond to the MT5 EA
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, writeErr := w.Write([]byte("MT5 trade result received"))
	if writeErr != nil {
		// Log error if writing response fails, but status has already been sent.
		log.Printf("ERROR: Failed to write response body for /mt5/trade_result: %v", writeErr)
	}
}

// healthHandler provides status information
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	// Read source query parameter
	sourceQuery := r.URL.Query().Get("source") // e.g., "hedgebot", "addon", or ""

	// --- HedgeBot Ping Tracking ---
	if sourceQuery == "hedgebot" {
		// log.Printf("DEBUG: healthHandler - Received ping with source: %s", sourceQuery) // More specific log
		var statusChanged bool = false // Track if status actually changed
		a.hedgebotStatusMux.Lock()
		// Set hedgebotActive to true if it wasn't already, and emit event ONCE
		if !a.hedgebotActive {
			log.Println("DEBUG: healthHandler - Updating hedgebotActive to true") // Log status change
			log.Println("HedgeBot connection established via /health?source=hedgebot ping.")
			a.hedgebotActive = true
			// Emit event ONLY when status changes from false to true
			statusChanged = true
		}
		a.hedgebotLastPing = time.Now() // Update last ping time on every successful ping
		// Status remains true after the first ping. No further events needed for subsequent pings.
		a.hedgebotStatusMux.Unlock()

		// Emit status change event if it happened
		if statusChanged {
			runtime.EventsEmit(a.ctx, "hedgebotStatusChanged", map[string]interface{}{"active": true})
		}
		// Emit a specific event for hedgebot ping success
		runtime.EventsEmit(a.ctx, "hedgebotPingSuccess") // New event for hedgebot

		// --- Process open_positions from HedgeBot ---
		openPositionsStr := r.URL.Query().Get("open_positions")
		if openPositionsStr != "" {
			openPositions, err := strconv.Atoi(openPositionsStr)
			if err == nil {
				if openPositions == 0 {
					a.queueMux.Lock() // Acquire lock before modifying shared state
					if a.netNT != 0 || a.hedgeLot != 0.0 {
						log.Println("DEBUG: HedgeBot reported 0 open positions. Resetting net position and hedge size.")
						a.netNT = 0
						a.hedgeLot = 0.0
						// Optionally emit an event to the UI to force an update
						runtime.EventsEmit(a.ctx, "positionReset", map[string]interface{}{"net_position": 0, "hedge_size": 0.0})
					}
					a.queueMux.Unlock() // Release lock
				}
				// If openPositions is not 0, we don't reset here.
				// The net position and hedge size are updated by the logTradeHandler based on individual trades.
				// This reset logic is specifically for the case where the hedgebot confirms *all* positions are closed.
			} else {
				log.Printf("ERROR: Failed to parse open_positions query parameter '%s': %v", openPositionsStr, err)
			}
		}
		// --- End Process open_positions ---

	} else if sourceQuery == "addon" || sourceQuery == "" { // Treat "addon" or empty source as Addon ping
		// Log pings from other known sources (like 'addon' if implemented)
		// log.Printf("DEBUG: healthHandler - Received ping treated as Addon (source: '%s')", sourceQuery)

		// --- Addon connection tracking for /health endpoint --- CORRECTED ---
		a.addonStatusMux.Lock()
		a.addonConnected = true
		a.lastAddonRequestTime = time.Now()
		// log.Printf("DEBUG: healthHandler - Correctly updating addonConnected=true for source '%s'", sourceQuery)
		a.addonStatusMux.Unlock()
		// --- End Addon connection tracking ---

		// Emit event ONLY for successful ADDON ping
		runtime.EventsEmit(a.ctx, "addonPingSuccess") // Moved inside Addon condition

	} else {
		// Log pings from unknown sources
		// log.Printf("DEBUG: healthHandler - Received ping from unknown source: %s", sourceQuery)
	}

	// Prepare status response
	a.queueMux.Lock() // Lock for accessing queue/trade state
	status := map[string]interface{}{
		"status":       "healthy",
		"queue_size":   len(a.tradeQueue),
		"net_position": a.netNT,
		"hedge_size":   a.hedgeLot,
	}
	queueSize := len(a.tradeQueue) // Get values while locked
	netPosition := a.netNT
	hedgeSize := a.hedgeLot
	a.queueMux.Unlock() // Unlock queueMux

	// Log health check details (skip MT5 polling noise) - UNCHANGED
	if r.Header.Get("User-Agent") != "Mozilla/4.0" {
		log.Printf("=== Health Check ===")
		log.Printf("Source: %s", sourceQuery) // Added source logging here for context
		log.Printf("Queue size: %d", queueSize)
		log.Printf("Net position: %d", netPosition)
		log.Printf("Current hedge size: %.2f", hedgeSize)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(status)
}

// GetStatus returns the current status for the UI
func (a *App) GetStatus() map[string]interface{} {
	// log.Println("DEBUG: Entered GetStatus")
	a.queueMux.Lock()
	// Read fields protected by queueMux
	bridgeActive := a.bridgeActive
	// hedgebotConnected removed
	netPosition := a.netNT
	hedgeSize := a.hedgeLot
	queueSize := len(a.tradeQueue)
	// hedgebotActive read below under its own mutex
	tradeLogSenderActive := a.tradeLogSenderActive
	a.queueMux.Unlock() // Unlock queueMux as soon as its protected fields are read

	// Read addonConnected under its own mutex - UNCHANGED
	a.addonStatusMux.Lock()
	addonConnected := a.addonConnected
	// log.Printf("DEBUG: GetStatus - Reading addonConnected: %v", addonConnected) // Keep or remove debug log as desired
	a.addonStatusMux.Unlock()

	// Read hedgebotActive under its own mutex
	a.hedgebotStatusMux.Lock()
	hedgebotActive := a.hedgebotActive
	// log.Printf("DEBUG: GetStatus - Reading hedgebotActive: %v", hedgebotActive)
	a.hedgebotStatusMux.Unlock()

	return map[string]interface{}{
		"bridgeActive": bridgeActive,
		// "hedgebotConnected":    hedgebotConnected, // Removed
		"addonConnected":       addonConnected, // Existing Addon status - UNCHANGED
		"netPosition":          netPosition,
		"hedgeSize":            hedgeSize,
		"queueSize":            queueSize,
		"hedgebotActive":       hedgebotActive, // New HedgeBot status (set once)
		"tradeLogSenderActive": tradeLogSenderActive,
	}
}

// GetTradeHistory returns the trade history for the UI
func (a *App) GetTradeHistory() []Trade {
	return a.tradeHistory
}

// shutdown is called when the app is closing
func (a *App) shutdown(ctx context.Context) {
	if a.server != nil {
		a.server.Shutdown(ctx)
	}
}

// AttemptReconnect tries to re-establish connections based on input flags.
// It returns a map detailing the outcome for each component.
func (a *App) AttemptReconnect(retryBridge bool, retryHedgebot bool, retryAddon bool) map[string]interface{} {
	results := make(map[string]interface{})
	var bridgeStatus struct {
		attempted bool
		success   interface{} // Use interface{} to allow bool or nil
		message   string
	}
	var hedgebotStatus struct {
		attempted bool
		success   interface{}
		message   string
	}
	var addonStatus struct {
		attempted bool
		success   interface{}
		message   string
	}

	// --- Handle Bridge Reconnection ---
	if retryBridge {
		bridgeStatus.attempted = true
		a.queueMux.Lock() // Protect access to bridgeActive and server
		if a.bridgeActive {
			bridgeStatus.success = true
			bridgeStatus.message = "Bridge server is already active."
			a.queueMux.Unlock()
		} else {
			log.Println("Attempting to restart Bridge server...")
			// Ensure existing server is shut down before restarting
			if a.server != nil {
				log.Println("Shutting down existing server instance...")
				// Use a short timeout context for shutdown
				shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				if err := a.server.Shutdown(shutdownCtx); err != nil {
					log.Printf("WARN: Error shutting down previous server instance: %v", err)
					// Continue anyway, as ListenAndServe might fail if port is still bound
				} else {
					log.Println("Previous server instance shut down.")
				}
				a.server = nil // Clear the server instance
			}
			a.queueMux.Unlock() // Unlock before calling startServer which manages its own state

			a.startServer() // This starts the server in a new goroutine and sets bridgeActive

			// Give the server goroutine a moment to start and update status
			time.Sleep(200 * time.Millisecond)

			a.queueMux.Lock() // Lock again to read the updated status
			if a.bridgeActive {
				bridgeStatus.success = true
				bridgeStatus.message = "Bridge server restarted successfully."
				log.Println("Bridge server restart successful.")
			} else {
				bridgeStatus.success = false
				bridgeStatus.message = "Failed to restart Bridge server. Check logs for errors."
				log.Println("Bridge server restart failed.")
			}
			a.queueMux.Unlock()
		}
	} else {
		bridgeStatus.attempted = false
		bridgeStatus.success = nil
		bridgeStatus.message = "Bridge reconnection not requested."
	}
	results["bridge"] = bridgeStatus

	// --- Handle Hedgebot Reconnection ---
	if retryHedgebot {
		hedgebotStatus.attempted = true
		hedgebotStatus.message = "Checking Hedgebot status based on last ping time..." // Initial message
		a.hedgebotStatusMux.Lock()                                                     // Use the correct mutex
		lastPingTime := a.hedgebotLastPing
		isActive := a.hedgebotActive // Still useful to know if *ever* connected
		a.hedgebotStatusMux.Unlock()

		if !lastPingTime.IsZero() {
			timeSinceLastPing := time.Since(lastPingTime)
			pingThreshold := 60 * time.Second // Consider ping recent if within 60 seconds
			log.Printf("DEBUG: AttemptReconnect - Time since last Hedgebot ping: %s", timeSinceLastPing)

			if timeSinceLastPing <= pingThreshold {
				hedgebotStatus.success = true
				hedgebotStatus.message = fmt.Sprintf("Hedgebot ping received recently (%s ago). Connection verified.", timeSinceLastPing.Round(time.Second))
				log.Println("Hedgebot connection verified based on recent ping.")
			} else {
				hedgebotStatus.success = false
				hedgebotStatus.message = fmt.Sprintf("Hedgebot ping is stale (last received %s ago). Assumed disconnected.", timeSinceLastPing.Round(time.Second))
				log.Println("Hedgebot connection assumed stale based on last ping time.")
			}
		} else {
			// No ping ever received
			hedgebotStatus.success = false
			if isActive { // Should technically not happen if lastPingTime is Zero, but for safety
				hedgebotStatus.message = "Hedgebot was active previously, but last ping time is missing. Assumed disconnected."
				log.Println("Hedgebot state inconsistent (active but no last ping time). Assuming disconnected.")
			} else {
				hedgebotStatus.message = "No Hedgebot ping has ever been received. Waiting for first /health?source=hedgebot ping."
				log.Println("Hedgebot connection never established (no pings received).")
			}
		}
	} else {
		hedgebotStatus.attempted = false
		hedgebotStatus.success = nil // Remains nil as it's not attempted
		hedgebotStatus.message = "Hedgebot reconnection not requested."
	}
	results["hedgebot"] = hedgebotStatus

	// --- Handle Addon Reconnection ---
	if retryAddon || (!retryBridge && !retryHedgebot && !retryAddon) {
		addonStatus.attempted = true
		addonPingURL := "http://localhost:8081/ping_msm" // TODO: Make this configurable
		client := http.Client{
			Timeout: 5 * time.Second,
		}

		log.Printf("Attempting to ping Addon/Transmitter at %s", addonPingURL)
		resp, err := client.Get(addonPingURL)

		if err != nil {
			log.Printf("Addon/Transmitter ping failed: %v", err)
			a.addonStatusMux.Lock()
			a.addonConnected = false
			a.addonStatusMux.Unlock()

			addonStatus.success = false
			addonStatus.message = fmt.Sprintf("Addon/Transmitter ping failed: %v", err)
			runtime.EventsEmit(a.ctx, "addonRetryResult", map[string]interface{}{"success": false, "message": addonStatus.message})
		} else {
			defer resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				log.Println("Addon/Transmitter ping successful.")
				a.addonStatusMux.Lock()
				a.addonConnected = true
				a.lastAddonRequestTime = time.Now()
				a.addonStatusMux.Unlock()

				addonStatus.success = true
				addonStatus.message = "Addon/Transmitter ping successful."
				runtime.EventsEmit(a.ctx, "addonRetryResult", map[string]interface{}{"success": true, "message": addonStatus.message})
			} else {
				errMsg := fmt.Sprintf("Addon/Transmitter ping failed: received status code %d", resp.StatusCode)
				log.Println(errMsg)
				a.addonStatusMux.Lock()
				a.addonConnected = false
				a.addonStatusMux.Unlock()

				addonStatus.success = false
				addonStatus.message = errMsg
				runtime.EventsEmit(a.ctx, "addonRetryResult", map[string]interface{}{"success": false, "message": addonStatus.message})
			}
		}
	} else {
		addonStatus.attempted = false
		addonStatus.success = nil // Remains nil as it's not attempted
		addonStatus.message = "Addon reconnection not requested."
	}
	results["addon"] = addonStatus

	log.Printf("AttemptReconnect results: %+v", results)
	return results
}
