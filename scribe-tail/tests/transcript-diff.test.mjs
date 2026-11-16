import { test } from "node:test";
import assert from "node:assert/strict";
import { TranscriptDiff, parseTranscript } from "../transcript-diff.mjs";

// タイマーを手で進められるようにする
function makeDiff(options = {}) {
  const lines = [];
  let pending;
  const diff = new TranscriptDiff({
    onLine: (line, meta) => lines.push(meta.revised ? `(訂正) ${line}` : line),
    setTimer: (fn) => (pending = fn),
    clearTimer: () => (pending = undefined),
    ...options,
  });
  return { diff, lines, fireIdle: () => pending?.() };
}

test("ラベルと改行を除いた本文と、各行の始まりに分ける", () => {
  const parsed = parseTranscript("[00:00:01] [自分] はい\n[00:00:03] 続き\n[相手1] どうも");
  assert.equal(parsed.content, "はい続きどうも");
  assert.deepEqual(parsed.lines, [
    { start: 0, label: "自分", timestamp: "[00:00:01] " },
    { start: 2, label: "自分", timestamp: "[00:00:03] " },
    { start: 4, label: "相手1", timestamp: "" },
  ]);
});

test("話者が切り替わったら、前の話者の行をすぐ出す", () => {
  const { diff, lines } = makeDiff();
  diff.update("[自分] こんにちは");
  diff.update("[自分] こんにちは\n[相手1] よろしく");
  assert.deepEqual(lines, ["[自分] こんにちは"]);
});

test("伸びている途中の行は、話が途切れてから出す", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("[自分] 今日は");
  diff.update("[自分] 今日は議題が三つあります");
  assert.deepEqual(lines, []);
  fireIdle();
  assert.deepEqual(lines, ["[自分] 今日は議題が三つあります"]);
});

test("一度出した部分は繰り返さず、続きだけを同じラベルで出す", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("[自分] 一つ目は");
  fireIdle();
  diff.update("[自分] 一つ目は予算です");
  fireIdle();
  assert.deepEqual(lines, ["[自分] 一つ目は", "[自分] 予算です"]);
});

test("長く話し続けても、決めた長さで区切って出す", () => {
  const { diff, lines } = makeDiff({ maxChars: 10 });
  diff.update("あいうえおかきくけこさしすせそ");
  assert.deepEqual(lines, ["あいうえおかきくけこ"]);
});

test("ラベルや行の分かれ方だけが変わっても、出し直さない", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("[相手1] 一つ目は頑張りすぎる");
  fireIdle();
  diff.update("[相手1] 一つ目は頑張りすぎる\n[相手2] 二つ目は");
  diff.update("[相手2] 一つ目は頑張りすぎる二つ目は話しすぎる");
  fireIdle();
  assert.deepEqual(lines, ["[相手1] 一つ目は頑張りすぎる", "[相手2] 二つ目は話しすぎる"]);
});

test("出した本文が書き換わったら、そのかたまりの頭から訂正として出す", () => {
  const { diff, lines, fireIdle } = makeDiff({ maxChars: 6 });
  diff.update("[相手1] あいうえおかきくけこさしすせそ");
  fireIdle();
  assert.deepEqual(lines, ["[相手1] あいうえおか", "[相手1] きくけこさし", "[相手1] すせそ"]);
  diff.update("[相手1] あいうえおかきくけこサシスセソ");
  fireIdle();
  assert.deepEqual(lines.slice(3), ["(訂正) [相手1] きくけこサシ", "[相手1] スセソ"]);
});

test("まだ出していない部分が書き換わっても、訂正にはしない", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("[自分] 予算はさん");
  diff.update("[自分] 予算は三百万です");
  fireIdle();
  assert.deepEqual(lines, ["[自分] 予算は三百万です"]);
});

test("reset のあとは最初から数え直す", () => {
  const { diff, lines } = makeDiff();
  diff.update("[自分] 一回目\n[相手1] x");
  diff.reset();
  diff.update("[自分] 二回目\n[相手1] y");
  assert.deepEqual(lines, ["[自分] 一回目", "[自分] 二回目"]);
});

test("空白だけの行は出さない", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("  \n本題");
  fireIdle();
  assert.deepEqual(lines, ["本題"]);
});
