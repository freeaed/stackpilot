import 'dart:io';

/// Returns whether [port] can be listened on locally.
///
/// Services bind the wildcard address on Windows, so trying the loopback
/// address is enough: the bind fails when another program already listens on
/// the port, whichever interface it chose.
typedef PortProbe = Future<bool> Function(int port);

Future<bool> isPortFree(int port) async {
  ServerSocket? socket;
  try {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    return true;
  } on SocketException {
    return false;
  } finally {
    try {
      await socket?.close();
    } on SocketException {
      // The socket is already gone; nothing left to release.
    }
  }
}
