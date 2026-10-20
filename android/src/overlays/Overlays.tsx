import React, { useEffect, useState } from 'react';
import { Sheet } from '../components/Sheet';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import { useSnapshot } from '../state/CrossDropProvider';
import { OfferSheetContent } from './OfferSheet';
import { PairingSheetContent } from './PairingSheet';

/**
 * Shows one decision at a time: pairing prompts first (they gate transfers),
 * then incoming offers in arrival order. Declined items are hidden right away;
 * accepted ones stay (in a waiting state) until the engine updates them.
 */
export function Overlays() {
  const snapshot = useSnapshot();
  // id → the answer this user gave
  const [answers, setAnswers] = useState<Map<string, boolean>>(new Map());

  const pairing = snapshot.pairing.find(
    p => answers.get(p.sessionId) !== false,
  );
  const offer = pairing
    ? undefined
    : snapshot.offers.find(o => answers.get(o.transferId) !== false);
  const now = useNow(1000, !!pairing || !!offer);

  // Forget answers for prompts that no longer exist.
  useEffect(() => {
    const live = new Set([
      ...snapshot.pairing.map(p => p.sessionId),
      ...snapshot.offers.map(o => o.transferId),
    ]);
    setAnswers(prev => {
      const next = new Map([...prev].filter(([id]) => live.has(id)));
      return next.size === prev.size ? prev : next;
    });
  }, [snapshot.pairing, snapshot.offers]);

  const record = (id: string, accept: boolean) =>
    setAnswers(prev => new Map(prev).set(id, accept));

  if (pairing) {
    const respond = (accept: boolean) => {
      record(pairing.sessionId, accept);
      CrossDrop.respondToPairing(pairing.sessionId, accept);
    };
    return (
      <Sheet
        key={pairing.sessionId}
        visible
        onRequestClose={() => respond(false)}
        accessibilityLabel={`Pair with ${pairing.peerName}`}
      >
        <PairingSheetContent
          prompt={pairing}
          now={now}
          responded={answers.get(pairing.sessionId) === true}
          onRespond={respond}
        />
      </Sheet>
    );
  }

  if (offer) {
    const respond = (accept: boolean) => {
      record(offer.transferId, accept);
      CrossDrop.respondToOffer(offer.transferId, accept);
    };
    return (
      <Sheet
        key={offer.transferId}
        visible
        onRequestClose={() => respond(false)}
        accessibilityLabel={`Incoming files from ${offer.peerName}`}
      >
        <OfferSheetContent
          offer={offer}
          trusted={snapshot.trusted.some(d => d.deviceId === offer.peerId)}
          now={now}
          responded={answers.get(offer.transferId) === true}
          onRespond={respond}
        />
      </Sheet>
    );
  }

  return null;
}
