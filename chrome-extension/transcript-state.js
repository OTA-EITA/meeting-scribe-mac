// MeetingScribe のエンジンから届くメッセージを、サイドパネルに表示する状態へ畳み込む。
// アプリ内の TranscriptClient.swift と同じ規則で動かす。画面の操作から切り離し、
// Node の単体テストで確かめられるようにしている。

const NOT_RUNNING = 'MeetingScribe が起動していません。Mac のアプリを起動してください。';

export function initialState() {
  return {
    connected: false,
    statusText: 'MeetingScribe に接続しています…',
    isModelLoading: true,
    isRecording: false,
    isDiarizing: false,
    warningText: null,
    confirmedText: '',
    unconfirmedText: '',
    transcript: '',
    lastExportPath: null,
  };
}

export function applyMessage(state, message) {
  const next = { ...state, connected: true };
  switch (message.type) {
    case 'status':
      return applyStatus(next, message);
    case 'transcript':
      next.confirmedText = message.confirmedText ?? next.confirmedText;
      next.unconfirmedText = message.unconfirmedText ?? '';
      return next;
    case 'error':
      next.statusText = message.message ?? 'エラーが発生しました';
      return next;
    case 'warning':
      next.warningText = message.message ?? null;
      return next;
    default:
      return next;
  }
}

function applyStatus(state, message) {
  switch (message.status) {
    case 'modelLoading':
      return { ...state, isModelLoading: true, statusText: 'モデルを準備しています…' };
    case 'ready':
      return { ...state, isModelLoading: false, isRecording: false, statusText: '準備完了。録音を開始してください。' };
    case 'recording':
      return { ...state, isModelLoading: false, isRecording: true, confirmedText: '', unconfirmedText: '', warningText: null, statusText: '録音中…' };
    case 'diarizing':
      return { ...state, isRecording: false, isDiarizing: true, statusText: '話者を分析しています…' };
    case 'stopped': {
      const session = (state.confirmedText + state.unconfirmedText).trim();
      return {
        ...state,
        isRecording: false,
        isDiarizing: false,
        transcript: appendSession(state.transcript, session),
        confirmedText: '',
        unconfirmedText: '',
        lastExportPath: message.message ?? null,
        statusText: '完了。続けて録音できます。',
      };
    }
    default:
      return state;
  }
}

function appendSession(transcript, session) {
  if (!session) return transcript;
  return transcript ? `${transcript}\n${session}` : session;
}

/// 接続が切れたときの状態。それまでの文字起こしは残す。
export function disconnected(state) {
  return {
    ...state,
    connected: false,
    isModelLoading: true,
    isRecording: false,
    isDiarizing: false,
    confirmedText: '',
    unconfirmedText: '',
    statusText: NOT_RUNNING,
  };
}

/// 画面に出すテキスト。録音中は、それまでの全文の後ろにライブの文字を続ける。
export function displayedText(state) {
  const live = state.confirmedText + state.unconfirmedText;
  if (!live) return state.transcript;
  return state.transcript ? `${state.transcript}\n${live}` : live;
}

export function controlMessage(action) {
  return JSON.stringify({ type: 'control', action });
}

const CAPTION_LINE_LENGTH = 80;

/// Google Meet に重ねる字幕の行。録音中のライブの文字の最後の数行だけを出し、
/// 録音していないときは何も出さない。長い行は末尾だけを残す。
export function captionLines(state, maxLines = 2) {
  if (!state.isRecording) return [];
  return (state.confirmedText + state.unconfirmedText)
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line)
    .slice(-maxLines)
    .map((line) => (line.length > CAPTION_LINE_LENGTH ? `…${line.slice(-CAPTION_LINE_LENGTH)}` : line));
}
