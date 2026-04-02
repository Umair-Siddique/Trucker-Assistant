import 'package:flutter/material.dart';

import '../services/log_store.dart';
import 'log_folder_detail_screen.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<_LogFolder> _allFolders = [
    _LogFolder(
      icon: Icons.local_gas_station,
      title: 'Fuel Log',
      subtitle: 'Fuel stops, gallons, cost, and MPG notes',
      category: 'fuel',
    ),
    _LogFolder(
      icon: Icons.local_shipping_outlined,
      title: 'Trip Log',
      subtitle: 'Loads, miles, routes, pickup and drop-off details',
      category: 'trip',
    ),
    _LogFolder(
      icon: Icons.build_outlined,
      title: 'Maintenance Log',
      subtitle: 'Repairs, oil changes, tires, and service history',
      category: 'maintenance',
    ),
    _LogFolder(
      icon: Icons.receipt_long_outlined,
      title: 'Receipt Folder',
      subtitle: 'Fuel, food, toll, repair, and scale receipts',
      category: 'receipts',
    ),
    _LogFolder(
      icon: Icons.note_alt_outlined,
      title: 'Driver Notes',
      subtitle: 'Reminders, route notes, and personal notes',
      category: 'notes',
    ),
    _LogFolder(
      icon: Icons.warning_amber_rounded,
      title: 'Incident Log',
      subtitle: 'Breakdowns, delays, damage, and roadside events',
      category: 'incidents',
    ),
    _LogFolder(
      icon: Icons.assignment_outlined,
      title: 'Load Documents',
      subtitle: 'Rate cons, BOLs, confirmations, and paperwork',
      category: 'documents',
    ),
    _LogFolder(
      icon: Icons.health_and_safety_outlined,
      title: 'Compliance',
      subtitle: 'DOT, permits, insurance, registration, and renewals',
      category: 'compliance',
    ),
  ];

  String _selectedFilter = 'all';
  bool _loading = true;
  List<LogEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final entries = await LogStore.loadEntries();
    if (!mounted) return;

    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  List<_LogFolder> get _filteredFolders {
    final query = _searchCtrl.text.trim().toLowerCase();

    return _allFolders.where((folder) {
      final matchesFilter =
          _selectedFilter == 'all' || folder.category == _selectedFilter;

      final matchesSearch = query.isEmpty ||
          folder.title.toLowerCase().contains(query) ||
          folder.subtitle.toLowerCase().contains(query) ||
          folder.category.toLowerCase().contains(query);

      return matchesFilter && matchesSearch;
    }).toList();
  }

  int _countForFolder(String category) {
    return _entries.where((e) => e.folderId == category).length;
  }

  int get _totalItems => _entries.length;

  List<LogEntry> get _recentEntries {
    final copy = [..._entries];
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return copy.take(3).toList();
  }

  String _formatRecent(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
    if (diff.inHours < 24) return '${diff.inHours} hours ago';
    return 'Today';
  }

  Future<void> _openFolder(_LogFolder folder) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LogFolderDetailScreen(
          folderId: folder.category,
          folderTitle: folder.title,
          folderSubtitle: folder.subtitle,
        ),
      ),
    );

    if (changed == true || changed == null) {
      await _loadLogs();
    }
  }

  void _showAddHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Open a folder to add an entry')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF4F4F4);
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final softSurface =
        isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7);
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.white70 : Colors.black54;

    final folders = _filteredFolders;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Logs',
                            style: TextStyle(
                              color: titleColor,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _showAddHint,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: border),
                            ),
                            child: Icon(
                              Icons.add,
                              color: titleColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Material(
                      color: surface,
                      elevation: isDark ? 0 : 6,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _StatCard(
                                    label: 'Folders',
                                    value: '${_allFolders.length}',
                                    isDark: isDark,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _StatCard(
                                    label: 'Saved Items',
                                    value: '$_totalItems',
                                    isDark: isDark,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _StatCard(
                                    label: 'Recent',
                                    value:
                                        _recentEntries.isEmpty ? '0' : '${_recentEntries.length}',
                                    isDark: isDark,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Container(
                              height: 56,
                              decoration: BoxDecoration(
                                color: softSurface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: border),
                              ),
                              child: Row(
                                children: [
                                  const SizedBox(width: 12),
                                  Icon(Icons.search, color: subtitleColor),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextField(
                                      controller: _searchCtrl,
                                      onChanged: (_) => setState(() {}),
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 15,
                                      ),
                                      decoration: InputDecoration(
                                        hintText:
                                            'Search logs, receipts, notes...',
                                        hintStyle: TextStyle(
                                          color: subtitleColor,
                                        ),
                                        border: InputBorder.none,
                                      ),
                                    ),
                                  ),
                                  if (_searchCtrl.text.isNotEmpty)
                                    IconButton(
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() {});
                                      },
                                      icon: Icon(Icons.close,
                                          color: subtitleColor),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        _FilterChip(
                          label: 'All',
                          selected: _selectedFilter == 'all',
                          onTap: () => setState(() => _selectedFilter = 'all'),
                          isDark: isDark,
                        ),
                        _FilterChip(
                          label: 'Fuel',
                          selected: _selectedFilter == 'fuel',
                          onTap: () => setState(() => _selectedFilter = 'fuel'),
                          isDark: isDark,
                        ),
                        _FilterChip(
                          label: 'Trip',
                          selected: _selectedFilter == 'trip',
                          onTap: () => setState(() => _selectedFilter = 'trip'),
                          isDark: isDark,
                        ),
                        _FilterChip(
                          label: 'Maintenance',
                          selected: _selectedFilter == 'maintenance',
                          onTap: () =>
                              setState(() => _selectedFilter = 'maintenance'),
                          isDark: isDark,
                        ),
                        _FilterChip(
                          label: 'Receipts',
                          selected: _selectedFilter == 'receipts',
                          onTap: () =>
                              setState(() => _selectedFilter = 'receipts'),
                          isDark: isDark,
                        ),
                        _FilterChip(
                          label: 'Notes',
                          selected: _selectedFilter == 'notes',
                          onTap: () => setState(() => _selectedFilter = 'notes'),
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                      children: [
                        Text(
                          'File Cabinet',
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (folders.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(22),
                            decoration: BoxDecoration(
                              color: surface,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: border),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.folder_open_outlined,
                                  size: 42,
                                  color: subtitleColor,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'No matching logs found',
                                  style: TextStyle(
                                    color: titleColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ...folders.map(
                            (folder) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _LogCard(
                                folder: folder,
                                count: _countForFolder(folder.category),
                                isDark: isDark,
                                onTap: () => _openFolder(folder),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Recent Activity',
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (_recentEntries.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: surface,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: border),
                            ),
                            child: Text(
                              'No recent activity yet',
                              style: TextStyle(
                                color: subtitleColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        else
                          ..._recentEntries.map(
                            (entry) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _RecentActivityTile(
                                title: entry.title,
                                subtitle:
                                    '${entry.note} • ${_formatRecent(entry.createdAt)}',
                                isDark: isDark,
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
}

class _LogFolder {
  final IconData icon;
  final String title;
  final String subtitle;
  final String category;

  const _LogFolder({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.category,
  });
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.isDark,
  });

  final String label;
  final String value;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7);
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? Colors.white70 : Colors.black54,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.isDark,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? Colors.black
                : (isDark ? const Color(0xFF1A1A1A) : Colors.white),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? Colors.black
                  : (isDark
                      ? const Color(0xFF2A2A2A)
                      : const Color(0xFFEAEAEA)),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : (isDark ? Colors.white : Colors.black87),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({
    required this.folder,
    required this.count,
    required this.isDark,
    required this.onTap,
  });

  final _LogFolder folder;
  final int count;
  final bool isDark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);

    final countLabel = count == 1 ? '1 entry' : '$count entries';

    return Material(
      color: surface,
      elevation: isDark ? 0 : 4,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(folder.icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.title,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      folder.subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? Colors.white70 : Colors.black54,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      countLabel,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.chevron_right,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentActivityTile extends StatelessWidget {
  const _RecentActivityTile({
    required this.title,
    required this.subtitle,
    required this.isDark,
  });

  final String title;
  final String subtitle;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181818) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.history,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}