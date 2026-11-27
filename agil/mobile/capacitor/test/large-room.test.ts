import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parseWidgetMessage } from '../src/bridge.js';
import {
  ConnectionDigest,
  LARGE_ROOM_MAX_PARTICIPANTS,
  ParticipantDigest,
  compactCallState,
  extractParticipantIds,
  normalizeConnectionState,
  normalizeLargeRoomLimits,
  readConnectionFields,
} from '../src/large-room.js';

function ids(count: number, prefix = 'p'): string[] {
  return Array.from({ length: count }, (_, index) => `${prefix}-${index}`);
}

test('capacitor large-room limits default to 200 and clamp', () => {
  assert.equal(LARGE_ROOM_MAX_PARTICIPANTS, 200);
  assert.equal(normalizeLargeRoomLimits().maxParticipants, 200);
  assert.equal(normalizeLargeRoomLimits({ maxParticipants: 10_000 }).maxParticipants, 200);
  assert.equal(normalizeLargeRoomLimits({ maxParticipants: 0 }).maxParticipants, 2);
});

test('capacitor digest emits one 200-id snapshot then deltas', () => {
  const digest = new ParticipantDigest();
  const snapshot = digest.apply({ participantIds: ids(200), count: 200 });
  assert.ok(snapshot);
  assert.equal(snapshot.kind, 'snapshot');
  assert.equal(snapshot.ids?.length, 200);
  const delta = digest.apply({ participantIds: [...ids(199), 'newcomer'], count: 200 });
  assert.ok(delta);
  assert.equal(delta.kind, 'delta');
  assert.deepEqual(delta.added, ['newcomer']);
  assert.deepEqual(delta.removed, ['p-199']);
  assert.equal(digest.apply({ participantIds: [...ids(199), 'newcomer'], count: 200 }), null);
});

test('capacitor compact state never carries the 200-id array', () => {
  const digest = new ParticipantDigest();
  const update = digest.apply({ participantIds: ids(200), count: 200 });
  assert.ok(update);
  const state = compactCallState(
    { phase: 'joined', participants: 200, participantIds: ids(200) },
    update,
  );
  assert.equal(Object.prototype.hasOwnProperty.call(state, 'participantIds'), false);
  assert.equal(state['participantCount'], 200);
  assert.ok(JSON.stringify(state).length < 300);
});

test('capacitor parse extracts participantIds before the generic array cap', () => {
  const event = parseWidgetMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 210, participantIds: ids(210) },
  });
  assert.ok(event && event.type === 'state');
  if (!event || event.type !== 'state') return;
  // Profile cap + 1: the extra id lets the digest flag an oversized widget.
  assert.equal(event.participantIds?.length, 201);
  assert.equal(Object.prototype.hasOwnProperty.call(event.state, 'participantIds'), false);
  assert.equal(extractParticipantIds({ participantIds: ids(260) }).length, 201);
});

test('capacitor parse path flags a >200-id widget state as truncated', () => {
  const event = parseWidgetMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 260, participantIds: ids(260) },
  });
  assert.ok(event && event.type === 'state');
  if (!event || event.type !== 'state') return;

  const update = new ParticipantDigest().apply({
    participantIds: event.participantIds,
    count: event.state.participants,
  });
  assert.ok(update);
  assert.equal(update.kind, 'snapshot');
  assert.equal(update.ids?.length, 200);
  assert.equal(update.truncated, true);

  const lowCap = new ParticipantDigest({ maxParticipants: 50 }).apply({
    participantIds: event.participantIds,
    count: event.state.participants,
  });
  assert.ok(lowCap);
  assert.equal(lowCap.ids?.length, 50);
  assert.equal(lowCap.truncated, true);
});

test('capacitor empty participantIds are an empty snapshot; absent ids are a summary', () => {
  const empty = parseWidgetMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 0, participantIds: [] },
  });
  assert.ok(empty && empty.type === 'state');
  if (!empty || empty.type !== 'state') return;
  assert.deepEqual(empty.participantIds, []);
  const emptyUpdate = new ParticipantDigest().apply({
    participantIds: empty.participantIds,
    count: empty.state.participants,
  });
  assert.ok(emptyUpdate);
  assert.equal(emptyUpdate.kind, 'snapshot');
  assert.deepEqual(emptyUpdate.ids, []);

  const absent = parseWidgetMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 0 },
  });
  assert.ok(absent && absent.type === 'state');
  if (!absent || absent.type !== 'state') return;
  assert.equal(absent.participantIds, undefined);
  assert.equal(
    new ParticipantDigest().apply({
      participantIds: absent.participantIds,
      count: absent.state.participants,
    })?.kind,
    'summary',
  );
});

test('capacitor connection digest deduplicates reconnect transitions', () => {
  const digest = new ConnectionDigest();
  assert.equal(digest.apply({ state: 'connected' })?.state, 'connected');
  const reconnecting = digest.apply({ state: 'reconnecting', attempt: 1, delayMs: 250 });
  assert.ok(reconnecting);
  assert.equal(reconnecting.reconnecting, true);
  assert.equal(digest.apply({ state: 'reconnecting', attempt: 1, delayMs: 250 }), null);
  const back = digest.apply({ state: 'connected' });
  assert.ok(back);
  assert.equal(back.previous, 'reconnecting');
  assert.equal(normalizeConnectionState('reconnecting'), 'reconnecting');
  assert.deepEqual(readConnectionFields({ connectionState: 'reconnecting' }), {
    state: 'reconnecting',
  });
});
