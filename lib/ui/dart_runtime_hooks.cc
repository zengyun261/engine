// Copyright 2014 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/lib/ui/dart_runtime_hooks.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <iostream>
#include <sstream>

#include "flutter/common/settings.h"
#include "flutter/lib/ui/ui_dart_state.h"
#include "lib/fxl/build_config.h"
#include "lib/fxl/logging.h"
#include "lib/tonic/converter/dart_converter.h"
#include "lib/tonic/dart_library_natives.h"
#include "lib/tonic/dart_microtask_queue.h"
#include "lib/tonic/dart_state.h"
#include "lib/tonic/logging/dart_error.h"
#include "lib/tonic/logging/dart_invoke.h"
#include "lib/tonic/scopes/dart_api_scope.h"
#include "lib/tonic/scopes/dart_isolate_scope.h"
#include "third_party/dart/runtime/bin/embedded_dart_io.h"
#include "third_party/dart/runtime/include/dart_api.h"
#include "third_party/dart/runtime/include/dart_tools_api.h"

#if defined(OS_ANDROID)
#include <android/log.h>
#elif defined(OS_IOS)
extern "C" {
// Cannot import the syslog.h header directly because of macro collision.
extern void syslog(int, const char*, ...);
}
#endif

using tonic::LogIfError;
using tonic::ToDart;

namespace blink {

#define REGISTER_FUNCTION(name, count) {"" #name, name, count, true},
#define DECLARE_FUNCTION(name, count) \
  extern void name(Dart_NativeArguments args);

#define BUILTIN_NATIVE_LIST(V) \
  V(Logger_PrintString, 1)     \
  V(SaveCompilationTrace, 0)   \
  V(ScheduleMicrotask, 1)

BUILTIN_NATIVE_LIST(DECLARE_FUNCTION);

void DartRuntimeHooks::RegisterNatives(tonic::DartLibraryNatives* natives) {
  natives->Register({BUILTIN_NATIVE_LIST(REGISTER_FUNCTION)});
}

static Dart_Handle GetClosure(Dart_Handle builtin_library, const char* name) {
  Dart_Handle getter_name = ToDart(name);
  Dart_Handle closure = Dart_Invoke(builtin_library, getter_name, 0, nullptr);
  DART_CHECK_VALID(closure);
  return closure;
}

static void InitDartInternal(Dart_Handle builtin_library, bool is_ui_isolate) {
  Dart_Handle print = GetClosure(builtin_library, "_getPrintClosure");

  Dart_Handle internal_library = Dart_LookupLibrary(ToDart("dart:_internal"));

  DART_CHECK_VALID(
      Dart_SetField(internal_library, ToDart("_printClosure"), print));

  if (is_ui_isolate) {
    // Call |_setupHooks| to configure |VMLibraryHooks|.
    Dart_Handle method_name = Dart_NewStringFromCString("_setupHooks");
    DART_CHECK_VALID(Dart_Invoke(builtin_library, method_name, 0, NULL))
  }

  Dart_Handle setup_hooks = Dart_NewStringFromCString("_setupHooks");

  Dart_Handle io_lib = Dart_LookupLibrary(ToDart("dart:io"));
  DART_CHECK_VALID(io_lib);
  DART_CHECK_VALID(Dart_Invoke(io_lib, setup_hooks, 0, NULL));

  Dart_Handle isolate_lib = Dart_LookupLibrary(ToDart("dart:isolate"));
  DART_CHECK_VALID(isolate_lib);
  DART_CHECK_VALID(Dart_Invoke(isolate_lib, setup_hooks, 0, NULL));
}

static void InitDartCore(Dart_Handle builtin, const std::string& script_uri) {
  Dart_Handle io_lib = Dart_LookupLibrary(ToDart("dart:io"));
  Dart_Handle get_base_url =
      Dart_Invoke(io_lib, ToDart("_getUriBaseClosure"), 0, NULL);
  Dart_Handle core_library = Dart_LookupLibrary(ToDart("dart:core"));
  DART_CHECK_VALID(
      Dart_SetField(core_library, ToDart("_uriBaseClosure"), get_base_url));
}

static void InitDartAsync(Dart_Handle builtin_library, bool is_ui_isolate) {
  Dart_Handle schedule_microtask;
  if (is_ui_isolate) {
    schedule_microtask =
        GetClosure(builtin_library, "_getScheduleMicrotaskClosure");
  } else {
    Dart_Handle isolate_lib = Dart_LookupLibrary(ToDart("dart:isolate"));
    Dart_Handle method_name =
        Dart_NewStringFromCString("_getIsolateScheduleImmediateClosure");
    schedule_microtask = Dart_Invoke(isolate_lib, method_name, 0, NULL);
  }
  Dart_Handle async_library = Dart_LookupLibrary(ToDart("dart:async"));
  Dart_Handle set_schedule_microtask = ToDart("_setScheduleImmediateClosure");
  DART_CHECK_VALID(Dart_Invoke(async_library, set_schedule_microtask, 1,
                               &schedule_microtask));
}

static void InitDartIO(Dart_Handle builtin_library,
                       const std::string& script_uri) {
  Dart_Handle io_lib = Dart_LookupLibrary(ToDart("dart:io"));
  DART_CHECK_VALID(io_lib);
  Dart_Handle platform_type =
      Dart_GetType(io_lib, ToDart("_Platform"), 0, nullptr);
  DART_CHECK_VALID(platform_type);
  if (!script_uri.empty()) {
    DART_CHECK_VALID(Dart_SetField(platform_type, ToDart("_nativeScript"),
                                   ToDart(script_uri)));
  }
  Dart_Handle locale_closure = GetClosure(builtin_library, "_getLocaleClosure");
  DART_CHECK_VALID(
      Dart_SetField(platform_type, ToDart("_localeClosure"), locale_closure));
}

void DartRuntimeHooks::Install(bool is_ui_isolate,
                               const std::string& script_uri) {
  Dart_Handle builtin = Dart_LookupLibrary(ToDart("dart:ui"));
  DART_CHECK_VALID(builtin);
  InitDartInternal(builtin, is_ui_isolate);
  InitDartCore(builtin, script_uri);
  InitDartAsync(builtin, is_ui_isolate);
  InitDartIO(builtin, script_uri);
}

// Implementation of native functions which are used for some
// test/debug functionality in standalone dart mode.
void Logger_PrintString(Dart_NativeArguments args) {
  std::stringstream stream;
  const auto& logger_prefix = UIDartState::Current()->logger_prefix();

#if !OS_ANDROID
  // Prepend all logs with the isolate debug name except on Android where that
  // prefix is specified in the log tag.
  if (logger_prefix.size() > 0) {
    stream << logger_prefix << ": ";
  }
#endif  // !OS_ANDROID

  // Append the log buffer obtained from Dart code.
  {
    Dart_Handle str = Dart_GetNativeArgument(args, 0);
    uint8_t* chars = nullptr;
    intptr_t length = 0;
    Dart_Handle result = Dart_StringToUTF8(str, &chars, &length);
    if (Dart_IsError(result)) {
      Dart_PropagateError(result);
      return;
    }
    if (length > 0) {
      stream << std::string{reinterpret_cast<const char*>(chars),
                            static_cast<size_t>(length)};
    }
  }

  const auto log_string = stream.str();
  const char* chars = log_string.c_str();
  const size_t length = log_string.size();

  // Log using platform specific mechanisms
  {
#if defined(OS_ANDROID)
    // Write to the logcat on Android.
    __android_log_print(ANDROID_LOG_INFO, logger_prefix.c_str(), "%.*s",
                        (int)length, chars);
#elif defined(OS_IOS)
    // Write to syslog on iOS.
    //
    // TODO(cbracken): replace with dedicated communication channel and bypass
    // iOS logging APIs altogether.
    syslog(1 /* LOG_ALERT */, "%.*s", (int)length, chars);
#else
    std::cout << log_string << std::endl;
#endif
  }

  if (dart::bin::ShouldCaptureStdout()) {
    // For now we report print output on the Stdout stream.
    uint8_t newline[] = {'\n'};
    Dart_ServiceSendDataEvent("Stdout", "WriteEvent",
                              reinterpret_cast<const uint8_t*>(chars), length);
    Dart_ServiceSendDataEvent("Stdout", "WriteEvent", newline, sizeof(newline));
  }
}

void SaveCompilationTrace(Dart_NativeArguments args) {
  uint8_t* buffer = nullptr;
  intptr_t length = 0;
  Dart_Handle result = Dart_SaveCompilationTrace(&buffer, &length);
  if (Dart_IsError(result)) {
    Dart_SetReturnValue(args, result);
    return;
  }

  result = Dart_NewExternalTypedData(Dart_TypedData_kUint8, buffer, length);
  if (Dart_IsError(result)) {
    Dart_SetReturnValue(args, result);
    return;
  }

  Dart_SetReturnValue(args, result);
}

void ScheduleMicrotask(Dart_NativeArguments args) {
  Dart_Handle closure = Dart_GetNativeArgument(args, 0);
  UIDartState::Current()->ScheduleMicrotask(closure);
}

}  // namespace blink
