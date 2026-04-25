import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_store.dart';

class LogFolderDetailScreen extends StatefulWidget {
  const LogFolderDetailScreen({
    super.key,
    required this.folderId,
    required this.folderTitle,
    required this.folderSubtitle,
    this.heroTag,
  });

  final String folderId;
  final String folderTitle;
  final String folderSubtitle;
  final String? heroTag;

  @override
  State<LogFolderDetailScreen> createState() => _LogFolderDetailScreenState();
}

class _LogFolderDetailScreenState extends State<LogFolderDetailScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  List<LogEntry> _entries = [];

  late final AnimationController _enterCtrl;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _loadFolder();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFolder() async {
    final entries = await LogStore.entriesForFolder(widget.folderId);
    if (!mounted) return;

    setState(() {
      _entries = entries;
      _loading = false;
    });

    _enterCtrl.forward(from: 0);
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
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final softBg =
        isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7);
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: bg,
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
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black26,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Add ${widget.folderTitle} Entry',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.folderSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: subtextColor,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _titleCtrl,
                style: TextStyle(
                    color: textColor, fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  labelText: 'Title',
                  labelStyle: TextStyle(color: subtextColor),
                  prefixIcon:
                      Icon(Icons.title_rounded, color: subtextColor),
                  filled: true,
                  fillColor: softBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:
                        const BorderSide(color: Colors.black, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                minLines: 3,
                maxLines: 5,
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  labelText: 'Details',
                  labelStyle: TextStyle(color: subtextColor),
                  alignLabelWithHint: true,
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(bottom: 48),
                    child: Icon(Icons.notes_rounded, color: subtextColor),
                  ),
                  filled: true,
                  fillColor: softBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:
                        const BorderSide(color: Colors.black, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: Material(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: _saving ? null : _addEntry,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: _saving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Save Entry',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ),
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

    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF4F4F4);
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final softBg =
        isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7);
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(true),
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: textColor, size: 20),
        ),
        title: Row(
          children: [
            Hero(
              tag: widget.heroTag ?? 'folder_icon_${widget.folderId}',
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.folder_open_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.folderTitle,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    widget.folderSubtitle,
                    style: TextStyle(
                      color: subtextColor,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Material(
              color: surface,
              borderRadius: BorderRadius.circular(13),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _showAddEntrySheet,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: border),
                  ),
                  child: Icon(Icons.add_rounded,
                      color: textColor, size: 20),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(strokeWidth: 2),
                    const SizedBox(height: 14),
                    Text(
                      'Loading entries...',
                      style: TextStyle(
                        color: subtextColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            : _entries.isEmpty
                ? _EmptyEntries(isDark: isDark)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _entries.length,
                    itemBuilder: (_, i) {
                      final entry = _entries[i];

                      final start = (i * 0.07).clamp(0.0, 0.7);
                      final end = (start + 0.4).clamp(0.0, 1.0);
                      final anim = CurvedAnimation(
                        parent: _enterCtrl,
                        curve: Interval(start, end,
                            curve: Curves.easeOutCubic),
                      );

                      return FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.05),
                            end: Offset.zero,
                          ).animate(anim),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Dismissible(
                              key: Key(entry.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding:
                                    const EdgeInsets.only(right: 20),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade700,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Icon(Icons.delete_outline_rounded,
                                    color: Colors.white, size: 24),
                              ),
                              onDismissed: (_) => _deleteEntry(entry),
                              child: Material(
                                color: surface,
                                elevation: isDark ? 0 : 2,
                                shadowColor: const Color(0x10000000),
                                borderRadius: BorderRadius.circular(20),
                                clipBehavior: Clip.antiAlias,
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              color: softBg,
                                              borderRadius:
                                                  BorderRadius.circular(11),
                                            ),
                                            child: Icon(
                                              Icons.description_outlined,
                                              size: 18,
                                              color: isDark
                                                  ? Colors.white60
                                                  : Colors.black45,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              entry.title,
                                              style: TextStyle(
                                                color: textColor,
                                                fontWeight: FontWeight.w900,
                                                fontSize: 15,
                                              ),
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            color: surface,
                                            iconColor: subtextColor,
                                            iconSize: 20,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                            ),
                                            onSelected: (value) {
                                              if (value == 'delete') {
                                                _deleteEntry(entry);
                                              }
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .delete_outline_rounded,
                                                      size: 18,
                                                      color: Colors.red,
                                                    ),
                                                    SizedBox(width: 8),
                                                    Text(
                                                      'Delete',
                                                      style: TextStyle(
                                                          color: Colors.red),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        entry.note,
                                        style: TextStyle(
                                          color: subtextColor,
                                          height: 1.45,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.schedule_rounded,
                                            size: 13,
                                            color: subtextColor,
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            _formatTime(entry.createdAt),
                                            style: TextStyle(
                                              color: subtextColor,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _EmptyEntries extends StatelessWidget {
  const _EmptyEntries({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white54 : Colors.black38;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Material(
          color: surface,
          borderRadius: BorderRadius.circular(24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF222222)
                        : const Color(0xFFF0F0F0),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.folder_open_outlined,
                    size: 30,
                    color: subtextColor,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'No entries yet',
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tap + to add your first entry\nto this folder.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: subtextColor,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
