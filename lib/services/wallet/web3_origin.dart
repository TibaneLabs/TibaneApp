/// Returns the security origin for an HTTP(S) page without leaking its path,
/// query, or fragment into libwallet's per-site permission key.
String? web3SecurityOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.origin;
}
