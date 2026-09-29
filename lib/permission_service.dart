import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  static Future<Map<String, bool>> checkAll() async {
    return {
      'notifications': await Permission.notification.isGranted,
      'microphone':    await Permission.microphone.isGranted,
      'alarms':        await Permission.scheduleExactAlarm.isGranted,
    };
  }

  /// Request notifications + alarms together; mic is separate (only if voice used).
  static Future<bool> requestNotifications() async {
    final notif  = await Permission.notification.request();
    final alarms = await Permission.scheduleExactAlarm.request();
    return notif.isGranted && alarms.isGranted;
  }

  static Future<bool> requestMicrophone() async {
    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  static Future<bool> anyDenied() async {
    final statuses = await checkAll();
    return statuses.values.any((granted) => !granted);
  }
}