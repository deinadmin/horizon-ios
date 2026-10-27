//! Native keyboard and relative mouse input missing from winit's iOS backend.
//! Handlers only queue values; the game drains them on UIKit's main thread.
use block2::RcBlock;
use objc2_game_controller::*;
use objc2_new::{rc::Retained, runtime::Bool};
use std::{cell::RefCell, collections::VecDeque, ptr::NonNull, sync::Mutex};

#[derive(Clone, Copy, Debug)]
pub enum Event {
    Key(i32, bool),
    Motion(f32, f32),
    Button(u16, bool),
    Scroll(f32, f32),
    Reset,
}
static EVENTS: Mutex<VecDeque<Event>> = Mutex::new(VecDeque::new());
fn push(event: Event) {
    let mut events = EVENTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    // Coalesce motion, but preserve button ordering and short presses.
    if let (Some(Event::Motion(x, y)), Event::Motion(dx, dy)) = (events.back_mut(), event) {
        *x += dx;
        *y += dy;
    } else {
        events.push_back(event);
    }
}
#[derive(Default)]
struct Devices {
    keyboard: Option<Retained<GCKeyboardInput>>,
    mice: Vec<Retained<GCMouse>>,
}
thread_local! { static DEVICES: RefCell<Devices> = RefCell::default(); }

/// Install handlers for hot-plugged devices and drain their ordered events.
pub fn take() -> Vec<Event> {
    assert!(objc2_foundation::MainThreadMarker::new().is_some());
    crate::input_preferences::refresh();
    DEVICES.with(|devices| {
        let mut devices = devices.borrow_mut();
        // SAFETY: GameController objects and handlers use their documented signatures;
        // setters copy blocks. The blocks capture only numbers and a synchronized queue.
        unsafe {
            let keyboard = GCKeyboard::coalescedKeyboard().and_then(|k| k.keyboardInput());
            if keyboard != devices.keyboard {
                if let Some(old) = devices.keyboard.take() {
                    old.setKeyChangedHandler(std::ptr::null_mut());
                    push(Event::Reset);
                }
                if let Some(input) = &keyboard {
                    // Remember the shortcut until Period is released, even if
                    // Command is released first. Avoid a stranded Escape key.
                    let mut_shortcut =
                        std::sync::Mutex::new(crate::escape_shortcut::EscapeShortcut::default());
                    let handler = RcBlock::new(
                        move |keyboard: NonNull<GCKeyboardInput>,
                              _: NonNull<GCControllerButtonInput>,
                              code: GCKeyCode,
                              down: Bool| {
                            // SAFETY: GameController supplies a live keyboard for
                            // the callback; these are the documented modifier keys.
                            let command = keyboard
                                .as_ref()
                                .buttonForKeyCode(GCKeyCodeLeftGUI)
                                .is_some_and(|b| b.isPressed())
                                || keyboard
                                    .as_ref()
                                    .buttonForKeyCode(GCKeyCodeRightGUI)
                                    .is_some_and(|b| b.isPressed());
                            let code = mut_shortcut
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .key(
                                    code as i32,
                                    down.as_bool(),
                                    command && crate::input_preferences::escape_enabled(),
                                );
                            push(Event::Key(code, down.as_bool()));
                        },
                    );
                    input.setKeyChangedHandler(RcBlock::as_ptr(&handler));
                }
                devices.keyboard = keyboard;
            }
            let mice: Vec<_> = GCMouse::mice().to_vec();
            for mouse in &mice {
                if devices.mice.contains(mouse) {
                    continue;
                }
                let Some(input) = mouse.mouseInput() else {
                    continue;
                };
                let motion = RcBlock::new(|_: NonNull<GCMouseInput>, x: f32, y: f32| {
                    if x != 0.0 || y != 0.0 {
                        push(Event::Motion(x, -y));
                    }
                });
                input.setMouseMovedHandler(RcBlock::as_ptr(&motion));
                let mut buttons = vec![
                    Some(input.leftButton()),
                    input.rightButton(),
                    input.middleButton(),
                ];
                if let Some(extra) = input.auxiliaryButtons() {
                    buttons.extend(extra.to_vec().into_iter().map(Some));
                }
                for (index, button) in buttons.into_iter().enumerate() {
                    if let Some(button) = button {
                        let handler = RcBlock::new(
                            move |_: NonNull<GCControllerButtonInput>, _: f32, down: Bool| {
                                push(Event::Button(index as u16, down.as_bool()));
                            },
                        );
                        button.setPressedChangedHandler(RcBlock::as_ptr(&handler));
                    }
                }
                let scroll =
                    RcBlock::new(|_: NonNull<GCControllerDirectionPad>, x: f32, y: f32| {
                        if x != 0.0 || y != 0.0 {
                            push(Event::Scroll(x, y));
                        }
                    });
                input
                    .scroll()
                    .setValueChangedHandler(RcBlock::as_ptr(&scroll));
            }
            if devices.mice.iter().any(|m| !mice.contains(m)) {
                push(Event::Reset);
            }
            devices.mice = mice;
        }
    });
    EVENTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .drain(..)
        .collect()
}

/// A finger takes precedence over hardware events queued before its contact.
pub fn discard() {
    EVENTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clear();
}
