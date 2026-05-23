/// 用户可见的产品品牌文案（集中维护，避免散落「AI 费曼」旧称）。
class AppBranding {
  AppBranding._();

  static const String displayName = '我讲你听';

  static const String tagline = '初中数学 · 讲给同伴听';

  /// AppBar / 桌面图标等主标题；[section] 为空时仅返回品牌名。
  static String appBarTitle([String? section]) {
    if (section == null || section.isEmpty) return displayName;
    return '$displayName · $section';
  }

  /// 注册 / 登录页等需要副标题的场景。
  static String get headerLine => '$displayName\n$tagline';

  /// 新用户默认学校名（后端 seed 与之对齐）。
  static const String defaultSchoolName = '我讲你听 · 示范校';

  /// 知识点列表、讲题入口等行为文案。
  static const String lectureEntryLabel = '讲给同伴听';
}
