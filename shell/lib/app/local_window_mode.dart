import 'package:flutter/foundation.dart';

/// Local playback can use the window the two ways users asked for: beside the
/// sidebar, or filling the whole window. The player's maximize button flips
/// this; the shell reads it to hide the sidebar while it is on.
class LocalWindowMode extends ChangeNotifier {
  bool _maximized = false;

  bool get maximized => _maximized;

  void setMaximized(bool value) {
    if (_maximized == value) return;
    _maximized = value;
    notifyListeners();
  }

  void toggle() => setMaximized(!_maximized);

  /// Called when the player closes: the next screen always gets the sidebar
  /// back.
  void reset() => setMaximized(false);
}
