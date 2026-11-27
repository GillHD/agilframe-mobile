/**
 * Stage 3b example: a 200-participant room in `<AgilCall />`.
 *
 * The SDK keeps the canonical participant set and delivers:
 *  - one `participants` snapshot with the bounded id list (max 200),
 *  - a `participants` delta (`added`/`removed`) for later changes,
 *  - a `connection` event while the widget reconnects.
 *
 * `state.participantIds` is intentionally empty/absent: rendering a 200-row
 * list from every `agil:state` tick is what this stage removes. Keep the list
 * keyed by the ids from the snapshot and apply deltas.
 */
import { useCallback, useRef, useState } from 'react';
import { AgilCall } from '@agil/calls-react-native';
import type {
  AgilCallEvent,
  AgilCallHandle,
  ParticipantUpdate,
} from '@agil/calls-react-native';

export function LargeRoomCall(props: {
  serverUrl: string;
  roomId: string;
  joinToken: string;
  onLeave: () => void;
}) {
  const callRef = useRef<AgilCallHandle>(null);
  const [participants, setParticipants] = useState<readonly string[]>([]);
  const [connection, setConnection] = useState('idle');

  const onEvent = useCallback((event: AgilCallEvent) => {
    switch (event.type) {
      case 'participants': {
        const update: ParticipantUpdate = event.participants;
        setParticipants((current) => {
          if (update.kind === 'snapshot') return update.ids ?? [];
          if (update.kind === 'summary') return current;
          const next = new Set(current);
          for (const id of update.removed) next.delete(id);
          for (const id of update.added) next.add(id);
          return [...next];
        });
        break;
      }
      case 'connection':
        setConnection(event.connection.state);
        break;
      case 'left':
        props.onLeave();
        break;
      default:
        break;
    }
  }, [props]);

  return (
    <AgilCall
      ref={callRef}
      serverUrl={props.serverUrl}
      roomId={props.roomId}
      joinToken={props.joinToken}
      limits={{ maxParticipants: 200 }}
      readyTimeoutMs={30_000}
      onEvent={onEvent}
      onError={(error) => {
        if (error.fatal) callRef.current?.reconnect();
      }}
    />
  );
}
