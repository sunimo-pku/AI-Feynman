/// 把含 LaTeX 的讲题文本转成适合 TTS 朗读的纯文本。
String plainTextForTts(String text) {
  var s = text.trim();
  if (s.isEmpty) return s;
  s = s.replaceAll(RegExp(r'\$\$(.+?)\$\$', dotAll: true), ' ');
  s = s.replaceAllMapped(RegExp(r'\$([^$]+)\$'), (m) => m.group(1) ?? '');
  s = s.replaceAll(RegExp(r'\\[([]'), ' ');
  s = s.replaceAll(RegExp(r'\\[\])]'), ' ');
  s = s.replaceAll(
    RegExp(r'\\(?:sqrt|frac|cdot|times|ge|le|ne|pm|pi)\{?'),
    '',
  );
  s = s.replaceAll(RegExp(r'[{}\\]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}
