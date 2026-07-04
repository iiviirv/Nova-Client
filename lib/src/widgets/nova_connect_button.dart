import 'package:flutter/material.dart';

import '../core/proxy/proxy_controller.dart';
import '../theme/nova_semantics.dart';
import '../theme/nova_theme.dart';

/// The floating power button that overflows the center of the bottom bar — a
/// rounded gradient tile with a soft glow halo, colored by connection state
/// (cyan→violet off, green connected, amber busy). Shows a spinner while busy.
/// Mirrors the native `NovaConnectButton`.
class NovaConnectButton extends StatelessWidget {
  const NovaConnectButton({
    super.key,
    required this.state,
    this.onTap,
    this.size = 58,
    this.enabled = true,
  });

  final ProxyConnectionState state;
  final VoidCallback? onTap;
  final double size;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final visual = NovaConnectVisual.of(state, nova);
    final bool connected = state.isActive;
    final bool busy = state.isBusy;
    final double halo = size * 1.28;

    return Semantics(
      button: true,
      enabled: enabled,
      label: connected ? 'Disconnect' : 'Connect',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: halo,
          height: halo,
          transform: Matrix4.translationValues(0, connected ? -2 : 0, 0),
          transformAlignment: Alignment.center,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: visual.accent.withValues(alpha: 0.10),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: visual.linear(),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: visual.accent.withValues(alpha: 0.22),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                  spreadRadius: -6,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: busy
                ? SizedBox(
                    width: size * 0.42,
                    height: size * 0.42,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2.4,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(Icons.power_settings_new_rounded,
                    color: Colors.white,
                    size: size * 0.45),
          ),
        ),
      ),
    );
  }
}
