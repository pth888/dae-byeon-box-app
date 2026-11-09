import 'package:flutter/material.dart';

Widget buildOsmEmbed(double latitude, double longitude) => ColoredBox(
      color: const Color(0xFF202124),
      child: Center(
        child: Text(
          '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
