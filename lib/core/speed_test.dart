import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'singbox_config.dart';

/// Throughput test THROUGH the tunnel: pulls/pushes a sized object from
/// Cloudflare's speed endpoint and computes Mbps. Routes via the local mixed
/// inbound (loopback) so it measures the ACTIVE outbound in BOTH proxy and TUN
/// modes — Dart's HttpClient otherwise ignores the system proxy and would test
/// the bare line. Neither Hiddify nor Happ surfaces a real Mbps test in-GUI;
/// they only show ping + live byte-counter arrows (both of which we already
/// have). The foreign `.com` host is NOT in the RU-direct list, so it exits
/// through the tunnel — exactly what we want to measure.
class SpeedTest {
  static const _downUrl = 'https://speed.cloudflare.com/__down?bytes=';
  static const _upUrl = 'https://speed.cloudflare.com/__up';

  HttpClient _client() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15)
      ..autoUncompress = false; // measure raw bytes, not decompressed
    final proxy = '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
    c.findProxy = (_) => 'PROXY $proxy';
    return c;
  }

  /// Download throughput in Mbps. Several parallel streams (a single TCP stream
  /// underreports on a long RTT to a foreign exit), measured over [window] AFTER
  /// [warmup] so TCP slow-start is excluded. Streams re-request so they never run
  /// dry mid-window. Mbps = bytes·8 / sec / 1e6 (decimal megabits, not /1024).
  Future<double> downloadMbps({
    int streams = 4,
    int bytesPerStream = 25 * 1024 * 1024,
    Duration warmup = const Duration(seconds: 2),
    Duration window = const Duration(seconds: 8),
  }) async {
    final client = _client();
    var bytes = 0;
    var counting = false, stop = false;
    Future<void> worker() async {
      while (!stop) {
        try {
          final req = await client.getUrl(Uri.parse('$_downUrl$bytesPerStream'));
          final resp = await req.close();
          await for (final chunk in resp) {
            if (stop) break;
            if (counting) bytes += chunk.length;
          }
        } catch (_) {
          if (stop) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }

    final workers = List.generate(streams, (_) => worker());
    await Future.delayed(warmup);
    counting = true;
    final sw = Stopwatch()..start();
    await Future.delayed(window);
    sw.stop();
    stop = true;
    client.close(force: true);
    await Future.wait(workers)
        .timeout(const Duration(seconds: 3), onTimeout: () => const []);
    final secs = sw.elapsedMicroseconds / 1e6;
    return secs > 0 ? (bytes * 8) / secs / 1e6 : 0;
  }

  /// Upload throughput in Mbps (approximate — counts bytes pushed to the wire;
  /// OS/proxy buffering makes the very first moments optimistic, which [warmup]
  /// absorbs). Same parallel-stream + timed-window method as download.
  Future<double> uploadMbps({
    int streams = 4,
    Duration warmup = const Duration(seconds: 2),
    Duration window = const Duration(seconds: 8),
  }) async {
    final client = _client();
    final chunk = Uint8List(64 * 1024); // 64 KB block, re-sent in a loop
    var bytes = 0;
    var counting = false, stop = false;
    Future<void> worker() async {
      while (!stop) {
        try {
          final req = await client.postUrl(Uri.parse(_upUrl));
          req.headers.contentType = ContentType.binary;
          req.headers.chunkedTransferEncoding = true;
          while (!stop) {
            req.add(chunk);
            if (counting) bytes += chunk.length;
            await req.flush(); // push toward the wire before counting the next
          }
          await req.close().timeout(const Duration(seconds: 2));
        } catch (_) {
          if (stop) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }

    final workers = List.generate(streams, (_) => worker());
    await Future.delayed(warmup);
    counting = true;
    final sw = Stopwatch()..start();
    await Future.delayed(window);
    sw.stop();
    stop = true;
    client.close(force: true);
    await Future.wait(workers)
        .timeout(const Duration(seconds: 3), onTimeout: () => const []);
    final secs = sw.elapsedMicroseconds / 1e6;
    return secs > 0 ? (bytes * 8) / secs / 1e6 : 0;
  }
}

/// Which leg of the test is running (drives the UI label/spinner).
enum SpeedPhase { idle, download, upload, done }

class SpeedTestState {
  const SpeedTestState({
    this.running = false,
    this.phase = SpeedPhase.idle,
    this.downMbps,
    this.upMbps,
    this.error,
  });

  final bool running;
  final SpeedPhase phase;
  final double? downMbps;
  final double? upMbps;
  final String? error; // non-null → couldn't run (e.g. not connected)

  SpeedTestState copyWith({
    bool? running,
    SpeedPhase? phase,
    double? downMbps,
    double? upMbps,
    String? error,
  }) =>
      SpeedTestState(
        running: running ?? this.running,
        phase: phase ?? this.phase,
        downMbps: downMbps ?? this.downMbps,
        upMbps: upMbps ?? this.upMbps,
        error: error,
      );
}

final speedTestProvider =
    NotifierProvider<SpeedTestController, SpeedTestState>(
        SpeedTestController.new);

class SpeedTestController extends Notifier<SpeedTestState> {
  @override
  SpeedTestState build() => const SpeedTestState();

  /// Run download then upload through the live tunnel. No-op if a run is in
  /// flight; sets [error] if the tunnel isn't up (nothing to measure).
  Future<void> run() async {
    if (state.running) return;
    if (!ref.read(coreControllerProvider).isOn) {
      state = const SpeedTestState(error: 'not-connected');
      return;
    }
    state = const SpeedTestState(running: true, phase: SpeedPhase.download);
    try {
      final st = SpeedTest();
      final down = await st.downloadMbps();
      state = state.copyWith(downMbps: down, phase: SpeedPhase.upload);
      final up = await st.uploadMbps();
      state = state.copyWith(upMbps: up, phase: SpeedPhase.done, running: false);
    } catch (e) {
      state = SpeedTestState(
          downMbps: state.downMbps, upMbps: state.upMbps, error: '$e');
    }
  }
}
