import 'package:flutter/material.dart';

/// A simple reusable scaffold that supports a BottomNavigationBar.
/// This file fixes your errors by DEFINING the named parameter `goTo:`.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.title,
    required this.body,
    this.currentIndex = 0,
    required this.goTo,
    this.floatingActionButton,
    this.showBottomNav = true,
  });

  final String title;
  final Widget body;

  /// Current selected tab index (used by bottom nav).
  final int currentIndex;

  /// ✅ FIX: This is the parameter VS Code says is missing.
  /// Use it to navigate tabs/screens however you want.
  final void Function(int index) goTo;

  final Widget? floatingActionButton;
  final bool showBottomNav;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: body,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: showBottomNav
          ? BottomNavigationBar(
              currentIndex: currentIndex,
              onTap: goTo,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home),
                  label: 'Home',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.map),
                  label: 'Maps',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.cloud),
                  label: 'Weather',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            )
          : null,
    );
  }
}