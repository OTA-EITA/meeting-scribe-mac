import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initialState, applyMessage, disconnected, displayedText, controlMessage } from '../transcript-state.js';

const status = (s, message) => ({ type: 'status', status: s, ...(message ? { message } : {}) });

test('starts disconnected', () => {
  assert.equal(initialState().statusText, 'MeetingScribe に接続しています…');
  assert.equal(initialState().connected, false);
});

test('becomes ready after the model loads', () => {
  let state = applyMessage(initialState(), status('modelLoading'));
  assert.equal(state.isModelLoading, true);
  state = applyMessage(state, status('ready'));
  assert.equal(state.isModelLoading, false);
  assert.equal(state.connected, true);
  assert.equal(state.statusText, '準備完了。録音を開始してください。');
});

test('shows live text while recording and keeps the final text after stopping', () => {
  let state = applyMessage(initialState(), status('ready'));
  state = applyMessage(state, status('recording'));
  state = applyMessage(state, { type: 'transcript', confirmedText: '[自分] こんにちは', unconfirmedText: '今日は' });
  assert.equal(displayedText(state), '[自分] こんにちは今日は');

  state = applyMessage(state, status('diarizing'));
  state = applyMessage(state, { type: 'transcript', confirmedText: '[00:00:01] [自分] こんにちは今日は', unconfirmedText: '' });
  state = applyMessage(state, status('stopped', '/tmp/議事録.txt'));
  assert.equal(state.isRecording, false);
  assert.equal(state.transcript, '[00:00:01] [自分] こんにちは今日は');
  assert.equal(state.lastExportPath, '/tmp/議事録.txt');
  assert.equal(displayedText(state), '[00:00:01] [自分] こんにちは今日は');
});

test('appends each session to the transcript', () => {
  let state = { ...initialState(), transcript: '一回目' };
  state = applyMessage(state, status('recording'));
  state = applyMessage(state, { type: 'transcript', confirmedText: '二回目', unconfirmedText: '' });
  assert.equal(displayedText(state), '一回目\n二回目');
  state = applyMessage(state, status('stopped'));
  assert.equal(state.transcript, '一回目\n二回目');
});

test('shows errors from the engine', () => {
  const state = applyMessage(initialState(), { type: 'error', message: 'モデルの読み込みに失敗しました' });
  assert.equal(state.statusText, 'モデルの読み込みに失敗しました');
});

test('resets live state when the connection drops', () => {
  let state = applyMessage(initialState(), status('recording'));
  state = disconnected({ ...state, transcript: '残す' });
  assert.equal(state.connected, false);
  assert.equal(state.isRecording, false);
  assert.equal(state.transcript, '残す');
  assert.match(state.statusText, /MeetingScribe が起動していません/);
});

test('builds control messages', () => {
  assert.deepEqual(JSON.parse(controlMessage('start')), { type: 'control', action: 'start' });
});

test('shows warnings and clears them when recording starts', () => {
  let state = applyMessage(initialState(), { type: 'warning', message: 'システム音声を取れていません' });
  assert.equal(state.warningText, 'システム音声を取れていません');
  state = applyMessage(state, status('recording'));
  assert.equal(state.warningText, null);
});
