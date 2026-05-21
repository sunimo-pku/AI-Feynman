import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class ApiService {
  Future<bool> checkHealth() async {
    try {
      final resp = await http
          .get(ApiConfig.uri('/health'))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
