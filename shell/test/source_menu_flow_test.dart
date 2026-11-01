import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/gateway/models.dart';
import 'package:free_player/core/theme/app_theme.dart';
import 'package:free_player/features/source/source_chooser.dart';

void main() {
  testWidgets('delete confirmation from menu', (tester) async {
    late BuildContext pageContext;
    var deleted = 0;
    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return SourceChooser(
                title: '切换内容源',
                subtitle: '已添加 1 个源',
                sources: const [
                  DiscoveredSource(
                    gatewayId: 'g1',
                    sourceId: 's1',
                    name: '红果短剧',
                    description: '短剧内容',
                  ),
                ],
                activeSourceId: 's1',
                localActive: false,
                onSelect: (_) async {},
                onOpenLocalFiles: () async {},
                onAdd: () async {},
                onEdit: (_) async {},
                onDelete: (_) async {
                  final ok = await showDialog<bool>(
                    context: pageContext,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('删除源'),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: const Text('确定删除'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) deleted++;
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确定删除'), findsOneWidget);
    await tester.tap(find.text('确定删除'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(tester.takeException(), isNull);
  });
}
