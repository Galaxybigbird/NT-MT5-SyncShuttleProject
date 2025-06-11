#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Globalization; // For number formatting
using System.Linq;
using System.Windows.Threading;
using NinjaTrader.Cbi; // For Account
using NinjaTrader.Gui;
using NinjaTrader.Gui.Tools;
using NinjaTrader.NinjaScript;
using NinjaTrader.Core;
using System.Threading;
using System.Diagnostics;
using NinjaTrader.Data;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Net; // Required for HttpListener
using System.IO; // Required for StreamReader
using System.Collections.Concurrent; // Added for ConcurrentDictionary
using NinjaTrader.NinjaScript.AddOns.MultiStratManagerLogic; // Added for SLTPRemovalLogic
#endregion

namespace NinjaTrader.NinjaScript.AddOns
{
    /// <summary>
    /// Multi-Strategy Manager for hedging and managing multiple trading strategies
    /// </summary>
    public class MultiStratManager : NinjaTrader.NinjaScript.AddOnBase, INotifyPropertyChanged
    {
        private static UIForManager window;
        private bool isFirstRun = true;
        private System.Windows.Threading.DispatcherTimer autoLaunchTimer;

        public static MultiStratManager Instance { get; private set; }
        public event Action PingReceivedFromBridge;

        private SLTPRemovalLogic sltpRemovalLogic;

        // Properties for SLTP Removal Logic
        public bool EnableSLTPRemoval { get; set; } = true; // Default to true
        public int SLTPRemovalDelaySeconds { get; set; } = 3; // Default to 3 seconds

        #region PnL Properties and INotifyPropertyChanged

        private double _realizedPnL;
        public double RealizedPnL
        {
            get { return _realizedPnL; }
            private set
            {
                if (_realizedPnL != value)
                {
                    _realizedPnL = value;
                    OnPropertyChanged(nameof(RealizedPnL));
                    UpdateTotalPnL();
                }
            }
        }

        private double _unrealizedPnL;
        public double UnrealizedPnL
        {
            get { return _unrealizedPnL; }
            private set
            {
                if (_unrealizedPnL != value)
                {
                    _unrealizedPnL = value;
                    OnPropertyChanged(nameof(UnrealizedPnL));
                    UpdateTotalPnL();
                }
            }
        }

        private double _totalPnL;
        public double TotalPnL
        {
            get { return _totalPnL; }
            private set
            {
                if (_totalPnL != value)
                {
                    _totalPnL = value;
                    OnPropertyChanged(nameof(TotalPnL));
                }
            }
        }

        private void UpdateTotalPnL()
        {
            TotalPnL = RealizedPnL + UnrealizedPnL;
        }

        // NT Performance Tracking for Elastic Hedging
        private double _sessionStartBalance = 0.0;
        private double _dailyStartPnL = 0.0;
        private DateTime _sessionStartTime = DateTime.MinValue;
        private int _sessionTradeCount = 0;
        private string _lastTradeResult = "";
        private double _lastTradePnL = 0.0;

        public double SessionStartBalance
        {
            get { return _sessionStartBalance; }
            private set { _sessionStartBalance = value; }
        }

        public double DailyPnL
        {
            get { return TotalPnL - _dailyStartPnL; }
        }

        public int SessionTradeCount
        {
            get { return _sessionTradeCount; }
            private set { _sessionTradeCount = value; }
        }

        public string LastTradeResult
        {
            get { return _lastTradeResult; }
            private set { _lastTradeResult = value; }
        }

        // Initialize session tracking (call when addon starts or new day begins)
        private void InitializeSessionTracking()
        {
            if (monitoredAccount != null)
            {
                _sessionStartTime = DateTime.Now;
                _dailyStartPnL = TotalPnL;
                _sessionTradeCount = 0;
                _lastTradeResult = "";
                _lastTradePnL = 0.0;

                // Get current account balance
                var balanceItem = monitoredAccount.GetAccountItem(Cbi.AccountItem.CashValue, Currency.UsDollar);
                if (balanceItem != null && balanceItem.Value is double)
                {
                    _sessionStartBalance = (double)balanceItem.Value;
                }

                LogAndPrint($"Session tracking initialized: Balance=${_sessionStartBalance:F2}, StartPnL=${_dailyStartPnL:F2}");
            }
        }

        // Update trade result based on execution
        private void UpdateTradeResult(ExecutionEventArgs e)
        {
            if (e.Execution.Order.OrderAction == OrderAction.Buy || e.Execution.Order.OrderAction == OrderAction.Sell)
            {
                _sessionTradeCount++;

                // Calculate P&L for this trade (simplified - actual P&L calculation may be more complex)
                double tradePnL = 0.0;

                // For closing trades, we can estimate P&L
                if (e.Execution.Order.OrderAction == OrderAction.BuyToCover || e.Execution.Order.OrderAction == OrderAction.SellShort)
                {
                    // This is a closing trade - determine if win/loss
                    // Note: This is a simplified approach. Real P&L tracking would require position tracking
                    double currentPnL = TotalPnL;
                    tradePnL = currentPnL - _lastTradePnL;
                    _lastTradePnL = currentPnL;

                    _lastTradeResult = tradePnL > 0 ? "win" : "loss";
                    LogAndPrint($"Trade result updated: {_lastTradeResult} (P&L: ${tradePnL:F2})");
                }
                else
                {
                    // Opening trade - set baseline
                    _lastTradePnL = TotalPnL;
                    _lastTradeResult = "pending";
                }
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;

        protected virtual void OnPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        #endregion
        
        // New menu items for Control Center integration
        private NTMenuItem multiStratMenuItem;
        private MenuItem existingMenuItemInControlCenter; // Changed type from NTMenuItem

        private static List<StrategyBase> monitoredStrategies = new List<StrategyBase>();

        private static readonly HttpClient httpClient = new HttpClient();
        private string bridgeServerUrl = "http://127.0.0.1:5000"; // Default base URL, will be updated later
        private Account monitoredAccount = null; // To keep track of the account being monitored

        // HTTP Listener Fields
        private HttpListener httpListener;
        private Thread listenerThread;
        private volatile bool isListenerRunning = false; // volatile for thread safety
        private const string PingPath = "/ping_msm";
        private const int ListenerPort = 8081;
        private const string NotifyHedgeClosedPath = "/notify_hedge_closed";

        // Class to store original NT trade details
        public class OriginalTradeDetails // Renamed from OriginalNtTradeInfo
        {
            public string BaseId { get; set; }
            public MarketPosition MarketPosition { get; set; } // Renamed from OriginalMarketPosition
            public int Quantity { get; set; } // Renamed from OriginalQuantity
            public double Price { get; set; }
            public string NtInstrumentSymbol { get; set; }
            public string NtAccountName { get; set; }
            public OrderAction OriginalOrderAction { get; set; } // Kept this field
            public DateTime Timestamp { get; set; }

            // MULTI_TRADE_GROUP_FIX: Track total and remaining quantity for this BaseID
            public int TotalQuantity { get; set; } = 0; // Total quantity for this BaseID
            public int RemainingQuantity { get; set; } = 0; // Remaining quantity not yet closed
        }

        // Dictionary to store active NT trades by their base_id (OrderId)
        private static ConcurrentDictionary<string, OriginalTradeDetails> activeNtTrades = new ConcurrentDictionary<string, OriginalTradeDetails>(); // Updated type
        private readonly object _activeNtTradesLock = new object(); // Added lock object

        // Class to represent the JSON payload for hedge close notifications
        public class HedgeCloseNotification
        {
            public string event_type { get; set; }
            public string base_id { get; set; }
            public string nt_instrument_symbol { get; set; }
            public string nt_account_name { get; set; }
            public double closed_hedge_quantity { get; set; }
            public string closed_hedge_action { get; set; } // "Buy" or "Sell"
            public string timestamp { get; set; }
            public string ClosureReason { get; set; } // Added for MT5 EA closure reason
        }
private HashSet<string> trackedHedgeClosingOrderIds;

        private void LogAndPrint(string message)
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager] {message}", PrintTo.OutputTab1);
        }

        private void LogForSLTP(string message, LogLevel level)
        {
            // NinjaTrader.Code.Output.Process can take a PrintTo argument, but not directly a LogLevel.
            // We'll map LogLevel to different PrintTo targets or prefixes if needed,
            // or simply log it with a level indicator.
            // For now, SLTPRemovalLogic already prefixes its messages.
            NinjaTrader.Code.Output.Process($"[MultiStratManager-SLTP:{level}] {message}", PrintTo.OutputTab1);
        }
 
        /// <summary>
        /// Standard constructor - required for NinjaTrader add-on registration
        /// </summary>
        public MultiStratManager()
        {
            NinjaTrader.Code.Output.Process("MultiStratManager constructor called", PrintTo.OutputTab1);
        }

        /// <summary>
        /// Constructor with command parameter - called when the menu item is clicked
        /// </summary>
        /// <param name="command">Command to execute</param>
        public MultiStratManager(string command)
        {
            NinjaTrader.Code.Output.Process(string.Format("MultiStratManager constructor with command '{0}' called", command), PrintTo.OutputTab1);
            if (command == "ShowWindow")
            {
                NinjaTrader.Code.Output.Process("ShowWindow command received", PrintTo.OutputTab1);
                ShowWindow();
            }
        }

        /// <summary>
        /// Handles state changes in the add-on lifecycle
        /// </summary>
        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager SetDefaults", PrintTo.OutputTab1);
                Description = "Multi-Strategy Manager for hedging";
                Name = "Multi-Strategy Manager";
                Instance = this;
                trackedHedgeClosingOrderIds = new HashSet<string>();
                sltpRemovalLogic = new SLTPRemovalLogic(LogForSLTP);
                // Other default settings can be initialized here
            }
            else if (State == State.Configure)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager Configure", PrintTo.OutputTab1);
                // Menu integration is now handled in OnWindowCreated/OnWindowDestroyed
                StartHttpListener();
            }
            else if (State == State.Active)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager Active", PrintTo.OutputTab1);
                if (isFirstRun)
                {
                    isFirstRun = false;
                    StartAutoLaunchTimer();
                }
            }
            else if (State == State.Terminated)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager Terminated", PrintTo.OutputTab1);
                StopHttpListener();
                StopAutoLaunchTimer();
                sltpRemovalLogic?.Cleanup(); // Cleanup SLTP logic
                SetMonitoredAccount(null); // ADDED FOR CLEANUP
                Instance = null;
                if (window != null)
                {
                    // Close the window if still open when NinjaTrader is shutting down
                    window.Dispatcher.BeginInvoke(new Action(delegate() { window.Close(); }));
                }
            }
            // State.Terminated already handles StopHttpListener.
            // The State enum does not have a 'Disabled' member in this context.
            // If runtime disabling requires specific cleanup beyond what State.Inactive or State.Terminated provide,
            // a different approach would be needed. For now, removing this erroneous check.
        }
        
        /// <summary>
        /// Shows the Multi-Strategy Manager window
        /// </summary>
        public void ShowWindow()
        {
            try
            {
                NinjaTrader.Code.Output.Process("ShowWindow called", PrintTo.OutputTab1);
                
                // We need to ensure we create and show the window on the UI thread
                // Using Application.Current.Dispatcher ensures we're on the main UI thread
                Application.Current.Dispatcher.Invoke(new Action(delegate()
                {
                    try
                    {
                        if (window == null)
                        {
                            NinjaTrader.Code.Output.Process("Creating new window", PrintTo.OutputTab1);
                            window = new UIForManager();
                            
                            // Handle window closed event
                            window.Closed += new EventHandler(delegate(object o, EventArgs e)
                            {
                                NinjaTrader.Code.Output.Process("Window closed", PrintTo.OutputTab1);
                                window = null;
                            });
                            
                            // Handle window loaded event to ensure content is visible
                            window.Loaded += new RoutedEventHandler(delegate(object o, RoutedEventArgs e)
                            {
                                NinjaTrader.Code.Output.Process("Window loaded", PrintTo.OutputTab1);
                                // Force layout update after window is loaded
                                window.UpdateLayout();
                            });
                        }

                        // Ensure the window is visible
                        if (!window.IsVisible)
                        {
                            NinjaTrader.Code.Output.Process("Showing window", PrintTo.OutputTab1);
                            window.Show();
                            window.Activate();
                            window.Focus();
                            
                            // Force layout update
                            window.UpdateLayout();
                        }
                        else
                        {
                            NinjaTrader.Code.Output.Process("Window already visible, bringing to front", PrintTo.OutputTab1);
                            window.WindowState = WindowState.Normal;
                            window.Activate();
                            window.Focus();
                            
                            // Force layout update
                            window.UpdateLayout();
                        }
                    }
                    catch (Exception innerEx)
                    {
                        NinjaTrader.Code.Output.Process(string.Format("ERROR in ShowWindow UI thread: {0}\n{1}", innerEx.Message, innerEx.StackTrace), PrintTo.OutputTab1);
                    }
                }));
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in ShowWindow: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }
        
        private void StartAutoLaunchTimer()
        {
            try
            {
                autoLaunchTimer = new System.Windows.Threading.DispatcherTimer();
                autoLaunchTimer.Interval = TimeSpan.FromSeconds(5);
                autoLaunchTimer.Tick += new EventHandler(OnAutoLaunchTimerTick);
                autoLaunchTimer.Start();
                NinjaTrader.Code.Output.Process("Auto launch timer started", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR starting auto launch timer: {0}", ex.Message), PrintTo.OutputTab1);
            }
        }
        
        private void StopAutoLaunchTimer()
        {
            try
            {
                if (autoLaunchTimer != null)
                {
                    autoLaunchTimer.Stop();
                    autoLaunchTimer.Tick -= OnAutoLaunchTimerTick;
                    autoLaunchTimer = null;
                    NinjaTrader.Code.Output.Process("Auto launch timer stopped", PrintTo.OutputTab1);
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR stopping auto launch timer: {0}", ex.Message), PrintTo.OutputTab1);
            }
        }
        
        private void OnAutoLaunchTimerTick(object sender, EventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("Auto launch timer tick", PrintTo.OutputTab1);
                
                // Only auto-launch if no window exists yet
                if (window == null && NinjaTrader.Core.Globals.ActiveWorkspace != null)
                {
                    NinjaTrader.Code.Output.Process("Auto launching window", PrintTo.OutputTab1);
                    
                    // Use Application.Current.Dispatcher to show window on UI thread
                    Application.Current.Dispatcher.BeginInvoke(new Action(delegate() 
                    {
                        ShowWindow();
                    }));
                }
                
                // Stop the timer after attempting auto-launch
                StopAutoLaunchTimer();
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in auto launch timer tick: {0}", ex.Message), PrintTo.OutputTab1);
                StopAutoLaunchTimer();
            }
        }

        // Add new method to handle window creation
        /// <summary>
        /// Called when a NinjaTrader window is created. Used here to add menu items to the Control Center.
        /// </summary>
        /// <param name="window">The window that was created.</param>
        protected override void OnWindowCreated(Window window)
        {
            try
            {
                // We want to place our AddOn in the Control Center's menus
                ControlCenter cc = window as ControlCenter;
                if (cc == null)
                    return;
                
                NinjaTrader.Code.Output.Process("ControlCenter window created", PrintTo.OutputTab1);
                
                // Find the "New" menu item
                if (cc.MainMenu == null)
                {
                    NinjaTrader.Code.Output.Process("ERROR: MainMenu not found in Control Center", PrintTo.OutputTab1);
                    return;
                }
                
                // Look for the "New" menu item
                existingMenuItemInControlCenter = null;
                // Replace this line:
                // Replace this line:
                // Iterate through the top-level items in the MainMenu
                foreach (object item in cc.MainMenu) // Iterate directly over the Menu control
                        {
                            MenuItem menuItem = item as MenuItem;
                            if (menuItem != null && menuItem.Header != null && menuItem.Header.ToString() == "New")
                            {
                                existingMenuItemInControlCenter = menuItem; // Removed incorrect cast
                                break;
                            }
                        }
                
                if (existingMenuItemInControlCenter == null)
                {
                    NinjaTrader.Code.Output.Process("ERROR: Could not find 'New' menu item in Control Center", PrintTo.OutputTab1);
                    return;
                }
                
                // Check if our menu item already exists to avoid duplicates
                // Renamed inner loop variable from 'item' to 'subItem' to resolve CS0136
                foreach (object subItem in existingMenuItemInControlCenter.ItemsSource ?? existingMenuItemInControlCenter.Items)
                {
                    // Use the renamed variable 'subItem'
                    MenuItem subMenuItem = subItem as MenuItem;
                    if (subMenuItem != null && subMenuItem.Header != null && subMenuItem.Header.ToString() == "Multi-Strategy Manager")
                    {
                        // Our menu item already exists, no need to add it again
                        NinjaTrader.Code.Output.Process("Menu item already exists, not adding again", PrintTo.OutputTab1);
                        return;
                    }
                }
                
                // 'Header' sets the name of our AddOn seen in the menu structure
                multiStratMenuItem = new NTMenuItem();
                multiStratMenuItem.Header = "Multi-Strategy Manager";
                multiStratMenuItem.Style = Application.Current.TryFindResource("MainMenuItem") as Style;
                
                // Add our AddOn into the "New" menu
                existingMenuItemInControlCenter.Items.Add(multiStratMenuItem);
                
                // Subscribe to the event for when the user presses our AddOn's menu item
                multiStratMenuItem.Click += new RoutedEventHandler(OnMenuItemClick);
                
                NinjaTrader.Code.Output.Process("Added Multi-Strategy Manager to Control Center menu", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in OnWindowCreated: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }
        
        // Helper method to find a visual child of a specific type
        private T FindVisualChild<T>(DependencyObject parent) where T : DependencyObject
        {
            try
            {
                // Check if the parent is null
                if (parent == null)
                    return null;
                
                // Check if the parent is of the requested type
                if (parent is T)
                    return parent as T;
                
                // Get the number of children
                int childCount = VisualTreeHelper.GetChildrenCount(parent);
                
                // Search through all children
                for (int i = 0; i < childCount; i++)
                {
                    DependencyObject child = VisualTreeHelper.GetChild(parent, i);
                    
                    // Recursively search this child
                    T result = FindVisualChild<T>(child);
                    
                    // If we found the child, return it
                    if (result != null)
                        return result;
                }
                
                return null;
            }
            catch
            {
                // Ignore errors and return null
                return null;
            }
        }
        
        // Add new method to clean up when window is destroyed
        /// <summary>
        /// Called when a NinjaTrader window is destroyed. Used here to clean up menu items from the Control Center.
        /// </summary>
        /// <param name="window">The window that was destroyed.</param>
        protected override void OnWindowDestroyed(Window window)
        {
            if (multiStratMenuItem != null && window is ControlCenter)
            {
                NinjaTrader.Code.Output.Process("ControlCenter window destroyed", PrintTo.OutputTab1);
                
                if (existingMenuItemInControlCenter != null && existingMenuItemInControlCenter.Items.Contains(multiStratMenuItem))
                    existingMenuItemInControlCenter.Items.Remove(multiStratMenuItem);
                
                multiStratMenuItem.Click -= OnMenuItemClick;
                multiStratMenuItem = null;
                existingMenuItemInControlCenter = null;
            }
        }
        
        // Add new method to handle menu item click
        private void OnMenuItemClick(object sender, RoutedEventArgs e)
        {
            NinjaTrader.Code.Output.Process("Menu item clicked", PrintTo.OutputTab1);
            // Use Application.Current.Dispatcher instead of RandomDispatcher
            Application.Current.Dispatcher.BeginInvoke(new Action(delegate() { ShowWindow(); }));
        }

        public void SetBridgeUrl(string url)
        {
            if (!string.IsNullOrEmpty(url))
            {
                bridgeServerUrl = url;
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Bridge Server URL set to: {bridgeServerUrl}", PrintTo.OutputTab1);
            }
        }

        private async Task SendToBridge(Dictionary<string, object> data)
        {
            if (string.IsNullOrEmpty(bridgeServerUrl))
            {
                NinjaTrader.Code.Output.Process("[MultiStratManager] Bridge Server URL is not set. Cannot send data.", PrintTo.OutputTab1);
                return;
            }

            try
            {
                string jsonPayload = SimpleJson.SerializeObject(data);
                HttpContent content = new StringContent(jsonPayload, Encoding.UTF8, "application/json");

                NinjaTrader.Code.Output.Process($"[MultiStratManager] Sending data to bridge: {jsonPayload}", PrintTo.OutputTab1); // Log payload
                string tradeUrl = $"{bridgeServerUrl}/log_trade";
                HttpResponseMessage response = await httpClient.PostAsync(tradeUrl, content);

                if (response.IsSuccessStatusCode)
                {
                    NinjaTrader.Code.Output.Process("[MultiStratManager] Data successfully sent to bridge.", PrintTo.OutputTab1);
                }
                else
                {
                    string responseContent = await response.Content.ReadAsStringAsync();
                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Failed to send data. Status: {response.StatusCode}, Response: {responseContent}", PrintTo.OutputTab1);
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Exception sending data to bridge: {ex.Message}", PrintTo.OutputTab1);
            }
        }

    public void SetMonitoredAccount(Account account)
    {
        // Unsubscribe from previous account if necessary
        if (monitoredAccount != null)
        {
            monitoredAccount.ExecutionUpdate -= OnExecutionUpdate;
            monitoredAccount.OrderUpdate    -= Account_OrderUpdate;
            monitoredAccount.AccountItemUpdate -= OnAccountItemUpdate; // Unsubscribe AccountItemUpdate
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Unsubscribed from events for account {monitoredAccount.Name}", PrintTo.OutputTab1);
        }

        monitoredAccount = account;

        // Subscribe to new account if not null
        if (monitoredAccount != null)
        {
            monitoredAccount.ExecutionUpdate += OnExecutionUpdate;
            monitoredAccount.OrderUpdate    += Account_OrderUpdate;
            monitoredAccount.AccountItemUpdate += OnAccountItemUpdate; // Subscribe AccountItemUpdate
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Subscribed to events for account {monitoredAccount.Name}", PrintTo.OutputTab1);

            // Initialize PnL values.
            var realizedItemArgs = monitoredAccount.GetAccountItem(Cbi.AccountItem.RealizedProfitLoss, Currency.UsDollar);
            if (realizedItemArgs != null && realizedItemArgs.Value is double) // Assuming GetAccountItem returns AccountItemEventArgs here based on CS0029
                RealizedPnL = (double)realizedItemArgs.Value;

            var unrealizedItemArgs = monitoredAccount.GetAccountItem(Cbi.AccountItem.UnrealizedProfitLoss, Currency.UsDollar);
            if (unrealizedItemArgs != null && unrealizedItemArgs.Value is double) // Assuming GetAccountItem returns AccountItemEventArgs here based on CS0029
                UnrealizedPnL = (double)unrealizedItemArgs.Value;
            // TotalPnL is updated automatically via setters of RealizedPnL/UnrealizedPnL

            // Initialize session tracking for elastic hedging
            InitializeSessionTracking();
        }
        else
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Monitored account set to null. PnL tracking stopped.", PrintTo.OutputTab1);
            // Reset PnL values
            RealizedPnL = 0;
            UnrealizedPnL = 0;
            // TotalPnL is updated automatically
        }
    }

    private void OnAccountItemUpdate(object sender, AccountItemEventArgs e)
    {
        _ = sender; // Suppress unused parameter warning
        if (e.Account == null || monitoredAccount == null || e.Account.Name != monitoredAccount.Name)
            return;

        bool pnlChanged = false;

        if (e.AccountItem == Cbi.AccountItem.RealizedProfitLoss)
        {
            if (e.Value is double realizedValue)
            {
                if (RealizedPnL != realizedValue)
                {
                    RealizedPnL = realizedValue;
                    pnlChanged = true;
                }
            }
        }
        else if (e.AccountItem == Cbi.AccountItem.UnrealizedProfitLoss)
        {
            if (e.Value is double unrealizedValue)
            {
                if (UnrealizedPnL != unrealizedValue)
                {
                    UnrealizedPnL = unrealizedValue;
                    pnlChanged = true;
                }
            }
        }

        if (pnlChanged)
        {
            // Assuming RealizedPnL and UnrealizedPnL setters call OnPropertyChanged for themselves.
            // TotalPnL is updated here, and OnPropertyChanged is called for it.
            TotalPnL = RealizedPnL + UnrealizedPnL;
            OnPropertyChanged(nameof(TotalPnL));
        }
    }

    private void OnExecutionUpdate(object sender, ExecutionEventArgs e)
    {
            LogForSLTP($"OnExecutionUpdate: Entered. ExecutionId: {{e.Execution?.ExecutionId}}, OrderId: {{e.Order?.Id}}, Strategy: {{e.Strategy?.Name}}", LogLevel.Information);
        try
        {
            // Ensure the execution is for the monitored account
            if (monitoredAccount == null || e.Execution.Account.Name != monitoredAccount.Name)
                return;

            // BIDIRECTIONAL_HEDGE_FIX: Skip processing executions of hedge closing orders
            // These orders are responses to MT5 notifications and should NOT trigger additional CLOSE_HEDGE commands
            if (e.Execution?.Order != null && trackedHedgeClosingOrderIds != null &&
                trackedHedgeClosingOrderIds.Contains(e.Execution.Order.Id.ToString()))
            {
                LogAndPrint($"HEDGE_CLOSURE_SKIP: Skipping execution processing for hedge closing order {e.Execution.Order.Id} ('{e.Execution.Order.Name}'). This prevents incorrect FIFO-based BaseID selection.");
                return;
            }

            // OFFICIAL NINJATRADER BEST PRACTICE: Comprehensive Trade Classification
            bool isClosingExecution = DetectTradeClosureByExecution(e);
            bool isNewEntryTrade = IsNewEntryTrade(e);

            LogAndPrint($"TRADE_CLASSIFICATION: Closure={isClosingExecution}, Entry={isNewEntryTrade}");

            if (isClosingExecution)
            {
                LogAndPrint($"PROCESSING_CLOSURE: Handling trade closure execution");
                HandleTradeClosureExecution(e);
                return; // Don't process as new trade
            }

            if (!isNewEntryTrade)
            {
                LogAndPrint($"EXECUTION_IGNORED: Not a closure and not a new entry - ignoring execution");
                return; // Don't process executions that are neither closures nor new entries
            }

            LogAndPrint($"PROCESSING_NEW_ENTRY: Handling new entry trade execution");

// Call SLTP Removal Logic
            LogForSLTP($"OnExecutionUpdate: EnableSLTPRemoval is {{EnableSLTPRemoval}}.", LogLevel.Information);
            if (sltpRemovalLogic == null)
            {
                LogForSLTP("OnExecutionUpdate: sltpRemovalLogic is null. SLTP removal will be skipped.", LogLevel.Warning);
            }
            if (sltpRemovalLogic != null && e.Execution != null && e.Execution.Account != null)
            {
                LogForSLTP("OnExecutionUpdate: Calling sltpRemovalLogic.HandleExecutionUpdate.", LogLevel.Information);
                sltpRemovalLogic.HandleExecutionUpdate(
                    e.Execution,
                    this.EnableSLTPRemoval,
                    this.SLTPRemovalDelaySeconds,
                    e.Execution.Account
                );
            }
            // Log only fills
            if (e.Execution != null && e.Execution.Quantity > 0)
            {
                // Ensure Order is not null before accessing its properties for logging
                if (e.Execution != null && e.Execution.Order != null)
                {
                    NinjaTrader.Code.Output.Process(String.Format("[MultiStratManager] DEBUG Addon: Execution Details - ID: {0}, Order.Filled: {1}, Execution.Quantity: {2}, Order.Quantity: {3}, MarketPosition: {4}",
                        e.Execution.ExecutionId, // Using ExecutionId as OrderId might be the base order id for multiple fills
                        e.Execution.Order.Filled,
                        e.Execution.Quantity,
                        e.Execution.Order.Quantity,
                        e.Execution.MarketPosition
                    ), PrintTo.OutputTab1);
                }
                else
                {
                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Received Execution Fill (Order details partially unavailable): {e.Execution}", PrintTo.OutputTab1);
                }
                
                // We use e.OrderId as the base_id - declare it here for use in both sections
                string baseId = e.OrderId;

                // MULTI_TRADE_GROUP_FIX: Store original trade info and handle multiple trades with same BaseID
                if (e.Execution.Order != null && e.Execution.Order.OrderState == OrderState.Filled)
                {
                    if (!string.IsNullOrEmpty(baseId))
                    {
                        lock (_activeNtTradesLock)
                        {
                            if (activeNtTrades.ContainsKey(baseId))
                            {
                                // MULTI_TRADE_GROUP_FIX: BaseID already exists, increment quantities
                                var existingTrade = activeNtTrades[baseId];
                                existingTrade.TotalQuantity += (int)e.Execution.Order.Quantity;
                                existingTrade.RemainingQuantity += (int)e.Execution.Order.Quantity;
                                LogAndPrint($"MULTI_TRADE_GROUP: Updated existing BaseID {baseId}. Total: {existingTrade.TotalQuantity}, Remaining: {existingTrade.RemainingQuantity}");
                            }
                            else
                            {
                                // MULTI_TRADE_GROUP_FIX: New BaseID, create new entry
                                var tradeInfo = new OriginalTradeDetails
                                {
                                    MarketPosition = e.Execution.MarketPosition,
                                    Quantity = (int)e.Execution.Order.Quantity,
                                    NtInstrumentSymbol = e.Execution.Instrument.FullName,
                                    NtAccountName = e.Execution.Account.Name,
                                    OriginalOrderAction = e.Execution.Order.OrderAction,
                                    TotalQuantity = (int)e.Execution.Order.Quantity,
                                    RemainingQuantity = (int)e.Execution.Order.Quantity
                                };

                                if (activeNtTrades.TryAdd(baseId, tradeInfo))
                                {
                                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Stored original trade info for base_id: {baseId}, Position: {tradeInfo.MarketPosition}, Qty: {tradeInfo.Quantity}, Action: {tradeInfo.OriginalOrderAction}", PrintTo.OutputTab1);
                                    LogAndPrint($"ACTIVE_TRADES_ADD: Added base_id {baseId} to activeNtTrades. Total entries: {activeNtTrades.Count}");
                                }
                                else
                                {
                                    LogAndPrint($"ACTIVE_TRADES_ADD_FAILED: Failed to add base_id {baseId} to activeNtTrades (race condition)");
                                }
                            }
                        }
                    }
                }

                // Update trade result tracking for elastic hedging
                UpdateTradeResult(e);

                // --- OPTIMIZED CLOSURE DETECTION: Call FindOriginalTradeBaseId only once ---
                string originalBaseId = FindOriginalTradeBaseId(e);
                bool isClosingTrade = !string.IsNullOrEmpty(originalBaseId);

                if (isClosingTrade)
                {
                    // CRITICAL FIX: Only send closure notification if this trade actually has an active hedge
                    // Check if this base_id was ever sent to MT5 and potentially has an active hedge
                    bool hasActiveHedge = activeNtTrades.ContainsKey(originalBaseId);

                    if (hasActiveHedge)
                    {
                        // This is a closing trade with an active hedge - send hedge closure notification
                        LogAndPrint($"NT_CLOSURE_DETECTED: Execution {e.Execution.ExecutionId} is closing trade for BaseID={originalBaseId} which has an active hedge. Sending hedge closure notification to MT5.");

                        try
                        {
                            // Send hedge closure notification to MT5 via bridge
                            // MT5 EA expects a trade message with action="CLOSE_HEDGE" for processing
                            var closureData = new Dictionary<string, object>
                            {
                                { "action", "CLOSE_HEDGE" },  // MT5 EA looks for this specific action
                                { "base_id", originalBaseId },
                                { "quantity", (float)e.Execution.Quantity },
                                { "price", 0.0 },  // Not critical for closure
                                { "total_quantity", (float)e.Execution.Quantity },
                                { "contract_num", 1 },
                                { "instrument_name", e.Execution.Instrument.FullName },
                                { "account_name", e.Execution.Account.Name },
                                { "time", e.Execution.Time.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture) },
                                { "nt_balance", 0 },  // Not critical for closure
                                { "nt_daily_pnl", 0 },  // Not critical for closure
                                { "nt_trade_result", "closed" },
                                { "nt_session_trades", 0 },
                                { "closure_reason", "NT_ORIGINAL_TRADE_CLOSED" } // This will NOT trigger whack-a-mole
                            };

                            string closureJson = SimpleJson.SerializeObject(closureData);
                            LogAndPrint($"NT_CLOSURE: Sending hedge closure notification: {closureJson}");

                            // Send to bridge's hedge closure endpoint
                            Task.Run(() => SendHedgeClosureNotification(closureData));

                            // Remove from active trades tracking since it's closed
                            if (activeNtTrades.ContainsKey(originalBaseId))
                            {
                                activeNtTrades.TryRemove(originalBaseId, out _);
                                LogAndPrint($"NT_CLOSURE: Removed closed trade {originalBaseId} from activeNtTrades tracking. Remaining entries: {activeNtTrades.Count}");
                            }
                            else
                            {
                                LogAndPrint($"NT_CLOSURE: Trade {originalBaseId} not found in activeNtTrades (may have been removed by hedge closure)");
                            }
                        }
                        catch (Exception ex_closure)
                        {
                            LogAndPrint($"ERROR: Exception sending hedge closure notification: {ex_closure.Message}");
                        }
                    }
                    else
                    {
                        // This is a closing trade but no active hedge exists - skip closure notification
                        LogAndPrint($"NT_CLOSURE_SKIPPED: Execution {e.Execution.ExecutionId} is closing trade for BaseID={originalBaseId} but no active hedge exists. Skipping closure notification to prevent noise.");
                        LogAndPrint($"NT_CLOSURE_SKIPPED: This trade was likely from a previous session or never had a hedge opened. No action needed.");
                    }

                    return; // Don't process as new trade regardless
                }
                else
                {
                    // This is an entry trade - send normal trade data
                    string jsonData = null; // To store serialized tradeData for logging in case of bridge error

                    try
                    {
                        var tradeData = new Dictionary<string, object>
                        {
                            { "id", e.Execution.ExecutionId },
                            { "base_id", baseId },
                            { "time", e.Execution.Time.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture) },
                            { "action", e.Execution.Order.OrderAction.ToString() },
                            { "quantity", (float)e.Execution.Quantity }, // Fill quantity
                            { "price", (float)e.Execution.Price },
                            { "total_quantity", (e.Execution.Order != null) ? (int)e.Execution.Order.Quantity : (int)e.Execution.Quantity }, // Order quantity
                            { "contract_num", 1 },
                            { "instrument_name", e.Execution.Instrument.FullName },
                            { "account_name", e.Execution.Account.Name },

                            // Enhanced NT Performance Data for Elastic Hedging
                            { "nt_balance", (float)_sessionStartBalance },
                            { "nt_daily_pnl", (float)DailyPnL },
                            { "nt_trade_result", _lastTradeResult },
                            { "nt_session_trades", _sessionTradeCount }
                        };

                        if (e.Execution.Order != null && !string.IsNullOrEmpty(e.Execution.Order.Name))
                        {
                            if (e.Execution.Order.Name.Contains("TP")) tradeData["order_type"] = "TP";
                            else if (e.Execution.Order.Name.Contains("SL")) tradeData["order_type"] = "SL";
                        }

                        jsonData = SimpleJson.SerializeObject(tradeData);
                        NinjaTrader.Code.Output.Process(String.Format("[MultiStratManager] DEBUG Addon: JSON to Bridge: {0}", jsonData), PrintTo.OutputTab1);
                        Task.Run(() => SendToBridge(tradeData));
                    }
                    catch (Exception ex_bridge)
                    {
                         NinjaTrader.Code.Output.Process($"ERROR: [MultiStratManager] Exception sending data to bridge: {ex_bridge.Message} | URL: {this.bridgeServerUrl} | Data: {jsonData} | StackTrace: {ex_bridge.StackTrace}", PrintTo.OutputTab1);
                         // Do not re-throw, allow ExecutionUpdate to complete
                    }
                }
            }
        }
        catch (Exception ex) // Outer catch for the entire handler
        {
            LogAndPrint($"ERROR: [MultiStratManager] Unhandled exception in ExecutionUpdate handler: {ex.Message} | StackTrace: {ex.StackTrace} | InnerException: {ex.InnerException?.Message}");
        }
    }

    // This method replaces the problematic override that caused CS0115.
    // This is the handler for monitoredAccount.OrderUpdate.
    // Ensure SetMonitoredAccount (lines 483-506) correctly subscribes Account_OrderUpdate.
    private void Account_OrderUpdate(object sender, NinjaTrader.Cbi.OrderEventArgs e)
{
    LogAndPrint($"Account_OrderUpdate: OrderId={e.Order?.OrderId}, State={e.OrderState}, FilledThisUpdate={e.Filled}, TotalOrderFilled={e.Order?.Filled}, AvgFillPriceThisUpdate={e.AverageFillPrice}, TotalOrderAvgFillPrice={e.Order?.AverageFillPrice}, QtyThisUpdate={e.Quantity}, LimitPrice={e.LimitPrice}, StopPrice={e.StopPrice}, Time={e.Time}");

    if (e.Order == null)
    {
        LogAndPrint("Account_OrderUpdate: e.Order is null, exiting.");
        return;
    }

    Order order = e.Order;
    long unfilledQuantity = order.Quantity - order.Filled; // Correctly calculate unfilled quantity

    // Log with corrected unfilled quantity
    LogAndPrint($"Account_OrderUpdate Details for {order.Name} (ID: {order.Id}): State={e.OrderState}, FilledThisUpdate={e.Filled}, TotalOrderFilled={order.Filled}, Unfilled={unfilledQuantity}");


    if (trackedHedgeClosingOrderIds.Contains(order.OrderId)) // Assumes line 90 is fixed to HashSet<string>
    {
        LogAndPrint($"Account_OrderUpdate: Tracking hedge closing order {order.OrderId}, Current State via e.OrderState: {e.OrderState}, via order.OrderState: {order.OrderState}");

        // Detailed logging for CancelPending or terminal states for HedgeClose_ orders
        if (e.Order.Name.StartsWith("HedgeClose_") &&
            (e.OrderState == OrderState.CancelPending || e.OrderState == OrderState.Filled || e.OrderState == OrderState.PartFilled || e.OrderState == OrderState.Cancelled || e.OrderState == OrderState.Rejected))
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager DEBUG] HedgeClose_ Order Update: Name='{e.Order.Name}', ID(int)={e.Order.Id}, State='{e.OrderState}', Filled={e.Order.Filled}/{e.Order.Quantity}, ErrorCode='{e.Error}'", PrintTo.OutputTab1);
        }

        if (e.OrderState == OrderState.Filled || e.OrderState == OrderState.PartFilled)
        {
            LogAndPrint($"Account_OrderUpdate: Hedge closing order {order.OrderId} received fill update. Filled this update: {e.Filled}, Total Order Filled: {order.Filled}");
            // If the order is terminally filled (fully filled), remove it from tracking.
            if ((order.OrderState == OrderState.Filled || order.OrderState == OrderState.Cancelled || order.OrderState == OrderState.Rejected) && order.Filled == order.Quantity)
            {
                trackedHedgeClosingOrderIds.Remove(order.OrderId);
                LogAndPrint($"Account_OrderUpdate: Fully filled hedge closing order {order.OrderId} removed from tracking.");
            }
        }
        else if ((order.OrderState == OrderState.Filled || order.OrderState == OrderState.Cancelled || order.OrderState == OrderState.Rejected)) // e.g. Cancelled, Rejected.
        {
            LogAndPrint($"Account_OrderUpdate: Hedge closing order {order.OrderId} is now terminal (State via e.OrderState: {e.OrderState}, via order.OrderState: {order.OrderState}). Removing from tracking.");
            trackedHedgeClosingOrderIds.Remove(order.OrderId);
        }
    }
}

    // HTTP Listener Implementation
    private void StartHttpListener()
    {
        if (isListenerRunning) return;

        try
        {
            httpListener = new HttpListener();
            // Important: Add trailing slash for HttpListener prefix
            // Make the listener more generic to handle multiple paths
            string prefix = $"http://localhost:{ListenerPort}/";
            httpListener.Prefixes.Add(prefix);
            // httpListener.Prefixes.Add($"http://localhost:{ListenerPort}{NotifyHedgeClosedPath}/"); // Alternative: specific prefixes

            httpListener.Start();
            isListenerRunning = true; // Set before starting thread
            NinjaTrader.Code.Output.Process($"MultiStratManager HTTP Listener started on {prefix} (and other configured paths)", PrintTo.OutputTab1);

            listenerThread = new Thread(HandleIncomingConnections);
            listenerThread.IsBackground = true; // Ensure thread exits when app exits
            listenerThread.Name = "MultiStratManagerHttpListenerThread";
            listenerThread.Start();
        }
        catch (HttpListenerException hle) when (hle.ErrorCode == 5) // ERROR_ACCESS_DENIED
        {
            NinjaTrader.Code.Output.Process($"Error starting MultiStratManager HTTP Listener: Access Denied. Please run NinjaTrader as Administrator or configure URL ACLs (netsh http add urlacl url=http://+:{ListenerPort}/ user=Everyone). Details: {hle.Message}", PrintTo.OutputTab1);
            isListenerRunning = false;
            if (httpListener != null)
            {
                try { if(httpListener.IsListening) httpListener.Stop(); } catch { /* Ignore */ }
                try { httpListener.Close(); } catch { /* Ignore */ }
                httpListener = null;
            }
        }
        catch (Exception ex)
        {
            NinjaTrader.Code.Output.Process($"Error starting MultiStratManager HTTP Listener: {ex.Message}", PrintTo.OutputTab1);
            isListenerRunning = false; // Reset on failure
            if (httpListener != null)
            {
                try { if(httpListener.IsListening) httpListener.Stop(); } catch { /* Ignore */ }
                try { httpListener.Close(); } catch { /* Ignore */ }
                httpListener = null;
            }
        }
    }

    private void HandleIncomingConnections()
    {
        NinjaTrader.Code.Output.Process("MultiStratManager: HandleIncomingConnections thread started.", PrintTo.OutputTab1);
        while (isListenerRunning)
        {
            HttpListenerContext context = null;
            try
            {
                if (httpListener == null || !httpListener.IsListening)
                {
                    if (isListenerRunning) // If we are supposed to be running but listener is dead, log and break
                    {
                        NinjaTrader.Code.Output.Process("MultiStratManager HTTP Listener is not listening or null, but isListenerRunning is true. Stopping.", PrintTo.OutputTab1);
                        isListenerRunning = false; // Ensure loop terminates
                    }
                    break;
                }
                
                context = httpListener.GetContext();
                HttpListenerRequest request = context.Request;
                HttpListenerResponse response = context.Response;

                NinjaTrader.Code.Output.Process($"MultiStratManager: Received request for {request.Url.AbsolutePath}", PrintTo.OutputTab1);

                if (request.HttpMethod == "GET" && request.Url.AbsolutePath.Equals(PingPath, StringComparison.OrdinalIgnoreCase))
                {
                    HandlePingRequest(response);
                }
                else if (request.HttpMethod == "POST" && request.Url.AbsolutePath.Equals(NotifyHedgeClosedPath, StringComparison.OrdinalIgnoreCase))
                {
                    HandleNotifyHedgeClosedRequest(request, response);
                }
                else
                {
                    response.StatusCode = (int)HttpStatusCode.NotFound; // Changed from MethodNotAllowed to NotFound for unhandled paths
                    byte[] notFoundBuffer = Encoding.UTF8.GetBytes("{\"error\": \"Endpoint not found.\"}");
                    response.ContentType = "application/json";
                    response.ContentLength64 = notFoundBuffer.Length;
                    using (System.IO.Stream output = response.OutputStream)
                    {
                        output.Write(notFoundBuffer, 0, notFoundBuffer.Length);
                    }
                    // response.Close(); // Close is handled in finally
                }
            }
            catch (HttpListenerException ex) when (ex.ErrorCode == 995) // ERROR_OPERATION_ABORTED
            {
                // This is expected when StopHttpListener calls httpListener.Stop() or .Close()
                NinjaTrader.Code.Output.Process("MultiStratManager HTTP Listener stopping (operation aborted as expected).", PrintTo.OutputTab1);
                isListenerRunning = false; // Ensure loop terminates
                break;
            }
            catch (ObjectDisposedException)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager HTTP Listener stopping (object disposed as expected).", PrintTo.OutputTab1);
                isListenerRunning = false; // Ensure loop terminates
                break;
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"Error handling request in MultiStratManager HTTP Listener: {ex.GetType().Name} - {ex.Message}", PrintTo.OutputTab1);
                if (context != null && context.Response != null && !context.Response.OutputStream.CanWrite)
                {
                    try
                    {
                        context.Response.StatusCode = (int)HttpStatusCode.InternalServerError;
                        context.Response.Close();
                    }
                    catch (Exception respEx)
                    {
                        NinjaTrader.Code.Output.Process($"MultiStratManager: Could not send 500 error response: {respEx.Message}", PrintTo.OutputTab1);
                    }
                }
                // If a critical error occurred and we decided to stop, isListenerRunning should be set to false elsewhere or here.
                // For now, we continue if isListenerRunning is true, assuming it's a transient request error.
                if (!isListenerRunning) break;
            }
            finally
            {
                // Ensure response is closed if not already (e.g. after successful GET)
                if (context != null && context.Response != null)
                {
                    try { context.Response.Close(); } catch { /* Already closed or error closing */ }
                }
            }
        }
        NinjaTrader.Code.Output.Process("MultiStratManager: HandleIncomingConnections thread ending.", PrintTo.OutputTab1);
    }

    private void HandlePingRequest(HttpListenerResponse response)
    {
        string responseString = $"{{\"status\": \"MultiStratManager_active\", \"timestamp\": \"{DateTime.UtcNow.ToString("o")}\"}}";
        byte[] buffer = System.Text.Encoding.UTF8.GetBytes(responseString);

        response.ContentType = "application/json";
        response.ContentLength64 = buffer.Length;
        response.StatusCode = (int)HttpStatusCode.OK;

        PingReceivedFromBridge?.Invoke();
        NinjaTrader.Code.Output.Process("MultiStratManager: PingReceivedFromBridge event raised.", PrintTo.OutputTab1);

        using (System.IO.Stream output = response.OutputStream)
        {
            output.Write(buffer, 0, buffer.Length);
        }
    }

    private void HandleNotifyHedgeClosedRequest(HttpListenerRequest request, HttpListenerResponse response)
    {
        try
        {
            string requestBody;
            using (StreamReader reader = new StreamReader(request.InputStream, request.ContentEncoding))
            {
                requestBody = reader.ReadToEnd();
            }

            NinjaTrader.Code.Output.Process($"[MultiStratManager] MT5_TO_NT_CLOSURE: Received /notify_hedge_closed POST data: {requestBody}", PrintTo.OutputTab1);
            Dictionary<string, object> jsonObject = null;
            HedgeCloseNotification notification = new HedgeCloseNotification(); // Initialize to prevent null ref later

            try
        {
            jsonObject = SimpleJson.DeserializeObject<Dictionary<string, object>>(requestBody);

            if (jsonObject == null)
            {
                NinjaTrader.Code.Output.Process("[MultiStratManager] Deserialized jsonObject for hedge_close_notification is null.", PrintTo.OutputTab1);
                SendErrorResponse(response, HttpStatusCode.BadRequest, "Invalid JSON payload: resulted in null dictionary.");
                return;
            }

            // Log the raw dictionary for debugging
            var sbLog = new StringBuilder("[MultiStratManager] DEBUG Raw Deserialized JsonObject for HedgeClose: ");
            foreach(var kvp in jsonObject)
            {
                sbLog.AppendFormat("'{0}':'{1}', ", kvp.Key, kvp.Value ?? "NULL_VALUE");
            }
            NinjaTrader.Code.Output.Process(sbLog.ToString().TrimEnd(',', ' '), PrintTo.OutputTab1);

            // Manually populate HedgeCloseNotification from jsonObject
            notification.event_type = jsonObject.ContainsKey("event_type") ? jsonObject["event_type"] as string : null;
            notification.base_id = jsonObject.ContainsKey("base_id") ? jsonObject["base_id"] as string : null;
            notification.nt_instrument_symbol = jsonObject.ContainsKey("nt_instrument_symbol") ? jsonObject["nt_instrument_symbol"] as string : null;
            notification.nt_account_name = jsonObject.ContainsKey("nt_account_name") ? jsonObject["nt_account_name"] as string : null;
            notification.timestamp = jsonObject.ContainsKey("timestamp") ? jsonObject["timestamp"] as string : null;
            notification.closed_hedge_action = jsonObject.ContainsKey("closed_hedge_action") ? jsonObject["closed_hedge_action"] as string : null;
            notification.ClosureReason = jsonObject.ContainsKey("closure_reason") ? jsonObject["closure_reason"] as string : null; // Added for closure_reason

            if (jsonObject.ContainsKey("closed_hedge_quantity"))
            {
                object qtyObj = jsonObject["closed_hedge_quantity"];
                if (qtyObj != null)
                {
                    try
                    {
                        // SimpleJson parses numbers as double. It can also be a string representation of a number.
                        notification.closed_hedge_quantity = Convert.ToDouble(qtyObj, CultureInfo.InvariantCulture);
                    }
                    catch (FormatException)
                    {
                         NinjaTrader.Code.Output.Process($"[MultiStratManager] Could not parse 'closed_hedge_quantity' due to FormatException. Value: '{qtyObj}'. Setting to 0.", PrintTo.OutputTab1);
                         notification.closed_hedge_quantity = 0; // Default or error state
                    }
                    catch (InvalidCastException)
                    {
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] Could not parse 'closed_hedge_quantity' due to InvalidCastException. Value: '{qtyObj}'. Setting to 0.", PrintTo.OutputTab1);
                        notification.closed_hedge_quantity = 0; // Default or error state
                    }
                }
                else
                {
                    NinjaTrader.Code.Output.Process("[MultiStratManager] 'closed_hedge_quantity' value is null in JSON. Setting to 0.", PrintTo.OutputTab1);
                    notification.closed_hedge_quantity = 0; // Default or error state
                }
            }
            else
            {
                NinjaTrader.Code.Output.Process("[MultiStratManager] 'closed_hedge_quantity' key not found in JSON. Setting to 0.", PrintTo.OutputTab1);
                notification.closed_hedge_quantity = 0; // Default or error state
            }
        }
        catch (Exception ex) // Catch issues from DeserializeObject or manual population
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager] JSON Deserialization/Population error for /notify_hedge_closed: {ex.Message}\nStackTrace: {ex.StackTrace}", PrintTo.OutputTab1);
            SendErrorResponse(response, HttpStatusCode.BadRequest, "Invalid JSON format or structure during processing.");
            return;
        }

        // Detailed logging for the populated HedgeCloseNotification object
        // Note: notification itself is new'd up, so it won't be null here unless 'new' failed, which is unlikely.
        NinjaTrader.Code.Output.Process($"[MultiStratManager] DEBUG Populated HedgeCloseNotification: " +
            $"event_type='{notification.event_type ?? "null"}', base_id='{notification.base_id ?? "null"}', " +
            $"nt_instrument_symbol='{notification.nt_instrument_symbol ?? "null"}', nt_account_name='{notification.nt_account_name ?? "null"}', " +
            $"closed_hedge_quantity={notification.closed_hedge_quantity.ToString(CultureInfo.InvariantCulture)}, closed_hedge_action='{notification.closed_hedge_action ?? "null"}', " +
            $"timestamp='{notification.timestamp ?? "null"}', ClosureReason='{notification.ClosureReason ?? "null"}'", PrintTo.OutputTab1);
        
        // Validate data
        // The 'notification == null' check is removed as 'notification' is initialized.
        if (notification.event_type != "hedge_close_notification" ||
            string.IsNullOrEmpty(notification.base_id) || string.IsNullOrEmpty(notification.nt_instrument_symbol) ||
            string.IsNullOrEmpty(notification.nt_account_name) || notification.closed_hedge_quantity <= 0 || // Quantity must be positive
            string.IsNullOrEmpty(notification.closed_hedge_action))
        {
            NinjaTrader.Code.Output.Process("[MultiStratManager] Invalid or incomplete hedge_close_notification data after manual population.", PrintTo.OutputTab1);
            SendErrorResponse(response, HttpStatusCode.BadRequest, "Missing or invalid fields in hedge_close_notification after processing.");
            return;
        }

        // Process the notification (find position, submit order)
        // This needs to be done on the NT thread
        Application.Current.Dispatcher.InvokeAsync(() =>
        {
            try
            {
                // Handle case where MT5 sends "UNKNOWN" account/symbol data for legitimate closures
                bool hasUnknownData = (notification.nt_account_name == "UNKNOWN" || notification.nt_instrument_symbol == "UNKNOWN");

                Account account = null;
                Instrument instrument = null;

                if (hasUnknownData)
                {
                    // Check if this is a legitimate closure reason that should be processed despite unknown data
                    bool shouldProcessDespiteUnknownData = ShouldCreateClosingOrderForReason(notification.ClosureReason);

                    if (shouldProcessDespiteUnknownData)
                    {
                        LogAndPrint($"INFO: Received legitimate closure reason '{notification.ClosureReason}' with UNKNOWN account/symbol data. Attempting to resolve from stored trade data for BaseID={notification.base_id}");

                        // Try to get account and instrument from stored trade data
                        if (activeNtTrades.ContainsKey(notification.base_id))
                        {
                            var storedTrade = activeNtTrades[notification.base_id];
                            account = Account.All.FirstOrDefault(a => a.Name == storedTrade.NtAccountName);
                            try { instrument = Instrument.GetInstrument(storedTrade.NtInstrumentSymbol, true); } catch { }

                            if (account != null && instrument != null)
                            {
                                LogAndPrint($"INFO: Successfully resolved UNKNOWN data from stored trade: Account={account.Name}, Instrument={instrument.FullName}");
                                // Update notification with resolved data for consistency
                                notification.nt_account_name = account.Name;
                                notification.nt_instrument_symbol = instrument.FullName;
                            }
                            else
                            {
                                LogAndPrint($"ERROR: Could not resolve account or instrument from stored trade data for BaseID={notification.base_id}. Account={account?.Name ?? "null"}, Instrument={instrument?.FullName ?? "null"}");
                                return;
                            }
                        }
                        else
                        {
                            // MISSING_DATA_FIX: Try fallback resolution methods
                            LogAndPrint($"WARNING: No stored trade data found for BaseID={notification.base_id}. Attempting fallback resolution...");

                            // Try to find partial matches (in case BaseID was truncated)
                            var partialMatch = activeNtTrades.FirstOrDefault(kvp =>
                                kvp.Key.StartsWith(notification.base_id.Substring(0, Math.Min(notification.base_id.Length, 20))) ||
                                notification.base_id.StartsWith(kvp.Key.Substring(0, Math.Min(kvp.Key.Length, 20))));

                            if (!partialMatch.Equals(default(KeyValuePair<string, OriginalTradeDetails>)))
                            {
                                var storedTrade = partialMatch.Value;
                                account = Account.All.FirstOrDefault(a => a.Name == storedTrade.NtAccountName);
                                try { instrument = Instrument.GetInstrument(storedTrade.NtInstrumentSymbol, true); } catch { }

                                if (account != null && instrument != null)
                                {
                                    LogAndPrint($"MISSING_DATA_FIX: Found partial match! Original BaseID={notification.base_id}, Matched BaseID={partialMatch.Key}, Account={account.Name}, Symbol={instrument.FullName}");
                                    // Update notification with resolved data for consistency
                                    notification.nt_account_name = account.Name;
                                    notification.nt_instrument_symbol = instrument.FullName;
                                }
                                else
                                {
                                    LogAndPrint($"ERROR: Could not resolve account or instrument from partial match for BaseID={notification.base_id}. Account={account?.Name ?? "null"}, Instrument={instrument?.FullName ?? "null"}");
                                    return;
                                }
                            }
                            else
                            {
                                // Last resort: use default values if available
                                LogAndPrint($"ERROR: No stored trade data found for BaseID={notification.base_id} to resolve UNKNOWN account/symbol data. Using fallback defaults.");
                                account = Account.All.FirstOrDefault(a => a.Name == "Sim101"); // Default account
                                try { instrument = Instrument.GetInstrument("NQ 03-25", true); } catch { } // Default symbol

                                if (account != null && instrument != null)
                                {
                                    LogAndPrint($"MISSING_DATA_FIX: Using fallback defaults - Account={account.Name}, Symbol={instrument.FullName}");
                                    notification.nt_account_name = account.Name;
                                    notification.nt_instrument_symbol = instrument.FullName;
                                }
                                else
                                {
                                    LogAndPrint($"ERROR: Fallback defaults failed. Cannot proceed without valid account/symbol data.");
                                    return;
                                }
                            }
                        }
                    }
                    else
                    {
                        LogAndPrint($"INFO: Received EA-managed closure reason '{notification.ClosureReason}' with UNKNOWN data. Skipping processing as expected.");
                        return;
                    }
                }
                else
                {
                    // Normal case - account and symbol are provided
                    account = Account.All.FirstOrDefault(a => a.Name == notification.nt_account_name);
                    if (account == null)
                    {
                        LogAndPrint($"ERROR: Account not found: {notification.nt_account_name}");
                        return;
                    }
                }

                // Get instrument if not already resolved above
                if (instrument == null)
                {
                    try { instrument = Instrument.GetInstrument(notification.nt_instrument_symbol, true); } catch { }
                }

                if (instrument == null)
                {
                    LogAndPrint($"ERROR: Instrument not found or invalid: {notification.nt_instrument_symbol}");
                    return;
                }

                // BIDIRECTIONAL_HEDGE_FIX: This function correctly processes hedge closure notifications
                // by using the EXACT BaseID from the MT5 notification. This is the correct behavior.
                // The issue was in FindTradeBeingClosed() which used FIFO logic instead of BaseID matching.
                OriginalTradeDetails originalDetails;
                lock (_activeNtTradesLock)
                {
                    if (!activeNtTrades.TryGetValue(notification.base_id, out originalDetails))
                    {
                        LogAndPrint($"HEDGE_CLOSURE_ERROR: Original NT trade for EXACT base_id '{notification.base_id}' not found in activeNtTrades. Available BaseIDs: [{string.Join(", ", activeNtTrades.Keys)}]");
                        return;
                    }

                    // DON'T remove from activeNtTrades yet - we need the details to create the closing order
                    // Will remove after successful order creation to prevent duplicate processing
                    LogAndPrint($"HEDGE_CLOSURE_SUCCESS: Found EXACT base_id '{notification.base_id}' in activeNtTrades. Will remove after creating closing order. Current entries: {activeNtTrades.Count}");
                }

                LogAndPrint($"INFO: Received hedge close notification for BaseID={notification.base_id}, Symbol={notification.nt_instrument_symbol}, Account={notification.nt_account_name}, Qty={notification.closed_hedge_quantity}, Action={notification.closed_hedge_action}, Reason='{notification.ClosureReason ?? "N/A"}'");

                // Check closure reason to determine if we should re-trade
                bool shouldCreateClosingOrder = ShouldCreateClosingOrderForReason(notification.ClosureReason);

                if (!shouldCreateClosingOrder)
                {
                    LogAndPrint($"INFO: Hedge closure reason '{notification.ClosureReason ?? "N/A"}' for BaseID={notification.base_id} indicates EA-managed closure. Skipping re-trading to prevent whack-a-mole effect.");
                    return; // Exit early without creating a closing order
                }

                LogAndPrint($"INFO: Hedge closure reason '{notification.ClosureReason ?? "N/A"}' for BaseID={notification.base_id} requires standard Addon reaction. Proceeding with re-trading.");

                    // Verify instrument and account match, as a safety check.
                    if (originalDetails.NtInstrumentSymbol != notification.nt_instrument_symbol || originalDetails.NtAccountName != notification.nt_account_name)
                    {
                        LogAndPrint($"ERROR: Mismatch in trade details for base_id: {notification.base_id}. " +
                                                        $"Stored: Inst={originalDetails.NtInstrumentSymbol}, Acc={originalDetails.NtAccountName}. " +
                                                        $"Notification: Inst={notification.nt_instrument_symbol}, Acc={notification.nt_account_name}. Aborting.");
                        return;
                    }

                    OrderAction finalNtAction;
                    // Determine Correct NT OrderAction
                    if (originalDetails.MarketPosition == MarketPosition.Short)
                    {
                        if (notification.closed_hedge_action.Equals("buy", StringComparison.OrdinalIgnoreCase))
                        {
                            finalNtAction = OrderAction.BuyToCover;
                        }
                        else
                        {
                            LogAndPrint($"ERROR: Unexpected closed_hedge_action '{notification.closed_hedge_action}' for original Short position. Expected 'buy'. BaseID: {notification.base_id}");
                            return;
                        }
                    }
                    else if (originalDetails.MarketPosition == MarketPosition.Long)
                    {
                        if (notification.closed_hedge_action.Equals("sell", StringComparison.OrdinalIgnoreCase))
                        {
                            finalNtAction = OrderAction.Sell;
                        }
                        else
                        {
                            LogAndPrint($"ERROR: Unexpected closed_hedge_action '{notification.closed_hedge_action}' for original Long position. Expected 'sell'. BaseID: {notification.base_id}");
                            return;
                        }
                    }
                    else // originalDetails.MarketPosition == MarketPosition.Flat or other
                    {
                        LogAndPrint($"ERROR: Original NT position for base_id '{notification.base_id}' is Flat or unknown ({originalDetails.MarketPosition}). Cannot process hedge closure.");
                        return;
                    }

                    // Determine Correct NT Quantity
                    int finalNtQuantity = originalDetails.Quantity; // originalDetails.Quantity is an int

                    if (finalNtQuantity <= 0)
                    {
                        LogAndPrint($"ERROR: Invalid original quantity {finalNtQuantity} for base_id '{notification.base_id}'. Cannot submit closing order.");
                        return;
                    }
                    
                    LogAndPrint($"INFO: Submitting NT Order: Action={finalNtAction}, Qty={finalNtQuantity} for BaseID={notification.base_id} (Original Pos: {originalDetails.MarketPosition}, Original Qty: {originalDetails.Quantity}, Hedge Close Action: {notification.closed_hedge_action})");

                    string orderName = $"HedgeClose_{notification.base_id}_{DateTime.UtcNow.Ticks}";
                    LogAndPrint($"DEBUG: Preparing to create HedgeClose Order: Name='{orderName}', Action={finalNtAction}, Qty={finalNtQuantity}, Instr='{instrument.FullName}', Type={OrderType.Market}, TIF={TimeInForce.Day}, Account='{account.Name}'");

                    Order orderToSubmit = null;
                    try
                    {
                        orderToSubmit = account.CreateOrder(instrument, finalNtAction, OrderType.Market, OrderEntry.Manual, TimeInForce.Day, finalNtQuantity, 0, 0, string.Empty, orderName, default(DateTime), null);
                        
                        if (orderToSubmit != null)
                        {
                            LogAndPrint($"DEBUG: Created HedgeClose Order object: Name='{orderToSubmit.Name}', InternalID={orderToSubmit.Id}, InitialState='{orderToSubmit.OrderState}', Action='{orderToSubmit.OrderAction}', Qty='{orderToSubmit.Quantity}'");
                            LogAndPrint($"DEBUG: Attempting to Submit HedgeClose Order: {orderToSubmit.Name} (InternalID: {orderToSubmit.Id})");
                            account.Submit(new[] { orderToSubmit });
                            LogAndPrint($"DEBUG: Call to Submit completed for HedgeClose Order: {orderToSubmit.Name} (InternalID: {orderToSubmit.Id})");

                            // MULTI_TRADE_GROUP_FIX: Update quantity tracking instead of removing entire BaseID
                            lock (_activeNtTradesLock)
                            {
                                if (activeNtTrades.TryGetValue(notification.base_id, out var tradeDetails))
                                {
                                    int closingQuantity = (int)Math.Round(notification.closed_hedge_quantity);
                                    tradeDetails.RemainingQuantity -= closingQuantity;
                                    LogAndPrint($"MULTI_TRADE_GROUP_HEDGE_CLOSE: Reduced remaining quantity for BaseID {notification.base_id} by {closingQuantity}. Remaining: {tradeDetails.RemainingQuantity}/{tradeDetails.TotalQuantity}");

                                    if (tradeDetails.RemainingQuantity <= 0)
                                    {
                                        // All trades with this BaseID are now closed
                                        activeNtTrades.TryRemove(notification.base_id, out _);
                                        LogAndPrint($"CLOSURE_SYNC_FIX: All trades closed for BaseID {notification.base_id}. Removed from tracking. Remaining entries: {activeNtTrades.Count}");
                                    }
                                    else
                                    {
                                        LogAndPrint($"CLOSURE_SYNC_PARTIAL: BaseID {notification.base_id} still has {tradeDetails.RemainingQuantity} trades remaining. Keeping in tracking.");
                                    }
                                }
                                else
                                {
                                    LogAndPrint($"CLOSURE_SYNC_ERROR: BaseID {notification.base_id} not found in activeNtTrades during hedge close processing.");
                                }
                            }

                            if (trackedHedgeClosingOrderIds != null)
                            {
                                 trackedHedgeClosingOrderIds.Add(orderToSubmit.Id.ToString());
                                 LogAndPrint($"HEDGE_CLOSURE_TRACKING: Added order {orderToSubmit.Id} ('{orderToSubmit.Name}') to tracked hedge closing orders. Total tracked: {trackedHedgeClosingOrderIds.Count}");
                            }
                            else
                            {
                                LogAndPrint($"ERROR: trackedHedgeClosingOrderIds is null. Cannot track order {orderToSubmit.Name}");
                            }
                        }
                        else
                        {
                            LogAndPrint($"ERROR: Failed to create HedgeClose market order (CreateOrder returned null) for BaseID {notification.base_id}. Order Name: {orderName}");
                        }
                    }
                    catch (Exception ex)
                    {
                        LogAndPrint($"ERROR: EXCEPTION during HedgeClose order submission for '{orderToSubmit?.Name ?? orderName}': {ex.ToString()}");
                    }
            }
            catch (Exception ex)
            {
                LogAndPrint($"ERROR: Error processing hedge close notification on NT thread for BaseID {notification?.base_id}: {ex.Message}\nStackTrace: {ex.StackTrace}");
            }
        });

            // Send success response to BridgeApp
            SendSuccessResponse(response, "Notification received and queued for processing.");
        }
        catch (Exception ex)
        {
            LogAndPrint($"MT5_TO_NT_CLOSURE: CRITICAL ERROR processing hedge close notification: {ex.Message}");
            SendErrorResponse(response, HttpStatusCode.InternalServerError, "Internal error processing hedge close notification");
        }
    }

    /// <summary>
    /// Determines whether a closing order should be created based on the hedge closure reason.
    /// This prevents the whack-a-mole effect where EA-managed closures trigger unnecessary re-trading.
    /// </summary>
    /// <param name="closureReason">The closure reason from the MT5 EA</param>
    /// <returns>True if a closing order should be created, false otherwise</returns>
    private bool ShouldCreateClosingOrderForReason(string closureReason)
    {
        if (string.IsNullOrEmpty(closureReason))
        {
            // If no closure reason is provided, default to creating closing order for backward compatibility
            LogAndPrint("WARNING: No closure reason provided. Defaulting to creating closing order for backward compatibility.");
            return true;
        }

        // Define closure reasons that should NOT trigger re-trading (EA-managed closures)
        // These are internal EA operations that don't require NinjaTrader position closure
        // WHACK-A-MOLE FIX: Most EA closures should NOT trigger NT position closure
        var eaManagedClosureReasons = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            // Internal EA adjustment and rebalancing operations
            "EA_ADJUSTMENT_CLOSE",              // EA adjustment closure (internal rebalancing)
            "EA_INTERNAL_REBALANCE",            // EA internal rebalancing operations

            // Standard EA hedge management operations - these should NOT trigger NT closure
            "EA_PARALLEL_ARRAY_CLOSE",          // Standard EA closure due to parallel array management
            "EA_COMMENT_BASED_CLOSE",           // EA closure based on comment parsing
            "EA_RECONCILED_AND_CLOSED",         // EA closure when trade group is fully reconciled
            "EA_PARALLEL_ARRAY_ORPHAN_CLOSE",   // EA closure from parallel arrays but no group
            "EA_COMMENT_ORPHAN_CLOSE",          // EA closure from comment but no group
            "EA_OLD_MAP_FALLBACK_CLOSE",        // EA closure using old map fallback

            // EA automatic closure operations - these should NOT trigger NT closure
            "EA_GLOBALFUTURES_ZERO_CLOSE",      // EA closes hedge when globalFutures reaches zero (internal balancing)
            "EA_TRAILING_STOP_CLOSE",           // EA trailing stop triggered closure (EA-managed)
        };

        // Define closure reasons that SHOULD trigger re-trading (legitimate user-initiated closures)
        // ONLY when the user or external systems close MT5 hedges should NT positions also close
        var legitimateClosureReasons = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            // User-initiated closures that should close NT positions
            "MANUAL_MT5_CLOSE",                 // Manual closure in MT5 platform by user
            "EA_MANUAL_CLOSE",                  // Manual closure through EA interface by user

            // User-set stop loss/take profit closures (not EA-managed)
            "USER_STOP_LOSS_CLOSE",             // User-set stop loss triggered
            "USER_TAKE_PROFIT_CLOSE",           // User-set take profit triggered

            // External system closures that should close NT positions
            "NT_ORIGINAL_TRADE_CLOSED",         // Original NinjaTrader trade was closed
            "BROKER_MARGIN_CALL",               // Broker-initiated closure
            "BROKER_STOP_OUT",                  // Broker stop-out

            // Legacy/unknown closures - default to closing for safety
            "UNKNOWN_MT5_CLOSE",                // Unknown MT5 closure (default EA reason) - safer to close NT position
            "EA_STOP_LOSS_CLOSE",               // Legacy - MT5 hedge closed by stop loss
            "EA_TAKE_PROFIT_CLOSE",             // Legacy - MT5 hedge closed by take profit
        };

        bool isEaManaged = eaManagedClosureReasons.Contains(closureReason);
        bool isLegitimate = legitimateClosureReasons.Contains(closureReason);

        if (isEaManaged)
        {
            // BIDIRECTIONAL HEDGING FIX: For bidirectional hedging, when MT5 closes a hedge,
            // we WANT to close the corresponding NT trade to maintain synchronization
            LogAndPrint($"CLOSURE_LOGIC: Reason '{closureReason}' is EA-managed. WILL create closing order for bidirectional hedging.");
            return true;  // Changed from false to true for bidirectional hedging
        }
        else if (isLegitimate)
        {
            LogAndPrint($"CLOSURE_LOGIC: Reason '{closureReason}' is legitimate. Will create closing order.");
            return true;
        }
        else
        {
            // Unknown closure reason - log warning and default to creating closing order for safety
            LogAndPrint($"WARNING: Unknown closure reason '{closureReason}'. Defaulting to creating closing order for safety.");
            return true;
        }
    }

    private void SendSuccessResponse(HttpListenerResponse response, string message)
    {
        string responseString = $"{{\"status\": \"success\", \"message\": \"{message}\"}}";
        byte[] buffer = Encoding.UTF8.GetBytes(responseString);
        response.ContentType = "application/json";
        response.ContentLength64 = buffer.Length;
        response.StatusCode = (int)HttpStatusCode.OK;
        using (System.IO.Stream output = response.OutputStream)
        {
            output.Write(buffer, 0, buffer.Length);
        }
    }

    private void SendErrorResponse(HttpListenerResponse response, HttpStatusCode statusCode, string errorMessage)
    {
        string responseString = $"{{\"status\": \"error\", \"message\": \"{errorMessage}\"}}";
        byte[] buffer = Encoding.UTF8.GetBytes(responseString);
        response.ContentType = "application/json";
        response.ContentLength64 = buffer.Length;
        response.StatusCode = (int)statusCode;
        using (System.IO.Stream output = response.OutputStream)
        {
            output.Write(buffer, 0, buffer.Length);
        }
    }

    private void StopHttpListener()
    {
        if (!isListenerRunning && httpListener == null) // If already stopped or never started
        {
            NinjaTrader.Code.Output.Process("MultiStratManager HTTP Listener already stopped or not started.", PrintTo.OutputTab1);
            return;
        }
        
        NinjaTrader.Code.Output.Process("MultiStratManager: Attempting to stop HTTP Listener...", PrintTo.OutputTab1);
        
        // Signal the loop in HandleIncomingConnections to exit
        // This must be set BEFORE calling Stop/Close on the listener,
        // as those calls can cause GetContext() to throw immediately.
        isListenerRunning = false;

        try
        {
            if (httpListener != null)
            {
                if (httpListener.IsListening)
                {
                    NinjaTrader.Code.Output.Process("MultiStratManager: Calling HttpListener.Stop().", PrintTo.OutputTab1);
                    httpListener.Stop(); // This should make GetContext throw an exception.
                }
                NinjaTrader.Code.Output.Process("MultiStratManager: Calling HttpListener.Close().", PrintTo.OutputTab1);
                httpListener.Close();
            }
        }
        catch (Exception ex)
        {
            NinjaTrader.Code.Output.Process($"Exception during HttpListener.Stop() or .Close(): {ex.Message}", PrintTo.OutputTab1);
        }
        finally
        {
            httpListener = null; // Dereference
        }

        if (listenerThread != null) // Check if thread object exists
        {
            NinjaTrader.Code.Output.Process($"MultiStratManager: Listener thread state: {listenerThread.ThreadState}. IsAlive: {listenerThread.IsAlive}", PrintTo.OutputTab1);
            if (listenerThread.IsAlive)
            {
                NinjaTrader.Code.Output.Process("MultiStratManager: Waiting for listener thread to join...", PrintTo.OutputTab1);
                if (!listenerThread.Join(TimeSpan.FromSeconds(3))) // Wait for 3 seconds
                {
                    NinjaTrader.Code.Output.Process("MultiStratManager: Listener thread did not join in time. Consider if Abort is necessary (currently not implemented).", PrintTo.OutputTab1);
                    // Thread.Abort is obsolete and dangerous. The loop should exit due to isListenerRunning = false and GetContext throwing.
                }
                else
                {
                    NinjaTrader.Code.Output.Process("MultiStratManager: Listener thread joined successfully.", PrintTo.OutputTab1);
                }
            }
            else
            {
                 NinjaTrader.Code.Output.Process("MultiStratManager: Listener thread was not alive before Join attempt.", PrintTo.OutputTab1);
            }
        }
        listenerThread = null; // Dereference
        NinjaTrader.Code.Output.Process("MultiStratManager HTTP Listener stopped.", PrintTo.OutputTab1);
    }

    public async Task<Tuple<bool, string>> PingBridgeAsync(string bridgeBaseUrl)
    {
        if (string.IsNullOrWhiteSpace(bridgeBaseUrl))
        {
            return Tuple.Create(false, "Bridge base URL is null or empty.");
        }

        Uri baseUri = new Uri(bridgeBaseUrl);
        string pingUrl = $"{baseUri.Scheme}://{baseUri.Authority}/health?source=addon"; // Append source parameter
        NinjaTrader.Code.Output.Process($"[MultiStratManager] Pinging bridge at URL: {pingUrl}", PrintTo.OutputTab1);

        // Using a new HttpClient instance for this specific operation as per plan,
        // though the class already has a static httpClient field.
        // This allows for specific timeout settings for the ping.
        using (HttpClient client = new HttpClient())
        {
            client.Timeout = TimeSpan.FromSeconds(5); // 5-second timeout
            try
            {
                HttpResponseMessage response = await client.GetAsync(pingUrl);
                string responseBody = await response.Content.ReadAsStringAsync();

                if (response.IsSuccessStatusCode)
                {
                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping successful. Status: {response.StatusCode}. Response: {responseBody}", PrintTo.OutputTab1);
                    try
                    {
                        // Assuming SimpleJson class is in NinjaTrader.NinjaScript.AddOns namespace
                        var healthStatus = NinjaTrader.NinjaScript.AddOns.SimpleJson.DeserializeObject<Dictionary<string, object>>(responseBody);
                        if (healthStatus != null && healthStatus.TryGetValue("status", out object statusObj) && "healthy".Equals(statusObj?.ToString(), StringComparison.OrdinalIgnoreCase))
                        {
                            string queueSize = healthStatus.TryGetValue("queue_size", out object q) ? q.ToString() : "N/A";
                            string netPos = healthStatus.TryGetValue("net_position", out object np) ? np.ToString() : "N/A";
                            string hedgeSize = healthStatus.TryGetValue("hedge_size", out object hs) ? hs.ToString() : "N/A";
                            return Tuple.Create(true, $"Bridge is healthy. Status: {statusObj}, Queue: {queueSize}, Net Position: {netPos}, Hedge Size: {hedgeSize}");
                        }
                        else
                        {
                            return Tuple.Create(true, $"Ping successful, but unexpected healthy response content: {responseBody}");
                        }
                    }
                    catch (Exception exJson)
                    {
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping successful, but failed to parse health response: {exJson.Message}. Raw response: {responseBody}", PrintTo.OutputTab1);
                        return Tuple.Create(true, $"Ping successful, but failed to parse health response: {exJson.Message}. Raw response: {responseBody}");
                    }
                }
                else
                {
                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping failed. Status: {response.StatusCode}. Response: {responseBody}", PrintTo.OutputTab1);
                    return Tuple.Create(false, $"Ping failed. Status: {response.StatusCode}. Response: {responseBody}");
                }
            }
            catch (HttpRequestException httpEx)
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping failed (HTTP Error): {httpEx.Message} for URL {pingUrl}", PrintTo.OutputTab1);
                return Tuple.Create(false, $"Ping failed (HTTP Error): {httpEx.Message}");
            }
            catch (TaskCanceledException tex) // Catches timeouts
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping failed (Timeout): {tex.Message} for URL {pingUrl}", PrintTo.OutputTab1);
                return Tuple.Create(false, $"Ping failed (Timeout): {tex.Message}");
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Ping failed (General Error): {ex.Message} for URL {pingUrl} | StackTrace: {ex.StackTrace}", PrintTo.OutputTab1);
                return Tuple.Create(false, $"Ping failed (Error): {ex.Message}");
            }
        }
    }
    /// <summary>
    /// Registers a strategy for state monitoring.
    /// </summary>
    /// <param name="strategy">The strategy to monitor.</param>
    public static void RegisterStrategyForMonitoring(StrategyBase strategy)
    {
        if (strategy != null && !monitoredStrategies.Contains(strategy))
        {
            monitoredStrategies.Add(strategy);
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Registered {strategy.Name} for state monitoring. Current state: {strategy.State}", PrintTo.OutputTab1);
            // Optionally, immediately notify of current state
            // OnStrategyExternalStateChange?.Invoke(strategy, strategy.State);
        }
    }

    /// <summary>
    /// Unregisters a strategy from state monitoring.
    /// </summary>
    /// <param name="strategy">The strategy to unmonitor.</param>
    public static void UnregisterStrategyForMonitoring(StrategyBase strategy)
    {
        if (strategy != null && monitoredStrategies.Contains(strategy))
        {
            monitoredStrategies.Remove(strategy);
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Unregistered {strategy.Name} from state monitoring.", PrintTo.OutputTab1);
        }
    }

    /// <summary>
    /// Requests a state change for the specified strategy.
    /// This method handles enabling and disabling strategies by setting their state
    /// to Active or Terminated respectively.
    /// </summary>
    /// <param name="strategy">The strategy instance to modify.</param>
    /// <param name="newState">The desired state (State.Active to enable, State.Terminated to disable).</param>
    public static void RequestStrategyStateChange(NinjaTrader.NinjaScript.StrategyBase strategy, NinjaTrader.NinjaScript.State newState)
    {
        if (strategy == null)
        {
            NinjaTrader.Code.Output.Process("[MultiStratManager] RequestStrategyStateChange called with null strategy.", PrintTo.OutputTab1);
            return;
        }

        // Validate that the requested state is one we expect for enabling/disabling
        if (newState != State.Active && newState != State.Terminated)
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager] RequestStrategyStateChange called with unexpected state: {newState}. Expected State.Active or State.Terminated.", PrintTo.OutputTab1);
            return;
        }

        NinjaTrader.Code.Output.Process($"[MultiStratManager] Requesting state change for {strategy.Name} to {newState}", PrintTo.OutputTab1);

        try
        {
            // ADDED CHECK: Prevent trying to set Terminated/Finalized to Active
            if (newState == State.Active && (strategy.State == State.Terminated || strategy.State == State.Finalized))
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] Attempt to set strategy '{strategy.Name}' to Active from {strategy.State} state. This is not allowed by the API. Operation aborted.", PrintTo.OutputTab1);
                return; // Abort the state change
            }

            // Check if the state change is actually needed
            if (strategy.State != newState)
            {
                // Execute the state change on the UI thread to ensure compatibility with NT core components
                Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    try
                    {
                        // Log before the state change
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] Calling SetState({newState}) for {strategy.Name}. Current state: {strategy.State}", PrintTo.OutputTab1);

                        // Perform the state change
                        strategy.SetState(newState);

                        // Log after the state change
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] SetState({newState}) called successfully for {strategy.Name}. New state: {strategy.State}", PrintTo.OutputTab1);

                        // Log after the state change
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] SetState({newState}) called successfully for {strategy.Name}. New state: {strategy.State}", PrintTo.OutputTab1);

                        // Attempt to notify the Control Center to refresh its strategy display
                        // This is a best effort - the actual refresh mechanism depends on NinjaTrader's internal implementation
                        try
                        {
                            // Force a property changed notification on the strategy
                            // This might help trigger UI updates in the Control Center
                            if (strategy is INotifyPropertyChanged notifyPropertyChanged)
                            {
                                var propertyInfo = strategy.GetType().GetProperty("State");
                                if (propertyInfo != null)
                                {
                                    NinjaTrader.Code.Output.Process($"[MultiStratManager] Attempting to trigger PropertyChanged for State property", PrintTo.OutputTab1);

                                    // Use reflection to invoke the OnPropertyChanged method if it exists
                                    var methodInfo = strategy.GetType().GetMethod("OnPropertyChanged",
                                        System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);

                                    if (methodInfo != null)
                                    {
                                        methodInfo.Invoke(strategy, new object[] { "State" });
                                        NinjaTrader.Code.Output.Process($"[MultiStratManager] Successfully triggered PropertyChanged for State", PrintTo.OutputTab1);
                                    }
                                }
                            }
                        }
                        catch (Exception refreshEx)
                        {
                            // Non-critical error - log but continue
                            NinjaTrader.Code.Output.Process($"[MultiStratManager] Non-critical error while attempting to refresh UI: {refreshEx.Message}", PrintTo.OutputTab1);
                        }
                    }
                    catch (Exception changeStateException)
                    {
                        NinjaTrader.Code.Output.Process($"[MultiStratManager] Error calling SetState({newState}) for {strategy.Name}: {changeStateException.Message}\nStackTrace: {changeStateException.StackTrace}", PrintTo.OutputTab1);
                    }
                });
            }
            else
            {
                NinjaTrader.Code.Output.Process($"[MultiStratManager] State for {strategy.Name} is already {newState}. No action taken.", PrintTo.OutputTab1);
                // Even if no action is taken, it might be useful to notify if the current state is what UI expects
                // For example, if the UI tried to enable an already enabled strategy,
                // we might still want to confirm the state back to the UI.
                // This part can be expanded based on UI interaction needs.
            }
        }
        catch (Exception ex)
        {
            NinjaTrader.Code.Output.Process($"[MultiStratManager] Error in RequestStrategyStateChange for {strategy.Name}: {ex.Message}\nStackTrace: {ex.StackTrace}", PrintTo.OutputTab1);
        }
    }

    /// <summary>
    /// Finds the original opening trade's base_id that corresponds to a closing execution
    /// IMPORTANT: This should only return a match if the order is explicitly designed to close a specific position
    /// </summary>
    /// <param name="e">The closing execution event args</param>
    /// <returns>The base_id of the original opening trade, or null if not found</returns>
    private string FindOriginalTradeBaseId(ExecutionEventArgs e)
    {
        if (e?.Execution?.Order == null) return null;

        string orderName = e.Execution.Order.Name?.ToUpper() ?? "";
        var orderAction = e.Execution.Order.OrderAction;
        var instrument = e.Execution.Instrument.FullName;
        var account = e.Execution.Account.Name;

        LogAndPrint($"CLOSURE_SEARCH_DEBUG: Searching for closure match. Order: '{e.Execution.Order.Name}', Action: {orderAction}, Instrument: {instrument}, Account: {account}");
        LogAndPrint($"CLOSURE_SEARCH_DEBUG: activeNtTrades contains {activeNtTrades.Count} entries");

        // CRITICAL FIX: Only detect closure if order name explicitly indicates closure
        // This prevents false positives where new trades are mistaken for closures
        LogAndPrint($"CLOSURE_CONSERVATIVE_LOGIC: Checking for explicit closure indicators only");

        string potentialClosureBaseId = null;

        // CONSERVATIVE CLOSURE DETECTION: Only detect closures with explicit indicators
        if (!string.IsNullOrEmpty(orderName))
        {
            // Check for explicit closure order names
            if (orderName.Contains("CLOSE") || orderName.Contains("EXIT") ||
                orderName.Contains("TP") || orderName.Contains("SL"))
            {
                LogAndPrint($"CLOSURE_BY_NAME: Order '{e.Execution.Order.Name}' identified as closing order by name");

                // Find the corresponding trade in activeNtTrades
                lock (_activeNtTradesLock)
                {
                    LogAndPrint($"CLOSURE_BY_NAME: Looking for corresponding trade in activeNtTrades ({activeNtTrades.Count} entries)");

                    // Look for any trade that this closure order would close
                    foreach (var kvp in activeNtTrades)
                    {
                        string baseId = kvp.Key;
                        var tradeInfo = kvp.Value;

                        // Check if this execution matches the stored trade info
                        bool instrumentMatches = tradeInfo.NtInstrumentSymbol == instrument;
                        bool accountMatches = tradeInfo.NtAccountName == account;

                        if (instrumentMatches && accountMatches)
                        {
                            // Check if this execution closes the existing position (opposite action)
                            var storedPosition = tradeInfo.MarketPosition;
                            bool isClosingAction = false;

                            // If original was a long position and we're selling/covering, it's a close
                            if (storedPosition == MarketPosition.Long &&
                                (orderAction == OrderAction.Sell || orderAction == OrderAction.SellShort))
                            {
                                isClosingAction = true;
                                LogAndPrint($"CLOSURE_BY_NAME: Long position + Sell/SellShort = CLOSURE DETECTED");
                            }
                            // If original was a short position and we're buying to cover, it's a close
                            else if (storedPosition == MarketPosition.Short &&
                                    (orderAction == OrderAction.BuyToCover || orderAction == OrderAction.Buy))
                            {
                                isClosingAction = true;
                                LogAndPrint($"CLOSURE_BY_NAME: Short position + BuyToCover/Buy = CLOSURE DETECTED");
                            }

                            if (isClosingAction)
                            {
                                LogAndPrint($"CLOSURE_BY_NAME_MATCH: Found closure for base_id {baseId} (Position: {storedPosition}, Action: {orderAction})");
                                potentialClosureBaseId = baseId;
                                break; // Found a match, stop searching
                            }
                        }
                    }
                }
            }
            else
            {
                LogAndPrint($"CLOSURE_CONSERVATIVE: Order name '{orderName}' does not contain explicit closure indicators - treating as entry trade");
            }
        }
        else
        {
            LogAndPrint($"CLOSURE_BY_NAME: Order has no name - proceeding to position-based closure detection");
        }

        // ENHANCED: Position-based closure detection for orders without explicit names
        // This is critical for detecting manual closures that don't have explicit order names
        if (string.IsNullOrEmpty(potentialClosureBaseId))
        {
            LogAndPrint($"CLOSURE_POSITION_BASED: Attempting position-based closure detection for unnamed order");
            potentialClosureBaseId = FindClosureByPositionAnalysis(orderAction, instrument, account);
        }

        if (!string.IsNullOrEmpty(potentialClosureBaseId))
        {
            LogAndPrint($"CLOSURE_POSITION_SUCCESS: Position-based closure detected for base_id {potentialClosureBaseId} (Order: '{e.Execution.Order.Name}', Action: {orderAction})");
            return potentialClosureBaseId;
        }

        LogAndPrint($"CLOSURE_POSITION_NONE: No position closure detected for order '{e.Execution.Order.Name}' (Action: {orderAction}). Treating as new entry trade.");
        return null;
    }

    /// <summary>
    /// Enhanced position-based closure detection that analyzes order actions and existing positions
    /// </summary>
    private string FindClosureByPositionAnalysis(OrderAction orderAction, string instrument, string account)
    {
        lock (_activeNtTradesLock)
        {
            LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Analyzing {activeNtTrades.Count} active trades for potential closure");

            // Find trades that could be closed by this order action
            var potentialClosures = new List<KeyValuePair<string, OriginalTradeDetails>>();

            foreach (var kvp in activeNtTrades)
            {
                var storedTrade = kvp.Value;

                // Must be same instrument and account
                if (storedTrade.NtInstrumentSymbol != instrument || storedTrade.NtAccountName != account)
                {
                    LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Skipping BaseID: {kvp.Key} - Different instrument/account. Stored: {storedTrade.NtInstrumentSymbol}/{storedTrade.NtAccountName}, Current: {instrument}/{account}");
                    continue;
                }

                bool isOppositeAction = false;

                // ENHANCED: Check if this order action is opposite to the stored position
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Checking BaseID: {kvp.Key} - StoredPosition: {storedTrade.MarketPosition}, StoredAction: {storedTrade.OriginalOrderAction}, CurrentAction: {orderAction}");

                // Case 1: Stored trade was a Long position (Buy action) and current is Sell action
                if (storedTrade.MarketPosition == MarketPosition.Long &&
                    (orderAction == OrderAction.Sell || orderAction == OrderAction.SellShort))
                {
                    isOppositeAction = true;
                    LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Found potential long closure - BaseID: {kvp.Key}, Original: Long, Current: {orderAction}");
                }
                // Case 2: Stored trade was a Short position (Sell action) and current is Buy action
                else if (storedTrade.MarketPosition == MarketPosition.Short &&
                        (orderAction == OrderAction.BuyToCover || orderAction == OrderAction.Buy))
                {
                    isOppositeAction = true;
                    LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Found potential short closure - BaseID: {kvp.Key}, Original: Short, Current: {orderAction}");
                }
                else
                {
                    LogAndPrint($"CLOSURE_POSITION_ANALYSIS: No closure match for BaseID: {kvp.Key} - Position: {storedTrade.MarketPosition}, OriginalAction: {storedTrade.OriginalOrderAction}, CurrentAction: {orderAction}");
                }

                if (isOppositeAction)
                {
                    potentialClosures.Add(kvp);
                }
            }

            if (potentialClosures.Count == 0)
            {
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: No potential closures found for {orderAction} on {instrument}");
                return null;
            }
            else if (potentialClosures.Count == 1)
            {
                // Single match - most likely scenario
                string baseId = potentialClosures[0].Key;
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Single closure match found - BaseID: {baseId}");
                return baseId;
            }
            else
            {
                // FIFO: Multiple matches found - use First In, First Out (oldest trade first)
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Multiple potential closures found ({potentialClosures.Count}). Using FIFO (oldest trade first) to resolve ambiguity.");
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: Potential matches were:");
                foreach (var closure in potentialClosures)
                {
                    LogAndPrint($"CLOSURE_POSITION_ANALYSIS:   - BaseID: {closure.Key}, Position: {closure.Value.MarketPosition}, Action: {closure.Value.OriginalOrderAction}, Timestamp: {closure.Value.Timestamp}");
                }

                // Use FIFO - select the oldest trade (earliest timestamp)
                var oldestTrade = potentialClosures.OrderBy(kvp => kvp.Value.Timestamp).First();
                string baseId = oldestTrade.Key;
                LogAndPrint($"CLOSURE_POSITION_ANALYSIS: FIFO selection - BaseID: {baseId} (oldest trade)");
                return baseId;
            }
        }
    }

    /// <summary>
    /// OFFICIAL NINJATRADER BEST PRACTICE: Comprehensive Entry vs Closure Detection
    /// Based on official NinjaTrader documentation for OnExecutionUpdate and OnPositionUpdate
    /// </summary>
    private bool DetectTradeClosureByExecution(ExecutionEventArgs e)
    {
        if (e?.Execution == null || e.Execution.Order == null) return false;

        string orderName = e.Execution.Order.Name ?? "";
        OrderAction orderAction = e.Execution.Order.OrderAction;
        string instrumentName = e.Execution.Instrument?.FullName ?? "Unknown";
        string accountName = e.Execution.Account?.Name ?? "Unknown";
        MarketPosition executionMarketPosition = e.Execution.MarketPosition;

        LogAndPrint($"ENTRY_VS_CLOSURE: Analyzing execution - OrderName: '{orderName}', Action: {orderAction}, MarketPosition: {executionMarketPosition}, Instrument: {instrumentName}");

        // METHOD 1: Order Name Analysis (Most Reliable for Manual Trades)
        if (IsClosingOrderByName(orderName))
        {
            LogAndPrint($"CLOSURE_DETECTED: Order '{orderName}' identified as closing order by name");
            return true;
        }

        // METHOD 2: OrderAction Analysis (Official NinjaTrader Pattern)
        if (IsExitOrderAction(orderAction))
        {
            LogAndPrint($"CLOSURE_DETECTED: OrderAction {orderAction} is an exit action");
            return true;
        }

        // METHOD 3: Position State Analysis (Most Reliable for Automated Detection)
        if (IsPositionClosingExecution(e))
        {
            LogAndPrint($"CLOSURE_DETECTED: Execution reduces position toward flat");
            return true;
        }

        LogAndPrint($"ENTRY_DETECTED: Execution identified as NEW ENTRY TRADE");
        return false;
    }

    /// <summary>
    /// OFFICIAL NINJATRADER: Detects if OrderAction represents an exit/closure
    /// Based on official OrderAction documentation
    /// IMPORTANT: OrderAction.Sell can be either entry (SellShort) or exit (Sell to close long)
    /// We need position context to determine the intent
    /// </summary>
    private bool IsExitOrderAction(OrderAction orderAction)
    {
        // From Official NinjaTrader Documentation:
        // ONLY BuyToCover is explicitly an exit action
        // OrderAction.Sell can be either entry (SellShort) or exit (Sell to close long)
        // OrderAction.Buy can be either entry (Buy to open long) or exit (Buy to cover short)

        // We should NOT classify Sell/Buy as exits without position context
        // Only BuyToCover is explicitly an exit action
        return orderAction == OrderAction.BuyToCover;
    }

    /// <summary>
    /// OFFICIAL NINJATRADER: Detects if execution represents a new entry
    /// Based on official OrderAction documentation
    /// IMPORTANT: OrderAction.Buy and OrderAction.Sell can be either entry or exit
    /// We need position context to determine the intent
    /// </summary>
    private bool IsEntryOrderAction(OrderAction orderAction)
    {
        // From Official NinjaTrader Documentation:
        // ONLY SellShort is explicitly an entry action
        // OrderAction.Buy can be either entry (Buy to open long) or exit (Buy to cover short)
        // OrderAction.Sell can be either entry (SellShort) or exit (Sell to close long)

        // For now, we'll consider all actions as potential entries
        // and rely on position analysis to determine if it's actually a closure
        return orderAction == OrderAction.Buy ||
               orderAction == OrderAction.Sell ||
               orderAction == OrderAction.SellShort ||
               orderAction == OrderAction.BuyToCover;
    }

    /// <summary>
    /// OFFICIAL NINJATRADER: Position State Analysis for Closure Detection
    /// Based on official OnPositionUpdate documentation and best practices
    /// </summary>
    private bool IsPositionClosingExecution(ExecutionEventArgs e)
    {
        if (e?.Execution == null || e.Execution.Order == null) return false;

        string instrumentName = e.Execution.Instrument?.FullName ?? "Unknown";
        string accountName = e.Execution.Account?.Name ?? "Unknown";
        OrderAction orderAction = e.Execution.Order.OrderAction;
        int executionQuantity = e.Execution.Quantity;

        lock (_activeNtTradesLock)
        {
            // Find existing positions for this instrument/account
            var existingPositions = activeNtTrades.Values
                .Where(trade => trade.NtInstrumentSymbol == instrumentName &&
                               trade.NtAccountName == accountName)
                .ToList();

            if (existingPositions.Count == 0)
            {
                LogAndPrint($"POSITION_ANALYSIS: No existing positions found - this is a NEW ENTRY");
                return false;
            }

            // Calculate current net position
            int currentLongQuantity = existingPositions
                .Where(p => p.MarketPosition == MarketPosition.Long)
                .Sum(p => p.Quantity);

            int currentShortQuantity = existingPositions
                .Where(p => p.MarketPosition == MarketPosition.Short)
                .Sum(p => p.Quantity);

            int netPosition = currentLongQuantity - currentShortQuantity;

            LogAndPrint($"POSITION_ANALYSIS: Current position - Long: {currentLongQuantity}, Short: {currentShortQuantity}, Net: {netPosition}");

            // Determine if this execution reduces the net position (closure) or increases it (entry)
            bool isClosing = false;

            if (netPosition > 0) // Currently net long
            {
                // Sell actions reduce long position (closure)
                if (orderAction == OrderAction.Sell || orderAction == OrderAction.SellShort)
                {
                    isClosing = true;
                    LogAndPrint($"POSITION_ANALYSIS: {orderAction} reduces net long position - CLOSURE");
                }
                else
                {
                    LogAndPrint($"POSITION_ANALYSIS: {orderAction} increases net long position - NEW ENTRY");
                }
            }
            else if (netPosition < 0) // Currently net short
            {
                // Buy actions reduce short position (closure)
                if (orderAction == OrderAction.Buy || orderAction == OrderAction.BuyToCover)
                {
                    isClosing = true;
                    LogAndPrint($"POSITION_ANALYSIS: {orderAction} reduces net short position - CLOSURE");
                }
                else
                {
                    LogAndPrint($"POSITION_ANALYSIS: {orderAction} increases net short position - NEW ENTRY");
                }
            }
            else // netPosition == 0 (flat)
            {
                LogAndPrint($"POSITION_ANALYSIS: Currently flat - any execution is NEW ENTRY");
                isClosing = false;
            }

            return isClosing;
        }
    }

    /// <summary>
    /// OFFICIAL NINJATRADER: Comprehensive New Entry Detection
    /// Based on official documentation best practices - ensures no new entries are missed
    /// </summary>
    private bool IsNewEntryTrade(ExecutionEventArgs e)
    {
        if (e?.Execution == null || e.Execution.Order == null) return false;

        string orderName = e.Execution.Order.Name ?? "";
        OrderAction orderAction = e.Execution.Order.OrderAction;
        string instrumentName = e.Execution.Instrument?.FullName ?? "Unknown";
        string accountName = e.Execution.Account?.Name ?? "Unknown";

        LogAndPrint($"ENTRY_DETECTION: Analyzing execution - OrderName: '{orderName}', Action: {orderAction}, Instrument: {instrumentName}");

        // METHOD 1: OrderAction Analysis (Primary Method)
        if (IsEntryOrderAction(orderAction))
        {
            LogAndPrint($"ENTRY_DETECTION: OrderAction {orderAction} is an entry action");

            // METHOD 2: Confirm it's not actually a closure by checking position state
            if (!IsPositionClosingExecution(e))
            {
                LogAndPrint($"ENTRY_CONFIRMED: Position analysis confirms this is a NEW ENTRY");
                return true;
            }
            else
            {
                LogAndPrint($"ENTRY_OVERRIDE: OrderAction suggests entry but position analysis indicates closure");
                return false;
            }
        }

        // METHOD 3: Order Name Analysis for Entry Detection
        if (IsEntryOrderByName(orderName))
        {
            LogAndPrint($"ENTRY_DETECTION: Order '{orderName}' identified as entry order by name");
            return true;
        }

        LogAndPrint($"ENTRY_DETECTION: Execution is NOT a new entry");
        return false;
    }

    /// <summary>
    /// Checks if order name indicates it's an entry order
    /// Based on common NinjaTrader naming conventions
    /// </summary>
    private bool IsEntryOrderByName(string orderName)
    {
        if (string.IsNullOrEmpty(orderName)) return false;

        string upperName = orderName.ToUpper();

        // Common entry order names in NinjaTrader
        return upperName.Contains("ENTRY") ||
               upperName.Contains("ENTER") ||
               upperName.Contains("LONG") ||
               upperName.Contains("SHORT") ||
               upperName.Contains("BUY") ||
               upperName.Contains("SELL") ||
               upperName == "ENTRY";           // Exact match for simple entry
    }

    /// <summary>
    /// Checks if order name indicates it's a closing order
    /// Based on common NinjaTrader naming conventions
    /// </summary>
    private bool IsClosingOrderByName(string orderName)
    {
        if (string.IsNullOrEmpty(orderName)) return false;

        string upperName = orderName.ToUpper();

        // Common closing order names in NinjaTrader
        return upperName.Contains("CLOSE") ||
               upperName.Contains("EXIT") ||
               upperName.Contains("STOP") ||
               upperName.Contains("TARGET") ||
               upperName.Contains("TP") ||     // Take Profit
               upperName.Contains("SL") ||     // Stop Loss
               upperName == "CLOSE";           // Exact match for manual close
    }

    /// <summary>
    /// Checks if this execution will close an existing position
    /// This is the most reliable method according to NinjaTrader docs
    /// </summary>
    private bool WillExecutionClosePosition(ExecutionEventArgs e)
    {
        if (e?.Execution == null || e.Execution.Order == null) return false;

        string instrumentName = e.Execution.Instrument?.FullName ?? "Unknown";
        string accountName = e.Execution.Account?.Name ?? "Unknown";
        OrderAction orderAction = e.Execution.Order.OrderAction;
        int executionQuantity = e.Execution.Quantity;

        lock (_activeNtTradesLock)
        {
            // Find existing positions that could be closed by this execution
            var matchingPositions = activeNtTrades.Values
                .Where(trade => trade.NtInstrumentSymbol == instrumentName &&
                               trade.NtAccountName == accountName)
                .ToList();

            if (matchingPositions.Count == 0)
            {
                LogAndPrint($"CLOSURE_DETECTION: No existing positions found for {instrumentName} - this is a NEW TRADE");
                return false;
            }

            // Check if this execution would close any existing positions
            foreach (var position in matchingPositions)
            {
                bool isOppositeDirection = IsOppositeDirection(position.MarketPosition, orderAction);

                if (isOppositeDirection)
                {
                    LogAndPrint($"CLOSURE_DETECTION: Found opposite position - Position: {position.MarketPosition}, Action: {orderAction} - this is a CLOSURE");
                    return true;
                }
            }

            LogAndPrint($"CLOSURE_DETECTION: No opposite positions found - this is a NEW TRADE");
            return false;
        }
    }

    /// <summary>
    /// Determines if an order action is opposite to a market position
    /// </summary>
    private bool IsOppositeDirection(MarketPosition position, OrderAction action)
    {
        return (position == MarketPosition.Long && (action == OrderAction.Sell || action == OrderAction.SellShort)) ||
               (position == MarketPosition.Short && (action == OrderAction.Buy || action == OrderAction.BuyToCover));
    }

    /// <summary>
    /// Handles a confirmed trade closure execution
    /// BIDIRECTIONAL_HEDGE_FIX: This function should only process user-initiated closures,
    /// NOT hedge closing orders (which are responses to MT5 notifications).
    /// Hedge closing orders are now filtered out in OnExecutionUpdate to prevent FIFO-based BaseID mismatches.
    /// </summary>
    private void HandleTradeClosureExecution(ExecutionEventArgs e)
    {
        string executionId = e.Execution.ExecutionId;
        string instrumentName = e.Execution.Instrument?.FullName ?? "Unknown";
        string accountName = e.Execution.Account?.Name ?? "Unknown";
        OrderAction orderAction = e.Execution.Order.OrderAction;
        int quantity = e.Execution.Quantity;

        LogAndPrint($"CLOSURE_CONFIRMED: Processing closure execution {executionId}");

        // BIDIRECTIONAL_HEDGE_FIX: Find the specific trade being closed using FIFO logic
        // This is appropriate for user-initiated closures but was causing issues when applied to hedge closing orders
        string closedTradeBaseId = FindTradeBeingClosed(orderAction, instrumentName, accountName, quantity);

        if (!string.IsNullOrEmpty(closedTradeBaseId))
        {
            LogAndPrint($"CLOSURE_SUCCESS: Found trade being closed - BaseID: {closedTradeBaseId}");

            // Send closure notification to MT5
            // MT5 EA expects a trade message with action="CLOSE_HEDGE" for processing
            var closureNotification = new
            {
                action = "CLOSE_HEDGE",  // MT5 EA looks for this specific action
                base_id = closedTradeBaseId,
                quantity = quantity,
                price = 0.0,  // Not critical for closure
                total_quantity = quantity,
                contract_num = 1,
                instrument_name = instrumentName,
                account_name = accountName,
                time = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                nt_balance = 0,  // Not critical for closure
                nt_daily_pnl = 0,  // Not critical for closure
                nt_trade_result = "closed",
                nt_session_trades = 0,
                closure_reason = "NT_ORIGINAL_TRADE_CLOSED"
            };

            string jsonMessage = SimpleJson.SerializeObject(closureNotification);
            LogAndPrint($"CLOSURE_NOTIFICATION: Sending to MT5: {jsonMessage}");

            // MULTI_TRADE_GROUP_FIX: Only remove BaseID when all trades with that BaseID are closed
            lock (_activeNtTradesLock)
            {
                if (activeNtTrades.TryGetValue(closedTradeBaseId, out var tradeDetails))
                {
                    tradeDetails.RemainingQuantity -= quantity;
                    LogAndPrint($"MULTI_TRADE_GROUP_CLOSURE: Reduced remaining quantity for BaseID {closedTradeBaseId} by {quantity}. Remaining: {tradeDetails.RemainingQuantity}/{tradeDetails.TotalQuantity}");

                    if (tradeDetails.RemainingQuantity <= 0)
                    {
                        // All trades with this BaseID are now closed
                        activeNtTrades.TryRemove(closedTradeBaseId, out _);
                        LogAndPrint($"CLOSURE_CLEANUP: All trades closed for BaseID {closedTradeBaseId}. Removed from tracking. Remaining entries: {activeNtTrades.Count}");
                    }
                    else
                    {
                        LogAndPrint($"CLOSURE_PARTIAL: BaseID {closedTradeBaseId} still has {tradeDetails.RemainingQuantity} trades remaining. Keeping in tracking.");
                    }
                }
                else
                {
                    LogAndPrint($"CLOSURE_ERROR: BaseID {closedTradeBaseId} not found in activeNtTrades during closure cleanup.");
                }
            }

            // Send to bridge
            Task.Run(() => SendToBridge(SimpleJson.DeserializeObject<Dictionary<string, object>>(jsonMessage)));
        }
        else
        {
            LogAndPrint($"CLOSURE_ERROR: Could not find matching trade to close for {orderAction} on {instrumentName}");
        }
    }

    /// <summary>
    /// Finds the specific trade being closed by this execution
    /// </summary>
    private string FindTradeBeingClosed(OrderAction orderAction, string instrument, string account, int quantity)
    {
        lock (_activeNtTradesLock)
        {
            var matchingTrades = activeNtTrades
                .Where(kvp => kvp.Value.NtInstrumentSymbol == instrument &&
                             kvp.Value.NtAccountName == account &&
                             IsOppositeDirection(kvp.Value.MarketPosition, orderAction))
                .ToList();

            if (matchingTrades.Count == 0)
            {
                LogAndPrint($"CLOSURE_SEARCH: No matching trades found for {orderAction} on {instrument}");
                return null;
            }

            if (matchingTrades.Count == 1)
            {
                LogAndPrint($"CLOSURE_SEARCH: Single matching trade found - BaseID: {matchingTrades[0].Key}");
                return matchingTrades[0].Key;
            }

            // Multiple matches - use FIFO (first in, first out)
            var oldestTrade = matchingTrades.OrderBy(kvp => kvp.Value.Timestamp).First();
            LogAndPrint($"CLOSURE_SEARCH: Multiple matches found, using FIFO - BaseID: {oldestTrade.Key}");
            return oldestTrade.Key;
        }
    }

    /// <summary>
    /// Determines if an execution represents a closing trade (exit from position)
    /// ENHANCED: More aggressive closure detection for manual closures
    /// </summary>
    /// <param name="e">The execution event args</param>
    /// <returns>True if this execution closes a position, false if it opens/adds to a position</returns>
    private bool IsClosingExecution(ExecutionEventArgs e)
    {
        if (e?.Execution?.Order == null) return false;

        // MOST RELIABLE: Check if order name explicitly indicates it's a closing order
        if (!string.IsNullOrEmpty(e.Execution.Order.Name))
        {
            string orderName = e.Execution.Order.Name.ToUpper();
            if (orderName.Contains("CLOSE") || orderName.Contains("EXIT") ||
                orderName.Contains("TP") || orderName.Contains("SL"))
            {
                LogAndPrint($"CLOSURE_BY_NAME: Order '{e.Execution.Order.Name}' identified as closing order by name");
                return true;
            }
        }

        // Check for closure matches using the improved FindOriginalTradeBaseId function
        // which now only matches when there are explicit closure indicators
        string originalBaseId = FindOriginalTradeBaseId(e);
        if (!string.IsNullOrEmpty(originalBaseId))
        {
            LogAndPrint($"CLOSURE_BY_EXPLICIT_MATCH: Order identified as closing order for base_id {originalBaseId}");
            return true;
        }

        // CONSERVATIVE APPROACH: Only treat as closure if we have explicit evidence
        // This prevents new entry trades from being incorrectly treated as closures
        LogAndPrint($"ENTRY_TRADE: Order '{e.Execution.Order.Name ?? "unnamed"}' identified as entry trade (Action: {e.Execution.Order.OrderAction}, Position: {e.Execution.MarketPosition})");
        return false;
    }

    /// <summary>
    /// Sends a hedge closure notification to the bridge
    /// </summary>
    /// <param name="closureData">The closure notification data</param>
    private async void SendHedgeClosureNotification(Dictionary<string, object> closureData)
    {
        try
        {
            string json = SimpleJson.SerializeObject(closureData);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            // Send to bridge's NT hedge closure endpoint (reverse flow: NT -> Bridge -> MT5)
            string url = $"{bridgeServerUrl}/nt_close_hedge";
            LogAndPrint($"NT_CLOSURE: Sending hedge closure notification to {url}");

            var response = await httpClient.PostAsync(url, content);

            if (response.IsSuccessStatusCode)
            {
                string responseText = await response.Content.ReadAsStringAsync();
                LogAndPrint($"NT_CLOSURE: Successfully sent hedge closure notification. Response: {responseText}");
            }
            else
            {
                string errorText = await response.Content.ReadAsStringAsync();
                LogAndPrint($"ERROR: Failed to send hedge closure notification. Status: {response.StatusCode}, Response: {errorText}");
            }
        }
        catch (Exception ex)
        {
            LogAndPrint($"ERROR: Exception sending hedge closure notification: {ex.Message}");
        }
    }
    }
}