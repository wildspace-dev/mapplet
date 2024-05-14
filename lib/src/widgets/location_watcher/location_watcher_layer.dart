import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_compass/flutter_compass.dart";
import "package:flutter_map/flutter_map.dart";
import "package:geolocator/geolocator.dart";
import "package:latlong2/latlong.dart";
import "package:mapplet/src/widgets/location_watcher/direction_painter.dart";
import "package:mapplet/src/widgets/location_watcher/payloads.dart";
import "package:mapplet/src/widgets/location_watcher/tweens.dart";

/// Default marker for the [LocationWatcherLayer]
class DefaultLocationWatcherMarker extends StatelessWidget {
  const DefaultLocationWatcherMarker({
    super.key,
    this.color = Colors.red,
    this.child,
  });
  final Widget? child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: child,
        ),
      ),
    );
  }
}

class LocationWatcherLayerStyle {
  LocationWatcherLayerStyle({
    this.showAccuracyCircle = true,
    this.accuracyCircleColor,
    this.accuracyCircleBorderColor,
    this.showDirection = true,
    this.locationMarker = const DefaultLocationWatcherMarker(),
    this.directionColor = Colors.red,
    this.directionAnimDuration = const Duration(milliseconds: 250),
    this.positionAnimDuration = const Duration(milliseconds: 250),
    this.directionAnimCurve = Curves.easeInOutCubic,
    this.accuracyCircleBorderWidth = 2,
    this.positionAnimCurve = Curves.easeInOutCubic,
    this.directionRadius = 60,
    this.markerSize = const Size.square(22),
    this.directionAngle,
  });
  final Curve positionAnimCurve;
  final Duration positionAnimDuration;
  final Curve directionAnimCurve;
  final Duration directionAnimDuration;
  final bool showAccuracyCircle;
  final double accuracyCircleBorderWidth;
  final Color? accuracyCircleColor;
  final Color? accuracyCircleBorderColor;
  final bool showDirection;
  final Widget locationMarker;
  final Color directionColor;
  final double directionRadius;
  final Size markerSize;
  final double? directionAngle;
}

/// A layer that can be added to **flutter_map** layers displaying the current user location and direction on the map
class LocationWatcherLayer extends StatefulWidget {
  const LocationWatcherLayer({
    super.key,
    this.positionStream,
    this.directionStream,
    this.initialPos,
    this.style,
  });
  final PositionPayload? initialPos;

  /// The direction stream
  ///
  /// If not passed, the `FlutterCompass.events` is used
  final Stream<DirectionPayload>? directionStream;

  /// Style the layer
  final LocationWatcherLayerStyle? style;

  /// The position stream
  ///
  /// If not passed, the `Geolocator.getPositionStream()` with best accuracy is used
  final Stream<PositionPayload>? positionStream;

  @override
  State<LocationWatcherLayer> createState() => _LocationWatcherLayerState();
}

class _LocationWatcherLayerState extends State<LocationWatcherLayer> with TickerProviderStateMixin {
  StreamSubscription? _posSub;
  StreamSubscription? _directionSub;

  late PositionPayload? _currentPos = widget.initialPos;
  DirectionPayload? _currentDirection;

  LocationWatcherLayerStyle get style => widget.style ?? LocationWatcherLayerStyle();

  AnimationController? _directionAnimController;
  AnimationController? _positionAnimController;
  Stream<PositionPayload>? _stream;

  /// Animate movement of the marker on the map
  void _driveMoveAnimation(PositionPayload event) {
    _positionAnimController?.dispose();
    _positionAnimController = AnimationController(vsync: this, duration: style.positionAnimDuration);

    var tween = PositionPayloadTween(begin: _currentPos ?? event, end: event);
    final animation = CurvedAnimation(parent: _positionAnimController!, curve: style.positionAnimCurve);

    _positionAnimController!.addListener(() => setState(() => _currentPos = tween.evaluate(animation)));

    _positionAnimController!.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        _positionAnimController!.dispose();
        _positionAnimController = null;
      }
    });
    _positionAnimController!.forward();
  }

  /// Animate the direction of the marker on the map
  void _driveDirectionAnimation(DirectionPayload event) {
    _directionAnimController?.dispose();
    _directionAnimController = AnimationController(vsync: this, duration: style.directionAnimDuration);

    var tween = DirectionPayloadTween(begin: _currentDirection ?? event, end: event);
    final animation = CurvedAnimation(parent: _directionAnimController!, curve: style.directionAnimCurve);

    _directionAnimController!.addListener(() {
      setState(() => _currentDirection = tween.evaluate(animation));
    });

    _directionAnimController!.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        _directionAnimController!.dispose();
        _directionAnimController = null;
      }
    });
    _directionAnimController!.forward();
  }

  @override
  void initState() {
    _subscribeStreams();
    super.initState();
  }

  void _subscribeStreams() {
    if (widget.positionStream != null) {
      _stream = widget.positionStream;
    } else {
      _stream = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best))
          .map((event) => PositionPayload(position: LatLng(event.latitude, event.longitude), accuracy: event.accuracy));
    }
    _posSub = _stream!.listen(_driveMoveAnimation);

    if (widget.directionStream != null) {
      _directionSub = widget.directionStream!.listen(_driveDirectionAnimation);
    } else {
      var dirStream = FlutterCompass.events;
      if (dirStream != null) {
        _directionSub = FlutterCompass.events!.listen((event) {
          _driveDirectionAnimation(DirectionPayload(direction: event.heading ?? 0, accuracy: event.accuracy ?? 0));
        });
      }
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _directionSub?.cancel();
    _directionAnimController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraState = MapCamera.of(context);

    if (_currentPos == null) return const SizedBox.shrink();
    return Stack(
      children: [
        if (style.showAccuracyCircle)
          CircleLayer(
            circles: [
              CircleMarker(
                point: _currentPos!.position,
                radius: _currentPos!.accuracy,
                useRadiusInMeter: true,
                color: style.accuracyCircleColor ?? Colors.redAccent.withOpacity(0.2),
                borderColor: style.accuracyCircleBorderColor ?? Colors.red.withOpacity(0.3),
                borderStrokeWidth: style.accuracyCircleBorderWidth,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            if (_currentDirection != null && style.showDirection)
              Marker(
                point: _currentPos!.position,
                width: style.directionRadius * 2,
                height: style.directionRadius * 2,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: Size.fromRadius(style.directionRadius),
                    painter: DirectionPainter(
                      color: style.directionColor,
                      direction: _currentDirection!.direction,
                      sweepAngle: style.directionAngle ?? _currentDirection!.accuracy * 2,
                    ),
                  ),
                ),
              ),
            Marker(
              point: _currentPos!.position,
              width: style.markerSize.width,
              height: style.markerSize.height,
              child: Transform.rotate(
                angle: -cameraState.rotationRad,
                child: style.locationMarker,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
