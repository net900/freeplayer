import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/gateway/models.dart';
import 'package:free_player/core/theme/app_theme.dart';
import 'package:free_player/features/source/source_chooser.dart';

void main() {
  const sources = [
    DiscoveredSource(
      gatewayId: 'g1',
      sourceId: 's1',
      name: '红果短剧',
      description: '短剧内容，来自网友源。',
    ),
    DiscoveredSource(
      gatewayId: 'local:s2',
      sourceId: 's2',
      name: '555 影视',
      description: '本站内置的本地源。',
      isLocal: true,
    ),
  ];

  Future<void> pumpChooser(
    WidgetTester tester, {
    Size size = const Size(900, 720),
    List<DiscoveredSource> items = sources,
    Future<void> Function()? onAdd,
    Future<void> Function()? onShowRecommended,
    Widget? recommended,
    Future<void> Function(DiscoveredSource)? onSelect,
    Future<void> Function(DiscoveredSource)? onEdit,
    Future<void> Function(DiscoveredSource)? onDelete,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: SourceChooser(
              title: '选择内容源',
              subtitle: '已添加的源会列在这里。',
              sources: items,
              activeSourceId: 's1',
              localActive: false,
              recommended: recommended,
              onShowRecommended: onShowRecommended,
              onSelect: onSelect ?? (_) async {},
              onOpenLocalFiles: () async {},
              onAdd: () async {
                if (onAdd != null) await onAdd();
              },
              onEdit: onEdit ?? (_) async {},
              onDelete: onDelete ?? (_) async {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows only added sources and one add entry', (tester) async {
    await pumpChooser(tester);

    expect(find.text('红果短剧'), findsOneWidget);
    expect(find.text('555 影视'), findsOneWidget);
    expect(find.text('本机视频'), findsOneWidget);
    expect(find.text('添加源'), findsOneWidget);
    expect(find.text('官方推荐源'), findsNothing);
    expect(find.text('安装本地源'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local video tile is sized like a source tile', (tester) async {
    await pumpChooser(tester);

    final sourceRow = tester.getSize(
      find
          .ancestor(of: find.text('红果短剧'), matching: find.byType(InkWell))
          .first,
    );
    final localRow = tester.getSize(
      find
          .ancestor(of: find.text('本机视频'), matching: find.byType(InkWell))
          .first,
    );

    expect(localRow.height, sourceRow.height);
    expect(localRow.height, greaterThan(60));
  });

  testWidgets('three-dot menu opens at full size', (tester) async {
    var selected = 0;
    await pumpChooser(tester, onSelect: (_) async => selected++);

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    expect(find.text('编辑地址'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    final item = tester.getSize(
      find
          .ancestor(
            of: find.text('编辑地址'),
            matching: find.byType(PopupMenuItem<String>),
          )
          .first,
    );
    expect(item.width, greaterThan(80));
    expect(item.height, greaterThan(30));
    expect(selected, 0);
  });

  testWidgets('recommended panel is inline and can be reopened',
      (tester) async {
    await pumpChooser(tester, recommended: const Text('推荐面板内容'));
    expect(find.text('推荐面板内容'), findsOneWidget);
    expect(find.text('显示官方推荐源'), findsNothing);

    var reopened = 0;
    await pumpChooser(
      tester,
      onShowRecommended: () async => reopened++,
    );
    expect(find.text('显示官方推荐源'), findsOneWidget);
    await tester.tap(find.text('显示官方推荐源'));
    expect(reopened, 1);
  });

  testWidgets('add entry starts the add flow', (tester) async {
    var tapped = 0;
    await pumpChooser(tester, onAdd: () async => tapped++);

    await tester.tap(find.text('添加源'));
    await tester.pump();

    expect(tapped, 1);
  });

  testWidgets('many sources wrap into rows without overflowing',
      (tester) async {
    final many = List.generate(
      12,
      (index) => DiscoveredSource(
        gatewayId: 'g$index',
        sourceId: 's$index',
        name: '源 $index',
        description: '第 $index 个源',
      ),
    );
    await pumpChooser(tester, size: const Size(1000, 900), items: many);

    expect(find.text('源 0'), findsOneWidget);
    expect(find.text('源 11'), findsOneWidget);
    expect(find.text('添加源'), findsOneWidget);
    final firstRow = tester.getTopLeft(find.text('源 0'));
    final secondRow = tester.getTopLeft(find.text('源 3'));
    expect(secondRow.dy, greaterThan(firstRow.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles fit a narrow window without overflowing', (tester) async {
    await pumpChooser(tester, size: const Size(360, 640));

    expect(find.text('添加源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
