import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/logging/nova_log.dart';
import '../../l10n/nova_strings.dart';
import '../../theme/nova_radii.dart';
import '../../theme/nova_theme.dart';
import '../../theme/nova_typography.dart';
import '../../widgets/nova_button.dart';
import '../../widgets/nova_card.dart';
import '../../widgets/nova_pill.dart';
import '../../widgets/nova_scope.dart';
import '../settings/settings_controller.dart';

/// Log body metrics. The log is machine output, so it keeps its own small
/// monospace size rather than following the UI type scale, but it still honours
/// the platform text scale, so the row height is derived, never hard-coded.
const double _kLogFontSize = 12;
const double _kLogLineSpacing = 1.5;

/// Severity rail: a 3px stripe in the start gutter. Colour lives here (not in
/// the message text) so severity is obvious at a glance while every line stays
/// at full text contrast in both themes.
const double _kRailWidth = 3;
const double _kRailGap = 9;
const double _kRailInset = 6;

/// `HH:MM:SS.mmm` is always 12 characters, which is what the content width of
/// the horizontal scroll is measured from.
const int _kClockChars = 12;

/// How close to the end still counts as "docked at the bottom".
const double _kBottomSlack = 24;

/// The troubleshooting log viewer.
///
/// Two streams kept apart on purpose (what Nova decided, and what the sing-box
/// core saw) because "it says connected but nothing loads" is answered by one
/// or the other, never by both interleaved. The screen is built around the one
/// thing a user actually does here: find the line that explains it, then copy
/// the stream into a support chat, which is why the redaction promise sits on
/// the Copy button rather than in a banner somewhere.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();

  NovaLogSource _source = NovaLogSource.app;

  /// Auto-scroll to the newest line. On by default, and switched off the moment
  /// the user drags away from the bottom: yanking the view out from under
  /// someone who is reading is the worst thing this screen could do.
  bool _follow = true;

  /// Guards against queueing one post-frame scroll per rebuild.
  bool _pendingFollow = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _setSource(NovaLogSource source) {
    if (source == _source) return;
    setState(() {
      _source = source;
      // A fresh stream opens on its newest line, like re-opening the screen.
      _follow = true;
    });
    _scheduleFollow();
  }

  void _toggleFollow() {
    final bool next = !_follow;
    setState(() => _follow = next);
    if (next) _jumpToEnd(animated: true);
  }

  void _jumpToEnd({bool animated = false}) {
    if (!_scroll.hasClients) return;
    final double end = _scroll.position.maxScrollExtent;
    if (animated && !MediaQuery.disableAnimationsOf(context)) {
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(end);
    }
  }

  /// Called from build: after the new lines are laid out, ride the bottom.
  void _scheduleFollow() {
    if (!_follow || _pendingFollow) return;
    _pendingFollow = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingFollow = false;
      if (!mounted || !_follow || !_scroll.hasClients) return;
      final ScrollPosition p = _scroll.position;
      if (p.pixels < p.maxScrollExtent) _jumpToEnd();
    });
  }

  /// Follow is a consequence of where the user put the view, not a mode they
  /// have to remember to switch. Dragging away turns it off immediately (so it
  /// never fights the drag); coming to rest at the bottom turns it back on.
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final bool atBottom =
        n.metrics.pixels >= n.metrics.maxScrollExtent - _kBottomSlack;
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      if (_follow && !atBottom) setState(() => _follow = false);
    } else if (n is ScrollEndNotification) {
      if (_follow != atBottom) setState(() => _follow = atBottom);
    }
    return false;
  }

  Future<void> _copy() async {
    final NovaStrings s = NovaStrings.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(text: NovaLog.instance.export(_source)),
    );
    if (!mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s.logsCopied)));
  }

  @override
  Widget build(BuildContext context) {
    final NovaStrings s = NovaStrings.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.logsTitle),
        actions: <Widget>[
          ListenableBuilder(
            listenable: NovaLog.instance,
            builder: (BuildContext context, _) {
              final bool empty = NovaLog.instance.count(_source) == 0;
              return IconButton(
                tooltip: s.logsClear,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: empty ? null : () => NovaLog.instance.clear(_source),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: NovaSpace.maxContentWidth),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                return ListenableBuilder(
                  listenable: NovaLog.instance,
                  builder: (BuildContext context, _) {
                    final List<NovaLogEntry> entries =
                        NovaLog.instance.lines(_source);
                    _scheduleFollow();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _header(context, s, entries.length,
                            // Orientation copy is the first thing to go when
                            // the viewport is short: the log needs the room
                            // more than the explanation does. Measured in
                            // text-sized units, so a large accessibility scale
                            // drops it for the same reason a small screen does.
                            showSubtitle: box.maxHeight >
                                620 *
                                    (MediaQuery.textScalerOf(context)
                                            .scale(14) /
                                        14)),
                        // The log owns the screen; the chrome is a thin band
                        // above and a share block below.
                        Expanded(child: _console(context, s, entries)),
                        _footer(context, s, box, entries.isNotEmpty),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---- Header: what this screen is, which stream, how much of it ----

  Widget _header(BuildContext context, NovaStrings s, int count,
      {required bool showSubtitle}) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          NovaSpace.lg, NovaSpace.md, NovaSpace.lg, NovaSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (showSubtitle) ...<Widget>[
            Text(s.logsSubtitle,
                style: text.bodySmall?.copyWith(color: nova.muted)),
            const SizedBox(height: NovaSpace.md),
          ],
          // A Row cannot hold this: the two pills and the count are all
          // intrinsically sized, so at a large text scale (or with Farsi
          // labels) they exceed a 320dp screen and overflow. Wrap flows the
          // count onto its own line instead, at any scale, in either script.
          Wrap(
            spacing: NovaSpace.sm,
            runSpacing: NovaSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _target(
                selected: _source == NovaLogSource.app,
                onTap: () => _setSource(NovaLogSource.app),
                // Vertical slop only: horizontal slop on two adjacent pills
                // would put their hit areas back to back.
                padding: const EdgeInsets.symmetric(vertical: NovaSpace.sm),
                child: NovaPill(
                  label: s.logsTabApp,
                  icon: Icons.bolt_rounded,
                  selected: _source == NovaLogSource.app,
                  onTap: () => _setSource(NovaLogSource.app),
                ),
              ),
              _target(
                selected: _source == NovaLogSource.core,
                onTap: () => _setSource(NovaLogSource.core),
                padding: const EdgeInsets.symmetric(vertical: NovaSpace.sm),
                child: NovaPill(
                  label: s.logsTabCore,
                  icon: Icons.terminal_rounded,
                  selected: _source == NovaLogSource.core,
                  onTap: () => _setSource(NovaLogSource.core),
                ),
              ),
              Padding(
                // A touch more air than the gap between the two pills, so the
                // count reads as a caption on the stream rather than a third
                // option in the switch.
                padding:
                    const EdgeInsetsDirectional.only(start: NovaSpace.sm),
                child: Text(
                  s.logsLineCount(count),
                  style: text.labelSmall?.copyWith(
                    color: nova.muted,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- Console: the log itself ----

  Widget _console(
      BuildContext context, NovaStrings s, List<NovaLogEntry> entries) {
    final nova = context.nova;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NovaSpace.lg),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: nova.codeBg,
          borderRadius: NovaRadii.cardR,
          border: Border.all(color: nova.border),
        ),
        child: entries.isEmpty
            ? _empty(context, s)
            : LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) {
                  return Stack(
                    children: <Widget>[
                      // Machine output stays left-to-right even in Farsi: a
                      // timestamped core line mirrored into RTL is unreadable.
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: _lines(context, entries, box.maxWidth),
                      ),
                      // Follow is docked on the log, where the thumb already
                      // is, and its selected state is the live indicator.
                      PositionedDirectional(
                        end: NovaSpace.sm,
                        bottom: NovaSpace.sm,
                        child: _followPill(context, s,
                            maxWidth: box.maxWidth - NovaSpace.lg),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _lines(
      BuildContext context, List<NovaLogEntry> entries, double viewport) {
    final nova = context.nova;
    final TextScaler scaler = MediaQuery.textScalerOf(context);

    final TextStyle mono = TextStyle(
      fontFamily: NovaTypography.fontMono,
      fontFamilyFallback: NovaTypography.monoFallback,
      fontSize: _kLogFontSize,
      height: _kLogLineSpacing,
      color: nova.text,
    );

    // One measured advance drives both the row height and the scrollable width,
    // so the layout is correct at any platform text scale.
    final double charWidth = _measureChar(mono, scaler);
    final double lineHeight =
        scaler.scale(_kLogFontSize) * _kLogLineSpacing + 4;

    int longest = 0;
    for (final NovaLogEntry e in entries) {
      final String? tag = _levelTag(e.level);
      final int chars = _kClockChars +
          2 +
          (tag == null ? 0 : tag.length + 2) +
          e.message.length;
      if (chars > longest) longest = chars;
    }
    final double content = _kRailInset +
        _kRailWidth +
        _kRailGap +
        longest * charWidth +
        NovaSpace.xxl;

    // The log ends far enough above the floating Follow control that the newest
    // line is never hidden behind it: the newest line is the one being read.
    final double followClearance =
        scaler.scale(13) * 1.2 + NovaSpace.md + NovaSpace.lg + NovaSpace.sm;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        // Long lines scroll sideways rather than wrapping into mush; short
        // logs still fill the panel so the empty right edge isn't draggable.
        width: math.max(viewport, content),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: SelectionArea(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: lineHeight,
              padding: EdgeInsets.only(
                  top: NovaSpace.sm, bottom: NovaSpace.sm + followClearance),
              itemCount: entries.length,
              itemBuilder: (BuildContext context, int i) =>
                  _line(context, entries[i], mono, lineHeight),
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(BuildContext context, NovaLogEntry e, TextStyle mono,
      double lineHeight) {
    final nova = context.nova;

    // Severity is carried by the rail's hue, plus a non-colour signal for every
    // step: no rail (routine), a rail and a word (warn), a rail, a word, bolder
    // text and a tinted row (error). Never hue alone.
    final Color rail = switch (e.level) {
      NovaLogLevel.error => nova.danger,
      NovaLogLevel.warn => nova.warning,
      NovaLogLevel.info || NovaLogLevel.debug => Colors.transparent,
    };
    final Color tint = e.level == NovaLogLevel.error
        ? nova.danger.withValues(alpha: 0.09)
        : Colors.transparent;
    final Color message =
        e.level == NovaLogLevel.debug ? nova.muted : nova.text;
    final FontWeight weight = switch (e.level) {
      NovaLogLevel.error => FontWeight.w600,
      NovaLogLevel.warn => FontWeight.w500,
      NovaLogLevel.info || NovaLogLevel.debug => FontWeight.w400,
    };
    final String? tag = _levelTag(e.level);

    return Container(
      color: tint,
      alignment: Alignment.centerLeft,
      child: Row(
        children: <Widget>[
          const SizedBox(width: _kRailInset),
          Container(
            width: _kRailWidth,
            height: lineHeight - 6,
            decoration: BoxDecoration(
              color: rail,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: _kRailGap),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${e.clock}  ',
                    style: TextStyle(color: nova.muted),
                  ),
                  if (tag != null)
                    TextSpan(
                      text: '$tag  ',
                      style: TextStyle(
                          color: nova.text, fontWeight: FontWeight.w700),
                    ),
                  TextSpan(
                    text: e.message,
                    style: TextStyle(color: message, fontWeight: weight),
                  ),
                ],
              ),
              style: mono,
              softWrap: false,
              maxLines: 1,
              overflow: TextOverflow.fade,
            ),
          ),
        ],
      ),
    );
  }

  Widget _followPill(BuildContext context, NovaStrings s,
      {required double maxWidth}) {
    final nova = context.nova;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.max(0, maxWidth)),
      child: _target(
        selected: _follow,
        onTap: _toggleFollow,
        padding: const EdgeInsets.all(NovaSpace.sm),
        // A floating control has no room to wrap, and its label is the longest
        // string on the screen. Rather than clip it against the console edge on
        // a narrow phone at a large text scale, it scales down to fit, and
        // only then: at ordinary sizes scaleDown is a no-op.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: DecoratedBox(
            // Opaque under the pill so log text never shows through it.
            decoration: BoxDecoration(
              color: nova.codeBg,
              borderRadius: NovaRadii.pillR,
            ),
            child: NovaPill(
              label: s.logsFollow,
              icon: Icons.arrow_downward_rounded,
              selected: _follow,
              onTap: _toggleFollow,
            ),
          ),
        ),
      ),
    );
  }

  /// A pill with hit slop and its selected state exposed to assistive tech.
  ///
  /// The pills are ~28px tall, which is under the 44px touch target, and their
  /// state is otherwise carried by colour alone. Neither is acceptable for the
  /// two controls this screen is operated with.
  Widget _target({
    required Widget child,
    required VoidCallback onTap,
    required bool selected,
    required EdgeInsets padding,
  }) {
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, NovaStrings s) {
    final nova = context.nova;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NovaSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.terminal_rounded, size: 26, color: nova.muted),
            const SizedBox(height: NovaSpace.md),
            Text(
              _source == NovaLogSource.app ? s.logsEmptyApp : s.logsEmptyCore,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: nova.muted),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Footer: the promise, the share, the setting ----

  Widget _footer(BuildContext context, NovaStrings s, BoxConstraints box,
      bool hasLines) {
    final nova = context.nova;
    final TextTheme text = Theme.of(context).textTheme;

    return ConstrainedBox(
      // The console is the focal element, so on a short viewport (small device,
      // large accessibility text) the share block scrolls within its share
      // rather than squeezing the log down to two lines or overflowing.
      constraints: BoxConstraints(maxHeight: box.maxHeight * 0.42),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(NovaSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // The action leads, so it stays above the fold when a large text
              // scale makes the note tall; the redaction promise sits directly
              // under it, where the fine print on a button belongs, never in
              // a banner somewhere the user scrolled past.
              NovaButton(
                label: s.logsCopy,
                icon: Icons.content_copy_rounded,
                expand: true,
                onPressed: hasLines ? _copy : null,
              ),
              const SizedBox(height: NovaSpace.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.lock_outline_rounded, size: 16, color: nova.muted),
                  const SizedBox(width: NovaSpace.sm),
                  Expanded(
                    child: Text(
                      s.logsRedactNote,
                      style: text.bodySmall?.copyWith(color: nova.muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NovaSpace.lg),
              NovaCard(
                padding: EdgeInsets.zero,
                child: ListenableBuilder(
                  listenable: NovaScope.of(context).settings,
                  builder: (BuildContext context, _) {
                    final SettingsController settings =
                        NovaScope.of(context).settings;
                    return SwitchListTile(
                      value: settings.verboseCoreLog,
                      onChanged: (bool v) => settings.setVerboseCoreLog(v),
                      secondary:
                          Icon(Icons.notes_rounded, color: nova.cyan),
                      title: Text(s.logsVerbose, style: text.bodyMedium),
                      subtitle: Text(
                        s.logsVerboseSub,
                        style: text.bodySmall?.copyWith(color: nova.muted),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The word shown in-line for the levels that must stand out. Routine lines get
/// no tag, which keeps the message column wide on a phone.
String? _levelTag(NovaLogLevel level) => switch (level) {
      NovaLogLevel.error || NovaLogLevel.warn => level.label,
      NovaLogLevel.info || NovaLogLevel.debug => null,
    };

/// Advance width of one character in [style]. Measured from 'M' so a device
/// that resolves none of the monospace families over-estimates rather than
/// clipping the longest line.
double _measureChar(TextStyle style, TextScaler scaler) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: 'M' * 10, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final double width = painter.width / 10;
  painter.dispose();
  return width;
}
