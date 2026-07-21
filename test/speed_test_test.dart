import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nova_client/src/features/speedtest/speed_test.dart';

void main() {
  test('download computes a positive Mbps from a payload', () async {
    // Mock client returns a fixed payload for __down and 200 for others.
    final SpeedTest st = SpeedTest(clientFactory: () => MockClient.streaming(
      (http.BaseRequest req, http.ByteStream body) async {
        if (req.url.toString().contains('__down')) {
          final data = List<int>.filled(2 * 1024 * 1024, 7); // 2MB
          return http.StreamedResponse(Stream.value(data), 200,
              contentLength: data.length);
        }
        await body.drain<void>();
        return http.StreamedResponse(Stream.value(utf8.encode('ok')), 200);
      },
    ));
    final SpeedResult r = await st.run(
      downTime: const Duration(milliseconds: 300),
      upTime: const Duration(milliseconds: 200),
    );
    expect(r.downMbps, greaterThan(0));
  });
}
