import 'package:flutter_test/flutter_test.dart';
import 'package:noven/main.dart';
import 'package:noven/ui/screens/home_screen.dart';

void main() {
  testWidgets('Noven app renders', (WidgetTester tester) async {
    await tester.pumpWidget(const NovenApp());
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
