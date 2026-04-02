import 'dart:convert';
import 'package:http/http.dart' as http;

class RoadDoggBackend {
  // If your backend is running on the SAME Mac as Flutter:
  // - iOS Simulator can use 127.0.0.1
  // - Physical iPhone cannot (it will point to the phone itself)
  //
  // For now we keep it simple and configurable.
  final String baseUrl;

  RoadDoggBackend({required this.baseUrl});

  Future<Map<String, dynamic>> health() async {
    final uri = Uri.parse('$baseUrl/health');
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Health failed: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> chat({required Map<String, dynamic> body}) async {
    final uri = Uri.parse('$baseUrl/chat');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (res.statusCode != 200) {
      throw Exception('Chat failed: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}