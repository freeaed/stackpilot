// Generates the Ed25519 key used for update manifests and signs them.
//
//   dart run tool/update_keys.dart generate build/keys
//   dart run tool/update_keys.dart sign build/update-manifest.json \
//       build/keys/update-private.key
//
// Keep the private key out of the repository and out of the release artifact.
// Only the public key is compiled into the app with
// --dart-define=STACKPILOT_UPDATE_PUBLIC_KEY=<base64>.
//
// The signature covers the exact bytes of the manifest, so publish the same
// file you signed as manifest.json and the base64 output as manifest.json.sig.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage();
    return;
  }

  try {
    switch (args.first) {
      case 'generate':
        await _generate(args.skip(1).toList());
      case 'sign':
        await _sign(args.skip(1).toList());
      case 'public':
        await _public(args.skip(1).toList());
      default:
        stderr.writeln('Unknown command: ${args.first}');
        _usage();
        exitCode = 2;
    }
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exitCode = 2;
  } on FileSystemException catch (error) {
    stderr.writeln('${error.message}: ${error.path}');
    exitCode = 1;
  }
}

Future<void> _generate(List<String> args) async {
  final output = args.isEmpty ? p.join('build', 'keys') : args.first;
  final directory = Directory(output)..createSync(recursive: true);
  final privateFile = File(p.join(directory.path, 'update-private.key'));
  if (privateFile.existsSync()) {
    throw ArgumentError(
      '${privateFile.path} already exists; refusing to replace the signing key.',
    );
  }

  final random = Random.secure();
  final seed = List<int>.generate(32, (_) => random.nextInt(256));
  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();

  privateFile.writeAsStringSync('${base64Encode(seed)}\n');
  final publicFile = File(p.join(directory.path, 'update-public.key'));
  publicFile.writeAsStringSync('${base64Encode(publicKey.bytes)}\n');

  stdout.writeln('Private key: ${privateFile.path} (keep secret)');
  stdout.writeln('Public key:  ${publicFile.path}');
  stdout.writeln('');
  stdout.writeln('Compile the public key into release builds with:');
  stdout.writeln('  -UpdatePublicKey ${base64Encode(publicKey.bytes)}');
}

Future<void> _sign(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError('sign needs a manifest path.');
  }
  final manifest = File(args[0]);
  if (!manifest.existsSync()) {
    throw ArgumentError('Manifest not found: ${manifest.path}');
  }
  final privateKeyFile = File(
    args.length > 1 ? args[1] : p.join('build', 'keys', 'update-private.key'),
  );
  if (!privateKeyFile.existsSync()) {
    throw ArgumentError('Private key not found: ${privateKeyFile.path}');
  }
  final signatureFile = File(
    args.length > 2 ? args[2] : '${manifest.path}.sig',
  );

  final seed = base64Decode(privateKeyFile.readAsStringSync().trim());
  if (seed.length != 32) {
    throw ArgumentError(
      '${privateKeyFile.path} is not a 32-byte Ed25519 seed.',
    );
  }

  final algorithm = Ed25519();
  final keyPair = await algorithm.newKeyPairFromSeed(seed);
  final bytes = manifest.readAsBytesSync();
  final signature = await algorithm.sign(bytes, keyPair: keyPair);
  final publicKey = await keyPair.extractPublicKey();

  signatureFile.writeAsStringSync('${base64Encode(signature.bytes)}\n');
  stdout.writeln('Signed ${manifest.path} (${bytes.length} bytes)');
  stdout.writeln('Signature: ${signatureFile.path}');
  stdout.writeln('Public key: ${base64Encode(publicKey.bytes)}');
}

Future<void> _public(List<String> args) async {
  final privateKeyFile = File(
    args.isEmpty ? p.join('build', 'keys', 'update-private.key') : args.first,
  );
  if (!privateKeyFile.existsSync()) {
    throw ArgumentError('Private key not found: ${privateKeyFile.path}');
  }
  final seed = base64Decode(privateKeyFile.readAsStringSync().trim());
  if (seed.length != 32) {
    throw ArgumentError(
      '${privateKeyFile.path} is not a 32-byte Ed25519 seed.',
    );
  }
  final keyPair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  stdout.writeln(base64Encode(publicKey.bytes));
}

void _usage() {
  stdout.writeln('''
StackPilot update signing keys.

Usage:
  dart run tool/update_keys.dart generate [outputDir]
  dart run tool/update_keys.dart sign <manifest> [privateKey] [signatureFile]
  dart run tool/update_keys.dart public [privateKey]

Defaults:
  outputDir     build/keys
  privateKey    build/keys/update-private.key
  signatureFile <manifest>.sig

The signature is base64 Ed25519 over the exact manifest bytes.
''');
}
