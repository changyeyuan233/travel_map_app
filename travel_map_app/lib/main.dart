import 'package:flutter/material.dart';

import 'widgets/map_screen.dart';

void main() {
  runApp(const TravelMapApp());
}

class TravelMapApp extends StatelessWidget {
  const TravelMapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Travel Map MVP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const MapScreen(),
    );
  }
}
