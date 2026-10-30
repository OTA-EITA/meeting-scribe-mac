// Google Meet のタブに、MeetingScribe の字幕を重ねて出す。
// 文字はサイドパネルから届く。Meet の画面と混ざらないよう閉じた Shadow DOM の中に置き、
// 文字は textContent で入れて、文字起こしの中身をタグとして解釈させない。
(() => {
  const MAX_LINES = 4;
  const MAX_LENGTH = 500;
  const STYLE = `
    .captions {
      position: fixed;
      left: 50%;
      bottom: 104px;
      transform: translateX(-50%);
      z-index: 2147483647;
      max-width: min(880px, 90vw);
      padding: 8px 16px;
      border-radius: 10px;
      background: rgba(0, 0, 0, 0.72);
      color: #fff;
      font: 18px/1.5 -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif;
      pointer-events: none;
    }
    .captions[hidden] { display: none; }
    .captions p { margin: 0; }
  `;

  let box = null;

  function ensureBox() {
    if (box) return box;
    const host = document.createElement('div');
    host.id = 'meetingscribe-captions';
    const root = host.attachShadow({ mode: 'closed' });
    const style = document.createElement('style');
    style.textContent = STYLE;
    box = document.createElement('div');
    box.className = 'captions';
    box.hidden = true;
    root.append(style, box);
    document.documentElement.append(host);
    return box;
  }

  function show(lines) {
    const el = ensureBox();
    el.replaceChildren(...lines.map((line) => {
      const p = document.createElement('p');
      p.textContent = line;
      return p;
    }));
    el.hidden = lines.length === 0;
  }

  chrome.runtime.onMessage.addListener((message, sender) => {
    if (sender.id !== chrome.runtime.id || message?.type !== 'meetingscribe-captions') return;
    const lines = Array.isArray(message.lines) ? message.lines : [];
    show(lines
      .filter((line) => typeof line === 'string')
      .slice(-MAX_LINES)
      .map((line) => line.slice(0, MAX_LENGTH)));
  });
})();
