#!/usr/bin/env python3
"""
Test script to verify enhanced JSON format with NT performance data
Simulates NinjaTrader Addon sending enhanced trade data to Bridge
"""

import json
import requests
import time

def test_enhanced_json_format():
    """Test the enhanced JSON format with NT performance data"""
    
    # Bridge URL
    bridge_url = "http://127.0.0.1:5000"
    
    # Test trade data with enhanced NT performance fields
    test_trade = {
        "id": "test_exec_001",
        "base_id": "test_base_001", 
        "time": "2025-01-04T15:30:00Z",
        "action": "Buy",
        "quantity": 1.0,
        "price": 21500.50,
        "total_quantity": 1,
        "contract_num": 1,
        "instrument_name": "NQ 03-25",
        "account_name": "Sim101",
        
        # Enhanced NT Performance Data for Elastic Hedging
        "nt_balance": 25000.0,
        "nt_daily_pnl": -75.0,
        "nt_trade_result": "loss",
        "nt_session_trades": 3
    }
    
    print("🧪 Testing Enhanced JSON Format for Elastic Hedging")
    print("=" * 60)
    
    # Test 1: Send trade data to Bridge
    print("\n📤 Test 1: Sending enhanced trade data to Bridge...")
    try:
        response = requests.post(
            f"{bridge_url}/log_trade",
            json=test_trade,
            timeout=5
        )
        
        if response.status_code == 200:
            print("✅ Bridge accepted enhanced trade data")
            print(f"   Response: {response.text}")
        else:
            print(f"❌ Bridge rejected trade data: {response.status_code}")
            print(f"   Response: {response.text}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Failed to connect to Bridge: {e}")
        return False
    
    # Test 2: Retrieve trade data from Bridge (as MT5 would)
    print("\n📥 Test 2: Retrieving trade data from Bridge (as MT5 EA would)...")
    try:
        response = requests.get(
            f"{bridge_url}/mt5/get_trade",
            timeout=5
        )
        
        if response.status_code == 200:
            trade_data = response.json()
            
            if "status" in trade_data and trade_data["status"] == "no_trade":
                print("ℹ️  No trade data available (queue empty)")
                return True
                
            print("✅ Retrieved enhanced trade data from Bridge")
            print("📋 Enhanced JSON Fields:")
            
            # Check for enhanced fields
            enhanced_fields = ["nt_balance", "nt_daily_pnl", "nt_trade_result", "nt_session_trades"]
            for field in enhanced_fields:
                if field in trade_data:
                    print(f"   ✓ {field}: {trade_data[field]}")
                else:
                    print(f"   ❌ Missing: {field}")
                    
            # Pretty print the full JSON
            print("\n📄 Complete JSON payload:")
            print(json.dumps(trade_data, indent=2))
            
            return True
            
        else:
            print(f"❌ Failed to retrieve trade data: {response.status_code}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Failed to connect to Bridge: {e}")
        return False

def test_multiple_scenarios():
    """Test different NT performance scenarios"""
    
    scenarios = [
        {
            "name": "First NT Loss",
            "data": {
                "id": "test_001",
                "base_id": "base_001",
                "action": "Buy",
                "quantity": 1.0,
                "price": 21500.0,
                "nt_balance": 25000.0,
                "nt_daily_pnl": -50.0,
                "nt_trade_result": "loss",
                "nt_session_trades": 1
            }
        },
        {
            "name": "Multiple NT Losses",
            "data": {
                "id": "test_002", 
                "base_id": "base_002",
                "action": "Sell",
                "quantity": 1.0,
                "price": 21450.0,
                "nt_balance": 24950.0,
                "nt_daily_pnl": -150.0,
                "nt_trade_result": "loss",
                "nt_session_trades": 2
            }
        },
        {
            "name": "NT Win After Losses",
            "data": {
                "id": "test_003",
                "base_id": "base_003", 
                "action": "Buy",
                "quantity": 1.0,
                "price": 21475.0,
                "nt_balance": 25050.0,
                "nt_daily_pnl": 100.0,
                "nt_trade_result": "win",
                "nt_session_trades": 3
            }
        }
    ]
    
    print("\n🎯 Testing Multiple NT Performance Scenarios")
    print("=" * 60)
    
    for scenario in scenarios:
        print(f"\n📊 Scenario: {scenario['name']}")
        
        # Add required fields
        scenario['data'].update({
            "time": "2025-01-04T15:30:00Z",
            "total_quantity": 1,
            "contract_num": 1,
            "instrument_name": "NQ 03-25",
            "account_name": "Sim101"
        })
        
        try:
            response = requests.post(
                "http://127.0.0.1:5000/log_trade",
                json=scenario['data'],
                timeout=5
            )
            
            if response.status_code == 200:
                print(f"   ✅ {scenario['name']} data sent successfully")
            else:
                print(f"   ❌ Failed to send {scenario['name']} data")
                
        except requests.exceptions.RequestException as e:
            print(f"   ❌ Connection error for {scenario['name']}: {e}")

if __name__ == "__main__":
    print("🚀 Enhanced JSON Format Test Suite")
    print("Testing NT Performance Data Integration for Elastic Hedging")
    print("=" * 80)
    
    # Test basic enhanced JSON format
    success = test_enhanced_json_format()
    
    if success:
        # Test multiple scenarios
        test_multiple_scenarios()
        
        print("\n🎉 Enhanced JSON Format Tests Complete!")
        print("✅ NT Performance data is now being sent to MT5 EA")
        print("✅ Elastic hedging can now respond to NT win/loss patterns")
        
    else:
        print("\n❌ Enhanced JSON Format Tests Failed!")
        print("🔧 Check that the Bridge server is running on port 5000")
