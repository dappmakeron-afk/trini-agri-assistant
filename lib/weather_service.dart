import 'dart:convert';
import 'package:http/http.dart' as http;

class WeatherService {
  // Open-Meteo (free, no API key required)
  static const String _baseUrl =
      'https://api.open-meteo.com/v1/forecast';

  // Trinidad defaults (Arima). Used when no coordinates are supplied.
  // These are intentionally fixed for this app's primary use case — if
  // you later want user-location support, pass lat/lon from a geolocator.
  static const double _defaultLat = 10.65;
  static const double _defaultLon = -61.52;

  // ── Core fetch ────────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>?> getWeather({
    double lat = _defaultLat,
    double lon = _defaultLon,
  }) async {
    try {
      final url = Uri.parse(
        '$_baseUrl?latitude=$lat&longitude=$lon'
        '&current_weather=true'
        '&hourly=precipitation_probability,temperature_2m'
        '&timezone=auto',
      );

      final res =
          await http.get(url).timeout(const Duration(seconds: 8));

      if (res.statusCode != 200) return null;
      return jsonDecode(res.body) as Map<String, dynamic>;
    } on Exception {
      // Network unavailable, timeout, JSON parse error, etc.
      // Callers receive null and show "Unavailable" — no crash.
      return null;
    }
  }

  // ── Weather code → human-readable condition ───────────────────────────────

  static String _conditionFromCode(int? code) {
    if (code == null) return 'Unknown';
    if (code == 0)    return 'Clear';
    if (code <= 3)    return 'Cloudy';
    if (code <= 48)   return 'Fog';
    if (code <= 67)   return 'Rain';
    if (code <= 77)   return 'Snow';
    if (code <= 82)   return 'Heavy Rain';
    if (code <= 99)   return 'Storm';
    return 'Unknown';
  }

  // ── Summary map ───────────────────────────────────────────────────────────
  //
  // Returns a map with the following keys:
  //   temp       : num? — current temperature in °C, null if unavailable
  //   condition  : String — human-readable condition or 'Unavailable'
  //   isRain     : bool  — true if ≥60% precipitation probability in next 24 h
  //   isHot      : bool  — true if temp ≥ 32 °C
  //   error      : bool  — true when data could not be fetched
  //                        allows callers to distinguish "no data yet"
  //                        from "API working, just not hot/rainy"
  //
  // FIX: the original returned the same shape for both "fetch failed" and
  // "fetched successfully but no rain". Added 'error' flag so UI can show
  // a meaningful "weather unavailable" state instead of silently showing
  // nothing.

  static Future<Map<String, dynamic>> getWeatherSummary() async {
    final data = await getWeather();

    if (data == null) {
      return {
        'temp':      null,
        'condition': 'Unavailable',
        'isRain':    false,
        'isHot':     false,
        'error':     true,
      };
    }

    final current     = data['current_weather']  as Map<String, dynamic>?;
    final hourly      = data['hourly']            as Map<String, dynamic>?;

    final temp        = current?['temperature']  as num?;
    final weatherCode = current?['weathercode']  as int?;
    final condition   = _conditionFromCode(weatherCode);

    bool rainExpected = false;
    if (hourly != null) {
      final probs = hourly['precipitation_probability'] as List<dynamic>? ?? [];
      for (int i = 0; i < probs.length && i < 24; i++) {
        if ((probs[i] as num? ?? 0) > 60) {
          rainExpected = true;
          break;
        }
      }
    }

    return {
      'temp':      temp,
      'condition': condition,
      'isRain':    rainExpected,
      'isHot':     temp != null && temp >= 32,
      'error':     false,
    };
  }

  // ── Convenience helpers ───────────────────────────────────────────────────

  static Future<bool> isRainExpected() async {
    final summary = await getWeatherSummary();
    return summary['isRain'] as bool? ?? false;
  }

  static Future<bool> isHotDay() async {
    final summary = await getWeatherSummary();
    return summary['isHot'] as bool? ?? false;
  }
}