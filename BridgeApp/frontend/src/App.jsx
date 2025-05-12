import React, { useState, useEffect } from 'react';
import { EventsOn } from '../wailsjs/runtime'; // Added for Wails event handling
import './App.css';
import { GetStatus, AttemptReconnect } from '../wailsjs/go/main/App';

function App() {
  // State structure based on GetStatus return value, now includes hedgebotActive and tradeLogSenderActive
  const [bridgeStatus, setBridgeStatus] = useState({
    bridgeActive: false,
    // hedgebotActive removed - managed by isHedgeBotActive state
    tradeLogSenderActive: false, // This seems unused based on GetStatus, but keeping for now
    // hedgebotConnected removed
    addonConnected: false,    // Tracks Addon/Transmitter status from GetStatus
    netPosition: 0,
    hedgeSize: 0,
    queueSize: 0
  });

  // State specifically for HedgeBot connection status (updated by polling and events)
  const [isHedgeBotActive, setIsHedgeBotActive] = useState(false);

  // State for retry connection logic
  const [isCheckingStatus, setIsCheckingStatus] = useState(false);
  const [isReconnecting, setIsReconnecting] = useState(false);
  const [reconnectResults, setReconnectResults] = useState(null);
  const [reconnectError, setReconnectError] = useState(null);

// State for custom notification display
  const [notification, setNotification] = useState({ visible: false, message: '', type: '' });
  const fetchStatus = async () => {
    try {
      const currentStatusFromServer = await GetStatus();

      // Update general bridge status
      setBridgeStatus(prevStatus => ({
        ...prevStatus, // Keep existing state like netPosition etc.
        bridgeActive: currentStatusFromServer?.bridgeActive ?? false,
        addonConnected: currentStatusFromServer?.addonConnected ?? false, // Update addon status
        netPosition: currentStatusFromServer?.netPosition ?? 0,
        hedgeSize: currentStatusFromServer?.hedgeSize ?? 0,
        queueSize: currentStatusFromServer?.queueSize ?? 0,
        // tradeLogSenderActive: currentStatusFromServer?.tradeLogSenderActive ?? false, // Update if needed
      }));

      // Update specific HedgeBot status state based on polled data
      // This ensures the UI is correct even if the event is missed or before the first event
      setIsHedgeBotActive(currentStatusFromServer?.hedgebotActive ?? false);

    } catch (err) {
      console.error("Failed to fetch bridge status:", err);
      // Reset all status on error
      setBridgeStatus({
        bridgeActive: false,
        addonConnected: false,
        netPosition: 0,
        hedgeSize: 0,
        queueSize: 0,
        tradeLogSenderActive: false,
      });
      setIsHedgeBotActive(false); // Reset HedgeBot status on error too
    }
  };

  // Handler for Retry Connection button
  const handleRetryClick = async () => {
    console.log("Attempting to reconnect...");
    try {
        const result = await AttemptReconnect(); // Call the Go method
        console.log("AttemptReconnect direct result:", result);
        // The actual status update and notification will be driven by backend state changes and events
    } catch (error) {
        console.error("Error calling AttemptReconnect:", error);
        alert("Failed to initiate reconnection attempt: " + (error?.message || error));
    }
  };

  // Placeholder for reset function - backend needs implementation
  const handleResetClick = () => {
    console.warn("Reset functionality not implemented in the backend (app.go) yet.");
    // If ResetState function existed in Go and was bound:
    // ResetState().then(setBridgeStatus).catch(err => console.error("Failed to reset:", err));
  };

  // Fetch status on load and every 2 seconds
  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 2000);
    return () => clearInterval(interval);
  }, []);

  // Event listeners for Wails events
  useEffect(() => {
    // Listener for "addonPingSuccess"
    const handlePingSuccess = () => {
        console.log('Frontend: "addonPingSuccess" event received. Showing alert.');
        alert("Ping received from transmitter!");
    };
    EventsOn("addonPingSuccess", handlePingSuccess); // Keep existing listener

    // Listener for "addonRetryResult" - Keep existing listener
    const handleAddonRetryResult = (data) => {
        console.log("Frontend: 'addonRetryResult' event received:", data);
        if (data && data.message) {
            alert(data.message);
        } else {
            alert("Received an addon reconnection result, but no message was provided.");
        }
    };
    EventsOn("addonRetryResult", handleAddonRetryResult);

    // Cleanup function for listeners
    // Wails v2 EventsOn listeners are generally managed by Wails and cleaned up on app close.
    // If specific cleanup (e.g., EventsOff) were required per listener, it would go here.
    return () => {
        // console.log("Cleaning up Wails event listeners."); // Optional for debugging
    };
  }, []); // Empty dependency array means this effect runs once on mount

  // NEW: Effect hook specifically for HedgeBot status event
  useEffect(() => {
    const handleHedgeBotStatusChange = (eventData) => {
      console.log("Frontend: 'hedgebotStatusChanged' event received:", eventData);
      if (eventData && typeof eventData.active === 'boolean') {
        setIsHedgeBotActive(eventData.active);
        if (eventData.active) {
          // Show notification only when it becomes active
          showNotification("HedgeBot connected", "success");
        }
        // Note: As per requirements, we don't show a notification or change status
        // back to inactive based on events alone. That would require a manual action.
      }
    };

    EventsOn("hedgebotStatusChanged", handleHedgeBotStatusChange);

    // Cleanup function for this specific listener if needed, though Wails usually handles it.
    return () => {
      // console.log("Cleaning up hedgebotStatusChanged listener.");
      // Potentially call EventsOff("hedgebotStatusChanged", handleHedgeBotStatusChange) if manual cleanup is desired.
    };
  }, []); // Runs once on mount

  // Helper to get status display text and class
  const getStatusDisplay = (isActive) => {
    return isActive
      ? { text: 'Active', className: 'healthy' }
      : { text: 'False', className: 'disconnected' }; // Capitalized 'False'
  };

  const bridgeDisplay = getStatusDisplay(bridgeStatus.bridgeActive);
  const hedgebotDisplay = getStatusDisplay(isHedgeBotActive); // Use the dedicated state
  const tradeLogSenderDisplay = getStatusDisplay(bridgeStatus.addonConnected); // Use addonConnected from bridgeStatus

// Helper function to show a notification
  const showNotification = (message, type = 'info', duration = 3000) => {
    setNotification({ visible: true, message, type });
    setTimeout(() => {
      setNotification({ visible: false, message: '', type: '' });
    }, duration);
  };
  return (
    <div className="container">
       {/* Notification Area */}
       {notification.visible && (
        <div className={`notification ${notification.type} ${notification.visible ? 'show' : ''}`}>
          {notification.message}
        </div>
      )}

      <h1>Bridge Controller</h1>
      <div className="card">
        {/* Status Lines */}
        <div className="status-lines">
          <div className="status-item">
            <span className="status-label">Bridge Status:</span>
            <span className={`status-value ${bridgeDisplay.className}`}>{bridgeDisplay.text}</span>
          </div>
          <div className="status-item">
            <span className="status-label">Hedgebot Status:</span>
            <span className={`status-value ${hedgebotDisplay.className}`}>{hedgebotDisplay.text}</span>
          </div>
          <div className="status-item">
            <span className="status-label">Transmitter Status:</span> {/* Renamed */}
            <span className={`status-value ${tradeLogSenderDisplay.className}`}>{tradeLogSenderDisplay.text}</span>
          </div>
        </div>

        {/* State Info */}
        <div className="state-info">
          <div className="state-item">
            <label>Net Position:</label>
            <span>{bridgeStatus.netPosition}</span>
          </div>
          <div className="state-item">
            <label>Hedge Size:</label>
            <span>{bridgeStatus.hedgeSize?.toFixed(2) || "0.00"}</span>
          </div>
          <div className="state-item">
            <label>Queue Size:</label>
            <span>{bridgeStatus.queueSize}</span>
          </div>
        </div>

        {/* Reset Button */}
        <button className="reset-btn" onClick={handleResetClick}>
          Reset Bridge State
        </button>
        {/* Retry Button */}
        <button className="retry-btn" onClick={handleRetryClick}>
          Retry Connection
        </button>

        {/* Feedback UI for Retry Connection */}
        <div className="retry-feedback" style={{ marginTop: '16px' }}>
          {isCheckingStatus && (
            <div className="retry-status-msg">Checking connection status...</div>
          )}
          {isReconnecting && (
            <div className="retry-status-msg">Attempting reconnect...</div>
          )}
          {reconnectError && (
            <div className="retry-error" style={{ color: 'red' }}>{reconnectError}</div>
          )}
        </div>
      </div>
    </div>
  );
}

export default App;
