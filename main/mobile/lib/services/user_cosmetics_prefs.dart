import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

class UserCosmeticsPrefs extends ChangeNotifier {
  UserCosmeticsPrefs._();
  static final UserCosmeticsPrefs instance = UserCosmeticsPrefs._();

  String _penStyle = 'default';
  bool _loaded = false;

  String get penStyle => _penStyle;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _penStyle = prefs.getString(_key) ?? 'default';
    _loaded = true;
    notifyListeners();
  }

  Future<void> equipPenStyle(String skuId) async {
    final next = switch (skuId) {
      'pen-gold' => 'gold',
      _ => skuId.contains('gold') ? 'gold' : 'default',
    };
    _penStyle = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _penStyle);
    _loaded = true;
    notifyListeners();
  }

  String get _key =>
      'ai_feynman.cosmetics.pen.v1.${AuthService.instance.storageNamespace}';

  bool get isLoaded => _loaded;
}
