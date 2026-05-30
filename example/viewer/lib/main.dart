import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'src/discovery_page.dart';

void main() {
  runApp(const NtrViewerApp());
}

class NtrViewerApp extends StatelessWidget {
  const NtrViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NTR Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: CupertinoColors.systemBlue,
        brightness: Brightness.dark,
      ),
      home: const DiscoveryPage(),
    );
  }
}
