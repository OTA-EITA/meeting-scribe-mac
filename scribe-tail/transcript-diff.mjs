// エンジンは transcript のたびに、確定した文字起こしを最初から全部送ってくる。
// 同じ話者が話し続ける間は最後の行が伸びていくので、前回との差分だけを取り出し、
// 話者の切り替わり・一定時間の無音・一定の長さのいずれかで区切って 1 行ずつ渡す。
//
// 録音中は話者分離をくり返すので、[相手1] と [相手2] のようなラベルや行の分かれ方は
// 何度も変わる。そのたびに出し直すと同じ話が何度も流れるので、書き換わったかどうかは
// ラベルと改行を除いた本文だけで比べる。本文が書き換わったとき(末尾の言い直しなど)だけ、
// その位置を含むかたまりの頭から訂正として出し直す。正しい話者は停止後の議事録で確かめる。

export const DEFAULT_IDLE_MS = 2500;
export const DEFAULT_MAX_CHARS = 120;

// 行頭の "[00:12:34] [相手1] " や "[00:12:34] "
const LABELED_LINE = /^((?:\[\d{2}:\d{2}:\d{2}\] )?)\[(?!\d{2}:\d{2}:\d{2}\])([^\]\n]+)\] /;
const TIMESTAMP_ONLY = /^\[\d{2}:\d{2}:\d{2}\] /;

function commonPrefixLength(a, b) {
  const n = Math.min(a.length, b.length);
  let i = 0;
  while (i < n && a[i] === b[i]) i++;
  return i;
}

// 文字起こしを、ラベルと改行を除いた本文と、本文の中での各行の始まりに分ける
export function parseTranscript(text) {
  let content = "";
  const lines = [];
  let label = null;
  for (const raw of text.split("\n")) {
    let body = raw;
    let timestamp = "";
    const labeled = raw.match(LABELED_LINE);
    if (labeled) {
      timestamp = labeled[1];
      label = labeled[2];
      body = raw.slice(labeled[0].length);
    } else {
      const stamp = raw.match(TIMESTAMP_ONLY);
      if (stamp) {
        timestamp = stamp[0];
        body = raw.slice(stamp[0].length);
      }
    }
    if (body.length === 0) continue;
    lines.push({ start: content.length, label, timestamp });
    content += body;
  }
  return { content, lines };
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
    this.content = "";
    this.lines = [];
    // 本文のうち、ここまでを出し終えた
    this.emittedEnd = 0;
    // 出したかたまりそれぞれの、本文の中での始まりの位置
    this.chunkStarts = [];
    this.revised = false;
  }

  update(confirmedText) {
    const { content, lines } = parseTranscript(confirmedText ?? "");
    const prefix = commonPrefixLength(this.content, content);
    if (prefix < this.emittedEnd) {
      const start = this.chunkStarts.filter((s) => s <= prefix).pop() ?? 0;
      this.chunkStarts = this.chunkStarts.filter((s) => s < start);
      this.emittedEnd = start;
      this.revised = true;
    }
    this.content = content;
    this.lines = lines;
    this.drain();
  }

  drain() {
    for (;;) {
      const nextLine = this.lines.find((line) => line.start > this.emittedEnd);
      const end = nextLine ? nextLine.start : this.content.length;
      if (end - this.emittedEnd >= this.maxChars) {
        this.emit(this.emittedEnd + this.maxChars);
      } else if (nextLine) {
        this.emit(nextLine.start);
      } else {
        break;
      }
    }
    this.clearIdle();
    if (this.emittedEnd < this.content.length) {
      this.idleTimer = this.setTimer(() => this.flush(), this.idleMs);
    }
  }

  flush() {
    this.clearIdle();
    if (this.emittedEnd < this.content.length) this.emit(this.content.length);
  }

  emit(end) {
    const start = this.emittedEnd;
    const body = this.content.slice(start, end).trim();
    this.emittedEnd = end;
    if (body.length === 0) return;
    this.chunkStarts.push(start);
    const revised = this.revised;
    this.revised = false;
    this.onLine(this.prefixFor(start) + body, { revised });
  }

  // かたまりの頭に付けるラベル。行の途中から始まるかたまりには経過時間を付けない
  prefixFor(start) {
    const line = this.lines.filter((l) => l.start <= start).pop();
    if (!line) return "";
    const timestamp = line.start === start ? line.timestamp : "";
    return timestamp + (line.label ? `[${line.label}] ` : "");
  }

  clearIdle() {
    if (this.idleTimer !== undefined) this.clearTimer(this.idleTimer);
    this.idleTimer = undefined;
  }
}
