import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 极简的 LaTeX → Unicode 渲染器（V1 占位用）。
///
/// 真正的公式渲染按 `MOBILE_STYLE.md` §4.1 应使用 `flutter_math_fork`。
/// 在引入该依赖之前，本组件做最小可读化处理，把 `\sqrt{...}` / `\frac{a}{b}` /
/// `\cdot` 等常见 token 转成 Unicode + 富文本，保证公式（特别是二次根式）
/// 在演示中不至于以原始 LaTeX 字符串呈现。
///
/// 渲染规则：
///   * 行内片段用 `$...$` 包裹，块级片段用 `$$...$$`。
///   * 未被 `$` 包裹的部分作为普通中文 / 英文文本渲染。
///   * `\sqrt{x}`     → `√(x)`（单字符则去括号，如 `√3`）。
///   * `\frac{a}{b}`  → `a/b`。
///   * `\cdot` / `\times` → `·` / `×`。
///   * `\le` / `\ge` / `\ne` → `≤` / `≥` / `≠`。
///   * `^{n}` / `^n` 上标（`²` `³` 直接映射，其他用 `^n`）。
///   * `_{n}` / `_n` 直接保留 `_n`。
class FormulaText extends StatelessWidget {
  const FormulaText(
    this.source, {
    super.key,
    this.style,
    this.formulaStyle,
    this.textAlign,
  });

  final String source;
  final TextStyle? style;
  final TextStyle? formulaStyle;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style ??
        Theme.of(context).textTheme.bodyLarge ??
        const TextStyle(fontSize: 16, height: 1.5);
    final formula = (formulaStyle ?? base).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      color: (formulaStyle?.color ?? base.color ?? AppPalette.primary),
      fontWeight: FontWeight.w600,
    );

    final spans = _buildSpans(source, base, formula);
    return RichText(
      text: TextSpan(style: base, children: spans),
      textAlign: textAlign ?? TextAlign.start,
    );
  }

  static List<InlineSpan> _buildSpans(
    String source,
    TextStyle baseStyle,
    TextStyle formulaStyle,
  ) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\$\$([^$]+)\$\$|\$([^$]+)\$');
    var cursor = 0;
    for (final match in pattern.allMatches(source)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: source.substring(cursor, match.start)));
      }
      final block = match.group(1);
      final inline = match.group(2);
      final raw = block ?? inline ?? '';
      final rendered = renderLatex(raw);
      spans.add(TextSpan(text: rendered, style: formulaStyle));
      cursor = match.end;
    }
    if (cursor < source.length) {
      spans.add(TextSpan(text: source.substring(cursor)));
    }
    if (spans.isEmpty) {
      spans.add(TextSpan(text: renderLatex(source)));
    }
    return spans;
  }

  /// 将常见的 LaTeX 片段转成 Unicode 文本（仅供 V1 占位）。
  static String renderLatex(String input) {
    var s = input;
    s = s.replaceAll(r'\,', ' ');
    s = s.replaceAll(r'\;', ' ');
    s = s.replaceAll(r'\!', '');
    s = s.replaceAll(r'\left', '');
    s = s.replaceAll(r'\right', '');
    s = s.replaceAll(r'\cdot', '·');
    s = s.replaceAll(r'\times', '×');
    s = s.replaceAll(r'\div', '÷');
    s = s.replaceAll(r'\pm', '±');
    s = s.replaceAll(r'\le', '≤');
    s = s.replaceAll(r'\geq', '≥');
    s = s.replaceAll(r'\ge', '≥');
    s = s.replaceAll(r'\leq', '≤');
    s = s.replaceAll(r'\ne', '≠');
    s = s.replaceAll(r'\neq', '≠');
    s = s.replaceAll(r'\approx', '≈');
    s = s.replaceAll(r'\pi', 'π');

    final sqrtBrace = RegExp(r'\\sqrt\{([^{}]+)\}');
    s = s.replaceAllMapped(sqrtBrace, (m) {
      final inner = m.group(1)!.trim();
      return inner.length == 1 ? '√$inner' : '√($inner)';
    });
    s = s.replaceAll(r'\sqrt', '√');

    final fracBrace = RegExp(r'\\frac\{([^{}]+)\}\{([^{}]+)\}');
    s = s.replaceAllMapped(fracBrace, (m) {
      final a = m.group(1)!.trim();
      final b = m.group(2)!.trim();
      return '$a/$b';
    });

    s = s.replaceAllMapped(RegExp(r'\^\{([^{}]+)\}'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAllMapped(RegExp(r'\^(\w)'), (m) => _toSuperscript(m.group(1)!));
    s = s.replaceAllMapped(RegExp(r'_\{([^{}]+)\}'), (m) => '_${m.group(1)}');

    s = s.replaceAll('|', '∣');

    return s;
  }

  static const Map<String, String> _superscriptMap = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
    '+': '⁺', '-': '⁻', 'n': 'ⁿ',
  };

  static String _toSuperscript(String raw) {
    final buf = StringBuffer();
    var allMapped = true;
    for (final ch in raw.split('')) {
      final mapped = _superscriptMap[ch];
      if (mapped == null) {
        allMapped = false;
        break;
      }
      buf.write(mapped);
    }
    return allMapped ? buf.toString() : '^$raw';
  }
}
