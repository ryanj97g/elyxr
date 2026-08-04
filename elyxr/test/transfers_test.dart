import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:elyxr/api/lymnal_client.dart';
import 'package:elyxr/state/transfers.dart';

/// A fake lymnal for transfers: serves a known blob for download (honouring
/// Range) and accepts chunked uploads, tracking received bytes.
class FakeServer {
  final Uint8List blob;
  int uploadReceived = 0;
  bool committed = false;
  bool staged = true; // false once discarded
  int? initSizeRefusedOver; // if set, init refuses over this size

  FakeServer(this.blob);

  http.Client client() => MockClient((req) async {
        final path = req.url.path;
        if (path == '/v1/download') {
          final range = req.headers['Range'];
          if (range != null && range.startsWith('bytes=')) {
            final start = int.parse(range.substring(6).split('-').first);
            return http.Response.bytes(blob.sublist(start), 206, headers: {
              'content-range': 'bytes $start-${blob.length - 1}/${blob.length}',
            });
          }
          return http.Response.bytes(blob, 200);
        }
        if (path == '/v1/upload/init') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final size = (body['size_bytes'] as num).toInt();
          if (initSizeRefusedOver != null && size > initSizeRefusedOver!) {
            return http.Response(
              jsonEncode({
                'code': 'TROVE_FULL',
                'message': "This file won't fit. …",
                'request_id': 'r',
              }),
              507,
              headers: {'content-type': 'application/json'},
            );
          }
          return _json({
            'upload_id': 'up1',
            'chunk_bytes': 8,
            'received_bytes': 0,
            'target_exists': false,
            'expires_at': 0,
          });
        }
        if (path == '/v1/upload/up1' && req.method == 'PUT') {
          uploadReceived += req.bodyBytes.length;
          return _json({
            'received_bytes': uploadReceived,
            'complete': uploadReceived >= blob.length,
          });
        }
        if (path == '/v1/upload/up1/commit') {
          committed = true;
          return _json({
            'path': 'x',
            'size_bytes': blob.length,
            'replaced': false,
            'identical': false,
            'used_bytes': blob.length,
            'warnings': [],
          });
        }
        if (path == '/v1/upload/up1' && req.method == 'DELETE') {
          staged = false;
          return http.Response('', 204);
        }
        return http.Response('{"code":"NOT_FOUND","message":"x","request_id":"r"}', 404,
            headers: {'content-type': 'application/json'});
      });

  static http.Response _json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
}

LymnalClient clientFor(FakeServer s) =>
    LymnalClient(baseUrl: 'http://x:7749', token: 't', httpClient: s.client());

Future<void> pumpUntil(bool Function() done, {int ms = 2000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: ms));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('elyxr_xfer'));
  tearDown(() async => tmp.delete(recursive: true));

  test('download writes the file and finishes', () async {
    final blob = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    final server = FakeServer(blob);
    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final dest = '${tmp.path}/out.bin';
    final t = ctl.enqueueDownload(remotePath: 'photos/roll.cr3', localPath: dest, name: 'roll.cr3');
    await pumpUntil(() => t.state == TransferState.done);
    expect(t.state, TransferState.done);
    expect(await File(dest).readAsBytes(), blob);
  });

  test('download resumes from bytes already on disk, not from zero', () async {
    final blob = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    final server = FakeServer(blob);
    final dest = '${tmp.path}/out.bin';
    // Pre-place the first half as a .part, as an interrupted download would.
    await File('$dest.part').writeAsBytes(blob.sublist(0, 2500));

    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final t = ctl.enqueueDownload(remotePath: 'x', localPath: dest, name: 'out.bin');
    await pumpUntil(() => t.state == TransferState.done);
    expect(await File(dest).readAsBytes(), blob, reason: 'resumed to the same full file');
  });

  test('download that finds an existing file lands as name (1).ext', () async {
    final blob = Uint8List.fromList([1, 2, 3, 4]);
    final server = FakeServer(blob);
    final dest = '${tmp.path}/out.bin';
    await File(dest).writeAsBytes([9, 9]); // already there, untouched

    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final t = ctl.enqueueDownload(remotePath: 'x', localPath: dest, name: 'out.bin');
    await pumpUntil(() => t.state == TransferState.done);
    expect(await File(dest).readAsBytes(), [9, 9], reason: 'existing file untouched');
    expect(await File('${tmp.path}/out (1).bin').readAsBytes(), blob);
  });

  test('upload chunks then commits', () async {
    final blob = Uint8List.fromList(List.generate(20, (i) => i));
    final server = FakeServer(blob);
    final src = '${tmp.path}/in.bin';
    await File(src).writeAsBytes(blob);

    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final t = ctl.enqueueUpload(localPath: src, remotePath: 'photos/in.bin', name: 'in.bin');
    await pumpUntil(() => t.state == TransferState.done);
    expect(t.state, TransferState.done);
    expect(server.uploadReceived, blob.length);
    expect(server.committed, isTrue);
  });

  test('an over-limit upload fails at init with lymnal\'s wording, no retry', () async {
    final blob = Uint8List.fromList(List.generate(5000, (i) => i % 256));
    final server = FakeServer(blob)..initSizeRefusedOver = 1000;
    final src = '${tmp.path}/big.bin';
    await File(src).writeAsBytes(blob);

    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final t = ctl.enqueueUpload(localPath: src, remotePath: 'big.bin', name: 'big.bin');
    await pumpUntil(() => t.state == TransferState.failed);
    expect(t.state, TransferState.failed);
    expect(t.errorCode, 'TROVE_FULL');
    expect(t.errorMessage, contains("won't fit"));
    expect(server.committed, isFalse);
  });

  test('cancelling an upload tells lymnal to discard its staging file', () async {
    // A large blob so the upload is still mid-flight when we cancel.
    final blob = Uint8List.fromList(List.generate(80000, (i) => i % 256));
    final server = FakeServer(blob);
    final src = '${tmp.path}/in.bin';
    await File(src).writeAsBytes(blob);

    final ctl = TransferController(() => clientFor(server), File('${tmp.path}/q.json'));
    final t = ctl.enqueueUpload(localPath: src, remotePath: 'in.bin', name: 'in.bin');
    await pumpUntil(() => t.uploadId != null && t.doneBytes > 0);
    await ctl.cancel(t);
    await pumpUntil(() => server.staged == false);
    expect(server.staged, isFalse, reason: 'staging discarded on cancel');
  });

  test('the queue persists and reloads', () async {
    final store = File('${tmp.path}/q.json');
    final server = FakeServer(Uint8List(0));
    final ctl = TransferController(() => clientFor(server), store);
    ctl.enqueueDownload(remotePath: 'a', localPath: '${tmp.path}/z', name: 'z');
    await pumpUntil(() => store.existsSync());
    expect(store.existsSync(), isTrue);
    final reloaded = TransferController(() => clientFor(server), store);
    await reloaded.load();
    expect(reloaded.queue.isNotEmpty, isTrue);
  });
}
