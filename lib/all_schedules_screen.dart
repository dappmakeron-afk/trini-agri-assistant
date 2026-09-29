import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'database_helper.dart';
import 'schedule_screen.dart';
import 'schedule_colors.dart';
import 'weather_service.dart';
import 'notification_service.dart';

class AllSchedulesScreen extends StatefulWidget {
  const AllSchedulesScreen({super.key});

  @override
  State<AllSchedulesScreen> createState() => _AllSchedulesScreenState();
}

class _AllSchedulesScreenState extends State<AllSchedulesScreen> {
  // ── Schedule data ─────────────────────────────────────────────────────────
  Map<DateTime, List<Map<String, dynamic>>> _events = {};

  // ── Completion state ──────────────────────────────────────────────────────
  // Keyed by "scheduleId|yyyy-MM-dd" → 'done' | 'skipped'
  final Map<String, String> _occurrenceStatus = {};

  // ── Calendar state ────────────────────────────────────────────────────────
  late DateTime _focusedMonth;
  late DateTime _selectedDay;

  // ── Filters ───────────────────────────────────────────────────────────────
  bool _showPastSchedules = false;

  // ── Weather ───────────────────────────────────────────────────────────────
  bool    _rainExpected     = false;
  bool    _hotDay           = false;
  String  _weatherCondition = 'Loading...';
  double? _temperature;

  // ─────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final now     = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month);
    _selectedDay  = _normalize(now);
    _loadSchedules();
    _loadWeather();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  DateTime _normalize(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<Map<String, dynamic>> _eventsForDay(DateTime day) =>
      _events[_normalize(day)] ?? [];

  /// Stable key that uniquely identifies one occurrence of a schedule.
  String _occurrenceKey(int scheduleId, DateTime occurrenceDate) =>
      '$scheduleId|${DateFormat('yyyy-MM-dd').format(occurrenceDate)}';

  /// Derives a stable notification slot ID for a specific occurrence.
  /// Uses the schedule's base ID combined with days-since-epoch so each
  /// occurrence maps to a unique, reproducible integer.
  int _occurrenceNotificationId(int scheduleId, DateTime occurrenceDate) {
    final daysSinceEpoch =
        occurrenceDate.difference(DateTime(2000)).inDays.abs();
    return (scheduleId * 10000 + daysSinceEpoch) % 2147483647;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CANCEL NOTIFICATION — both base ID and occurrence-derived ID
  // ─────────────────────────────────────────────────────────────────────────

  /// Cancels notifications for a specific occurrence using BOTH the base
  /// scheduleId and the occurrence-derived ID. This is necessary because:
  ///  - Non-repeating / "edit all" schedules are booked under the base ID.
  ///  - Per-occurrence edits may be booked under the occurrence-derived ID.
  /// Cancelling both guarantees the notification is suppressed regardless
  /// of which ID was used at booking time.
  Future<void> _cancelOccurrenceNotifications(
      int scheduleId, DateTime occDt) async {
    await NotificationService.cancelNotification(scheduleId);
    await NotificationService.cancelNotification(
        _occurrenceNotificationId(scheduleId, occDt));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DATA LOADING
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadSchedules() async {
    final data = await DatabaseHelper.instance.getSchedulesWithPlant();
    final now  = DateTime.now();

    final expandUntil = DateTime(now.year + 2, now.month, now.day);

    // Load all completion statuses first so we can filter while building map
    await _loadOccurrenceStatuses(data);

    final map = <DateTime, List<Map<String, dynamic>>>{};

    for (final raw in data) {
      final s = Map<String, dynamic>.from(raw);

      DateTime startDt;
      try {
        startDt = DateTime.parse(s['dateTime'] as String);
      } catch (_) {
        continue;
      }

      final repeatType     = s['repeatType']?.toString().toLowerCase() ?? 'none';
      final repeatInterval =
          int.tryParse(s['repeatInterval']?.toString() ?? '1') ?? 1;

      final occurrences = <DateTime>[];

      if (repeatType == 'none') {
        if (_showPastSchedules || !startDt.isBefore(now)) {
          occurrences.add(startDt);
        }
      } else {
        final stepDays =
            repeatType == 'daily' ? repeatInterval : repeatInterval * 7;
        DateTime cursor = startDt;
        while (!cursor.isAfter(expandUntil)) {
          if (_showPastSchedules || !cursor.isBefore(now)) {
            occurrences.add(cursor);
          }
          cursor = cursor.add(Duration(days: stepDays));
        }
      }

      final scheduleId = s['id'] as int;

      for (final occ in occurrences) {
        // Skip occurrences that were deleted (marked skipped via
        // "Delete this day only"). They must not appear on the calendar.
        final occKey = _occurrenceKey(scheduleId, occ);
        if (_occurrenceStatus[occKey] == 'skipped') continue;

        final dayKey = _normalize(occ);
        map.putIfAbsent(dayKey, () => []);
        map[dayKey]!.add({
          ...s,
          'dateTime':      occ.toIso8601String(),
          'originalStart': startDt.toIso8601String(),
        });
      }
    }

    if (!mounted) return;
    setState(() => _events = map);
  }

  /// Loads all per-occurrence done/skip statuses from schedule_completions.
  Future<void> _loadOccurrenceStatuses(
      List<Map<String, dynamic>> schedules) async {
    final statuses = <String, String>{};

    for (final s in schedules) {
      final scheduleId = s['id'] as int?;
      final plantId    = s['plantId'] as int?;
      if (scheduleId == null || plantId == null) continue;

      final completions =
          await DatabaseHelper.instance.getScheduleCompletions(plantId);

      for (final c in completions) {
        if (c['scheduleId'] != scheduleId) continue;

        final rawAt = c['completedAt']?.toString() ?? '';
        if (rawAt.isEmpty) continue;

        DateTime completedAt;
        try {
          completedAt = DateTime.parse(rawAt);
        } catch (_) {
          continue;
        }

        final key = _occurrenceKey(scheduleId, completedAt);
        statuses[key] = c['status'] as String? ?? 'done';
      }
    }

    if (mounted) {
      setState(() => _occurrenceStatus
        ..clear()
        ..addAll(statuses));
    }
  }

  Future<void> _loadWeather() async {
    final summary = await WeatherService.getWeatherSummary();
    if (!mounted) return;
    setState(() {
      _rainExpected     = summary['isRain']    as bool?   ?? false;
      _hotDay           = summary['isHot']     as bool?   ?? false;
      _weatherCondition = summary['condition'] as String? ?? 'Unknown';
      _temperature      = (summary['temp'] as num?)?.toDouble();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIONS — DELETE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _onDeleteTapped(Map<String, dynamic> schedule) async {
    final repeatType  = schedule['repeatType']?.toString().toLowerCase() ?? 'none';
    final isRepeating = repeatType != 'none';

    if (!isRepeating) {
      await _deleteAllOccurrences(schedule['id'] as int);
      return;
    }

    final choice = await _showInstanceOrAllDialog(
      title:         'Delete schedule',
      instanceLabel: 'Delete this day only',
      allLabel:      'Delete all occurrences',
    );
    if (choice == null || !mounted) return;

    if (choice == 'instance') {
      await _deleteThisDayOnly(schedule);
    } else {
      await _deleteAllOccurrences(schedule['id'] as int);
    }
  }

  /// Deletes the entire schedule row and cancels all its notifications.
  Future<void> _deleteAllOccurrences(int scheduleId) async {
    await NotificationService.cancelNotification(scheduleId);
    await DatabaseHelper.instance.deleteSchedule(scheduleId);
    await _loadSchedules();
  }

  /// Suppresses a single occurrence:
  ///  1. Cancels the notification for that specific occurrence using BOTH
  ///     the base ID and the occurrence-derived ID (covers whichever was
  ///     used at booking time).
  ///  2. Records a 'skipped' completion so it is excluded from the calendar
  ///     on next load.
  ///  3. Removes it from the in-memory map immediately so the card vanishes
  ///     without waiting for a full reload.
  Future<void> _deleteThisDayOnly(Map<String, dynamic> schedule) async {
    final scheduleId = schedule['id'] as int;
    final plantId    = schedule['plantId'] as int;
    final type       = schedule['type'] as String? ?? '';
    final occDt      = DateTime.parse(schedule['dateTime'] as String);
    final key        = _occurrenceKey(scheduleId, occDt);

    // Guard: already actioned
    if (_occurrenceStatus.containsKey(key)) return;

    // ── Cancel notifications for this occurrence (both possible IDs) ──
    await _cancelOccurrenceNotifications(scheduleId, occDt);

    // ── Persist the skip so it survives app restarts ──
    await DatabaseHelper.instance.insertScheduleCompletion(
      scheduleId: scheduleId,
      plantId:    plantId,
      type:       type,
      status:     'skipped',
      at:         occDt,
    );

    if (!mounted) return;

    // ── Remove from in-memory calendar immediately ──
    final dayKey = _normalize(occDt);
    setState(() {
      _occurrenceStatus[key] = 'skipped';
      final dayList = _events[dayKey];
      if (dayList != null) {
        dayList.removeWhere((e) =>
            e['id'] == scheduleId &&
            _isSameDay(DateTime.parse(e['dateTime'] as String), occDt));
        if (dayList.isEmpty) _events.remove(dayKey);
      }
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIONS — EDIT
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _onEditTapped(Map<String, dynamic> schedule) async {
    final repeatType  = schedule['repeatType']?.toString().toLowerCase() ?? 'none';
    final isRepeating = repeatType != 'none';

    if (!isRepeating) {
      await _editAllOccurrences(schedule);
      return;
    }

    final choice = await _showInstanceOrAllDialog(
      title:         'Edit schedule',
      instanceLabel: 'Edit this day only',
      allLabel:      'Edit all occurrences',
    );
    if (choice == null || !mounted) return;

    if (choice == 'instance') {
      await _editThisDayOnly(schedule);
    } else {
      await _editAllOccurrences(schedule);
    }
  }

  /// Opens ScheduleScreen in create mode pre-seeded with this occurrence's
  /// values, then suppresses the original occurrence on this day.
  Future<void> _editThisDayOnly(Map<String, dynamic> schedule) async {
    final occDt   = DateTime.parse(schedule['dateTime'] as String);
    final plantId = schedule['plantId'] as int;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleScreen(
          plant: {
            'id':   plantId,
            'name': schedule['plantName'],
          },
          existingSchedule: null,
          prefillSchedule: {
            'type':           schedule['type'],
            'dateTime':       occDt.toIso8601String(),
            'repeatType':     'none',
            'repeatInterval': 1,
          },
        ),
      ),
    );

    if (result == true) {
      // _deleteThisDayOnly already cancels both notification IDs
      await _deleteThisDayOnly(schedule);
      await _loadSchedules();
    }
  }

  /// Updates the original DB row — all future occurrences follow.
  Future<void> _editAllOccurrences(Map<String, dynamic> schedule) async {
    final scheduleForEdit = Map<String, dynamic>.from(schedule);
    if (schedule.containsKey('originalStart')) {
      scheduleForEdit['dateTime'] = schedule['originalStart'];
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleScreen(
          plant: {
            'id':   schedule['plantId'],
            'name': schedule['plantName'],
          },
          existingSchedule: scheduleForEdit,
        ),
      ),
    );

    if (result == true) {
      final updated =
          await DatabaseHelper.instance.getSchedulesWithPlant();
      final updatedItem = updated.firstWhere(
        (e) => e['id'] == schedule['id'],
        orElse: () => {},
      );

      if (updatedItem.isNotEmpty) {
        final dt = DateTime.parse(updatedItem['dateTime'] as String);
        // Cancel both IDs before rescheduling
        await _cancelOccurrenceNotifications(
            schedule['id'] as int,
            DateTime.parse(schedule['dateTime'] as String));
        await NotificationService.showNotification(
          schedule['id'] as int,
          "${updatedItem['plantName']} — ${getScheduleLabel(updatedItem['type']?.toString())}",
          "Hi Plant Parent!",
          dt,
        );
      }

      await _loadSchedules();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ACTIONS — DONE / SKIP
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _recordCompletion(
      Map<String, dynamic> schedule, String status) async {
    final scheduleId = schedule['id'] as int;
    final plantId    = schedule['plantId'] as int;
    final type       = schedule['type'] as String? ?? '';
    final occDt      = DateTime.parse(schedule['dateTime'] as String);
    final key        = _occurrenceKey(scheduleId, occDt);

    if (_occurrenceStatus.containsKey(key)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Already recorded for this day."),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // ── FIX: cancel the notification when skipping OR marking done ──
    // Done: task is complete, reminder no longer needed.
    // Skipped: user explicitly dismissed this occurrence.
    // Cancel both possible notification IDs to be safe.
    await _cancelOccurrenceNotifications(scheduleId, occDt);

    await DatabaseHelper.instance.insertScheduleCompletion(
      scheduleId: scheduleId,
      plantId:    plantId,
      type:       type,
      status:     status,
      at:         occDt,
    );

    if (mounted) {
      setState(() => _occurrenceStatus[key] = status);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'done'
                ? "✓ Marked as done — recorded for Care Impact."
                : "✗ Marked as skipped.",
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SHARED DIALOG
  // ─────────────────────────────────────────────────────────────────────────

  Future<String?> _showInstanceOrAllDialog({
    required String title,
    required String instanceLabel,
    required String allLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: const Text(
          'Do you want to apply this change to just this day, '
          'or to all occurrences of this schedule?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'instance'),
            child: Text(instanceLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'all'),
            child: Text(allLabel),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PLANT SELECTION
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _showPlantSelectionDialog() async {
    final plants = await DatabaseHelper.instance.getPlants();
    if (plants.isEmpty || !mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Select Plant"),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: plants.length,
            itemBuilder: (_, i) {
              final plant = Map<String, dynamic>.from(plants[i]);
              return ListTile(
                title: Text(plant['name'] ?? ''),
                subtitle: Text(plant['type'] ?? ''),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ScheduleScreen(plant: plant)),
                  ).then((_) => _loadSchedules());
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CUSTOM CALENDAR
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildCalendar() {
    final theme        = Theme.of(context);
    final today        = _normalize(DateTime.now());
    final firstOfMonth = _focusedMonth;
    final daysInMonth  =
        DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    final startWeekday = (firstOfMonth.weekday - 1) % 7;
    final rows         = ((startWeekday + daysInMonth) / 7).ceil();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _focusedMonth =
                    DateTime(_focusedMonth.year, _focusedMonth.month - 1)),
              ),
              Expanded(
                child: Text(
                  DateFormat('MMMM yyyy').format(_focusedMonth),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _focusedMonth =
                    DateTime(_focusedMonth.year, _focusedMonth.month + 1)),
              ),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(d,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.secondary,
                            )),
                      ),
                    ))
                .toList(),
          ),
        ),

        const SizedBox(height: 4),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            children: List.generate(rows, (row) {
              return Row(
                children: List.generate(7, (col) {
                  final dayNum = row * 7 + col - startWeekday + 1;
                  if (dayNum < 1 || dayNum > daysInMonth) {
                    return const Expanded(child: SizedBox(height: 36));
                  }

                  final day        = DateTime(
                      firstOfMonth.year, firstOfMonth.month, dayNum);
                  final isSelected = _isSameDay(day, _selectedDay);
                  final isToday    = _isSameDay(day, today);
                  final hasEvents  = _eventsForDay(day).isNotEmpty;

                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedDay = day),
                      child: Container(
                        height: 36,
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : isToday
                                  ? theme.colorScheme.primaryContainer
                                  : Colors.transparent,
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Text('$dayNum',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isToday || isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isSelected
                                      ? theme.colorScheme.onPrimary
                                      : isToday
                                          ? theme.colorScheme.primary
                                          : null,
                                )),
                            if (hasEvents)
                              Positioned(
                                bottom: 3,
                                child: Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isSelected
                                        ? theme.colorScheme.onPrimary
                                        : Colors.green.shade600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              );
            }),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SCHEDULE CARD
  // ─────────────────────────────────────────────────────────────────────────

  Widget _scheduleCard(Map<String, dynamic> s) {
    final dt      = DateTime.parse(s['dateTime'] as String);
    final type    = s['type'] as String?;
    final isWater = type == 'water';
    final id      = s['id'] as int;

    final isOccurrenceToday = _isSameDay(dt, DateTime.now());

    final repeatType     = s['repeatType']?.toString().toLowerCase() ?? 'none';
    final repeatInterval =
        int.tryParse(s['repeatInterval']?.toString() ?? '1') ?? 1;

    String repeatLabel = '';
    if (repeatType == 'daily') {
      repeatLabel =
          repeatInterval == 1 ? 'Every day' : 'Every $repeatInterval days';
    } else if (repeatType == 'weekly') {
      repeatLabel =
          repeatInterval == 1 ? 'Every week' : 'Every $repeatInterval weeks';
    }

    // Per-occurrence status — only 'done' cards show a tint/badge now.
    // 'skipped' occurrences are filtered out before reaching this builder.
    final key        = _occurrenceKey(id, dt);
    final statusVal  = _occurrenceStatus[key];
    final isDone     = statusVal == 'done';
    final isActioned = isDone; // skipped never reaches here

    final cardTint = isDone ? Colors.green.withOpacity(0.06) : null;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: cardTint,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: getScheduleColor(type),
                child: Icon(getScheduleIcon(type),
                    color: Colors.white, size: 18),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s['plantName']?.toString() ?? 'Unknown Plant',
                          style:
                              const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (isDone)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '✓ Done',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (isOccurrenceToday && _temperature != null)
                    Text(
                      "$_weatherCondition • ${_temperature!.toStringAsFixed(1)}°C",
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey),
                    ),
                  if (isOccurrenceToday && _rainExpected && isWater)
                    const Text("🌧 Rain expected soon",
                        style:
                            TextStyle(fontSize: 12, color: Colors.blue)),
                  if (isOccurrenceToday && _hotDay && isWater)
                    const Text("☀ Hot conditions today",
                        style: TextStyle(
                            fontSize: 12, color: Colors.orange)),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${getScheduleLabel(type)} • "
                    "${DateFormat('yyyy-MM-dd HH:mm').format(dt)}",
                  ),
                  if (repeatLabel.isNotEmpty)
                    Text(
                      repeatLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20),
                    onPressed: () => _onEditTapped(s),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, size: 20),
                    onPressed: () => _onDeleteTapped(s),
                  ),
                ],
              ),
            ),

            // ── Done / Skip row ──
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isActioned
                          ? null
                          : () => _recordCompletion(s, 'done'),
                      icon: Icon(Icons.check_circle_outline,
                          size: 16,
                          color: isDone ? Colors.green
                              : isActioned ? Colors.grey
                              : Colors.green),
                      label: Text("Done",
                          style: TextStyle(
                              fontSize: 12,
                              color: isDone ? Colors.green
                                  : isActioned ? Colors.grey
                                  : Colors.green)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: isDone ? Colors.green
                                : isActioned ? Colors.grey.shade300
                                : Colors.green.withOpacity(0.5)),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isActioned
                          ? null
                          : () => _recordCompletion(s, 'skipped'),
                      icon: Icon(Icons.cancel_outlined,
                          size: 16,
                          color: isActioned
                              ? Colors.grey
                              : Colors.red.shade400),
                      label: Text("Skip",
                          style: TextStyle(
                              fontSize: 12,
                              color: isActioned
                                  ? Colors.grey
                                  : Colors.red.shade400)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                            color: isActioned
                                ? Colors.grey.shade300
                                : Colors.red.withOpacity(0.4)),
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final selectedEvents = _eventsForDay(_selectedDay);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Schedules 🌿"),
        actions: [
          Row(
            children: [
              const Text("Past"),
              Switch(
                value: _showPastSchedules,
                onChanged: (val) {
                  setState(() => _showPastSchedules = val);
                  _loadSchedules();
                },
              ),
            ],
          ),
        ],
      ),

      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            elevation: 1,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
              child: _buildCalendar(),
            ),
          ),

          const SizedBox(height: 8),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                DateFormat('EEEE, d MMMM yyyy').format(_selectedDay),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.grey),
              ),
            ),
          ),

          const SizedBox(height: 4),

          Expanded(
            child: selectedEvents.isEmpty
                ? const Center(child: Text("No schedules for this day"))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                    itemCount: selectedEvents.length,
                    itemBuilder: (_, i) =>
                        _scheduleCard(selectedEvents[i]),
                  ),
          ),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: _showPlantSelectionDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}