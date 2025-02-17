// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'active_request_tracker.dart';
import 'base_client.dart';
import 'base_request.dart';
import 'client.dart';
import 'exception.dart';
import 'io_streamed_response.dart';
import 'request_controller.dart';

/// Create an [IOClient].
///
/// Used from conditional imports, matches the definition in `client_stub.dart`.
BaseClient createClient() {
  if (const bool.fromEnvironment('no_default_http_client')) {
    throw StateError('no_default_http_client was defined but runWithClient '
        'was not used to configure a Client implementation.');
  }
  return IOClient();
}

/// Exception thrown when the underlying [HttpClient] throws a
/// [SocketException].
///
/// Implements [SocketException] to avoid breaking existing users of
/// [IOClient] that may catch that exception.
class _ClientSocketException extends ClientException
    implements SocketException {
  final SocketException cause;
  _ClientSocketException(SocketException e, Uri uri)
      : cause = e,
        super(e.message, uri);

  @override
  InternetAddress? get address => cause.address;

  @override
  OSError? get osError => cause.osError;

  @override
  int? get port => cause.port;

  @override
  String toString() => 'ClientException with $cause, uri=$uri';
}

/// A `dart:io`-based HTTP [Client].
///
/// If there is a socket-level failure when communicating with the server
/// (for example, if the server could not be reached), [IOClient] will emit a
/// [ClientException] that also implements [SocketException]. This allows
/// callers to get more detailed exception information for socket-level
/// failures, if desired.
///
/// For example:
/// ```dart
/// final client = http.Client();
/// late String data;
/// try {
///   data = await client.read(Uri.https('example.com', ''));
/// } on SocketException catch (e) {
///   // Exception is transport-related, check `e.osError` for more details.
/// } on http.ClientException catch (e) {
///   // Exception is HTTP-related (e.g. the server returned a 404 status code).
///   // If the handler for `SocketException` were removed then all exceptions
///   // would be caught by this handler.
/// }
/// ```
class IOClient extends BaseClient {
  @override
  final bool supportsController = true;

  /// The underlying `dart:io` HTTP client.
  HttpClient? _inner;

  IOClient([HttpClient? inner]) : _inner = inner ?? HttpClient();

  /// Sends an HTTP request and asynchronously returns the response.
  @override
  Future<IOStreamedResponse> send(BaseRequest request) async {
    if (_inner == null) {
      throw ClientException(
          'HTTP request failed. Client is already closed.', request.url);
    }

    var stream = request.finalize();

    try {
      final tracker = request.controller?.track(request, isStreaming: true);

      // Open a connection to the server.
      // If the connection times out, this will simply throw a
      // CancelledException and we needn't do anything else as there's no
      // resulting HttpClientRequest to close.
      var ioRequest = (await maybeTrack(
        _inner!.openUrl(request.method, request.url),
        tracker: tracker,
        state: RequestLifecycleState.connecting,
      ))
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..contentLength = (request.contentLength ?? -1)
        ..persistentConnection = request.persistentConnection;

      // Pass-thru all request headers from the BaseRequest.
      request.headers.forEach((name, value) {
        ioRequest.headers.set(name, value);
      });

      // Pipe the byte stream of request body data into the HttpClientRequest.
      // This will send the request to the server and call .done() on the
      // HttpClientRequest when the stream is done. At which point, the future
      // will complete once the response is available.
      //
      // If the step or the request times out or is cancelled, this will abort
      // with the corresponding error.
      var response = await maybeTrack(
        stream.pipe(ioRequest),
        tracker: tracker,
        state: RequestLifecycleState.sending,
        onCancel: (error) => ioRequest.abort(error),
      ) as HttpClientResponse;

      // Read all the response headers into a map, comma-concatenating any
      // duplicate values for a single header name.
      var headers = <String, String>{};
      response.headers.forEach((key, values) {
        // TODO: Remove trimRight() when
        // https://github.com/dart-lang/sdk/issues/53005 is resolved and the
        // package:http SDK constraint requires that version or later.
        headers[key] = values.map((value) => value.trimRight()).join(',');
      });

      return IOStreamedResponse(
          response.handleError((Object error) {
            final httpException = error as HttpException;
            throw ClientException(httpException.message, httpException.uri);
          }, test: (error) => error is HttpException),
          response.statusCode,
          contentLength:
              response.contentLength == -1 ? null : response.contentLength,
          request: request,
          headers: headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
          inner: response);
    } on SocketException catch (error) {
      throw _ClientSocketException(error, request.url);
    } on HttpException catch (error) {
      throw ClientException(error.message, error.uri);
    }
  }

  /// Closes the client.
  ///
  /// Terminates all active connections. If a client remains unclosed, the Dart
  /// process may not terminate.
  @override
  void close({bool force = true}) {
    if (_inner != null) {
      _inner!.close(force: force);
      _inner = null;
    }
  }
}
