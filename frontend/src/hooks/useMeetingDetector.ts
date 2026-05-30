/**
 * useMeetingDetector
 *
 * Listens for Tauri events emitted by the Rust meeting_detector module and
 * automatically starts / stops recording when Zoom or Google Meet sessions
 * are detected.
 *
 * Events consumed:
 *   meeting-auto-detected  { platform, meeting_name }
 *   meeting-auto-ended     { platform }
 *
 * Behaviour:
 *   - On detection: shows a toast ("Recording started for <platform>") then
 *     immediately starts recording using the same flow as the sidebar trigger.
 *   - On end: stops recording automatically (calls window.handleRecordingStop).
 *   - Guards against double-starts / stops using the shared isRecording flag.
 */

import { useEffect, useRef } from 'react';
import { listen, UnlistenFn } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { toast } from 'sonner';
import { useRecordingState } from '@/contexts/RecordingStateContext';

interface MeetingDetectedPayload {
  platform: 'zoom' | 'google_meet';
  meeting_name: string;
}

interface MeetingEndedPayload {
  platform: 'zoom' | 'google_meet';
}

const PLATFORM_LABELS: Record<string, string> = {
  zoom: 'Zoom',
  google_meet: 'Google Meet',
};

export function useMeetingDetector() {
  const { isRecording } = useRecordingState();
  const isRecordingRef = useRef(isRecording);

  // Keep ref in sync so event callbacks always see the current value
  useEffect(() => {
    isRecordingRef.current = isRecording;
  }, [isRecording]);

  useEffect(() => {
    const unlisteners: UnlistenFn[] = [];

    const setup = async () => {
      // ── Meeting detected ────────────────────────────────────────────────
      const unDetect = await listen<MeetingDetectedPayload>(
        'meeting-auto-detected',
        (event) => {
          const { platform, meeting_name } = event.payload;
          const label = PLATFORM_LABELS[platform] ?? platform;

          if (isRecordingRef.current) {
            console.log(`[MeetingDetector] ${label} detected but recording already active — skipping`);
            return;
          }

          console.log(`[MeetingDetector] ${label} meeting detected: "${meeting_name}" — starting recording`);

          // Store the detected meeting name so handleDirectStart picks it up
          // instead of generating a generic timestamp title
          sessionStorage.setItem('meetingDetectorTitle', meeting_name);

          // Use the same window-event mechanism already wired in useRecordingStart
          window.dispatchEvent(
            new CustomEvent('start-recording-from-sidebar', {
              detail: { meeting_name, platform },
            })
          );

          toast.success(`${label} meeting detected`, {
            description: `Recording started automatically for "${meeting_name}"`,
            duration: 5000,
          });
        }
      );
      unlisteners.push(unDetect);

      // ── Meeting ended ────────────────────────────────────────────────────
      const unEnd = await listen<MeetingEndedPayload>(
        'meeting-auto-ended',
        (event) => {
          const { platform } = event.payload;
          const label = PLATFORM_LABELS[platform] ?? platform;

          if (!isRecordingRef.current) {
            console.log(`[MeetingDetector] ${label} ended but no active recording — skipping`);
            return;
          }

          console.log(`[MeetingDetector] ${label} meeting ended — stopping recording`);

          // handleRecordingStop is exposed on window by useRecordingStop
          if (typeof (window as any).handleRecordingStop === 'function') {
            (window as any).handleRecordingStop(true);
          } else {
            console.warn('[MeetingDetector] window.handleRecordingStop not available yet');
          }

          toast.info(`${label} meeting ended`, {
            description: 'Recording stopped and saved automatically.',
            duration: 5000,
          });
        }
      );
      unlisteners.push(unEnd);
    };

    setup().catch((err) =>
      console.error('[MeetingDetector] Failed to attach event listeners:', err)
    );

    return () => {
      unlisteners.forEach((fn) => fn());
    };
  }, []); // Only mount once — isRecordingRef keeps current value

  // Expose helpers so the settings toggle can call into Rust
  const setAutoDetect = (enabled: boolean) =>
    invoke('set_meeting_auto_detect', { enabled });

  const getAutoDetect = () =>
    invoke<boolean>('get_meeting_auto_detect');

  return { setAutoDetect, getAutoDetect };
}
