//! Feed iOS hardware input through the same mappings and screens as desktop input.
use super::{Game, keyboard::KeyEvent};
use horizon_client::{Result, keybinds};
use horizon_ios_launcher::{
    input::{self, Event},
    scene,
};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalPosition,
    event::{DeviceId, ElementState, MouseButton, MouseScrollDelta, TouchPhase, WindowEvent},
    event_loop::ActiveEventLoop,
    keyboard::{Key, NativeKey, PhysicalKey},
};

impl Game<'_> {
    pub(super) fn ios_input_frame(&mut self, event_loop: &ActiveEventLoop) {
        let events = input::take();
        if !self.focused
            || !scene::game_active()
            || self.pending_entry.is_some()
            || self.world_loader.is_some()
            || self.pending_save.is_some()
        {
            if !self.touch_is_active() {
                let _ = self.reset_ios_input(event_loop);
            }
            return;
        }
        // Some overlays (books, signs, resource-pack prompts) keep Playing as
        // their underlying screen. Release camera capture for their menu pointer.
        if self.captured && !self.touch_playing() {
            self.capture(false);
        }
        for event in events {
            if let Err(error) = self.ios_input(event_loop, event) {
                log::warn!("Horizon: iOS input: {error}");
            }
        }
        // Hide and lock the system pointer in hardware mode. Menus draw their own
        // pointer at the same position used for hit-testing.
        scene::lock_pointer(!self.touch_is_active());
    }

    fn ios_input(&mut self, event_loop: &ActiveEventLoop, event: Event) -> Result<()> {
        let Some(id) = self.window.as_ref().map(|w| w.id()) else {
            return Ok(());
        };
        let pressed = |down| {
            if down {
                ElementState::Pressed
            } else {
                ElementState::Released
            }
        };
        match event {
            Event::Reset => self.reset_ios_input(event_loop)?,
            Event::Key(code, down) => {
                if down {
                    self.hardware_input(event_loop)?;
                }
                if self.touch_is_active() {
                    return Ok(());
                }
                let Some(key) = keybinds::ios_key_code(
                    code,
                    horizon_ios_launcher::input_preferences::escape_enabled(),
                ) else {
                    return Ok(());
                };
                if down {
                    self.physical_keys.insert(key);
                } else {
                    self.physical_keys.remove(&key);
                }
                let action = if down {
                    horizon_client::debug_keys::KeyAction::Press
                } else {
                    horizon_client::debug_keys::KeyAction::Release
                };
                if !self.debug_key(key, action) {
                    self.keyboard_event(KeyEvent {
                        physical_key: PhysicalKey::Code(key),
                        logical_key: Key::Unidentified(NativeKey::Unidentified),
                        text: None,
                        state: pressed(down),
                        repeat: false,
                    })?;
                }
            }
            Event::Motion(x, y) => {
                self.hardware_input(event_loop)?;
                if self.captured {
                    self.mouse
                        .on_move(0.0, 0.0, f64::from(x), f64::from(y), true, true);
                } else if let Some(r) = &self.renderer {
                    let b = horizon_client::hud::HudBatch::new([r.config.width, r.config.height]);
                    let speed = horizon_ios_launcher::input_preferences::cursor_speed();
                    let x = (self.cursor.0 * b.scale + x * speed).clamp(0.0, r.config.width as f32);
                    let y =
                        (self.cursor.1 * b.scale + y * speed).clamp(0.0, r.config.height as f32);
                    self.window_event(
                        event_loop,
                        id,
                        WindowEvent::CursorMoved {
                            device_id: DeviceId::dummy(),
                            position: PhysicalPosition::new(f64::from(x), f64::from(y)),
                        },
                    );
                }
            }
            Event::Button(button, down) => {
                if down {
                    self.hardware_input(event_loop)?;
                }
                if self.touch_is_active() {
                    return Ok(());
                }
                self.window_event(
                    event_loop,
                    id,
                    WindowEvent::MouseInput {
                        device_id: DeviceId::dummy(),
                        state: pressed(down),
                        button: match button {
                            0 => MouseButton::Left,
                            1 => MouseButton::Right,
                            2 => MouseButton::Middle,
                            3 => MouseButton::Back,
                            4 => MouseButton::Forward,
                            n => MouseButton::Other(n),
                        },
                    },
                );
            }
            Event::Scroll(x, y) => {
                self.hardware_input(event_loop)?;
                self.window_event(
                    event_loop,
                    id,
                    WindowEvent::MouseWheel {
                        device_id: DeviceId::dummy(),
                        delta: MouseScrollDelta::LineDelta(x, y),
                        phase: TouchPhase::Moved,
                    },
                );
            }
        }
        Ok(())
    }
}
