//! Command-period is an Escape alternative on keyboards without Escape.
//! HID usages are independent of the active text layout.
#[derive(Default)]
pub(crate) struct EscapeShortcut {
    period_is_escape: bool,
}
impl EscapeShortcut {
    pub(crate) fn key(&mut self, usage: i32, pressed: bool, command: bool) -> i32 {
        if usage != 55 {
            return usage;
        }
        if pressed {
            self.period_is_escape |= command;
        }
        let mapped = if self.period_is_escape { 41 } else { usage };
        if !pressed {
            self.period_is_escape = false;
        }
        mapped
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_period_sends_both_escape_edges() {
        let mut keys = EscapeShortcut::default();
        assert_eq!(keys.key(55, true, true), 41);
        // Command may be released before Period.
        assert_eq!(keys.key(55, false, false), 41);
        assert_eq!(keys.key(55, true, false), 55);
        assert_eq!(keys.key(55, false, false), 55);
    }

    #[test]
    fn shortcut_does_not_change_other_keys_or_repeats() {
        let mut keys = EscapeShortcut::default();
        assert_eq!(keys.key(26, true, true), 26);
        assert_eq!(keys.key(55, true, true), 41);
        assert_eq!(keys.key(55, true, false), 41);
        assert_eq!(keys.key(55, false, false), 41);
    }
}
