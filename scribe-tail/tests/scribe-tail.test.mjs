import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const cli = fileURLToPath(new URL("../scribe-tail.mjs", import.meta.url));

// エンジンの代わりに、つないできた相手へ決めたメッセージを送るだけの WebSocket サーバー
function fakeEngine(messages) {
  const server = createServer();
  const seen = { origin: "unset" };
  server.on("upgrade", (req, socket) => {
    seen.origin = req.headers.origin;
    const accept = createHash("sha1")
      .update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      .digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    for (const message of messages) {
      const payload = Buffer.from(JSON.stringify(message));
      const header =
        payload.length < 126
          ? Buffer.from([0x81, payload.length])
          : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]);
      socket.write(Buffer.concat([header, payload]));
    }
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, seen, port: server.address().port })));
}

function run(port, extraArgs, until) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cli, "--port", String(port), "--idle-ms", "50", ...extraArgs]);
    let out = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`時間切れ。ここまでの出力:\n${out}`));
    }, 5000);
    child.stdout.on("data", (chunk) => {
      out += chunk;
      if (until(out)) {
        clearTimeout(timer);
        child.kill();
        resolve(out.trim().split("\n").map((line) => line.replace(/^(# )?\d\d:\d\d:\d\d /, "$1")));
      }
    });
  });
}

test("録音中の文字起こしを 1 行ずつ流し、停止後の全文は二重に出さない (Mac 版)", async () => {
  const { server, seen, port } = await fakeEngine([
    { type: "status", status: "recording" },
    { type: "transcript", confirmedText: "[自分] 始めます", unconfirmedText: "" },
    { type: "transcript", confirmedText: "[自分] 始めます\n[相手1] お願いします", unconfirmedText: "" },
    { type: "status", status: "diarizing" },
    { type: "transcript", confirmedText: "[自分] 始めます\n[相手1] お願いします", unconfirmedText: "" },
    { type: "status", status: "stopped", message: "/tmp/会議.txt" },
  ]);
  try {
    const lines = await run(port, ["--status"], (out) => out.includes("録音停止"));
    assert.deepEqual(lines, [
      `# エンジンにつなぎました (ws://127.0.0.1:${port})`,
      "# 録音開始",
      "[自分] 始めます",
      "[相手1] お願いします",
      "# 話者を分けています",
      "# 録音停止 保存先: /tmp/会議.txt",
    ]);
    assert.equal(seen.origin, undefined, "Origin を付けるとエンジンに断られる");
  } finally {
    server.close();
  }
});

test("録音中に何も届かなければ、停止後の全文を流す (Windows 版)", async () => {
  const { server, port } = await fakeEngine([
    { type: "status", status: "recording" },
    { type: "status", status: "diarizing", message: "文字起こししています…" },
    { type: "transcript", confirmedText: "[00:00:01] [自分] 始めます\n[00:00:04] [相手1] お願いします", unconfirmedText: "" },
    { type: "status", status: "stopped" },
  ]);
  try {
    const lines = await run(port, [], (out) => out.includes("お願いします"));
    assert.deepEqual(lines, ["[00:00:01] [自分] 始めます", "[00:00:04] [相手1] お願いします"]);
  } finally {
    server.close();
  }
});
