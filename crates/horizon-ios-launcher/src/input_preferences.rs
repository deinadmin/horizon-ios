//! Preferences shared with the SwiftUI launcher through the app's UserDefaults.
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
static ESCAPE: AtomicBool = AtomicBool::new(true);
static SPEED: AtomicU32 = AtomicU32::new(2.0_f32.to_bits());

pub fn escape_enabled() -> bool {
    ESCAPE.load(Ordering::Relaxed)
}
pub fn cursor_speed() -> f32 {
    f32::from_bits(SPEED.load(Ordering::Relaxed))
}

#[cfg(any(target_os = "ios", test))]
fn bounded_speed(value: f64) -> f32 {
    if value.is_finite() && value > 0.0 {
        value.clamp(0.5, 6.0) as f32
    } else {
        2.0
    }
}

#[cfg(target_os = "ios")]
pub(crate) fn refresh() {
    use objc2_foundation::{MainThreadMarker, NSString, NSUserDefaults};
    assert!(MainThreadMarker::new().is_some());
    // SAFETY: Foundation preference reads on the main thread, using the same
    // application domain and key names as Settings.swift's AppStorage.
    unsafe {
        let defaults = NSUserDefaults::standardUserDefaults();
        let escape = NSString::from_str("horizon.escapeAlternative");
        let speed = NSString::from_str("horizon.cursorSensitivity");
        ESCAPE.store(
            defaults.objectForKey(&escape).is_none() || defaults.boolForKey(&escape),
            Ordering::Relaxed,
        );
        SPEED.store(
            bounded_speed(defaults.doubleForKey(&speed)).to_bits(),
            Ordering::Relaxed,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cursor_speed_defaults_and_clamps_invalid_preferences() {
        assert_eq!(bounded_speed(0.0), 2.0);
        assert_eq!(bounded_speed(f64::NAN), 2.0);
        assert_eq!(bounded_speed(0.1), 0.5);
        assert_eq!(bounded_speed(99.0), 6.0);
        assert_eq!(bounded_speed(3.25), 3.25);
    }
}
