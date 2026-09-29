import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:intl/intl.dart';

import 'database_helper.dart';
import 'growth_stages.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────

class _DayYield {
  final String date;
  final double amount;
  const _DayYield(this.date, this.amount);
}

class _StageChange {
  final String date;
  final String stage;
  const _StageChange(this.date, this.stage);
}

/// One period bucket holding yield totals + confirmed care counts.
class _ImpactBucket {
  final String label;
  final String startDate;
  final String endDate;
  final double yieldTotal;
  final Map<String, int> careCounts; // type → count of 'done' completions

  const _ImpactBucket({
    required this.label,
    required this.startDate,
    required this.endDate,
    required this.yieldTotal,
    required this.careCounts,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// CARE TYPE DEFINITIONS  (mirrors plant_logs_screen + schedule_colors)
// ─────────────────────────────────────────────────────────────────────────────

class _CareType {
  final String value;
  final String label;
  final Color color;
  final IconData icon;
  const _CareType(this.value, this.label, this.color, this.icon);
}

const List<_CareType> _kCareTypes = [
  _CareType('water',      'Water',      Colors.blue,   Icons.water_drop),
  _CareType('fertilize',  'Fertilize',  Colors.green,  Icons.eco),
  _CareType('appearance', 'Appearance', Colors.orange, Icons.visibility),
  _CareType('pest',       'Pest',       Colors.red,    Icons.bug_report),
  _CareType('disease',    'Disease',    Colors.purple, Icons.coronavirus),
];

IconData _careIcon(String type) =>
    _kCareTypes
        .firstWhere((t) => t.value == type,
            orElse: () => const _CareType('', '', Colors.grey, Icons.circle))
        .icon;

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class YieldGraphScreen extends StatefulWidget {
  final Map<String, dynamic> plant;
  const YieldGraphScreen({super.key, required this.plant});

  @override
  State<YieldGraphScreen> createState() => _YieldGraphScreenState();
}

class _YieldGraphScreenState extends State<YieldGraphScreen>
    with SingleTickerProviderStateMixin {

  // ── Yield data ─────────────────────────────────────────────────────────────
  List<_DayYield> _allDays  = [];
  List<_DayYield> _filtered = [];

  // ── Comparison data ────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _allPlants         = [];
  List<int> _comparedPlantIds                   = [];
  final Map<int, List<_DayYield>> _comparedData = {};
  Map<int, Color> _plantColors                  = {};

  // ── Stage markers ──────────────────────────────────────────────────────────
  List<_StageChange> _stageChanges = [];

  // ── Daily tab filters ──────────────────────────────────────────────────────
  String _filterMode      = 'all';
  bool _showAverage       = true;
  bool _showStageMarkers  = true;
  bool _comparisonLoading = false;

  // ── Care Impact tab state ──────────────────────────────────────────────────
  List<_ImpactBucket> _impactBuckets = [];
  String _impactPeriod               = 'weekly';
  Set<String> _activeCareTypes       = {
    'water', 'fertilize', 'appearance', 'pest', 'disease'
  };
  bool _impactLoading = false;

  /// Only 'done' schedule completions — skipped events are excluded so the
  /// Care Impact chart reflects care that actually happened.
  List<Map<String, dynamic>> _completions = [];

  // ── Voice ──────────────────────────────────────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening       = false;
  bool _isProcessingVoice = false;
  bool _dataChanged       = false;

  late TabController _tabController;

  static const List<Color> _palette = [
    Color(0xFFE53935),
    Color(0xFF1E88E5),
    Color(0xFFFB8C00),
    Color(0xFF8E24AA),
    Color(0xFF00897B),
  ];

  // ─────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      setState(() {});
      if (_tabController.index == 2 &&
          _impactBuckets.isEmpty &&
          !_impactLoading) {
        _loadImpactData();
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // SAFE DATE PARSING
  // ─────────────────────────────────────────────────────────────────────────

  String _parseDateSafe(dynamic raw) {
    final fallback = DateFormat('yyyy-MM-dd').format(DateTime.now());
    if (raw == null) return fallback;
    if (raw is String) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return DateFormat('yyyy-MM-dd').format(dt);
      final n = int.tryParse(raw);
      if (n != null) return _fromUnix(n);
      return fallback;
    }
    if (raw is int)    return _fromUnix(raw);
    if (raw is double) return _fromUnix(raw.toInt());
    return fallback;
  }

  String _fromUnix(int n) {
    final dt = n > 10000000000
        ? DateTime.fromMillisecondsSinceEpoch(n)
        : DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return DateFormat('yyyy-MM-dd').format(dt);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DATA LOADING
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    await Future.wait([
      _loadPrimaryYields(),
      _loadStageChanges(),
      _loadAllPlants(),
      _loadCompletions(),
    ]);
  }

  Future<void> _loadPrimaryYields() async {
    final raw = await DatabaseHelper.instance.getYields(widget.plant['id']);
    final grouped = <String, double>{};
    for (final y in raw) {
      final date = _parseDateSafe(y['dateTime']);
      grouped[date] = (grouped[date] ?? 0) + (y['amount'] as num).toDouble();
    }
    final days = grouped.entries
        .map((e) => _DayYield(e.key, e.value))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    setState(() => _allDays = days);
    _applyFilter();
  }

  Future<void> _loadStageChanges() async {
    final logs =
        await DatabaseHelper.instance.getPlantLogs(widget.plant['id']);
    final changes = <_StageChange>[];
    for (final l in logs) {
      final type  = (l['type'] ?? '').toString().toLowerCase();
      final notes = (l['notes'] ?? '').toString();
      if (type == 'stage_change' || type.contains('stage')) {
        final date  = _parseDateSafe(l['dateTime']);
        final stage = notes.trim().isNotEmpty ? notes.trim() : type;
        changes.add(_StageChange(date, stage));
      }
    }
    if (changes.isEmpty) {
      final currentStage = widget.plant['growth_stage']?.toString();
      if (currentStage != null &&
          currentStage.trim().isNotEmpty &&
          _allDays.isNotEmpty) {
        changes.add(_StageChange(_allDays.first.date, currentStage));
      }
    }
    setState(() => _stageChanges = changes);
  }

  Future<void> _loadAllPlants() async {
    final plants = await DatabaseHelper.instance.getPlants();
    setState(() {
      _allPlants =
          plants.where((p) => p['id'] != widget.plant['id']).toList();
    });
  }

  /// Loads only 'done' completions from schedule_completions.
  /// Skipped entries are intentionally excluded — the chart should only
  /// reflect care that was actually performed.
  Future<void> _loadCompletions() async {
    final rows = await DatabaseHelper.instance
        .getDoneCompletions(widget.plant['id']);
    final careTypes = _kCareTypes.map((t) => t.value).toSet();
    setState(() {
      _completions = rows
          .where((r) => careTypes.contains((r['type'] ?? '').toString()))
          .toList();
    });
  }

  Future<void> _loadComparisonPlant(int plantId) async {
    final raw = await DatabaseHelper.instance.getYields(plantId);
    final grouped = <String, double>{};
    for (final y in raw) {
      final date = _parseDateSafe(y['dateTime']);
      grouped[date] = (grouped[date] ?? 0) + (y['amount'] as num).toDouble();
    }
    final days = grouped.entries
        .map((e) => _DayYield(e.key, e.value))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    setState(() => _comparedData[plantId] = days);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CARE IMPACT — BUCKET BUILDER
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _loadImpactData() async {
    if (_impactLoading) return;
    setState(() => _impactLoading = true);
    if (_completions.isEmpty && _allDays.isEmpty) {
      await Future.wait([_loadPrimaryYields(), _loadCompletions()]);
    } else if (_completions.isEmpty) {
      await _loadCompletions();
    }
    final buckets = _buildImpactBuckets();
    if (mounted) {
      setState(() {
        _impactBuckets = buckets;
        _impactLoading = false;
      });
    }
  }

  List<_ImpactBucket> _buildImpactBuckets() {
    if (_allDays.isEmpty && _completions.isEmpty) return [];

    final allDateStrings = <String>[
      ..._allDays.map((d) => d.date),
      ..._completions.map((c) => _parseDateSafe(c['completedAt'])),
    ]..sort();

    if (allDateStrings.isEmpty) return [];

    final rangeStart = DateTime.parse(allDateStrings.first);
    final rangeEnd   = DateTime.parse(allDateStrings.last);

    final bucketStarts = <DateTime>[];
    if (_impactPeriod == 'daily') {
      var cur = DateTime(rangeStart.year, rangeStart.month, rangeStart.day);
      while (!cur.isAfter(rangeEnd)) {
        bucketStarts.add(cur);
        cur = cur.add(const Duration(days: 1));
      }
    } else if (_impactPeriod == 'weekly') {
      var cur = DateTime(rangeStart.year, rangeStart.month, rangeStart.day);
      cur = cur.subtract(Duration(days: cur.weekday - 1));
      while (!cur.isAfter(rangeEnd)) {
        bucketStarts.add(cur);
        cur = cur.add(const Duration(days: 7));
      }
    } else {
      var cur = DateTime(rangeStart.year, rangeStart.month);
      while (!cur.isAfter(rangeEnd)) {
        bucketStarts.add(cur);
        cur = DateTime(cur.year, cur.month + 1);
      }
    }

    if (bucketStarts.isEmpty) return [];

    final yieldByDate = <String, double>{
      for (final d in _allDays) d.date: d.amount,
    };

    final completionsByDate = <String, List<String>>{};
    for (final c in _completions) {
      final date = _parseDateSafe(c['completedAt']);
      final type = (c['type'] ?? '').toString();
      if (type.isNotEmpty) {
        completionsByDate.putIfAbsent(date, () => []).add(type);
      }
    }

    DateTime bucketEnd(DateTime start) {
      if (_impactPeriod == 'daily')  return start;
      if (_impactPeriod == 'weekly') return start.add(const Duration(days: 6));
      return DateTime(start.year, start.month + 1, 0);
    }

    String bucketLabel(DateTime start) {
      if (_impactPeriod == 'daily')  return DateFormat('dd/MM').format(start);
      if (_impactPeriod == 'weekly') return 'W${_isoWeekNumber(start)}';
      return DateFormat('MMM').format(start);
    }

    final buckets = <_ImpactBucket>[];

    for (final bStart in bucketStarts) {
      final bEnd        = bucketEnd(bStart);
      double totalYield = 0;
      final careCounts  = <String, int>{};

      var day = bStart;
      while (!day.isAfter(bEnd)) {
        final dateStr = DateFormat('yyyy-MM-dd').format(day);
        totalYield += yieldByDate[dateStr] ?? 0;
        for (final type in (completionsByDate[dateStr] ?? [])) {
          careCounts[type] = (careCounts[type] ?? 0) + 1;
        }
        day = day.add(const Duration(days: 1));
      }

      buckets.add(_ImpactBucket(
        label:      bucketLabel(bStart),
        startDate:  DateFormat('yyyy-MM-dd').format(bStart),
        endDate:    DateFormat('yyyy-MM-dd').format(bEnd),
        yieldTotal: totalYield,
        careCounts: careCounts,
      ));
    }

    int first = 0;
    while (first < buckets.length &&
        buckets[first].yieldTotal == 0 &&
        buckets[first].careCounts.isEmpty) {
      first++;
    }
    int last = buckets.length - 1;
    while (last > first &&
        buckets[last].yieldTotal == 0 &&
        buckets[last].careCounts.isEmpty) {
      last--;
    }

    return buckets.sublist(first, last + 1);
  }

  int _isoWeekNumber(DateTime date) {
    final dayOfYear = int.parse(DateFormat('D').format(date));
    return ((dayOfYear - date.weekday + 10) / 7).floor();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CORRELATION INSIGHT
  // ─────────────────────────────────────────────────────────────────────────

  List<String> _computeInsights() {
    if (_impactBuckets.length < 3) return [];
    final insights = <String>[];

    for (final ct in _kCareTypes) {
      if (!_activeCareTypes.contains(ct.value)) continue;

      final pairs = <(int care, double yieldNext)>[];
      for (int i = 0; i < _impactBuckets.length - 1; i++) {
        final care      = _impactBuckets[i].careCounts[ct.value] ?? 0;
        final nextYield = _impactBuckets[i + 1].yieldTotal;
        pairs.add((care, nextYield));
      }

      final withCare    = pairs.where((p) => p.$1 > 0).toList();
      final withoutCare = pairs.where((p) => p.$1 == 0).toList();
      if (withCare.isEmpty || withoutCare.isEmpty) continue;

      final avgWith =
          withCare.fold(0.0, (s, p) => s + p.$2) / withCare.length;
      final avgWithout =
          withoutCare.fold(0.0, (s, p) => s + p.$2) / withoutCare.length;
      final diff = avgWith - avgWithout;
      if (diff.abs() < 0.1) continue;

      final periodName = _impactPeriod == 'daily'
          ? 'day'
          : _impactPeriod == 'weekly' ? 'week' : 'month';

      insights.add(diff > 0
          ? '${ct.label}: yield is ${diff.toStringAsFixed(1)} units higher '
              'the $periodName after a ${ct.label.toLowerCase()} event.'
          : '${ct.label}: yield tends to be ${(-diff).toStringAsFixed(1)} '
              'units lower the $periodName after a ${ct.label.toLowerCase()} '
              'event (may reflect reactive care).');
    }

    final highCare = _impactBuckets.where(
        (b) => b.careCounts.values.fold(0, (s, v) => s + v) >= 2).toList();
    final noCare = _impactBuckets.where(
        (b) => b.careCounts.values.fold(0, (s, v) => s + v) == 0).toList();

    if (highCare.isNotEmpty && noCare.isNotEmpty) {
      final avgH =
          highCare.fold(0.0, (s, b) => s + b.yieldTotal) / highCare.length;
      final avgL =
          noCare.fold(0.0, (s, b) => s + b.yieldTotal) / noCare.length;
      if ((avgH - avgL).abs() > 0.1) {
        insights.add(
          'Overall: periods with ≥2 care events average '
          '${avgH.toStringAsFixed(1)} units vs '
          '${avgL.toStringAsFixed(1)} in periods with no care.',
        );
      }
    }

    return insights;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // FILTER  (Daily tab)
  // ─────────────────────────────────────────────────────────────────────────

  void _applyFilter() {
    final now = DateTime.now();
    if (_filterMode == '7') {
      _filtered = _allDays
          .where((y) => now.difference(DateTime.parse(y.date)).inDays <= 7)
          .toList();
    } else if (_filterMode == '30') {
      _filtered = _allDays
          .where((y) => now.difference(DateTime.parse(y.date)).inDays <= 30)
          .toList();
    } else {
      _filtered = List.from(_allDays);
    }
    setState(() {});
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ROLLING AVERAGE
  // ─────────────────────────────────────────────────────────────────────────

  List<double> _computeRollingAverage({int window = 7}) {
    if (_filtered.isEmpty) return [];
    final result = <double>[];
    for (int i = 0; i < _filtered.length; i++) {
      final start = (i - window + 1).clamp(0, i);
      final slice = _filtered.sublist(start, i + 1);
      result.add(slice.fold(0.0, (s, e) => s + e.amount) / slice.length);
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STAGE MARKER POSITIONS
  // ─────────────────────────────────────────────────────────────────────────

  List<({int index, _StageChange change})> _stageMarkerPositions() {
    if (_filtered.isEmpty) return [];
    final result = <({int index, _StageChange change})>[];
    for (final sc in _stageChanges) {
      for (int i = 0; i < _filtered.length; i++) {
        if (_filtered[i].date.compareTo(sc.date) >= 0) {
          result.add((index: i, change: sc));
          break;
        }
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ADD YIELD
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _addYieldDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("Add Yield — ${widget.plant['name']}"),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: "Amount"),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel")),
          ElevatedButton(
              onPressed: () {
                final val = double.tryParse(controller.text);
                if (val != null) Navigator.pop(context, val);
              },
              child: const Text("Save")),
        ],
      ),
    );

    if (result != null) {
      await DatabaseHelper.instance.insertYield({
        'plantId':  widget.plant['id'],
        'amount':   result,
        'dateTime': DateTime.now().toIso8601String(),
      });
      _dataChanged = true;
      await _loadPrimaryYields();
      if (_impactBuckets.isNotEmpty) {
        final buckets = _buildImpactBuckets();
        if (mounted) setState(() => _impactBuckets = buckets);
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Yield added: $result")));
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // VOICE
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _startListening() async {
    final available = await _speech.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(onResult: (result) {
        if (result.finalResult) {
          _handleVoiceCommand(result.recognizedWords.toLowerCase());
          setState(() => _isListening = false);
        }
      });
    }
  }

  void _handleVoiceCommand(String command) async {
    if (_isProcessingVoice) return;
    _isProcessingVoice = true;
    try {
      final text = command.trim();
      if (text.contains("yield")) {
        final match = RegExp(r'\d+(\.\d+)?').firstMatch(text);
        if (match != null) {
          final value = double.parse(match.group(0)!);
          await DatabaseHelper.instance.insertYield({
            'plantId':  widget.plant['id'],
            'amount':   value,
            'dateTime': DateTime.now().toIso8601String(),
          });
          _dataChanged = true;
          await _loadPrimaryYields();
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text("Yield added: $value")));
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Say a number with yield")));
          }
        }
        return;
      }
      if (text.contains("week") || text.contains("7")) {
        _filterMode = "7";
      } else if (text.contains("30") || text.contains("month")) {
        _filterMode = "30";
      } else if (text.contains("all")) {
        _filterMode = "all";
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Command not recognised")));
        }
      }
      _applyFilter();
    } catch (e) {
      debugPrint("VOICE ERROR: $e");
    } finally {
      _isProcessingVoice = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // COMPARISON PICKER
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _showComparisonPicker() async {
    final selected = Set<int>.from(_comparedPlantIds);
    final picked = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text("Compare with plants"),
          content: SizedBox(
            width: 280,
            child: _allPlants.isEmpty
                ? const Text("No other plants to compare.")
                : ListView(
                    shrinkWrap: true,
                    children: _allPlants.map((p) {
                      final id   = p['id'] as int;
                      final name = p['name']?.toString() ?? 'Plant';
                      return CheckboxListTile(
                        title: Text(name),
                        value: selected.contains(id),
                        onChanged: (v) {
                          setS(() {
                            if (v == true) {
                              if (selected.length < 5) selected.add(id);
                            } else {
                              selected.remove(id);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel")),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, selected),
                child: const Text("Apply")),
          ],
        ),
      ),
    );

    if (picked == null) return;
    final ids = List<int>.from(picked);
    final colors = <int, Color>{};
    int ci = 0;
    for (final id in ids) {
      colors[id] = _palette[ci % _palette.length];
      ci++;
    }
    for (final id in _comparedPlantIds.where((id) => !ids.contains(id))) {
      _comparedData.remove(id);
    }
    setState(() {
      _comparedPlantIds  = ids;
      _plantColors       = colors;
      _comparisonLoading = ids.isNotEmpty;
    });
    await Future.wait(ids.map((id) => _loadComparisonPlant(id)));
    if (mounted) setState(() => _comparisonLoading = false);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CHART HELPERS
  // ─────────────────────────────────────────────────────────────────────────

  double _getMaxY() {
    if (_filtered.isEmpty) return 10;
    double max =
        _filtered.map((e) => e.amount).fold(0.0, (a, b) => a > b ? a : b);
    for (final days in _comparedData.values) {
      for (final d in days) {
        if (d.amount > max) max = d.amount;
      }
    }
    return max + 5;
  }

  double _getInterval() {
    final m = _getMaxY();
    if (m <= 10)  return 1;
    if (m <= 50)  return 5;
    if (m <= 100) return 10;
    return (m / 5).ceilToDouble();
  }

  List<BarChartGroupData> _buildBars() {
    final maxVal = _getMaxY();
    return List.generate(_filtered.length, (i) {
      final val       = _filtered[i].amount;
      final intensity = val / maxVal;
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: val,
            width: 16,
            borderRadius: BorderRadius.circular(5),
            color: Colors.green.withOpacity(0.3 + intensity * 0.7),
          ),
        ],
      );
    });
  }

  LineChartBarData _buildAverageLine(List<double> avgs) {
    return LineChartBarData(
      spots: List.generate(avgs.length, (i) => FlSpot(i.toDouble(), avgs[i])),
      isCurved: true,
      color: Colors.orange,
      barWidth: 2.5,
      dotData: const FlDotData(show: false),
      belowBarData:
          BarAreaData(show: true, color: Colors.orange.withOpacity(0.08)),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — DAILY TAB
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildSinglePlantChart() {
    if (_filtered.isEmpty) {
      return const Center(child: Text("No data — tap + to add a yield"));
    }
    final avgValues       = _computeRollingAverage();
    final markerPositions = _stageMarkerPositions();
    final maxY            = _getMaxY();

    return Stack(
      children: [
        BarChart(
          BarChartData(
            maxY: maxY,
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, __) {
                  final item = _filtered[group.x];
                  return BarTooltipItem(
                    "${item.date}\n${rod.toY.toStringAsFixed(1)}",
                    const TextStyle(color: Colors.white),
                  );
                },
              ),
            ),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                axisNameWidget: const Text("Yield"),
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: _getInterval(),
                ),
              ),
              bottomTitles: AxisTitles(
                axisNameWidget: const Text("Date"),
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (value, _) {
                    if (value != value.roundToDouble()) return const SizedBox();
                    final i = value.toInt();
                    if (i < 0 || i >= _filtered.length) return const SizedBox();
                    final step = (_filtered.length / 6).ceil().clamp(1, 999);
                    if (i % step != 0) return const SizedBox();
                    final d = DateTime.parse(_filtered[i].date);
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(DateFormat('dd/MM').format(d),
                          style: const TextStyle(fontSize: 9)),
                    );
                  },
                ),
              ),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            gridData:   const FlGridData(show: true),
            borderData: FlBorderData(show: false),
            barGroups:  _buildBars(),
          ),
        ),

        if (_showAverage && avgValues.length == _filtered.length)
          IgnorePointer(
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (_filtered.length - 1).toDouble(),
                minY: 0,
                maxY: maxY,
                lineBarsData:  [_buildAverageLine(avgValues)],
                titlesData:    const FlTitlesData(show: false),
                gridData:      const FlGridData(show: false),
                borderData:    FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
              ),
            ),
          ),

        if (_showStageMarkers && markerPositions.isNotEmpty)
          IgnorePointer(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const leftReserved   = 44.0;
                const bottomReserved = 30.0;
                final drawWidth = constraints.maxWidth - leftReserved;
                final n = _filtered.length;
                return Stack(
                  children: markerPositions.map((mp) {
                    final fraction = n <= 1 ? 0.5 : mp.index / (n - 1);
                    final x = leftReserved + fraction * drawWidth;
                    final stageColor =
                        getGrowthStageColor(mp.change.stage).withOpacity(0.85);
                    return Positioned(
                      left: x - 1,
                      top: 0,
                      bottom: bottomReserved,
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: stageColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                              border:
                                  Border.all(color: stageColor, width: 0.8),
                            ),
                            child: Text(
                              '${getGrowthStageEmoji(mp.change.stage)} '
                              '${getGrowthStageLabel(mp.change.stage)}',
                              style: TextStyle(
                                fontSize: 8,
                                color: stageColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Expanded(
                            child: CustomPaint(
                                painter:
                                    _DashedLinePainter(color: stageColor)),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — COMPARE TAB
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildComparisonChart() {
    if (_allPlants.isEmpty) {
      return const Center(
          child: Text("No other plants available to compare."));
    }
    if (_comparedPlantIds.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.compare_arrows, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text("No plants selected for comparison.",
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text("Select plants"),
              onPressed: _showComparisonPicker,
            ),
          ],
        ),
      );
    }
    if (_comparisonLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final allDates = <String>{};
    for (final d in _allDays) allDates.add(d.date);
    for (final id in _comparedPlantIds) {
      for (final d in (_comparedData[id] ?? [])) allDates.add(d.date);
    }
    if (allDates.isEmpty) {
      return const Center(child: Text("No yield data for selected plants."));
    }
    final sortedDates = allDates.toList()..sort();

    final lines  = <LineChartBarData>[];
    final legend = <({String name, Color color})>[];

    final primaryByDate = {for (final d in _allDays) d.date: d.amount};
    final primarySpots  = <FlSpot>[];
    for (int i = 0; i < sortedDates.length; i++) {
      final v = primaryByDate[sortedDates[i]];
      if (v != null) primarySpots.add(FlSpot(i.toDouble(), v));
    }
    if (primarySpots.isNotEmpty) {
      lines.add(LineChartBarData(
        spots:    primarySpots,
        isCurved: primarySpots.length >= 3,
        color:    Colors.green,
        barWidth: 2.5,
        dotData:  FlDotData(show: primarySpots.length == 1),
      ));
      legend.add((
        name:  widget.plant['name']?.toString() ?? 'This plant',
        color: Colors.green,
      ));
    }

    for (final id in _comparedPlantIds) {
      final days = _comparedData[id];
      if (days == null || days.isEmpty) continue;
      final color  = _plantColors[id] ?? Colors.grey;
      final byDate = {for (final d in days) d.date: d.amount};
      final plant  = _allPlants.firstWhere(
        (p) => p['id'] == id,
        orElse: () => {'name': 'Plant $id'},
      );
      final spots = <FlSpot>[];
      for (int i = 0; i < sortedDates.length; i++) {
        final v = byDate[sortedDates[i]];
        if (v != null) spots.add(FlSpot(i.toDouble(), v));
      }
      if (spots.isEmpty) continue;
      lines.add(LineChartBarData(
        spots:     spots,
        isCurved:  spots.length >= 3,
        color:     color,
        barWidth:  2,
        dotData:   FlDotData(show: spots.length == 1),
        dashArray: [6, 3],
      ));
      legend.add((
        name:  plant['name']?.toString() ?? 'Plant',
        color: color,
      ));
    }

    if (lines.isEmpty) {
      return const Center(child: Text("No yield data for selected plants."));
    }

    double maxY = 10;
    for (final line in lines) {
      for (final s in line.spots) {
        if (s.y > maxY) maxY = s.y;
      }
    }
    maxY += 5;
    double interval = 1;
    if (maxY > 10)  interval = 5;
    if (maxY > 50)  interval = 10;
    if (maxY > 100) interval = (maxY / 5).ceilToDouble();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: legend.map((l) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 16, height: 3, color: l.color),
                const SizedBox(width: 4),
                Text(l.name, style: const TextStyle(fontSize: 11)),
              ],
            )).toList(),
          ),
        ),
        Expanded(
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: (sortedDates.length - 1).toDouble(),
              minY: 0,
              maxY: maxY,
              lineBarsData: lines,
              lineTouchData: LineTouchData(
                enabled: true,
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((ts) {
                    final idx  = ts.x.toInt();
                    final date = idx >= 0 && idx < sortedDates.length
                        ? sortedDates[idx]
                        : '';
                    return LineTooltipItem(
                      '$date\n${ts.y.toStringAsFixed(1)}',
                      TextStyle(
                          color: ts.bar.color ?? Colors.white, fontSize: 11),
                    );
                  }).toList(),
                ),
              ),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  axisNameWidget: const Text("Yield"),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    interval: interval,
                  ),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: const Text("Date"),
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, _) {
                      if (value != value.roundToDouble()) return const SizedBox();
                      final i = value.toInt();
                      if (i < 0 || i >= sortedDates.length) return const SizedBox();
                      final step =
                          (sortedDates.length / 5).ceil().clamp(1, 999);
                      if (i % step != 0) return const SizedBox();
                      final d = DateTime.parse(sortedDates[i]);
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(DateFormat('dd/MM').format(d),
                            style: const TextStyle(fontSize: 9)),
                      );
                    },
                  ),
                ),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData:   const FlGridData(show: true),
              borderData: FlBorderData(show: false),
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — CARE IMPACT TAB
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildCareImpactTab() {
    if (_impactLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_allDays.isEmpty && _completions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights, size: 52, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              "No data yet.\nAdd yield entries and mark schedules\nas done to see impact analysis.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight;
        const controlsH = 90.0;
        final remaining = (available - controlsH).clamp(0.0, double.infinity);
        final chartH    = (remaining * 0.32).clamp(120.0, 200.0);
        final insightH  =
            (remaining - chartH * 2 - 40).clamp(120.0, double.infinity);

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPeriodSelector(),
              const SizedBox(height: 6),
              _buildCareFilterChips(),
              const SizedBox(height: 10),

              if (_impactBuckets.isEmpty)
                const SizedBox(
                  height: 120,
                  child:
                      Center(child: Text("No data for selected filters.")),
                )
              else ...[
                _buildPanelLabel("Yield per period", Colors.green.shade700),
                const SizedBox(height: 4),
                SizedBox(
                  height: chartH,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                    child: _buildYieldPanel(),
                  ),
                ),

                const SizedBox(height: 12),

                _buildPanelLabel(
                    "Completed care per period", Colors.blueGrey.shade600),
                const SizedBox(height: 4),
                SizedBox(
                  height: chartH,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
                    child: _buildCareFrequencyPanel(),
                  ),
                ),

                const SizedBox(height: 12),

                SizedBox(height: insightH, child: _buildInsightCard()),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildPanelLabel(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Container(
              width: 3,
              height: 14,
              color: color,
              margin: const EdgeInsets.only(right: 6)),
          Text(text,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    const periods = [
      ('daily', 'Daily'), ('weekly', 'Weekly'), ('monthly', 'Monthly'),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: periods.map((p) {
        final selected = _impactPeriod == p.$1;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ChoiceChip(
            label: Text(p.$2),
            selected: selected,
            selectedColor: Theme.of(context).colorScheme.primary,
            labelStyle: TextStyle(
                color: selected ? Colors.white : null, fontSize: 12),
            onSelected: (_) async {
              setState(() {
                _impactPeriod  = p.$1;
                _impactLoading = true;
              });
              await Future.microtask(() {});
              final buckets = _buildImpactBuckets();
              if (mounted) {
                setState(() {
                  _impactBuckets = buckets;
                  _impactLoading = false;
                });
              }
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCareFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: _kCareTypes.map((ct) {
          final active = _activeCareTypes.contains(ct.value);
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FilterChip(
              avatar: Icon(_careIcon(ct.value),
                  size: 14, color: active ? ct.color : Colors.grey),
              label: Text(ct.label,
                  style: TextStyle(
                      fontSize: 11,
                      color: active ? ct.color : Colors.grey)),
              selected: active,
              selectedColor: ct.color.withOpacity(0.12),
              checkmarkColor: ct.color,
              side: BorderSide(
                  color: active
                      ? ct.color.withOpacity(0.5)
                      : Colors.grey.shade300),
              showCheckmark: false,
              onSelected: (val) {
                setState(() {
                  if (val) {
                    _activeCareTypes.add(ct.value);
                  } else {
                    if (_activeCareTypes.length > 1) {
                      _activeCareTypes.remove(ct.value);
                    }
                  }
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildYieldPanel() {
    final buckets = _impactBuckets;
    if (buckets.isEmpty) return const SizedBox();

    double maxY =
        buckets.fold(0.0, (m, b) => b.yieldTotal > m ? b.yieldTotal : m);
    if (maxY == 0) maxY = 1;
    maxY = maxY * 1.25;
    double yInterval = 1;
    if (maxY > 10)  yInterval = (maxY / 4).ceilToDouble();
    if (maxY > 100) yInterval = (maxY / 5).ceilToDouble();

    return BarChart(
      BarChartData(
        maxY: maxY,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, rod, __) {
              final b = buckets[group.x];
              return BarTooltipItem(
                '${b.startDate}'
                '${b.startDate != b.endDate ? '\n→ ${b.endDate}' : ''}'
                '\nYield: ${rod.toY.toStringAsFixed(1)}',
                const TextStyle(color: Colors.white, fontSize: 11),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: yInterval,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(v % 1 == 0 ? 0 : 1),
                style: const TextStyle(fontSize: 9),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, _) {
                if (value != value.roundToDouble()) return const SizedBox();
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) return const SizedBox();
                final step = (buckets.length / 6).ceil().clamp(1, 999);
                if (i % step != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(buckets[i].label,
                      style: const TextStyle(fontSize: 8)),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.withOpacity(0.15), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(buckets.length, (i) {
          final val       = buckets[i].yieldTotal;
          final intensity =
              maxY > 0 ? (val / maxY).clamp(0.0, 1.0) : 0.0;
          return BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: val,
                width: _barWidth(buckets.length),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
                color: Colors.green.withOpacity(0.3 + intensity * 0.7),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildCareFrequencyPanel() {
    final buckets     = _impactBuckets;
    final activeTypes = _kCareTypes
        .where((t) => _activeCareTypes.contains(t.value))
        .toList();
    if (buckets.isEmpty || activeTypes.isEmpty) return const SizedBox();

    int maxCount = 1;
    for (final b in buckets) {
      for (final t in activeTypes) {
        final c = b.careCounts[t.value] ?? 0;
        if (c > maxCount) maxCount = c;
      }
    }
    final maxY       = (maxCount + 1).toDouble();
    final groupWidth = _barWidth(buckets.length);
    final rodWidth   = (groupWidth / activeTypes.length).clamp(6.0, 12.0);

    return BarChart(
      BarChartData(
        maxY: maxY,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              if (groupIndex >= buckets.length) return null;
              if (rodIndex >= activeTypes.length) return null;
              final b     = buckets[groupIndex];
              final ct    = activeTypes[rodIndex];
              final count = b.careCounts[ct.value] ?? 0;
              return BarTooltipItem(
                '${b.label}\n${ct.label}: $count',
                TextStyle(color: ct.color, fontSize: 11),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 1,
              getTitlesWidget: (v, _) {
                if (v % 1 != 0) return const SizedBox();
                return Text(v.toInt().toString(),
                    style: const TextStyle(fontSize: 9));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, _) {
                if (value != value.roundToDouble()) return const SizedBox();
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) return const SizedBox();
                final step = (buckets.length / 6).ceil().clamp(1, 999);
                if (i % step != 0) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(buckets[i].label,
                      style: const TextStyle(fontSize: 8)),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 1,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.withOpacity(0.15), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        barGroups: List.generate(buckets.length, (i) {
          final bucket = buckets[i];
          return BarChartGroupData(
            x: i,
            groupVertically: false,
            barRods: activeTypes.map((ct) {
              final count = bucket.careCounts[ct.value] ?? 0;
              return BarChartRodData(
                toY: count.toDouble(),
                width: rodWidth,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
                color: count > 0
                    ? ct.color.withOpacity(0.75)
                    : ct.color.withOpacity(0.08),
              );
            }).toList(),
          );
        }),
      ),
    );
  }

  double _barWidth(int n) {
    if (n <= 8)  return 18;
    if (n <= 16) return 12;
    if (n <= 30) return 8;
    return 5;
  }

  Widget _buildInsightCard() {
    final insights = _computeInsights();
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 4),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceVariant
            .withOpacity(0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color:
                Theme.of(context).colorScheme.outline.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(Icons.lightbulb_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  "Care Impact Insights",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 12, endIndent: 12),
          Expanded(
            child: insights.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _impactBuckets.length < 3
                          ? "More data needed — insights appear once you have\n"
                              "at least 3 periods of completed care."
                          : "No strong correlation found yet between completed\n"
                              "care and yield for the selected filters.",
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: insights.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, idx) {
                      final text = insights[idx];
                      Color dotColor = Colors.grey;
                      for (final ct in _kCareTypes) {
                        if (text.startsWith(ct.label)) {
                          dotColor = ct.color;
                          break;
                        }
                      }
                      if (text.startsWith('Overall')) dotColor = Colors.blueGrey;
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding:
                                const EdgeInsets.only(top: 4, right: 8),
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                  color: dotColor, shape: BoxShape.circle),
                            ),
                          ),
                          Expanded(
                            child: Text(text,
                                style: const TextStyle(
                                    fontSize: 12, height: 1.45)),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (insights.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 4,
                children: _kCareTypes
                    .where((t) => _activeCareTypes.contains(t.value))
                    .map((ct) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                  color: ct.color.withOpacity(0.8),
                                  shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 4),
                            Text(ct.label,
                                style: const TextStyle(fontSize: 10)),
                          ],
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD — FILTER / OVERLAY WIDGETS  (Daily tab)
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildFilterRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _filterChip("All",     "all"),
        _filterChip("7 Days",  "7"),
        _filterChip("30 Days", "30"),
      ],
    );
  }

  Widget _filterChip(String label, String mode) {
    return ChoiceChip(
      label: Text(label),
      selected: _filterMode == mode,
      selectedColor: Colors.green,
      labelStyle:
          TextStyle(color: _filterMode == mode ? Colors.white : null),
      onSelected: (_) {
        _filterMode = mode;
        _applyFilter();
      },
    );
  }

  Widget _buildOverlayToggles() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: [
        FilterChip(
          label: const Text("Avg line"),
          avatar: const Icon(Icons.show_chart, size: 16),
          selected: _showAverage,
          selectedColor: Colors.orange.shade100,
          onSelected: (v) => setState(() => _showAverage = v),
        ),
        FilterChip(
          label: const Text("Stage markers"),
          avatar: const Icon(Icons.flag_outlined, size: 16),
          selected: _showStageMarkers,
          selectedColor: Colors.purple.shade100,
          onSelected: (v) => setState(() => _showStageMarkers = v),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) Navigator.pop(context, _dataChanged);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _dataChanged),
          ),
          title: Text("${widget.plant['name']} Yield"),
          bottom: TabBar(
            controller: _tabController,
            tabs: const [
              Tab(icon: Icon(Icons.bar_chart),      text: "Daily"),
              Tab(icon: Icon(Icons.compare_arrows), text: "Compare"),
              Tab(icon: Icon(Icons.insights),       text: "Care Impact"),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: "Add yield",
              onPressed: _addYieldDialog,
            ),
            if (_tabController.index == 1)
              IconButton(
                icon: const Icon(Icons.playlist_add_check),
                tooltip: "Select plants",
                onPressed: _showComparisonPicker,
              ),
            IconButton(
              icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
              color: _isListening ? Colors.red : null,
              onPressed: _startListening,
            ),
          ],
        ),

        body: SafeArea(
          child: TabBarView(
            controller: _tabController,
            children: [

              // ── TAB 1 — DAILY ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    const Text("Daily Yield",
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      'Say "yield 5" to log · "week" / "month" / "all" to filter',
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade500),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    _buildFilterRow(),
                    const SizedBox(height: 6),
                    _buildOverlayToggles(),
                    const SizedBox(height: 12),
                    if (_showStageMarkers && _stageChanges.isNotEmpty)
                      _buildStageLegend(),
                    const SizedBox(height: 8),
                    Expanded(child: _buildSinglePlantChart()),
                  ],
                ),
              ),

              // ── TAB 2 — COMPARE ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Plant Comparison",
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          icon: const Icon(Icons.edit, size: 16),
                          label: const Text("Edit"),
                          onPressed: _showComparisonPicker,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(child: _buildComparisonChart()),
                  ],
                ),
              ),

              // ── TAB 3 — CARE IMPACT ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            "Care Impact Analysis",
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: "Refresh data",
                          onPressed: () async {
                            await _loadCompletions();
                            final buckets = _buildImpactBuckets();
                            if (mounted) {
                              setState(() => _impactBuckets = buckets);
                            }
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Based on schedules marked as done — skipped events excluded.",
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade500),
                    ),
                    const SizedBox(height: 10),
                    Expanded(child: _buildCareImpactTab()),
                  ],
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStageLegend() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: _stageChanges.map((sc) {
        final color = getGrowthStageColor(sc.stage);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 2, height: 14, color: color),
            const SizedBox(width: 4),
            Text(
              '${getGrowthStageEmoji(sc.stage)} '
              '${getGrowthStageLabel(sc.stage)} (${sc.date})',
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DASHED LINE PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color       = color
      ..strokeWidth = 1.5
      ..style       = PaintingStyle.stroke;
    const dashH = 5.0;
    const gapH  = 4.0;
    double y    = 0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(0, (y + dashH).clamp(0, size.height)),
        paint,
      );
      y += dashH + gapH;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) => old.color != color;
}