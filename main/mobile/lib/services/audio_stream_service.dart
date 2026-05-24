import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

/// 实时音频采集服务（第九轮）。
///
/// 责任：
///   * 在用户点击"开始讲题"时申请麦克风权限、起 [AudioRecorder] 推流；
///   * 把 PCM16 字节流按 ~300ms 一片切成 chunk，通过 [chunks] 广播；
///   * 维护"自然停顿"判定：连续 [_pauseSilenceMs] 毫秒静音 → [pauses]
///     广播一次 silenceMs 数值；新音量回到 [_voiceThreshold] 之上则清零计时；
///   * 同时根据持续静音 / 重新发声 推送 [voiceActivity] 给 UI 显示
///     "正在听你讲..." vs. "检测到停顿..."；
///   * 暴露 [stop] / [dispose]，调用方在 LecturePage dispose / 切题时调用。
///
/// 平台与依赖：
///   * 通过 [Record] 包跨 Android/iOS/macOS/Web 抓 PCM16 16k 流，
///     不持有任何 platform-channel 直依赖。
///   * 权限通过 [permission_handler] 单独申请，**不**与录音库的权限
///     检测耦合 —— 后者各平台行为不一致（Web 走浏览器 API），
///     统一在前端层判 [Permission.microphone] 更稳定。
///
/// 错误语义（对齐 brief 第 13 节）：
///   * 拒绝权限 → 进入 [AudioStreamStatus.permissionDenied] 状态，
///     **不**抛异常，不阻塞 UI；
///   * 录音库异常 → 进入 [AudioStreamStatus.failed] 状态 + [failureReason]，
///     UI 据此给"录音不可用，先用文字提交"的兜底入口；
///   * 任意状态下 [stop] 都安全可调，幂等。
class AudioStreamService {
  AudioStreamService({
    AudioRecorder? recorder,
    int? voiceThreshold,
    int? pauseSilenceMs,
  })  : _recorder = recorder ?? AudioRecorder(),
        _voiceThreshold = voiceThreshold ?? 600,
        // 第十二轮：1500ms 太保守，端到端体感 3.5-4s 像微信语音条而不是对话。
        // 700ms 是 OpenAI Realtime / Whisper Realtime 等同类系统的典型阈值。
        // 副作用：学生「嗯…然后…」的犹豫间歇会被判成结束；可以靠 wrapUp 阶段
        // 的 voice 重新触发恢复 listening 来缓解（见 _onAudioVoice）。
        _pauseSilenceMs = pauseSilenceMs ?? 700;

  final AudioRecorder _recorder;
  final int _voiceThreshold;
  final int _pauseSilenceMs;

  final _chunkController = StreamController<Uint8List>.broadcast();
  final _pauseController = StreamController<int>.broadcast();
  final _voiceController = StreamController<bool>.broadcast();
  final _statusController = StreamController<AudioStreamStatus>.broadcast();

  StreamSubscription<Uint8List>? _streamSub;
  Timer? _silenceTimer;

  AudioStreamStatus _status = AudioStreamStatus.idle;
  String? _failureReason;
  DateTime? _lastVoiceAt;
  bool _voiceActive = false;
  bool _disposed = false;

  /// PCM16 chunk 流：调用方 `LiveLectureService` 应 base64 编码后再走 WS。
  Stream<Uint8List> get chunks => _chunkController.stream;

  /// 静音超过阈值时广播一次"silenceMs"数值（毫秒）。
  Stream<int> get pauses => _pauseController.stream;

  /// 是否检测到学生在说话（音量 > 阈值）。
  Stream<bool> get voiceActivity => _voiceController.stream;

  /// 内部状态流，对应 UI 三态：idle / listening / paused / permissionDenied / failed。
  Stream<AudioStreamStatus> get statusStream => _statusController.stream;

  AudioStreamStatus get status => _status;
  String? get failureReason => _failureReason;

  Future<bool> start() async {
    if (_disposed) return false;
    _failureReason = null;
    try {
      final granted = await _ensureMicrophonePermission();
      if (!granted) {
        _setStatus(AudioStreamStatus.permissionDenied);
        return false;
      }
      // 第九轮：用 16kHz / 16bit PCM，与后端 ASR pcm 格式约定一致。
      // 不用 wav / mp3：后端聚合窗口时需要纯 PCM 拼接，wav 会带头。
      const config = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      );
      final stream = await _recorder.startStream(config);
      _streamSub = stream.listen(
        _onAudioBytes,
        onError: (Object e, StackTrace st) {
          _setFailure('录音流异常：$e');
        },
        onDone: () {
          // 自然结束（如系统打断）—— 若仍在 listening 切到 idle
          if (_status == AudioStreamStatus.listening ||
              _status == AudioStreamStatus.paused) {
            _setStatus(AudioStreamStatus.idle);
          }
        },
        cancelOnError: false,
      );
      _setStatus(AudioStreamStatus.listening);
      _resetSilenceTimer();
      return true;
    } catch (e) {
      _setFailure('启动录音失败：$e');
      return false;
    }
  }

  Future<void> stop() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    // 先 stop 录音器让 record 包 flush 末段 PCM，再 cancel stream；
    // 反过来会先丢 listener，表现为「讲题结束」后 ASR 缺句尾。
    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {
      /* swallow */
    }
    try {
      await _streamSub?.cancel();
    } catch (_) {
      /* swallow */
    }
    _streamSub = null;
    _voiceActive = false;
    _lastVoiceAt = null;
    if (_status == AudioStreamStatus.listening ||
        _status == AudioStreamStatus.paused) {
      _setStatus(AudioStreamStatus.idle);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    try {
      await _recorder.dispose();
    } catch (_) {
      /* swallow */
    }
    await _chunkController.close();
    await _pauseController.close();
    await _voiceController.close();
    await _statusController.close();
  }

  Future<bool> _ensureMicrophonePermission() async {
    try {
      var status = await Permission.microphone.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) return false;
      status = await Permission.microphone.request();
      return status.isGranted;
    } catch (e) {
      // 桌面 / Web 上 permission_handler 可能不支持，回落到 recorder 自带检测
      try {
        return await _recorder.hasPermission();
      } catch (_) {
        return false;
      }
    }
  }

  void _onAudioBytes(Uint8List data) {
    if (data.isEmpty) return;
    if (!_chunkController.isClosed) {
      _chunkController.add(data);
    }
    final amplitude = _estimateRms(data);
    final hasVoice = amplitude > _voiceThreshold;
    if (hasVoice) {
      _lastVoiceAt = DateTime.now();
      if (!_voiceActive) {
        _voiceActive = true;
        if (!_voiceController.isClosed) _voiceController.add(true);
      }
      if (_status == AudioStreamStatus.paused) {
        _setStatus(AudioStreamStatus.listening);
      }
    }
  }

  /// 用一个独立 Timer 每 200ms 检查"上次说话时间到现在过了多久"，
  /// 而不是在每个 chunk 里 if 判定 —— Timer 节奏更稳，可控性更强,
  /// 不受 chunk 大小变化影响。
  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_disposed) return;
      if (_status != AudioStreamStatus.listening &&
          _status != AudioStreamStatus.paused) {
        return;
      }
      final last = _lastVoiceAt;
      if (last == null) return;
      final elapsed = DateTime.now().difference(last).inMilliseconds;
      if (elapsed >= _pauseSilenceMs) {
        if (_voiceActive) {
          _voiceActive = false;
          if (!_voiceController.isClosed) _voiceController.add(false);
        }
        if (_status != AudioStreamStatus.paused) {
          _setStatus(AudioStreamStatus.paused);
          if (!_pauseController.isClosed) _pauseController.add(elapsed);
        }
      }
    });
  }

  /// PCM16 little-endian 字节流的近似 RMS。不做 sqrt（线性比较即可），
  /// 比标准 RMS 省一次 sqrt，对阈值判定足够。
  int _estimateRms(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    final n = bytes.length ~/ 2;
    var sumSq = 0;
    // 采样最多 256 个 sample（≈8ms），避免每片几千次乘法。
    final step = (n / 256).ceil().clamp(1, n);
    var count = 0;
    for (var i = 0; i < bytes.length - 1; i += step * 2) {
      final low = bytes[i];
      final high = bytes[i + 1];
      var sample = low | (high << 8);
      if (sample >= 0x8000) sample -= 0x10000;
      sumSq += sample * sample;
      count += 1;
      if (count >= 256) break;
    }
    if (count == 0) return 0;
    final meanSq = sumSq ~/ count;
    return _intSqrt(meanSq);
  }

  int _intSqrt(int v) {
    if (v <= 0) return 0;
    var x = v;
    var y = (x + 1) ~/ 2;
    while (y < x) {
      x = y;
      y = (x + v ~/ x) ~/ 2;
    }
    return x;
  }

  void _setStatus(AudioStreamStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }

  void _setFailure(String reason) {
    _failureReason = reason;
    if (kDebugMode) {
      debugPrint('[AudioStreamService] failure: $reason');
    }
    _setStatus(AudioStreamStatus.failed);
    // 失败时主动 stop，避免半挂状态
    unawaited(stop());
  }
}

enum AudioStreamStatus {
  /// 未开启。
  idle,

  /// 正在采集且最近检测到声音。
  listening,

  /// 正在采集但持续静音（已超过 pause 阈值）。
  paused,

  /// 用户拒绝麦克风权限。
  permissionDenied,

  /// 录音库异常（设备不可用 / 平台不支持）。
  failed,
}
