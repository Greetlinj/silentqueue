import 'package:flutter_test/flutter_test.dart';
import 'package:silent_queue/main.dart';

void main() {
  testWidgets('SilentQueue app starts', (WidgetTester tester) async {
    await tester.pumpWidget(const SilentQueueApp());

    expect(find.byType(SilentQueueApp), findsOneWidget);
  });
}