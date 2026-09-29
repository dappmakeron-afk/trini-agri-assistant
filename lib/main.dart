import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'add_plant_screen.dart';
import 'schedule_screen.dart';
import 'plant_logs_screen.dart';
import 'all_schedules_screen.dart';
import 'yield_graph_screen.dart';
import 'crop_timeline_screen.dart';
import 'theme_provider.dart';
import 'export_service.dart';
import 'growth_stages.dart';
import 'permission_service.dart';
import 'permissions_onboarding_screen.dart';

Future<void> setupTimezone() async {
  tz.initializeTimeZones();
  try {
    tz.setLocalLocation(tz.getLocation('America/Port_of_Spain'));
  } catch (e) {
    tz.setLocalLocation(tz.UTC);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupTimezone();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Trini Agri Assistant 🌱',
      themeMode: themeProvider.themeMode,
      theme: ThemeData(
          brightness: Brightness.light, primarySwatch: Colors.green),
      darkTheme: ThemeData(
          brightness: Brightness.dark, primarySwatch: Colors.green),
      home: const PlantListScreen(),
    );
  }
}

class PlantListScreen extends StatefulWidget {
  const PlantListScreen({super.key});

  @override
  State<PlantListScreen> createState() => _PlantListScreenState();
}

class _PlantListScreenState extends State<PlantListScreen> {
  List<Map<String, dynamic>> plants = [];
  Map<String, dynamic>? selectedPlant;
  String? selectedImage;

  final ImagePicker picker = ImagePicker();

  // ── VOICE ──
  late stt.SpeechToText _speech;
  bool _isListening       = false;
  bool _isProcessingVoice = false;

  @override
  void initState() {
    super.initState();
    loadPlants();
    _speech = stt.SpeechToText();
    // Check permissions after the first frame so Navigator is ready
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsOnboarding();
    });
  }

  // ── PERMISSIONS ONBOARDING ──
  Future<void> _checkPermissionsOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('permissions_seen') ?? false;
    // Show if never seen OR if any permission has since been revoked
    if (!seen || await PermissionService.anyDenied()) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PermissionsOnboardingScreen(
          onComplete: () => Navigator.of(context).pop(),
        ),
      ));
    }
  }

  // ── VOICE METHODS ──
  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  Future<void> _startListening() async {
    bool available = await _speech.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(onResult: (result) {
        if (result.recognizedWords.isNotEmpty) {
          _handleVoiceCommand(result.recognizedWords.toLowerCase());
        }
        if (result.finalResult) setState(() => _isListening = false);
      });
    }
  }

  void _handleVoiceCommand(String command) async {
    if (_isProcessingVoice) return;
    _isProcessingVoice = true;
    try {
      final text = command.toLowerCase().trim();

      if (text.contains("yield")) {
        if (selectedPlant == null) {
          _snack("Please select a plant first");
          return;
        }
        final match = RegExp(r'\d+').firstMatch(text);
        if (match != null) {
          final value = int.parse(match.group(0)!);
          await DatabaseHelper.instance.insertYield({
            'plantId':  selectedPlant!['id'],
            'amount':   value,
            'dateTime': DateTime.now().toIso8601String(),
          });
          await loadPlants();
          _snack("Yield added: $value");
        } else {
          _snack("Say a number with yield");
        }
        return;
      }

      if (text.contains("timeline") || text.contains("crop timeline")) {
        if (selectedPlant != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => CropTimelineScreen(plant: selectedPlant!)),
          );
        } else {
          _snack("Select a plant first to view its crop timeline");
        }
        return;
      }

      if (text.contains("schedule") ||
          text.contains("water") ||
          text.contains("fertilize")) {
        if (selectedPlant != null) {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ScheduleScreen(plant: selectedPlant!)));
        }
        return;
      }

      if (text.contains("graph")) {
        if (selectedPlant != null) {
          final changed = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
                builder: (_) => YieldGraphScreen(plant: selectedPlant!)),
          );
          if (changed == true) await loadPlants();
        }
        return;
      }

      String plantName = text
          .replaceAll("open", "")
          .replaceAll("show", "")
          .replaceAll("plant", "")
          .replaceAll("add", "")
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (plantName.isEmpty) {
        _snack("No plant name detected");
        return;
      }

      final existing = plants.where(
          (p) => p['name'].toString().toLowerCase() == plantName.toLowerCase());

      if (existing.isNotEmpty) {
        setState(() {
          selectedPlant = existing.first;
          selectedImage = existing.first['imagePath'];
        });
        _snack("Plant detected: ${existing.first['name']}");
      } else {
        await DatabaseHelper.instance.insertPlant({
          "name":        plantName,
          "type":        "Unknown",
          "description": "Added via voice command",
          "imagePath":   null,
        });
        await loadPlants();
        _snack("New plant added: $plantName");
      }
    } catch (e) {
      _snack("Voice command failed");
    } finally {
      _isProcessingVoice = false;
    }
  }

  // ── DATA ──
  Future<void> loadPlants() async {
    final data = await DatabaseHelper.instance.getPlants();
    if (!mounted) return;
    setState(() {
      plants = data;
      if (selectedPlant != null) {
        final updated =
            plants.where((p) => p['id'] == selectedPlant!['id']);
        if (updated.isNotEmpty) {
          selectedPlant = updated.first;
          selectedImage = selectedPlant?['imagePath'];
        }
      }
    });
  }

  Future<List<Map<String, dynamic>>> _getPlantImages(int plantId) async {
    return await DatabaseHelper.instance.getPlantImages(plantId);
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  // ── EXPORT / IMPORT ──
  Future<void> _handleExportImport(String action) async {
    try {
      if (action == 'csv') {
        await ExportService.exportAllCSV();
      } else if (action == 'pdf') {
        if (selectedPlant == null) {
          _snack("Select a plant first to export its PDF report");
          return;
        }
        await ExportService.exportPlantReportPDF(selectedPlant!);
      } else if (action == 'import_csv') {
        final result = await ExportService.importCSV();
        _snack(result.summary);
        if (!result.cancelled) {
          setState(() {
            selectedPlant = null;
            selectedImage = null;
          });
          await loadPlants();
        }
      } else if (action == 'import_excel') {
        final result = await ExportService.importExcel();
        _snack(result.summary);
        if (!result.cancelled && result.inserted > 0) {
          setState(() {
            selectedPlant = null;
            selectedImage = null;
          });
          await loadPlants();
        }
        if (result.errors.isNotEmpty) {
          _snack(result.errors.first);
        }
      } else if (action == 'delete_all') {
        await _confirmDeleteAll();
      }
    } catch (e) {
      _snack("Operation failed: $e");
    }
  }

  // ── DELETE ALL ──
  Future<void> _confirmDeleteAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete all data?"),
        content: const Text(
          "This will permanently delete ALL plants, logs, yields, schedules "
          "and images. This cannot be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete everything"),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await DatabaseHelper.instance.deleteAllData();
      setState(() {
        selectedPlant = null;
        selectedImage = null;
      });
      await loadPlants();
      _snack("All data deleted.");
    }
  }

  // ── PREVIEW PANEL ──
  Widget _buildPreviewPanel() {
    if (selectedPlant == null) {
      return const Center(child: Text("Select a plant to view details"));
    }

    final plantId = selectedPlant!['id'];

    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _getPlantImages(plantId),
      builder: (context, snapshot) {
        final images = snapshot.data ?? [];

        final bottomInset = MediaQuery.of(context).padding.bottom;
        final fabClearance = bottomInset + 180.0;

        return SingleChildScrollView(
          padding: EdgeInsets.only(bottom: fabClearance),
          child: Column(
            children: [
              // ── MAIN IMAGE ──
              Container(
                margin: const EdgeInsets.all(12),
                height: 220,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: (selectedImage != null && selectedImage!.isNotEmpty)
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(File(selectedImage!),
                            fit: BoxFit.cover),
                      )
                    : const Center(child: Text("No Image Selected")),
              ),

              // ── THUMBNAIL STRIP ──
              if (images.isNotEmpty)
                SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: images.length,
                    itemBuilder: (context, index) {
                      final path = images[index]['imagePath'];
                      return GestureDetector(
                        onTap: () =>
                            setState(() => selectedImage = path),
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          width: 72,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selectedImage == path
                                  ? Colors.green
                                  : Colors.grey.shade300,
                              width: selectedImage == path ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(path),
                                fit: BoxFit.cover),
                          ),
                        ),
                      );
                    },
                  ),
                ),

              const Divider(height: 20),

              // ── ACTION BUTTONS ──
              Wrap(
                spacing: 4,
                runSpacing: 4,
                alignment: WrapAlignment.center,
                children: [
                  _actionButton(Icons.add_a_photo, "Add photo", () async {
                    final picked = await picker.pickImage(
                        source: ImageSource.gallery);
                    if (picked != null) {
                      await DatabaseHelper.instance.addPlantImage(
                        selectedPlant!['id'] as int,
                        picked.path,
                      );
                      setState(() => selectedImage = picked.path);
                    }
                  }),
                  _actionButton(Icons.agriculture, "Add yield",
                      () => _addYield(selectedPlant!)),
                  _actionButton(Icons.bar_chart, "Yield graph", () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              YieldGraphScreen(plant: selectedPlant!)),
                    );
                    if (changed == true) await loadPlants();
                  }),
                  _actionButton(Icons.timeline, "Crop Timeline", () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              CropTimelineScreen(plant: selectedPlant!)),
                    );
                  }),
                  _actionButton(Icons.list, "Logs", () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              PlantLogsScreen(plant: selectedPlant!)),
                    );
                  }),
                  _actionButton(Icons.schedule, "Schedule", () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              ScheduleScreen(plant: selectedPlant!)),
                    );
                  }),
                  _actionButton(Icons.picture_as_pdf, "Export PDF",
                      () => _handleExportImport('pdf')),
                  _actionButton(Icons.edit, "Edit",
                      () => _editPlant(selectedPlant!)),
                  _actionButton(
                      Icons.delete, "Delete",
                      () => _deletePlant(selectedPlant!['id']),
                      color: Colors.red.shade300),
                ],
              ),

              const SizedBox(height: 16),

              // ── PLANT INFO ──
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: Colors.grey.shade200),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selectedPlant!['name'] ?? '',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if ((selectedPlant!['type'] ?? '')
                          .toString()
                          .isNotEmpty)
                        Text('Type: ${selectedPlant!['type']}',
                            style: const TextStyle(color: Colors.grey)),
                      if ((selectedPlant!['description'] ?? '')
                          .toString()
                          .isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(selectedPlant!['description'],
                              style: const TextStyle(fontSize: 13)),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'Total yield: ${selectedPlant!['totalYield'] ?? 0}',
                        style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      GrowthStageBadge(
                        stage: selectedPlant!['growth_stage']?.toString(),
                        compact: false,
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _actionButton(IconData icon, String tooltip,
      VoidCallback onPressed, {Color? color}) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 24, color: color),
        ),
      ),
    );
  }

  // ── ADD YIELD ──
  Future<void> _addYield(Map<String, dynamic> plant) async {
    final controller = TextEditingController();
    final result = await showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("Add Yield — ${plant['name']}"),
        content: TextField(
          controller: controller,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
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
        'plantId':  plant['id'],
        'amount':   result,
        'dateTime': DateTime.now().toIso8601String(),
      });
      await loadPlants();
    }
  }

  // ── DELETE ──
  Future<void> _deletePlant(int id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Delete plant?"),
        content: const Text(
            "This will also delete all logs, yields and schedules for this plant."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deletePlant(id);
      setState(() {
        selectedPlant = null;
        selectedImage = null;
      });
      await loadPlants();
    }
  }

  // ── EDIT ──
  Future<void> _editPlant(Map<String, dynamic> plant) async {
    final nameCtrl = TextEditingController(text: plant['name']);
    final typeCtrl = TextEditingController(text: plant['type']);
    final descCtrl = TextEditingController(text: plant['description']);

    String? editStage = plant['growth_stage']?.toString();
    if (editStage != null && editStage.trim().isEmpty) editStage = null;

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Edit Plant"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration:
                      const InputDecoration(labelText: "Plant Name"),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: typeCtrl,
                  decoration:
                      const InputDecoration(labelText: "Type"),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descCtrl,
                  decoration:
                      const InputDecoration(labelText: "Description"),
                  maxLines: 3,
                ),
                const SizedBox(height: 20),
                const Text(
                  "Growth Stage",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                GrowthStageSelector(
                  selectedStage: editStage,
                  onStageSelected: (stage) {
                    setDialogState(() => editStage = stage);
                  },
                  allowClear: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("Cancel")),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text("Save")),
          ],
        ),
      ),
    );

    if (result == true) {
      await DatabaseHelper.instance.updatePlant(plant['id'], {
        ...plant,
        'name':         nameCtrl.text.trim(),
        'type':         typeCtrl.text.trim(),
        'description':  descCtrl.text.trim(),
        'growth_stage': editStage,
      });
      await loadPlants();
    }
  }

  // ── UI ──
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Trini Agri Assistant 🌱"),
        actions: [
          IconButton(
            icon: Icon(themeProvider.isDarkMode
                ? Icons.dark_mode
                : Icons.light_mode),
            onPressed: themeProvider.toggleTheme,
          ),
          IconButton(
            icon: const Icon(Icons.schedule),
            tooltip: "All schedules",
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AllSchedulesScreen())),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: "Export / Import",
            onSelected: _handleExportImport,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'csv',
                child: Row(children: [
                  Icon(Icons.table_chart, size: 18),
                  SizedBox(width: 10),
                  Text("Export all (CSV)"),
                ]),
              ),
              PopupMenuItem(
                value: 'pdf',
                child: Row(children: [
                  Icon(Icons.picture_as_pdf, size: 18),
                  SizedBox(width: 10),
                  Text("Export plant (PDF)"),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'import_csv',
                child: Row(children: [
                  Icon(Icons.upload_file, size: 18),
                  SizedBox(width: 10),
                  Text("Import CSV"),
                ]),
              ),
              PopupMenuItem(
                value: 'import_excel',
                child: Row(children: [
                  Icon(Icons.grid_on, size: 18),
                  SizedBox(width: 10),
                  Text("Import Excel / CSV"),
                ]),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete_all',
                child: Row(children: [
                  Icon(Icons.delete_forever, size: 18, color: Colors.red),
                  SizedBox(width: 10),
                  Text("Delete all data",
                      style: TextStyle(color: Colors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),

      body: Row(
        children: [
          // ── PLANT LIST ──
          Expanded(
            flex: 2,
            child: plants.isEmpty
                ? const Center(
                    child: Text("No plants yet.\nTap + to add one.",
                        textAlign: TextAlign.center))
                : ListView.builder(
                    itemCount: plants.length,
                    itemBuilder: (context, index) {
                      final plant      = plants[index];
                      final isSelected =
                          selectedPlant?['id'] == plant['id'];
                      final stage =
                          plant['growth_stage']?.toString();
                      final hasStage =
                          stage != null && stage.trim().isNotEmpty;

                      return GestureDetector(
                        onTap: () => setState(() {
                          selectedPlant = plant;
                          selectedImage = plant['imagePath'];
                        }),
                        child: Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          color: isSelected
                              ? Colors.green.withOpacity(0.1)
                              : null,
                          shape: isSelected
                              ? RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8),
                                  side: const BorderSide(
                                      color: Colors.green),
                                )
                              : null,
                          child: ListTile(
                            title: Text(
                              plant['name'] ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              plant['type'] ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: 72,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '${plant['totalYield'] ?? 0}',
                                      style: const TextStyle(
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (hasStage) ...[
                                    const SizedBox(width: 4),
                                    GrowthStageBadge(
                                      stage: stage,
                                      compact: true,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // ── PREVIEW PANEL ──
          Expanded(flex: 3, child: _buildPreviewPanel()),
        ],
      ),

      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: "voice",
            backgroundColor:
                _isListening ? Colors.red : Colors.green,
            onPressed:
                _isListening ? _stopListening : _startListening,
            child: Icon(_isListening ? Icons.mic : Icons.mic_none),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: "add",
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const AddPlantScreen()));
              await loadPlants();
            },
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}