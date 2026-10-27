import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'system_bridge.dart';

class WebLink {
  const WebLink(this.start, this.end, this.label, this.uri);
  final int start, end;
  final String label;
  final Uri uri;
}

List<WebLink> findWebLinks(String text) {
  final matches = RegExp(
    r'''(?:https?://|www\.)[^\s<>"'，。；！？、【】《》“”‘’（）]+''',
    caseSensitive: false,
  ).allMatches(text);
  final links = <WebLink>[];
  for (final match in matches) {
    var label = match.group(0)!;
    label = label.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
    for (final pair in [('(', ')'), ('[', ']'), ('{', '}')]) {
      while (label.endsWith(pair.$2) &&
          pair.$2.allMatches(label).length > pair.$1.allMatches(label).length) {
        label = label.substring(0, label.length - 1);
      }
    }
    final uri = Uri.tryParse(
      label.toLowerCase().startsWith('www.') ? 'https://$label' : label,
    );
    if (uri == null ||
        uri.host.isEmpty ||
        !['http', 'https'].contains(uri.scheme.toLowerCase())) {
      continue;
    }
    links.add(WebLink(match.start, match.start + label.length, label, uri));
  }
  return links;
}

Future<void> openWebLink(BuildContext context, Uri uri) async {
  try {
    await SystemBridge.openWebUrl(uri);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('无法打开网址')));
    }
  }
}

/// Readable links without loading a remote page or disturbing whole-card drag.
class WebLinkText extends StatefulWidget {
  const WebLinkText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.onOpen,
  });
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final Future<void> Function(Uri)? onOpen;
  @override
  State<WebLinkText> createState() => _WebLinkTextState();
}

class _WebLinkTextState extends State<WebLinkText> {
  final recognizers = <TapGestureRecognizer>[];
  late List<WebLink> links;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  @override
  void didUpdateWidget(WebLinkText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) prepare();
  }

  void prepare() {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
    recognizers.clear();
    links = findWebLinks(widget.text);
    for (final link in links) {
      recognizers.add(
        TapGestureRecognizer()
          ..onTap = () {
            (widget.onOpen ?? (uri) => openWebLink(context, uri))(link.uri);
          },
      );
    }
  }

  @override
  void dispose() {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var offset = 0;
    for (var index = 0; index < links.length; index++) {
      final link = links[index];
      spans.add(TextSpan(text: widget.text.substring(offset, link.start)));
      spans.add(
        TextSpan(
          text: link.label,
          recognizer: recognizers[index],
          mouseCursor: SystemMouseCursors.click,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      );
      offset = link.end;
    }
    spans.add(TextSpan(text: widget.text.substring(offset)));
    final child = Text.rich(
      TextSpan(children: spans),
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
    return child;
  }
}
