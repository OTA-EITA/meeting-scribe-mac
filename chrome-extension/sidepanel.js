import { initialState, applyMessage, disconnected, controlMessage } from './transcript-state.js';

// エンジン(TranscriptionServer)の待ち受け先。アプリ側の TranscriptionServer.port と合わせる。
const ENGINE_URL = 'ws://127.0.0.1:8765';
const RECONNECT_DELAY_MS = 1000;

const statusEl = document.getElementById('status');
const warningEl = document.getElementById('warning');
const recordButton = document.getElementById('record');
const transcriptEl = document.getElementById('transcript');
const copyButton = document.getElementById('copy');
const savedEl = document.getElementById('saved');

let state = initialState();
let socket = null;

function connect() {
  socket = new WebSocket(ENGINE_URL);
  socket.addEventListener('message', (event) => {
    try {
      update(applyMessage(state, JSON.parse(event.data)));
    } catch (error) {
      console.error('MeetingScribe: メッセージを読めませんでした', error);
    }
  });
  socket.addEventListener('close', () => {
    socket = null;
    update(disconnected(state));
    setTimeout(connect, RECONNECT_DELAY_MS);
  });
}

function update(next) {
  state = next;
  render();
}

function render() {
  statusEl.textContent = state.statusText;
  warningEl.textContent = state.warningText ?? '';
  warningEl.hidden = !state.warningText;

  recordButton.textContent = state.isRecording ? '停止する' : '録音を開始';
  recordButton.classList.toggle('recording', state.isRecording);
  recordButton.disabled = !state.connected || state.isModelLoading || state.isDiarizing;

  const live = state.confirmedText + state.unconfirmedText;
  const atBottom = transcriptEl.scrollHeight - transcriptEl.scrollTop - transcriptEl.clientHeight < 24;
  transcriptEl.replaceChildren();
  if (!state.transcript && !live) {
    const placeholder = document.createElement('p');
    placeholder.className = 'placeholder';
    placeholder.textContent = 'ここに文字起こし結果が表示されます。';
    transcriptEl.append(placeholder);
  } else {
    if (state.transcript) {
      transcriptEl.append(document.createTextNode(state.transcript + (live ? '\n' : '')));
    }
    if (live) {
      const liveEl = document.createElement('span');
      liveEl.className = 'live';
      liveEl.textContent = live;
      transcriptEl.append(liveEl);
    }
  }
  if (atBottom) {
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
  }

  copyButton.disabled = !state.transcript;
  savedEl.textContent = state.lastExportPath ? `保存先: ${state.lastExportPath}` : '';
  savedEl.title = state.lastExportPath ?? '';
}

recordButton.addEventListener('click', () => {
  if (socket?.readyState !== WebSocket.OPEN) return;
  socket.send(controlMessage(state.isRecording ? 'stop' : 'start'));
});

copyButton.addEventListener('click', async () => {
  await navigator.clipboard.writeText(state.transcript);
  copyButton.textContent = 'コピーしました';
  setTimeout(() => { copyButton.textContent = 'コピー'; }, 1500);
});

render();
connect();
