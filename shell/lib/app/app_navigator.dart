import 'package:flutter/foundation.dart';

/// Lets a full-screen route (the player) ask the shell to switch to a content
/// page after it closes. The shell owns the page state, so it consumes the
/// request on the next rebuild.
class AppNavigator extends ChangeNotifier {
  String? _request;

  /// Returns and clears the pending page, if any.
  String? takeRequest() {
    final request = _request;
    _request = null;
    return request;
  }

  void request(String page) {
    _request = page;
    notifyListeners();
  }
}
