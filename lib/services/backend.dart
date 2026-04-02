class Backend {
  // Default: iOS Simulator can reach your Mac backend at localhost.
  // If you run on a REAL iPhone, pass your Mac LAN IP with:
  // flutter run --dart-define=BACKEND_HOST=192.168.x.x ...
  static const int port = 3000;

  static String baseUrl() {
    const host = String.fromEnvironment('BACKEND_HOST', defaultValue: 'localhost');
    return 'http://$host:$port';
  }
}