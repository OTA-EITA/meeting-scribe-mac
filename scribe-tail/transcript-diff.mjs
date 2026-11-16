// エンジンは transcript のたびに、確定した文字起こしを最初から全部送ってくる。
// 同じ話者が話し続ける間は最後の行が伸びていくので、前回との差分だけを取り出し、
// 改行・一定時間の無音・一定の長さのいずれかで区切って 1 行ずつ渡す。

export const DEFAULT_IDLE_MS = 2500;
export const DEFAULT_MAX_CHARS = 120;

function commonPrefixLength(a, b) {
  const n = Math.min(a.length, b.length);
  let i = 0;
  while (i < n && a[i] === b[i]) i++;
  return i;
}

export class TranscriptDiff {
  constructor({ onLine, idleMs = DEFAULT_IDLE_MS, maxChars = DEFAULT_MAX_CHARS, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
    this.onLine = onLine;
    this.idleMs = idleMs;
    this.maxChars = maxChars;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.reset();
  }

  reset() {
    this.clearIdle();
    this.previous = "";
    this.buffer = "";
  }

  // confirmedText を受け取り、増えた分をバッファに積む
  update(confirmedText) {
    const text = confirmedText ?? "";
    const prefix = commonPrefixLength(this.previous, text);
    if (prefix < this.previous.length) {
      // 前に送った内容が書き換わった(話者ラベルの付け替えなど)。書き換わった行の頭からもう一度出す
      this.flush();
      const lineStart = text.lastIndexOf("\n", prefix - 1) + 1;
      this.buffer = text.slice(lineStart);
      this.revised = true;
    } else {
      this.buffer += text.slice(prefix);
    }
    this.previous = text;
    this.drain();
  }

  drain() {
    let newline;
    while ((newline = this.buffer.indexOf("\n")) !== -1) {
      this.emit(this.buffer.slice(0, newline));
      this.buffer = this.buffer.slice(newline + 1);
    }
    while (this.buffer.length >= this.maxChars) {
      this.emit(this.buffer.slice(0, this.maxChars));
      this.buffer = this.buffer.slice(this.maxChars);
    }
    this.clearIdle();
    if (this.buffer.length > 0) {
      this.idleTimer = this.setTimer(() => this.flush(), this.idleMs);
    }
  }

  flush() {
    this.clearIdle();
    if (this.buffer.length > 0) this.emit(this.buffer);
    this.buffer = "";
  }

  emit(line) {
    const trimmed = line.trim();
    const revised = this.revised === true;
    this.revised = false;
    if (trimmed.length > 0) this.onLine(trimmed, { revised });
  }

  clearIdle() {
    if (this.idleTimer !== undefined) this.clearTimer(this.idleTimer);
    this.idleTimer = undefined;
  }
}
