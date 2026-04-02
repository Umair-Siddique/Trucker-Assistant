import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LogEntry {
  final String id;
  final String folderId;
  final String title;
  final String note;
  final DateTime createdAt;

  const LogEntry({
    required this.id,
    required this.folderId,
    required this.title,
    required this.note,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'folderId': folderId,
      'title': title,
      'note': note,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      id: (json['id'] ?? '').toString(),
      folderId: (json['folderId'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      note: (json['note'] ?? '').toString(),
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
          DateTime.now(),
    );
  }
}

class LogStore {
  LogStore._();

  static const String _key = 'roaddogg_log_entries_v1';

  static Future<List<LogEntry>> loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);

    if (raw == null || raw.trim().isEmpty) {
      return _seedDefaults();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _seedDefaults();

      return decoded
          .whereType<Map>()
          .map((e) => LogEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return _seedDefaults();
    }
  }

  static Future<void> saveEntries(List<LogEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_key, raw);
  }

  static Future<List<LogEntry>> addEntry({
    required String folderId,
    required String title,
    required String note,
  }) async {
    final entries = await loadEntries();

    final entry = LogEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      folderId: folderId,
      title: title.trim(),
      note: note.trim(),
      createdAt: DateTime.now(),
    );

    final updated = [entry, ...entries];
    await saveEntries(updated);
    return updated;
  }

  static Future<List<LogEntry>> deleteEntry(String id) async {
    final entries = await loadEntries();
    final updated = entries.where((e) => e.id != id).toList();
    await saveEntries(updated);
    return updated;
  }

  static Future<List<LogEntry>> entriesForFolder(String folderId) async {
    final entries = await loadEntries();
    return entries.where((e) => e.folderId == folderId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  static Future<List<LogEntry>> _seedDefaults() async {
    final seeded = <LogEntry>[
      LogEntry(
        id: 'seed_1',
        folderId: 'fuel',
        title: 'Love’s fuel stop',
        note: '160 gallons • Dallas, TX • Truck diesel island 4',
        createdAt: DateTime.now().subtract(const Duration(minutes: 18)),
      ),
      LogEntry(
        id: 'seed_2',
        folderId: 'trip',
        title: 'Dallas to Houston',
        note: 'Load picked up on time. Light traffic most of the route.',
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
      ),
      LogEntry(
        id: 'seed_3',
        folderId: 'maintenance',
        title: 'Oil change reminder',
        note: 'Schedule service soon.',
        createdAt: DateTime.now().subtract(const Duration(hours: 4)),
      ),
      LogEntry(
        id: 'seed_4',
        folderId: 'receipts',
        title: 'Scale receipt saved',
        note: 'CAT scale ticket scanned and stored.',
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
    ];

    await saveEntries(seeded);
    return seeded;
  }
}