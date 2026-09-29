import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'database_helper.dart';
import 'growth_stages.dart';
import 'schedule_colors.dart';

class ExportService {
  // ─────────────────────────────────────────────
  // EMOJI / NON-ASCII STRIPPER
  // ─────────────────────────────────────────────
  static String _stripEmoji(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0x20 && rune <= 0x7E) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString().trim();
  }

  static String _pdfCell(dynamic value) => _dash(_stripEmoji(_dash(value)));

  // ─────────────────────────────────────────────
  // SAFE DATE PARSER
  // ─────────────────────────────────────────────
  static DateTime _safeParseDate(dynamic raw) {
    if (raw == null) return DateTime.now();
    if (raw is DateTime) return raw;

    final s = raw.toString().trim();
    if (s.isEmpty) return DateTime.now();

    final asInt = int.tryParse(s);
    if (asInt != null) {
      return asInt > 10000000000
          ? DateTime.fromMillisecondsSinceEpoch(asInt)
          : DateTime.fromMillisecondsSinceEpoch(asInt * 1000);
    }

    try {
      return DateTime.parse(s);
    } catch (_) {}

    final fallbackFormats = [
      'yyyy-MM-dd HH:mm:ss',
      'yyyy-MM-dd HH:mm',
      'yyyy-MM-dd hh:mm a',
      'yyyy-MM-dd h:mm a',
      'yyyy-MM-dd',
      'M/d/yyyy HH:mm:ss',
      'M/d/yyyy HH:mm',
      'M/d/yyyy H:mm',
      'M/d/yyyy hh:mm a',
      'M/d/yyyy h:mm a',
      'M/d/yyyy',
      'MM/dd/yyyy HH:mm:ss',
      'MM/dd/yyyy HH:mm',
      'MM/dd/yyyy hh:mm a',
      'MM/dd/yyyy h:mm a',
      'MM/dd/yyyy',
      'd/M/yyyy HH:mm:ss',
      'd/M/yyyy HH:mm',
      'd/M/yyyy H:mm',
      'd/M/yyyy hh:mm a',
      'd/M/yyyy h:mm a',
      'd/M/yyyy',
      'dd/MM/yyyy HH:mm:ss',
      'dd/MM/yyyy HH:mm',
      'dd/MM/yyyy hh:mm a',
      'dd/MM/yyyy h:mm a',
      'dd/MM/yyyy',
      'dd-MM-yyyy HH:mm:ss',
      'dd-MM-yyyy HH:mm',
      'dd-MM-yyyy hh:mm a',
      'dd-MM-yyyy h:mm a',
      'dd-MM-yyyy',
      'd MMM yyyy HH:mm',
      'd MMM yyyy hh:mm a',
      'd MMM yyyy h:mm a',
      'd MMM yyyy',
      'MMM d, yyyy HH:mm',
      'MMM d, yyyy hh:mm a',
      'MMM d, yyyy h:mm a',
      'MMM d, yyyy',
      // ── Excel 12-hour formats (e.g. "5/14/2026 8:00:00 PM") ──
      'M/d/yyyy h:mm:ss a',
      'M/d/yyyy hh:mm:ss a',
      'MM/dd/yyyy h:mm:ss a',
      'MM/dd/yyyy hh:mm:ss a',
      'd/M/yyyy h:mm:ss a',
      'dd/MM/yyyy h:mm:ss a',
      'HH:mm',
      'H:mm',
      'hh:mm a',
      'h:mm a',
    ];

    for (final fmt in fallbackFormats) {
      try {
        return DateFormat(fmt).parseStrict(s);
      } catch (_) {}
    }

    return DateTime.now();
  }

  // ─────────────────────────────────────────────
  // DATE FORMATTERS
  // ─────────────────────────────────────────────

  /// Canonical ISO string used in both DB and CSV.
  /// Format: yyyy-MM-dd HH:mm:ss
  /// Using this consistently on export prevents Excel from silently
  /// reformatting the cell to M/d/yyyy and stripping the time component,
  /// which would cause the schedule time to be lost on re-import.
  static String _normalizeDate(dynamic raw) {
    final dt = _safeParseDate(raw);
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dt);
  }

  static String? _normalizeDateOrNull(dynamic raw) {
    if (raw == null) return null;
    final s = raw.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return _normalizeDate(s);
  }

  static String _displayDate(dynamic raw) {
    if (raw == null) return '-';
    final s = raw.toString().trim();
    if (s.isEmpty || s == 'null') return '-';
    try {
      return DateFormat('yyyy-MM-dd').format(_safeParseDate(s));
    } catch (_) {
      return s;
    }
  }

  static String _displayDateTime12h(dynamic raw) {
    if (raw == null) return '-';
    final s = raw.toString().trim();
    if (s.isEmpty || s == 'null') return '-';
    try {
      return DateFormat('yyyy-MM-dd  h:mm a').format(_safeParseDate(s));
    } catch (_) {
      return s;
    }
  }

  static String _dash(dynamic value) {
    if (value == null) return '-';
    final s = value.toString().trim();
    return s.isEmpty || s == 'null' ? '-' : s;
  }

  // ─────────────────────────────────────────────
  // PDF EXPORT  (single plant)
  // ─────────────────────────────────────────────
  static Future<void> exportPlantReportPDF(Map<String, dynamic> plant) async {
    final plantId   = plant['id'] as int;
    final plantName = plant['name'] ?? 'Plant';

    final logs           = await DatabaseHelper.instance.getPlantLogs(plantId);
    final yields         = await DatabaseHelper.instance.getYieldLogs(plantId);
    final schedules      = await DatabaseHelper.instance.getSchedulesWithPlant();
    final plantSchedules = schedules.where((s) => s['plantId'] == plantId).toList();
    final cropCycles     = await DatabaseHelper.instance.getCropCycles(plantId);
    final totalYield     = await DatabaseHelper.instance.getPlantTotalYield(plantId);

    final growthStage = plant['growth_stage']?.toString();
    final stageLabel  = getGrowthStageLabel(growthStage);
    final hasStage    = growthStage != null && growthStage.trim().isNotEmpty;

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (ctx) => [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    _stripEmoji(plantName.toString()),
                    style: pw.TextStyle(
                        fontSize: 24, fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text('Type: ${_stripEmoji(_dash(plant['type']))}'),
                  if (hasStage)
                    pw.Text(
                      'Growth Stage: $stageLabel',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  pw.Text(
                    'Generated: ${DateFormat('yyyy-MM-dd  h:mm a').format(DateTime.now())}',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ],
              ),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: const pw.BoxDecoration(
                  color: PdfColors.green100,
                  borderRadius:
                      pw.BorderRadius.all(pw.Radius.circular(6)),
                ),
                child: pw.Text(
                  'Total yield: ${_dash(totalYield)}',
                  style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.green800),
                ),
              ),
            ],
          ),

          pw.SizedBox(height: 12),
          pw.Divider(),

          if ((plant['description'] ?? '').toString().isNotEmpty) ...[
            pw.Text('Description',
                style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold, fontSize: 14)),
            pw.Text(_stripEmoji(plant['description'].toString())),
            pw.SizedBox(height: 12),
          ],

          _pdfSection(
            'Crop Timeline',
            cropCycles.isEmpty
                ? null
                : [
                    _pdfTable(
                      ['Cycle', 'Sow', 'Transplant', 'Flower', 'Harvest', 'End'],
                      cropCycles.map((c) {
                        return <String>[
                          _pdfCell(c['name']),
                          _pdfCell(_displayDate(c['sow_date'])),
                          _pdfCell(_displayDate(c['transplant_date'])),
                          _pdfCell(_displayDate(c['first_flower_date'])),
                          _pdfCell(_displayDate(c['first_harvest_date'])),
                          _pdfCell(_displayDate(c['harvest_end_date'])),
                        ];
                      }).toList(),
                      columnWidths: {
                        0: const pw.FlexColumnWidth(1.4),
                        1: const pw.FlexColumnWidth(1.0),
                        2: const pw.FlexColumnWidth(1.1),
                        3: const pw.FlexColumnWidth(1.0),
                        4: const pw.FlexColumnWidth(1.0),
                        5: const pw.FlexColumnWidth(1.0),
                      },
                    ),
                  ],
          ),

          _pdfSection(
            'Yield Log',
            yields.isEmpty
                ? null
                : [
                    _pdfTable(
                      ['Date', 'Amount'],
                      yields.map((y) {
                        final dt = _safeParseDate(y['dateTime']);
                        return [
                          DateFormat('yyyy-MM-dd HH:mm').format(dt),
                          _pdfCell(y['amount']),
                        ];
                      }).toList(),
                    ),
                  ],
          ),

          _pdfSection(
            'Activity Logs',
            logs.isEmpty
                ? null
                : [
                    _pdfTable(
                      ['Type', 'Date', 'Severity', 'Notes'],
                      logs.map((l) {
                        final dt    = _safeParseDate(l['dateTime']);
                        final notes = _pdfCell(l['notes']);
                        return <String>[
                          _pdfCell(l['type']),
                          DateFormat('yyyy-MM-dd').format(dt),
                          _pdfCell(l['severity']),
                          notes.length > 40
                              ? '${notes.substring(0, 40)}...'
                              : notes,
                        ];
                      }).toList(),
                    ),
                  ],
          ),

          _pdfSection(
            'Schedules',
            plantSchedules.isEmpty
                ? null
                : [
                    _pdfTable(
                      ['Type', 'Date & Time', 'Repeat', 'Interval'],
                      plantSchedules.map((s) {
                        // FIX 3: toLowerCase() so 'Daily'/'Weekly' from a
                        // re-imported CSV still matches 'daily'/'weekly'
                        final repeatType =
                            s['repeatType']?.toString().toLowerCase() ?? 'none';
                        final repeatInterval =
                            s['repeatInterval']?.toString() ?? '1';

                        String intervalDisplay = '-';
                        if (repeatType != 'none') {
                          final unit =
                              repeatType == 'daily' ? 'day(s)' : 'week(s)';
                          intervalDisplay = 'Every $repeatInterval $unit';
                        }

                        return <String>[
                          _pdfCell(getScheduleLabel(s['type']?.toString())),
                          _pdfCell(_displayDateTime12h(s['dateTime'])),
                          _pdfCell(repeatType == 'none' ? '-' : repeatType),
                          _pdfCell(intervalDisplay),
                        ];
                      }).toList(),
                      columnWidths: {
                        0: const pw.FlexColumnWidth(1.6),
                        1: const pw.FlexColumnWidth(1.9),
                        2: const pw.FlexColumnWidth(0.9),
                        3: const pw.FlexColumnWidth(1.1),
                      },
                    ),
                  ],
          ),
        ],
      ),
    );

    await _saveAndShare(
        () async => pdf.save(),
        '${_stripEmoji(plantName.toString())}_report.pdf');
  }

  // ─────────────────────────────────────────────
  // CSV EXPORT  (full database)
  //
  // All dateTime fields are written using _normalizeDate() which always
  // produces 'yyyy-MM-dd HH:mm:ss'. This ISO format is treated as plain
  // text by Excel so it cannot silently reformat the cell to 'M/d/yyyy',
  // which strips the time and causes wrong dates on re-import.
  // ─────────────────────────────────────────────
  static Future<void> exportAllCSV() async {
    final plants = await DatabaseHelper.instance.getPlants();
    final buffer = StringBuffer();

    // ── PLANTS ──
    buffer.writeln('=== PLANTS ===');
    final plantRows = [
      ['ID', 'Name', 'Type', 'Description', 'GrowthStage', 'GrowthStageLabel'],
      ...plants.map((p) {
        final stage = p['growth_stage']?.toString() ?? '';
        return [
          p['id'].toString(),
          p['name']        ?? '',
          p['type']        ?? '',
          p['description'] ?? '',
          stage,
          getGrowthStageLabel(stage.isEmpty ? null : stage),
        ];
      }),
    ];
    buffer.write(const ListToCsvConverter().convert(plantRows));

    // ── LOGS ──
    buffer.writeln('\n\n=== LOGS ===');
    final logRows = [
      ['PlantID', 'PlantName', 'Type', 'Date', 'Severity', 'Notes']
    ];
    for (final plant in plants) {
      final logs =
          await DatabaseHelper.instance.getPlantLogs(plant['id'] as int);
      for (final l in logs) {
        logRows.add([
          plant['id'].toString(),
          plant['name']  ?? '',
          l['type']      ?? '',
          _normalizeDate(l['dateTime']),
          l['severity']  ?? '',
          l['notes']     ?? '',
        ]);
      }
    }
    buffer.write(const ListToCsvConverter().convert(logRows));

    // ── YIELDS ──
    buffer.writeln('\n\n=== YIELDS ===');
    final yieldRows = [
      ['PlantID', 'PlantName', 'Amount', 'Date']
    ];
    for (final plant in plants) {
      final yields =
          await DatabaseHelper.instance.getYieldLogs(plant['id'] as int);
      for (final y in yields) {
        yieldRows.add([
          plant['id'].toString(),
          plant['name'] ?? '',
          y['amount'].toString(),
          _normalizeDate(y['dateTime']),
        ]);
      }
    }
    buffer.write(const ListToCsvConverter().convert(yieldRows));

    // ── SCHEDULES ──
    buffer.writeln('\n\n=== SCHEDULES ===');
    final scheduleRows = [
      [
        'PlantID', 'PlantName', 'Type', 'TypeLabel',
        'DateTime', 'RepeatType', 'RepeatInterval',
      ]
    ];
    final allSchedules = await DatabaseHelper.instance.getSchedulesWithPlant();
    for (final s in allSchedules) {
      // FIX 1: isWeatherBased column removed — header and data now both
      // have 7 columns, eliminating the previous 7-header / 8-value mismatch.
      scheduleRows.add([
        s['plantId']?.toString()   ?? '',
        s['plantName']?.toString() ?? '',
        s['type']?.toString()      ?? '',
        getScheduleLabel(s['type']?.toString()),
        _normalizeDate(s['dateTime']),
        s['repeatType']?.toString()     ?? 'none',
        s['repeatInterval']?.toString() ?? '1',
      ]);
    }
    buffer.write(const ListToCsvConverter().convert(scheduleRows));

    // ── CROP CYCLES ──
    buffer.writeln('\n\n=== CROP CYCLES ===');
    final cycleRows = [
      [
        'PlantID', 'PlantName', 'CycleName',
        'SowDate', 'TransplantDate', 'FirstFlowerDate',
        'FirstHarvestDate', 'HarvestEndDate',
      ]
    ];
    for (final plant in plants) {
      final cycles =
          await DatabaseHelper.instance.getCropCycles(plant['id'] as int);
      for (final c in cycles) {
        cycleRows.add([
          plant['id'].toString(),
          plant['name'] ?? '',
          c['name']                        ?? '',
          c['sow_date']           != null ? _normalizeDate(c['sow_date'])           : '',
          c['transplant_date']    != null ? _normalizeDate(c['transplant_date'])    : '',
          c['first_flower_date']  != null ? _normalizeDate(c['first_flower_date'])  : '',
          c['first_harvest_date'] != null ? _normalizeDate(c['first_harvest_date']) : '',
          c['harvest_end_date']   != null ? _normalizeDate(c['harvest_end_date'])   : '',
        ]);
      }
    }
    buffer.write(const ListToCsvConverter().convert(cycleRows));

    final dir  = await getApplicationDocumentsDirectory();
    final file = File(
        '${dir.path}/agri_export_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv');
    await file.writeAsString(buffer.toString());
    await Share.shareXFiles([XFile(file.path)]);
  }

  // ─────────────────────────────────────────────
  // IMPORT CSV
  // ─────────────────────────────────────────────
  static Future<ImportResult> importCSV() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx'],
    );

    if (result == null) return ImportResult.cancelled();

    final file    = File(result.files.single.path!);
    final content = await file.readAsString();

    return _parseCSV(content);
  }

  static Future<ImportResult> importExcel() async {
    return importCSV();
  }

  // ─────────────────────────────────────────────
  // CORE IMPORT LOGIC
  // ─────────────────────────────────────────────
  static Future<ImportResult> _parseCSV(String content) async {
    int inserted = 0;
    int skipped  = 0;
    final errors = <String>[];

    final sections = _splitSections(content);

    final existingPlants = await DatabaseHelper.instance.getPlants();

    final plantById = <int, Map<String, dynamic>>{
      for (var p in existingPlants) p['id'] as int: p
    };
    final plantByName = <String, Map<String, dynamic>>{
      for (var p in existingPlants)
        (p['name'] ?? '').toString().toLowerCase(): p
    };

    final exportedIdToDbId = <int, int>{};

    // ───────── PLANTS ─────────
    final plantSection = sections['PLANTS'];
    if (plantSection != null && plantSection.length > 1) {
      for (int i = 1; i < plantSection.length; i++) {
        final row = plantSection[i];
        if (row.length < 4) continue;

        final exportedId  = int.tryParse(row[0].toString().trim());
        final name        = row[1].toString().trim();
        final type        = row[2].toString().trim();
        final description = row[3].toString().trim();
        final growthStage = row.length > 4 ? row[4].toString().trim() : '';

        if (name.isEmpty) continue;

        Map<String, dynamic>? existing;
        if (exportedId != null && plantById.containsKey(exportedId)) {
          existing = plantById[exportedId];
        } else {
          existing = plantByName[name.toLowerCase()];
        }

        final plantData = <String, dynamic>{
          'name':        name,
          'type':        type,
          'description': description,
          if (growthStage.isNotEmpty) 'growth_stage': growthStage,
        };

        if (existing != null) {
          await DatabaseHelper.instance.updatePlant(
              existing['id'] as int, plantData);
          if (exportedId != null) {
            exportedIdToDbId[exportedId] = existing['id'] as int;
          }
          skipped++;
        } else {
          final newId =
              await DatabaseHelper.instance.insertPlant(plantData);
          if (exportedId != null) exportedIdToDbId[exportedId] = newId;
          inserted++;
        }
      }
    }

    final refreshedPlants = await DatabaseHelper.instance.getPlants();
    final refreshedByName = <String, Map<String, dynamic>>{
      for (var p in refreshedPlants)
        (p['name'] ?? '').toString().toLowerCase(): p
    };

    int? resolvePlantId(String exportedIdStr, String nameStr) {
      final exportedId = int.tryParse(exportedIdStr.trim());
      if (exportedId != null && exportedIdToDbId.containsKey(exportedId)) {
        return exportedIdToDbId[exportedId];
      }
      return refreshedByName[nameStr.trim().toLowerCase()]?['id'] as int?;
    }

    // ───────── LOGS ─────────
    final logSection = sections['LOGS'];
    if (logSection != null && logSection.length > 1) {
      for (int i = 1; i < logSection.length; i++) {
        final row = logSection[i];
        if (row.every((cell) => cell.toString().trim().isEmpty)) continue;

        int? plantDbId;
        String type, rawDate, severity, notes;

        if (row.length >= 6) {
          plantDbId = resolvePlantId(row[0].toString(), row[1].toString());
          type      = row[2].toString();
          rawDate   = row[3].toString();
          severity  = row[4].toString();
          notes     = row[5].toString();
        } else if (row.length >= 5) {
          plantDbId = refreshedByName[row[0].toString().trim().toLowerCase()]
              ?['id'] as int?;
          type      = row[1].toString();
          rawDate   = row[2].toString();
          severity  = row[3].toString();
          notes     = row[4].toString();
        } else {
          errors.add('Log row $i has too few columns, skipped.');
          skipped++;
          continue;
        }

        if (plantDbId == null) {
          errors.add('Log row $i: plant not found, skipped.');
          skipped++;
          continue;
        }

        final normalizedDate = _normalizeDate(rawDate);
        final isDup = await DatabaseHelper.instance
            .logExists(plantDbId, type, normalizedDate);
        if (isDup) { skipped++; continue; }

        await DatabaseHelper.instance.insertLog({
          'plantId':  plantDbId,
          'type':     type,
          'dateTime': normalizedDate,
          'severity': severity,
          'notes':    notes,
        });
        inserted++;
      }
    }

    // ───────── YIELDS ─────────
    final yieldSection = sections['YIELDS'];
    if (yieldSection != null && yieldSection.length > 1) {
      for (int i = 1; i < yieldSection.length; i++) {
        final row = yieldSection[i];
        if (row.every((cell) => cell.toString().trim().isEmpty)) continue;

        int? plantDbId;
        String amountStr, rawDate;

        if (row.length >= 4) {
          plantDbId = resolvePlantId(row[0].toString(), row[1].toString());
          amountStr = row[2].toString();
          rawDate   = row[3].toString();
        } else if (row.length >= 3) {
          plantDbId = refreshedByName[row[0].toString().trim().toLowerCase()]
              ?['id'] as int?;
          amountStr = row[1].toString();
          rawDate   = row[2].toString();
        } else {
          errors.add('Yield row $i has too few columns, skipped.');
          skipped++;
          continue;
        }

        if (plantDbId == null) {
          errors.add('Yield row $i: plant not found, skipped.');
          skipped++;
          continue;
        }

        final normalizedDate = _normalizeDate(rawDate);
        final isDup = await DatabaseHelper.instance
            .yieldExists(plantDbId, normalizedDate);
        if (isDup) { skipped++; continue; }

        final amountDouble = double.tryParse(amountStr) ?? 0.0;
        await DatabaseHelper.instance.insertYield({
          'plantId':  plantDbId,
          'amount':   amountDouble.round(),
          'dateTime': normalizedDate,
        });
        inserted++;
      }
    }

    // ───────── SCHEDULES ─────────
    final scheduleSection = sections['SCHEDULES'];
    if (scheduleSection != null && scheduleSection.length > 1) {
      final existingSchedules =
          await DatabaseHelper.instance.getSchedulesWithPlant();
      final existingKeys = <String>{
        for (final s in existingSchedules)
          '${s['plantId']}|${s['type']}|${_normalizeDate(s['dateTime'])}'
      };

      for (int i = 1; i < scheduleSection.length; i++) {
        final row = scheduleSection[i];
        if (row.every((cell) => cell.toString().trim().isEmpty)) continue;

        if (row.length < 5) {
          errors.add('Schedule row $i has too few columns, skipped.');
          skipped++;
          continue;
        }

        final plantDbId =
            resolvePlantId(row[0].toString(), row[1].toString());
        if (plantDbId == null) {
          errors.add('Schedule row $i: plant not found, skipped.');
          skipped++;
          continue;
        }

        final scheduleType = row[2].toString().trim();
        final rawDateTime  = row[4].toString();
        // FIX 2: toLowerCase() normalizes Excel-capitalised values like
        // 'Daily' / 'Weekly' back to 'daily' / 'weekly' before storing,
        // so _loadSchedules() equality checks ('daily', 'weekly') always
        // match and repeating schedules expand correctly after re-import.
        final repeatType =
            row.length > 5 ? row[5].toString().trim().toLowerCase() : 'none';
        final repeatInterval =
            row.length > 6 ? int.tryParse(row[6].toString().trim()) ?? 1 : 1;

        if (scheduleType.isEmpty) {
          errors.add('Schedule row $i: type is empty, skipped.');
          skipped++;
          continue;
        }

        final normalizedDate = _normalizeDate(rawDateTime);
        final key = '$plantDbId|$scheduleType|$normalizedDate';

        if (existingKeys.contains(key)) { skipped++; continue; }

        // FIX 2 (cont): isWeatherBased removed from insertSchedule call —
        // the feature is no longer used and the column is no longer exported.
        await DatabaseHelper.instance.insertSchedule({
          'plantId':        plantDbId,
          'type':           scheduleType,
          'dateTime':       normalizedDate,
          'repeatType':     repeatType,
          'repeatInterval': repeatInterval,
        });
        existingKeys.add(key);
        inserted++;
      }
    }

    // ───────── CROP CYCLES ─────────
    final cycleSection = sections['CROP CYCLES'];
    if (cycleSection != null && cycleSection.length > 1) {
      for (int i = 1; i < cycleSection.length; i++) {
        final row = cycleSection[i];
        if (row.every((cell) => cell.toString().trim().isEmpty)) continue;

        if (row.length < 3) {
          errors.add('Crop cycle row $i has too few columns, skipped.');
          skipped++;
          continue;
        }

        final plantDbId =
            resolvePlantId(row[0].toString(), row[1].toString());
        if (plantDbId == null) {
          errors.add('Crop cycle row $i: plant not found, skipped.');
          skipped++;
          continue;
        }

        final cycleName = row[2].toString().trim();
        if (cycleName.isEmpty) {
          errors.add('Crop cycle row $i: cycle name is empty, skipped.');
          skipped++;
          continue;
        }

        final sowDate          = row.length > 3 ? _normalizeDateOrNull(row[3]) : null;
        final transplantDate   = row.length > 4 ? _normalizeDateOrNull(row[4]) : null;
        final firstFlowerDate  = row.length > 5 ? _normalizeDateOrNull(row[5]) : null;
        final firstHarvestDate = row.length > 6 ? _normalizeDateOrNull(row[6]) : null;
        final harvestEndDate   = row.length > 7 ? _normalizeDateOrNull(row[7]) : null;

        final existingCycles =
            await DatabaseHelper.instance.getCropCycles(plantDbId);
        final existingCycle = existingCycles.firstWhere(
          (c) =>
              (c['name'] ?? '').toString().trim().toLowerCase() ==
              cycleName.toLowerCase(),
          orElse: () => {},
        );

        final milestones = <String, String?>{
          if (sowDate          != null) 'sow_date':           sowDate,
          if (transplantDate   != null) 'transplant_date':    transplantDate,
          if (firstFlowerDate  != null) 'first_flower_date':  firstFlowerDate,
          if (firstHarvestDate != null) 'first_harvest_date': firstHarvestDate,
          if (harvestEndDate   != null) 'harvest_end_date':   harvestEndDate,
        };

        if (existingCycle.isNotEmpty) {
          final cycleId = existingCycle['id'] as int;
          if (milestones.isNotEmpty) {
            await DatabaseHelper.instance
                .updateCropCycleMilestones(cycleId, milestones);
          }
          if (existingCycle['name'].toString() != cycleName) {
            await DatabaseHelper.instance.renameCropCycle(cycleId, cycleName);
          }
          skipped++;
        } else {
          final cycleId = await DatabaseHelper.instance
              .createCropCycle(plantDbId, cycleName);
          if (milestones.isNotEmpty) {
            await DatabaseHelper.instance
                .updateCropCycleMilestones(cycleId, milestones);
          }
          inserted++;
        }
      }
    }

    return ImportResult(
      cancelled: false,
      inserted:  inserted,
      skipped:   skipped,
      errors:    errors,
    );
  }

  // ─────────────────────────────────────────────
  // SECTION PARSER
  // ─────────────────────────────────────────────
  static Map<String, List<List<String>>> _splitSections(String content) {
    final result = <String, List<List<String>>>{};
    String? section;
    final buffer = StringBuffer();

    for (final line in content.split('\n')) {
      final match = RegExp(r'^===\s*(.+?)\s*===').firstMatch(line.trim());
      if (match != null) {
        if (section != null) {
          final parsed =
              const CsvToListConverter().convert(buffer.toString().trim());
          result[section] =
              parsed.map((r) => r.map((c) => c.toString()).toList()).toList();
          buffer.clear();
        }
        section = match.group(1)!.trim().toUpperCase();
      } else if (section != null) {
        buffer.writeln(line);
      }
    }

    if (section != null && buffer.isNotEmpty) {
      final parsed =
          const CsvToListConverter().convert(buffer.toString().trim());
      result[section] =
          parsed.map((r) => r.map((c) => c.toString()).toList()).toList();
    }

    return result;
  }

  // ─────────────────────────────────────────────
  // PDF HELPERS
  // ─────────────────────────────────────────────
  static pw.Widget _pdfSection(String title, List<pw.Widget>? children) {
    return pw.Column(children: [
      pw.SizedBox(height: 12),
      pw.Text(title,
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 14)),
      pw.SizedBox(height: 4),
      if (children != null) ...children else pw.Text('No data'),
      pw.SizedBox(height: 8),
    ]);
  }

  static pw.Widget _pdfTable(
    List<String> headers,
    List<List<String>> rows, {
    Map<int, pw.TableColumnWidth>? columnWidths,
  }) {
    return pw.Table(
      border: pw.TableBorder.all(),
      columnWidths: columnWidths,
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: headers
              .map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Text(h,
                        style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold, fontSize: 8)),
                  ))
              .toList(),
        ),
        ...rows.map(
          (r) => pw.TableRow(
            children: r
                .map((c) => pw.Padding(
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(c,
                          style: const pw.TextStyle(fontSize: 8)),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  static Future<void> _saveAndShare(
      Future<List<int>> Function() gen, String name) async {
    final bytes = await gen();
    final dir   = await getApplicationDocumentsDirectory();
    final file  = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)]);
  }
}

// ─────────────────────────────────────────────
// RESULT MODEL
// ─────────────────────────────────────────────
class ImportResult {
  final bool cancelled;
  final int inserted;
  final int skipped;
  final List<String> errors;

  ImportResult({
    required this.cancelled,
    required this.inserted,
    required this.skipped,
    required this.errors,
  });

  factory ImportResult.cancelled() =>
      ImportResult(cancelled: true, inserted: 0, skipped: 0, errors: []);

  String get summary {
    if (cancelled) return 'Import cancelled.';
    if (errors.isNotEmpty && inserted == 0) {
      return 'Import failed: ${errors.first}';
    }
    final parts = <String>[];
    if (inserted > 0) parts.add('$inserted imported');
    if (skipped  > 0) parts.add('$skipped skipped/updated');
    if (errors.isNotEmpty) parts.add('${errors.length} error(s)');
    return parts.isEmpty ? 'Nothing to import.' : parts.join(', ');
  }
}