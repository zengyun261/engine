// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/android/platform_view_android.h"

#include <memory>
#include <utility>

#include "flutter/shell/common/io_manager.h"
#include "flutter/shell/platform/android/android_external_texture_gl.h"
#include "flutter/shell/platform/android/android_surface_gl.h"
#include "flutter/shell/platform/android/platform_message_response_android.h"
#include "flutter/shell/platform/android/platform_view_android_jni.h"
#include "flutter/shell/platform/android/vsync_waiter_android.h"
#include "lib/fxl/synchronization/waitable_event.h"

namespace shell {

PlatformViewAndroid::PlatformViewAndroid(
    PlatformView::Delegate& delegate,
    blink::TaskRunners task_runners,
    fml::jni::JavaObjectWeakGlobalRef java_object,
    bool use_software_rendering)
    : PlatformView(delegate, std::move(task_runners)),
      java_object_(java_object),
      android_surface_(AndroidSurface::Create(use_software_rendering)) {
  FXL_CHECK(android_surface_)
      << "Could not create an OpenGL, Vulkan or Software surface to setup "
         "rendering.";
}

PlatformViewAndroid::~PlatformViewAndroid() = default;

void PlatformViewAndroid::NotifyCreated(
    fxl::RefPtr<AndroidNativeWindow> native_window) {
  InstallFirstFrameCallback();
  android_surface_->SetNativeWindow(native_window);
  PlatformView::NotifyCreated();
}

void PlatformViewAndroid::NotifyDestroyed() {
  PlatformView::NotifyDestroyed();
  android_surface_->TeardownOnScreenContext();
}

void PlatformViewAndroid::NotifyChanged(const SkISize& size) {
  fxl::AutoResetWaitableEvent latch;
  fml::TaskRunner::RunNowOrPostTask(
      task_runners_.GetGPUTaskRunner(),  //
      [&latch, surface = android_surface_.get(), size]() {
        surface->OnScreenSurfaceResize(size);
        latch.Signal();
      });
  latch.Wait();
}

void PlatformViewAndroid::DispatchPlatformMessage(JNIEnv* env,
                                                  std::string name,
                                                  jobject java_message_data,
                                                  jint java_message_position,
                                                  jint response_id) {
  uint8_t* message_data =
      static_cast<uint8_t*>(env->GetDirectBufferAddress(java_message_data));
  std::vector<uint8_t> message =
      std::vector<uint8_t>(message_data, message_data + java_message_position);

  fxl::RefPtr<blink::PlatformMessageResponse> response;
  if (response_id) {
    response = fxl::MakeRefCounted<PlatformMessageResponseAndroid>(
        response_id, java_object_, task_runners_.GetPlatformTaskRunner());
  }

  PlatformView::DispatchPlatformMessage(
      fxl::MakeRefCounted<blink::PlatformMessage>(
          std::move(name), std::move(message), std::move(response)));
}

void PlatformViewAndroid::DispatchEmptyPlatformMessage(JNIEnv* env,
                                                       std::string name,
                                                       jint response_id) {
  fxl::RefPtr<blink::PlatformMessageResponse> response;
  if (response_id) {
    response = fxl::MakeRefCounted<PlatformMessageResponseAndroid>(
        response_id, java_object_, task_runners_.GetPlatformTaskRunner());
  }

  PlatformView::DispatchPlatformMessage(
      fxl::MakeRefCounted<blink::PlatformMessage>(std::move(name),
                                                  std::move(response)));
}

void PlatformViewAndroid::InvokePlatformMessageResponseCallback(
    JNIEnv* env,
    jint response_id,
    jobject java_response_data,
    jint java_response_position) {
  if (!response_id)
    return;
  auto it = pending_responses_.find(response_id);
  if (it == pending_responses_.end())
    return;
  uint8_t* response_data =
      static_cast<uint8_t*>(env->GetDirectBufferAddress(java_response_data));
  std::vector<uint8_t> response = std::vector<uint8_t>(
      response_data, response_data + java_response_position);
  auto message_response = std::move(it->second);
  pending_responses_.erase(it);
  message_response->Complete(
      std::make_unique<fml::DataMapping>(std::move(response)));
}

void PlatformViewAndroid::InvokePlatformMessageEmptyResponseCallback(
    JNIEnv* env,
    jint response_id) {
  if (!response_id)
    return;
  auto it = pending_responses_.find(response_id);
  if (it == pending_responses_.end())
    return;
  auto message_response = std::move(it->second);
  pending_responses_.erase(it);
  message_response->CompleteEmpty();
}

// |shell::PlatformView|
void PlatformViewAndroid::HandlePlatformMessage(
    fxl::RefPtr<blink::PlatformMessage> message) {
  JNIEnv* env = fml::jni::AttachCurrentThread();
  fml::jni::ScopedJavaLocalRef<jobject> view = java_object_.get(env);
  if (view.is_null())
    return;

  int response_id = 0;
  if (auto response = message->response()) {
    response_id = next_response_id_++;
    pending_responses_[response_id] = response;
  }
  auto java_channel = fml::jni::StringToJavaString(env, message->channel());
  if (message->hasData()) {
    fml::jni::ScopedJavaLocalRef<jbyteArray> message_array(
        env, env->NewByteArray(message->data().size()));
    env->SetByteArrayRegion(
        message_array.obj(), 0, message->data().size(),
        reinterpret_cast<const jbyte*>(message->data().data()));
    message = nullptr;

    // This call can re-enter in InvokePlatformMessageXxxResponseCallback.
    FlutterViewHandlePlatformMessage(env, view.obj(), java_channel.obj(),
                                     message_array.obj(), response_id);
  } else {
    message = nullptr;

    // This call can re-enter in InvokePlatformMessageXxxResponseCallback.
    FlutterViewHandlePlatformMessage(env, view.obj(), java_channel.obj(),
                                     nullptr, response_id);
  }
}

void PlatformViewAndroid::DispatchSemanticsAction(JNIEnv* env,
                                                  jint id,
                                                  jint action,
                                                  jobject args,
                                                  jint args_position) {
  if (env->IsSameObject(args, NULL)) {
    std::vector<uint8_t> args_vector;
    PlatformView::DispatchSemanticsAction(
        id, static_cast<blink::SemanticsAction>(action), args_vector);
    return;
  }

  uint8_t* args_data = static_cast<uint8_t*>(env->GetDirectBufferAddress(args));
  std::vector<uint8_t> args_vector =
      std::vector<uint8_t>(args_data, args_data + args_position);

  PlatformView::DispatchSemanticsAction(
      id, static_cast<blink::SemanticsAction>(action), std::move(args_vector));
}

// |shell::PlatformView|
void PlatformViewAndroid::UpdateSemantics(blink::SemanticsNodeUpdates update) {
  constexpr size_t kBytesPerNode = 35 * sizeof(int32_t);
  constexpr size_t kBytesPerChild = sizeof(int32_t);

  JNIEnv* env = fml::jni::AttachCurrentThread();
  {
    fml::jni::ScopedJavaLocalRef<jobject> view = java_object_.get(env);
    if (view.is_null())
      return;

    size_t num_bytes = 0;
    for (const auto& value : update) {
      num_bytes += kBytesPerNode;
      num_bytes +=
          value.second.childrenInTraversalOrder.size() * kBytesPerChild;
      num_bytes += value.second.childrenInHitTestOrder.size() * kBytesPerChild;
    }

    std::vector<uint8_t> buffer(num_bytes);
    int32_t* buffer_int32 = reinterpret_cast<int32_t*>(&buffer[0]);
    float* buffer_float32 = reinterpret_cast<float*>(&buffer[0]);

    std::vector<std::string> strings;
    size_t position = 0;
    for (const auto& value : update) {
      // If you edit this code, make sure you update kBytesPerNode
      // and/or kBytesPerChild above to match the number of values you are
      // sending.
      const blink::SemanticsNode& node = value.second;
      buffer_int32[position++] = node.id;
      buffer_int32[position++] = node.flags;
      buffer_int32[position++] = node.actions;
      buffer_int32[position++] = node.textSelectionBase;
      buffer_int32[position++] = node.textSelectionExtent;
      buffer_float32[position++] = (float)node.scrollPosition;
      buffer_float32[position++] = (float)node.scrollExtentMax;
      buffer_float32[position++] = (float)node.scrollExtentMin;
      if (node.label.empty()) {
        buffer_int32[position++] = -1;
      } else {
        buffer_int32[position++] = strings.size();
        strings.push_back(node.label);
      }
      if (node.value.empty()) {
        buffer_int32[position++] = -1;
      } else {
        buffer_int32[position++] = strings.size();
        strings.push_back(node.value);
      }
      if (node.increasedValue.empty()) {
        buffer_int32[position++] = -1;
      } else {
        buffer_int32[position++] = strings.size();
        strings.push_back(node.increasedValue);
      }
      if (node.decreasedValue.empty()) {
        buffer_int32[position++] = -1;
      } else {
        buffer_int32[position++] = strings.size();
        strings.push_back(node.decreasedValue);
      }
      if (node.hint.empty()) {
        buffer_int32[position++] = -1;
      } else {
        buffer_int32[position++] = strings.size();
        strings.push_back(node.hint);
      }
      buffer_int32[position++] = node.textDirection;
      buffer_float32[position++] = node.rect.left();
      buffer_float32[position++] = node.rect.top();
      buffer_float32[position++] = node.rect.right();
      buffer_float32[position++] = node.rect.bottom();
      node.transform.asColMajorf(&buffer_float32[position]);
      position += 16;

      buffer_int32[position++] = node.childrenInTraversalOrder.size();
      for (int32_t child : node.childrenInTraversalOrder)
        buffer_int32[position++] = child;

      for (int32_t child : node.childrenInHitTestOrder)
        buffer_int32[position++] = child;
    }

    fml::jni::ScopedJavaLocalRef<jobject> direct_buffer(
        env, env->NewDirectByteBuffer(buffer.data(), buffer.size()));

    FlutterViewUpdateSemantics(
        env, view.obj(), direct_buffer.obj(),
        fml::jni::VectorToStringArray(env, strings).obj());
  }
}

void PlatformViewAndroid::RegisterExternalTexture(
    int64_t texture_id,
    const fml::jni::JavaObjectWeakGlobalRef& surface_texture) {
  RegisterTexture(
      std::make_shared<AndroidExternalTextureGL>(texture_id, surface_texture));
}

// |shell::PlatformView|
std::unique_ptr<VsyncWaiter> PlatformViewAndroid::CreateVSyncWaiter() {
  return std::make_unique<VsyncWaiterAndroid>(task_runners_);
}

// |shell::PlatformView|
std::unique_ptr<Surface> PlatformViewAndroid::CreateRenderingSurface() {
  return android_surface_->CreateGPUSurface();
}

// |shell::PlatformView|
sk_sp<GrContext> PlatformViewAndroid::CreateResourceContext() const {
  sk_sp<GrContext> resource_context;
  if (android_surface_->ResourceContextMakeCurrent()) {
    // TODO(chinmaygarde): Currently, this code depends on the fact that only
    // the OpenGL surface will be able to make a resource context current. If
    // this changes, this assumption breaks. Handle the same.
    resource_context = IOManager::CreateCompatibleResourceLoadingContext(
        GrBackend::kOpenGL_GrBackend);
  } else {
    FXL_DLOG(ERROR) << "Could not make the resource context current.";
  }

  return resource_context;
}

void PlatformViewAndroid::InstallFirstFrameCallback() {
  // On Platform Task Runner.
  SetNextFrameCallback(
      [platform_view = GetWeakPtr(),
       platform_task_runner = task_runners_.GetPlatformTaskRunner()]() {
        // On GPU Task Runner.
        platform_task_runner->PostTask([platform_view]() {
          // Back on Platform Task Runner.
          if (platform_view) {
            reinterpret_cast<PlatformViewAndroid*>(platform_view.get())
                ->FireFirstFrameCallback();
          }
        });
      });
}

void PlatformViewAndroid::FireFirstFrameCallback() {
  JNIEnv* env = fml::jni::AttachCurrentThread();
  fml::jni::ScopedJavaLocalRef<jobject> view = java_object_.get(env);
  if (view.is_null()) {
    // The Java object died.
    return;
  }
  FlutterViewOnFirstFrame(fml::jni::AttachCurrentThread(), view.obj());
}

}  // namespace shell
