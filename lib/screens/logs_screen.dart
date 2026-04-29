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
      accentColor: Color(0xFFFF9500),
      title: 'Fuel Log',
      subtitle: 'Fuel stops, gallons, cost, and MPG notes',
      category: 'fuel',
    ),
    _LogFolder(
      icon: Icons.local_shipping_outlined,
      accentColor: Color(0xFF007AFF),
      title: 'Trip Log',
      subtitle: 'Loads, miles, routes, pickup and drop-off details',
      category: 'trip',
    ),
    _LogFolder(
      icon: Icons.build_outlined,
      accentColor: Color(0xFFFF3B30),
      title: 'Maintenance Log',
      subtitle: 'Repairs, oil changes, tires, and service history',
      category: 'maintenance',
    ),
    _LogFolder(
      icon: Icons.receipt_long_outlined,
      accentColor: Color(0xFF34C759),
      title: 'Receipt Folder',
      subtitle: 'Fuel, food, toll, repair, and scale receipts',
      category: 'receipts',
    ),
    _LogFolder(
      icon: Icons.note_alt_outlined,
      accentColor: Color(0xFFBF5AF2),
      title: 'Driver Notes',
      subtitle: 'Reminders, route notes, and personal notes',
      category: 'notes',
    ),
    _LogFolder(
      icon: Icons.warning_amber_rounded,
      accentColor: Color(0xFFFF6B00),
      title: 'Incident Log',
      subtitle: 'Breakdowns, delays, damage, and roadside events',
      category: 'incidents',
    ),
    _LogFolder(
      icon: Icons.assignment_outlined,
      accentColor: Color(0xFF5AC8FA),
      title: 'Load Documents',
      subtitle: 'Rate cons, BOLs, confirmations, and paperwork',
      category: 'documents',
    ),
    _LogFolder(
      icon: Icons.health_and_safety_outlined,
      accentColor: Color(0xFF30D158),
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
      duration: const Duration(milliseconds: 700),
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

  int _countForFolder(String category) =>
      _entries.where((e) => e.folderId == category).length;

  int get _totalItems => _entries.length;

  List<LogEntry> get _recentEntries {
    final copy = [..._entries];
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return copy.take(3).toList();
  }

  Color _accentForCategory(String category) {
    for (final f in _allFolders) {
      if (f.category == category) return f.accentColor;
    }
    return Colors.black;
  }

  String _formatRecent(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return 'Today';
  }

  Future<void> _openFolder(_LogFolder folder) async {
    HapticFeedback.lightImpact();
    final changed = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        pageBuilder: (_, animation, secondaryAnimation) =>
            LogFolderDetailScreen(
          folderId: folder.category,
          folderTitle: folder.title,
          folderSubtitle: folder.subtitle,
          folderIcon: folder.icon,
          accentColor: folder.accentColor,
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
    final bg = isDark ? const Color(0xFF111111) : const Color(0xFFF2F2F7);
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final titleColor = isDark ? Colors.white : Colors.black87;

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
            child: GestureDetector(
              onTap: _showAddHint,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: border),
                  boxShadow: isDark
                      ? const []
                      : const [
                          BoxShadow(
                            blurRadius: 8,
                            offset: Offset(0, 2),
                            color: Color(0x14000000),
                          ),
                        ],
                ),
                child: Icon(Icons.add_rounded, color: titleColor, size: 22),
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
                        color: isDark ? Colors.white54 : Colors.black38,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Gradient hero card ─────────────────────────────────
                  _HeroStatsCard(
                    totalFolders: _allFolders.length,
                    totalItems: _totalItems,
                    recentCount: _recentEntries.length,
                    searchCtrl: _searchCtrl,
                    onSearch: () => setState(() {}),
                    onClear: () {
                      _searchCtrl.clear();
                      setState(() {});
                    },
                  ),

                  // ── Filter chips ───────────────────────────────────────
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        _FilterPill(
                          label: 'All',
                          selected: _selectedFilter == 'all',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'all');
                          },
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Fuel',
                          selected: _selectedFilter == 'fuel',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'fuel');
                          },
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Trip',
                          selected: _selectedFilter == 'trip',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'trip');
                          },
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Maintenance',
                          selected: _selectedFilter == 'maintenance',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'maintenance');
                          },
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Receipts',
                          selected: _selectedFilter == 'receipts',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'receipts');
                          },
                          isDark: isDark,
                        ),
                        _FilterPill(
                          label: 'Notes',
                          selected: _selectedFilter == 'notes',
                          onTap: () {
                            HapticFeedback.selectionClick();
                            setState(() => _selectedFilter = 'notes');
                          },
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ),

                  // ── Scrollable list ────────────────────────────────────
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      children: [
                        _SectionLabel(
                          label: 'FILE CABINET',
                          trailing: '${folders.length} of ${_allFolders.length}',
                          isDark: isDark,
                        ),
                        const SizedBox(height: 10),

                        if (folders.isEmpty)
                          _EmptyState(
                            isDark: isDark,
                            icon: Icons.folder_open_outlined,
                            message: 'No matching logs found',
                            subMessage:
                                'Try a different filter or search term',
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

                        const SizedBox(height: 10),
                        _SectionLabel(
                          label: 'RECENT ACTIVITY',
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
                                      '${log.note} · ${_formatRecent(log.createdAt)}',
                                  isDark: isDark,
                                  accentColor:
                                      _accentForCategory(log.folderId),
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

// ── Data model ─────────────────────────────────────────────────────────────────

class _LogFolder {
  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final String category;

  const _LogFolder({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.category,
  });
}

// ── Hero stats card ────────────────────────────────────────────────────────────

class _HeroStatsCard extends StatelessWidget {
  const _HeroStatsCard({
    required this.totalFolders,
    required this.totalItems,
    required this.recentCount,
    required this.searchCtrl,
    required this.onSearch,
    required this.onClear,
  });

  final int totalFolders;
  final int totalItems;
  final int recentCount;
  final TextEditingController searchCtrl;
  final VoidCallback onSearch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1C1C2E), Color(0xFF16213E)],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              blurRadius: 24,
              offset: Offset(0, 8),
              color: Color(0x38000000),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'File Cabinet',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Your driving records',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.50),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      _HeroStat(
                        label: 'Folders',
                        value: '$totalFolders',
                        icon: Icons.folder_outlined,
                      ),
                      const SizedBox(width: 18),
                      _HeroStat(
                        label: 'Items',
                        value: '$totalItems',
                        icon: Icons.description_outlined,
                      ),
                      const SizedBox(width: 18),
                      _HeroStat(
                        label: 'Recent',
                        value: '$recentCount',
                        icon: Icons.history_outlined,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.09),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Colors.white.withOpacity(0.13)),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(
                      Icons.search_rounded,
                      color: Colors.white.withOpacity(0.50),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        onChanged: (_) => onSearch(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search logs, receipts, notes...',
                          hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.35),
                            fontWeight: FontWeight.w500,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (searchCtrl.text.isNotEmpty)
                      IconButton(
                        onPressed: onClear,
                        icon: Icon(
                          Icons.close_rounded,
                          color: Colors.white.withOpacity(0.55),
                          size: 18,
                        ),
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
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.45),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

// ── Section label ──────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    required this.isDark,
    this.trailing,
  });

  final String label;
  final bool isDark;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final color = isDark ? Colors.white38 : Colors.black38;

    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Stagger animation wrapper ──────────────────────────────────────────────────

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
    final start = (index * 0.07).clamp(0.0, 0.65);
    final end = (start + 0.45).clamp(0.0, 1.0);

    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOutQuart),
    );

    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.10),
          end: Offset.zero,
        ).animate(anim),
        child: child,
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

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
                color:
                    isDark ? const Color(0xFF222222) : const Color(0xFFF0F0F0),
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
              style: TextStyle(color: subtextColor, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Filter pill ────────────────────────────────────────────────────────────────

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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                      : const Color(0xFFE0E0E0)),
            ),
            boxShadow: selected
                ? const []
                : (isDark
                    ? const []
                    : [
                        BoxShadow(
                          blurRadius: 6,
                          offset: Offset(0, 2),
                          color: Color(0x10000000),
                        ),
                      ]),
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

// ── Log folder card (with press-scale + accent color) ─────────────────────────

class _LogCard extends StatefulWidget {
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
  State<_LogCard> createState() => _LogCardState();
}

class _LogCardState extends State<_LogCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressCtrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;
    final accent = widget.folder.accentColor;
    final iconBg = accent.withOpacity(isDark ? 0.16 : 0.10);
    final hasEntries = widget.count > 0;

    final countLabel = widget.count == 0
        ? 'Empty'
        : widget.count == 1
            ? '1 entry'
            : '${widget.count} entries';

    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(
        onTapDown: (_) => _pressCtrl.forward(),
        onTapUp: (_) {
          _pressCtrl.reverse();
          widget.onTap();
        },
        onTapCancel: () => _pressCtrl.reverse(),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border),
            boxShadow: isDark
                ? const []
                : const [
                    BoxShadow(
                      blurRadius: 12,
                      offset: Offset(0, 3),
                      color: Color(0x0C000000),
                    ),
                  ],
          ),
          child: Row(
            children: [
              Hero(
                tag: 'folder_icon_${widget.folder.category}',
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: accent.withOpacity(isDark ? 0.22 : 0.18)),
                  ),
                  child: Icon(widget.folder.icon, color: accent, size: 26),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.folder.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.folder.subtitle,
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
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: hasEntries
                          ? accent.withOpacity(isDark ? 0.20 : 0.12)
                          : (isDark
                              ? const Color(0xFF252525)
                              : const Color(0xFFF0F0F0)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      countLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: hasEntries
                            ? accent
                            : (isDark ? Colors.white38 : Colors.black38),
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

// ── Recent activity tile ───────────────────────────────────────────────────────

class _RecentActivityTile extends StatelessWidget {
  const _RecentActivityTile({
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.accentColor,
  });

  final String title;
  final String subtitle;
  final bool isDark;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final surface = isDark ? const Color(0xFF181818) : Colors.white;
    final border = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.white70 : Colors.black54;
    final iconBg = accentColor.withOpacity(isDark ? 0.16 : 0.10);

    return Material(
      color: surface,
      elevation: isDark ? 0 : 2,
      shadowColor: const Color(0x0C000000),
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
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.history_rounded,
                color: accentColor,
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
            const SizedBox(width: 10),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: accentColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
