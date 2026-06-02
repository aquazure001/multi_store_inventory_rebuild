import 'package:flutter_test/flutter_test.dart';
import 'package:multi_store_inventory_rebuild/main.dart';

void main() {
  testWidgets('Start page smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MultiStoreInventoryApp());

    expect(find.text('多店舗在庫管理システム'), findsOneWidget);
    expect(find.text('Ver. 2026.03.07'), findsOneWidget);
    expect(find.text('ログイン'), findsOneWidget);
  });
}