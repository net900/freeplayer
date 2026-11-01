import 'package:flutter_test/flutter_test.dart';
import 'package:free_player/core/sp/models.dart';
import 'package:free_player/core/sp/quality.dart';

void main() {
  test('MediaPlan parses streams and decryption declaration', () {
    final plan = MediaPlan.fromJson({
      'item_id': 'i1',
      'episode_id': 'e1',
      'streams': [
        {'id': '720p', 'height': 720, 'url': 'https://cdn/720.mp4'},
        {'id': '1080p', 'height': 1080, 'url': 'https://cdn/1080.mp4'},
      ],
      'decryption': {
        'required': true,
        'algorithm': 'cenc-ctr',
        'location': 'server',
      },
      'expires_at': '2099-01-01T00:00:00Z',
    });
    expect(plan.streams.length, 2);
    expect(plan.decryption.algorithm, 'cenc-ctr');
    expect(plan.decryption.location, 'server');
    expect(plan.expiresAt, startsWith('2099'));
  });

  test('Quality.pick defaults to the highest stream', () {
    final streams = [
      Stream.fromJson({'height': 480, 'quality': '480p'}),
      Stream.fromJson({'height': 1080, 'quality': '1080p'}),
      Stream.fromJson({'height': 720, 'quality': '720p'}),
    ];
    expect(Quality.pick(streams)!.height, 1080);
  });

  test('Quality.pick honors a max height preference', () {
    final streams = [
      Stream.fromJson({'height': 1080}),
      Stream.fromJson({'height': 720}),
    ];
    expect(Quality.pick(streams, maxHeight: 720)!.height, 720);
  });

  test('missing required fields fall back to zero values', () {
    final item = Item.fromJson({'title': 'only title'});
    expect(item.id, isEmpty);
    expect(item.badges, isEmpty);
    expect(item.extra, isEmpty);
  });

  test('source manifest carries endpoints, tabs, auth and decryptors', () {
    final manifest = SourceManifest.fromJson({
      'id': 'demo',
      'name': '示例源',
      'protocol': '1',
      'endpoints': {
        'ui': '/v1/xxx/ui_test.php',
        'feed': '/v1/xxx/feed.php',
      },
      'decryptors': [
        {'id': 'builtin:cenc-ctr', 'algorithms': ['cenc-ctr'], 'abi': 1},
        {
          'id': 'sample-cenc',
          'version': '1.0.0',
          'url': 'https://example.test/a.dll',
          'sha256': 'abc',
          'size': 12,
        },
      ],
      'auth': {
        'required': true,
        'methods': ['form'],
        'login': {
          'method': 'form',
          'fields': [
            {'key': 'username', 'label': '账号', 'required': true},
            {'key': 'password', 'label': '密码', 'type': 'password'},
          ],
        },
      },
    });
    expect(manifest.endpoints['ui'], '/v1/xxx/ui_test.php');
    expect(manifest.decryptors.length, 2);
    expect(manifest.decryptors[0].downloadable, isFalse);
    expect(manifest.decryptors[1].downloadable, isTrue);
    expect(manifest.auth?.login?.isCustom, isTrue);
    expect(manifest.auth?.login?.fields.first.key, 'username');
  });

  test('UI manifest carries home tabs and source labels', () {
    final ui = UIManifest.fromJson({
      'default_page': 'home.feed',
      'home_tabs': [
        {'key': 'home', 'title': '精选', 'channel': 'home'},
        {
          'key': 'mine',
          'title': '我的',
          'channel': 'following',
          'requires_auth': true,
          'category_tag': '示例分类',
        },
      ],
      'labels': {'detail.hot_label': '热度'},
    });
    expect(ui.homeTabs.length, 2);
    expect(ui.homeTabs[1].requiresAuth, isTrue);
    expect(ui.homeTabs[1].categoryTag, '示例分类');
    expect(ui.labels['detail.hot_label'], '热度');
  });
}
