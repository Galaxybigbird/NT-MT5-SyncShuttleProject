package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"
)

var (
	tradeQueue = make(chan Trade, 100)
	queueMux   sync.Mutex
	netNT      int
	hedgeLot   float64
)

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

func logTradeHandler(w http.ResponseWriter, r *http.Request) {
	var trade Trade
	if err := json.NewDecoder(r.Body).Decode(&trade); err != nil {
		log.Printf("ERROR: Failed to decode trade: %v", err)
		http.Error(w, err.Error(), 400)
		return
	}

	log.Printf("=== Received New Trade ===")
	log.Printf("ID: %s, Base ID: %s", trade.ID, trade.BaseID)
	log.Printf("Action: %s, Quantity: %.2f", trade.Action, trade.Quantity)
	log.Printf("Contract: %d of %d", trade.ContractNum, trade.TotalQuantity)
	log.Printf("Price: %.2f", trade.Price)

	// Handle measurement data for TP/SL orders
	if trade.OrderType == "TP" || trade.OrderType == "SL" {
		log.Printf("Processing %s measurement:", trade.OrderType)
		log.Printf("Raw measurement: %.2f", trade.RawMeasurement)
		log.Printf("Converted to pips: %d", trade.MeasurementPips)

		// Send to MT5 EA queue
		sel := tradeQueue
		select {
		case sel <- trade:
			log.Printf("Measurement queued successfully")
			w.Write([]byte(`{"status":"success", "measurement_processed":true}`))
		default:
			log.Printf("ERROR: Queue full, measurement not processed")
			http.Error(w, "queue full", http.StatusServiceUnavailable)
		}
		return
	}

	// Handle regular trade data
	sel := tradeQueue
	select {
	case sel <- trade:
		// Update hedging state using actual quantity
		queueMux.Lock()
		oldNT := netNT
		oldHedge := hedgeLot

		// Check if this is a position closure
		if (trade.Action == "Sell" && oldNT > 0) || (trade.Action == "Buy" && oldNT < 0) {
			// For closing trades, respect the original quantity
			log.Printf("Partial position closure detected. Closing quantity: %.2f", trade.Quantity)
		}

		// Update net position
		if trade.Action == "Buy" {
			netNT += int(trade.Quantity)
			log.Printf("Adding %.0f long contracts. Net position: %d → %d", trade.Quantity, oldNT, netNT)
		} else if trade.Action == "Sell" {
			netNT -= int(trade.Quantity)
			log.Printf("Adding %.0f short contracts. Net position: %d → %d", trade.Quantity, oldNT, netNT)
		}

		// No lot multiplier needed - pass through actual position size
		desiredHedgeLot := float64(netNT)
		if hedgeLot != desiredHedgeLot {
			log.Printf("=== Hedge Position Update ===")
			log.Printf("Previous hedge size: %.2f", oldHedge)
			log.Printf("New hedge size: %.2f", desiredHedgeLot)
			log.Printf("Change triggered by: %s %.2f", trade.Action, trade.Quantity)
			hedgeLot = desiredHedgeLot
		}
		queueMux.Unlock()

		log.Printf("Trade queued successfully")
		log.Printf("Current queue size: %d", len(tradeQueue))
		w.Write([]byte(`{"status":"success"}`))
	default:
		log.Printf("ERROR: Queue full, trade not processed")
		http.Error(w, "queue full", http.StatusServiceUnavailable)
	}
}

func getTradeHandler(w http.ResponseWriter, r *http.Request) {
	select {
	case trade := <-tradeQueue:
		log.Printf("=== Sending Trade to MT5 ===")
		log.Printf("ID: %s, Base ID: %s", trade.ID, trade.BaseID)
		log.Printf("Action: %s, Quantity: %.2f", trade.Action, trade.Quantity)
		log.Printf("Contract: %d of %d", trade.ContractNum, trade.TotalQuantity)
		json.NewEncoder(w).Encode(trade)
	default:
		w.Write([]byte(`{"status":"no_trade"}`))
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	queueMux.Lock()
	defer queueMux.Unlock()

	status := map[string]interface{}{
		"status":       "healthy",
		"queue_size":   len(tradeQueue),
		"net_position": netNT,
		"hedge_size":   hedgeLot,
	}

	if r.Header.Get("User-Agent") != "Mozilla/4.0" { // Skip logging for MT5's polling
		log.Printf("=== Health Check ===")
		log.Printf("Queue size: %d", len(tradeQueue))
		log.Printf("Net position: %d", netNT)
		log.Printf("Current hedge size: %.2f", hedgeLot)
	}

	json.NewEncoder(w).Encode(status)
}

func main() {
	log.Printf("=== Bridge Server Starting ===")
	log.Printf("Initial state:")
	log.Printf("Net position: %d", netNT)
	log.Printf("Hedge size: %.2f", hedgeLot)
	log.Printf("Queue size: %d", len(tradeQueue))

	http.HandleFunc("/log_trade", logTradeHandler)
	http.HandleFunc("/mt5/get_trade", getTradeHandler)
	http.HandleFunc("/health", healthHandler)

	log.Printf("Listening on 127.0.0.1:5000")
	log.Fatal(http.ListenAndServe("127.0.0.1:5000", nil))
}
