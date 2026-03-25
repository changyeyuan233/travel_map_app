class MapTiles {
  /// AMap (高德) tile URL template.
  ///
  /// Notes:
  /// - Some deployments require an API key; you can provide one via `AMAP_API_KEY`.
  /// - If your tiles cannot load, tell me your AMap tile domain/params and I’ll adjust.
  static String amapTileUrlTemplate({required String apiKey}) {
    final keyPart = apiKey.isEmpty ? '' : '&key=$apiKey';
    // Public-ish style template; adjust `style` to match your AMap settings.
    // Use fixed subdomain to keep template compatible with most FlutterMap versions.
    return 'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&z={z}&x={x}&y={y}$keyPart';
  }
}

