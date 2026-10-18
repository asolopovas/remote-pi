import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/data/update/update_checker_impl.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends Fake implements HttpClient {
  final requested = <Uri>[];
  final request = _Request();
  bool closed = false;

  @override
  set connectionTimeout(Duration? timeout) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url);
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Request extends Fake implements HttpClientRequest {
  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _Response();
}

class _Response extends Fake implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.ok;

  @override
  Stream<T> transform<T>(StreamTransformer<List<int>, T> transformer) =>
      Stream<List<int>>.value(
        utf8.encode('{"version":"2.0.0","artifacts":[]}'),
      ).transform(transformer);
}

void main() {
  test(
    'default returns no release and never constructs a network client',
    () async {
      var clients = 0;
      final result = await HttpOverrides.runZoned(
        () => const UpdateCheckerImpl().fetchLatest(),
        createHttpClient: (_) {
          clients++;
          throw StateError('network must not be used');
        },
      );
      expect(result, isNull);
      expect(clients, 0);
    },
  );

  for (final url in [
    '',
    'http://updates.example.test/latest.json',
    '/latest.json',
    'https:///latest.json',
    'https://user:password@updates.example.test/latest.json',
    'https://updates.example.test/latest.json#fragment',
    'https://[invalid',
  ]) {
    test('rejects untrusted configuration without networking: $url', () async {
      var clients = 0;
      final result = await HttpOverrides.runZoned(
        () => UpdateCheckerImpl(manifestUrl: url).fetchLatest(),
        createHttpClient: (_) {
          clients++;
          throw StateError('network must not be used');
        },
      );
      expect(result, isNull);
      expect(clients, 0);
    });
  }

  test(
    'explicit HTTPS feed preserves the compatible parsing seam without sockets',
    () async {
      final client = _Client();
      const url = 'https://updates.example.test/latest.json';
      final result = await HttpOverrides.runZoned(
        () => const UpdateCheckerImpl(manifestUrl: url).fetchLatest(),
        createHttpClient: (_) => client,
      );
      expect(result?.version, '2.0.0');
      expect(result?.artifacts, isEmpty);
      expect(client.requested, [Uri.parse(url)]);
      expect(client.request.followRedirects, isFalse);
      expect(client.closed, isTrue);
    },
  );
}
