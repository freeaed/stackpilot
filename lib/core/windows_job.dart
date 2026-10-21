import 'dart:ffi';
import 'dart:io';

/// Windows job object that kills adopted services when StackPilot exits.
///
/// The singleton is never disposed. Windows closes the handle with the process
/// and terminates every process assigned to it, including on a crash.
class WindowsJob {
  WindowsJob._(this._handle, this._openProcess, this._assign, this._close);

  static final WindowsJob? instance = _create();

  static const _jobObjectExtendedLimitInformation = 9;
  static const _killOnJobClose = 0x2000;
  static const _processSetQuota = 0x0100;
  static const _processTerminate = 0x0001;
  static const _heapZeroMemory = 0x00000008;

  final int _handle;
  final int Function(int access, int inherit, int pid) _openProcess;
  final int Function(int job, int process) _assign;
  final int Function(int handle) _close;

  bool adopt(int pid) {
    final process = _openProcess(_processSetQuota | _processTerminate, 0, pid);
    if (process == 0) {
      return false;
    }
    try {
      return _assign(_handle, process) != 0;
    } finally {
      _close(process);
    }
  }

  static WindowsJob? _create() {
    if (!Platform.isWindows) {
      return null;
    }
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createJob = kernel32
          .lookupFunction<
            IntPtr Function(Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>)
          >('CreateJobObjectW');
      final setInformation = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, Int32, Pointer<Void>, Int32),
            int Function(int, int, Pointer<Void>, int)
          >('SetInformationJobObject');
      final assignProcess = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, IntPtr),
            int Function(int, int)
          >('AssignProcessToJobObject');
      final openProcess = kernel32
          .lookupFunction<
            IntPtr Function(Int32, Int32, Int32),
            int Function(int, int, int)
          >('OpenProcess');
      final closeHandle = kernel32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final getProcessHeap = kernel32
          .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
      final heapAlloc = kernel32
          .lookupFunction<
            Pointer<Void> Function(IntPtr, Int32, IntPtr),
            Pointer<Void> Function(int, int, int)
          >('HeapAlloc');
      final heapFree = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, Int32, Pointer<Void>),
            int Function(int, int, Pointer<Void>)
          >('HeapFree');

      final job = createJob(nullptr, nullptr);
      if (job == 0) {
        return null;
      }

      final heap = getProcessHeap();
      final size = sizeOf<_JobExtendedLimitInformation>();
      final memory = heapAlloc(heap, _heapZeroMemory, size);
      if (memory == nullptr) {
        closeHandle(job);
        return null;
      }

      try {
        memory
                .cast<_JobExtendedLimitInformation>()
                .ref
                .basicLimitInformation
                .limitFlags =
            _killOnJobClose;
        final ok = setInformation(
          job,
          _jobObjectExtendedLimitInformation,
          memory,
          size,
        );
        if (ok == 0) {
          closeHandle(job);
          return null;
        }
      } finally {
        heapFree(heap, 0, memory);
      }

      return WindowsJob._(job, openProcess, assignProcess, closeHandle);
    } on Object {
      return null;
    }
  }
}

final class _JobBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @IntPtr()
  external int minimumWorkingSetSize;

  @IntPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @IntPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _IoCounters extends Struct {
  @Uint64()
  external int readOperationCount;

  @Uint64()
  external int writeOperationCount;

  @Uint64()
  external int otherOperationCount;

  @Uint64()
  external int readTransferCount;

  @Uint64()
  external int writeTransferCount;

  @Uint64()
  external int otherTransferCount;
}

final class _JobExtendedLimitInformation extends Struct {
  external _JobBasicLimitInformation basicLimitInformation;
  external _IoCounters ioInfo;

  @IntPtr()
  external int processMemoryLimit;

  @IntPtr()
  external int jobMemoryLimit;

  @IntPtr()
  external int peakProcessMemoryUsed;

  @IntPtr()
  external int peakJobMemoryUsed;
}
