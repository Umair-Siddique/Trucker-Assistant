import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  final void Function(String destination) goTo;

  const HomeScreen({super.key, required this.goTo});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Home Screen'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => goTo('maps'),
              child: const Text('Go to Map'),
            ),
            ElevatedButton(
              onPressed: () => goTo('weather'),
              child: const Text('Go to Weather'),
            ),
            ElevatedButton(
              onPressed: () => goTo('settings'),
              child: const Text('Go to Settings'),
            ),
          ],
        ),
      ),
    );
  }
}