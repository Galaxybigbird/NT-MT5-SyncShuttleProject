#region Using declarations
// Core .NET libraries for HTTP communication and text handling
using System;
using System.Net.Http;
using System.Text;
using System.Collections.Generic;
using System.Linq;  // Add this for FirstOrDefault
using System.Threading.Tasks;

// NinjaTrader specific imports for trading functionality
using NinjaTrader.Cbi;              // Core Business Intelligence
using NinjaTrader.Gui;             // GUI components
using NinjaTrader.Gui.Chart;       // Charting components
using NinjaTrader.Data;            // Data handling
using NinjaTrader.NinjaScript;     // NinjaScript base functionality
using NinjaTrader.Core.FloatingPoint; // Floating point operations
using System.ComponentModel;        // Component model for properties
using System.ComponentModel.DataAnnotations; // Data annotations
using System.Windows.Media;         // WPF media functionality
using System.Windows;               // WPF core
using NinjaTrader.Gui.Tools;       // NinjaTrader tools
using NinjaTrader.NinjaScript.DrawingTools; // Drawing tools for charts
#endregion

namespace NinjaTrader.NinjaScript.Indicators
{
    // Class to track individual trade positions
    public class TradePosition
    {
        public string TradeId { get; set; }  // Base trade ID
        public string OrderId { get; set; }  // Individual order ID (entry, TP, or SL)
        public string OrderType { get; set; } // "ENTRY", "TP", or "SL"
        public string Instrument { get; set; }
        public OrderAction Action { get; set; }
        public double Quantity { get; set; }
        public double Price { get; set; }
        public DateTime EntryTime { get; set; }
        public double? RulerMeasurement { get; set; } // Store ruler measurement if applicable
        public double AccumulatedQuantity { get; set; } // Track accumulated quantity for partial fills
        public string OrderName { get; set; } // Store the original order name
    }

    // Main indicator class that logs trade executions to a Python server
    public class TradeLoggerIndicator : Indicator
    {
        // Private member variables
        private Account selectedAccount;           // Currently selected trading account
        private bool statusTextDrawn;             // Flag to track if status text is drawn on chart
        private readonly HttpClient httpClient;    // HTTP client for API communication
        private Dictionary<string, List<TradePosition>> activePositions = new Dictionary<string, List<TradePosition>>(); // Tracks active positions by instrument
        private Dictionary<string, Ruler> _activeRulers = new Dictionary<string, Ruler>();
        private Dictionary<string, TradePosition> _activeTrades = new Dictionary<string, TradePosition>();
        private Dictionary<string, TradePosition> partialFills = new Dictionary<string, TradePosition>();

        // Constructor initializes the HTTP client
        public TradeLoggerIndicator()
        {
            httpClient = new HttpClient();
        }

        // Account name storage
        private string accountName = string.Empty;
        
        // Property for account selection in the indicator settings
        [NinjaScriptProperty]
        [Display(Name = "Account", GroupName = "Parameters", Order = 0)]
        [TypeConverter(typeof(AccountNameConverter))]
        public string AccountName
        { 
            get { return accountName; }
            set
            {
                accountName = value;
                // Only process during setup phases
                if (State == State.SetDefaults || State == State.Configure)
                {
                    // Find and set the selected account object
                    if (Account.All != null)
                    {
                        foreach (Account acc in Account.All)
                        {
                            if (acc.Name == value)
                            {
                                selectedAccount = acc;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Custom converter class to provide account selection dropdown
        public class AccountNameConverter : TypeConverter
        {
            // Returns list of available account names
            public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext context)
            {
                List<string> accountNames = new List<string>();
                if (Account.All != null)
                {
                    foreach (Account account in Account.All)
                    {
                        // Only add accounts that are connected/active
                        if (account.Connection != null && account.Connection.Status == ConnectionStatus.Connected)
                        {
                            accountNames.Add(account.Name);
                        }
                    }
                }
                return new StandardValuesCollection(accountNames);
            }

            // Enable dropdown list
            public override bool GetStandardValuesSupported(ITypeDescriptorContext context)
            {
                return true;
            }

            // Make dropdown list exclusive (no manual entry)
            public override bool GetStandardValuesExclusive(ITypeDescriptorContext context)
            {
                return true;
            }
        }

        // Property for Go bridge server URL configuration
        [NinjaScriptProperty]
        [Display(Name = "Bridge Server URL", GroupName = "Parameters", Order = 1)]
        public string BridgeServerUrl { get; set; } = "http://127.0.0.1:5000/log_trade";

        [NinjaScriptProperty]
        [Display(Name = "Auto Measure TP/SL", GroupName = "Parameters", Order = 2)]
        public bool AutoMeasureTPSL { get; set; } = true;

        // Handles state changes in the indicator lifecycle
        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                // Initialize default settings
                Description = "Logs executed trades and measures TP/SL distances using rulers";
                Name = "TradeLoggerIndicator";
                IsOverlay = true;
            }
            else if (State == State.Configure)
            {
                // Force clear and print debug info
                ClearOutputWindow();
                Print("====== TradeLoggerIndicator Debug Info ======");
                Print($"Current State: {State}");
                Print($"Selected Account: '{AccountName}'");
                Print("Available accounts:");
                
                bool foundAny = false;
                // List all connected accounts
                foreach (Account acc in Account.All)
                {
                    // Only check connected/active accounts
                    if (acc.Connection != null && acc.Connection.Status == ConnectionStatus.Connected)
                    {
                        foundAny = true;
                        Print($"- Account Name: '{acc.Name}'");
                        if (acc.Name == AccountName)
                        {
                            selectedAccount = acc;
                            Print($"Found matching account: '{acc.Name}'");
                        }
                    }
                }
                
                // Warning if no accounts found
                if (!foundAny)
                {
                    Print("WARNING: No connected accounts found!");
                }

                // Error if selected account not found
                if (selectedAccount == null)
                {
                    Print($"ERROR: Account '{AccountName}' not found in available accounts!");
                    return;
                }

                Print($"Python Server URL: {BridgeServerUrl}");
                Print("=======================================");

                // Subscribe to execution updates
                selectedAccount.ExecutionUpdate += OnExecutionUpdate;
            }
            else if (State == State.DataLoaded)
            {
                Print("TradeLoggerIndicator: Data Loaded");
            }
            else if (State == State.Historical)
            {
                Print("TradeLoggerIndicator: Historical data processing");
            }
            else if (State == State.Realtime)
            {
                Print("TradeLoggerIndicator: Entering Realtime mode");
            }
            else if (State == State.Terminated)
            {
                // Cleanup on termination
                Print("TradeLoggerIndicator: Terminating");
                if (selectedAccount != null)
                {
                    selectedAccount.ExecutionUpdate -= OnExecutionUpdate;
                }
                if (httpClient != null)
                {
                    httpClient.Dispose();
                }
            }
        }

        // Called on each bar update
        protected override void OnBarUpdate()
        {
            // Check for measurements in realtime
            if (State == State.Realtime)
            {
                foreach (var trade in _activeTrades.Values)
                {
                    if (trade.OrderType != "ENTRY")
                    {
                        double currentPrice = Close[0];
                        double measurement = Math.Abs(currentPrice - trade.Price);
                        ProcessRulerMeasurement(trade.OrderId, measurement);
                        
                        // Update measurement display
                        Draw.TextFixed(this, "Measurement_" + trade.OrderId, 
                            $"{measurement:F1} points from {trade.OrderType}", 
                            TextPosition.TopRight,
                            Brushes.Yellow,
                            new SimpleFont("Arial", 10),
                            Brushes.Transparent,
                            Brushes.Black,
                            30);
                    }
                }
            }

            if (State == State.Realtime && !statusTextDrawn)
            {
                // Draw status text at the top-right of the chart
                Draw.TextFixed(this, "StatusText", "Trade Logger Active", 
                    TextPosition.TopRight,
                    Brushes.LimeGreen,
                    new NinjaTrader.Gui.Tools.SimpleFont("Arial", 12),
                    Brushes.Transparent,
                    Brushes.Transparent,
                    0);
                
                statusTextDrawn = true;
                // Output status information
                Print("====== TradeLoggerIndicator Status ======");
                Print($"Account being monitored: '{AccountName}'");
                Print($"Instrument being monitored: {Instrument.FullName}");
                Print($"Bridge Server URL: {BridgeServerUrl}");
                Print("Trade Logger Indicator started and ready to monitor trades.");
                Print("=========================================");
            }
        }

        private string GenerateTradeId()
        {
            // Generate a unique base trade ID using timestamp and random number
            Random random = new Random();  // Create Random instance here
            return DateTime.UtcNow.Ticks.ToString("x") + "_" + random.Next(1000, 9999).ToString();
        }

        private void ProcessRulerMeasurement(string orderId, double measurement)
        {
            if (!_activeTrades.ContainsKey(orderId)) return;

            var trade = _activeTrades[orderId];
            trade.RulerMeasurement = Math.Abs(measurement);

            // Convert measurement to pips (first 3 digits rounded to nearest 10)
            int pips = (int)(Math.Round(trade.RulerMeasurement.Value * 100) / 10) * 10;

            // Update trade data with measurement
            var tradeData = new Dictionary<string, object>
            {
                { "id", trade.OrderId },
                { "base_id", trade.TradeId },
                { "order_type", trade.OrderType },
                { "measurement_pips", pips },
                { "raw_measurement", trade.RulerMeasurement.Value },
                { "time", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
            };

            // Send measurement to bridge
            SendToBridge(tradeData);
        }

        private void SendToBridge(Dictionary<string, object> data)
        {
            try
            {
                string jsonData = SimpleJson.SerializeObject(data);
                Print($"Sending measurement data: {jsonData}");

                var content = new StringContent(jsonData, Encoding.UTF8, "application/json");
                var response = httpClient.PostAsync(BridgeServerUrl, content).Result;

                if (response.IsSuccessStatusCode)
                {
                    Print($"Measurement logged successfully for Order ID: {data["id"]}");
                }
                else
                {
                    Print($"Error logging measurement: {response.StatusCode} - {response.ReasonPhrase}");
                }
            }
            catch (Exception ex)
            {
                Print($"Error sending measurement data: {ex.Message}");
            }
        }

        private void OnRulerChanged(object sender, EventArgs e)
        {
            if (!AutoMeasureTPSL) return;

            var ruler = sender as Ruler;
            if (ruler == null) return;

            string orderId = ruler.Tag as string;
            if (string.IsNullOrEmpty(orderId)) return;

            double measurement = ruler.EndAnchor.Price - ruler.StartAnchor.Price;
            ProcessRulerMeasurement(orderId, measurement);
        }

        // Handles trade execution updates
        private async void OnExecutionUpdate(object sender, ExecutionEventArgs e)
        {
            // Debug output for execution details
            Print($"====== Execution Update Received ======");
            Print($"Execution Account: {e.Execution.Account.Name}");
            Print($"Execution Instrument: {e.Execution.Instrument.FullName}");
            Print($"Current Instrument: {Instrument.FullName}");
            Print($"Order State: {e.Execution.Order.OrderState}");
            Print($"Order Action: {e.Execution.Order.OrderAction}");
            Print($"Order Quantity: {e.Execution.Quantity}");
            Print($"Order Price: {e.Execution.Price}");

            // Skip if execution is for a different instrument
            if (e.Execution.Instrument.FullName != Instrument.FullName)
            {
                Print("Skipping - different instrument");
                return;
            }

            // Handle partial fills and completed orders
            string orderKey = e.Execution.Order.Id.ToString();

            if (e.Execution.Order.OrderState == OrderState.PartFilled || e.Execution.Order.OrderState == OrderState.Filled)
            {
                if (!partialFills.ContainsKey(orderKey))
                {
                    string baseTradeId = null;
                
                    // Try to extract base trade ID from order name/comment
                    if (!string.IsNullOrEmpty(e.Execution.Order.Name))
                    {
                        if (e.Execution.Order.Name.StartsWith("ENTRY_"))
                        {
                            baseTradeId = e.Execution.Order.Name;
                        }
                        else if (e.Execution.Order.Name.Contains("_SL") || e.Execution.Order.Name.Contains("_TP"))
                        {
                            baseTradeId = e.Execution.Order.Name.Split('_')[0];
                        }
                    }

                    // If no base ID found, generate new one
                    if (baseTradeId == null)
                    {
                        baseTradeId = GenerateTradeId();
                    }

                    string orderType = "ENTRY";
                    if (e.Execution.Order.Name?.Contains("_SL") == true)
                        orderType = "SL";
                    else if (e.Execution.Order.Name?.Contains("_TP") == true)
                        orderType = "TP";

                    partialFills[orderKey] = new TradePosition
                    {
                        TradeId = baseTradeId,
                        OrderId = e.Execution.Order.Name ?? $"{baseTradeId}_{orderType}",
                        OrderType = orderType,
                        Instrument = e.Execution.Instrument.FullName,
                        Action = e.Execution.Order.OrderAction,
                        Quantity = e.Execution.Order.Quantity, // Total quantity expected
                        Price = e.Execution.Price,
                        EntryTime = e.Execution.Time,
                        AccumulatedQuantity = e.Execution.Quantity, // Current execution quantity
                        OrderName = e.Execution.Order.Name
                    };
                }
                else
                {
                    // Update accumulated quantity and average price
                    var position = partialFills[orderKey];
                    position.AccumulatedQuantity += e.Execution.Quantity;
                    position.Price = ((position.Price * (position.AccumulatedQuantity - e.Execution.Quantity)) + 
                                    (e.Execution.Price * e.Execution.Quantity)) / position.AccumulatedQuantity;
                }

                // Only process complete fills
                if (e.Execution.Order.OrderState == OrderState.Filled)
                {
                    var completedPosition = partialFills[orderKey];
                    
                    // For multi-contract trades, we'll send one message per contract
                    int numContracts = (int)completedPosition.AccumulatedQuantity;
                    Print($"Processing {numContracts} contract(s)");

                    for (int i = 0; i < numContracts; i++)
                    {
                        string tradeId = numContracts > 1 ? $"{completedPosition.TradeId}_{i + 1}" : completedPosition.TradeId;
                        Print($"Processing contract {i + 1} with Trade ID: {tradeId}");

                        // Create trade data object
                        var tradeData = new Dictionary<string, object>
                        {
                            { "id", tradeId },
                            { "base_id", completedPosition.TradeId },
                            { "action", completedPosition.Action.ToString() },
                            { "quantity", 1.0 },
                            { "price", completedPosition.Price },
                            { "total_quantity", numContracts },
                            { "contract_num", i + 1 }
                        };

                        try
                        {
                            string jsonData = SimpleJson.SerializeObject(tradeData);
                            Print($"Sending trade data: {jsonData}");

                            var content = new StringContent(jsonData, Encoding.UTF8, "application/json");
                            var response = await httpClient.PostAsync(BridgeServerUrl, content);

                            if (response.IsSuccessStatusCode)
                            {
                                Print($"Trade logged successfully. Trade ID: {tradeId}");
                            }
                            else
                            {
                                Print($"Error logging trade: {response.StatusCode} - {response.ReasonPhrase}");
                            }
                        }
                        catch (Exception ex)
                        {
                            Print($"Error sending trade data: {ex.Message}");
                        }
                    }

                    // Remove the completed order from tracking
                    partialFills.Remove(orderKey);
                }
                else
                {
                    Print($"Skipping - partial fill accumulated: {partialFills[orderKey].AccumulatedQuantity}");
                }
            }
            Print("======================================");
        }

        // Determines if an execution is closing an existing position
        private bool IsExitForPosition(ExecutionEventArgs e)
        {
            string instrumentKey = e.Execution.Instrument.FullName;
            
            // Initialize position tracking if not already done
            if (!activePositions.ContainsKey(instrumentKey))
            {
                activePositions[instrumentKey] = new List<TradePosition>();
                return false;
            }

            var positions = activePositions[instrumentKey];
            
            // Check if this execution closes any specific position
            if (e.Execution.Order.OrderAction == OrderAction.Buy)
            {
                // Look for matching short positions to close
                var matchingPosition = positions.FirstOrDefault(p => 
                    p.Action == OrderAction.Sell && 
                    p.Quantity == e.Execution.Quantity);
                    
                if (matchingPosition != null)
                {
                    positions.Remove(matchingPosition);
                    return true;
                }
            }
            else if (e.Execution.Order.OrderAction == OrderAction.Sell)
            {
                // Look for matching long positions to close
                var matchingPosition = positions.FirstOrDefault(p => 
                    p.Action == OrderAction.Buy && 
                    p.Quantity == e.Execution.Quantity);
                    
                if (matchingPosition != null)
                {
                    positions.Remove(matchingPosition);
                    return true;
                }
            }

            // Add new position if not closing existing one
            positions.Add(new TradePosition
            {
                OrderId = e.Execution.Order.Id.ToString(),
                Instrument = e.Execution.Instrument.FullName,
                Action = e.Execution.Order.OrderAction,
                Quantity = e.Execution.Quantity,
                Price = e.Execution.Price,
                EntryTime = e.Execution.Time
            });
            
            return false;
        }
    }

    // Simple JSON serializer implementation to avoid external dependencies
    internal static class SimpleJson
    {
        // Serializes an object to JSON string
        public static string SerializeObject(object obj)
        {
            if (obj == null) return "null";
            
            // Handle Dictionary<string, object> specially
            if (obj is Dictionary<string, object> dict)
            {
                var pairs = new List<string>();
                foreach (var kvp in dict)
                {
                    var serializedValue = SerializeValue(kvp.Value);
                    pairs.Add($"\"{kvp.Key}\":{serializedValue}");
                }
                return "{" + string.Join(",", pairs) + "}";
            }
            
            // Handle regular objects
            var properties = obj.GetType().GetProperties();
            var jsonPairs = new string[properties.Length];
            
            for (int i = 0; i < properties.Length; i++)
            {
                var prop = properties[i];
                var value = prop.GetValue(obj);
                var serializedValue = SerializeValue(value);
                jsonPairs[i] = $"\"{prop.Name.ToLower()}\":{serializedValue}";
            }
            
            return "{" + string.Join(",", jsonPairs) + "}";
        }

        // Helper method to serialize different value types
        private static string SerializeValue(object value)
        {
            if (value == null) return "null";
            if (value is string) return $"\"{value}\"";
            if (value is bool) return value.ToString().ToLower();
            if (value is DateTime dt) return $"\"{dt:o}\"";
            if (value is int || value is long || value is float || value is double) return value.ToString();
            if (value is Dictionary<string, object>) return SerializeObject(value);
            if (value.GetType().IsValueType) return value.ToString();
            return SerializeObject(value);
        }
    }
}

#region NinjaScript generated code. Neither change nor remove.

namespace NinjaTrader.NinjaScript.Indicators
{
	public partial class Indicator : NinjaTrader.Gui.NinjaScript.IndicatorRenderBase
	{
		private TradeLoggerIndicator[] cacheTradeLoggerIndicator;
		public TradeLoggerIndicator TradeLoggerIndicator(string accountName, string bridgeServerUrl)
		{
			return TradeLoggerIndicator(Input, accountName, bridgeServerUrl);
		}

		public TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input, string accountName, string bridgeServerUrl)
		{
			if (cacheTradeLoggerIndicator != null)
				for (int idx = 0; idx < cacheTradeLoggerIndicator.Length; idx++)
					if (cacheTradeLoggerIndicator[idx] != null && cacheTradeLoggerIndicator[idx].AccountName == accountName && cacheTradeLoggerIndicator[idx].BridgeServerUrl == bridgeServerUrl && cacheTradeLoggerIndicator[idx].EqualsInput(input))
						return cacheTradeLoggerIndicator[idx];
			return CacheIndicator<TradeLoggerIndicator>(new TradeLoggerIndicator(){ AccountName = accountName, BridgeServerUrl = bridgeServerUrl }, input, ref cacheTradeLoggerIndicator);
		}
	}
}

namespace NinjaTrader.NinjaScript.MarketAnalyzerColumns
{
	public partial class MarketAnalyzerColumn : MarketAnalyzerColumnBase
	{
		public Indicators.TradeLoggerIndicator TradeLoggerIndicator(string accountName, string bridgeServerUrl)
		{
			return indicator.TradeLoggerIndicator(Input, accountName, bridgeServerUrl);
		}

		public Indicators.TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input , string accountName, string bridgeServerUrl)
		{
			return indicator.TradeLoggerIndicator(input, accountName, bridgeServerUrl);
		}
	}
}

namespace NinjaTrader.NinjaScript.Strategies
{
	public partial class Strategy : NinjaTrader.Gui.NinjaScript.StrategyRenderBase
	{
		public Indicators.TradeLoggerIndicator TradeLoggerIndicator(string accountName, string bridgeServerUrl)
		{
			return indicator.TradeLoggerIndicator(Input, accountName, bridgeServerUrl);
		}

		public Indicators.TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input , string accountName, string bridgeServerUrl)
		{
			return indicator.TradeLoggerIndicator(input, accountName, bridgeServerUrl);
		}
	}
}

#endregion
