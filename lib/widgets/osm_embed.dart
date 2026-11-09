import 'package:flutter/widgets.dart';

import 'osm_embed_stub.dart'
    if (dart.library.html) 'osm_embed_web.dart' as platform;

Widget buildOsmEmbed(double latitude, double longitude) =>
    platform.buildOsmEmbed(latitude, longitude);
