import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/poi.dart';
import '../services/poi_service.dart';
import '../services/route_planner_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  final _poiService = PoiService();
  final _routePlanner = RoutePlannerService();

  LatLng? _currentLocation;
  List<Poi> _pois = const [];
  final Set<String> _selectedPoiIds = {};

  RoutePlanResult? _routeResult;
  bool _isSelecting = false;
  bool _isLoadingLocation = true;

  @override
  void initState() {
    super.initState();
    unawaited(_initLocationAndPois());
  }

  Future<void> _initLocationAndPois() async {
    setState(() => _isLoadingLocation = true);
    final position = await _determinePosition();
    if (!mounted) return;

    final current = LatLng(position.latitude, position.longitude);
    setState(() {
      _currentLocation = current;
      _pois = _poiService.getNearbyRecommendations(current);
      _isLoadingLocation = false;
    });
  }

  Future<Position> _determinePosition() async {
    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return Future.error('Location services are disabled.');
      }
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return Future.error('Location permissions are denied.');
    }

    return Geolocator.getCurrentPosition();
  }

  void _centerOnUser() {
    final current = _currentLocation;
    if (current == null) return;
    _mapController.move(current, 15);
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelecting = !_isSelecting;
      if (!_isSelecting) {
        _selectedPoiIds.clear();
      }
    });
  }

  void _onTapPoi(Poi poi) {
    if (_isSelecting) {
      setState(() {
        if (_selectedPoiIds.contains(poi.id)) {
          _selectedPoiIds.remove(poi.id);
        } else {
          _selectedPoiIds.add(poi.id);
        }
      });
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(poi.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Rating: ${poi.rating.toStringAsFixed(1)} / 5.0'),
              const SizedBox(height: 4),
              Text('Type: ${poi.category.name}'),
              const SizedBox(height: 8),
              Text(poi.description),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showRouteConstraintsAndPlan() async {
    if (_selectedPoiIds.isEmpty || _currentLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one POI first.')),
      );
      return;
    }

    var timeLimit = 180.0;
    var pref = TravelPreference.food;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Route Constraints', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('Time Limit: ${timeLimit.toInt()} min'),
                Slider(
                  min: 30,
                  max: 480,
                  divisions: 15,
                  value: timeLimit,
                  onChanged: (v) => setSheetState(() => timeLimit = v),
                ),
                const SizedBox(height: 8),
                DropdownButton<TravelPreference>(
                  value: pref,
                  isExpanded: true,
                  items: TravelPreference.values
                      .map(
                        (e) => DropdownMenuItem(
                          value: e,
                          child: Text('Preference: ${e.name}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setSheetState(() => pref = v);
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Generate'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed != true) return;

    final selected = _pois.where((p) => _selectedPoiIds.contains(p.id)).toList();
    final result = _routePlanner.plan(
      start: _currentLocation!,
      selectedPois: selected,
      timeLimitMinutes: timeLimit.toInt(),
      preference: pref,
    );

    setState(() {
      _routeResult = result;
      _isSelecting = false;
      _selectedPoiIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentLocation;
    if (_isLoadingLocation) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (current == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unable to get location.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _initLocationAndPois,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: current,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.travel_map_app',
              ),
              MarkerLayer(markers: _buildPoiMarkers()),
              MarkerLayer(
                markers: [
                  Marker(
                    point: current,
                    width: 40,
                    height: 40,
                    child: const Icon(Icons.my_location, color: Colors.blue, size: 30),
                  ),
                ],
              ),
              if ((_routeResult?.polyline.length ?? 0) > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routeResult!.polyline,
                      strokeWidth: 4,
                      color: Colors.deepOrange,
                    ),
                  ],
                ),
            ],
          ),
          Positioned(
            top: 48,
            left: 12,
            right: 12,
            child: _TopInfoBar(
              isSelecting: _isSelecting,
              routeMinutes: _routeResult?.estimatedMinutes,
              routeStops: _routeResult?.orderedPois.length,
            ),
          ),
          Positioned(
            right: 16,
            bottom: 160,
            child: FloatingActionButton.small(
              heroTag: 'center_btn',
              onPressed: _centerOnUser,
              child: const Icon(Icons.gps_fixed),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton.extended(
              heroTag: 'select_btn',
              onPressed: _toggleSelectionMode,
              icon: Icon(_isSelecting ? Icons.close : Icons.checklist),
              label: Text(_isSelecting ? 'Cancel Select' : 'Select POIs'),
            ),
          ),
          if (_isSelecting)
            Positioned(
              right: 16,
              bottom: 24,
              child: FloatingActionButton.extended(
                heroTag: 'plan_btn',
                onPressed: _showRouteConstraintsAndPlan,
                icon: const Icon(Icons.route),
                label: Text('Plan (${_selectedPoiIds.length})'),
              ),
            ),
        ],
      ),
    );
  }

  List<Marker> _buildPoiMarkers() {
    return _pois.map((poi) {
      final isSelected = _selectedPoiIds.contains(poi.id);
      return Marker(
        point: poi.location,
        width: 92,
        height: 58,
        child: GestureDetector(
          onTap: () => _onTapPoi(poi),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? Colors.deepOrange : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.black12),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  poi.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isSelected ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  '★ ${poi.rating.toStringAsFixed(1)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isSelected ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }
}

class _TopInfoBar extends StatelessWidget {
  const _TopInfoBar({
    required this.isSelecting,
    required this.routeMinutes,
    required this.routeStops,
  });

  final bool isSelecting;
  final int? routeMinutes;
  final int? routeStops;

  @override
  Widget build(BuildContext context) {
    final text = isSelecting
        ? 'Selection mode: tap POIs to add/remove'
        : routeMinutes != null && routeStops != null
            ? 'Route ready: $routeStops stops, about $routeMinutes min'
            : 'Nearby POIs recommended by location';

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black87.withOpacity(0.75),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
