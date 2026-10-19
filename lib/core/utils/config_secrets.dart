import 'dart:convert';

const _proxyKeys = <String>{'proxy', 'proxy_url', 'proxyurl', 'proxy_password', 'proxy_pass', 'proxy_username', 'proxy_user'};

Object? stripProxyFields(Object? value) {
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final normalized = key.toLowerCase().replaceAll('-', '_');
      if (_proxyKeys.contains(normalized)) continue;
      out[key] = stripProxyFields(entry.value);
    }
    return out;
  }
  if (value is List) return value.map(stripProxyFields).toList();
  return value;
}

String? stripProxyFieldsFromJson(String? encoded) {
  if (encoded == null || encoded.isEmpty) return encoded;
  try {
    final value = jsonDecode(encoded);
    if (value is! Map) return null;
    return jsonEncode(stripProxyFields(value));
  } catch (_) {
    return null;
  }
}
