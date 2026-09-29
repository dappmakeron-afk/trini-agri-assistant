import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'database_helper.dart';
import 'notification_service.dart';

class CropTimelineScreen extends StatefulWidget {
  final Map<String, dynamic> plant;
  const CropTimelineScreen({super.key, required this.plant});

  @override
  State<CropTimelineScreen> createState() => _CropTimelineScreenState();
}

class _CropTimelineScreenState extends State<CropTimelineScreen> {
  final db = DatabaseHelper.instance;
  List<Map<String, dynamic>> _cycles = [];
  bool _loading = true;

  static const _milestoneKeys = [
    'sow_date',
    'transplant_date',
    'first_flower_date',
    'first_harvest_date',
    'harvest_end_date',
  ];

  static const _milestoneLabels = {
    'sow_date': 'Sow',
    'transplant_date': 'Transplant',
    'first_flower_date': 'First Flower',
    'first_harvest_date': 'First Harvest',
    'harvest_end_date': 'Harvest End',
  };

  static const _milestoneIcons = {
    'sow_date': '🌾',
    'transplant_date': '🌿',
    'first_flower_date': '🌸',
    'first_harvest_date': '🧺',
    'harvest_end_date': '📦',
  };

  static const _notifiableMilestones = {
    'transplant_date',
    'first_flower_date',
    'first_harvest_date',
    'harvest_end_date',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final cycles = await db.getCropCycles(widget.plant['id'] as int);
      if (mounted) setState(() { _cycles = cycles; _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Date helpers ──────────────────────────────────────────────────────────

  DateTime? _parseDate(dynamic val) {
    if (val == null || val.toString().isEmpty) return null;
    try { return DateTime.parse(val.toString()).toLocal(); } catch (_) { return null; }
  }

  String _fmt(DateTime? d) =>
      d == null ? '—' : DateFormat('dd MMM yyyy').format(d);

  Color _countdownColor(DateTime harvest) {
    final days = harvest.difference(DateTime.now()).inDays;
    if (days < 0) return Colors.red;
    if (days <= 14) return Colors.orange;
    return Colors.green;
  }

  // ── Estimation ────────────────────────────────────────────────────────────

  Map<String, DateTime> _estimateDates(DateTime sow, int matDays) => {
    'transplant_date':    sow.add(Duration(days: (matDays * 0.15).round())),
    'first_flower_date':  sow.add(Duration(days: (matDays * 0.50).round())),
    'first_harvest_date': sow.add(Duration(days: matDays)),
    'harvest_end_date':   sow.add(Duration(days: (matDays * 1.20).round())),
  };

  // ── Notifications ─────────────────────────────────────────────────────────

  Future<void> _scheduleNotificationsForCycle(Map<String, dynamic> cycle) async {
    final plantName = widget.plant['name'] as String;
    final cycleName = cycle['name']?.toString() ?? 'Cycle ${cycle['id']}';

    for (final key in _notifiableMilestones) {
      final date = _parseDate(cycle[key]);
      if (date == null) continue;
      final notifDate = DateTime(date.year, date.month, date.day, 7, 0);
      if (notifDate.isBefore(DateTime.now())) continue;

      final notifId = (cycle['id'].toString() + key).hashCode.abs() % 2147483647;
      try {
        await NotificationService.scheduleNotification(
          id: notifId,
          title: '${_milestoneIcons[key]} $plantName — ${_milestoneLabels[key]}',
          body: '$cycleName: ${_milestoneLabels[key]} milestone is today.',
          scheduledDate: notifDate,
        );

        if (key == 'harvest_end_date') {
          await NotificationService.scheduleNotification(
            id: (notifId + 1) % 2147483647,
            title: '⚠️ $plantName — Harvest Overdue',
            body: '$cycleName: Harvest window has passed. Log your yield or update dates.',
            scheduledDate: notifDate.add(const Duration(days: 1)),
          );
        }
      } on PlatformException catch (e) {
        debugPrint('Notification scheduling failed: ${e.code} — ${e.message}');
      }
    }
  }

  Future<void> _cancelNotificationsForCycle(Map<String, dynamic> cycle) async {
    for (final key in _notifiableMilestones) {
      final notifId = (cycle['id'].toString() + key).hashCode.abs() % 2147483647;
      await NotificationService.cancelNotification(notifId);
      if (key == 'harvest_end_date') {
        await NotificationService.cancelNotification((notifId + 1) % 2147483647);
      }
    }
  }

  // ── Save helper ───────────────────────────────────────────────────────────

  Future<void> _saveMilestonesAndRefresh(
      Map<String, dynamic> cycle, Map<String, String?> updates) async {
    await db.updateCropCycleMilestones(cycle['id'] as int, updates);
    await _cancelNotificationsForCycle(cycle);
    final fresh = await db.getCropCycles(widget.plant['id'] as int);
    final updated = fresh.firstWhere(
        (c) => c['id'] == cycle['id'], orElse: () => cycle);
    await _scheduleNotificationsForCycle(updated);
    await _load();
  }

  // ── Date picking ──────────────────────────────────────────────────────────

  Future<void> _pickMilestone(Map<String, dynamic> cycle, String key) async {
    final existing = _parseDate(cycle[key]);
    final picked = await showDatePicker(
      context: context,
      initialDate: existing ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: 'Select ${_milestoneLabels[key]} date',
    );
    if (picked == null) return;

    if (key == 'sow_date') {
      final typeName = widget.plant['type']?.toString() ?? '';
      final int? matDays = await db.getDefaultMaturationDays(typeName);
      if (matDays != null && matDays > 0) {
        if (!mounted) return;
        final confirmed = await _showEstimationSheet(picked, matDays);
        if (confirmed != null) {
          final updates = <String, String?>{};
          for (final k in _milestoneKeys) {
            final d = confirmed[k];
            updates[k] = d != null ? DateFormat('yyyy-MM-dd').format(d) : null;
          }
          await _saveMilestonesAndRefresh(cycle, updates);
          return;
        }
      }
    }

    await _saveMilestonesAndRefresh(
        cycle, {key: DateFormat('yyyy-MM-dd').format(picked)});
  }

  Future<Map<String, DateTime?>?> _showEstimationSheet(
      DateTime sowDate, int matDays) async {
    final estimates = _estimateDates(sowDate, matDays);
    final editable = <String, DateTime?>{'sow_date': sowDate, ...estimates};
    return showModalBottomSheet<Map<String, DateTime?>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _EstimationSheet(
        plantName: widget.plant['name'] as String,
        matDays: matDays,
        editable: editable,
        milestoneLabels: _milestoneLabels,
        milestoneIcons: _milestoneIcons,
      ),
    );
  }

  // ── Seed Packet Calculator ────────────────────────────────────────────────

  Future<void> _showSeedPacketCalculator(Map<String, dynamic> cycle) async {
    final result = await showModalBottomSheet<Map<String, String?>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _SeedPacketCalculatorSheet(
        plantName: widget.plant['name'] as String,
        existingSowDate: _parseDate(cycle['sow_date']),
        milestoneLabels: _milestoneLabels,
        milestoneIcons: _milestoneIcons,
        estimateDates: _estimateDates,
      ),
    );

    if (result == null || !mounted) return;
    await _saveMilestonesAndRefresh(cycle, result);
  }

  // ── Add cycle ─────────────────────────────────────────────────────────────

  Future<void> _addCycle() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Grow Cycle'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Cycle name',
            hintText: 'e.g. Spring 2025, Bed A',
          ),
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await db.createCropCycle(widget.plant['id'] as int, name);
    await _load();
  }

  // ── Edit / Delete ─────────────────────────────────────────────────────────

  Future<void> _editCycleOptions(Map<String, dynamic> cycle) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename cycle'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete cycle',
                  style: TextStyle(color: Colors.red)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx, null),
            ),
          ],
        ),
      ),
    );

    if (choice == 'rename') await _renameCycle(cycle);
    if (choice == 'delete') await _deleteCycle(cycle);
  }

  Future<void> _renameCycle(Map<String, dynamic> cycle) async {
    final controller =
        TextEditingController(text: cycle['name']?.toString() ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Cycle'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Cycle name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await db.renameCropCycle(cycle['id'] as int, name);
    await _load();
  }

  Future<void> _deleteCycle(Map<String, dynamic> cycle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Cycle?'),
        content: Text(
            'This will permanently delete "${cycle['name']}" and all its milestone dates.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _cancelNotificationsForCycle(cycle);
    await db.deleteCropCycle(cycle['id'] as int);
    await _load();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.plant['name']} — Crop Timeline')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCycle,
        icon: const Icon(Icons.add),
        label: const Text('New Cycle'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cycles.isEmpty
              ? _buildEmpty(theme)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: _cycles.length,
                  itemBuilder: (_, i) => _buildCycleCard(_cycles[i], theme),
                ),
    );
  }

  Widget _buildEmpty(ThemeData theme) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('🌱', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          Text('No grow cycles yet', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Tap New Cycle to start tracking\nthis plant\'s milestones.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall),
        ]),
      );

  Widget _buildCycleCard(Map<String, dynamic> cycle, ThemeData theme) {
    final sowDate = _parseDate(cycle['sow_date']);
    final harvestDate = _parseDate(cycle['first_harvest_date']);
    final harvestEnd = _parseDate(cycle['harvest_end_date']);
    final now = DateTime.now();

    String? countdownText;
    Color? countdownColor;

    if (harvestDate != null) {
      final days = harvestDate.difference(now).inDays;
      if (days > 0) {
        countdownText = '$days days to harvest';
        countdownColor = _countdownColor(harvestDate);
      } else if (harvestEnd != null && now.isBefore(harvestEnd)) {
        countdownText = 'In harvest window';
        countdownColor = Colors.green;
      } else {
        countdownText = 'Harvest overdue';
        countdownColor = Colors.red;
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Header row ──
          Row(children: [
            Expanded(
              child: Text(
                cycle['name']?.toString() ?? 'Cycle ${cycle['id']}',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (countdownText != null) ...[
              Chip(
                label: Text(countdownText,
                    style: const TextStyle(fontSize: 11, color: Colors.white)),
                backgroundColor: countdownColor,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
            ],
            // ── Seed Packet Calculator button ──
            IconButton(
              icon: const Icon(Icons.calculate_outlined),
              tooltip: 'Seed packet calculator',
              onPressed: () => _showSeedPacketCalculator(cycle),
            ),
            // ── Edit/Delete button ──
            IconButton(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Edit or delete',
              onPressed: () => _editCycleOptions(cycle),
            ),
          ]),

          if (sowDate != null) ...[
            const SizedBox(height: 4),
            Text('Started ${_fmt(sowDate)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.secondary)),
          ],

          const SizedBox(height: 16),
          _buildMilestoneRow(cycle, theme),
        ]),
      ),
    );
  }

  Widget _buildMilestoneRow(Map<String, dynamic> cycle, ThemeData theme) {
    return Row(
      children: List.generate(_milestoneKeys.length, (i) {
        final key = _milestoneKeys[i];
        final date = _parseDate(cycle[key]);
        final hasDate = date != null;
        final isPast = hasDate && date.isBefore(DateTime.now());
        final isNotifiable = _notifiableMilestones.contains(key);

        return Expanded(
          child: Column(children: [
            Row(children: [
              if (i > 0)
                Expanded(
                    child: Container(
                        height: 2,
                        color: isPast
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant)),
              GestureDetector(
                onTap: () => _pickMilestone(cycle, key),
                child: Stack(alignment: Alignment.topRight, children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: hasDate
                          ? (isPast
                              ? theme.colorScheme.primary
                              : theme.colorScheme.primaryContainer)
                          : theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color: hasDate
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                        width: 2,
                      ),
                    ),
                    child: Center(
                        child: Text(_milestoneIcons[key]!,
                            style: const TextStyle(fontSize: 16))),
                  ),
                  if (isNotifiable && hasDate)
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary,
                          shape: BoxShape.circle),
                      child: const Icon(Icons.notifications,
                          size: 9, color: Colors.white),
                    ),
                ]),
              ),
              if (i < _milestoneKeys.length - 1)
                Expanded(
                    child: Container(
                        height: 2,
                        color: theme.colorScheme.outlineVariant)),
            ]),
            const SizedBox(height: 6),
            Text(_milestoneLabels[key]!,
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center),
            GestureDetector(
              onTap: () => _pickMilestone(cycle, key),
              child: Text(
                hasDate ? _fmt(date) : 'tap',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: hasDate
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  fontWeight:
                      hasDate ? FontWeight.w600 : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ]),
        );
      }),
    );
  }
}

// ── Estimation sheet (unchanged) ──────────────────────────────────────────────

class _EstimationSheet extends StatefulWidget {
  final String plantName;
  final int matDays;
  final Map<String, DateTime?> editable;
  final Map<String, String> milestoneLabels;
  final Map<String, String> milestoneIcons;

  const _EstimationSheet({
    required this.plantName,
    required this.matDays,
    required this.editable,
    required this.milestoneLabels,
    required this.milestoneIcons,
  });

  @override
  State<_EstimationSheet> createState() => _EstimationSheetState();
}

class _EstimationSheetState extends State<_EstimationSheet> {
  late final Map<String, DateTime?> _dates;

  static const _order = [
    'sow_date', 'transplant_date', 'first_flower_date',
    'first_harvest_date', 'harvest_end_date',
  ];

  @override
  void initState() {
    super.initState();
    _dates = Map.from(widget.editable);
  }

  Future<void> _editDate(String key) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dates[key] ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: 'Override ${widget.milestoneLabels[key]}',
    );
    if (picked != null) setState(() => _dates[key] = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = DateFormat('dd MMM yyyy');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Row(children: [
          const Text('🗓️', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Text('Estimated Milestone Dates',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            Text('${widget.plantName} · ${widget.matDays}-day maturation',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.secondary)),
          ])),
        ]),
        const SizedBox(height: 6),
        Text(
          'These are estimates based on your crop type. '
          'Tap ✏️ next to any date to override it before saving.',
          style: theme.textTheme.bodySmall,
        ),
        const Divider(height: 24),
        ..._order.map((key) {
          final date = _dates[key];
          final isEstimate = key != 'sow_date';
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Text(widget.milestoneIcons[key]!,
                style: const TextStyle(fontSize: 22)),
            title: Text(widget.milestoneLabels[key]!),
            subtitle: isEstimate
                ? Text('Estimated',
                    style: TextStyle(
                        fontSize: 11, color: theme.colorScheme.secondary))
                : null,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(date != null ? fmt.format(date) : '—',
                  style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary)),
              if (isEstimate) ...[
                const SizedBox(width: 4),
                IconButton(
                    icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                    onPressed: () => _editDate(key),
                    tooltip: 'Override date'),
              ],
            ]),
          );
        }),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'))),
          const SizedBox(width: 12),
          Expanded(
              flex: 2,
              child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _dates),
                  icon: const Icon(Icons.check),
                  label: const Text('Save All Dates'))),
        ]),
      ]),
    );
  }
}

// ── Seed Packet Calculator Sheet ──────────────────────────────────────────────

class _SeedPacketCalculatorSheet extends StatefulWidget {
  final String plantName;
  final DateTime? existingSowDate;
  final Map<String, String> milestoneLabels;
  final Map<String, String> milestoneIcons;
  final Map<String, DateTime> Function(DateTime sow, int matDays) estimateDates;

  const _SeedPacketCalculatorSheet({
    required this.plantName,
    required this.existingSowDate,
    required this.milestoneLabels,
    required this.milestoneIcons,
    required this.estimateDates,
  });

  @override
  State<_SeedPacketCalculatorSheet> createState() =>
      _SeedPacketCalculatorSheetState();
}

class _SeedPacketCalculatorSheetState
    extends State<_SeedPacketCalculatorSheet> {
  bool _useWeeks = false;
  final _inputController = TextEditingController();
  DateTime? _sowDate;
  int? _parsedDays;

  static final _fmt = DateFormat('dd MMM yyyy');

  @override
  void initState() {
    super.initState();
    _sowDate = widget.existingSowDate;
    _inputController.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final raw = int.tryParse(_inputController.text.trim());
    setState(() {
      if (raw != null && raw > 0) {
        _parsedDays = _useWeeks ? raw * 7 : raw;
      } else {
        _parsedDays = null;
      }
    });
  }

  void _toggleUnit(bool weeks) {
    setState(() {
      _useWeeks = weeks;
      // Re-parse with new unit
      final raw = int.tryParse(_inputController.text.trim());
      if (raw != null && raw > 0) {
        _parsedDays = weeks ? raw * 7 : raw;
      }
    });
  }

  DateTime? get _harvestDate {
    if (_sowDate == null || _parsedDays == null) return null;
    return _sowDate!.add(Duration(days: _parsedDays!));
  }

  Future<void> _pickSowDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _sowDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: 'When did / will you sow?',
    );
    if (picked != null) setState(() => _sowDate = picked);
  }

  /// Returns updates map for autofill (all milestones)
  Map<String, String?> _buildAutofillUpdates() {
    final sow = _sowDate!;
    final days = _parsedDays!;
    final estimates = widget.estimateDates(sow, days);
    final fmt = DateFormat('yyyy-MM-dd');
    return {
      'sow_date': fmt.format(sow),
      'transplant_date': fmt.format(estimates['transplant_date']!),
      'first_flower_date': fmt.format(estimates['first_flower_date']!),
      'first_harvest_date': fmt.format(estimates['first_harvest_date']!),
      'harvest_end_date': fmt.format(estimates['harvest_end_date']!),
    };
  }

  /// Returns updates map for harvest-only save
  Map<String, String?> _buildHarvestOnlyUpdates() {
    final fmt = DateFormat('yyyy-MM-dd');
    return {
      'first_harvest_date': fmt.format(_harvestDate!),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final harvest = _harvestDate;
    final canSave = harvest != null;

    // Build preview rows for autofill
    List<_PreviewRow>? previewRows;
    if (canSave && _sowDate != null && _parsedDays != null) {
      final estimates = widget.estimateDates(_sowDate!, _parsedDays!);
      previewRows = [
        _PreviewRow('sow_date', _sowDate!),
        _PreviewRow('transplant_date', estimates['transplant_date']!),
        _PreviewRow('first_flower_date', estimates['first_flower_date']!),
        _PreviewRow('first_harvest_date', estimates['first_harvest_date']!),
        _PreviewRow('harvest_end_date', estimates['harvest_end_date']!),
      ];
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 
          MediaQuery.of(context).padding.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Handle ──
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),

            // ── Title ──
            Row(children: [
              const Text('🌱', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Seed Packet Calculator',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold)),
                    Text(
                      widget.plantName,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.secondary),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
              'Enter the days or weeks to harvest from your seed packet '
              'and we\'ll calculate your milestone dates automatically.',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 24),

            // ── Sow date row ──
            Row(children: [
              const Text('🌾', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _sowDate != null
                      ? 'Sow date: ${DateFormat('dd MMM yyyy').format(_sowDate!)}'
                      : 'No sow date set — tap to pick one',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _sowDate != null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.outline,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _pickSowDate,
                icon: const Icon(Icons.edit_calendar_outlined, size: 16),
                label: Text(_sowDate != null ? 'Change' : 'Set date'),
              ),
            ]),
            const SizedBox(height: 16),

            // ── Days / Weeks toggle ──
            Row(children: [
              Expanded(
                child: Text('Time to harvest on packet:',
                    style: theme.textTheme.bodyMedium),
              ),
              // Toggle pill
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _ToggleChip(
                    label: 'Days',
                    selected: !_useWeeks,
                    onTap: () => _toggleUnit(false),
                    theme: theme,
                  ),
                  _ToggleChip(
                    label: 'Weeks',
                    selected: _useWeeks,
                    onTap: () => _toggleUnit(true),
                    theme: theme,
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 10),

            // ── Number input ──
            TextField(
              controller: _inputController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: _useWeeks
                    ? 'e.g. 13  (= 91 days)'
                    : 'e.g. 90',
                labelText:
                    _useWeeks ? 'Weeks until harvest' : 'Days until harvest',
                prefixIcon: const Icon(Icons.schedule_outlined),
                suffixText: _useWeeks ? 'weeks' : 'days',
                border: const OutlineInputBorder(),
                helperText: _parsedDays != null && _useWeeks
                    ? '$_parsedDays days total'
                    : null,
              ),
            ),
            const SizedBox(height: 16),

            // ── Live preview ──
            if (canSave) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.auto_awesome,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text('Projected Dates',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 10),
                    ...previewRows!.map((r) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(children: [
                            Text(widget.milestoneIcons[r.key]!,
                                style: const TextStyle(fontSize: 16)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(widget.milestoneLabels[r.key]!,
                                  style: theme.textTheme.bodySmall),
                            ),
                            Text(
                              DateFormat('dd MMM yyyy').format(r.date),
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary),
                            ),
                          ]),
                        )),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ] else if (_sowDate == null && _parsedDays != null) ...[
              // Nudge user to set sow date
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Set a sow date above to see your harvest preview.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],

            // ── Action buttons ──
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canSave
                      ? () => Navigator.pop(
                          context, _buildHarvestOnlyUpdates())
                      : null,
                  icon: const Icon(Icons.agriculture_outlined, size: 18),
                  label: const Text('Harvest Only'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canSave
                    ? () => Navigator.pop(context, _buildAutofillUpdates())
                    : null,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Autofill All Dates'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _PreviewRow {
  final String key;
  final DateTime date;
  const _PreviewRow(this.key, this.date);
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _ToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}