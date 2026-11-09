import 'dart:html' as html;
import 'dart:ui_web' as ui;

import 'package:flutter/widgets.dart';

final Set<String> _registeredViews = <String>{};

Widget buildOsmEmbed(double latitude, double longitude) {
  final viewType = 'incident-osm-${latitude.toStringAsFixed(6)}-'
      '${longitude.toStringAsFixed(6)}';
  if (_registeredViews.add(viewType)) {
    const marginLat = 0.0035;
    const marginLon = 0.0045;
    final uri = Uri.https('www.openstreetmap.org', '/export/embed.html', {
      'bbox': '${longitude - marginLon},${latitude - marginLat},'
          '${longitude + marginLon},${latitude + marginLat}',
      'layer': 'mapnik',
      'marker': '$latitude,$longitude',
    });
    ui.platformViewRegistry.registerViewFactory(viewType, (int _) {
      return html.IFrameElement()
        ..src = uri.toString()
        ..title = '사고 GPS 위치 지도'
        ..setAttribute('loading', 'lazy')
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%';
    });
  }
  return SizedBox.expand(child: HtmlElementView(viewType: viewType));
}
