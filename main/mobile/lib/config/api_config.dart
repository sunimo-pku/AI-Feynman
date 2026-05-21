/// 后端 API 配置。
///
/// 真机调试时改为开发机局域网 IP，例如 `http://192.168.1.100:8001`。
/// Android 模拟器访问本机可用 `http://10.0.2.2:8001`。
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8001',
  );

  static Uri uri(String path) => Uri.parse('$baseUrl$path');
}
