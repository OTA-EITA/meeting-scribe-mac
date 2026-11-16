import { initialState, applyMessage, disconnected, controlMessage, captionLines } from './transcript-state.js';

// エンジン(TranscriptionServer)の待ち受け先。アプリ側の TranscriptionServer.port と合わせる。
const ENGINE_URL = 'ws://127.0.0.1:8765';
const RECONNECT_DELAY_MS = 1000;
const MEET_TABS = 'https://meet.google.com/*';

const statusEl = document.getElementById('status');
const warningEl = document.getElementById('warning');
const recordButton = document.getElementById('record');
const transcriptEl = document.getElementById('transcript');
const copyButton = document.getElementById('copy');
const savedEl = document.getElementById('saved');
const meetCaptionsEl = document.getElementById('meet-captions');

let state = initialState();
let socket = null;
let lastCaptionKey = null;

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
  relayCaptions();
}

/// 字幕が変わったときだけ、開いている Google Meet のタブへ送る。
/// 拡張機能を入れる前から開いていたタブには受け手がいないので、送れなくても無視する。
async function relayCaptions() {
  const lines = meetCaptionsEl.checked ? captionLines(state) : [];
  const key = JSON.stringify(lines);
  if (key === lastCaptionKey) return;
  lastCaptionKey = key;
  const tabs = await chrome.tabs.query({ url: MEET_TABS });
  for (const tab of tabs) {
    chrome.tabs.sendMessage(tab.id, { type: 'meetingscribe-captions', lines }).catch(() => {});
  }
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

meetCaptionsEl.addEventListener('change', () => {
  chrome.storage.local.set({ meetCaptions: meetCaptionsEl.checked });
  relayCaptions();
});

const { meetCaptions } = await chrome.storage.local.get({ meetCaptions: true });
meetCaptionsEl.checked = meetCaptions;
render();
connect();
