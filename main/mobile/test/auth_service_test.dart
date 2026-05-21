import 'package:ai_feynman/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthService persistence', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AuthService.instance.testPrefsOverride = await SharedPreferences.getInstance();
      await AuthService.instance.logout();
    });

    test('load yields logged out when prefs empty', () async {
      await AuthService.instance.load();
      expect(AuthService.instance.isLoggedIn, false);
      expect(AuthService.instance.currentToken, '');
    });

    test('authHeaders does not include Bearer when logged out', () {
      final headers = AuthService.instance.authHeaders();
      expect(headers.containsKey('Authorization'), false);
      expect(headers['Content-Type'], 'application/json; charset=utf-8');
    });
  });
}
