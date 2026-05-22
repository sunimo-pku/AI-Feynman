import 'dart:typed_data';

/// 当前「未提交」讲解段的 PCM 缓冲（从「开始讲题」到「讲题结束」）。
class SegmentAudioBuffer {
  final List<Uint8List> _chunks = <Uint8List>[];

  bool get isEmpty => _chunks.isEmpty;
  bool get isNotEmpty => _chunks.isNotEmpty;
  int get length => _chunks.length;

  Iterable<Uint8List> get chunks => _chunks;

  void add(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(Uint8List.fromList(data));
  }

  void clear() => _chunks.clear();
}
