import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/proxy/proxy_controller.dart';
import '../../core/util/format.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_gradients.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_logo.dart';
import '../../widgets/nova_scope.dart';

/// The home screen: the connect control, live status and traffic, and the
/// active profile. The connect orb is the visual anchor of the app.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    final s = NovaStrings.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[scope.proxy, scope.profiles]),
      builder: (context, _) {
        final proxy = scope.proxy;
        final active = scope.profiles.active;
        // Keep the proxy's selected profile in sync with the active profile.
        if (proxy.activeProfile?.id != active?.id) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            proxy.selectProfile(active);
          });
        }

        return Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: ListView(
              padding: const EdgeInsets.all(NovaSpace.xl),
              children: <Widget>[
                _Header(),
                const SizedBox(height: NovaSpace.xxl),
                Center(
                  child: _ConnectOrb(
                    state: proxy.state,
                    onTap: active == null ? null : proxy.toggle,
                  ),
                ),
                const SizedBox(height: NovaSpace.xl),
                Center(child: _StatusText(state: proxy.state, error: proxy.lastError)),
                const SizedBox(height: NovaSpace.xxl),
                _TrafficRow(traffic: proxy.traffic, active: proxy.state.isActive),
                const SizedBox(height: NovaSpace.lg),
                _ActiveProfileCard(s: s),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const NovaLogo(size: 34),
        const SizedBox(width: NovaSpace.md),
        Text('Nova Client',
            style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
      ],
    );
  }
}

class _ConnectOrb extends StatefulWidget {
  const _ConnectOrb({required this.state, required this.onTap});
  final ProxyConnectionState state;
  final VoidCallback? onTap;

  @override
  State<_ConnectOrb> createState() => _ConnectOrbState();
}

class _ConnectOrbState extends State<_ConnectOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final bool active = widget.state.isActive;
    final bool busy = widget.state.isBusy;

    final String label = switch (widget.state) {
      ProxyConnectionState.connected => s.disconnect,
      ProxyConnectionState.connecting => s.connecting,
      ProxyConnectionState.disconnecting => s.connecting,
      _ => s.connect,
    };

    return GestureDetector(
      onTap: busy ? null : widget.onTap,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          return SizedBox(
            width: 240,
            height: 240,
            child: CustomPaint(
              painter: _OrbPainter(
                t: _pulse.value,
                active: active,
                cyan: nova.cyan,
                violet: nova.violet,
                ring: nova.border,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (busy)
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: nova.cyan,
                        ),
                      )
                    else
                      Icon(
                        Icons.power_settings_new,
                        size: 56,
                        color: active ? nova.cyan : nova.muted,
                      ),
                    const SizedBox(height: 10),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: active ? nova.text : nova.muted,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.t,
    required this.active,
    required this.cyan,
    required this.violet,
    required this.ring,
  });

  final double t;
  final bool active;
  final Color cyan;
  final Color violet;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;

    // Idle ring.
    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ring;
    canvas.drawCircle(c, r - 16, ringPaint);

    if (active) {
      // Expanding pulse rings.
      for (int i = 0; i < 2; i++) {
        final double phase = (t + i * 0.5) % 1.0;
        final double radius = (r - 60) + phase * 56;
        final Paint pulse = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = cyan.withValues(alpha: (1 - phase) * 0.5);
        canvas.drawCircle(c, radius, pulse);
      }
      // Glow.
      final Paint glow = Paint()
        ..shader = NovaGradients.glow(cyan, opacity: 0.45)
            .createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, glow);
    }

    // Inner disc with the signature gradient sweep.
    final Rect inner = Rect.fromCircle(center: c, radius: r - 30);
    final Paint disc = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        transform: GradientRotation(t * 2 * math.pi),
        colors: active
            ? <Color>[cyan, violet, cyan]
            : <Color>[ring, ring.withValues(alpha: 0.4), ring],
      ).createShader(inner);
    canvas.drawCircle(c, r - 30, disc..style = PaintingStyle.stroke..strokeWidth = 4);
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.active != active;
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.state, required this.error});
  final ProxyConnectionState state;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    final s = NovaStrings.of(context);
    final (String text, Color color) = switch (state) {
      ProxyConnectionState.connected => (s.connected, nova.success),
      ProxyConnectionState.connecting => (s.connecting, nova.cyan),
      ProxyConnectionState.disconnecting => (s.connecting, nova.muted),
      ProxyConnectionState.error => (error ?? 'Error', nova.danger),
      ProxyConnectionState.disconnected => (s.disconnected, nova.muted),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: color)),
      ],
    );
  }
}

class _TrafficRow extends StatelessWidget {
  const _TrafficRow({required this.traffic, required this.active});
  final TrafficStats traffic;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final s = NovaStrings.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: _TrafficTile(
            icon: Icons.south_rounded,
            label: s.download,
            value: active ? Fmt.bps(traffic.downlinkBps) : '—',
            total: active ? Fmt.bytes(traffic.downlinkTotal) : null,
            color: context.nova.cyan,
          ),
        ),
        const SizedBox(width: NovaSpace.md),
        Expanded(
          child: _TrafficTile(
            icon: Icons.north_rounded,
            label: s.upload,
            value: active ? Fmt.bps(traffic.uplinkBps) : '—',
            total: active ? Fmt.bytes(traffic.uplinkTotal) : null,
            color: context.nova.violet,
          ),
        ),
      ],
    );
  }
}

class _TrafficTile extends StatelessWidget {
  const _TrafficTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.total,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final nova = context.nova;
    return NovaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: nova.muted)),
            ],
          ),
          const SizedBox(height: 8),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
          if (total != null)
            Text(total!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: nova.muted)),
        ],
      ),
    );
  }
}

class _ActiveProfileCard extends StatelessWidget {
  const _ActiveProfileCard({required this.s});
  final NovaStrings s;

  @override
  Widget build(BuildContext context) {
    final scope = NovaScope.of(context);
    final nova = context.nova;
    final active = scope.profiles.active;

    return NovaCard(
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: nova.surface2,
              borderRadius: NovaRadii.smR,
            ),
            child: Icon(Icons.layers, color: nova.cyan, size: 20),
          ),
          const SizedBox(width: NovaSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.activeProfile,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: nova.muted)),
                const SizedBox(height: 2),
                Text(
                  active?.name ?? s.noProfile,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (active?.lastLatencyMs != null)
            Text('${active!.lastLatencyMs} ms',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: nova.success)),
        ],
      ),
    );
  }
}
