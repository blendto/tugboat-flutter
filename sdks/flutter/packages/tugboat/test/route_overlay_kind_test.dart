import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tugboat/tugboat.dart';

void main() {
  test('null route is unknown overlay with unnamed identity', () {
    expect(tugboatOverlayKindFor(null), TugboatOverlayKind.unknown);
    final identity = tugboatRouteIdentityFor(null);
    expect(identity.route, isNull);
    expect(identity.routeName, isNull);
    expect(identity.routeType, 'unknown');
    expect(identity.routeNamed, isFalse);
  });

  test('MaterialPageRoute is a named or unnamed page', () {
    final unnamed = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    expect(tugboatOverlayKindFor(unnamed), TugboatOverlayKind.page);
    expect(tugboatRouteIdentityFor(unnamed).routeNamed, isFalse);
    expect(
      tugboatRouteIdentityFor(unnamed).route,
      unnamed.runtimeType.toString(),
    );
    expect(
      tugboatRouteIdentityFor(unnamed).routeType,
      unnamed.runtimeType.toString(),
    );

    final named = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/home'),
      builder: (_) => const SizedBox(),
    );
    final identity = tugboatRouteIdentityFor(named);
    expect(tugboatOverlayKindFor(named), TugboatOverlayKind.page);
    expect(identity.route, '/home');
    expect(identity.routeName, '/home');
    expect(identity.routeNamed, isTrue);
  });

  test('empty RouteSettings.name is unnamed', () {
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: ''),
      builder: (_) => const SizedBox(),
    );
    final identity = tugboatRouteIdentityFor(route);
    expect(identity.routeNamed, isFalse);
    expect(identity.routeName, isNull);
    expect(identity.route, route.runtimeType.toString());
  });

  test('sheet, dialog, and other popup kinds are mechanical', () {
    expect(
      tugboatOverlayKindFor(_FakeModalBottomSheetRoute()),
      TugboatOverlayKind.sheet,
    );
    expect(
      tugboatOverlayKindFor(_CustomBottomSheetRoute()),
      TugboatOverlayKind.sheet,
    );
    expect(
      tugboatOverlayKindFor(_PaywallDialogRoute()),
      TugboatOverlayKind.dialog,
    );
    expect(tugboatOverlayKindFor(_PaywallRoute()), TugboatOverlayKind.popup);
    expect(
      tugboatOverlayKindFor(_UnknownModalRoute()),
      TugboatOverlayKind.unknown,
    );
  });
}

class _FakeModalBottomSheetRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'sheet';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}

class _CustomBottomSheetRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'sheet';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}

class _PaywallDialogRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'dialog';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}

class _PaywallRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'paywall';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}

class _UnknownModalRoute extends ModalRoute<void> {
  @override
  Color? get barrierColor => const Color(0x80000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'unknown';

  @override
  bool get maintainState => true;

  @override
  bool get opaque => false;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}
