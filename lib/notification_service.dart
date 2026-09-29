import 'dart:io';

import 'package:flutter/material.dart'  show Color;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'weather_service.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static const MethodChannel _platform =
      MethodChannel('exact_alarm_checker');

  // ── Channel IDs ──────────────────────────────────────────────────────────
  static const String _scheduleChannelId   = 'plant_channel';
  static const String _scheduleChannelName = 'Plant Notifications';
  static const String _scheduleChannelDesc =
      'Reminders for watering and fertilizing plants';

  static const String _milestoneChannelId   = 'crop_milestones';
  static const String _milestoneChannelName = 'Crop Milestones';
  static const String _milestoneChannelDesc =
      'Notifications for sowing, transplant, harvest, and other crop milestones';

  // ── Init ─────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _notifications.initialize(initSettings);
  }

  // ── Watering / fertilizing reminder ──────────────────────────────────────
  // Weather context is fetched and appended to the body automatically.

  static Future<void> showNotification(
    int id,
    String title,
    String body,
    DateTime scheduledTime,
  ) async {
    final weather = await WeatherService.getWeatherSummary();

    String weatherText = '';
    if (weather['temp'] != null && weather['condition'] != null) {
      weatherText = ' (${weather['condition']}, ${weather['temp']}°C)';
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _scheduleChannelId,
        _scheduleChannelName,
        channelDescription: _scheduleChannelDesc,
        importance: Importance.max,
        priority: Priority.high,
      ),
    );

    final tzScheduled = tz.TZDateTime.from(scheduledTime, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      '$body$weatherText',
      tzScheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // ── Crop milestone notification ───────────────────────────────────────────
  // Separate channel from watering reminders; no weather context since
  // milestone dates are set weeks/months in advance.

  static Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    // Guard: never schedule in the past
    if (scheduledDate.isBefore(DateTime.now())) return;

    final tzDate = tz.TZDateTime.from(scheduledDate, tz.local);

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _milestoneChannelId,
        _milestoneChannelName,
        channelDescription: _milestoneChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        // FIX: Color requires package:flutter/material.dart (or dart:ui).
        // The original file imported only dart:io, so this line caused a
        // compile error. Fixed by importing Color from flutter/material.dart.
        color: const Color(0xFF4CAF50),
      ),
      iOS: const DarwinNotificationDetails(),
    );

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tzDate,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // ── Cancel helpers ────────────────────────────────────────────────────────

  static Future<void> cancelNotification(int id) async {
    await _notifications.cancel(id);
  }

  static Future<void> cancelAllNotifications() async {
    await _notifications.cancelAll();
  }

  static Future<void> cancelNotificationRange(
    int baseId,
    int count,
  ) async {
    for (int i = 0; i < count; i++) {
      await _notifications.cancel(baseId + i);
    }
  }

  // ── Reschedule helper ─────────────────────────────────────────────────────

  static Future<void> rescheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime newTime,
  }) async {
    await cancelNotification(id);
    await showNotification(id, title, body, newTime);
  }

  // ── Android helpers ───────────────────────────────────────────────────────

  static Future<int?> getAndroidSdkInt() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await const MethodChannel('device_info')
          .invokeMethod('getSdkInt');
      return result as int?;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> areExactAlarmsAllowed() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool result =
          await _platform.invokeMethod('areExactAlarmsAllowed');
      return result;
    } catch (_) {
      return false;
    }
  }
}