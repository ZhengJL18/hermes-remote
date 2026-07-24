import 'dart:async';

enum GatewayState { idle, connecting, open, closed, error }

typedef VoidCallback = void Function();

class ConnectionManager {
  GatewayState _state = GatewayState.idle;
  Timer? _reconnectTimer;
  int _retryCount = 0;
  VoidCallback? _onReconnect;

  GatewayState get state => _state;

  void setState(GatewayState newState) {
    if (_state == newState) return;
    _state = newState;
    if (newState == GatewayState.closed || newState == GatewayState.error) {
      _scheduleReconnect();
    }
    if (newState == GatewayState.open) {
      _retryCount = 0;
    }
  }

  void setOnReconnect(VoidCallback cb) => _onReconnect = cb;

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = Duration(milliseconds: (1000 * (1 << _retryCount)).clamp(0, 30000));
    _retryCount++;
    _reconnectTimer = Timer(delay, () {
      setState(GatewayState.connecting);
      _onReconnect?.call();
    });
  }

  void dispose() => _reconnectTimer?.cancel();
}
