import 'dart:typed_data';

/// 当前「未提交」讲解段的 PCM 缓冲（从「开始讲题」到「讲题结束」）。
class SegmentAudioBuffer {
  final List<Uint8List> _chunks = <Uint8List>[];
  int _replayCursor = 0;

  bool get isEmpty => _chunks.isEmpty;
  bool get isNotEmpty => _chunks.isNotEmpty;
  int get length => _chunks.length;
  int get replayPendingCount => _chunks.length - _replayCursor;

  Iterable<Uint8List> get chunks => _chunks;
  Iterable<Uint8List> get replayPendingChunks => _chunks.skip(_replayCursor);

  void add(Uint8List data) {
    if (data.isEmpty) return;
    _chunks.add(Uint8List.fromList(data));
  }

  void resetReplayCursor() {
    _replayCursor = 0;
  }

  void markReplaySent(int count) {
    if (count <= 0) return;
    _replayCursor = (_replayCursor + count).clamp(0, _chunks.length);
  }

  void clear() {
    _chunks.clear();
    _replayCursor = 0;
  }
}
