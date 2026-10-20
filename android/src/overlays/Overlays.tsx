import React, { useEffect, useRef, useState } from 'react';
import { Alert } from 'react-native';
import { isFinal } from '../copy';
import { useNow } from '../hooks/useNow';
import * as CrossDrop from '../native/crossdrop';
import { useNavigation } from '../navigation/NavigationContext';
import { useSnapshot } from '../state/CrossDropProvider';
import { IncomingStage } from './IncomingStage';
import { PairingStage } from './PairingStage';
import { TransferStage } from './TransferStage';

/**
 * Full-screen moments, one at a time: pairing codes first (they gate
 * transfers), then incoming offers in arrival order, then the transfer this
 * user is following. Any transfer that starts while the app is open is
 * followed automatically; hiding it leaves it running in Activity.
 */
export function Overlays() {
  const snapshot = useSnapshot();
  const { navigate } = useNavigation();
  // id → the answer this user gave
  const [answers, setAnswers] = useState<Map<string, boolean>>(new Map());
  const [followed, setFollowed] = useState<string | null>(null);
  const seen = useRef<Set<string> | null>(null);

  // Follow transfers that appear while the app is open (sent, accepted or auto-accepted).
  useEffect(() => {
    const ids = snapshot.transfers.map(tr => tr.id);
    if (seen.current === null) {
      // On launch, only pick up something still in progress.
      seen.current = new Set(ids);
      const running = snapshot.transfers.find(tr => !isFinal(tr.status));
      if (running) setFollowed(running.id);
      return;
    }
    const fresh = snapshot.transfers.find(
      tr => !seen.current!.has(tr.id) && !isFinal(tr.status),
    );
    ids.forEach(id => seen.current!.add(id));
    if (fresh) setFollowed(fresh.id);
  }, [snapshot.transfers]);

  const pairing = snapshot.pairing.find(
    p => answers.get(p.sessionId) !== false,
  );
  const offer = pairing
    ? undefined
    : snapshot.offers.find(o => answers.get(o.transferId) !== false);
  const transfer = followed
    ? snapshot.transfers.find(tr => tr.id === followed)
    : undefined;
  const now = useNow(1000, !!pairing || !!offer);

  // Stop following a transfer that was dismissed or simply cancelled.
  useEffect(() => {
    if (followed && (!transfer || transfer.status === 'cancelled'))
      setFollowed(null);
  }, [followed, transfer]);

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
      <PairingStage
        key={pairing.sessionId}
        prompt={pairing}
        now={now}
        responded={answers.get(pairing.sessionId) === true}
        onRespond={respond}
      />
    );
  }

  if (offer) {
    const respond = (accept: boolean) => {
      record(offer.transferId, accept);
      CrossDrop.respondToOffer(offer.transferId, accept);
      if (accept) setFollowed(offer.transferId);
    };
    return (
      <IncomingStage
        key={offer.transferId}
        offer={offer}
        trusted={snapshot.trusted.some(d => d.deviceId === offer.peerId)}
        destination={snapshot.destinationLabel}
        now={now}
        responded={answers.get(offer.transferId) === true}
        onRespond={respond}
      />
    );
  }

  if (transfer && transfer.status !== 'cancelled') {
    return (
      <TransferStage
        key={transfer.id}
        transfer={transfer}
        onHide={() => {
          setFollowed(null);
          navigate('activity');
        }}
        onClose={() => setFollowed(null)}
        onSendMore={() => {
          setFollowed(null);
          navigate('nearby');
        }}
        onRetryError={message => Alert.alert('Couldn’t retry', message)}
      />
    );
  }

  return null;
}
