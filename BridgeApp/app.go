package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
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
	hedgebotStatusMux sync.Mutex // Protects hedgebotActive
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

		// NOTE: hedgebotConnected field removed. Status tracked via /health pings.

		json.NewEncoder(w).Encode(trade)
	default:
		w.Write([]byte(`{"status":"no_trade"}`))
	}
}

// healthHandler provides status information
func (a *App) healthHandler(w http.ResponseWriter, r *http.Request) {
	// Read source query parameter
	sourceQuery := r.URL.Query().Get("source")

	// --- HedgeBot Ping Tracking ---
	if sourceQuery == "hedgebot" {
		log.Printf("Health check ping from source: %s", sourceQuery)
		a.hedgebotStatusMux.Lock()
		// Set hedgebotActive to true if it wasn't already, and emit event ONCE
		if !a.hedgebotActive {
			log.Println("HedgeBot connection established via /health?source=hedgebot ping.")
			a.hedgebotActive = true
			// Emit event ONLY when status changes from false to true
			runtime.EventsEmit(a.ctx, "hedgebotStatusChanged", map[string]interface{}{"active": true})
		}
		// Status remains true after the first ping. No further events needed for subsequent pings.
		a.hedgebotStatusMux.Unlock()
	} else if sourceQuery != "" {
		log.Printf("Health check ping from source: %s", sourceQuery)
	} else {
		log.Printf("Health check ping: source parameter not provided")
	}

	// --- Addon connection tracking for /health endpoint --- UNCHANGED ---
	a.addonStatusMux.Lock()
	a.addonConnected = true
	a.lastAddonRequestTime = time.Now()
	log.Println("DEBUG: healthCheckHandler - Addon ping detected, addonConnected SET to true, lastAddonRequestTime updated")
	a.addonStatusMux.Unlock()
	// --- End Addon connection tracking ---

	// Emit event for successful ping - UNCHANGED
	runtime.EventsEmit(a.ctx, "addonPingSuccess")

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
	log.Println("DEBUG: Entered GetStatus")
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
		a.hedgebotStatusMux.Lock() // Use the correct mutex for hedgebotActive
		if a.hedgebotActive {
			hedgebotStatus.success = true
			hedgebotStatus.message = "Hedgebot is marked as active (ping has been received at least once)."
		} else {
			hedgebotStatus.success = false // If never received a ping, it's inactive.
			hedgebotStatus.message = "Hedgebot is marked as inactive. Waiting for first /health?source=hedgebot ping."
		}
		a.hedgebotStatusMux.Unlock()
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
