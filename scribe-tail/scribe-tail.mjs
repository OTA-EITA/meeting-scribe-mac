#!/usr/bin/env node
// 文字起こしエンジン(Mac 版・Windows 版のどちらでも)のローカル WebSocket につなぎ、
// 確定した文字起こしを 1 行ずつ標準出力に流す。tail -f のように、他のツールへ
// 会議の内容をそのまま渡すために使う。
//
//   node scribe-tail.mjs [--port 8765] [--out meeting.log] [--status] [--others-only] [--fast]
//
// Origin ヘッダーを付けないので、エンジンの OriginPolicy はアプリ内のクライアントと同じ扱いで通す。

import { appendFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { TranscriptDiff } from "./transcript-diff.mjs";

const { values: args } = parseArgs({
  options: {
    port: { type: "string", default: "8765" },
    out: { type: "string" },
    status: { type: "boolean", default: false },
    "others-only": { type: "boolean", default: false },
    fast: { type: "boolean", default: false },
    "idle-ms": { type: "string" },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (args.help) {
  console.log(`使い方: scribe-tail [--port 8765] [--out FILE] [--status] [--others-only] [--fast] [--idle-ms 2500]

  --port         エンジンのポート(既定 8765)
  --out          出力した行をこのファイルにも追記する
  --status       録音の開始・停止・保存先も行頭 # で出す
  --others-only  相手の発言だけを出す(自分の発言は出さない)
  --fast         確定前の部分も出す。短く話して黙ってもすぐ出るが、言い直しで (訂正) が増える
  --idle-ms      話が途切れてから、伸びている途中の行を出すまでの時間`);
  process.exit(0);
}

const url = `ws://127.0.0.1:${args.port}`;
const RETRY_MS = 2000;

function clock() {
  return new Date().toTimeString().slice(0, 8);
}

function write(line) {
  process.stdout.write(line + "\n");
  if (args.out) appendFileSync(args.out, line + "\n");
}

function notice(text) {
  if (args.status) write(`# ${clock()} ${text}`);
}

// 録音中に流した行の数。Windows 版は停止してからまとめて文字起こしするので、録音中は 0 のまま
let linesWhileRecording = 0;
// 停止後に送り直される全文を待っているところ
let afterStop = false;

// 録音中の相手のラベルは「相手」「相手1」…か、話者が分からないときの「不明」
const OTHERS_LABEL = /^(相手|不明)/;
const LINE_LABEL = /^(?:\[\d{2}:\d{2}:\d{2}\] )?\[([^\]]+)\]/;

function isOthers(line) {
  const label = line.match(LINE_LABEL)?.[1];
  return label === undefined || OTHERS_LABEL.test(label);
}

const diff = new TranscriptDiff({
  idleMs: args["idle-ms"] ? Number(args["idle-ms"]) : undefined,
  onLine: (line, { revised }) => {
    if (!afterStop) linesWhileRecording++;
    if (args["others-only"] && !isOthers(line)) return;
    write(`${clock()} ${revised ? "(訂正) " : ""}${line}`);
  },
});

const STATUS_TEXT = {
  modelLoading: "モデルを読み込み中",
  ready: "待機中",
  recording: "録音開始",
  diarizing: "話者を分けています",
};

function handle(message) {
  switch (message.type) {
    case "transcript":
      if (afterStop) {
        // 停止後の全文。録音中に流し終えていれば二重になるので捨て、何も流していなければここで流す
        if (linesWhileRecording === 0) {
          diff.update(message.confirmedText);
          diff.flush();
        }
        break;
      }
      // --fast のときは確定前の部分まで含む liveText を使う。無いエンジン(Windows 版など)は確定した分だけ
      diff.update((args.fast && message.liveText) || message.confirmedText);
      break;
    case "status":
      if (message.status === "recording") {
        diff.reset();
        linesWhileRecording = 0;
        afterStop = false;
        notice(STATUS_TEXT.recording);
      } else if (message.status === "diarizing") {
        // 停止すると、話者分離(Windows 版は文字起こし)のあとで全文が送り直される
        diff.flush();
        diff.reset();
        afterStop = true;
        notice(STATUS_TEXT.diarizing);
      } else if (message.status === "stopped") {
        diff.flush();
        notice(message.message ? `録音停止 保存先: ${message.message}` : "録音停止");
      } else if (STATUS_TEXT[message.status]) {
        notice(STATUS_TEXT[message.status]);
      }
      break;
    case "warning":
    case "error":
      notice(`${message.type === "error" ? "エラー" : "注意"}: ${message.message ?? ""}`);
      break;
  }
}

let connectedOnce = false;
let waitingNoticed = false;

function connect() {
  const socket = new WebSocket(url);
  let opened = false;

  socket.addEventListener("open", () => {
    opened = true;
    waitingNoticed = false;
    notice(connectedOnce ? "エンジンにつなぎ直しました" : `エンジンにつなぎました (${url})`);
    connectedOnce = true;
  });

  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    handle(message);
  });

  socket.addEventListener("close", () => {
    diff.flush();
    if (opened) notice("エンジンとの接続が切れました。つなぎ直します");
    else if (!waitingNoticed) {
      notice(`エンジンが起動していません (${url})。起動を待ちます`);
      waitingNoticed = true;
    }
    setTimeout(connect, RETRY_MS);
  });

  // close も続けて来るので、つなぎ直しはそちらに任せる
  socket.addEventListener("error", () => {});
}

process.on("SIGINT", () => {
  diff.flush();
  process.exit(0);
});

connect();
