import React, { useCallback, useState } from 'react';
import { Alert } from 'react-native';
import {
  QueueOfferSheet,
  QueueOfferReason,
} from '../components/QueueOfferSheet';
import { errorCode, friendlyError, queueError } from '../copy';
import { AUTO_DELETE_SECONDS, pluralFiles } from '../format';
import * as CrossDrop from '../native/crossdrop';
import type {
  NearbyDevice,
  SendOptions,
  SharedFile,
  SharedText,
} from '../native/types';
import { useCrossDrop, useSnapshot } from './CrossDropProvider';
import { rememberSend } from './sendMemory';

interface SendFlowConfig {
  /** The files to send, picking them when there are none yet. [] when cancelled. */
  resolveFiles: () => Promise<SharedFile[]>;
  /** Files already chosen (for the wording before they're resolved). */
  count: number;
  /** A share-sheet link / text being sent instead of files. */
  text: SharedText | null;
  /** Something was sent or queued: clear the selection / shared items. */
  onDone: () => void;
}

interface Offer {
  device: NearbyDevice;
  reason: QueueOfferReason;
  /** Resolved files (null until chosen). */
  files: SharedFile[] | null;
  queued: boolean;
  error: string | null;
}

type SendResult = 'sent' | 'unreachable' | 'failed';

/**
 * Tapping a device: send now, or — for a paired device that isn't around —
 * offer "Send when nearby". Shared by Nearby, the share sheet and the widget.
 * Render `element` once; it holds the offer sheet.
 */
export function useSendFlow({
  resolveFiles,
  count,
  text,
  onDone,
}: SendFlowConfig) {
  const snapshot = useSnapshot();
  const { autoDelete, setAutoDelete } = useCrossDrop();
  const [busy, setBusy] = useState(false);
  const [offer, setOffer] = useState<Offer | null>(null);

  const options = useCallback(
    (): SendOptions =>
      autoDelete && !text ? { expiresAfter: AUTO_DELETE_SECONDS } : {},
    [autoDelete, text],
  );

  const finish = useCallback(() => {
    onDone();
    setAutoDelete(false);
  }, [onDone, setAutoDelete]);

  /** One attempt; alerts for anything but "not reachable", which the caller handles. */
  const sendNow = useCallback(
    async (device: NearbyDevice, files: SharedFile[]): Promise<SendResult> => {
      setBusy(true);
      try {
        if (text) {
          await CrossDrop.sendSharedText(device.deviceId);
        } else {
          const opts = options();
          const id = await CrossDrop.sendFiles(device.deviceId, files, opts);
          rememberSend(id, { deviceId: device.deviceId, files, options: opts });
        }
        return 'sent';
      } catch (e) {
        const code = errorCode(e);
        if (code === 'unreachable') return 'unreachable';
        Alert.alert(
          `Couldn’t send to ${device.name}`,
          e instanceof Error && e.message
            ? e.message
            : 'Something went wrong. Try again.',
        );
        return 'failed';
      } finally {
        setBusy(false);
      }
    },
    [text, options],
  );

  const unreachable = useCallback(
    (device: NearbyDevice, files: SharedFile[]) => {
      if (device.trusted) {
        setOffer({
          device,
          reason: 'unreachable',
          files: text ? null : files,
          queued: false,
          error: null,
        });
      } else {
        const e = friendlyError('unreachable');
        Alert.alert(e.title, e.detail);
      }
    },
    [text],
  );

  const select = useCallback(
    async (device: NearbyDevice) => {
      if (device.trusted && device.remembered) {
        setOffer({
          device,
          reason: 'notSeen',
          files: null,
          queued: false,
          error: null,
        });
        return;
      }
      const files = text ? [] : await resolveFiles();
      if (!text && files.length === 0) return;
      const result = await sendNow(device, files);
      if (result === 'sent') finish();
      else if (result === 'unreachable') unreachable(device, files);
    },
    [text, resolveFiles, sendNow, finish, unreachable],
  );

  const selectMany = useCallback(
    async (devices: NearbyDevice[]) => {
      const files = text ? [] : await resolveFiles();
      if (!text && files.length === 0) return;
      let sent = 0;
      for (const device of devices) {
        const result = await sendNow(device, files);
        if (result === 'sent') sent += 1;
        else if (result === 'unreachable') {
          Alert.alert(
            `Couldn’t reach ${device.name}`,
            friendlyError('unreachable').detail,
          );
        }
      }
      if (sent > 0) finish();
    },
    [text, resolveFiles, sendNow, finish],
  );

  const filesFor = async (current: Offer): Promise<SharedFile[] | null> => {
    if (text) return [];
    if (current.files) return current.files;
    const picked = await resolveFiles();
    return picked.length > 0 ? picked : null;
  };

  const queue = async () => {
    if (!offer) return;
    const files = await filesFor(offer);
    if (!files) return;
    setBusy(true);
    try {
      if (text) await CrossDrop.queueSharedText(offer.device.deviceId);
      else await CrossDrop.queueFiles(offer.device.deviceId, files, options());
      CrossDrop.feedback('confirm');
      setOffer({ ...offer, files, queued: true, error: null });
    } catch (e) {
      setOffer({ ...offer, files, error: queueError(errorCode(e)) });
    } finally {
      setBusy(false);
    }
  };

  const tryNow = async () => {
    if (!offer) return;
    const files = await filesFor(offer);
    if (!files) return;
    const result = await sendNow(offer.device, files);
    if (result === 'sent') {
      setOffer(null);
      finish();
    } else if (result === 'unreachable') {
      setOffer({ ...offer, files, reason: 'unreachable', error: null });
    }
  };

  const close = () => {
    if (offer?.queued) finish();
    setOffer(null);
  };

  const what = text
    ? text.kind === 'link'
      ? 'the link'
      : 'the text'
    : offer?.files
    ? pluralFiles(offer.files.length)
    : count > 0
    ? pluralFiles(count)
    : null;

  const element = offer ? (
    <QueueOfferSheet
      device={offer.device}
      reason={offer.reason}
      foundNow={snapshot.nearby.some(
        d => d.deviceId === offer.device.deviceId && !d.remembered,
      )}
      what={what}
      storage={snapshot.queueStorage}
      busy={busy}
      queued={offer.queued}
      error={offer.error}
      onQueue={queue}
      onTryNow={tryNow}
      onClose={close}
    />
  ) : null;

  return { select, selectMany, busy, element };
}
