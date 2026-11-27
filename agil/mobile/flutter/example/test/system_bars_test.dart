import 'package:agil_calls_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('uses readable edge-to-edge system bars in ${brightness.name}', (tester) async {
      final TestPlatformDispatcher dispatcher = tester.binding.platformDispatcher;
      dispatcher.platformBrightnessTestValue = brightness;
      addTearDown(dispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpWidget(const AgilCallsExampleApp());
      await tester.pumpAndSettle();

      final Iterable<AnnotatedRegion<SystemUiOverlayStyle>> styles = tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(find.byWidgetPredicate(
            (widget) => widget is AnnotatedRegion<SystemUiOverlayStyle>,
          ));
      final Brightness expectedIcons = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
      final Color? surface = tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor;
      expect(styles.any((region) =>
          region.value.systemNavigationBarColor == surface &&
          region.value.systemNavigationBarIconBrightness == expectedIcons &&
          region.value.systemNavigationBarContrastEnforced == false), isTrue);
      expect(find.byType(SafeArea), findsWidgets);
      final FilledButton join = tester.widget<FilledButton>(
        find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(join.style?.minimumSize?.resolve({})?.height, greaterThanOrEqualTo(48));
      expect(join.style?.textStyle?.resolve({})?.fontSize, 16);
    });
  }
}
