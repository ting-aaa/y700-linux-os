"""Exercise registration on the installed Onboard under an isolated X display."""
from types import SimpleNamespace
from unittest.mock import patch

from gi.repository import GLib
from Onboard import UDevTracker as module


subscribers = []
settings = SimpleNamespace(
    keyboard_device_detection_exceptions=[],
    keyboard_device_detection_exceptions_notify_add=subscribers.append,
    keyboard_device_detection_exceptions_notify_remove=subscribers.remove,
)
tracker = module.UDevTracker()


def changed(_detected):
    pass


with patch.object(module, "config", SimpleNamespace(auto_show=settings)):
    for _ in range(30):
        tracker.connect("keyboard-detection-changed", changed)
        assert len(subscribers) == 1 and tracker._udev is not None
        source = tracker._observer.event_source
        context = GLib.MainContext.default()
        assert context.find_source_by_id(source) is not None
        subscribers[0]([])
        tracker.disconnect("keyboard-detection-changed", changed)
        assert not subscribers and tracker._udev is None
        assert tracker._observer is None and context.find_source_by_id(source) is None

    with patch.object(module.osk, "UDev", side_effect=ValueError("unavailable")):
        tracker.connect("keyboard-detection-changed", changed)
        assert tracker.is_keyboard_device_detected() is None
        tracker.disconnect("keyboard-detection-changed", changed)
        assert not subscribers

print("Onboard GLib observer cycled 30 times and handled an unavailable monitor")
