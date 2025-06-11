using System;
using System.Windows.Input;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Linq;
using NinjaTrader.Cbi;
using NinjaTrader.Gui;
using NinjaTrader.Gui.Tools;
using System.Windows.Media.Imaging;
using System.Globalization;
using NinjaTrader.NinjaScript;
using System.Windows.Threading; // Added for Dispatcher
using System.ComponentModel; // Added for INotifyPropertyChanged
using System.Threading.Tasks; // Added for Task for async operations

namespace NinjaTrader.NinjaScript.AddOns
{
    public class PnlToBrushConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is double pnl)
            {
                return pnl >= 0 ? Brushes.Green : Brushes.Red;
            }
            if (value is int pnlInt) // Handle if PNL comes as int
            {
                return pnlInt >= 0 ? Brushes.Green : Brushes.Red;
            }
            // Fallback for cases where conversion might fail or value is not double/int
            return Brushes.Black; // Default color
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            throw new NotImplementedException();
        }
    }

    /// <summary>
    /// User interface window for the Multi-Strategy Manager
    /// </summary>
    public class UIForManager : NTWindow
    {
        private ComboBox accountComboBox;
        private TextBlock realizedBalanceText;
        private TextBlock unrealizedBalanceText;
        private TextBlock totalPnlText; // Added for Total PnL
        private ToggleButton enabledToggle;
        private Button resetDailyStatusButton; // Added for resetting daily limit status
        private Account selectedAccount;
        private TextBox dailyTakeProfitInput;
        private TextBox dailyLossLimitInput;
        private DataGrid strategyGrid;
        private double dailyTakeProfit;
        private double dailyLossLimit;
        private System.Collections.ObjectModel.ObservableCollection<StrategyDisplayInfo> activeStrategies;
        // Key: Account Name, Value: HashSet of unique strategy system names the user has explicitly interacted with (checked "Enabled")
        private Dictionary<string, HashSet<string>> explicitlyManagedStrategySystemNamesByAccount = new Dictionary<string, HashSet<string>>();
        private DateTime lastResetDate;
        private System.Windows.Threading.DispatcherTimer strategyStatePollTimer;
        private bool dailyLimitHitForSelectedAccountToday = false; // Flag to track if daily P&L limit is hit
        private string bridgeServerUrl = "http://127.0.0.1:5000"; // Default base URL, will be updated later
        private TextBox bridgeUrlInput; // Added for Bridge URL input
        private Button pingBridgeButton; // Added for Ping Bridge button
        private CheckBox enableSLTPRemovalCheckBox;
        private TextBox sltpRemovalDelayTextBox;
        
        public string BridgeServerUrl { get { return bridgeServerUrl; } }

        /// <summary>
        /// Represents information about a trading strategy
        /// </summary>
        public class StrategyInfo
        {
            private string strategy;
            private string accountDisplayName;
            private string instrument;
            private string dataSeries;
            private string parameter;
            private string position;
            private string accountPosition;
            private string sync;
            private double averagePrice;
            private double unrealizedPL;
            private double realizedPL;
            private string connection;
            private bool enabled;

            /// <summary>
            /// Gets or sets the strategy name
            /// </summary>
            public string Strategy { get { return strategy; } set { strategy = value; } }
            
            /// <summary>
            /// Gets or sets the account display name
            /// </summary>
            public string AccountDisplayName { get { return accountDisplayName; } set { accountDisplayName = value; } }
            
            /// <summary>
            /// Gets or sets the instrument name
            /// </summary>
            public string Instrument { get { return instrument; } set { instrument = value; } }
            
            /// <summary>
            /// Gets or sets the data series information
            /// </summary>
            public string DataSeries { get { return dataSeries; } set { dataSeries = value; } }
            
            /// <summary>
            /// Gets or sets the parameter information
            /// </summary>
            public string Parameter { get { return parameter; } set { parameter = value; } }
            
            /// <summary>
            /// Gets or sets the position information
            /// </summary>
            public string Position { get { return position; } set { position = value; } }
            
            /// <summary>
            /// Gets or sets the account position information
            /// </summary>
            public string AccountPosition { get { return accountPosition; } set { accountPosition = value; } }
            
            /// <summary>
            /// Gets or sets the sync status
            /// </summary>
            public string Sync { get { return sync; } set { sync = value; } }
            
            /// <summary>
            /// Gets or sets the average price
            /// </summary>
            public double AveragePrice { get { return averagePrice; } set { averagePrice = value; } }
            
            /// <summary>
            /// Gets or sets the unrealized profit/loss
            /// </summary>
            public double UnrealizedPL { get { return unrealizedPL; } set { unrealizedPL = value; } }
            
            /// <summary>
            /// Gets or sets the realized profit/loss
            /// </summary>
            public double RealizedPL { get { return realizedPL; } set { realizedPL = value; } }
            
            /// <summary>
            /// Gets or sets the connection information
            /// </summary>
            public string Connection { get { return connection; } set { connection = value; } }
            
            /// <summary>
            /// Gets or sets whether the strategy is enabled
            /// </summary>
            public bool Enabled { get { return enabled; } set { enabled = value; } }
        }

        /// <summary>
        /// Represents data for display in the strategy grid
        /// </summary>
        public class StrategyDisplayInfo : INotifyPropertyChanged
        {
            // INotifyPropertyChanged implementation
            public event PropertyChangedEventHandler PropertyChanged;

            protected virtual void OnPropertyChanged([System.Runtime.CompilerServices.CallerMemberName] string propertyName = null)
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
            }

            // Backing fields
            private string _strategyName;
            private string _accountDisplayName;
            private string _instrumentName;
            private string _dataSeriesInfo;
            private string _parameters;
            private string _strategyPosition;
            private int _accountPosition;
            private string _syncStatus;
            private double _averagePrice;
            private double _unrealizedPL;
            private double _realizedPL;
            private bool _isEnabled;
            private string _connectionStatus;

            /// <summary>
            /// Gets or sets the strategy name
            /// </summary>
            public string StrategyName
            {
                get { return _strategyName; }
                set { if (_strategyName != value) { _strategyName = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the account display name
            /// </summary>
            public string AccountDisplayName
            {
                get { return _accountDisplayName; }
                set { if (_accountDisplayName != value) { _accountDisplayName = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the instrument name
            /// </summary>
            public string InstrumentName
            {
                get { return _instrumentName; }
                set { if (_instrumentName != value) { _instrumentName = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the data series information
            /// </summary>
            public string DataSeriesInfo
            {
                get { return _dataSeriesInfo; }
                set { if (_dataSeriesInfo != value) { _dataSeriesInfo = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the parameter information
            /// </summary>
            public string Parameters
            {
                get { return _parameters; }
                set { if (_parameters != value) { _parameters = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the strategy position (e.g., "Flat", "Long", "Short")
            /// </summary>
            public string StrategyPosition
            {
                get { return _strategyPosition; }
                set { if (_strategyPosition != value) { _strategyPosition = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the account position size
            /// </summary>
            public int AccountPosition
            {
                get { return _accountPosition; }
                set { if (_accountPosition != value) { _accountPosition = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the sync status (e.g., "Synced", "Not Synced")
            /// </summary>
            public string SyncStatus
            {
                get { return _syncStatus; }
                set { if (_syncStatus != value) { _syncStatus = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the average price
            /// </summary>
            public double AveragePrice
            {
                get { return _averagePrice; }
                set { if (_averagePrice != value) { _averagePrice = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the unrealized profit/loss
            /// </summary>
            public double UnrealizedPL
            {
                get { return _unrealizedPL; }
                set { if (_unrealizedPL != value) { _unrealizedPL = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the realized profit/loss
            /// </summary>
            public double RealizedPL
            {
                get { return _realizedPL; }
                set { if (_realizedPL != value) { _realizedPL = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets whether the strategy is enabled
            /// </summary>
            public bool IsEnabled
            {
                get { return _isEnabled; }
                set
                {
                    if (_isEnabled != value)
                    {
                        _isEnabled = value;
                        OnPropertyChanged(); // Automatically uses "IsEnabled"
                    }
                }
            }

            /// <summary>
            /// Gets or sets the connection status
            /// </summary>
            public string ConnectionStatus
            {
                get { return _connectionStatus; }
                set { if (_connectionStatus != value) { _connectionStatus = value; OnPropertyChanged(); } }
            }

            /// <summary>
            /// Gets or sets the reference to the underlying StrategyBase object.
            /// This property does NOT need change notification.
            /// </summary>
            public StrategyBase StrategyReference { get; set; }
        }

        /// <summary>
        /// Initializes a new instance of the UIForManager class
        /// </summary>
        public UIForManager()
        {
            try
            {
                NinjaTrader.Code.Output.Process("UIForManager constructor started", PrintTo.OutputTab1);

                // Add PnL to Brush Converter to resources
                if (!this.Resources.Contains("PnlColorConverter"))
                {
                    this.Resources.Add("PnlColorConverter", new PnlToBrushConverter());
                }
                
                // Load custom styles - Fix the resource loading path
                // Programmatically apply styles instead of loading from XAML
                ApplyProgrammaticStyles();
                
                // Ensure we're on the UI thread
                if (!CheckAccess())
                {
                    NinjaTrader.Code.Output.Process("ERROR: UIForManager constructor called from non-UI thread. UI must be created on the UI thread.", PrintTo.OutputTab1);
                    throw new InvalidOperationException("The UIForManager must be created on the UI thread.");
                }
                
                // Set window properties
                Title = "Multi-Strategy Manager";
                Width = 1200;
                Height = 800;
                WindowStartupLocation = WindowStartupLocation.CenterScreen;
                Style = Resources["ModernWindowStyle"] as Style;
                MinWidth = 800;
                MinHeight = 600;
                
                // Try to set icon, but handle possible exceptions
                try
                {
                    Icon = Application.Current.MainWindow.Icon;
                }
                catch
                {
                    // Non-critical if icon fails
                }
                
                // Initialize data
                dailyTakeProfit = 1000;
                dailyLossLimit = 500;
                lastResetDate = DateTime.Today;
                activeStrategies = new System.Collections.ObjectModel.ObservableCollection<StrategyDisplayInfo>();
                
                // Create UI
                NinjaTrader.Code.Output.Process("Creating UI", PrintTo.OutputTab1);
                CreateUI();
                
                // Register for loaded event to ensure proper initialization
                this.Loaded += new RoutedEventHandler(OnWindowLoaded);
                // Register for closed event for cleanup
                this.Closed += new EventHandler(OnWindowClosed);

                // Initialize and configure the polling timer
                strategyStatePollTimer = new System.Windows.Threading.DispatcherTimer();
                strategyStatePollTimer.Interval = TimeSpan.FromMilliseconds(500); // Poll every 500ms
                strategyStatePollTimer.Tick += StrategyStatePollTimer_Tick;

                NinjaTrader.Code.Output.Process("UIForManager constructor completed successfully", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in UIForManager constructor: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }
        
        private void OnWindowLoaded(object sender, RoutedEventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("Window Loaded event fired", PrintTo.OutputTab1);
                
                // Update account list
                UpdateAccountList();
                
                // Initialize empty strategy list
                if (activeStrategies == null)
                {
                    activeStrategies = new System.Collections.ObjectModel.ObservableCollection<StrategyDisplayInfo>();
                }
                else
                {
                    // Unregister old strategies before clearing
                    foreach (var stratInfo in activeStrategies)
                    {
                        if (stratInfo.StrategyReference != null)
                            MultiStratManager.UnregisterStrategyForMonitoring(stratInfo.StrategyReference);
                    }
                    activeStrategies.Clear();
                }
                
                // Initialize the grid with an empty list - no sample data
                Dispatcher.BeginInvoke(new Action(delegate()
                {
                    if (strategyGrid != null)
                    {
                        NinjaTrader.Code.Output.Process("Initializing empty grid - no sample data", PrintTo.OutputTab1);
                        strategyGrid.ItemsSource = activeStrategies;
                        strategyGrid.UpdateLayout();
                    }
                    else
                    {
                        NinjaTrader.Code.Output.Process("ERROR: strategyGrid is null", PrintTo.OutputTab1);
                    }
                    
                    // Force layout update - critical for correct display
                    UpdateLayout();
// Populate the grid initially
                    UpdateStrategyGrid(accountComboBox.SelectedItem as Account);
                }));
                
                // Start tracking account updates
                StartBalanceTracking();
                
                // Force initial update of P&L display
                if (selectedAccount != null)
                {
                    NinjaTrader.Code.Output.Process($"[UIForManager] OnWindowLoaded: Initial P&L update for account {selectedAccount.Name}", PrintTo.OutputTab1);
                    
                    // Ensure we're subscribed to this specific account's events
                    selectedAccount.AccountItemUpdate += OnAccountUpdateHandler;
                    
                    // Force an immediate update of the P&L display
                    UpdateBalanceDisplay();
                }
                
                // Make sure toggle is in "Disabled" state initially
                if (enabledToggle != null)
                {
                    enabledToggle.IsChecked = false;
                }

                // Start the polling timer
                strategyStatePollTimer.Start();
                NinjaTrader.Code.Output.Process("Strategy state polling timer started.", PrintTo.OutputTab1);

                // Initial setup for MultiStratManager instance
                if (MultiStratManager.Instance != null)
                {
                    this.DataContext = MultiStratManager.Instance; // Set DataContext for PnL bindings
                    NinjaTrader.Code.Output.Process("[UIForManager] OnWindowLoaded: DataContext set to MultiStratManager.Instance.", PrintTo.OutputTab1);
                    NinjaTrader.Code.Output.Process("[UIForManager] OnWindowLoaded: Setting initial Bridge URL and Monitored Account in MultiStratManager.", PrintTo.OutputTab1);
                    MultiStratManager.Instance.SetBridgeUrl(this.bridgeServerUrl);
                    MultiStratManager.Instance.SetMonitoredAccount(this.selectedAccount);
 
                    // Subscribe to the PingReceivedFromBridge event
                    MultiStratManager.Instance.PingReceivedFromBridge += MultiStratManager_PingReceivedFromBridge;
                    NinjaTrader.Code.Output.Process("[UIForManager] Subscribed to PingReceivedFromBridge event.", PrintTo.OutputTab1);
                }
                
                NinjaTrader.Code.Output.Process("Window loaded successfully. Toggle the 'Enabled' button to activate strategy tracking.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in OnWindowLoaded: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }

        private void StrategyStatePollTimer_Tick(object sender, EventArgs e)
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (strategyGrid == null || activeStrategies == null)
                    return;

                // Original strategy state polling logic
                foreach (StrategyDisplayInfo stratInfo in activeStrategies)
                {
                    if (stratInfo.StrategyReference != null)
                    {
                        try
                        {
                            // Always update IsEnabled to reflect the actual strategy state.
                            // The dailyLimitHitForSelectedAccountToday flag will prevent new orders and disable strategies,
                            // but the checkbox should still reflect the true current state of the strategy.
                            State currentState = stratInfo.StrategyReference.State;
                            bool shouldBeEnabled = currentState == State.Active || currentState == State.Realtime;

                            if (stratInfo.IsEnabled != shouldBeEnabled)
                            {
                                stratInfo.IsEnabled = shouldBeEnabled;
                            }
                        }
                        catch (Exception ex)
                        {
                            NinjaTrader.Code.Output.Process($"[UIForManager] Error polling state for {stratInfo.StrategyName}: {ex.Message}", PrintTo.OutputTab1);
                        }
                    }
                }

                // P&L Monitoring and Limit Checking Logic
                if (enabledToggle != null && enabledToggle.IsChecked == true)
                {
                    // Daily Reset Logic
                    if (DateTime.Today != lastResetDate)
                    {
                        NinjaTrader.Code.Output.Process($"[UIForManager] New day detected. Resetting daily P&L limit flag. Old date: {lastResetDate}, New date: {DateTime.Today}", PrintTo.OutputTab1);
                        dailyLimitHitForSelectedAccountToday = false;
                        lastResetDate = DateTime.Today;
                        // If the toggle was programmatically set to "Limit Reached", reset it.
                        if (enabledToggle.Content.ToString() == "Limit Reached")
                        {
                            enabledToggle.Content = "Enabled"; // Or back to "Disabled" if it should be unchecked
                        }
                    }

                    if (dailyLimitHitForSelectedAccountToday)
                    {
                        // NinjaTrader.Code.Output.Process("[UIForManager] Daily P&L limit already hit for the selected account today. Skipping further checks.", PrintTo.OutputTab1); // Can be noisy
                        return; // Don't proceed if limit is already hit for the day
                    }

                    if (selectedAccount == null)
                    {
                        // NinjaTrader.Code.Output.Process("[UIForManager] P&L Check: No account selected.", PrintTo.OutputTab1); // Can be noisy
                        return;
                    }

                    try
                    {
                        // Get the latest P&L values directly from the account
                        // Using explicit decimal cast to maintain precision in financial calculations
                        decimal currentDailyUnrealizedPnL = (decimal)(selectedAccount.GetAccountItem(AccountItem.UnrealizedProfitLoss, Currency.UsDollar)?.Value ?? 0.0);
                        decimal currentDailyRealizedPnL = (decimal)(selectedAccount.GetAccountItem(AccountItem.RealizedProfitLoss, Currency.UsDollar)?.Value ?? 0.0);
                        decimal currentTotalDailyPnL = currentDailyUnrealizedPnL + currentDailyRealizedPnL;
                        
                        // Format values for logging with "C" for currency format
                        NinjaTrader.Code.Output.Process($"[UIForManager] P&L Check for account {selectedAccount.Name}: Current Total Daily P&L (Unrealized + Realized) = {currentTotalDailyPnL.ToString("C")} (Unrealized: {currentDailyUnrealizedPnL.ToString("C")}, Realized: {currentDailyRealizedPnL.ToString("C")}), Take Profit Limit = {dailyTakeProfit.ToString("C")}, Loss Limit = {dailyLossLimit.ToString("C")}", PrintTo.OutputTab1);

                        bool limitHit = false;
                        string limitTypeHit = string.Empty;

                        // Check Take Profit Limit - ensure we have positive P&L >= take profit limit
                        if (dailyTakeProfit > 0 && currentTotalDailyPnL >= (decimal)dailyTakeProfit)
                        {
                            limitHit = true;
                            limitTypeHit = "Take Profit";
                            NinjaTrader.Code.Output.Process($"[UIForManager] TAKE PROFIT LIMIT HIT for account {selectedAccount.Name}. Total P&L: {currentTotalDailyPnL.ToString("C")}, Limit: {dailyTakeProfit.ToString("C")}", PrintTo.OutputTab1);
                        }
                        // Check Daily Loss Limit - ensure we have negative P&L <= negative loss limit
                        else if (dailyLossLimit > 0 && currentTotalDailyPnL <= (-1 * (decimal)dailyLossLimit))
                        {
                            limitHit = true;
                            limitTypeHit = "Loss Limit";
                            NinjaTrader.Code.Output.Process($"[UIForManager] LOSS LIMIT HIT for account {selectedAccount.Name}. Total P&L: {currentTotalDailyPnL.ToString("C")}, Limit: {(-1 * (decimal)dailyLossLimit).ToString("C")}", PrintTo.OutputTab1);
                        }

                        if (limitHit)
                        {
                            dailyLimitHitForSelectedAccountToday = true;
                            NinjaTrader.Code.Output.Process($"[UIForManager] Daily {limitTypeHit} limit hit for account {selectedAccount.Name}. Flattening all positions and disabling strategies for this account today.", PrintTo.OutputTab1);

                            // Update toggle button text and state
                            if (enabledToggle != null)
                            {
                                enabledToggle.Content = "Limit Reached";
                                // Optionally, uncheck the toggle if it should visually represent "disabled due to limit"
                                // enabledToggle.IsChecked = false; // This might conflict with user's explicit enable/disable
                            }

                            // Flatten all positions for the account first
                            try
                            {
                                NinjaTrader.Code.Output.Process($"[UIForManager] Attempting to flatten all positions for account {selectedAccount.Name}.", PrintTo.OutputTab1);
                                if (selectedAccount != null && selectedAccount.Positions != null)
                                {
                                    // Create a list of positions to avoid issues if the collection is modified during iteration.
                                    var positionsToFlatten = new System.Collections.Generic.List<NinjaTrader.Cbi.Position>(selectedAccount.Positions);
                                    
                                    if (positionsToFlatten.Count == 0)
                                    {
                                        NinjaTrader.Code.Output.Process($"[UIForManager] No open positions to flatten for account {selectedAccount.Name}.", PrintTo.OutputTab1);
                                    }
                                    else
                                    {
                                        NinjaTrader.Code.Output.Process($"[UIForManager] Found {positionsToFlatten.Count} positions to potentially flatten for account {selectedAccount.Name}.", PrintTo.OutputTab1);
                                        // Outer try-catch for the entire position iteration loop
                                        try
                                        {
                                            foreach (NinjaTrader.Cbi.Position position in positionsToFlatten)
                                            {
                                                try // Inner try-catch for each position
                                                {
                                                    // Ensure position is not null and actually has a market position (is not flat)
                                                    if (position != null && position.MarketPosition != NinjaTrader.Cbi.MarketPosition.Flat)
                                                    {
                                                        NinjaTrader.Code.Output.Process($"[UIForManager] Processing position to flatten: Instrument={position.Instrument.FullName}, MarketPosition={position.MarketPosition}, Quantity={position.Quantity}, Account={selectedAccount.Name}", PrintTo.OutputTab1);

                                                        NinjaTrader.Cbi.OrderAction actionToFlatten;
                                                        if (position.MarketPosition == NinjaTrader.Cbi.MarketPosition.Long)
                                                            actionToFlatten = NinjaTrader.Cbi.OrderAction.Sell;
                                                        else // Position must be Short if not Flat (checked in outer if) and not Long
                                                            actionToFlatten = NinjaTrader.Cbi.OrderAction.Buy;

                                                        // Create and submit an Order object as UIForManager is not a NinjaScript
                                                        NinjaTrader.Cbi.Order orderToFlatten = new NinjaTrader.Cbi.Order
                                                        {
                                                            Account = selectedAccount,
                                                            Instrument = position.Instrument,
                                                            OrderAction = actionToFlatten,
                                                            OrderType = NinjaTrader.Cbi.OrderType.Market,
                                                            Quantity = (int)position.Quantity,
                                                            LimitPrice = 0, // Not strictly necessary for Market orders
                                                            StopPrice = 0,  // Not strictly necessary for Market orders
                                                            TimeInForce = NinjaTrader.Cbi.TimeInForce.Day, // Default for market flatten
                                                            Name = "PnLLimitFlatten"
                                                            // Oco = string.Empty, // OCO is typically handled differently if needed
                                                        };
                                                        NinjaTrader.Code.Output.Process($"[UIForManager] Creating flattening order: Account={orderToFlatten.Account.Name}, Instrument={orderToFlatten.Instrument.FullName}, Action={orderToFlatten.OrderAction}, Type={orderToFlatten.OrderType}, Quantity={orderToFlatten.Quantity}, TimeInForce={orderToFlatten.TimeInForce}, Name={orderToFlatten.Name}", PrintTo.OutputTab1);

                                                        NinjaTrader.Code.Output.Process($"[UIForManager] Attempting to submit flattening order list for {position.Instrument.FullName} via selectedAccount.Submit().", PrintTo.OutputTab1);
                                                        selectedAccount.Submit(new List<NinjaTrader.Cbi.Order> { orderToFlatten });
                                                        NinjaTrader.Code.Output.Process($"[UIForManager] Successfully submitted flattening order list for {position.Instrument.FullName}.", PrintTo.OutputTab1);
                                                    }
                                                    else if (position != null && position.MarketPosition == NinjaTrader.Cbi.MarketPosition.Flat)
                                                    {
                                                        NinjaTrader.Code.Output.Process($"[UIForManager] Position {position.Instrument.FullName} in account {selectedAccount.Name} is already flat.", PrintTo.OutputTab1);
                                                    }
                                                }
                                                catch (Exception ex_inner)
                                                {
                                                    NinjaTrader.Code.Output.Process($"ERROR: [UIForManager] ERROR flattening position {position?.Instrument?.FullName ?? "Unknown Instrument"} ({position?.MarketPosition.ToString() ?? "N/A"} {position?.Quantity.ToString() ?? "N/A"}): {ex_inner.Message} | StackTrace: {ex_inner.StackTrace} | InnerException: {ex_inner.InnerException?.Message}", PrintTo.OutputTab1);
                                                }
                                            } // End foreach
                                            NinjaTrader.Code.Output.Process($"[UIForManager] Finished processing positions for flattening in account {selectedAccount.Name}.", PrintTo.OutputTab1);
                                        }
                                        catch (Exception ex_outer_loop)
                                        {
                                            NinjaTrader.Code.Output.Process($"ERROR: [UIForManager] ERROR in position flattening loop: {ex_outer_loop.Message} | StackTrace: {ex_outer_loop.StackTrace} | InnerException: {ex_outer_loop.InnerException?.Message}", PrintTo.OutputTab1);
                                        }
                                    }
                                }
                                else
                                {
                                    NinjaTrader.Code.Output.Process($"[UIForManager] Account {selectedAccount?.Name} is null or its Positions collection is null. Cannot flatten.", PrintTo.OutputTab1);
                                }
                            }
                            catch (Exception ex)
                            {
                                NinjaTrader.Code.Output.Process($"[UIForManager] Error calling FlattenEverything for account {selectedAccount.Name}: {ex.Message}", PrintTo.OutputTab1);
                            }
                            
                            // Then, disable all strategies associated with this account
                            foreach (StrategyDisplayInfo stratInfo in activeStrategies.Where(s => s.AccountDisplayName == selectedAccount.DisplayName && s.StrategyReference != null))
                            {
                                try
                                {
                                    if (stratInfo.StrategyReference.State == State.Active || stratInfo.StrategyReference.State == State.Realtime)
                                    {
                                        NinjaTrader.Code.Output.Process($"[UIForManager] Disabling strategy {stratInfo.StrategyName} (due to daily P&L {limitTypeHit} limit).", PrintTo.OutputTab1);
                                        
                                        // Position closing is now handled by FlattenEverything() globally.
                                        // Individual stratInfo.StrategyReference.CloseStrategy() is removed.
                                        
                                        // Disable the strategy
                                        stratInfo.StrategyReference.SetState(State.Terminated);
                                        stratInfo.IsEnabled = false; // Update UI
                                    }
                                }
                                catch (Exception ex)
                                {
                                    NinjaTrader.Code.Output.Process($"[UIForManager] Error disabling strategy {stratInfo.StrategyName} (post-flatten attempt): {ex.Message}", PrintTo.OutputTab1);
                                }
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        NinjaTrader.Code.Output.Process($"[UIForManager] Error in P&L check: {ex.Message}\n{ex.StackTrace}", PrintTo.OutputTab1);
                    }
                }
            }));
        }

        private void UpdateStrategyGrid(Account selectedAccount)
        {
            try
            {
                NinjaTrader.Code.Output.Process($"[UIForManager] UpdateStrategyGrid called for account: {(selectedAccount != null ? selectedAccount.Name : "null")}", PrintTo.OutputTab1);

                if (activeStrategies == null)
                {
                    activeStrategies = new System.Collections.ObjectModel.ObservableCollection<StrategyDisplayInfo>();
                    if (strategyGrid != null) strategyGrid.ItemsSource = activeStrategies;
                }

                // Create a temporary list of new items for the grid
                var newGridDisplayItems = new List<StrategyDisplayInfo>();
                // Keep track of strategy references that are currently live and should be monitored
                var liveReferencesToMonitor = new HashSet<StrategyBase>();

                if (selectedAccount == null)
                {
                    // If no account is selected, clear everything
                    NinjaTrader.Code.Output.Process("[UIForManager] No account selected. Clearing strategy grid and unregistering all.", PrintTo.OutputTab1);
                }
                else
                {
                    // Ensure the account has an entry in our tracking dictionary
                    if (!explicitlyManagedStrategySystemNamesByAccount.ContainsKey(selectedAccount.Name))
                    {
                        explicitlyManagedStrategySystemNamesByAccount[selectedAccount.Name] = new HashSet<string>();
                    }
                    HashSet<string> managedSystemNamesForAccount = explicitlyManagedStrategySystemNamesByAccount[selectedAccount.Name];

                    // Create a map of currently live strategies from selectedAccount.Strategies for quick lookup
                    // The key is the strategy's system name (StrategyBase.Name)
                    Dictionary<string, StrategyBase> liveStrategiesMap = new Dictionary<string, StrategyBase>();
                    if (selectedAccount.Strategies != null)
                    {
                        foreach (var sb in selectedAccount.Strategies)
                        {
                            if (sb != null && !string.IsNullOrEmpty(sb.Name))
                            {
                                liveStrategiesMap[sb.Name] = sb;
                                // Auto-add any live strategy to the managed list if it's not already there.
                                // This makes strategies visible if they are started outside this UI.
                                if (managedSystemNamesForAccount.Add(sb.Name))
                                {
                                    NinjaTrader.Code.Output.Process($"[UIForManager] Discovered and added live strategy '{sb.Name}' to managed list for account '{selectedAccount.Name}'.", PrintTo.OutputTab1);
                                }
                            }
                        }
                        NinjaTrader.Code.Output.Process($"[UIForManager] Found {liveStrategiesMap.Count} live strategies in selectedAccount.Strategies for {selectedAccount.Name}.", PrintTo.OutputTab1);
                    }
                    else
                    {
                        NinjaTrader.Code.Output.Process($"[UIForManager] selectedAccount.Strategies is null for {selectedAccount.Name}.", PrintTo.OutputTab1);
                    }

                    NinjaTrader.Code.Output.Process($"[UIForManager] Processing {managedSystemNamesForAccount.Count} explicitly managed strategy names for account {selectedAccount.Name}: {string.Join(", ", managedSystemNamesForAccount)}", PrintTo.OutputTab1);

                    foreach (string systemName in managedSystemNamesForAccount)
                    {
                        StrategyBase liveStrategyInstance = null;
                        liveStrategiesMap.TryGetValue(systemName, out liveStrategyInstance);

                        if (liveStrategyInstance != null)
                        {
                            // Strategy is in our managed list AND is currently live
                            string displayName = liveStrategyInstance.Name ?? "Unnamed Strategy"; // Should be same as systemName

                            string instrumentName = "N/A";
                            if (liveStrategyInstance.Instrument != null)
                                instrumentName = liveStrategyInstance.Instrument.FullName;

                            string dataSeriesInfo = "N/A";
                            if (liveStrategyInstance.BarsArray != null && liveStrategyInstance.BarsArray.Length > 0 && liveStrategyInstance.BarsArray[0] != null)
                                dataSeriesInfo = liveStrategyInstance.BarsArray[0].ToString();
                            
                            string parameters = "N/A"; // Placeholder - True parameters would require deeper inspection or different API

                            string strategyPositionString = "N/A";
                            int accountPositionQty = 0;
                            double averagePriceVal = 0.0;

                            if (liveStrategyInstance.Position != null)
                            {
                                strategyPositionString = liveStrategyInstance.Position.MarketPosition.ToString(); // E.g., Long, Short, Flat
                                accountPositionQty = liveStrategyInstance.Position.Quantity;
                                averagePriceVal = liveStrategyInstance.Position.AveragePrice;
                            }

                            double unrealizedPLVal = 0.0;
                            if (liveStrategyInstance.PositionAccount != null && liveStrategyInstance.Instrument?.MarketData?.Last != null)
                            {
                                double lastPrice = liveStrategyInstance.Instrument.MarketData.Last.Price;
                                // It's possible for lastPrice to be 0 if market data isn't fully loaded or for certain instruments.
                                // GetUnrealizedProfitLoss should ideally handle this, but defensive check is fine.
                                if (liveStrategyInstance.Instrument.MasterInstrument.TickSize > 0) // Basic check if instrument is somewhat valid
                                {
                                   unrealizedPLVal = liveStrategyInstance.PositionAccount.GetUnrealizedProfitLoss(PerformanceUnit.Currency, lastPrice);
                                }
                            }
                            else if (liveStrategyInstance.PositionAccount != null)
                            {
                                NinjaTrader.Code.Output.Process($"[UIForManager] Warning: PositionAccount exists but Instrument or MarketData is null/incomplete for {displayName}. Cannot calculate Unrealized P/L accurately.", PrintTo.OutputTab1);
                            }


                            double realizedPLVal = 0.0;
                            if (liveStrategyInstance.SystemPerformance != null &&
                                liveStrategyInstance.SystemPerformance.AllTrades != null &&
                                liveStrategyInstance.SystemPerformance.AllTrades.TradesPerformance != null) // Currency is a struct, should not be null if TradesPerformance isn't.
                            {
                                realizedPLVal = liveStrategyInstance.SystemPerformance.AllTrades.TradesPerformance.Currency.CumProfit;
                            }

                            bool isEnabledState = liveStrategyInstance.State == State.Active || liveStrategyInstance.State == State.Realtime;
                            string currentStrategyState = liveStrategyInstance.State.ToString();

                            newGridDisplayItems.Add(new StrategyDisplayInfo
                            {
                                StrategyName = displayName,
                                AccountDisplayName = selectedAccount.DisplayName,
                                InstrumentName = instrumentName,
                                DataSeriesInfo = dataSeriesInfo,
                                Parameters = parameters,
                                StrategyPosition = strategyPositionString,
                                AccountPosition = accountPositionQty,
                                SyncStatus = "N/A", // Placeholder
                                AveragePrice = averagePriceVal,
                                UnrealizedPL = unrealizedPLVal,
                                RealizedPL = realizedPLVal,
                                IsEnabled = isEnabledState, // Reflects actual strategy state
                                ConnectionStatus = currentStrategyState,
                                StrategyReference = liveStrategyInstance
                            });
                            liveReferencesToMonitor.Add(liveStrategyInstance);
                            NinjaTrader.Code.Output.Process($"[UIForManager] Added LIVE strategy to display: {displayName}, Enabled: {isEnabledState}, State: {currentStrategyState}, UPL: {unrealizedPLVal}, RPL: {realizedPLVal}", PrintTo.OutputTab1);
                        }
                        else
                        {
                            // Strategy is in our managed list BUT is NOT currently live
                            newGridDisplayItems.Add(new StrategyDisplayInfo
                            {
                                StrategyName = systemName, // System name
                                AccountDisplayName = selectedAccount.DisplayName,
                                InstrumentName = "N/A",
                                DataSeriesInfo = "N/A",
                                Parameters = "N/A",
                                StrategyPosition = "N/A",
                                AccountPosition = 0,
                                SyncStatus = "N/A",
                                AveragePrice = 0,
                                UnrealizedPL = 0,
                                RealizedPL = 0,
                                IsEnabled = false, // Not live, so cannot be enabled through UI click here
                                ConnectionStatus = "Not Active/Found",
                                StrategyReference = null // No live reference
                            });
                            NinjaTrader.Code.Output.Process($"[UIForManager] Added placeholder for MANAGED (not live) strategy: {systemName}", PrintTo.OutputTab1);
                        }
                    }
                }

                // Unregister strategies that were previously monitored but are no longer live or relevant
                foreach (var existingStratInfo in activeStrategies.ToList()) // Iterate copy for safe removal
                {
                    if (existingStratInfo.StrategyReference != null && !liveReferencesToMonitor.Contains(existingStratInfo.StrategyReference))
                    {
                        MultiStratManager.UnregisterStrategyForMonitoring(existingStratInfo.StrategyReference);
                        NinjaTrader.Code.Output.Process($"[UIForManager] Unregistered {existingStratInfo.StrategyName} (was {existingStratInfo.ConnectionStatus}) as it's no longer in the live/monitored set.", PrintTo.OutputTab1);
                    }
                }

                // Update the actual DataGrid ItemsSource
                activeStrategies.Clear();
                foreach (var item in newGridDisplayItems.OrderBy(s => s.StrategyName)) // Keep a consistent order
                {
                    activeStrategies.Add(item);
                }

                // Register all current live references
                foreach (var liveRef in liveReferencesToMonitor)
                {
                    MultiStratManager.RegisterStrategyForMonitoring(liveRef);
                }
                
                if (strategyGrid != null) strategyGrid.Items.Refresh();
                NinjaTrader.Code.Output.Process($"[UIForManager] Strategy grid refreshed. Displaying {activeStrategies.Count} items. Monitoring {liveReferencesToMonitor.Count} live strategies.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"[UIForManager] ERROR in UpdateStrategyGrid: {ex.Message}\n{ex.StackTrace}", PrintTo.OutputTab1);
            }
        }

        private void CreateUI()
        {
            try
            {
                NinjaTrader.Code.Output.Process("Creating UI elements", PrintTo.OutputTab1);

                // Create main grid
                Grid mainGrid = new Grid();
                RowDefinition rowDef1 = new RowDefinition(); // Header
                rowDef1.Height = GridLength.Auto;
                mainGrid.RowDefinitions.Add(rowDef1);

                RowDefinition rowDef2 = new RowDefinition(); // Controls
                rowDef2.Height = GridLength.Auto;
                mainGrid.RowDefinitions.Add(rowDef2);

                RowDefinition rowDef3 = new RowDefinition(); // DataGrid
                rowDef3.Height = new GridLength(1, GridUnitType.Star);
                mainGrid.RowDefinitions.Add(rowDef3);

                // Create header
                Border headerBorder = new Border();
                headerBorder.Style = Resources["HeaderPanelStyle"] as Style;
                Grid.SetRow(headerBorder, 0);

                StackPanel headerPanel = new StackPanel();
                headerPanel.Orientation = Orientation.Horizontal;

                TextBlock headerText = new TextBlock();
                headerText.Text = "Multi-Strategy Manager";
                headerText.Style = Resources["HeaderTextStyle"] as Style;
                headerPanel.Children.Add(headerText);

                headerBorder.Child = headerPanel;
                mainGrid.Children.Add(headerBorder);

                // Create controls panel
                Border controlsBorder = new Border();
                controlsBorder.Style = Resources["ContentPanelStyle"] as Style;
                controlsBorder.Margin = new Thickness(10);
                Grid.SetRow(controlsBorder, 1);

                Grid controlsGrid = new Grid();
                controlsGrid.Margin = new Thickness(5);

                // Define columns for the controls grid
                ColumnDefinition colDef1 = new ColumnDefinition();
                colDef1.Width = GridLength.Auto;
                controlsGrid.ColumnDefinitions.Add(colDef1);

                ColumnDefinition colDef2 = new ColumnDefinition();
                colDef2.Width = new GridLength(1, GridUnitType.Star);
                controlsGrid.ColumnDefinitions.Add(colDef2);

                ColumnDefinition colDef3 = new ColumnDefinition();
                colDef3.Width = GridLength.Auto;
                controlsGrid.ColumnDefinitions.Add(colDef3);

                ColumnDefinition colDef4 = new ColumnDefinition();
                colDef4.Width = new GridLength(1, GridUnitType.Star);
                controlsGrid.ColumnDefinitions.Add(colDef4);

                // Define rows for the controls grid
                RowDefinition ctrlRowDef1 = new RowDefinition();
                ctrlRowDef1.Height = GridLength.Auto;
                controlsGrid.RowDefinitions.Add(ctrlRowDef1);

                RowDefinition ctrlRowDef2 = new RowDefinition();
                ctrlRowDef2.Height = GridLength.Auto;
                controlsGrid.RowDefinitions.Add(ctrlRowDef2);

                RowDefinition ctrlRowDef3_new = new RowDefinition();
                ctrlRowDef3_new.Height = GridLength.Auto;
                controlsGrid.RowDefinitions.Add(ctrlRowDef3_new);

                // Account selection
                TextBlock accountLabel = new TextBlock();
                accountLabel.Text = "Account:";
                accountLabel.Style = Resources["FieldLabelStyle"] as Style;
                accountLabel.Margin = new Thickness(5);
                Grid.SetRow(accountLabel, 0);
                Grid.SetColumn(accountLabel, 0);
                controlsGrid.Children.Add(accountLabel);

                accountComboBox = new ComboBox();
                accountComboBox.Margin = new Thickness(5);
                accountComboBox.MinWidth = 150;
                accountComboBox.DisplayMemberPath = "DisplayName";
                accountComboBox.SelectionChanged += new SelectionChangedEventHandler(OnAccountSelectionChanged);

                // Create Refresh Button
                Button refreshButton = new Button();
                refreshButton.Content = "Refresh";
                refreshButton.Margin = new Thickness(5, 0, 0, 0); // Add some left margin
                refreshButton.Click += RefreshButton_Click;
                // Attempt to apply a style if available, otherwise default
                if (Resources.Contains("ModernButtonStyle"))
                    refreshButton.Style = Resources["ModernButtonStyle"] as Style;
                else if (Resources.Contains("StandardButtonStyle")) // Fallback to another common style
                    refreshButton.Style = Resources["StandardButtonStyle"] as Style;


                // Panel to hold Account ComboBox and Refresh Button
                StackPanel accountPanel = new StackPanel();
                accountPanel.Orientation = Orientation.Horizontal;
                accountPanel.Children.Add(accountComboBox);
                accountPanel.Children.Add(refreshButton);

                Grid.SetRow(accountPanel, 0);
                Grid.SetColumn(accountPanel, 1);
                controlsGrid.Children.Add(accountPanel);

                // Daily limits
                TextBlock limitsLabel = new TextBlock();
                limitsLabel.Text = "Daily Limits:";
                limitsLabel.Style = Resources["FieldLabelStyle"] as Style;
                limitsLabel.Margin = new Thickness(5);
                Grid.SetRow(limitsLabel, 0);
                Grid.SetColumn(limitsLabel, 2);
                controlsGrid.Children.Add(limitsLabel);

                StackPanel limitsPanel = new StackPanel();
                limitsPanel.Orientation = Orientation.Horizontal;
                limitsPanel.Margin = new Thickness(5);
                Grid.SetRow(limitsPanel, 0);
                Grid.SetColumn(limitsPanel, 3);

                TextBlock takeProfitLabel = new TextBlock();
                takeProfitLabel.Text = "Take Profit:";
                takeProfitLabel.Margin = new Thickness(0, 0, 5, 0);
                takeProfitLabel.VerticalAlignment = VerticalAlignment.Center;
                limitsPanel.Children.Add(takeProfitLabel);

                dailyTakeProfitInput = new TextBox();
                dailyTakeProfitInput.Width = 80;
                dailyTakeProfitInput.Text = dailyTakeProfit.ToString("F2");
                dailyTakeProfitInput.Margin = new Thickness(0, 0, 10, 0);
                dailyTakeProfitInput.LostFocus += DailyLimitInput_LostFocus; // Add event handler
                dailyTakeProfitInput.TextChanged += DailyLimitInput_TextChanged; // Add event handler
                limitsPanel.Children.Add(dailyTakeProfitInput);

                TextBlock lossLimitLabel = new TextBlock();
                lossLimitLabel.Text = "Loss Limit:";
                lossLimitLabel.Margin = new Thickness(0, 0, 5, 0);
                lossLimitLabel.VerticalAlignment = VerticalAlignment.Center;
                limitsPanel.Children.Add(lossLimitLabel);

                dailyLossLimitInput = new TextBox();
                dailyLossLimitInput.Width = 80;
                dailyLossLimitInput.Text = dailyLossLimit.ToString("F2");
                dailyLossLimitInput.LostFocus += DailyLimitInput_LostFocus; // Add event handler
                dailyLossLimitInput.TextChanged += DailyLimitInput_TextChanged; // Add event handler
                limitsPanel.Children.Add(dailyLossLimitInput);

                controlsGrid.Children.Add(limitsPanel);

                // Balance display
                TextBlock balanceLabel = new TextBlock();
                balanceLabel.Text = "Balance:";
                balanceLabel.Style = Resources["FieldLabelStyle"] as Style;
                balanceLabel.Margin = new Thickness(5);
                Grid.SetRow(balanceLabel, 1);
                Grid.SetColumn(balanceLabel, 0);
                controlsGrid.Children.Add(balanceLabel);

                StackPanel balancePanel = new StackPanel();
                balancePanel.Orientation = Orientation.Horizontal;
                balancePanel.Margin = new Thickness(5);
                Grid.SetRow(balancePanel, 1);
                Grid.SetColumn(balancePanel, 1);

                TextBlock realizedLabel = new TextBlock();
                realizedLabel.Text = "Realized:";
                realizedLabel.Margin = new Thickness(0, 0, 5, 0);
                balancePanel.Children.Add(realizedLabel);

                realizedBalanceText = new TextBlock { Margin = new Thickness(0, 0, 15, 0), VerticalAlignment = VerticalAlignment.Center };
                Binding realizedPnlTextBinding = new Binding("RealizedPnL") { StringFormat = "{0:C}", FallbackValue = "N/A" };
                realizedBalanceText.SetBinding(TextBlock.TextProperty, realizedPnlTextBinding);
                Binding realizedPnlColorBinding = new Binding("RealizedPnL") { Converter = (IValueConverter)Resources["PnlColorConverter"], FallbackValue = Brushes.Black };
                realizedBalanceText.SetBinding(TextBlock.ForegroundProperty, realizedPnlColorBinding);
                balancePanel.Children.Add(realizedBalanceText);

                TextBlock unrealizedLabel = new TextBlock { Text = "Unrealized:", Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
                balancePanel.Children.Add(unrealizedLabel);

                unrealizedBalanceText = new TextBlock { Margin = new Thickness(0, 0, 15, 0), VerticalAlignment = VerticalAlignment.Center };
                Binding unrealizedPnlTextBinding = new Binding("UnrealizedPnL") { StringFormat = "{0:C}", FallbackValue = "N/A" };
                unrealizedBalanceText.SetBinding(TextBlock.TextProperty, unrealizedPnlTextBinding);
                Binding unrealizedPnlColorBinding = new Binding("UnrealizedPnL") { Converter = (IValueConverter)Resources["PnlColorConverter"], FallbackValue = Brushes.Black };
                unrealizedBalanceText.SetBinding(TextBlock.ForegroundProperty, unrealizedPnlColorBinding);
                balancePanel.Children.Add(unrealizedBalanceText);

                TextBlock totalPnlLabel = new TextBlock { Text = "Total:", Margin = new Thickness(0, 0, 5, 0), VerticalAlignment = VerticalAlignment.Center };
                balancePanel.Children.Add(totalPnlLabel);

                totalPnlText = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
                Binding totalPnlTextBinding = new Binding("TotalPnL") { StringFormat = "{0:C}", FallbackValue = "N/A" };
                totalPnlText.SetBinding(TextBlock.TextProperty, totalPnlTextBinding);
                Binding totalPnlColorBinding = new Binding("TotalPnL") { Converter = (IValueConverter)Resources["PnlColorConverter"], FallbackValue = Brushes.Black };
                totalPnlText.SetBinding(TextBlock.ForegroundProperty, totalPnlColorBinding);
                balancePanel.Children.Add(totalPnlText);
 
                controlsGrid.Children.Add(balancePanel);

                // Enable/Disable toggle
                TextBlock enabledLabelText = new TextBlock(); // Renamed to avoid conflict if 'enabledLabel' is used elsewhere
                enabledLabelText.Text = "Tracking Status:";
                enabledLabelText.Style = Resources["FieldLabelStyle"] as Style;
                enabledLabelText.FontFamily = new FontFamily("Segoe UI");
                enabledLabelText.FontWeight = FontWeights.SemiBold;
                enabledLabelText.Margin = new Thickness(5, 0, 10, 0);
                enabledLabelText.VerticalAlignment = VerticalAlignment.Center;
                Grid.SetRow(enabledLabelText, 1);
                Grid.SetColumn(enabledLabelText, 2);
                controlsGrid.Children.Add(enabledLabelText);

                // Panel for Status Toggle and Reset Button
                StackPanel statusControlsPanel = new StackPanel();
                statusControlsPanel.Orientation = Orientation.Horizontal;
                statusControlsPanel.Margin = new Thickness(5);

                enabledToggle = new ToggleButton();
                enabledToggle.Content = "Disabled";
                enabledToggle.Style = Resources["ModernToggleButtonStyle"] as Style;
                enabledToggle.FontFamily = new FontFamily("Segoe UI");
                enabledToggle.FontWeight = FontWeights.Medium;
                enabledToggle.VerticalAlignment = VerticalAlignment.Center;
                //enabledToggle.Margin = new Thickness(5); // Margin will be on the panel
                enabledToggle.Checked += new RoutedEventHandler(OnEnabledToggleChecked);
                enabledToggle.Unchecked += new RoutedEventHandler(OnEnabledToggleUnchecked);
                statusControlsPanel.Children.Add(enabledToggle);

                resetDailyStatusButton = new Button();
                resetDailyStatusButton.Content = "Reset Daily Status";
                resetDailyStatusButton.FontFamily = new FontFamily("Segoe UI");
                resetDailyStatusButton.FontWeight = FontWeights.Medium;
                if (Resources.Contains("ModernButtonStyle"))
                    resetDailyStatusButton.Style = Resources["ModernButtonStyle"] as Style;
                else if (Resources.Contains("StandardButtonStyle")) // Fallback
                    resetDailyStatusButton.Style = Resources["StandardButtonStyle"] as Style;
                resetDailyStatusButton.Margin = new Thickness(10, 0, 0, 0); // Add some left margin
                resetDailyStatusButton.VerticalAlignment = VerticalAlignment.Center;
                resetDailyStatusButton.Click += ResetDailyStatusButton_Click;
                statusControlsPanel.Children.Add(resetDailyStatusButton);

                Grid.SetRow(statusControlsPanel, 1);
                Grid.SetColumn(statusControlsPanel, 3);
                controlsGrid.Children.Add(statusControlsPanel);

                // Create a GroupBox for Bridge Server settings
                GroupBox bridgeServerGroup = new GroupBox
                {
                    Header = "Bridge Server",
                    Margin = new Thickness(5),
                    Padding = new Thickness(5),
                    Style = Resources["ModernGroupBoxStyle"] as Style
                };
                Grid.SetRow(bridgeServerGroup, 2); // Use row 2 for Bridge Server
                Grid.SetColumn(bridgeServerGroup, 0);
                Grid.SetColumnSpan(bridgeServerGroup, 4); // Span across all columns

                // Create a grid for the Bridge Server content
                Grid bridgeServerGrid = new Grid();
                bridgeServerGrid.Margin = new Thickness(5);
                
                // Define columns for the Bridge Server grid
                bridgeServerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                bridgeServerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                bridgeServerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                
                // Define rows for the Bridge Server grid
                bridgeServerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                
                bridgeServerGroup.Content = bridgeServerGrid;

                // Bridge URL Label
                TextBlock bridgeUrlLabel = new TextBlock
                {
                    Text = "Bridge URL:",
                    Style = Resources["FieldLabelStyle"] as Style,
                    Margin = new Thickness(0, 5, 10, 5),
                    VerticalAlignment = VerticalAlignment.Center
                };
                Grid.SetRow(bridgeUrlLabel, 0);
                Grid.SetColumn(bridgeUrlLabel, 0);
                bridgeServerGrid.Children.Add(bridgeUrlLabel);

                // Bridge URL TextBox
                bridgeUrlInput = new TextBox
                {
                    Margin = new Thickness(0, 5, 10, 5),
                    Text = bridgeServerUrl,
                    VerticalAlignment = VerticalAlignment.Center,
                    Style = Resources["ModernTextBoxStyle"] as Style
                };
                bridgeUrlInput.TextChanged += BridgeUrlInput_TextChanged;
                Grid.SetRow(bridgeUrlInput, 0);
                Grid.SetColumn(bridgeUrlInput, 1);
                bridgeServerGrid.Children.Add(bridgeUrlInput);

                // Ping Bridge Button
                pingBridgeButton = new Button
                {
                    Content = "Ping Bridge",
                    Style = Resources["ModernButtonStyle"] as Style,
                    Margin = new Thickness(0, 5, 0, 5),
                    VerticalAlignment = VerticalAlignment.Center,
                    Padding = new Thickness(10, 3, 10, 3)
                };
                pingBridgeButton.Click += PingBridgeButton_Click;
                Grid.SetRow(pingBridgeButton, 0);
                Grid.SetColumn(pingBridgeButton, 2);
                bridgeServerGrid.Children.Add(pingBridgeButton);

                controlsGrid.Children.Add(bridgeServerGroup);

                // Add a new row for the SL/TP Management section
                RowDefinition ctrlRowDef4 = new RowDefinition();
                ctrlRowDef4.Height = GridLength.Auto;
                controlsGrid.RowDefinitions.Add(ctrlRowDef4);

                // SL/TP Management Section
                GroupBox sltpManagementGroup = new GroupBox
                {
                    Header = "SL/TP Management",
                    Margin = new Thickness(5),
                    Padding = new Thickness(5),
                    Style = Resources["ModernGroupBoxStyle"] as Style
                };
                Grid.SetRow(sltpManagementGroup, 3); // Use the new row for SL/TP settings
                Grid.SetColumn(sltpManagementGroup, 0);
                Grid.SetColumnSpan(sltpManagementGroup, 4); // Span across all columns

                // Create a Grid inside the GroupBox for better control over layout
                Grid sltpManagementGrid = new Grid();
                sltpManagementGrid.Margin = new Thickness(5);
                
                // Add a background color to the GroupBox header for better contrast
                sltpManagementGroup.HeaderTemplate = new DataTemplate();
                FrameworkElementFactory headerFactory = new FrameworkElementFactory(typeof(TextBlock));
                headerFactory.SetValue(TextBlock.TextProperty, "SL/TP Management");
                headerFactory.SetValue(TextBlock.ForegroundProperty, new SolidColorBrush(Colors.White));
                headerFactory.SetValue(TextBlock.FontWeightProperty, FontWeights.Bold);
                headerFactory.SetValue(TextBlock.MarginProperty, new Thickness(5, 2, 5, 2));
                sltpManagementGroup.HeaderTemplate.VisualTree = headerFactory;
                
                // Define columns for the SL/TP management grid
                sltpManagementGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                sltpManagementGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                
                // Define rows for the SL/TP management grid
                sltpManagementGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                sltpManagementGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                
                sltpManagementGroup.Content = sltpManagementGrid;

                // Enable SL/TP Removal CheckBox - Row 0
                enableSLTPRemovalCheckBox = new CheckBox
                {
                    Content = "Enable SL/TP Order Removal",
                    Margin = new Thickness(0, 5, 0, 10),
                    VerticalAlignment = VerticalAlignment.Center,
                    Style = Resources["ModernCheckBoxStyle"] as Style,
                    Foreground = new SolidColorBrush(Colors.White)  // Explicit white text for better visibility
                };
                Binding enableSLTPRemovalBinding = new Binding("EnableSLTPRemoval")
                {
                    Source = MultiStratManager.Instance,
                    Mode = BindingMode.TwoWay,
                    UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged
                };
                enableSLTPRemovalCheckBox.SetBinding(ToggleButton.IsCheckedProperty, enableSLTPRemovalBinding);
                Grid.SetRow(enableSLTPRemovalCheckBox, 0);
                Grid.SetColumn(enableSLTPRemovalCheckBox, 0);
                Grid.SetColumnSpan(enableSLTPRemovalCheckBox, 2);
                sltpManagementGrid.Children.Add(enableSLTPRemovalCheckBox);

                // SL/TP Removal Delay - Row 1
                TextBlock delayLabel = new TextBlock
                {
                    Text = "Removal Delay (seconds):",
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 5, 10, 5),
                    Style = Resources["ModernTextBlockStyle"] as Style,
                    Foreground = new SolidColorBrush(Colors.White)  // Explicit white text for better visibility
                };
                Grid.SetRow(delayLabel, 1);
                Grid.SetColumn(delayLabel, 0);
                sltpManagementGrid.Children.Add(delayLabel);
                
                sltpRemovalDelayTextBox = new TextBox
                {
                    Width = 80,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 5, 0, 5),
                    Style = Resources["ModernTextBoxStyle"] as Style,
                    Background = new SolidColorBrush(Color.FromRgb(70, 70, 70)),  // Slightly lighter background for visibility
                    Foreground = new SolidColorBrush(Colors.White)  // White text for better contrast
                };
                Binding sltpRemovalDelayBinding = new Binding("SLTPRemovalDelaySeconds")
                {
                    Source = MultiStratManager.Instance,
                    Mode = BindingMode.TwoWay,
                    UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged,
                    ConverterCulture = CultureInfo.CurrentCulture // Ensure correct number parsing
                };
                sltpRemovalDelayTextBox.SetBinding(TextBox.TextProperty, sltpRemovalDelayBinding);
                Grid.SetRow(sltpRemovalDelayTextBox, 1);
                Grid.SetColumn(sltpRemovalDelayTextBox, 1);
                sltpManagementGrid.Children.Add(sltpRemovalDelayTextBox);

                controlsGrid.Children.Add(sltpManagementGroup);

                controlsBorder.Child = controlsGrid;
                mainGrid.Children.Add(controlsBorder);

                // Create DataGrid for strategies
                Border gridBorder = new Border();
                gridBorder.Style = Resources["ContentPanelStyle"] as Style;
                gridBorder.Margin = new Thickness(10);
                Grid.SetRow(gridBorder, 2);

                strategyGrid = new DataGrid();
                strategyGrid.AutoGenerateColumns = false;
                strategyGrid.IsReadOnly = false; // Overall grid not read-only to allow checkbox interaction
                strategyGrid.SelectionMode = DataGridSelectionMode.Single;
                strategyGrid.SelectionUnit = DataGridSelectionUnit.FullRow;
                strategyGrid.HeadersVisibility = DataGridHeadersVisibility.Column;
                strategyGrid.CanUserAddRows = false;
                strategyGrid.CanUserDeleteRows = false;
                strategyGrid.CanUserReorderColumns = true;
                strategyGrid.CanUserResizeColumns = true;
                strategyGrid.CanUserSortColumns = true;
                strategyGrid.GridLinesVisibility = DataGridGridLinesVisibility.All;
                strategyGrid.RowHeaderWidth = 0;
                strategyGrid.Margin = new Thickness(5);

                // Restore dark background and compact width/layout
                strategyGrid.Background = new SolidColorBrush(Color.FromRgb(51, 51, 51)); // #333333 dark, can adjust for preference
                strategyGrid.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
                strategyGrid.MaxWidth = 1020; // Prevents grid from stretching window; adjust as needed

                // Apply Modern Dark Theme Styles to the DataGrid
                if (Resources.Contains("ModernDataGridStyle"))
                    strategyGrid.Style = Resources["ModernDataGridStyle"] as Style;
                if (Resources.Contains("ModernDataGridRowStyle"))
                    strategyGrid.RowStyle = Resources["ModernDataGridRowStyle"] as Style;
                if (Resources.Contains("ModernDataGridCellStyle"))
                    strategyGrid.CellStyle = Resources["ModernDataGridCellStyle"] as Style;
                if (Resources.Contains("ModernDataGridColumnHeaderStyle"))
                    strategyGrid.ColumnHeaderStyle = Resources["ModernDataGridColumnHeaderStyle"] as Style;

                // Ensure the dark background color is applied after the style is set so it is not overridden.
                strategyGrid.Background = new SolidColorBrush(Color.FromRgb(45,45,48)); // #2D2D30, VS dark theme

                strategyGrid.CellEditEnding += StrategyGrid_CellEditEnding;

                // Style for DataGridRow: No hover highlight, click to select/highlight
                /* Style dataGridRowStyle = new Style(typeof(DataGridRow));
                dataGridRowStyle.Setters.Add(new Setter(DataGridRow.BackgroundProperty, Brushes.Transparent));
                dataGridRowStyle.Setters.Add(new Setter(DataGridRow.BorderBrushProperty, Brushes.LightGray)); // Subtle border
                dataGridRowStyle.Setters.Add(new Setter(DataGridRow.BorderThicknessProperty, new Thickness(0,0,0,1)));

                Trigger rowMouseOverTrigger = new Trigger { Property = DataGridRow.IsMouseOverProperty, Value = true };
                rowMouseOverTrigger.Setters.Add(new Setter(DataGridRow.BackgroundProperty, Brushes.Transparent)); // No change on hover
                dataGridRowStyle.Triggers.Add(rowMouseOverTrigger);

                Trigger rowSelectedTrigger = new Trigger { Property = DataGridRow.IsSelectedProperty, Value = true };
                SolidColorBrush selectedBackground = SystemColors.HighlightBrush; // Default selection blue
                SolidColorBrush selectedForeground = SystemColors.HighlightTextBrush; // Default selection text (white)
                
                // Attempt to use theme brushes if available, otherwise use system defaults
                if (Resources.Contains("AccentColorBrush"))
                    selectedBackground = Resources["AccentColorBrush"] as SolidColorBrush ?? selectedBackground;
                if (Resources.Contains("IdealForegroundColorBrush")) // Common brush for text on accent
                    selectedForeground = Resources["IdealForegroundColorBrush"] as SolidColorBrush ?? selectedForeground;

                rowSelectedTrigger.Setters.Add(new Setter(DataGridRow.BackgroundProperty, selectedBackground));
                rowSelectedTrigger.Setters.Add(new Setter(DataGridRow.ForegroundProperty, selectedForeground));
                dataGridRowStyle.Triggers.Add(rowSelectedTrigger);
                strategyGrid.RowStyle = dataGridRowStyle;
                */
                // Style for CheckBox in "Enabled" column for hover highlight
                Style enabledCheckBoxStyle = new Style(typeof(CheckBox));
                enabledCheckBoxStyle.Setters.Add(new Setter(CheckBox.HorizontalAlignmentProperty, HorizontalAlignment.Center));
                enabledCheckBoxStyle.Setters.Add(new Setter(CheckBox.VerticalAlignmentProperty, VerticalAlignment.Center));
                enabledCheckBoxStyle.Setters.Add(new Setter(CheckBox.MarginProperty, new Thickness(4))); // Add some padding around checkbox

                Trigger checkBoxMouseOverTrigger = new Trigger { Property = CheckBox.IsMouseOverProperty, Value = true };
                SolidColorBrush hoverBrush = (SolidColorBrush)(new BrushConverter().ConvertFrom("#FFE0E0E0")); // Light gray
                if (Resources.Contains("ControlHoverBrush"))
                     hoverBrush = Resources["ControlHoverBrush"] as SolidColorBrush ?? hoverBrush;
                checkBoxMouseOverTrigger.Setters.Add(new Setter(CheckBox.BackgroundProperty, hoverBrush));
                enabledCheckBoxStyle.Triggers.Add(checkBoxMouseOverTrigger);
                
                // Programmatically define all columns for strategyGrid
                strategyGrid.Columns.Add(new DataGridTextColumn {
                    Header = "Strategy Name",
                    Binding = new Binding("StrategyName"),
                    IsReadOnly = true,
                    Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                    MinWidth = 130,
                    MaxWidth = 170,
                });
                strategyGrid.Columns.Add(new DataGridTextColumn {
                    Header = "Account",
                    Binding = new Binding("AccountDisplayName"),
                    IsReadOnly = true,
                    Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                    MinWidth = 110,
                    MaxWidth = 150,
                });
                strategyGrid.Columns.Add(new DataGridTextColumn {
                    Header = "Instrument",
                    Binding = new Binding("InstrumentName"),
                    IsReadOnly = true,
                    Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                    MinWidth = 90,
                    MaxWidth = 130,
                });
                // REMOVED COLUMN: "Strategy Position"
                // strategyGrid.Columns.Add(new DataGridTextColumn {
                //     Header = "Strategy Position",
                //     Binding = new Binding("StrategyPosition"),
                //     IsReadOnly = true,
                //     Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                //     MinWidth = 90,
                //     MaxWidth = 120,
                // });
                strategyGrid.Columns.Add(new DataGridTextColumn {
                    Header = "Account Position",
                    Binding = new Binding("AccountPosition"),
                    IsReadOnly = true,
                    Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                    MinWidth = 80,
                    MaxWidth = 110,
                });
                // REMOVED COLUMN: "Average Price"
                // strategyGrid.Columns.Add(new DataGridTextColumn {
                //     Header = "Average Price",
                //     Binding = new Binding("AveragePrice"),
                //     IsReadOnly = true,
                //     Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                //     MinWidth = 80,
                //     MaxWidth = 110,
                // });
                strategyGrid.Columns.Add(new DataGridTextColumn {
                    Header = "Connected",
                    Binding = new Binding("ConnectionStatus"),
                    IsReadOnly = true,
                    Width = new DataGridLength(1, DataGridLengthUnitType.Auto),
                    MinWidth = 80,
                    MaxWidth = 110,
                });

                // Enabled (IsEnabled) - Using DataGridTemplateColumn
                DataGridTemplateColumn enabledColumn = new DataGridTemplateColumn();
                enabledColumn.Header = "Enabled";
                enabledColumn.MinWidth = 70;
                enabledColumn.MaxWidth = 80;
                
                DataTemplate cellTemplate = new DataTemplate();
                FrameworkElementFactory checkBoxFactory = new FrameworkElementFactory(typeof(CheckBox));
                checkBoxFactory.SetBinding(CheckBox.IsCheckedProperty, new Binding("IsEnabled") { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
                checkBoxFactory.SetValue(CheckBox.StyleProperty, enabledCheckBoxStyle);
                // Attach the Click event handler
                checkBoxFactory.AddHandler(CheckBox.ClickEvent, new RoutedEventHandler(EnabledCheckBox_Click));
                cellTemplate.VisualTree = checkBoxFactory;
                
                enabledColumn.CellTemplate = cellTemplate;
                enabledColumn.CellEditingTemplate = cellTemplate; // Use same template for editing

                strategyGrid.Columns.Add(enabledColumn);
                
                gridBorder.Child = strategyGrid;
                mainGrid.Children.Add(gridBorder);
                
                // Set window content and force layout update
                Content = mainGrid;
                UpdateLayout();
                
                NinjaTrader.Code.Output.Process("UI elements created successfully with new DataGrid styles and Enabled column template.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in CreateUI: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }

        private void UpdateAccountList()
        {
            try
            {
                NinjaTrader.Code.Output.Process("Updating account list", PrintTo.OutputTab1);
                if (accountComboBox == null)
                {
                    NinjaTrader.Code.Output.Process("ERROR: accountComboBox is null in UpdateAccountList", PrintTo.OutputTab1);
                    return;
                }

                // Ensure we are on the UI thread for UI updates
                if (!Dispatcher.CheckAccess())
                {
                    Dispatcher.BeginInvoke(new Action(UpdateAccountList));
                    return;
                }

                // Store the currently selected account
                Account previouslySelectedAccount = accountComboBox.SelectedItem as Account;

                accountComboBox.Items.Clear();
                lock (Account.All) // Lock for thread safety when accessing Account.All
                {
                    foreach (Account account in Account.All)
                    {
                        if (account.Connection != null && account.Connection.Status == NinjaTrader.Cbi.ConnectionStatus.Connected)
                        {
                            accountComboBox.Items.Add(account);
                            NinjaTrader.Code.Output.Process($"Added account to dropdown: {account.DisplayName}", PrintTo.OutputTab1);
                        }
                    }
                }

                // Attempt to re-select the previously selected account
                if (previouslySelectedAccount != null)
                {
                    bool reSelected = false;
                    foreach (Account account in accountComboBox.Items)
                    {
                        if (account.Name == previouslySelectedAccount.Name) // Compare by Name or other unique identifier
                        {
                            accountComboBox.SelectedItem = account;
                            selectedAccount = account; // Update the selectedAccount field
                            NinjaTrader.Code.Output.Process($"Re-selected account: {account.DisplayName}", PrintTo.OutputTab1);
                            reSelected = true;
                            break;
                        }
                    }
                    if (!reSelected)
                    {
                        // If the previously selected account is no longer in the list,
                        // the default selection (first item or none) will remain.
                        NinjaTrader.Code.Output.Process($"Previously selected account '{previouslySelectedAccount.DisplayName}' not found after refresh.", PrintTo.OutputTab1);
                    }
                }
                else if (accountComboBox.Items.Count > 0)
                {
                    // If no account was previously selected, or the list was empty,
                    // select the first item if available.
                    accountComboBox.SelectedIndex = 0;
                    selectedAccount = accountComboBox.SelectedItem as Account;
                    NinjaTrader.Code.Output.Process($"Selected account: {(selectedAccount != null ? selectedAccount.DisplayName : "None")}", PrintTo.OutputTab1);
                }
                else
                {
                    selectedAccount = null;
                    NinjaTrader.Code.Output.Process("No accounts available to select.", PrintTo.OutputTab1);
                }
                UpdateBalanceDisplay(); // Update balance for the initially selected account
                UpdateStrategyGrid(selectedAccount); // Update strategy grid for the initially selected account
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in UpdateAccountList: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }

        private void StartBalanceTracking()
        {
            try
            {
                Account.AccountStatusUpdate += OnAccountStatusUpdate;
                
                // Subscribe to account item updates for the selected account
                if (selectedAccount != null)
                {
                    selectedAccount.AccountItemUpdate += OnAccountUpdateHandler;
                    NinjaTrader.Code.Output.Process($"Subscribed to AccountItemUpdate for account: {selectedAccount.Name}", PrintTo.OutputTab1);
                }
                
                NinjaTrader.Code.Output.Process("Balance tracking started. Subscribed to account events.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in StartBalanceTracking: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }

        private void UpdateBalanceDisplay()
        {
            try
            {
                if (selectedAccount != null && realizedBalanceText != null && unrealizedBalanceText != null)
                {
                    // Ensure we are on the UI thread for UI updates
                    if (!Dispatcher.CheckAccess())
                    {
                        Dispatcher.BeginInvoke(new Action(UpdateBalanceDisplay));
                        return;
                    }

                    double realized = selectedAccount.GetAccountItem(AccountItem.RealizedProfitLoss, Currency.UsDollar)?.Value ?? 0.0;
                    double unrealized = selectedAccount.GetAccountItem(AccountItem.UnrealizedProfitLoss, Currency.UsDollar)?.Value ?? 0.0;

                    realizedBalanceText.Text = realized.ToString("C", CultureInfo.CurrentCulture);
                    unrealizedBalanceText.Text = unrealized.ToString("C", CultureInfo.CurrentCulture);
                    
                    // Log P&L values for verification (uncomment when debugging P&L issues)
                    // NinjaTrader.Code.Output.Process($"[UIForManager] Balance display updated for {selectedAccount.Name}: Realized={realized.ToString("C")}, Unrealized={unrealized.ToString("C")}", PrintTo.OutputTab1);
                }
                else if (realizedBalanceText != null && unrealizedBalanceText != null)
                {
                    realizedBalanceText.Text = "$0.00";
                    unrealizedBalanceText.Text = "$0.00";
                    // NinjaTrader.Code.Output.Process("Balance display cleared (no account selected).", PrintTo.OutputTab1); // Can be noisy
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in UpdateBalanceDisplay: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }
        
        private void OnAccountStatusUpdate(object sender, EventArgs e)
        {
            // Update balance display on account status changes
            UpdateBalanceDisplay();
        }

        // Event handler for account selection change
        private void OnAccountSelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            try
            {
                if (accountComboBox.SelectedItem is Account newSelectedAccount)
                {
                    // Unsubscribe from previous account-specific events if we had a selected account
                    if (selectedAccount != null)
                    {
                        selectedAccount.AccountItemUpdate -= OnAccountUpdateHandler;
                        NinjaTrader.Code.Output.Process($"[UIForManager] Unsubscribed from AccountItemUpdate for previous account: {selectedAccount.Name}", PrintTo.OutputTab1);
                    }
                    
                    // Set the new selected account
                    selectedAccount = newSelectedAccount;
                    NinjaTrader.Code.Output.Process($"Account selection changed to: {selectedAccount.Name}", PrintTo.OutputTab1);
                    
                    // Subscribe to account-specific events for the new account
                    selectedAccount.AccountItemUpdate += OnAccountUpdateHandler;
                    NinjaTrader.Code.Output.Process($"[UIForManager] Subscribed to AccountItemUpdate for new account: {selectedAccount.Name}", PrintTo.OutputTab1);
                    
                    // Force initial P&L retrieval and display update
                    UpdateBalanceDisplay();
                    
                    // Ensure the MultiStratManager knows about the account change
                    if (MultiStratManager.Instance != null)
                    {
                        MultiStratManager.Instance.SetMonitoredAccount(selectedAccount);
                    }
                    
                    UpdateStrategyGrid(selectedAccount); // Update strategy grid based on new selection

                    // Reset daily limit flag when account changes, as limits are per account
                    dailyLimitHitForSelectedAccountToday = false;
                    lastResetDate = DateTime.Today; // Also reset the date to ensure fresh check
                    if (enabledToggle != null && enabledToggle.Content.ToString() == "Limit Reached")
                    {
                        // If the global toggle was showing "Limit Reached", reset its text
                        // based on its actual IsChecked state.
                        enabledToggle.Content = enabledToggle.IsChecked == true ? "Enabled" : "Disabled";
                    }
                    NinjaTrader.Code.Output.Process($"Daily P&L limit status reset due to account change to {selectedAccount.Name}.", PrintTo.OutputTab1);
                }
                else
                {
                    selectedAccount = null;
                    NinjaTrader.Code.Output.Process("Account selection cleared.", PrintTo.OutputTab1);
                    
                    // Clear MultiStratManager reference to the account
                    if (MultiStratManager.Instance != null)
                    {
                        MultiStratManager.Instance.SetMonitoredAccount(null);
                    }
                    
                    UpdateBalanceDisplay();
                    UpdateStrategyGrid(null); // Clear strategy grid
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in OnAccountSelectionChanged: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }


        // Event handler for account updates
        private void OnAccountUpdateHandler(object sender, AccountItemEventArgs e)
        {
            try
            {
                // Ensure we are on the UI thread for UI updates
                if (!Dispatcher.CheckAccess())
                {
                    Dispatcher.BeginInvoke(new Action(() => OnAccountUpdateHandler(sender, e)));
                    return;
                }
                
                // Process the update only if it's for the selected account
                if (e.Account == selectedAccount)
                {
                    // Check if this is a P&L related update (Unrealized or Realized P&L)
                    if (e.AccountItem == AccountItem.UnrealizedProfitLoss || e.AccountItem == AccountItem.RealizedProfitLoss)
                    {
                        // NinjaTrader.Code.Output.Process($"[UIForManager] Account item update received for {e.AccountItem}: {e.Value}", PrintTo.OutputTab1);
                        UpdateBalanceDisplay();
                    }
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"ERROR: [UIForManager] Unhandled exception in OnAccountUpdateHandler: {ex.Message} | StackTrace: {ex.StackTrace}", PrintTo.OutputTab1);
            }
        }

        // Event handler for when the Enabled toggle is checked
        private void OnEnabledToggleChecked(object sender, RoutedEventArgs e)
        {
            try
            {
                enabledToggle.Content = "Enabled";
                NinjaTrader.Code.Output.Process("Strategy tracking enabled.", PrintTo.OutputTab1);
                // Start or resume strategy monitoring logic here if needed
                // For now, the P&L check in StrategyStatePollTimer_Tick will become active.
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in OnEnabledToggleChecked: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }
        
        private void DailyLimitInput_TextChanged(object sender, TextChangedEventArgs e)
        {
            // This event is primarily for real-time feedback or complex validation if needed.
            // The main update logic is in LostFocus to avoid issues with partial input.
            // For now, we can just log or leave it empty if LostFocus handles the update.
            // NinjaTrader.Code.Output.Process("Daily limit input text changed.", PrintTo.OutputTab1);
        }

        private void DailyLimitInput_LostFocus(object sender, RoutedEventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("Daily limit input lost focus.", PrintTo.OutputTab1);
                if (double.TryParse(dailyTakeProfitInput.Text, NumberStyles.Currency, CultureInfo.CurrentCulture, out double newTakeProfit))
                {
                    dailyTakeProfit = newTakeProfit;
                    NinjaTrader.Code.Output.Process($"Daily Take Profit updated to: {dailyTakeProfit.ToString("C")}", PrintTo.OutputTab1);
                }
                else
                {
                    // Revert to old value or show error
                    dailyTakeProfitInput.Text = dailyTakeProfit.ToString("F2"); // Revert
                    NinjaTrader.Code.Output.Process("Invalid input for Daily Take Profit. Reverted.", PrintTo.OutputTab1);
                }

                if (double.TryParse(dailyLossLimitInput.Text, NumberStyles.Currency, CultureInfo.CurrentCulture, out double newLossLimit))
                {
                    dailyLossLimit = newLossLimit;
                    NinjaTrader.Code.Output.Process($"Daily Loss Limit updated to: {dailyLossLimit.ToString("C")}", PrintTo.OutputTab1);
                }
                else
                {
                    // Revert to old value or show error
                    dailyLossLimitInput.Text = dailyLossLimit.ToString("F2"); // Revert
                    NinjaTrader.Code.Output.Process("Invalid input for Daily Loss Limit. Reverted.", PrintTo.OutputTab1);
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in DailyLimitInput_LostFocus: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
                // Optionally revert to old values on any error
                dailyTakeProfitInput.Text = dailyTakeProfit.ToString("F2");
                dailyLossLimitInput.Text = dailyLossLimit.ToString("F2");
            }
        }


        // Event handler for when the Enabled toggle is unchecked
        private void OnEnabledToggleUnchecked(object sender, RoutedEventArgs e)
        {
            try
            {
                enabledToggle.Content = "Disabled";
                NinjaTrader.Code.Output.Process("Strategy tracking disabled.", PrintTo.OutputTab1);
                // Stop or pause strategy monitoring logic here if needed
                // The P&L check in StrategyStatePollTimer_Tick will become inactive.
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process(string.Format("ERROR in OnEnabledToggleUnchecked: {0}\n{1}", ex.Message, ex.StackTrace), PrintTo.OutputTab1);
            }
        }

        private void RefreshButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("Refresh button clicked.", PrintTo.OutputTab1);
                UpdateAccountList(); // This will re-populate accounts and trigger updates for balance and strategies
                // UpdateStrategyGrid(selectedAccount); // This is now called within UpdateAccountList and OnAccountSelectionChanged
                // UpdateBalanceDisplay(); // This is now called within UpdateAccountList and OnAccountSelectionChanged
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"Error during refresh: {ex.Message}", PrintTo.OutputTab1);
            }
        }
private void ResetDailyStatusButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("Reset Daily Status button clicked.", PrintTo.OutputTab1);
                dailyLimitHitForSelectedAccountToday = false;
                lastResetDate = DateTime.Today; // Ensure it's considered reset for today

                if (enabledToggle != null)
                {
                    // Reset the toggle button's content based on its actual checked state,
                    // not just assuming it should be "Enabled".
                    enabledToggle.Content = enabledToggle.IsChecked == true ? "Enabled" : "Disabled";
                }

                NinjaTrader.Code.Output.Process($"Daily P&L limit status has been manually reset for account: {(selectedAccount != null ? selectedAccount.Name : "N/A")}. All strategies for this account may need to be manually re-enabled if they were disabled by the limit.", PrintTo.OutputTab1);

                // Optionally, re-enable strategies that were disabled by the limit if desired,
                // but the message above suggests manual re-enablement.
                // If automatic re-enablement is needed:
                /*
                if (selectedAccount != null)
                {
                    var accountStrategies = MultiStratManager.GetStrategiesForAccount(selectedAccount.Name);
                    if (accountStrategies != null)
                    {
                        foreach (var strategyBase in accountStrategies)
                        {
                            if (strategyBase != null && strategyBase.State == State.Disabled)
                            {
                                // Check if this strategy was one that was auto-disabled by the limit
                                // This might require more sophisticated tracking or simply re-enable all disabled ones.
                                // For simplicity, let's assume we re-enable if the user wants this behavior.
                                // NinjaTrader.Code.Output.Process($"Attempting to re-enable strategy {strategyBase.Name}", PrintTo.OutputTab1);
                                // strategyBase.SetState(State.Active); // Or State.Realtime
                            }
                        }
                    }
                }
                UpdateStrategyGrid(selectedAccount); // Refresh grid to show updated states
                */
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"Error in ResetDailyStatusButton_Click: {ex.Message}", PrintTo.OutputTab1);
            }
        }

        private void BridgeUrlInput_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (bridgeUrlInput != null)
            {
                bridgeServerUrl = bridgeUrlInput.Text;
                NinjaTrader.Code.Output.Process($"[UIForManager] Bridge Server URL changed to: {bridgeServerUrl}", PrintTo.OutputTab1);
                
                // Update MultiStratManager with the new bridge URL
                if (MultiStratManager.Instance != null)
                {
                    NinjaTrader.Code.Output.Process($"[UIForManager] Bridge URL text changed. Updating MultiStratManager with URL: {bridgeServerUrl}", PrintTo.OutputTab1);
                    MultiStratManager.Instance.SetBridgeUrl(bridgeServerUrl);
                }
                // Basic validation (optional, as per instructions)
                if (string.IsNullOrWhiteSpace(bridgeServerUrl))
                {
                    NinjaTrader.Code.Output.Process("[UIForManager] Warning: Bridge Server URL is empty.", PrintTo.OutputTab1);
                }
            }
        }

        private async void PingBridgeButton_Click(object sender, RoutedEventArgs e)
        {
            string url = bridgeUrlInput.Text;
            if (string.IsNullOrWhiteSpace(url))
            {
                MessageBox.Show(this, "Bridge URL is not set.", "Ping Error", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            if (MultiStratManager.Instance == null)
            {
                MessageBox.Show(this, "MultiStratManager instance is not available.", "Ping Error", MessageBoxButton.OK, MessageBoxImage.Error);
                return;
            }

            SetIsWindowLocked(true); // Disable UI
            try
            {
                Tuple<bool, string> result = await MultiStratManager.Instance.PingBridgeAsync(url);
                
                if (result.Item1) // Success
                {
                    MessageBox.Show(this, $"Bridge Ping Successful:\n{result.Item2}", "Ping Result", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                else // Failure
                {
                    MessageBox.Show(this, $"Bridge Ping Failed:\n{result.Item2}", "Ping Result", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, $"An unexpected error occurred during ping: {ex.Message}", "Ping Error", MessageBoxButton.OK, MessageBoxImage.Error);
                NinjaTrader.Code.Output.Process($"[UIForManager] PingBridgeButton_Click Exception: {ex.Message} | StackTrace: {ex.StackTrace}", PrintTo.OutputTab1);
            }
            finally
            {
                SetIsWindowLocked(false); // Re-enable UI
            }
        }

        private void SetIsWindowLocked(bool isLocked)
        {
            // Disable/Enable key controls to prevent interaction during async operations
            if (accountComboBox != null) accountComboBox.IsEnabled = !isLocked;
            if (enabledToggle != null) enabledToggle.IsEnabled = !isLocked;
            if (resetDailyStatusButton != null) resetDailyStatusButton.IsEnabled = !isLocked;
            if (dailyTakeProfitInput != null) dailyTakeProfitInput.IsEnabled = !isLocked;
            if (dailyLossLimitInput != null) dailyLossLimitInput.IsEnabled = !isLocked;
            if (strategyGrid != null) strategyGrid.IsEnabled = !isLocked;
            if (bridgeUrlInput != null) bridgeUrlInput.IsEnabled = !isLocked;
            if (pingBridgeButton != null) pingBridgeButton.IsEnabled = !isLocked;
            
            // Attempt to find the Refresh button by its name if it was added with x:Name
            var refreshButton = this.FindName("RefreshButton") as Button; // Assuming RefreshButton has x:Name
            if (refreshButton == null)
            {
                // Fallback: If RefreshButton is not found by name, and assuming 'topPanel' exists and contains it.
                // This part is speculative as the exact structure of topPanel and RefreshButton isn't fully known from current context.
                // If 'topPanel' is a known container (e.g., a StackPanel field or found by FindName), we could iterate its children.
                // For example, if topPanel is a field:
                // if (topPanel != null) refreshButton = topPanel.Children.OfType<Button>().FirstOrDefault(b => b.Name == "RefreshButton" || b.Content?.ToString() == "Refresh");
                // For now, this specific fallback for RefreshButton might need adjustment if 'FindName' fails and 'topPanel' isn't directly accessible or named.
            }
            if (refreshButton != null) refreshButton.IsEnabled = !isLocked;

            Cursor = isLocked ? Cursors.Wait : Cursors.Arrow;
        }

        
        private void ApplyProgrammaticStyles()
        {
            try
            {
                // ModernWindowStyle
                Style modernWindowStyle = new Style(typeof(NTWindow));
                modernWindowStyle.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF2D2D30"))));
                modernWindowStyle.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
                modernWindowStyle.Setters.Add(new Setter(Control.FontFamilyProperty, new FontFamily("Segoe UI")));
                modernWindowStyle.Setters.Add(new Setter(Window.WindowStyleProperty, WindowStyle.SingleBorderWindow));
                Resources["ModernWindowStyle"] = modernWindowStyle;

                // HeaderPanelStyle
                Style headerPanelStyle = new Style(typeof(Border));
                headerPanelStyle.Setters.Add(new Setter(Border.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF3F3F46"))));
                headerPanelStyle.Setters.Add(new Setter(Border.PaddingProperty, new Thickness(10)));
                Resources["HeaderPanelStyle"] = headerPanelStyle;

                // HeaderTextStyle
                Style headerTextStyle = new Style(typeof(TextBlock));
                headerTextStyle.Setters.Add(new Setter(TextBlock.FontSizeProperty, 20.0));
                headerTextStyle.Setters.Add(new Setter(TextBlock.FontWeightProperty, FontWeights.SemiBold));
                headerTextStyle.Setters.Add(new Setter(TextBlock.ForegroundProperty, Brushes.White));
                Resources["HeaderTextStyle"] = headerTextStyle;

                // ContentPanelStyle
                Style contentPanelStyle = new Style(typeof(Border));
                contentPanelStyle.Setters.Add(new Setter(Border.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF252526"))));
                contentPanelStyle.Setters.Add(new Setter(Border.BorderBrushProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF3F3F46"))));
                contentPanelStyle.Setters.Add(new Setter(Border.BorderThicknessProperty, new Thickness(1)));
                contentPanelStyle.Setters.Add(new Setter(Border.CornerRadiusProperty, new CornerRadius(3)));
                Resources["ContentPanelStyle"] = contentPanelStyle;

                // FieldLabelStyle
                Style fieldLabelStyle = new Style(typeof(TextBlock));
                fieldLabelStyle.Setters.Add(new Setter(TextBlock.ForegroundProperty, Brushes.LightGray));
                fieldLabelStyle.Setters.Add(new Setter(TextBlock.VerticalAlignmentProperty, VerticalAlignment.Center));
                fieldLabelStyle.Setters.Add(new Setter(TextBlock.MarginProperty, new Thickness(0,0,5,0)));
                Resources["FieldLabelStyle"] = fieldLabelStyle;

                // ModernToggleButtonStyle
                Style modernToggleButtonstyle = new Style(typeof(ToggleButton));
                modernToggleButtonstyle.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF007ACC")))); // Blue when checked
                modernToggleButtonstyle.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
                modernToggleButtonstyle.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(0)));
                modernToggleButtonstyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10,5,10,5)));
                modernToggleButtonstyle.Setters.Add(new Setter(Control.CursorProperty, Cursors.Hand));
                // Template for visual states (Checked/Unchecked)
                ControlTemplate toggleButtonTemplate = new ControlTemplate(typeof(ToggleButton));
                var border = new FrameworkElementFactory(typeof(Border), "border");
                border.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
                border.SetValue(Border.SnapsToDevicePixelsProperty, true);
                var contentPresenter = new FrameworkElementFactory(typeof(ContentPresenter), "contentPresenter");
                contentPresenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
                contentPresenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
                contentPresenter.SetValue(ContentPresenter.MarginProperty, new Thickness(5,2,5,2));
                border.AppendChild(contentPresenter);
                toggleButtonTemplate.VisualTree = border;
                // Triggers for visual states
                Trigger isCheckedTrigger = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = true };
                isCheckedTrigger.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF007ACC")), "border")); // Blue
                isCheckedTrigger.Setters.Add(new Setter(TextBlock.FontWeightProperty, FontWeights.Bold));
                Trigger isUncheckedTrigger = new Trigger { Property = ToggleButton.IsCheckedProperty, Value = false };
                isUncheckedTrigger.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF555555")), "border")); // Dark Gray
                Trigger mouseOverTrigger = new Trigger { Property = IsMouseOverProperty, Value = true };
                mouseOverTrigger.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF4A4A4A")), "border")); // Slightly lighter gray on hover
                
                toggleButtonTemplate.Triggers.Add(isCheckedTrigger);
                toggleButtonTemplate.Triggers.Add(isUncheckedTrigger);
                toggleButtonTemplate.Triggers.Add(mouseOverTrigger);
                modernToggleButtonstyle.Setters.Add(new Setter(Control.TemplateProperty, toggleButtonTemplate));
                Resources["ModernToggleButtonStyle"] = modernToggleButtonstyle;

                // ModernButtonStyle (for Reset button)
                Style modernButtonStyle = new Style(typeof(Button));
                modernButtonStyle.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF4F4F4F")))); // Darker Gray for regular buttons
                modernButtonStyle.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.White));
                modernButtonStyle.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
                modernButtonStyle.Setters.Add(new Setter(Control.BorderBrushProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF6A6A6A"))));
                modernButtonStyle.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10,5,10,5)));
                modernButtonStyle.Setters.Add(new Setter(Control.CursorProperty, Cursors.Hand));
                // Template for visual states
                ControlTemplate buttonTemplate = new ControlTemplate(typeof(Button));
                var btnBorder = new FrameworkElementFactory(typeof(Border), "border");
                btnBorder.SetValue(Border.CornerRadiusProperty, new CornerRadius(3));
                btnBorder.SetValue(Border.SnapsToDevicePixelsProperty, true);
                btnBorder.SetBinding(Border.BackgroundProperty, new Binding("Background") { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
                btnBorder.SetBinding(Border.BorderBrushProperty, new Binding("BorderBrush") { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
                btnBorder.SetBinding(Border.BorderThicknessProperty, new Binding("BorderThickness") { RelativeSource = new RelativeSource(RelativeSourceMode.TemplatedParent) });
                var btnContentPresenter = new FrameworkElementFactory(typeof(ContentPresenter), "contentPresenter");
                btnContentPresenter.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Center);
                btnContentPresenter.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
                btnContentPresenter.SetValue(ContentPresenter.MarginProperty, new Thickness(5,2,5,2));
                btnBorder.AppendChild(btnContentPresenter);
                buttonTemplate.VisualTree = btnBorder;
                // Triggers
                Trigger btnMouseOverTrigger = new Trigger { Property = IsMouseOverProperty, Value = true };
                btnMouseOverTrigger.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF5A5A5A")), "border"));
                btnMouseOverTrigger.Setters.Add(new Setter(Control.BorderBrushProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF7A7A7A")), "border"));
                Trigger btnPressedTrigger = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
                btnPressedTrigger.Setters.Add(new Setter(Control.BackgroundProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF007ACC")), "border")); // Blue when pressed
                btnPressedTrigger.Setters.Add(new Setter(Control.BorderBrushProperty, (SolidColorBrush)(new BrushConverter().ConvertFrom("#FF005A9C")), "border"));
                
                buttonTemplate.Triggers.Add(btnMouseOverTrigger);
                buttonTemplate.Triggers.Add(btnPressedTrigger);
                modernButtonStyle.Setters.Add(new Setter(Control.TemplateProperty, buttonTemplate));
                Resources["ModernButtonStyle"] = modernButtonStyle;


                // DataGrid Styles (Copied from previous successful implementation)
                Resources["ModernDataGridStyle"] = Application.Current.TryFindResource("ModernDataGridStyle") ?? new Style(typeof(DataGrid));
                Resources["ModernDataGridRowStyle"] = Application.Current.TryFindResource("ModernDataGridRowStyle") ?? new Style(typeof(DataGridRow));
                Resources["ModernDataGridCellStyle"] = Application.Current.TryFindResource("ModernDataGridCellStyle") ?? new Style(typeof(DataGridCell));
                Resources["ModernDataGridColumnHeaderStyle"] = Application.Current.TryFindResource("ModernDataGridColumnHeaderStyle") ?? new Style(typeof(System.Windows.Controls.Primitives.DataGridColumnHeader));
                Resources["ControlHoverBrush"] = Application.Current.TryFindResource("ControlHoverBrush") ?? Brushes.LightGray;


                NinjaTrader.Code.Output.Process("Programmatic styles applied.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"Error applying programmatic styles: {ex.Message}\n{ex.StackTrace}", PrintTo.OutputTab1);
            }
        }


        private void EnabledCheckBox_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (sender is CheckBox checkBox && checkBox.DataContext is StrategyDisplayInfo strategyInfo)
                {
                    bool isChecked = checkBox.IsChecked ?? false; // The new desired state from the checkbox click
                    NinjaTrader.Code.Output.Process($"[UIForManager] EnabledCheckBox_Click: Strategy '{strategyInfo.StrategyName}', IsChecked (New Desired State): {isChecked}", PrintTo.OutputTab1);

                    if (selectedAccount == null || string.IsNullOrEmpty(strategyInfo.StrategyName))
                    {
                        NinjaTrader.Code.Output.Process("[UIForManager] EnabledCheckBox_Click: No selected account or strategy name is empty. Reverting checkbox.", PrintTo.OutputTab1);
                        checkBox.IsChecked = !isChecked; // Revert
                        return;
                    }

                    // Ensure this strategy name is in the managed list for the current account if user is checking the box
                    if (isChecked)
                    {
                        if (!explicitlyManagedStrategySystemNamesByAccount.ContainsKey(selectedAccount.Name))
                        {
                            explicitlyManagedStrategySystemNamesByAccount[selectedAccount.Name] = new HashSet<string>();
                        }
                        if (explicitlyManagedStrategySystemNamesByAccount[selectedAccount.Name].Add(strategyInfo.StrategyName))
                        {
                             NinjaTrader.Code.Output.Process($"[UIForManager] Added '{strategyInfo.StrategyName}' to explicitly managed list for account '{selectedAccount.Name}'.", PrintTo.OutputTab1);
                        }
                    }
                    
                    // Handle attempt to enable/disable
                    if (strategyInfo.StrategyReference == null)
                    {
                        // This means the strategy is in our managed list but not currently live/found by UpdateStrategyGrid
                        if (isChecked) // User is trying to ENABLE a non-live strategy
                        {
                            NinjaTrader.Code.Output.Process($"[UIForManager] User tried to ENABLE strategy '{strategyInfo.StrategyName}', but it has no live StrategyReference (Status: {strategyInfo.ConnectionStatus}). Action denied.", PrintTo.OutputTab1);
                            MessageBox.Show($"Strategy '{strategyInfo.StrategyName}' is not currently active or loaded in NinjaTrader.\nPlease ensure the strategy is running in NinjaTrader to manage it here.", "Cannot Enable Strategy", MessageBoxButton.OK, MessageBoxImage.Warning);
                            checkBox.IsChecked = false; // Revert checkbox because we can't enable it
                            strategyInfo.IsEnabled = false; // Ensure model reflects this (it should be already, but defensive)
                        }
                        else // User is trying to DISABLE a non-live strategy
                        {
                             // If it's not live, it's already effectively "disabled". No API call needed.
                             // The UI state (IsEnabled=false) is already correct.
                            NinjaTrader.Code.Output.Process($"[UIForManager] User tried to DISABLE strategy '{strategyInfo.StrategyName}', which has no live StrategyReference. No API action needed.", PrintTo.OutputTab1);
                            strategyInfo.IsEnabled = false; // Ensure model is false
                        }
                        return; // No further action if no live reference
                    }

                    // If we have a StrategyReference, proceed with state change via NinjaTrader API
                    // Check for daily limit before enabling
                    if (isChecked && dailyLimitHitForSelectedAccountToday && strategyInfo.AccountDisplayName == selectedAccount?.DisplayName)
                    {
                        NinjaTrader.Code.Output.Process($"[UIForManager] Cannot enable strategy '{strategyInfo.StrategyName}'. Daily P&L limit has been hit for account '{selectedAccount.Name}'.", PrintTo.OutputTab1);
                        MessageBox.Show($"Cannot enable strategy '{strategyInfo.StrategyName}'.\nDaily P&L limit has been hit for account '{selectedAccount.Name}'.\nReset 'Daily Status' to re-enable strategies for this account.", "Daily Limit Reached", MessageBoxButton.OK, MessageBoxImage.Warning);
                        checkBox.IsChecked = false; // Revert the checkbox
                        strategyInfo.IsEnabled = false; // Ensure model reflects this
                        return;
                    }

                    State targetState = isChecked ? State.Active : State.Terminated; // Or State.Realtime if preferred for enabling
                    NinjaTrader.Code.Output.Process($"Attempting to set state of '{strategyInfo.StrategyName}' to {targetState}", PrintTo.OutputTab1);

                    strategyInfo.StrategyReference.SetState(targetState);
                    
                    // Verify state change (optional, for debugging)
                    // Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => {
                    //     State actualState = strategyInfo.StrategyReference.State;
                    //     NinjaTrader.Code.Output.Process($"State of '{strategyInfo.StrategyName}' after SetState: {actualState}. Expected: {targetState}", PrintTo.OutputTab1);
                    //     if(actualState != targetState && actualState != (isChecked ? State.Realtime : State.Disabled)) // Allow Realtime as valid enabled state
                    //     {
                    //        NinjaTrader.Code.Output.Process($"WARNING: State mismatch for {strategyInfo.StrategyName}. UI might not reflect actual state.", PrintTo.OutputTab1);
                    //        // Consider reverting UI if state change failed critically
                    //        // strategyInfo.IsEnabled = (actualState == State.Active || actualState == State.Realtime);
                    //        // checkBox.IsChecked = strategyInfo.IsEnabled;
                    //     }
                    // }));
                    
                    // Update the IsEnabled property which should trigger UI update via binding
                    strategyInfo.IsEnabled = isChecked; 
                }
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"ERROR in EnabledCheckBox_Click: {ex.Message}\n{ex.StackTrace}", PrintTo.OutputTab1);
                // Optionally revert checkbox on error
                if (sender is CheckBox cb) cb.IsChecked = !(cb.IsChecked ?? false);
            }
        }



        private void StrategyGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
        {
            // This event is primarily for handling edits in other editable columns if any were added.
            // For the "Enabled" CheckBox column, the click event is more direct.
            // However, if direct binding updates from CheckBox need to be committed, this can be a place.

            if (e.EditAction == DataGridEditAction.Commit)
            {
                if (e.Column is DataGridTemplateColumn templateColumn && templateColumn.Header.ToString() == "Enabled")
                {
                    if (e.Row.Item is StrategyDisplayInfo strategyInfo)
                    {
                        // The IsEnabled property in StrategyDisplayInfo should already be updated by two-way binding.
                        // This is more of a confirmation or a place for additional logic after commit.
                        NinjaTrader.Code.Output.Process($"CellEditEnding for 'Enabled' column, Strategy: {strategyInfo.StrategyName}, IsEnabled: {strategyInfo.IsEnabled}", PrintTo.OutputTab1);
                        
                        // The actual state change is handled by EnabledCheckBox_Click
                    }
                }
            }
        }
        private void OnWindowClosed(object sender, EventArgs e)
        {
            try
            {
                NinjaTrader.Code.Output.Process("UIForManager window closed. Cleaning up resources.", PrintTo.OutputTab1);
                
                // Stop the polling timer
                if (strategyStatePollTimer != null)
                {
                    strategyStatePollTimer.Stop();
                    strategyStatePollTimer.Tick -= StrategyStatePollTimer_Tick;
                    NinjaTrader.Code.Output.Process("Strategy state polling timer stopped.", PrintTo.OutputTab1);
                }

                // Unsubscribe from global account events
                Account.AccountStatusUpdate -= OnAccountStatusUpdate;
                
                // Unsubscribe from the selected account's events
                if (selectedAccount != null)
                {
                    selectedAccount.AccountItemUpdate -= OnAccountUpdateHandler;
                    NinjaTrader.Code.Output.Process($"[UIForManager] Unsubscribed from AccountItemUpdate for account: {selectedAccount.Name}", PrintTo.OutputTab1);
                }
                
                NinjaTrader.Code.Output.Process("Unsubscribed from all account events.", PrintTo.OutputTab1);

                // Unregister all strategies from monitoring
                if (activeStrategies != null)
                {
                    foreach (var stratInfo in activeStrategies)
                    {
                        if (stratInfo.StrategyReference != null)
                        {
                            MultiStratManager.UnregisterStrategyForMonitoring(stratInfo.StrategyReference);
                            NinjaTrader.Code.Output.Process($"Unregistered strategy '{stratInfo.StrategyName}' from monitoring.", PrintTo.OutputTab1);
                        }
                    }
                    activeStrategies.Clear();
                }

                // Unsubscribe from the PingReceivedFromBridge event
                if (MultiStratManager.Instance != null)
                {
                    MultiStratManager.Instance.PingReceivedFromBridge -= MultiStratManager_PingReceivedFromBridge;
                    NinjaTrader.Code.Output.Process("[UIForManager] Unsubscribed from PingReceivedFromBridge event.", PrintTo.OutputTab1);
                }
                
                // Nullify UI elements to help with garbage collection, though not strictly necessary with WPF's GC.
                accountComboBox = null;
                realizedBalanceText = null;
                unrealizedBalanceText = null;
                enabledToggle = null;
                resetDailyStatusButton = null;
                dailyTakeProfitInput = null;
                dailyLossLimitInput = null;
                strategyGrid = null;
                bridgeUrlInput = null; // Clean up new field

                // Any other cleanup
                NinjaTrader.Code.Output.Process("UIForManager cleanup complete.", PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                NinjaTrader.Code.Output.Process($"Error during OnWindowClosed: {ex.Message}\n{ex.StackTrace}", PrintTo.OutputTab1);
            }
        }

        private void MultiStratManager_PingReceivedFromBridge()
        {
            // Ensure this runs on the UI thread
            this.Dispatcher.BeginInvoke(new Action(() =>
            {
                MessageBox.Show(this, "Ping successfully received from bridge.", "Bridge Ping", MessageBoxButton.OK, MessageBoxImage.Information);
                NinjaTrader.Code.Output.Process("[UIForManager] Displayed PingReceivedFromBridge MessageBox.", PrintTo.OutputTab1);
            }));
        }
    }
}