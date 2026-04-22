import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class OpenAiResponsesClient {
  OpenAiResponsesClient();

  static String? get _apiKey {
    final k = dotenv.env['OPENAI_API_KEY']?.trim();
    return (k == null || k.isEmpty) ? null : k;
  }

  static Never _missingKey() {
    throw Exception(
      'Missing `OPENAI_API_KEY` in .env. Add it, restart the app, and try again.',
    );
  }

  Future<String> reply({
    required String userText,
    String systemPrompt =
        'You are RoadDogg AI, a concise trucking assistant. Keep replies short, natural, and useful for a driver on the road.',
    String model = 'gpt-4o-mini',
  }) async {
    final key = _apiKey ?? _missingKey();
    final resp = await http.post(
      Uri.parse('https://api.openai.com/v1/responses'),
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': model,
        'input': [
          {
            'role': 'system',
            'content': systemPrompt,
          },
          {
            'role': 'user',
            'content': userText.trim(),
          },
        ],
      }),
    );

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('OpenAI failed: HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = jsonDecode(resp.body);
    if (data is Map && data['output_text'] is String) {
      final t = (data['output_text'] as String).trim();
      if (t.isNotEmpty) return t;
    }

    // Fallback: best-effort parse `output[]`.
    if (data is Map && data['output'] is List) {
      final out = StringBuffer();
      for (final item in (data['output'] as List)) {
        if (item is Map && item['content'] is List) {
          for (final c in (item['content'] as List)) {
            if (c is Map && c['type'] == 'output_text' && c['text'] is String) {
              out.write(c['text'] as String);
            }
          }
        }
      }
      final t = out.toString().trim();
      if (t.isNotEmpty) return t;
    }

    return 'OK';
  }
}

