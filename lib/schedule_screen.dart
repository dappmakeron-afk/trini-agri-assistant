import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'database_helper.dart';
import 'schedule_colors.dart';

class ScheduleScreen extends StatefulWidget {
  final Map<String, dynamic> plant;

  /// Existing schedule for EDIT MODE (updates DB row in-place).
  final Map<String, dynamic>? existingSchedule;

  /// Pre-fill values for CREATE MODE when overriding a single occurrence.
  /// Only used when existingSchedule is null. Populates type/date/repeat
  /// without putting the screen into edit mode.
  final Map<String, dynamic>? prefillSchedule;

  const ScheduleScreen({
    super.key,
    required this.plant,
    this.existingSchedule,
    this.prefillSchedule,
  });

  @override
  ScheduleScreenState createState() => ScheduleScreenState();
}

class ScheduleScreenState extends State<ScheduleScreen> {
  DateTime? selectedDate;
  TimeOfDay? selectedTime;

  String type           = "water";
  String repeatType     = "none";
  int    repeatInterval = 1;

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool get isEditMode => widget.existingSchedule != null;

  static const List<Map<String, dynamic>> _scheduleTypes = [
    {'value': 'water',      'label': '💧 Water',             'icon': Icons.water_drop},
    {'value': 'fertilize',  'label': '🌿 Fertilize',         'icon': Icons.eco},
    {'value': 'appearance', 'label': '👁 Appearance Check',   'icon': Icons.visibility},
    {'value': 'trim',       'label': '✂️ Trimming / Pruning', 'icon': Icons.content_cut},
    {'value': 'pest',       'label': '🐛 Pest Control',       'icon': Icons.bug_report},
    {'value': 'disease',    'label': '🦠 Disease Treatment',  'icon': Icons.coronavirus},
    {'value': 'repot',      'label': '🪴 Repotting',          'icon': Icons.yard},
    {'value': 'mulch',      'label': '🌾 Mulching',           'icon': Icons.grass},
  ];

  @override
  void initState() {
    super.initState();
    _initNotifications();

    if (isEditMode) {
      // ── Edit existing schedule ──
      final s = widget.existingSchedule!;
      type = s['type'] ?? "water";
      if (!_scheduleTypes.any((t) => t['value'] == type)) type = 'water';

      repeatType     = s['repeatType'] ?? "none";
      repeatInterval =
          int.tryParse(s['repeatInterval']?.toString() ?? "1") ?? 1;

      final rawDt = s['dateTime']?.toString() ?? '';
      DateTime? dt;
      try {
        dt = rawDt.isNotEmpty ? DateTime.parse(rawDt) : null;
      } catch (_) {
        dt = null;
      }
      if (dt != null) {
        selectedDate = dt;
        selectedTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
      }
    } else if (widget.prefillSchedule != null) {
      // ── Create mode with pre-filled values (single-day override) ──
      final p = widget.prefillSchedule!;
      type = p['type']?.toString() ?? "water";
      if (!_scheduleTypes.any((t) => t['value'] == type)) type = 'water';

      repeatType     = p['repeatType']?.toString() ?? "none";
      repeatInterval =
          int.tryParse(p['repeatInterval']?.toString() ?? "1") ?? 1;

      final rawDt = p['dateTime']?.toString() ?? '';
      DateTime? dt;
      try {
        dt = rawDt.isNotEmpty ? DateTime.parse(rawDt) : null;
      } catch (_) {
        dt = null;
      }
      if (dt != null) {
        selectedDate = dt;
        selectedTime = TimeOfDay(hour: dt.hour, minute: dt.minute);
      }
    }
  }

  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(android: androidSettings),
    );
  }

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> pickDate() async {
    final now = DateTime.now();
    final firstDate = isEditMode
        ? DateTime(now.year - 5)
        : DateTime(now.year, now.month, now.day);

    final date = await showDatePicker(
      context: context,
      initialDate: selectedDate ?? now,
      firstDate: firstDate,
      lastDate: DateTime(2100),
    );
    if (date != null) setState(() => selectedDate = date);
  }

  // ── Time picker ───────────────────────────────────────────────────────────

  Future<void> pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: selectedTime ?? TimeOfDay.now(),
    );
    if (time != null) setState(() => selectedTime = time);
  }

  // ── Notifications ─────────────────────────────────────────────────────────

  Future<void> _scheduleNotifications(
      int baseId, DateTime startDateTime) async {
    const androidDetails = AndroidNotificationDetails(
      'plant_channel',
      'Plant Notifications',
      channelDescription: 'Plant care reminders',
      importance: Importance.max,
      priority: Priority.high,
    );
    const notificationDetails = NotificationDetails(android: androidDetails);

    final rawLabel   = getScheduleLabel(type);
    final cleanLabel = rawLabel.replaceAll(RegExp(r'[^\x00-\x7F]'), '').trim();

    DateTime current = startDateTime;

    for (int i = 0; i < 30; i++) {
      final tzDate = tz.TZDateTime.from(current, tz.local);

      await flutterLocalNotificationsPlugin.zonedSchedule(
        baseId + i,
        "${widget.plant['name']} — $cleanLabel reminder",
        "Hi Plant Parent!",
        tzDate,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );

      if (repeatType == 'none') break;

      if (repeatType == 'daily') {
        current = current.add(Duration(days: repeatInterval));
      } else if (repeatType == 'weekly') {
        current = current.add(Duration(days: 7 * repeatInterval));
      }
    }
  }

  // ── Save / Update ─────────────────────────────────────────────────────────

  Future<void> saveSchedule() async {
    if (selectedDate == null || selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select date and time!')),
      );
      return;
    }

    final scheduledDateTime = DateTime(
      selectedDate!.year,
      selectedDate!.month,
      selectedDate!.day,
      selectedTime!.hour,
      selectedTime!.minute,
    );

    final plantId = widget.plant['id'];
    if (plantId == null) return;

    try {
      int scheduleId;

      if (isEditMode) {
        scheduleId = widget.existingSchedule!['id'];
        await DatabaseHelper.instance.updateSchedule(scheduleId, {
          'type':           type,
          'dateTime':       scheduledDateTime.toIso8601String(),
          'repeatType':     repeatType,
          'repeatInterval': repeatInterval,
          'isWeatherBased': 0,
        });
      } else {
        scheduleId = await DatabaseHelper.instance.insertSchedule({
          'plantId':        plantId,
          'type':           type,
          'dateTime':       scheduledDateTime.toIso8601String(),
          'repeatType':     repeatType,
          'repeatInterval': repeatInterval,
          'isWeatherBased': 0,
        });
      }

      await _scheduleNotifications(scheduleId, scheduledDateTime);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEditMode
                ? 'Schedule updated successfully!'
                : 'Schedule saved successfully!'),
          ),
        );
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving schedule: $e')),
        );
      }
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditMode
              ? "Edit Schedule for ${widget.plant['name']}"
              : "Schedule for ${widget.plant['name']}",
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Type ──
            const Text("Schedule Type",
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: InputDecoration(
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: _scheduleTypes
                  .map((t) => DropdownMenuItem<String>(
                        value: t['value'] as String,
                        child: Row(
                          children: [
                            Icon(t['icon'] as IconData, size: 18),
                            const SizedBox(width: 8),
                            Text(t['label'] as String),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (val) => setState(() => type = val!),
            ),

            const SizedBox(height: 16),

            // ── Repeat type ──
            const Text("Repeat",
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              initialValue: repeatType,
              decoration: InputDecoration(
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: const [
                DropdownMenuItem(value: "none",   child: Text("No Repeat")),
                DropdownMenuItem(value: "daily",  child: Text("Daily")),
                DropdownMenuItem(value: "weekly", child: Text("Weekly")),
              ],
              onChanged: (val) => setState(() => repeatType = val!),
            ),

            const SizedBox(height: 10),

            // ── Interval ──
            if (repeatType != "none")
              Row(
                children: [
                  const Text("Every "),
                  Expanded(
                    child: Slider(
                      value: repeatInterval.toDouble(),
                      min: 1,
                      max: 30,
                      divisions: 29,
                      label: repeatInterval.toString(),
                      onChanged: (val) =>
                          setState(() => repeatInterval = val.toInt()),
                    ),
                  ),
                  Text("$repeatInterval"),
                  Text(repeatType == 'daily' ? " day(s)" : " week(s)"),
                ],
              ),

            const SizedBox(height: 24),

            // ── Date + Time ──
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(
                      selectedDate == null
                          ? "Pick Date"
                          : "${selectedDate!.year}-"
                              "${selectedDate!.month.toString().padLeft(2, '0')}-"
                              "${selectedDate!.day.toString().padLeft(2, '0')}",
                    ),
                    onPressed: pickDate,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.access_time, size: 16),
                    label: Text(
                      selectedTime == null
                          ? "Pick Time"
                          : selectedTime!.format(context),
                    ),
                    onPressed: pickTime,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // ── Save / Update ──
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: Icon(isEditMode ? Icons.save : Icons.check),
                label: Text(
                    isEditMode ? "Update Schedule" : "Save Schedule"),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: saveSchedule,
              ),
            ),
          ],
        ),
      ),
    );
  }
}