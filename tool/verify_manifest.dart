// Verifies a detached Ed25519 signature, such as update manifest signatures.
//
//   dart run tool/verify_manifest.dart <file> <file.sig> <public-key-file>
//
// The public key file contains the base64 key (the output of
// `dart run tool/update_keys.dart public`). Exit code 0 means the signature is
// valid for the exact bytes of <file>.

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'Usage: dart run tool/verify_manifest.dart <file> <file.sig> '
      '<public-key-file>',
    );
    exitCode = 2;
    return;
  }

  final file = File(args[0]);
  final signatureFile = File(args[1]);
  final keyFile = File(args[2]);
  for (final required in [file, signatureFile, keyFile]) {
    if (!required.existsSync()) {
      stderr.writeln('Not found: ${required.path}');
      exitCode = 2;
      return;
    }
  }

  final List<int> signatureBytes;
  final List<int> keyBytes;
  try {
    signatureBytes = base64Decode(signatureFile.readAsStringSync().trim());
    keyBytes = base64Decode(keyFile.readAsStringSync().trim());
  } on FormatException catch (error) {
    stderr.writeln('Not valid base64: ${error.message}');
    exitCode = 2;
    return;
  }
  if (signatureBytes.length != 64) {
    stderr.writeln('The signature is not a 64-byte Ed25519 signature.');
    exitCode = 2;
    return;
  }
  if (keyBytes.length != 32) {
    stderr.writeln('The public key is not a 32-byte Ed25519 key.');
    exitCode = 2;
    return;
  }

  final valid = await Ed25519().verify(
    file.readAsBytesSync(),
    signature: Signature(
      signatureBytes,
      publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
    ),
  );

  stdout.writeln(
    valid
        ? 'Signature OK for ${file.path} (${file.lengthSync()} bytes)'
        : 'Signature INVALID for ${file.path}',
  );
  exitCode = valid ? 0 : 1;
}
