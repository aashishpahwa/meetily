/// Meeting Detector
///
/// Polls the system every 3 seconds to detect active Zoom and Google Meet sessions.
/// When a meeting is detected or ends, Tauri events are emitted to the frontend:
///   - "meeting-auto-detected"  { platform: "zoom" | "google_meet", meeting_name: String }
///   - "meeting-auto-ended"     { platform: "zoom" | "google_meet" }
///
/// The feature is disabled by default and toggled via Tauri commands.

use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use sysinfo::System;
use tauri::{AppHandle, Emitter, Runtime};
use tokio::time::{interval, Duration};

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

static AUTO_DETECT_ENABLED: AtomicBool = AtomicBool::new(false);

pub fn set_auto_detect_enabled(enabled: bool) {
    AUTO_DETECT_ENABLED.store(enabled, Ordering::SeqCst);
}

pub fn is_auto_detect_enabled() -> bool {
    AUTO_DETECT_ENABLED.load(Ordering::SeqCst)
}

// ---------------------------------------------------------------------------
// Tauri commands
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn set_meeting_auto_detect(enabled: bool) {
    log::info!("Meeting auto-detect set to: {}", enabled);
    set_auto_detect_enabled(enabled);
}

#[tauri::command]
pub fn get_meeting_auto_detect() -> bool {
    is_auto_detect_enabled()
}

// ---------------------------------------------------------------------------
// Event payloads
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingDetectedPayload {
    pub platform: String,
    pub meeting_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingEndedPayload {
    pub platform: String,
}

// ---------------------------------------------------------------------------
// Platform detection helpers
// ---------------------------------------------------------------------------

/// Zoom creates a `CptHost` subprocess only while an active meeting is running.
/// This is the most reliable cross-platform indicator of an active Zoom meeting.
fn is_zoom_in_meeting(sys: &System) -> bool {
    #[cfg(target_os = "windows")]
    let process_name = "CptHost.exe";
    #[cfg(not(target_os = "windows"))]
    let process_name = "CptHost";

    sys.processes()
        .values()
        .any(|p| p.name().to_string_lossy() == process_name)
}

/// Returns the window title of an active Google Meet tab, or None if not found.
/// Strategy: enumerate all visible OS windows and look for "Google Meet" in the title.
async fn find_google_meet_window() -> Option<String> {
    #[cfg(target_os = "windows")]
    {
        // Enumerate ALL visible top-level windows via a small inline PowerShell snippet.
        // This catches Meet even when it's not the active/focused Chrome window.
        let ps = r#"
Add-Type -Name W -Namespace '' -MemberDefinition '
  [DllImport("user32.dll")] public static extern bool EnumWindows(System.Func<System.IntPtr,System.IntPtr,bool> f, System.IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
' -ErrorAction SilentlyContinue
$found = ''
[W]::EnumWindows({
  param($h,$l)
  if ([W]::IsWindowVisible($h)) {
    $sb = New-Object System.Text.StringBuilder 256
    [W]::GetWindowText($h, $sb, 256) | Out-Null
    $t = $sb.ToString()
    if ($t -match 'meet\.google\.com|Google Meet') {
      $script:found = $t
      return $false
    }
  }
  return $true
}, [System.IntPtr]::Zero) | Out-Null
$found
"#;
        match tokio::process::Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", ps])
            .output()
            .await
        {
            Ok(out) => {
                let title = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if title.is_empty() { None } else { Some(title) }
            }
            Err(e) => {
                log::debug!("Google Meet window check failed: {}", e);
                None
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let script = r#"
tell application "System Events"
    set allTitles to {}
    repeat with p in (processes whose background only is false)
        try
            repeat with w in (windows of p)
                set end of allTitles to name of w
            end repeat
        end try
    end repeat
    repeat with t in allTitles
        if t contains "Google Meet" or t contains "meet.google.com" then
            return t as string
        end if
    end repeat
    return ""
end tell
"#;
        match tokio::process::Command::new("osascript")
            .args(["-e", script])
            .output()
            .await
        {
            Ok(out) => {
                let title = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if title.is_empty() { None } else { Some(title) }
            }
            Err(e) => {
                log::debug!("Google Meet window check (macOS) failed: {}", e);
                None
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        match tokio::process::Command::new("sh")
            .args([
                "-c",
                "wmctrl -l 2>/dev/null | grep -i 'Google Meet\\|meet\\.google\\.com' | head -1 | cut -c21-",
            ])
            .output()
            .await
        {
            Ok(out) => {
                let title = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if title.is_empty() { None } else { Some(title) }
            }
            Err(e) => {
                log::debug!("Google Meet window check (Linux) failed: {}", e);
                None
            }
        }
    }
}

/// Extract a human-readable meeting name from a Google Meet window title.
/// Browser tab title format: "Name - Google Meet" or just "Google Meet".
fn extract_meet_name(window_title: &str) -> String {
    if let Some(idx) = window_title.find(" - Google Meet") {
        let name = window_title[..idx].trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }
    "Google Meet".to_string()
}

// ---------------------------------------------------------------------------
// Background polling loop
// ---------------------------------------------------------------------------

pub async fn start_meeting_detector<R: Runtime>(app: AppHandle<R>) {
    log::info!("Meeting detector loop started (polling every 3 s)");

    let mut ticker = interval(Duration::from_secs(3));
    let mut zoom_was_active = false;
    let mut meet_was_active = false;

    let mut sys = System::new_all();

    loop {
        ticker.tick().await;

        if !is_auto_detect_enabled() {
            // Reset state so transitions fire again if re-enabled mid-session
            zoom_was_active = false;
            meet_was_active = false;
            continue;
        }

        sys.refresh_all();

        // ---- Zoom --------------------------------------------------------
        let zoom_now = is_zoom_in_meeting(&sys);
        match (zoom_was_active, zoom_now) {
            (false, true) => {
                log::info!("Zoom meeting detected");
                let _ = app.emit(
                    "meeting-auto-detected",
                    MeetingDetectedPayload {
                        platform: "zoom".into(),
                        meeting_name: "Zoom Meeting".into(),
                    },
                );
            }
            (true, false) => {
                log::info!("Zoom meeting ended");
                let _ = app.emit(
                    "meeting-auto-ended",
                    MeetingEndedPayload { platform: "zoom".into() },
                );
            }
            _ => {}
        }
        zoom_was_active = zoom_now;

        // ---- Google Meet -------------------------------------------------
        let meet_window = find_google_meet_window().await;
        let meet_now = meet_window.is_some();
        match (meet_was_active, meet_now) {
            (false, true) => {
                let name = extract_meet_name(meet_window.as_deref().unwrap_or("Google Meet"));
                log::info!("Google Meet detected: {}", name);
                let _ = app.emit(
                    "meeting-auto-detected",
                    MeetingDetectedPayload {
                        platform: "google_meet".into(),
                        meeting_name: name,
                    },
                );
            }
            (true, false) => {
                log::info!("Google Meet ended");
                let _ = app.emit(
                    "meeting-auto-ended",
                    MeetingEndedPayload { platform: "google_meet".into() },
                );
            }
            _ => {}
        }
        meet_was_active = meet_now;
    }
}
