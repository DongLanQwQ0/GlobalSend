import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'ui_tokens.dart';
import 'user_guide_content.g.dart';

/// The current platform's tasks, kept in sync with the Web guide and Markdown.
class UserGuideScreen extends StatefulWidget {
  const UserGuideScreen({super.key, this.platform});
  final String? platform;

  @override
  State<UserGuideScreen> createState() => _UserGuideScreenState();
}

class _UserGuideScreenState extends State<UserGuideScreen> {
  int topic = 0;

  @override
  Widget build(BuildContext context) {
    final platform =
        widget.platform ??
        switch (Theme.of(context).platform) {
          TargetPlatform.android => 'android',
          TargetPlatform.iOS => 'ipad',
          _ => 'windows',
        };
    final guide = userGuides[platform] ?? userGuides['windows']!;
    final section = guide.sections[topic];
    final colors = Ui.colors(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const AppIcon(Icons.arrow_back),
            ),
            title: const Text('使用指南'),
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  key: const ValueKey('user-guide-scroll'),
                  padding: const EdgeInsets.all(Ui.space3),
                  children: [
                    Text(
                      guide.name,
                      style: TextStyle(
                        color: colors.accent,
                        fontSize: Ui.textSm,
                        fontWeight: Ui.weightLabel,
                      ),
                    ),
                    const SizedBox(height: Ui.space1),
                    Text(
                      guide.intro,
                      style: const TextStyle(
                        fontSize: Ui.textBase,
                        height: Ui.leadingNormal,
                      ),
                    ),
                    const SizedBox(height: Ui.space4),
                    Wrap(
                      spacing: Ui.space1,
                      runSpacing: Ui.space1,
                      children: [
                        for (
                          var index = 0;
                          index < guide.sections.length;
                          index++
                        )
                          ChoiceChip(
                            key: ValueKey('guide-topic-$index'),
                            label: Text(guide.sections[index].title),
                            selected: topic == index,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => topic = index),
                          ),
                      ],
                    ),
                    const SizedBox(height: Ui.space3),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 180),
                      alignment: Alignment.topCenter,
                      curve: Curves.easeOutCubic,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          key: ValueKey('guide-section-$topic'),
                          width: double.infinity,
                          padding: const EdgeInsets.all(Ui.space4),
                          decoration: BoxDecoration(
                            color: colors.surface,
                            borderRadius: Ui.cardRadius,
                            border: Border.all(color: colors.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                section.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: Ui.space3),
                              for (
                                var index = 0;
                                index < section.steps.length;
                                index++
                              )
                                Padding(
                                  padding: EdgeInsets.only(
                                    bottom: index == section.steps.length - 1
                                        ? 0
                                        : Ui.space3,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                        width: Ui.space4,
                                        child: Text(
                                          '${index + 1}',
                                          style: TextStyle(
                                            color: colors.accent,
                                            fontSize: Ui.textSm,
                                            height: Ui.leadingNormal,
                                            fontWeight: Ui.weightLabel,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          section.steps[index],
                                          style: const TextStyle(
                                            fontSize: Ui.textSm,
                                            height: Ui.leadingNormal,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
