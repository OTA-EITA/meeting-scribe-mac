import { test } from "node:test";
import assert from "node:assert/strict";
import { TranscriptDiff } from "../transcript-diff.mjs";

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

test("改行で区切れた行はすぐ出す", () => {
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

test("一度出した部分は繰り返さず、続きだけを出す", () => {
  const { diff, lines, fireIdle } = makeDiff();
  diff.update("[自分] 一つ目は");
  fireIdle();
  diff.update("[自分] 一つ目は予算です");
  fireIdle();
  assert.deepEqual(lines, ["[自分] 一つ目は", "予算です"]);
});

test("長く話し続けても、決めた長さで区切って出す", () => {
  const { diff, lines } = makeDiff({ maxChars: 10 });
  diff.update("あいうえおかきくけこさしすせそ");
  assert.deepEqual(lines, ["あいうえおかきくけこ"]);
});

test("前に送った部分が書き換わったら、その行の頭から訂正として出す", () => {
  const { diff, lines } = makeDiff();
  diff.update("[自分] はい\n[不明] 了解です\n");
  diff.update("[自分] はい\n[相手1] 了解です\n");
  assert.deepEqual(lines, ["[自分] はい", "[不明] 了解です", "(訂正) [相手1] 了解です"]);
});

test("reset のあとは最初から数え直す", () => {
  const { diff, lines } = makeDiff();
  diff.update("一回目\n");
  diff.reset();
  diff.update("二回目\n");
  assert.deepEqual(lines, ["一回目", "二回目"]);
});

test("空白だけの行は出さない", () => {
  const { diff, lines } = makeDiff();
  diff.update("  \n本題\n");
  assert.deepEqual(lines, ["本題"]);
});
