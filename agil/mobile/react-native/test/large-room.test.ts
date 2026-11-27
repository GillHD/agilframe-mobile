import { test } from 'node:test';
import assert from 'node:assert/strict';

import { mapBridgeMessage, parseBridgeMessage } from '../src/bridge.js';
import type { WidgetToHostMessage } from '../src/bridge.js';
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
import { buildWidgetUrl } from '../src/url.js';

function ids(count: number, prefix = 'p'): string[] {
  return Array.from({ length: count }, (_, index) => `${prefix}-${index}`);
}

test('large-room limits default to the 200-participant profile', () => {
  const limits = normalizeLargeRoomLimits();
  assert.equal(limits.maxParticipants, LARGE_ROOM_MAX_PARTICIPANTS);
  assert.equal(limits.maxParticipants, 200);
  assert.equal(limits.resyncMin, 32);
  assert.equal(limits.resyncRatio, 0.5);
  // Out-of-range values are clamped, never expanded past the profile.
  assert.equal(normalizeLargeRoomLimits({ maxParticipants: 5_000 }).maxParticipants, 200);
  assert.equal(normalizeLargeRoomLimits({ maxParticipants: 1 }).maxParticipants, 2);
  assert.equal(normalizeLargeRoomLimits({ maxParticipants: Number.NaN }).maxParticipants, 200);
});

test('first participant snapshot carries the bounded id set exactly once', () => {
  const digest = new ParticipantDigest();
  const update = digest.apply({ participantIds: ids(200), count: 200 });
  assert.ok(update);
  assert.equal(update.kind, 'snapshot');
  assert.equal(update.count, 200);
  assert.equal(update.revision, 1);
  assert.equal(update.ids?.length, 200);
  assert.deepEqual(update.added, ids(200));
  assert.deepEqual(update.removed, []);
  assert.equal(digest.count, 200);
  assert.equal(digest.ids.length, 200);
});

test('subsequent ticks are deltas, not another 200-id snapshot', () => {
  const digest = new ParticipantDigest();
  digest.apply({ participantIds: ids(200), count: 200 });

  const joined = digest.apply({ participantIds: [...ids(199), 'late-joiner'], count: 200 });
  assert.ok(joined);
  assert.equal(joined.kind, 'delta');
  assert.deepEqual(joined.added, ['late-joiner']);
  assert.deepEqual(joined.removed, ['p-199']);
  assert.equal(joined.revision, 2);

  const unchanged = digest.apply({ participantIds: [...ids(199), 'late-joiner'], count: 200 });
  assert.equal(unchanged, null, 'an unchanged periodic snapshot stays silent');

  const left = digest.apply({ participantIds: ids(199), count: 199 });
  assert.ok(left);
  assert.equal(left.kind, 'delta');
  assert.deepEqual(left.removed, ['late-joiner']);
  assert.deepEqual(left.added, []);
});

test('large churn resynchronises with one snapshot instead of a huge delta', () => {
  const digest = new ParticipantDigest();
  digest.apply({ participantIds: ids(40), count: 40 });
  const replacement = [...ids(20), ...ids(20, 'q')];
  const update = digest.apply({ participantIds: replacement, count: 40 });
  assert.ok(update);
  assert.equal(update.kind, 'snapshot');
  assert.equal(update.ids?.length, 40);
  assert.deepEqual(update.ids, replacement);
  assert.equal(update.revision, 2);
});

test('more than maxParticipants ids are truncated and flagged', () => {
  const digest = new ParticipantDigest();
  const update = digest.apply({ participantIds: ids(260), count: 260 });
  assert.ok(update);
  assert.equal(update.kind, 'snapshot');
  assert.equal(update.ids?.length, 200);
  assert.equal(update.count, 260);
  assert.equal(update.truncated, true);
});

test('count-only snapshots produce a summary only when the count changes', () => {
  const digest = new ParticipantDigest();
  const first = digest.apply({ count: 180 });
  assert.ok(first);
  assert.equal(first.kind, 'summary');
  assert.deepEqual(first.added, []);
  assert.equal(digest.apply({ count: 180 }), null);
  const changed = digest.apply({ count: 179 });
  assert.ok(changed);
  assert.equal(changed.kind, 'summary');
  assert.equal(changed.count, 179);
});

test('invalid participant ids are dropped without throwing', () => {
  const digest = new ParticipantDigest();
  const update = digest.apply({
    participantIds: ['ok', '', '   ', 'with\u0000control', 42, null, 'x'.repeat(201), 'ok'],
    count: 1,
  });
  assert.ok(update);
  assert.equal(update.kind, 'snapshot');
  assert.deepEqual(update.ids, ['ok']);
});

test('compactCallState strips participantIds and carries the compact digest', () => {
  const digest = new ParticipantDigest();
  const update = digest.apply({ participantIds: ids(200), count: 200 });
  assert.ok(update);
  const compact = compactCallState(
    { phase: 'joined', participants: 200, participantIds: ids(200), connectionState: 'connected' },
    update,
  );
  assert.equal(Object.prototype.hasOwnProperty.call(compact, 'participantIds'), false);
  assert.equal(compact['participantCount'], 200);
  assert.equal(compact['participantRevision'], 1);
  assert.equal(compact['participants'], 200);
  assert.equal(compact['phase'], 'joined');
  assert.ok(JSON.stringify(compact).length < 300, 'compact state must not contain the 200-id array');
});

test('extractParticipantIds is bounded and deduplicated', () => {
  // One id above the profile cap is kept so the digest can flag truncation.
  const extracted = extractParticipantIds({ participantIds: [...ids(210), 'p-0'] });
  assert.equal(extracted.length, 201);
  assert.equal(new Set(extracted).size, 201);
  assert.deepEqual(extractParticipantIds({ participantIds: 'nope' }), []);
});

test('a >200-id widget state through the bridge path sets truncated', () => {
  const parsed = parseBridgeMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 260, participantIds: ids(260) },
  });
  assert.ok(parsed && parsed.type === 'agil:state');
  if (!parsed || parsed.type !== 'agil:state') return;
  assert.equal(parsed.participantIds?.length, 201);

  const mapped = mapBridgeMessage(parsed, { participants: new ParticipantDigest() });
  const snapshot = mapped.events.find((event) => event.type === 'participants');
  assert.ok(snapshot && snapshot.type === 'participants');
  assert.equal(snapshot.participants.kind, 'snapshot');
  assert.equal(snapshot.participants.ids?.length, 200);
  assert.equal(snapshot.participants.truncated, true);

  // A configured cap below 200 still wins over the parse headroom.
  const lowCap = new ParticipantDigest({ maxParticipants: 50 }).apply({
    participantIds: parsed.participantIds,
    count: parsed.state.participants,
  });
  assert.ok(lowCap);
  assert.equal(lowCap.ids?.length, 50);
  assert.equal(lowCap.truncated, true);
});

test('empty participantIds are an empty-room snapshot, absent ids are a summary', () => {
  const parsedEmpty = parseBridgeMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 0, participantIds: [] },
  });
  assert.ok(parsedEmpty && parsedEmpty.type === 'agil:state');
  if (!parsedEmpty || parsedEmpty.type !== 'agil:state') return;
  assert.deepEqual(parsedEmpty.participantIds, []);
  const emptyMapped = mapBridgeMessage(parsedEmpty, { participants: new ParticipantDigest() });
  const emptyUpdate = emptyMapped.events.find((event) => event.type === 'participants');
  assert.ok(emptyUpdate && emptyUpdate.type === 'participants');
  assert.equal(emptyUpdate.participants.kind, 'snapshot');
  assert.equal(emptyUpdate.participants.count, 0);
  assert.deepEqual(emptyUpdate.participants.ids, []);

  const parsedAbsent = parseBridgeMessage({
    type: 'agil:state',
    state: { phase: 'joined', participants: 0 },
  });
  assert.ok(parsedAbsent && parsedAbsent.type === 'agil:state');
  if (!parsedAbsent || parsedAbsent.type !== 'agil:state') return;
  assert.equal(parsedAbsent.participantIds, undefined);
  const summaryMapped = mapBridgeMessage(parsedAbsent, { participants: new ParticipantDigest() });
  const summaryUpdate = summaryMapped.events.find((event) => event.type === 'participants');
  assert.ok(summaryUpdate && summaryUpdate.type === 'participants');
  assert.equal(summaryUpdate.participants.kind, 'summary');
});

test('connection digest emits one reconnect event per state change', () => {
  const digest = new ConnectionDigest();
  assert.equal(digest.apply({ state: 'connected' })?.state, 'connected');
  assert.equal(digest.apply({ state: 'connected' }), null);

  const reconnecting = digest.apply({ state: 'reconnecting', attempt: 2, delayMs: 1_000 });
  assert.ok(reconnecting);
  assert.equal(reconnecting.state, 'reconnecting');
  assert.equal(reconnecting.reconnecting, true);
  assert.equal(reconnecting.attempt, 2);
  assert.equal(reconnecting.delayMs, 1_000);
  assert.equal(reconnecting.previous, 'connected');

  const retry = digest.apply({ state: 'reconnecting', attempt: 3, delayMs: 2_000 });
  assert.ok(retry, 'a new attempt is meaningful even while reconnecting');
  assert.equal(retry.attempt, 3);

  assert.equal(digest.apply({ state: 'reconnecting', attempt: 3, delayMs: 2_000 }), null);

  const reconnected = digest.apply({ state: 'connected' });
  assert.ok(reconnected);
  assert.equal(reconnected.reconnecting, false);
  assert.equal(reconnected.previous, 'reconnecting');
});

test('connection aliases are normalized and unknown values stay visible', () => {
  assert.equal(normalizeConnectionState('OPEN'), 'connected');
  assert.equal(normalizeConnectionState('new'), 'connecting');
  assert.equal(normalizeConnectionState('wat'), 'unknown');
  assert.equal(normalizeConnectionState(42), null);
  assert.deepEqual(readConnectionFields({ connection: 'reconnecting', attempt: 4 }), {
    state: 'reconnecting',
    attempt: 4,
  });
  assert.deepEqual(readConnectionFields({ payload: { connection: 'offline' } }), {
    state: 'offline',
  });
});

test('bridge mapping emits one 200-id snapshot, then deltas (no 200-JSON per tick)', () => {
  const participants = new ParticipantDigest();
  const connection = new ConnectionDigest();
  const first = parseBridgeMessage({
    type: 'agil:state',
    state: {
      phase: 'joined',
      participants: 200,
      participantIds: ids(200),
      connectionState: 'connected',
    },
  });
  assert.ok(first);
  const firstMapped = mapBridgeMessage(first, { participants, connection });
  const firstState = firstMapped.events.find((event) => event.type === 'state');
  assert.ok(firstState && firstState.type === 'state');
  assert.equal(Object.prototype.hasOwnProperty.call(firstState.state, 'participantIds'), false);
  assert.ok(JSON.stringify(firstState.state).length < 300);
  const snapshot = firstMapped.events.find((event) => event.type === 'participants');
  assert.ok(snapshot && snapshot.type === 'participants');
  assert.equal(snapshot.participants.kind, 'snapshot');
  assert.equal(snapshot.participants.ids?.length, 200);

  const second = parseBridgeMessage({
    type: 'agil:state',
    state: {
      phase: 'joined',
      participants: 200,
      participantIds: [...ids(199), 'newcomer'],
      connectionState: 'connected',
    },
  });
  assert.ok(second);
  const secondMapped = mapBridgeMessage(second, { participants, connection });
  const delta = secondMapped.events.find((event) => event.type === 'participants');
  assert.ok(delta && delta.type === 'participants');
  assert.equal(delta.participants.kind, 'delta');
  assert.deepEqual(delta.participants.added, ['newcomer']);
  assert.deepEqual(delta.participants.removed, ['p-199']);
  assert.equal(JSON.stringify(secondMapped.events).includes('"ids"'), false);
});

test('bridge mapping exposes reconnect state and deduplicates connection-state', () => {
  const participants = new ParticipantDigest();
  const connection = new ConnectionDigest();
  connection.apply({ state: 'connected' });
  const reconnecting = parseBridgeMessage({
    type: 'agil:event',
    event: 'connection-state',
    payload: { connection: 'reconnecting', attempt: 2, delayMs: 500 },
  });
  assert.ok(reconnecting);
  const mapped = mapBridgeMessage(reconnecting, { participants, connection });
  const event = mapped.events.find((item) => item.type === 'connection');
  assert.ok(event && event.type === 'connection');
  assert.equal(event.connection.state, 'reconnecting');
  assert.equal(event.connection.attempt, 2);
  assert.equal(event.connection.reconnecting, true);

  const again = parseBridgeMessage({
    type: 'agil:event',
    event: 'connection-state',
    payload: { connection: 'reconnecting', attempt: 2, delayMs: 500 },
  });
  assert.ok(again);
  const mappedAgain = mapBridgeMessage(again, { participants, connection });
  assert.equal(mappedAgain.events.some((item) => item.type === 'connection'), false);
});

test('state.reconnect is attached only to the reconnect transition', () => {
  const participants = new ParticipantDigest();
  const connection = new ConnectionDigest();
  connection.apply({ state: 'connected' });

  const reconnecting = (): WidgetToHostMessage => {
    const parsed = parseBridgeMessage({
      type: 'agil:state',
      state: { phase: 'joined', participants: 2, connectionState: 'reconnecting' },
    });
    assert.ok(parsed && parsed.type === 'agil:state');
    return parsed as WidgetToHostMessage;
  };

  const first = mapBridgeMessage(reconnecting(), { participants, connection });
  const firstState = first.events.find((event) => event.type === 'state');
  assert.ok(firstState && firstState.type === 'state');
  assert.deepEqual(firstState.state.reconnect, {}, 'transition tick attaches reconnect');
  assert.ok(first.events.some((event) => event.type === 'connection'));

  // The repeated reconnecting tick is deduplicated: no connection event and no
  // state.reconnect. Hosts should keep the last connection event / connectionState.
  const second = mapBridgeMessage(reconnecting(), { participants, connection });
  const secondState = second.events.find((event) => event.type === 'state');
  assert.ok(secondState && secondState.type === 'state');
  assert.equal(secondState.state.reconnect, undefined);
  assert.equal(second.events.some((event) => event.type === 'connection'), false);
});

test('reconnect keeps server, room, join token and identity token in the URL', () => {
  const options = {
    serverUrl: 'https://calls.example.com',
    roomId: 'large-room-1',
    tenantId: 'acme',
    joinToken: 'join-token-123',
    identityToken: 'identity-token-456',
  };
  const first = buildWidgetUrl(options);
  const afterReconnect = buildWidgetUrl(options);
  assert.equal(afterReconnect, first);
  assert.match(afterReconnect, /[?&]token=join-token-123(&|$)/);
  assert.match(afterReconnect, /[?&]identity_token=identity-token-456(&|$)/);
  assert.match(afterReconnect, /[?&]room=large-room-1(&|$)/);
  assert.equal(new URL(afterReconnect).origin, 'https://calls.example.com');
});
