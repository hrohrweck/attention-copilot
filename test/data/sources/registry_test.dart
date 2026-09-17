import 'package:attention_copilot/data/sources/registry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  test('registers, looks up and preserves insertion order', () {
    final registry = CalendarSourceRegistry();
    final a = FakeCalendarSource(id: 'a');
    final b = FakeCalendarSource(id: 'b');
    registry.register(a);
    registry.register(b);

    expect(registry.lookup('a'), same(a));
    expect(registry.lookup('b'), same(b));
    expect(registry.lookup('ghost'), isNull);
    expect(registry.all.map((s) => s.id), ['a', 'b']);
  });

  test('rejects a duplicate registration', () {
    final registry = CalendarSourceRegistry();
    registry.register(FakeCalendarSource(id: 'a'));
    expect(
      () => registry.register(FakeCalendarSource(id: 'a')),
      throwsStateError,
    );
  });

  test('tracks the enabled set independently of registration', () {
    final registry = CalendarSourceRegistry();
    final a = FakeCalendarSource(id: 'a');
    final b = FakeCalendarSource(id: 'b');
    registry.register(a);
    registry.register(b, enabled: false);

    expect(registry.isEnabled('a'), isTrue);
    expect(registry.isEnabled('b'), isFalse);
    expect(registry.enabledIds, {'a'});
    expect(registry.enabledSources.map((s) => s.id), ['a']);

    registry.setEnabled('b', true);
    registry.setEnabled('a', false);
    expect(registry.isEnabled('a'), isFalse);
    expect(registry.isEnabled('b'), isTrue);
    expect(registry.enabledIds, {'b'});
    expect(registry.enabledSources.map((s) => s.id), ['b']);

    // Re-enabling is idempotent.
    registry.setEnabled('a', true);
    registry.setEnabled('a', true);
    expect(registry.enabledIds, {'b', 'a'});
  });

  test('setEnabled on an unknown id throws', () {
    final registry = CalendarSourceRegistry();
    expect(() => registry.setEnabled('ghost', true), throwsArgumentError);
    expect(() => registry.setEnabled('ghost', false), throwsArgumentError);
  });

  test('unregister removes the source and its enabled flag', () {
    final registry = CalendarSourceRegistry();
    final a = FakeCalendarSource(id: 'a');
    registry.register(a);
    registry.unregister('a');

    expect(registry.lookup('a'), isNull);
    expect(registry.isEnabled('a'), isFalse);
    expect(registry.all, isEmpty);
    expect(registry.enabledSources, isEmpty);
  });

  test('collections returned by the registry are unmodifiable', () {
    final registry = CalendarSourceRegistry()
      ..register(FakeCalendarSource(id: 'a'));
    expect(
      () => registry.all.add(FakeCalendarSource(id: 'x')),
      throwsUnsupportedError,
    );
    expect(
      () => registry.enabledSources.add(FakeCalendarSource(id: 'x')),
      throwsUnsupportedError,
    );
    expect(() => registry.enabledIds.add('x'), throwsUnsupportedError);
  });
}
