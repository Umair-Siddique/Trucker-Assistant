import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_store.dart';
import 'log_folder_detail_screen.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen>
    with SingleTickerProviderStateMixin {
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

  late final AnimationController _enterCtrl;

  @override
  void initState() {
    super.initState();
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _loadLogs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final entries = await LogStore.loadEntries();
    if (!mounted) return;

    setState(() {
      _entries = entries;
      _loading = false;
    });

    _enterCtrl.forward(from: 0);
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
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return 'Today';
  }

  Future<void> _openFolder(_LogFolder folder) async {
    final changed = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        pageBuilder: (_, animation, secondaryAnimation) =>
            LogFolderDetailScreen(
          folderId: folder.category,
          folderTitle: folder.title,
          folderSubtitle: folder.subtitle,
          heroTag: 'folder_icon_${folder.category}',
        ),
        transitionsBuilder: (_, animation, __, child) {
          final slide = Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          );
          final fade = CurvedAnimation(
            parent: animation,
            curve: const Interval(0, 0.5),
          );
          return FadeTransition(
            opacity: fade,
            child: SlideTransition(position: slide, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 320),
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
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: const Text(
          'Logs',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Material(
              color: surface,
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _showAddHint,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: border),
                  ),
                  child: Icon(Icons.add, color: titleColor),
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
                      'Loading logs...',
                      style: TextStyle(
                        color: subtitleColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Stats + Search card ──────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: Material(
                      color: surface,
                      elevation: isDark ? 0 : 4,
                      shadowColor: const Color(0x12000000),
                      borderRadius: BorderRadius.circular(22),
                      clipBehavior: Clip.antiAlias,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
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
                                    icon: Icons.folder_outlined,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _StatCard(
                                    label: 'Saved Items',
                                    value: '$_totalItems',
                                    isDark: isDark,
                                    icon: Icons.description_outlined,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _StatCard(
                                    label: 'Recent',
                                    value: _recentEntries.isEmpty
                                        ? '0'
                                        : '${_recentEntries.length}',
                                    isDark: isDark,
                                    icon: Icons.history_outlined,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Container(
                              height: 52,
                              decoration: BoxDecoration(
                                color: softSurface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: border),
                              ),
                              child: Row(
                                children: [
                                  const SizedBox(width: 14),
                                  Icon(Icons.search,
                                      color: subtitleColor, size: 20),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextField(
                                      controller: _searchCtrl,
                                      onChanged: (_) => setState(() {}),
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      decoration: InputDecoration(
                                        hintText:
                                            'Search logs, receipts, notes...',
                                        hintStyle: TextStyle(
                                          color: subtitleColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
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
                                          color: subtitleColor, size: 18),
                                      padding: EdgeInsets.zero,
                                    ),
                                  const SizedBox(width: 6),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Filter chips ─────────────────────────────────────
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 38,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        _FilterPill(
                          label: 'All',
                          selected: _selectedFilter == 'all',
                          onTap: () =>
                              setState(() => _selectedFilter = 'all'),
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Fuel',
                          selected: _selectedFilter == 'fuel',
                          onTap: () =>
                              setState(() => _selectedFilter = 'fuel'),
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Trip',
                          selected: _selectedFilter == 'trip',
                          onTap: () =>
                              setState(() => _selectedFilter = 'trip'),
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Maintenance',
                          selected: _selectedFilter == 'maintenance',
                          onTap: () =>
                              setState(() => _selectedFilter = 'maintenance'),
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Receipts',
                          selected: _selectedFilter == 'receipts',
                          onTap: () =>
                              setState(() => _selectedFilter = 'receipts'),
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Notes',
                          selected: _selectedFilter == 'notes',
                          onTap: () =>
                              setState(() => _selectedFilter = 'notes'),
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ),

                  // ── Scrollable content ───────────────────────────────
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      children: [
                        // Section header
                        _SectionHeader(
                          label: 'File Cabinet',
                          trailing: '${folders.length} of ${_allFolders.length}',
                          isDark: isDark,
                        ),
                        const SizedBox(height: 10),

                        // Folders
                        if (folders.isEmpty)
                          _EmptyState(
                            isDark: isDark,
                            icon: Icons.folder_open_outlined,
                            message: 'No matching logs found',
                            subMessage: 'Try a different filter or search term',
                          )
                        else
                          ...folders.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final folder = entry.value;
                            return _StaggerAnim(
                              key: ValueKey(folder.category),
                              controller: _enterCtrl,
                              index: idx,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _LogCard(
                                  folder: folder,
                                  count: _countForFolder(folder.category),
                                  isDark: isDark,
                                  onTap: () => _openFolder(folder),
                                ),
                              ),
                            );
                          }),

                        const SizedBox(height: 8),

                        // Recent activity
                        _SectionHeader(
                          label: 'Recent Activity',
                          trailing: null,
                          isDark: isDark,
                        ),
                        const SizedBox(height: 10),

                        if (_recentEntries.isEmpty)
                          _EmptyState(
                            isDark: isDark,
                            icon: Icons.history_outlined,
                            message: 'No recent activity yet',
                            subMessage: 'Entries you add will appear here',
                          )
                        else
                          ..._recentEntries.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final log = entry.value;
                            return _StaggerAnim(
                              key: ValueKey('recent_${log.id}'),
                              controller: _enterCtrl,
                              index: folders.length + idx,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _RecentActivityTile(
                                  title: log.title,
                                  subtitle:
                                      '${log.note} • ${_formatRecent(log.createdAt)}',
                                  isDark: isDark,
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────
// Stagger animation wrapper
// ─────────────────────────────────────────────────────────────

class _StaggerAnim extends StatelessWidget {
  const _StaggerAnim({
    super.key,
    required this.controller,
    required this.index,
    required this.child,
  });

  final AnimationController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final start = (index * 0.06).clamp(0.0, 0.7);
    final end = (start + 0.4).clamp(0.0, 1.0);

    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );

    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(anim),
        child: child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.isDark,
    this.trailing,
  });

  final String label;
  final bool isDark;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white54 : Colors.black38;

    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.1,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: TextStyle(
              color: subtextColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.isDark,
    required this.icon,
    required this.message,
    required this.subMessage,
  });

  final bool isDark;
  final IconData icon;
  final String message;
  final String subMessage;

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white54 : Colors.black38;

    return Material(
      color: surface,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF222222)
                    : const Color(0xFFF0F0F0),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: subtextColor),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: subtextColor,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Stat card
// ─────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.isDark,
    required this.icon,
  });

  final String label;
  final String value;
  final bool isDark;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final softBg =
        isDark ? const Color(0xFF1F1F1F) : const Color(0xFFF7F7F7);
    final border =
        isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white54 : Colors.black38;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: softBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: subtextColor),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: textColor,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: subtextColor,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Filter pill
// ─────────────────────────────────────────────────────────────

class _FilterPill extends StatelessWidget {
  const _FilterPill({
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
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
                  : (isDark ? Colors.white70 : Colors.black87),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Log folder card
// ─────────────────────────────────────────────────────────────

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
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;
    final countLabel = count == 0
        ? 'No entries'
        : count == 1
            ? '1 entry'
            : '$count entries';

    return Material(
      color: surface,
      elevation: isDark ? 0 : 3,
      shadowColor: const Color(0x10000000),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Hero(
                tag: 'folder_icon_${folder.category}',
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(folder.icon, color: Colors.white, size: 26),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      folder.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: subtextColor,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF252525)
                          : const Color(0xFFF0F0F0),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: border),
                    ),
                    child: Text(
                      countLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 14,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// Recent activity tile
// ─────────────────────────────────────────────────────────────

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
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final softBg =
        isDark ? const Color(0xFF222222) : const Color(0xFFF7F7F7);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;

    return Material(
      color: surface,
      elevation: isDark ? 0 : 2,
      shadowColor: const Color(0x10000000),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: softBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.history_rounded,
                color: isDark ? Colors.white60 : Colors.black45,
                size: 20,
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
                      color: textColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subtextColor,
                      fontSize: 12,
                      height: 1.3,
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
