import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../theme/app_theme.dart';

/// 全站公式渲染封装。
///
/// 第十一轮起使用 `flutter_math_fork` 原生 Canvas 渲染 LaTeX，同时保留
/// `renderLatex` 作为旧单测和极端 fallback 的可读化工具。
class FormulaText extends StatelessWidget {
  const FormulaText(
    this.source, {
    super.key,
    this.style,
    this.formulaStyle,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String source;
  final TextStyle? style;
  final TextStyle? formulaStyle;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

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

    final normalized = _normalizeDelimiters(source);
    if (!_looksLikeFormula(normalized)) {
      return Text(
        normalized,
        style: base,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    if (!normalized.contains(r'$') && normalized.contains('\\')) {
      return RepaintBoundary(
        child: _MathBox(normalized, textStyle: formula, isBlock: false),
      );
    }
    return RepaintBoundary(
      child: RichText(
        maxLines: maxLines,
        overflow: overflow ?? TextOverflow.clip,
        text: TextSpan(style: base, children: _buildSpans(normalized, base, formula)),
        textAlign: textAlign ?? TextAlign.start,
      ),
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
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _MathBox(
          raw,
          textStyle: formulaStyle,
          isBlock: block != null,
        ),
      ));
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

  static String _normalizeDelimiters(String input) {
    return input
        .replaceAllMapped(RegExp(r'\\\((.*?)\\\)'), (m) => '\$${m.group(1)}\$')
        .replaceAllMapped(RegExp(r'\\\[(.*?)\\\]', dotAll: true), (m) => '\$\$${m.group(1)}\$\$');
  }

  static bool _looksLikeFormula(String input) {
    return input.contains(r'$') || input.contains('\\');
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

class _MathBox extends StatelessWidget {
  const _MathBox(
    this.tex, {
    required this.textStyle,
    required this.isBlock,
  });

  final String tex;
  final TextStyle textStyle;
  final bool isBlock;

  @override
  Widget build(BuildContext context) {
    final math = Math.tex(
      tex,
      textStyle: textStyle,
      mathStyle: MathStyle.text,
      onErrorFallback: (error) => Text(
        FormulaText.renderLatex(tex),
        style: textStyle,
      ),
    );
    if (!isBlock) return math;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(child: math),
    );
  }
}
