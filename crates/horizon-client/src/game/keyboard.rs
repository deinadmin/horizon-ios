//! Shared physical keyboard dispatch, including native iOS keyboard events.
use super::{Game, Screen};
use horizon_client::Result;
use winit::{
    event::ElementState,
    keyboard::{Key, KeyCode, PhysicalKey},
};

pub(super) struct KeyEvent {
    pub physical_key: PhysicalKey,
    pub logical_key: Key,
    pub text: Option<String>,
    pub state: ElementState,
    pub repeat: bool,
}
impl From<winit::event::KeyEvent> for KeyEvent {
    fn from(event: winit::event::KeyEvent) -> Self {
        Self {
            physical_key: event.physical_key,
            logical_key: event.logical_key,
            text: event.text.map(|s| s.to_string()),
            state: event.state,
            repeat: event.repeat,
        }
    }
}
impl Game<'_> {
    pub(super) fn keyboard_event(&mut self, event: KeyEvent) -> Result<()> {
        match event {
            event if self.server_packs.prompt.is_some() => {
                if event.state == ElementState::Pressed
                    && event.physical_key == PhysicalKey::Code(KeyCode::Escape)
                {
                    self.answer_pack_prompt(false)?;
                }
            }
            event if self.screen == Screen::Chat && self.title.is_none() => {
                if let PhysicalKey::Code(key) = event.physical_key {
                    if event.state == ElementState::Pressed {
                        self.keys.insert(key);
                        self.chat_key(&event);
                    } else {
                        self.keys.remove(&key);
                    }
                } else if event.state == ElementState::Pressed
                    && let Some(text) = &event.text
                {
                    self.chat_type(text);
                }
            }
            event if self.sign_edit.is_some() => self.sign_edit_key(&event),
            event if self.book.is_some() => self.book_key(&event),
            event
                if self.screen == Screen::Creative
                    && self.creative_screen.tab().search
                    && event.state == ElementState::Pressed
                    && !matches!(event.physical_key, PhysicalKey::Code(KeyCode::Escape)) =>
            {
                if let PhysicalKey::Code(key) = event.physical_key
                    && self.search_tab_hotbar_key(key)
                {
                    // The hovered slot took the key (`ignoreTextInput`).
                } else if let Some(shortcut) = self.edit_shortcut(&event) {
                    self.creative_search_shortcut(shortcut);
                } else {
                    let backspace = event.physical_key == PhysicalKey::Code(KeyCode::Backspace);
                    self.creative_search_edit(event.text.as_deref(), backspace);
                }
            }
            event
                if self.recipe_search_focused()
                    && event.state == ElementState::Pressed
                    && !matches!(event.physical_key, PhysicalKey::Code(KeyCode::Escape)) =>
            {
                // The recipe book's search box takes every key but Escape.
                self.recipe_key(&event);
            }
            event
                if self.station_typing()
                    && event.state == ElementState::Pressed
                    && !matches!(event.physical_key, PhysicalKey::Code(KeyCode::Escape)) =>
            {
                // The anvil rename box takes every key but Escape (AnvilScreen.keyPressed).
                if let Some(shortcut) = self.edit_shortcut(&event) {
                    self.station_shortcut(shortcut);
                } else {
                    let backspace = event.physical_key == PhysicalKey::Code(KeyCode::Backspace);
                    self.station_text(event.text.as_deref(), backspace);
                }
            }
            event
                if self.screen == Screen::WorldOptions
                    && !matches!(event.physical_key, PhysicalKey::Code(KeyCode::Escape)) =>
            {
                self.world_options_key(&event)
            }
            event if self.screen == Screen::Win => self.win_key(&event)?,
            event if self.screen == Screen::CommandBlock => self.command_block_key(&event),
            // Options consumes presses; releases still reach the bound
            // gameplay mapping below, including sneak/sprint toggles.
            event if self.screen == Screen::Options && event.state == ElementState::Pressed => {
                if let Some(shortcut) = self.edit_shortcut(&event)
                    && self.options_shortcut(shortcut)
                {
                    return Ok(());
                }
                if let PhysicalKey::Code(key) = event.physical_key {
                    self.options_key(key, event.text.as_deref())?;
                }
            }
            event if self.title.is_some() => {
                if event.state == ElementState::Pressed {
                    if let Some(shortcut) = self.edit_shortcut(&event) {
                        self.title_shortcut(shortcut);
                        return Ok(());
                    }
                    match event.physical_key {
                        PhysicalKey::Code(KeyCode::Enter | KeyCode::NumpadEnter) => {
                            if let Some(t) = self.title.as_mut() {
                                t.confirm_edit();
                            }
                        }
                        PhysicalKey::Code(
                            key @ (KeyCode::Backspace
                            | KeyCode::Delete
                            | KeyCode::ArrowLeft
                            | KeyCode::ArrowRight
                            | KeyCode::Home
                            | KeyCode::End),
                        ) if self.title.as_mut().is_some_and(|t| t.has_caret_field()) => {
                            let (ctrl, shift) = (self.has_control_down(), self.has_shift_down());
                            if let Some(t) = self.title.as_mut() {
                                t.field_key(key, ctrl, shift);
                            }
                        }
                        PhysicalKey::Code(KeyCode::Backspace) => self.title_edit(None, true),
                        PhysicalKey::Code(KeyCode::Tab) => {
                            if let Some(t) = self.title.as_mut() {
                                t.tab();
                            }
                        }
                        PhysicalKey::Code(KeyCode::Escape) => {
                            if let Some(t) = self.title.as_mut() {
                                t.escape();
                            }
                            self.save_title_options();
                        }
                        _ => self.title_edit(event.text.as_deref(), false),
                    }
                }
            }
            event => {
                let PhysicalKey::Code(key) = event.physical_key else {
                    return Ok(());
                };
                self.extras_key(key, event.state == ElementState::Pressed, event.repeat);
                // key.smoothCamera toggles the cinematic camera.
                if self.screen == Screen::Playing
                    && event.state == ElementState::Pressed
                    && !event.repeat
                    && horizon_client::keybinds::key_name(key)
                        .is_some_and(|n| self.settings.keys.get("key.smoothCamera") == n)
                {
                    self.smooth_camera = !self.smooth_camera;
                }
                // Key binds: act as the default key of the bound mapping.
                let key = match self.settings.keys.translate(key) {
                    Some(Ok(k)) => k,
                    Some(Err(button)) => {
                        if self.screen == Screen::Playing && !event.repeat {
                            self.play_mouse(button, event.state == ElementState::Pressed)?;
                        }
                        return Ok(());
                    }
                    None => return Ok(()),
                };
                self.mapped_key(key, event.state == ElementState::Pressed, event.repeat)?;
            }
        }
        Ok(())
    }
}
