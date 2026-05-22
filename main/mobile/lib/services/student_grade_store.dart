import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

/// 学生当前年级（注册 / 「我的」资料为唯一修改入口，其它页只读）。
class StudentGradeStore extends ChangeNotifier {
  StudentGradeStore._();

  static final StudentGradeStore instance = StudentGradeStore._();

  static const List<String> validGrades = ['七年级', '八年级', '九年级'];

  String? _grade;
  bool _loaded = false;

  /// 未加载完成前为 null；加载后必有合法年级（默认八年级仅作冷启动兜底）。
  String? get gradeLabel => _grade;

  bool get isLoaded => _loaded;

  String _prefsKey() {
    final ns = AuthService.instance.storageNamespace;
    return 'ai_feynman.student_grade.v1.$ns';
  }

  Future<void> load() async {
    if (!AuthService.instance.isLoggedIn) {
      _grade = null;
      _loaded = true;
      notifyListeners();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = (prefs.getString(_prefsKey()) ?? '').trim();
      if (validGrades.contains(saved)) {
        _grade = saved;
      }
    } catch (_) {
      /* 读盘失败不阻塞 UI */
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setGrade(String grade) async {
    final normalized = grade.trim();
    if (!validGrades.contains(normalized)) return;
    _grade = normalized;
    _loaded = true;
    if (AuthService.instance.isLoggedIn) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey(), normalized);
      } catch (_) {
        /* 写盘失败仍更新内存，下次进资料页可再保存 */
      }
    }
    notifyListeners();
  }

  void clear() {
    _grade = null;
    _loaded = false;
    notifyListeners();
  }

  /// 与后端 `/learning/profile` 对齐；服务器为准。
  Future<void> applyServerGrade(String? grade) async {
    final normalized = (grade ?? '').trim();
    if (normalized.isEmpty || !validGrades.contains(normalized)) return;
    await setGrade(normalized);
  }
}
