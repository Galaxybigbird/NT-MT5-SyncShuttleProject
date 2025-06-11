using System;
using System.Collections.Generic;
using System.Text; // Required for StringBuilder if we were to optimize, but not strictly for current code. Good to have.
using System.Linq; // Required for .Select and .ToArray if we were to use them, not strictly for current.
using System.Globalization; // Required for NumberStyles and CultureInfo

namespace NinjaTrader.NinjaScript.AddOns
{
    public static class SimpleJson
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
                jsonPairs[i] = $"\"{prop.Name.ToLower()}\":{serializedValue}"; // Matching original behavior of ToLower()
            }
            
            return "{" + string.Join(",", jsonPairs) + "}";
        }
        public static T DeserializeObject<T>(string json) where T : new()
        {
            if (string.IsNullOrWhiteSpace(json))
                return default(T);

            var obj = new T();
            var type = typeof(T);

            if (type == typeof(Dictionary<string, object>))
            {
                var dict = new Dictionary<string, object>();
                // Basic parser for flat JSON like {"key1":"value1", "key2":123, "key3":true}
                // This is a simplified parser and may need to be made more robust
                // for complex JSON structures, arrays, or nested objects.
                json = json.Trim();
                if (json.StartsWith("{") && json.EndsWith("}"))
                {
                    json = json.Substring(1, json.Length - 2).Trim(); // Remove curly braces
                    var pairs = new List<string>();
                    int braceCounter = 0;
                    int lastSplit = 0;
                    for(int i = 0; i < json.Length; i++)
                    {
                        if (json[i] == '{' || json[i] == '[') braceCounter++;
                        else if (json[i] == '}' || json[i] == ']') braceCounter--;
                        else if (json[i] == ',' && braceCounter == 0)
                        {
                            pairs.Add(json.Substring(lastSplit, i - lastSplit).Trim());
                            lastSplit = i + 1;
                        }
                    }
                    pairs.Add(json.Substring(lastSplit).Trim()); // Add the last pair

                    foreach (var pairString in pairs)
                    {
                        if (string.IsNullOrWhiteSpace(pairString)) continue;

                        var colonIndex = pairString.IndexOf(':');
                        if (colonIndex > 0)
                        {
                            string key = pairString.Substring(0, colonIndex).Trim();
                            if (key.StartsWith("\"") && key.EndsWith("\""))
                                key = key.Substring(1, key.Length - 2);

                            string valueString = pairString.Substring(colonIndex + 1).Trim();
                            object value = null;

                            if (valueString.StartsWith("\"") && valueString.EndsWith("\""))
                                value = valueString.Substring(1, valueString.Length - 2);
                            else if (valueString.Equals("true", StringComparison.OrdinalIgnoreCase))
                                value = true;
                            else if (valueString.Equals("false", StringComparison.OrdinalIgnoreCase))
                                value = false;
                            else if (valueString.Equals("null", StringComparison.OrdinalIgnoreCase))
                                value = null;
                            else if (double.TryParse(valueString, NumberStyles.Any, CultureInfo.InvariantCulture, out double numValue))
                                value = numValue; // Could be int, double, float etc. Store as double for simplicity here.
                            else
                                value = valueString; // Fallback to string if not recognized

                            dict[key] = value;
                        }
                    }
                }
                return (T)(object)dict; // Cast to T
            }
            // Add more specific type handling if needed, or throw NotSupportedException
            // For now, this primarily supports Dictionary<string, object> for the /health endpoint
            // and will return new T() or default(T) for other types.
            // A more robust solution would use System.Text.Json or Newtonsoft.Json.
            // This is a placeholder for basic functionality.
            // NinjaTrader.Code.Output.Process($"[SimpleJson] DeserializeObject for type {type.FullName} is not fully implemented for complex types beyond Dictionary<string,object>.", PrintTo.OutputTab1);
            return obj; // Or default(T) if obj creation isn't always desired for unsupported types
        }

        // Helper method to serialize different value types
        private static string SerializeValue(object value)
        {
            if (value == null) return "null";
            if (value is string s) return $"\"{s.Replace("\"", "\\\"")}\""; // Added basic string escaping
            if (value is bool) return value.ToString().ToLower();
            if (value is DateTime dt) return $"\"{dt:o}\""; // ISO 8601 format
            if (value is int || value is long || value is float || value is double || value is decimal) return value.ToString(); // Added decimal
            if (value is Dictionary<string, object>) return SerializeObject(value); // Recursive call for nested dictionaries
            
            // For other IEnumerable types (like List<T>), serialize as JSON array
            if (value is System.Collections.IEnumerable enumerable && !(value is string) && !(value is Dictionary<string,object>))
            {
                var elements = new List<string>();
                foreach (var item in enumerable)
                {
                    elements.Add(SerializeValue(item));
                }
                return "[" + string.Join(",", elements) + "]";
            }

            if (value.GetType().IsValueType && !value.GetType().IsPrimitive && !(value is DateTime) && !(value is decimal)) return SerializeObject(value); // Serialize structs
            if (value.GetType().IsClass && !(value is string)) return SerializeObject(value); // Serialize other class objects

            return $"\"{value.ToString().Replace("\"", "\\\"")}\""; // Fallback, ensure basic escaping
        }
    }
}