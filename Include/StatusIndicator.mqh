//+------------------------------------------------------------------+
//|                                             StatusIndicator.mqh |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023"
#property link      ""
#property version   "1.00"
#property strict

// Input parameters for status indicator position
input group    "==== Status Indicator Settings ====" ;
input int      StatusLabelXDistance = 200;  // X distance for status label position
input int      StatusLabelYDistance = 50;   // Y distance for status label position

// Global variables for status indicator
string StatusLabelName = "EA_Status_Label";
color StatusActiveColor = clrLime;
color StatusInactiveColor = clrRed;
bool StatusIndicatorVisible = true;

//+------------------------------------------------------------------+
//| Initialize and create the status indicator on the chart           |
//+------------------------------------------------------------------+
void InitStatusIndicator()
{
    // Create a text label in the top-right corner of the chart
    ObjectCreate(0, StatusLabelName, OBJ_LABEL, 0, 0, 0);
    
    // Set label properties
    ObjectSetInteger(0, StatusLabelName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_XDISTANCE, StatusLabelXDistance);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_YDISTANCE, StatusLabelYDistance);
    ObjectSetString(0, StatusLabelName, OBJPROP_TEXT, "HedgeBot: DEMA-ATR Trailing Ready");
    ObjectSetInteger(0, StatusLabelName, OBJPROP_COLOR, StatusActiveColor);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_FONTSIZE, 12);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_BACK, false);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_SELECTED, false);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_HIDDEN, true);
    
    // Refresh the chart to show the label
    ChartRedraw();
    
    Print("Status indicator initialized and visible on chart");
}

//+------------------------------------------------------------------+
//| Update the status indicator text and color                        |
//+------------------------------------------------------------------+
void UpdateStatusIndicator(string text, color textColor = clrLime)
{
    if(!ObjectFind(0, StatusLabelName))
    {
        // If the label doesn't exist, create it
        InitStatusIndicator();
    }
    
    // Update the label text and color
    ObjectSetString(0, StatusLabelName, OBJPROP_TEXT, text);
    ObjectSetInteger(0, StatusLabelName, OBJPROP_COLOR, textColor);
    
    // Refresh the chart
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Toggle the visibility of the status indicator                     |
//+------------------------------------------------------------------+
void ToggleStatusIndicator()
{
    StatusIndicatorVisible = !StatusIndicatorVisible;
    
    if(ObjectFind(0, StatusLabelName) >= 0)
    {
        ObjectSetInteger(0, StatusLabelName, OBJPROP_TIMEFRAMES, 
                        StatusIndicatorVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
        ChartRedraw();
    }
}

//+------------------------------------------------------------------+
//| Remove the status indicator from the chart                        |
//+------------------------------------------------------------------+
void RemoveStatusIndicator()
{
    if(ObjectFind(0, StatusLabelName) >= 0)
    {
        ObjectDelete(0, StatusLabelName);
        ChartRedraw();
    }
}
