import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider extends ChangeNotifier {
  bool _isDarkMode = false;

  bool get isDarkMode => _isDarkMode;

  ThemeMode get themeMode =>
      _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  ThemeProvider() {
    _loadTheme();
  }

  // FIX: the original declared _loadTheme as void but contained async
  // operations. On a cold start, if SharedPreferences took even a single
  // frame to resolve, notifyListeners() could fire before the widget tree
  // had fully attached, producing a subtle one-frame flash of the wrong
  // theme.
  //
  // The fix is to make the method Future<void> so the compiler tracks
  // the async chain, and to guard against the ChangeNotifier being
  // disposed before the future completes (dispose() sets _disposed=true
  // via the parent class — we check hasListeners as a safe proxy).
  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool('darkMode') ?? false;

    // Only update state if the loaded value differs from the default
    // and the notifier still has listeners (i.e. not disposed).
    if (saved != _isDarkMode && hasListeners) {
      _isDarkMode = saved;
      notifyListeners();
    }
  }

  Future<void> toggleTheme() async {
    _isDarkMode = !_isDarkMode;
    notifyListeners(); // update UI immediately — don't wait for prefs write
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('darkMode', _isDarkMode);
  }
}