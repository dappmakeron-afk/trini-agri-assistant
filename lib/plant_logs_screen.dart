import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'database_helper.dart';

class PlantLogsScreen extends StatefulWidget {
  final Map<String, dynamic> plant;

  const PlantLogsScreen({super.key, required this.plant});

  @override
  State<PlantLogsScreen> createState() => _PlantLogsScreenState();
}

class _PlantLogsScreenState extends State<PlantLogsScreen> {
  List<Map<String, dynamic>> logs = [];

  // ── Single source of truth for log types ─────────────────────────────────
  // Both the voice handler and the FAB dialog read from this list.
  // To add a new type, add one entry here — nowhere else.
  static const _logTypes = [
    _LogType('water',      'Water',      Colors.blue),
    _LogType('fertilize',  'Fertilize',  Colors.green),
    _LogType('appearance', 'Appearance', Colors.orange),
    _LogType('pest',       'Pest',       Colors.red),
    _LogType('disease',    'Disease',    Colors.purple),
  ];

  // Quick lookups derived from the list above
  static String _formatType(String type) =>
      _logTypes.firstWhere((t) => t.value == type,
              orElse: () => _LogType(type, type, Colors.grey))
          .label;

  static Color _getLogColor(String type) =>
      _logTypes.firstWhere((t) => t.value == type,
              orElse: () => _LogType(type, type, Colors.grey))
          .color;

  static const _severityTypes = {'pest', 'disease'};

  // ── Voice ─────────────────────────────────────────────────────────────────
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening       = false;
  bool _isProcessingVoice = false;

  Future<void> _startListening() async {
    bool available = await _speech.initialize();
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

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  void _handleVoiceCommand(String command) async {
    if (_isProcessingVoice) return;
    _isProcessingVoice = true;

    try {
      final text = command.toLowerCase().trim();

      // ── Detect log type from voice ──
      String? detectedType;
      if (text.contains("water") || text.contains("watered")) {
        detectedType = "water";
      } else if (text.contains("fertilize") ||
          text.contains("fertilizer") ||
          text.contains("fertilised")) {
        detectedType = "fertilize";
      } else if (text.contains("appearance") ||
          text.contains("looking") ||
          text.contains("looks")) {
        detectedType = "appearance";
      } else if (text.contains("pest") ||
          text.contains("bug") ||
          text.contains("insect")) {
        detectedType = "pest";
      } else if (text.contains("disease") ||
          text.contains("sick") ||
          text.contains("rot")) {
        detectedType = "disease";
      }

      if (detectedType == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Say "water", "fertilize", "appearance", "pest", or "disease"',
              ),
            ),
          );
        }
        return;
      }

      // ── Detect severity ──
      String? detectedSeverity;
      if (_severityTypes.contains(detectedType)) {
        if (text.contains("high") ||
            text.contains("severe") ||
            text.contains("bad")) {
          detectedSeverity = "High";
        } else if (text.contains("medium") || text.contains("moderate")) {
          detectedSeverity = "Medium";
        } else if (text.contains("low") ||
            text.contains("minor") ||
            text.contains("small")) {
          detectedSeverity = "Low";
        }
      }

      // ── Strip keywords to form notes ──
      final strippable = [
        "log", "add", "water", "watered", "fertilize", "fertilizer",
        "fertilised", "appearance", "looking", "looks", "pest", "bug",
        "insect", "disease", "sick", "rot", "high", "severe", "bad",
        "medium", "moderate", "low", "minor", "small",
      ];
      String notes = text;
      for (final word in strippable) {
        notes = notes.replaceAll(word, '');
      }
      notes = notes.replaceAll(RegExp(r'\s+'), ' ').trim();

      // ── Confirm before saving ──
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Row(
            children: [
              CircleAvatar(
                backgroundColor: _getLogColor(detectedType!),
                radius: 12,
              ),
              const SizedBox(width: 10),
              Text("Log ${_formatType(detectedType)}?"),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Type: ${_formatType(detectedType)}"),
              if (detectedSeverity != null)
                Text("Severity: $detectedSeverity"),
              if (notes.isNotEmpty) Text("Notes: $notes"),
              if (notes.isEmpty && detectedSeverity == null)
                const Text("No extra details detected."),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text("Save"),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await DatabaseHelper.instance.insertLog({
          'plantId':  widget.plant['id'],
          'type':     detectedType,
          'dateTime': DateTime.now().toIso8601String(),
          'notes':    notes,
          'severity': detectedSeverity,
        });
        // FIX: await + mounted guard
        await _loadLogs();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("${_formatType(detectedType)} log saved")),
          );
        }
      }
    } catch (e) {
      // FIX: debugPrint instead of print
      debugPrint("VOICE ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Voice command failed")),
        );
      }
    } finally {
      _isProcessingVoice = false;
    }
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _loadLogs() async {
    final data =
        await DatabaseHelper.instance.getPlantLogs(widget.plant['id']);
    // FIX: mounted guard before setState
    if (!mounted) return;
    setState(() => logs = data);
  }

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("${widget.plant['name']} Logs"),
        actions: [
          IconButton(
            icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
            color: _isListening ? Colors.red : null,
            tooltip: "Voice log",
            onPressed: _isListening ? _stopListening : _startListening,
          ),
        ],
      ),

      body: Column(
        children: [
          // ── Voice hint ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Text(
              'Say "water", "fertilize", "pest high", "disease low", etc.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: 6),

          // ── Log list ──
          Expanded(
            child: logs.isEmpty
                ? const Center(child: Text("No logs yet"))
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, index) {
                      final log  = logs[index];
                      final type = log['type'] ?? '';
                      DateTime? date;
                      try {
                        date = log['dateTime'] != null
                            ? DateTime.parse(log['dateTime']).toLocal()
                            : null;
                      } catch (_) {
                        date = null;
                      }

                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _getLogColor(type),
                          ),
                          title: Text(_formatType(type)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (log['severity'] != null &&
                                  log['severity'].toString().isNotEmpty)
                                Text("Severity: ${log['severity']}"),
                              if (log['notes'] != null &&
                                  log['notes'].toString().isNotEmpty)
                                Text(log['notes']),
                            ],
                          ),
                          trailing: Text(
                            date != null
                                ? "${date.year}-${date.month}-${date.day}\n"
                                    "${date.hour}:${date.minute.toString().padLeft(2, '0')}"
                                : '',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),

      // ── FABs ──
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: "voice",
            mini: true,
            backgroundColor: _isListening ? Colors.red : Colors.green,
            tooltip: "Voice log",
            onPressed: _isListening ? _stopListening : _startListening,
            child: Icon(_isListening ? Icons.mic : Icons.mic_none),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: "add",
            tooltip: "Add Log",
            onPressed: _showAddLogDialog,
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  // ── Manual add dialog ─────────────────────────────────────────────────────
  // FIX: uses _logTypes list — adding a new type here automatically
  // appears in both the voice handler and this dialog.
  Future<void> _showAddLogDialog() async {
    // Step 1: pick type
    final type = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text("Select Type"),
        children: _logTypes
            .map((t) => SimpleDialogOption(
                  child: Row(
                    children: [
                      CircleAvatar(
                          backgroundColor: t.color,
                          radius: 8),
                      const SizedBox(width: 10),
                      Text(t.label),
                    ],
                  ),
                  onPressed: () => Navigator.pop(context, t.value),
                ))
            .toList(),
      ),
    );
    if (type == null || !mounted) return;

    // Step 2: notes + optional severity
    final notesController  = TextEditingController();
    String? selectedSeverity;
    final needsSeverity = _severityTypes.contains(type);

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: Text("Add ${_formatType(type)} Log"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (needsSeverity)
                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(
                        labelText: "Severity (optional)"),
                    items: ['Low', 'Medium', 'High']
                        .map((s) => DropdownMenuItem(
                            value: s, child: Text(s)))
                        .toList(),
                    onChanged: (val) =>
                        setStateDialog(() => selectedSeverity = val),
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: "Notes (optional)",
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () async {
                await DatabaseHelper.instance.insertLog({
                  'plantId':  widget.plant['id'],
                  'type':     type,
                  'dateTime': DateTime.now().toIso8601String(),
                  'notes':    notesController.text,
                  'severity': selectedSeverity,
                });
                if (mounted) Navigator.pop(context);
                await _loadLogs();
              },
              child: const Text("Save"),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Value type for log type definitions ──────────────────────────────────────
class _LogType {
  final String value;
  final String label;
  final Color color;
  const _LogType(this.value, this.label, this.color);
}