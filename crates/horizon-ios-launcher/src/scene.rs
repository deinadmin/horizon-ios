//! Single-scene adapter for winit 0.30's application-notification lifecycle.
//! Register before UIApplicationMain; attach both the loading and game windows.
use std::cell::RefCell;

use objc2::rc::Retained;
use objc2::{ClassType, DeclaredClass, declare_class, mutability};
use objc2_foundation::{
    MainThreadMarker, NSNotificationCenter, NSObject, NSObjectProtocol, NSString,
};
use objc2_ui_kit::{
    UIApplication, UIApplicationDidBecomeActiveNotification,
    UIApplicationDidEnterBackgroundNotification, UIApplicationWillEnterForegroundNotification,
    UIApplicationWillResignActiveNotification, UIScene, UISceneConnectionOptions, UISceneDelegate,
    UISceneSession, UIView, UIWindow, UIWindowScene,
};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

thread_local! {
    static SCENE: RefCell<Option<Retained<UIWindowScene>>> = const { RefCell::new(None) };
    static WINDOW: RefCell<Option<Retained<UIWindow>>> = const { RefCell::new(None) };
}

fn connect_window() {
    let scene = SCENE.with(|slot| slot.borrow().clone());
    let window = WINDOW.with(|slot| slot.borrow().clone());
    if let (Some(scene), Some(window)) = (scene, window) {
        // SAFETY: both objects are retained and accessed only on UIKit's main thread.
        unsafe { window.setWindowScene(Some(&scene)) };
        window.makeKeyAndVisible();
    }
}

fn notify(name: &NSString) {
    let mtm = MainThreadMarker::new().expect("scene callbacks run on the main thread");
    // SAFETY: UIKit's notification names and UIApplication object match winit's observers.
    unsafe {
        NSNotificationCenter::defaultCenter()
            .postNotificationName_object(name, Some(&UIApplication::sharedApplication(mtm)));
    }
}

declare_class!(
    struct HorizonSceneDelegate;

    // SAFETY: NSObject superclass, no additional ivars, and UIKit main-thread confinement.
    unsafe impl ClassType for HorizonSceneDelegate {
        type Super = NSObject;
        type Mutability = mutability::MainThreadOnly;
        const NAME: &'static str = "HorizonSceneDelegate";
    }
    impl DeclaredClass for HorizonSceneDelegate {}
    unsafe impl NSObjectProtocol for HorizonSceneDelegate {}

    unsafe impl UISceneDelegate for HorizonSceneDelegate {
        #[method(scene:willConnectToSession:options:)]
        fn connect(&self, scene: &UIScene, _session: &UISceneSession, _options: &UISceneConnectionOptions) {
            if scene.isKindOfClass(UIWindowScene::class()) {
                // SAFETY: the class check proves this is a UIWindowScene; retain it beyond the callback.
                let scene = unsafe { Retained::retain(scene as *const UIScene as *mut UIWindowScene) };
                SCENE.with(|slot| *slot.borrow_mut() = scene);
                connect_window();
            }
        }

        #[method(sceneDidBecomeActive:)]
        fn active(&self, _scene: &UIScene) {
            // SAFETY: UIKit-provided constant notification name.
            notify(unsafe { UIApplicationDidBecomeActiveNotification });
        }

        #[method(sceneWillResignActive:)]
        fn inactive(&self, _scene: &UIScene) {
            // SAFETY: UIKit-provided constant notification name.
            notify(unsafe { UIApplicationWillResignActiveNotification });
        }

        #[method(sceneWillEnterForeground:)]
        fn foreground(&self, _scene: &UIScene) {
            // SAFETY: UIKit-provided constant notification name.
            notify(unsafe { UIApplicationWillEnterForegroundNotification });
        }

        #[method(sceneDidEnterBackground:)]
        fn background(&self, _scene: &UIScene) {
            // SAFETY: UIKit-provided constant notification name.
            notify(unsafe { UIApplicationDidEnterBackgroundNotification });
        }

        #[method(sceneDidDisconnect:)]
        fn disconnect(&self, _scene: &UIScene) {
            let window = WINDOW.with(|slot| slot.borrow().clone());
            if let Some(window) = window {
                // SAFETY: main-thread-owned window, detached from the disconnected scene.
                unsafe { window.setWindowScene(None) };
            }
            SCENE.with(|slot| *slot.borrow_mut() = None);
        }
    }
);

/// Register the class named by GameInfo.plist before UIKit resolves the scene manifest.
pub fn register() {
    assert!(MainThreadMarker::new().is_some());
    let _ = HorizonSceneDelegate::class();
}

/// Attach a winit window to the current scene, or retain it until the scene connects.
pub fn attach(window: &impl HasWindowHandle) {
    assert!(MainThreadMarker::new().is_some());
    let handle = window.window_handle().expect("live iOS window");
    let RawWindowHandle::UiKit(handle) = handle.as_raw() else {
        return;
    };
    // SAFETY: HasWindowHandle guarantees a valid UIView for this borrowed handle;
    // the window remains alive throughout this call and UIKit is on its main thread.
    let view = unsafe { &*handle.ui_view.as_ptr().cast::<UIView>() };
    WINDOW.with(|slot| *slot.borrow_mut() = view.window());
    connect_window();
    install_input_adapter(view);
}

// UIKit asks the top controller; the launcher keeps its ordinary pointer, while
// the game controller opts into pointer lock only when mouse control is active.
static POINTER_LOCK: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn prefers_lock(
    _: &objc2::runtime::AnyObject,
    _: objc2::runtime::Sel,
) -> objc2::runtime::Bool {
    objc2::runtime::Bool::new(POINTER_LOCK.load(std::sync::atomic::Ordering::Relaxed))
}

// Independent of pointer lock: touch players need bottom-edge protection too.
static GAME_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

extern "C" fn deferred_edges(
    _: &objc2::runtime::AnyObject,
    _: objc2::runtime::Sel,
) -> objc2_ui_kit::UIRectEdge {
    if GAME_RUNNING.load(std::sync::atomic::Ordering::Relaxed) {
        objc2_ui_kit::UIRectEdge::Bottom
    } else {
        objc2_ui_kit::UIRectEdge::None
    }
}

/// Request the system's two-swipe Home gesture only during a game session.
/// Full-screen launcher controllers keep UIKit's default (no deferred edges).
pub fn set_game_running(running: bool) {
    assert!(MainThreadMarker::new().is_some());
    if GAME_RUNNING.swap(running, std::sync::atomic::Ordering::Relaxed) == running {
        return;
    }
    WINDOW.with(|w| {
        if let Some(controller) = w.borrow().as_ref().and_then(|w| w.rootViewController()) {
            controller.setNeedsUpdateOfScreenEdgesDeferringSystemGestures();
        }
    });
}

pub fn game_active() -> bool {
    WINDOW.with(|w| {
        w.borrow()
            .as_ref()
            .and_then(|w| w.rootViewController())
            .is_some_and(|c| unsafe { c.presentedViewController().is_none() })
    })
}

pub fn lock_pointer(lock: bool) {
    assert!(MainThreadMarker::new().is_some());
    if POINTER_LOCK.swap(lock, std::sync::atomic::Ordering::Relaxed) == lock {
        return;
    }
    WINDOW.with(|w| {
        if let Some(c) = w.borrow().as_ref().and_then(|w| w.rootViewController()) {
            // SAFETY: retained controller on UIKit's main thread.
            unsafe {
                c.setNeedsUpdateOfPrefersPointerLocked();
            }
        }
    });
}

fn install_input_adapter(view: &UIView) {
    use objc2::runtime::{AnyClass, AnyObject, ClassBuilder};
    use objc2::sel;
    let object: &AnyObject = view;
    let class = AnyClass::get("HorizonInputView").unwrap_or_else(|| {
        let mut builder = ClassBuilder::new("HorizonInputView", object.class()).unwrap();
        // SAFETY: UIKit's touch method ABI; subclass adds no storage.
        unsafe {
            builder.add_method(
                sel!(touchesBegan:withEvent:),
                fingers_began as extern "C" fn(_, _, _, _),
            );
            builder.add_method(
                sel!(touchesMoved:withEvent:),
                fingers_moved as extern "C" fn(_, _, _, _),
            );
            builder.add_method(
                sel!(touchesEnded:withEvent:),
                fingers_ended as extern "C" fn(_, _, _, _),
            );
            builder.add_method(
                sel!(touchesCancelled:withEvent:),
                fingers_cancelled as extern "C" fn(_, _, _, _),
            );
        }
        builder.register()
    });
    // SAFETY: no additional ivars; superclass is the original winit view class.
    unsafe {
        AnyObject::set_class(object, class);
    }
    let Some(controller) = view.window().and_then(|w| w.rootViewController()) else {
        return;
    };
    let object: &AnyObject = &controller;
    let class = AnyClass::get("HorizonPointerController").unwrap_or_else(|| {
        let mut builder = ClassBuilder::new("HorizonPointerController", object.class()).unwrap();
        // SAFETY: same ABI as UIViewController.prefersPointerLocked, no added ivars.
        unsafe {
            builder.add_method(
                sel!(prefersPointerLocked),
                prefers_lock as extern "C" fn(_, _) -> objc2::runtime::Bool,
            );
            builder.add_method(
                sel!(preferredScreenEdgesDeferringSystemGestures),
                deferred_edges as extern "C" fn(_, _) -> objc2_ui_kit::UIRectEdge,
            );
        }
        builder.register()
    });
    // SAFETY: layout-compatible subclass of this winit controller, no extra ivars.
    unsafe {
        AnyObject::set_class(object, class);
    }
}

// UIKit sends indirect-pointer contacts as touches too. Keep those out of
// winit's finger path: GameController already delivers their mouse buttons.
macro_rules! forward_fingers {
    ($name:ident, $selector:ident) => {
        extern "C" fn $name(
            this: &objc2::runtime::AnyObject,
            _: objc2::runtime::Sel,
            touches: &objc2_foundation::NSSet<objc2_ui_kit::UITouch>,
            event: Option<&objc2_ui_kit::UIEvent>,
        ) {
            use objc2_ui_kit::UITouchType;
            let fingers: Vec<_> = touches.iter()
                .filter(|t| matches!(t.r#type(), UITouchType::Direct | UITouchType::Pencil))
                .collect();
            if fingers.is_empty() { return; }
            let pointers: Vec<_> = fingers.iter().map(|t| &**t as *const objc2_ui_kit::UITouch).collect();
            // SAFETY: each pointer remains retained in fingers; NSSet retains its
            // members and UITouch identity/hash is stable for the event's lifetime.
            let set: Retained<objc2_foundation::NSSet<objc2_ui_kit::UITouch>> = unsafe {
                objc2::msg_send_id![objc2::class!(NSSet), setWithObjects: pointers.as_ptr() count: pointers.len()]
            };
            // SAFETY: layout-compatible view subclass, documented touch-method
            // signature; forward only finger/stylus contacts to winit's superclass.
            unsafe {
                let superclass = this.class().superclass().unwrap();
                let _: () = objc2::msg_send![super(this, superclass), $selector: &*set withEvent: event];
            }
        }
    };
}
forward_fingers!(fingers_began, touchesBegan);
forward_fingers!(fingers_moved, touchesMoved);
forward_fingers!(fingers_ended, touchesEnded);
forward_fingers!(fingers_cancelled, touchesCancelled);
