import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('plants.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path   = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 11,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  // ════════════════════════════════════════════
  // CREATE DATABASE  (fresh install)
  // ════════════════════════════════════════════
  Future _createDB(Database db, int version) async {
    await db.execute('''
CREATE TABLE plants (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name         TEXT,
  type         TEXT,
  description  TEXT,
  groupName    TEXT,
  imagePath    TEXT,
  growth_stage TEXT
)
''');

    await db.execute('''
CREATE TABLE schedules (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId            INTEGER,
  type               TEXT,
  dateTime           TEXT,
  repeatType         TEXT    DEFAULT 'none',
  repeatInterval     INTEGER DEFAULT 1,
  isWeatherBased     INTEGER DEFAULT 0,
  sow_date           TEXT,
  transplant_date    TEXT,
  first_flower_date  TEXT,
  first_harvest_date TEXT,
  harvest_end_date   TEXT
)
''');

    await db.execute('''
CREATE TABLE logs (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId   INTEGER,
  type      TEXT,
  dateTime  TEXT,
  notes     TEXT,
  severity  TEXT
)
''');

    await db.execute('''
CREATE TABLE yield_logs (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId   INTEGER,
  amount    REAL,
  dateTime  TEXT
)
''');

    await db.execute('''
CREATE TABLE crop_cycles (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId            INTEGER NOT NULL,
  name               TEXT NOT NULL,
  sow_date           TEXT,
  transplant_date    TEXT,
  first_flower_date  TEXT,
  first_harvest_date TEXT,
  harvest_end_date   TEXT
)
''');

    await db.execute('''
CREATE TABLE plant_types (
  id                      INTEGER PRIMARY KEY AUTOINCREMENT,
  name                    TEXT NOT NULL UNIQUE,
  default_maturation_days INTEGER
)
''');

    await _seedPlantTypes(db);

    await db.execute('''
CREATE TABLE plant_images (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId     INTEGER,
  imagePath   TEXT,
  createdAt   TEXT
)
''');

    // v11: schedule completion tracking
    await db.execute('''
CREATE TABLE schedule_completions (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scheduleId   INTEGER NOT NULL,
  plantId      INTEGER NOT NULL,
  type         TEXT    NOT NULL,
  completedAt  TEXT    NOT NULL,
  status       TEXT    NOT NULL DEFAULT 'done'
)
''');
  }

  // ════════════════════════════════════════════
  // SEED PLANT TYPES
  // ════════════════════════════════════════════
  Future<void> _seedPlantTypes(DatabaseExecutor db) async {
    const types = [
      ('Vegetable',   60),
      ('Fruit',       90),
      ('Root Crop',  100),
      ('Legume',      65),
      ('Herb',        40),
      ('Spice',      120),
      ('Citrus',     180),
      ('Tree Crop',  365),
      ('Ornamental',  90),
      ('Cover Crop',  55),
      ('Other',      null),
    ];
    for (final (name, mat) in types) {
      await db.rawInsert(
        'INSERT OR IGNORE INTO plant_types (name, default_maturation_days) VALUES (?, ?)',
        [name, mat],
      );
    }
  }

  // ════════════════════════════════════════════
  // UPGRADE  (existing installs)
  // ════════════════════════════════════════════
  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          "ALTER TABLE schedules ADD COLUMN repeatType TEXT DEFAULT 'none'");
      await db.execute(
          "ALTER TABLE schedules ADD COLUMN repeatInterval INTEGER DEFAULT 1");
    }

    if (oldVersion < 3) {
      await db.execute("ALTER TABLE logs ADD COLUMN severity TEXT");
      await db.execute('''
CREATE TABLE IF NOT EXISTS yield_logs (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId   INTEGER,
  amount    REAL,
  dateTime  TEXT
)
''');
    }

    if (oldVersion < 4) {
      try {
        await db.execute("ALTER TABLE plants ADD COLUMN imagePath TEXT");
      } catch (_) {}
    }

    if (oldVersion < 5) {
      try {
        await db.execute(
            "ALTER TABLE schedules ADD COLUMN isWeatherBased INTEGER DEFAULT 0");
      } catch (_) {}
    }

    if (oldVersion < 6) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS plant_images (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId     INTEGER,
  imagePath   TEXT,
  createdAt   TEXT
)
''');
    }

    // ── v7: migrate yield_logs.amount from INTEGER → REAL ──
    if (oldVersion < 7) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS yield_logs_new (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId   INTEGER,
  amount    REAL,
  dateTime  TEXT
)
''');
      await db.execute('''
INSERT INTO yield_logs_new (id, plantId, amount, dateTime)
SELECT id, plantId, CAST(amount AS REAL), dateTime FROM yield_logs
''');
      await db.execute('DROP TABLE yield_logs');
      await db.execute('ALTER TABLE yield_logs_new RENAME TO yield_logs');

      final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM plant_types'));
      if (count == null || count == 0) {
        await _seedPlantTypes(db);
      }
    }

    // ── v8: crop timeline milestone columns + maturation defaults ──
    if (oldVersion < 8) {
      for (final col in [
        'sow_date', 'transplant_date', 'first_flower_date',
        'first_harvest_date', 'harvest_end_date',
      ]) {
        try {
          await db.execute('ALTER TABLE schedules ADD COLUMN $col TEXT');
        } catch (_) {}
      }

      try {
        await db.execute(
            'ALTER TABLE plant_types ADD COLUMN default_maturation_days INTEGER');
      } catch (_) {}

      const matDefaults = {
        'Vegetable':   60,
        'Fruit':       90,
        'Root Crop':  100,
        'Legume':      65,
        'Herb':        40,
        'Spice':      120,
        'Citrus':     180,
        'Tree Crop':  365,
        'Ornamental':  90,
        'Cover Crop':  55,
      };
      for (final e in matDefaults.entries) {
        await db.rawUpdate(
          'UPDATE plant_types SET default_maturation_days = ? WHERE name = ?',
          [e.value, e.key],
        );
      }

      final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM plant_types'));
      if (count == null || count == 0) {
        await _seedPlantTypes(db);
      }
    }

    // ── v9: dedicated crop_cycles table ──
    if (oldVersion < 9) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS crop_cycles (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  plantId            INTEGER NOT NULL,
  name               TEXT NOT NULL,
  sow_date           TEXT,
  transplant_date    TEXT,
  first_flower_date  TEXT,
  first_harvest_date TEXT,
  harvest_end_date   TEXT
)
''');
    }

    // ── v10: growth_stage column on plants ──
    if (oldVersion < 10) {
      try {
        await db.execute(
            'ALTER TABLE plants ADD COLUMN growth_stage TEXT');
      } catch (_) {}
    }

    // ── v11: schedule_completions table ──
    if (oldVersion < 11) {
      await db.execute('''
CREATE TABLE IF NOT EXISTS schedule_completions (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  scheduleId   INTEGER NOT NULL,
  plantId      INTEGER NOT NULL,
  type         TEXT    NOT NULL,
  completedAt  TEXT    NOT NULL,
  status       TEXT    NOT NULL DEFAULT 'done'
)
''');
    }
  }

  // ════════════════════════════════════════════
  // INTERNAL: safe ISO date normalizer
  // ════════════════════════════════════════════
  static String _toIso(String raw) {
    final s = raw.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) return s;

    final dt = _manualParse(s);
    if (dt != null) {
      return '${dt.year.toString().padLeft(4, '0')}'
          '-${dt.month.toString().padLeft(2, '0')}'
          '-${dt.day.toString().padLeft(2, '0')}'
          ' ${dt.hour.toString().padLeft(2, '0')}'
          ':${dt.minute.toString().padLeft(2, '0')}'
          ':${dt.second.toString().padLeft(2, '0')}';
    }
    return s;
  }

  static DateTime? _manualParse(String s) {
    try { return DateTime.parse(s); } catch (_) {}

    final re = RegExp(
      r'^(\d{1,4})[/\-](\d{1,2})[/\-](\d{2,4})'
      r'(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?'
      r'(?:\s*(am|pm))?$',
      caseSensitive: false,
    );
    final m = re.firstMatch(s.trim());
    if (m == null) return null;

    int a = int.parse(m.group(1)!);
    int b = int.parse(m.group(2)!);
    int c = int.parse(m.group(3)!);
    int hour   = m.group(4) != null ? int.parse(m.group(4)!) : 0;
    int minute = m.group(5) != null ? int.parse(m.group(5)!) : 0;
    int second = m.group(6) != null ? int.parse(m.group(6)!) : 0;
    final ampm = m.group(7)?.toLowerCase();

    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;

    int year, month, day;
    if (a > 31)      { year = a; month = b; day = c; }
    else if (c > 31) { year = c; month = a; day = b; }
    else             { return null; }

    if (year < 100) year += year < 50 ? 2000 : 1900;

    try {
      return DateTime(year, month, day, hour, minute, second);
    } catch (_) {
      return null;
    }
  }

  // ════════════════════════════════════════════
  // PLANTS
  // ════════════════════════════════════════════
  Future<int> insertPlant(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('plants', row);
  }

  Future<List<Map<String, dynamic>>> getPlants() async {
    final db = await instance.database;
    final rows = await db.rawQuery('''
SELECT
  plants.*,
  IFNULL(SUM(yield_logs.amount), 0) AS totalYield
FROM plants
LEFT JOIN yield_logs ON yield_logs.plantId = plants.id
GROUP BY plants.id
ORDER BY plants.name ASC
''');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<int> getPlantTotalYield(int plantId) async {
    final db = await instance.database;
    final result = await db.rawQuery('''
SELECT IFNULL(SUM(amount), 0) AS total
FROM yield_logs
WHERE plantId = ?
''', [plantId]);
    final raw = result.first['total'];
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    return (num.tryParse(raw.toString()) ?? 0).round();
  }

  Future<int> updatePlant(int id, Map<String, dynamic> row) async {
    final db = await instance.database;
    const allowedKeys = {
      'name', 'type', 'description', 'groupName', 'imagePath', 'growth_stage',
    };
    final cleanRow = Map<String, dynamic>.fromEntries(
      row.entries.where((e) => allowedKeys.contains(e.key)),
    );
    return await db.update('plants', cleanRow,
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updatePlantGrowthStage(int plantId, String? stage) async {
    final db = await instance.database;
    return await db.update(
      'plants',
      {'growth_stage': stage},
      where: 'id = ?',
      whereArgs: [plantId],
    );
  }

  Future<int> deletePlant(int id) async {
    final db = await instance.database;
    await db.delete('yield_logs',            where: 'plantId = ?', whereArgs: [id]);
    await db.delete('logs',                  where: 'plantId = ?', whereArgs: [id]);
    await db.delete('schedules',             where: 'plantId = ?', whereArgs: [id]);
    await db.delete('schedule_completions',  where: 'plantId = ?', whereArgs: [id]);
    await db.delete('plant_images',          where: 'plantId = ?', whereArgs: [id]);
    await db.delete('crop_cycles',           where: 'plantId = ?', whereArgs: [id]);
    return await db.delete('plants',         where: 'id = ?',      whereArgs: [id]);
  }

  // ════════════════════════════════════════════
  // DELETE ALL DATA
  // ════════════════════════════════════════════
  Future<void> deleteAllData() async {
    final db = await instance.database;
    await db.delete('yield_logs');
    await db.delete('logs');
    await db.delete('schedules');
    await db.delete('schedule_completions');
    await db.delete('plant_images');
    await db.delete('crop_cycles');
    await db.delete('plants');
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM plant_types'));
    if (count == null || count == 0) {
      await _seedPlantTypes(db);
    }
  }

  // ════════════════════════════════════════════
  // YIELD
  // ════════════════════════════════════════════
  Future<int> insertYield(Map<String, dynamic> row) async {
    final db = await instance.database;
    final clean = Map<String, dynamic>.from(row);
    if (clean['dateTime'] != null) {
      clean['dateTime'] = _toIso(clean['dateTime'].toString());
    }
    if (clean['amount'] != null) {
      final parsed = double.tryParse(clean['amount'].toString());
      clean['amount'] = parsed ?? 0.0;
    }
    return await db.insert('yield_logs', clean);
  }

  Future<List<Map<String, dynamic>>> getYields(int plantId) async {
    final db = await instance.database;
    return await db.query('yield_logs',
        where: 'plantId = ?',
        whereArgs: [plantId],
        orderBy: 'dateTime DESC');
  }

  Future<List<Map<String, dynamic>>> getYieldLogs(int plantId) async {
    final db = await instance.database;
    return await db.query('yield_logs',
        where: 'plantId = ?',
        whereArgs: [plantId],
        orderBy: 'dateTime ASC');
  }

  Future<bool> yieldExists(int plantId, String dateTime) async {
    final db = await instance.database;
    final normalizedIncoming = _toIso(dateTime);
    final rows = await db.query('yield_logs',
        columns: ['dateTime'],
        where: 'plantId = ?',
        whereArgs: [plantId]);
    for (final row in rows) {
      final stored = _toIso(row['dateTime']?.toString() ?? '');
      if (stored == normalizedIncoming) return true;
    }
    return false;
  }

  Future<int> deleteYield(int id) async {
    final db = await instance.database;
    return await db.delete('yield_logs', where: 'id = ?', whereArgs: [id]);
  }

  // ════════════════════════════════════════════
  // SCHEDULES
  // ════════════════════════════════════════════
  Future<int> insertSchedule(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('schedules', {
      'plantId':        row['plantId'],
      'type':           row['type'],
      'dateTime':       row['dateTime'],
      'repeatType':     row['repeatType']     ?? 'none',
      'repeatInterval': row['repeatInterval'] ?? 1,
      'isWeatherBased': row['isWeatherBased'] ?? 0,
    });
  }

  Future<List<Map<String, dynamic>>> getSchedulesWithPlant() async {
    final db = await instance.database;
    return await db.rawQuery('''
SELECT
  schedules.id,
  schedules.plantId,
  schedules.type,
  schedules.dateTime,
  schedules.repeatType,
  schedules.repeatInterval,
  schedules.isWeatherBased,
  schedules.sow_date,
  schedules.transplant_date,
  schedules.first_flower_date,
  schedules.first_harvest_date,
  schedules.harvest_end_date,
  plants.name AS plantName
FROM schedules
LEFT JOIN plants ON schedules.plantId = plants.id
ORDER BY schedules.dateTime ASC
''');
  }

  Future<List<Map<String, dynamic>>> getSchedulesForPlant(int plantId) async {
    final db = await instance.database;
    return await db.query(
      'schedules',
      where: 'plantId = ?',
      whereArgs: [plantId],
      orderBy: 'dateTime ASC',
    );
  }

  Future<int> updateSchedule(int id, Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.update(
      'schedules',
      {
        'type':           row['type'],
        'dateTime':       row['dateTime'],
        'repeatType':     row['repeatType']     ?? 'none',
        'repeatInterval': row['repeatInterval'] ?? 1,
        'isWeatherBased': row['isWeatherBased'] ?? 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteSchedule(int id) async {
    final db = await instance.database;
    // Also remove any completions recorded for this schedule
    await db.delete('schedule_completions',
        where: 'scheduleId = ?', whereArgs: [id]);
    return await db.delete('schedules', where: 'id = ?', whereArgs: [id]);
  }

  // ════════════════════════════════════════════
  // SCHEDULE COMPLETIONS
  // ════════════════════════════════════════════

  /// Records a completion or skip for a schedule entry.
  /// [status] must be either 'done' or 'skipped'.
  Future<int> insertScheduleCompletion({
    required int scheduleId,
    required int plantId,
    required String type,
    required String status, // 'done' | 'skipped'
    DateTime? at,
  }) async {
    final db = await instance.database;
    return await db.insert('schedule_completions', {
      'scheduleId':  scheduleId,
      'plantId':     plantId,
      'type':        type,
      'completedAt': (at ?? DateTime.now()).toIso8601String(),
      'status':      status,
    });
  }

  /// Returns all completions for a plant, newest first.
  Future<List<Map<String, dynamic>>> getScheduleCompletions(
      int plantId) async {
    final db = await instance.database;
    return await db.query(
      'schedule_completions',
      where: 'plantId = ?',
      whereArgs: [plantId],
      orderBy: 'completedAt DESC',
    );
  }

  /// Returns only 'done' completions for a plant — used by Care Impact chart.
  Future<List<Map<String, dynamic>>> getDoneCompletions(int plantId) async {
    final db = await instance.database;
    return await db.query(
      'schedule_completions',
      where: 'plantId = ? AND status = ?',
      whereArgs: [plantId, 'done'],
      orderBy: 'completedAt ASC',
    );
  }

  /// Checks whether a specific schedule already has a completion recorded
  /// on the same calendar day (prevents double-tapping).
  Future<bool> completionExistsForDay(
      int scheduleId, DateTime day) async {
    final db = await instance.database;
    final dayStr =
        '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final rows = await db.rawQuery('''
SELECT id FROM schedule_completions
WHERE scheduleId = ?
  AND completedAt LIKE ?
LIMIT 1
''', [scheduleId, '$dayStr%']);
    return rows.isNotEmpty;
  }

  /// Removes all completions tied to a schedule (called when schedule deleted).
  Future<void> deleteScheduleCompletions(int scheduleId) async {
    final db = await instance.database;
    await db.delete('schedule_completions',
        where: 'scheduleId = ?', whereArgs: [scheduleId]);
  }

  // ════════════════════════════════════════════
  // LOGS
  // ════════════════════════════════════════════
  Future<int> insertLog(Map<String, dynamic> row) async {
    final db = await instance.database;
    final clean = Map<String, dynamic>.from(row);
    if (clean['dateTime'] != null) {
      clean['dateTime'] = _toIso(clean['dateTime'].toString());
    }
    return await db.insert('logs', clean);
  }

  Future<List<Map<String, dynamic>>> getPlantLogs(int plantId) async {
    final db = await instance.database;
    return await db.query('logs',
        where: 'plantId = ?',
        whereArgs: [plantId],
        orderBy: 'dateTime DESC');
  }

  Future<List<Map<String, dynamic>>> getLogs() async {
    final db = await instance.database;
    return await db.query('logs');
  }

  Future<bool> logExists(int plantId, String type, String dateTime) async {
    final db = await instance.database;
    final normalizedIncoming = _toIso(dateTime);
    final rows = await db.query('logs',
        columns: ['type', 'dateTime'],
        where: 'plantId = ? AND type = ?',
        whereArgs: [plantId, type]);
    for (final row in rows) {
      final stored = _toIso(row['dateTime']?.toString() ?? '');
      if (stored == normalizedIncoming) return true;
    }
    return false;
  }

  Future<int> deleteLog(int id) async {
    final db = await instance.database;
    return await db.delete('logs', where: 'id = ?', whereArgs: [id]);
  }

  // ════════════════════════════════════════════
  // PLANT TYPES
  // ════════════════════════════════════════════
  Future<List<Map<String, dynamic>>> getPlantTypes() async {
    final db = await instance.database;
    return await db.query('plant_types', orderBy: 'name ASC');
  }

  Future<int> insertPlantType(String name) async {
    final db = await instance.database;
    return await db.insert('plant_types', {'name': name});
  }

  // ════════════════════════════════════════════
  // MULTI IMAGE GALLERY
  // ════════════════════════════════════════════
  Future<int> addPlantImage(int plantId, String path) async {
    final db = await instance.database;
    return await db.insert('plant_images', {
      'plantId':   plantId,
      'imagePath': path,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getPlantImages(int plantId) async {
    final db = await instance.database;
    return await db.query('plant_images',
        where: 'plantId = ?',
        whereArgs: [plantId],
        orderBy: 'createdAt DESC');
  }

  Future<int> insertPlantImage(Map<String, dynamic> row) async {
    final db = await database;
    return await db.insert('plant_images', row);
  }

  Future<int> deletePlantImage(int id) async {
    final db = await instance.database;
    return await db.delete('plant_images',
        where: 'id = ?', whereArgs: [id]);
  }

  // ════════════════════════════════════════════
  // CROP TIMELINE
  // ════════════════════════════════════════════

  Future<List<Map<String, dynamic>>> getCropCycles(int plantId) async {
    final db = await instance.database;
    return await db.query(
      'crop_cycles',
      where: 'plantId = ?',
      whereArgs: [plantId],
      orderBy: 'id DESC',
    );
  }

  Future<int?> getDefaultMaturationDays(String typeName) async {
    if (typeName.trim().isEmpty) return null;
    final db = await instance.database;
    final rows = await db.query(
      'plant_types',
      columns: ['default_maturation_days'],
      where: 'name = ?',
      whereArgs: [typeName.trim()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['default_maturation_days'] as int?;
  }

  Future<void> updateScheduleMilestones(
      int scheduleId, Map<String, String?> updates) async {
    final db = await instance.database;
    if (updates.isEmpty) return;
    final data = <String, Object?>{};
    for (final e in updates.entries) {
      data[e.key] = (e.value?.trim().isEmpty ?? true) ? null : e.value;
    }
    await db.update('schedules', data,
        where: 'id = ?', whereArgs: [scheduleId]);
  }

  Future<int> createCropCycle(int plantId, String name) async {
    final db = await database;
    return db.insert('crop_cycles', {
      'plantId':            plantId,
      'name':               name,
      'sow_date':           null,
      'transplant_date':    null,
      'first_flower_date':  null,
      'first_harvest_date': null,
      'harvest_end_date':   null,
    });
  }

  Future<void> updateCropCycleMilestones(
      int cycleId, Map<String, String?> updates) async {
    final db = await database;
    if (updates.isEmpty) return;
    await db.update(
      'crop_cycles',
      updates,
      where: 'id = ?',
      whereArgs: [cycleId],
    );
  }

  Future<void> renameCropCycle(int cycleId, String newName) async {
    final db = await database;
    await db.update(
      'crop_cycles',
      {'name': newName},
      where: 'id = ?',
      whereArgs: [cycleId],
    );
  }

  Future<void> deleteCropCycle(int cycleId) async {
    final db = await database;
    await db.delete('crop_cycles', where: 'id = ?', whereArgs: [cycleId]);
  }
}