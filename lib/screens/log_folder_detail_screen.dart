import 'package:flutter/material.dart';

import '../services/log_store.dart';

class LogFolderDetailScreen extends StatefulWidget {
  const LogFolderDetailScreen({
    super.key,
    required this.folderId,
    required this.folderTitle,
    required this.folderSubtitle,
  });

  final String folderId;
  final String folderTitle;
  final String folderSubtitle;

  @override
  State<LogFolderDetailScreen> createState() => _LogFolderDetailScreenState();
}

class _LogFolderDetailScreenState extends State<LogFolderDetailScreen> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  List<LogEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadFolder();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFolder() async {
    final entries = await LogStore.entriesForFolder(widget.folderId);
    if (!mounted) return;

    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _addEntry() async {
    final title = _titleCtrl.text.trim();
    final note = _noteCtrl.text.trim();

    if (title.isEmpty || note.isEmpty || _saving) return;

    setState(() => _saving = true);

    await LogStore.addEntry(
      folderId: widget.folderId,
      title: title,
      note: note,
    );

    _titleCtrl.clear();
    _noteCtrl.clear();

    if (!mounted) return;
    Navigator.of(context).pop();
    await _loadFolder();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${widget.folderTitle} entry added')),
    );

    setState(() => _saving = false);
  }

  Future<void> _deleteEntry(LogEntry entry) async {
    await LogStore.deleteEntry(entry.id);
    await _loadFolder();
  }

  void _showAddEntrySheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Add ${widget.folderTitle} Entry',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _titleCtrl,
                decoration: InputDecoration(
                  labelText: 'Title',
                  filled: true,
                  fillColor:
                      isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: border),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                minLines: 3,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'Details',
                  filled: true,
                  fillColor:
                      isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: border),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _saving ? null : _addEntry,
                  child: Text(_saving ? 'Saving...' : 'Save Entry'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} min ago';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours} hr ago';
    }
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF4F4F4);
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: Icon(
                      Icons.arrow_back,
                      color: titleColor,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.folderTitle,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          widget.folderSubtitle,
                          style: TextStyle(
                            color: subtitleColor,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: _showAddEntrySheet,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: border),
                      ),
                      child: Icon(Icons.add, color: titleColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _entries.isEmpty
                      ? Center(
                          child: Text(
                            'No entries yet',
                            style: TextStyle(
                              color: subtitleColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                          itemCount: _entries.length,
                          itemBuilder: (_, i) {
                            final entry = _entries[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: surface,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(color: border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            entry.title,
                                            style: TextStyle(
                                              color: titleColor,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 16,
                                            ),
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          color: surface,
                                          onSelected: (value) {
                                            if (value == 'delete') {
                                              _deleteEntry(entry);
                                            }
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete'),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      entry.note,
                                      style: TextStyle(
                                        color: subtitleColor,
                                        height: 1.35,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      _formatTime(entry.createdAt),
                                      style: TextStyle(
                                        color: subtitleColor,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}