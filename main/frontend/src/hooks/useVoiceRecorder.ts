import { useState, useRef, useCallback } from "react";

interface RecorderState {
  isRecording: boolean;
  duration: number; // seconds
  error: string | null;
}

function writeString(view: DataView, offset: number, string: string) {
  for (let i = 0; i < string.length; i++) {
    view.setUint8(offset + i, string.charCodeAt(i));
  }
}

function floatTo16BitPCM(
  output: DataView,
  offset: number,
  input: Float32Array
) {
  for (let i = 0; i < input.length; i++, offset += 2) {
    const s = Math.max(-1, Math.min(1, input[i]));
    output.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
}

function encodeWAV(
  samples: Float32Array,
  sampleRate: number,
  numChannels: number
): ArrayBuffer {
  const bytesPerSample = 2;
  const blockAlign = numChannels * bytesPerSample;
  const dataSize = samples.length * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);

  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, "WAVE");
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);
  writeString(view, 36, "data");
  view.setUint32(40, dataSize, true);
  floatTo16BitPCM(view, 44, samples);

  return buffer;
}

function downsampleBuffer(
  buffer: Float32Array,
  srcSampleRate: number,
  targetSampleRate: number
): Float32Array {
  if (targetSampleRate === srcSampleRate) return buffer;
  const ratio = srcSampleRate / targetSampleRate;
  const newLength = Math.round(buffer.length / ratio);
  const result = new Float32Array(newLength);
  for (let i = 0; i < newLength; i++) {
    result[i] = buffer[Math.round(i * ratio)];
  }
  return result;
}

export function useVoiceRecorder(onComplete: (base64Wav: string) => void) {
  const [state, setState] = useState<RecorderState>({
    isRecording: false,
    duration: 0,
    error: null,
  });

  const mediaRef = useRef<MediaStream | null>(null);
  const contextRef = useRef<AudioContext | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const buffersRef = useRef<Float32Array[]>([]);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const startTimeRef = useRef<number>(0);
  const sampleRateRef = useRef<number>(16000);

  const startRecording = useCallback(async () => {
    try {
      setState({ isRecording: false, duration: 0, error: null });
      buffersRef.current = [];

      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      mediaRef.current = stream;

      const audioContext = new AudioContext({ sampleRate: 16000 });
      contextRef.current = audioContext;
      sampleRateRef.current = audioContext.sampleRate;

      const source = audioContext.createMediaStreamSource(stream);
      sourceRef.current = source;

      // 4096 samples buffer, 16000Hz => ~256ms per buffer
      const processor = audioContext.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      processor.onaudioprocess = (e) => {
        const channelData = e.inputBuffer.getChannelData(0);
        buffersRef.current.push(new Float32Array(channelData));
      };

      source.connect(processor);
      processor.connect(audioContext.destination);

      startTimeRef.current = Date.now();
      timerRef.current = setInterval(() => {
        const dur = Math.round((Date.now() - startTimeRef.current) / 1000);
        setState((prev) => ({ ...prev, duration: dur }));
      }, 1000);

      setState({ isRecording: true, duration: 0, error: null });
    } catch (err: any) {
      let msg = err.message || String(err);
      if (err.name === "NotAllowedError") {
        msg = "麦克风权限被拒绝，请检查浏览器权限设置";
      } else if (err.name === "NotFoundError") {
        msg = "未找到麦克风设备";
      }
      setState({ isRecording: false, duration: 0, error: msg });
    }
  }, []);

  const stopRecording = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }

    if (processorRef.current && sourceRef.current) {
      sourceRef.current.disconnect(processorRef.current);
      processorRef.current.disconnect();
      processorRef.current.onaudioprocess = null;
      processorRef.current = null;
      sourceRef.current = null;
    }

    if (contextRef.current) {
      contextRef.current.close();
      contextRef.current = null;
    }

    if (mediaRef.current) {
      mediaRef.current.getTracks().forEach((t) => t.stop());
      mediaRef.current = null;
    }

    const buffers = buffersRef.current;
    buffersRef.current = [];

    if (buffers.length === 0) {
      setState({ isRecording: false, duration: 0, error: null });
      return;
    }

    // Merge buffers
    const totalLength = buffers.reduce((sum, b) => sum + b.length, 0);
    const merged = new Float32Array(totalLength);
    let offset = 0;
    for (const b of buffers) {
      merged.set(b, offset);
      offset += b.length;
    }

    // Web Audio API 可能不支持所有浏览器的 16000 sampleRate，做兜底降采样
    const actualRate = sampleRateRef.current;
    const finalBuffer = downsampleBuffer(merged, actualRate, 16000);

    const wavBuffer = encodeWAV(finalBuffer, 16000, 1);
    const blob = new Blob([wavBuffer], { type: "audio/wav" });

    const reader = new FileReader();
    reader.onloadend = () => {
      const base64 = (reader.result as string).split(",")[1];
      setState({ isRecording: false, duration: 0, error: null });
      onComplete(base64);
    };
    reader.readAsDataURL(blob);
  }, [onComplete]);

  const toggleRecording = useCallback(() => {
    if (state.isRecording) {
      stopRecording();
    } else {
      startRecording();
    }
  }, [state.isRecording, startRecording, stopRecording]);

  return {
    isRecording: state.isRecording,
    duration: state.duration,
    error: state.error,
    toggleRecording,
    startRecording,
    stopRecording,
  };
}
