// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/lib/ui/painting/codec.h"

#include "flutter/common/task_runners.h"
#include "flutter/glue/trace_event.h"
#include "flutter/lib/ui/painting/frame_info.h"
#include "lib/fxl/functional/make_copyable.h"
#include "lib/fxl/logging.h"
#include "lib/tonic/dart_binding_macros.h"
#include "lib/tonic/dart_library_natives.h"
#include "lib/tonic/dart_state.h"
#include "lib/tonic/logging/dart_invoke.h"
#include "lib/tonic/typed_data/uint8_list.h"
#include "third_party/skia/include/codec/SkCodec.h"
#include "third_party/skia/include/core/SkPixelRef.h"

#ifdef ERROR
#undef ERROR
#endif

using tonic::DartInvoke;
using tonic::DartPersistentValue;
using tonic::ToDart;

namespace blink {

namespace {

static constexpr const char* kInitCodecTraceTag = "InitCodec";
static constexpr const char* kCodecNextFrameTraceTag = "CodecNextFrame";

// This must be kept in sync with the enum in painting.dart
enum PixelFormat {
  kRGBA8888,
  kBGRA8888,
};

struct ImageInfo {
  SkImageInfo sk_info;
  size_t row_bytes;
};

static void InvokeCodecCallback(fxl::RefPtr<Codec> codec,
                                std::unique_ptr<DartPersistentValue> callback,
                                size_t trace_id) {
  tonic::DartState* dart_state = callback->dart_state().get();
  if (!dart_state) {
    TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
    return;
  }
  tonic::DartState::Scope scope(dart_state);
  if (!codec) {
    DartInvoke(callback->value(), {Dart_Null()});
  } else {
    DartInvoke(callback->value(), {ToDart(codec)});
  }
  TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
}

static sk_sp<SkImage> DecodeImage(fml::WeakPtr<GrContext> context,
                                  sk_sp<SkData> buffer,
                                  size_t trace_id) {
  TRACE_FLOW_STEP("flutter", kInitCodecTraceTag, trace_id);
  TRACE_EVENT0("flutter", "DecodeImage");

  if (buffer == nullptr || buffer->isEmpty()) {
    return nullptr;
  }

  if (context) {
    // This indicates that we do not want a "linear blending" decode.
    sk_sp<SkColorSpace> dstColorSpace = nullptr;
    return SkImage::MakeCrossContextFromEncoded(
        context.get(), std::move(buffer), false, dstColorSpace.get(), true);
  } else {
    // Defer decoding until time of draw later on the GPU thread. Can happen
    // when GL operations are currently forbidden such as in the background
    // on iOS.
    return SkImage::MakeFromEncoded(std::move(buffer));
  }
}

fxl::RefPtr<Codec> InitCodec(fml::WeakPtr<GrContext> context,
                             sk_sp<SkData> buffer,
                             fxl::RefPtr<flow::SkiaUnrefQueue> unref_queue,
                             size_t trace_id) {
  TRACE_FLOW_STEP("flutter", kInitCodecTraceTag, trace_id);
  TRACE_EVENT0("blink", "InitCodec");

  if (buffer == nullptr || buffer->isEmpty()) {
    FXL_LOG(ERROR) << "InitCodec failed - buffer was empty ";
    return nullptr;
  }

  std::unique_ptr<SkCodec> skCodec = SkCodec::MakeFromData(buffer);
  if (!skCodec) {
    FXL_LOG(ERROR) << "Failed decoding image. Data is either invalid, or it is "
                      "encoded using an unsupported format.";
    return nullptr;
  }
  if (skCodec->getFrameCount() > 1) {
    return fxl::MakeRefCounted<MultiFrameCodec>(std::move(skCodec));
  }
  auto skImage = DecodeImage(context, buffer, trace_id);
  if (!skImage) {
    FXL_LOG(ERROR) << "DecodeImage failed";
    return nullptr;
  }
  auto image = CanvasImage::Create();
  image->set_image({skImage, unref_queue});
  auto frameInfo = fxl::MakeRefCounted<FrameInfo>(std::move(image), 0);
  return fxl::MakeRefCounted<SingleFrameCodec>(std::move(frameInfo));
}

fxl::RefPtr<Codec> InitCodecUncompressed(
    fml::WeakPtr<GrContext> context,
    sk_sp<SkData> buffer,
    ImageInfo image_info,
    fxl::RefPtr<flow::SkiaUnrefQueue> unref_queue,
    size_t trace_id) {
  TRACE_FLOW_STEP("flutter", kInitCodecTraceTag, trace_id);
  TRACE_EVENT0("blink", "InitCodecUncompressed");

  if (buffer == nullptr || buffer->isEmpty()) {
    FXL_LOG(ERROR) << "InitCodecUncompressed failed - buffer was empty";
    return nullptr;
  }

  sk_sp<SkImage> skImage;
  if (context) {
    SkPixmap pixmap(image_info.sk_info, buffer->data(), image_info.row_bytes);
    skImage = SkImage::MakeCrossContextFromPixmap(context.get(), pixmap, false,
                                                  nullptr, true);
  } else {
    skImage = SkImage::MakeRasterData(image_info.sk_info, std::move(buffer),
                                      image_info.row_bytes);
  }

  auto image = CanvasImage::Create();
  image->set_image({skImage, unref_queue});
  auto frameInfo = fxl::MakeRefCounted<FrameInfo>(std::move(image), 0);
  return fxl::MakeRefCounted<SingleFrameCodec>(std::move(frameInfo));
}

void InitCodecAndInvokeCodecCallback(
    fxl::RefPtr<fxl::TaskRunner> ui_task_runner,
    fml::WeakPtr<GrContext> context,
    fxl::RefPtr<flow::SkiaUnrefQueue> unref_queue,
    std::unique_ptr<DartPersistentValue> callback,
    sk_sp<SkData> buffer,
    std::unique_ptr<ImageInfo> image_info,
    size_t trace_id) {
  fxl::RefPtr<Codec> codec;
  if (image_info) {
    codec = InitCodecUncompressed(context, std::move(buffer), *image_info,
                                  std::move(unref_queue), trace_id);
  } else {
    codec =
        InitCodec(context, std::move(buffer), std::move(unref_queue), trace_id);
  }
  ui_task_runner->PostTask(
      fxl::MakeCopyable([callback = std::move(callback),
                         codec = std::move(codec), trace_id]() mutable {
        InvokeCodecCallback(std::move(codec), std::move(callback), trace_id);
      }));
}

bool ConvertImageInfo(Dart_Handle image_info_handle,
                      Dart_NativeArguments args,
                      ImageInfo* image_info) {
  Dart_Handle width_handle = Dart_GetField(image_info_handle, ToDart("width"));
  if (!Dart_IsInteger(width_handle)) {
    Dart_SetReturnValue(args, ToDart("ImageInfo.width must be an integer"));
    return false;
  }
  Dart_Handle height_handle =
      Dart_GetField(image_info_handle, ToDart("height"));
  if (!Dart_IsInteger(height_handle)) {
    Dart_SetReturnValue(args, ToDart("ImageInfo.height must be an integer"));
    return false;
  }
  Dart_Handle format_handle =
      Dart_GetField(image_info_handle, ToDart("format"));
  if (!Dart_IsInteger(format_handle)) {
    Dart_SetReturnValue(args, ToDart("ImageInfo.format must be an integer"));
    return false;
  }
  Dart_Handle row_bytes_handle =
      Dart_GetField(image_info_handle, ToDart("rowBytes"));
  if (!Dart_IsInteger(row_bytes_handle)) {
    Dart_SetReturnValue(args, ToDart("ImageInfo.rowBytes must be an integer"));
    return false;
  }

  PixelFormat pixel_format = static_cast<PixelFormat>(
      tonic::DartConverter<int>::FromDart(format_handle));
  SkColorType color_type = kUnknown_SkColorType;
  switch (pixel_format) {
    case kRGBA8888:
      color_type = kRGBA_8888_SkColorType;
      break;
    case kBGRA8888:
      color_type = kBGRA_8888_SkColorType;
      break;
  }
  if (color_type == kUnknown_SkColorType) {
    Dart_SetReturnValue(args, ToDart("Invalid pixel format"));
    return false;
  }

  int width = tonic::DartConverter<int>::FromDart(width_handle);
  if (width <= 0) {
    Dart_SetReturnValue(args, ToDart("width must be greater than zero"));
    return false;
  }
  int height = tonic::DartConverter<int>::FromDart(height_handle);
  if (height <= 0) {
    Dart_SetReturnValue(args, ToDart("height must be greater than zero"));
    return false;
  }
  image_info->sk_info =
      SkImageInfo::Make(width, height, color_type, kPremul_SkAlphaType);
  image_info->row_bytes =
      tonic::DartConverter<size_t>::FromDart(row_bytes_handle);

  if (image_info->row_bytes < image_info->sk_info.minRowBytes()) {
    Dart_SetReturnValue(
        args, ToDart("rowBytes does not match the width of the image"));
    return false;
  }

  return true;
}

void InstantiateImageCodec(Dart_NativeArguments args) {
  static size_t trace_counter = 1;
  const size_t trace_id = trace_counter++;
  TRACE_FLOW_BEGIN("flutter", kInitCodecTraceTag, trace_id);

  Dart_Handle callback_handle = Dart_GetNativeArgument(args, 1);
  if (!Dart_IsClosure(callback_handle)) {
    TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
    Dart_SetReturnValue(args, ToDart("Callback must be a function"));
    return;
  }

  Dart_Handle image_info_handle = Dart_GetNativeArgument(args, 2);
  std::unique_ptr<ImageInfo> image_info;
  if (!Dart_IsNull(image_info_handle)) {
    image_info = std::make_unique<ImageInfo>();
    if (!ConvertImageInfo(image_info_handle, args, image_info.get())) {
      TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
      return;
    }
  }

  Dart_Handle exception = nullptr;
  tonic::Uint8List list =
      tonic::DartConverter<tonic::Uint8List>::FromArguments(args, 0, exception);
  if (exception) {
    TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
    Dart_SetReturnValue(args, exception);
    return;
  }

  if (image_info) {
    int expected_size = image_info->row_bytes * image_info->sk_info.height();
    if (list.num_elements() < expected_size) {
      TRACE_FLOW_END("flutter", kInitCodecTraceTag, trace_id);
      list.Release();
      Dart_SetReturnValue(
          args, ToDart("Pixel buffer size does not match image size"));
      return;
    }
  }

  auto buffer = SkData::MakeWithCopy(list.data(), list.num_elements());

  auto dart_state = UIDartState::Current();

  const auto& task_runners = dart_state->GetTaskRunners();
  task_runners.GetIOTaskRunner()->PostTask(fxl::MakeCopyable(
      [callback = std::make_unique<DartPersistentValue>(
           tonic::DartState::Current(), callback_handle),
       buffer = std::move(buffer), trace_id, image_info = std::move(image_info),
       ui_task_runner = task_runners.GetUITaskRunner(),
       context = dart_state->GetResourceContext(),
       queue = UIDartState::Current()->GetSkiaUnrefQueue()]() mutable {
        InitCodecAndInvokeCodecCallback(std::move(ui_task_runner), context,
                                        std::move(queue), std::move(callback),
                                        std::move(buffer),
                                        std::move(image_info), trace_id);
      }));
}

bool copy_to(SkBitmap* dst, SkColorType dstColorType, const SkBitmap& src) {
  SkPixmap srcPM;
  if (!src.peekPixels(&srcPM)) {
    return false;
  }

  SkBitmap tmpDst;
  SkImageInfo dstInfo = srcPM.info().makeColorType(dstColorType);
  if (!tmpDst.setInfo(dstInfo)) {
    return false;
  }

  if (!tmpDst.tryAllocPixels()) {
    return false;
  }

  SkPixmap dstPM;
  if (!tmpDst.peekPixels(&dstPM)) {
    return false;
  }

  if (!srcPM.readPixels(dstPM)) {
    return false;
  }

  dst->swap(tmpDst);
  return true;
}

void InvokeNextFrameCallback(fxl::RefPtr<FrameInfo> frameInfo,
                             std::unique_ptr<DartPersistentValue> callback,
                             size_t trace_id) {
  tonic::DartState* dart_state = callback->dart_state().get();
  if (!dart_state) {
    TRACE_FLOW_END("flutter", kCodecNextFrameTraceTag, trace_id);
    return;
  }
  tonic::DartState::Scope scope(dart_state);
  if (!frameInfo) {
    DartInvoke(callback->value(), {Dart_Null()});
  } else {
    DartInvoke(callback->value(), {ToDart(frameInfo)});
  }
  TRACE_FLOW_END("flutter", kCodecNextFrameTraceTag, trace_id);
}

}  // namespace

IMPLEMENT_WRAPPERTYPEINFO(ui, Codec);

#define FOR_EACH_BINDING(V) \
  V(Codec, getNextFrame)    \
  V(Codec, frameCount)      \
  V(Codec, repetitionCount) \
  V(Codec, dispose)

FOR_EACH_BINDING(DART_NATIVE_CALLBACK)

void Codec::dispose() {
  ClearDartWrapper();
}

MultiFrameCodec::MultiFrameCodec(std::unique_ptr<SkCodec> codec)
    : codec_(std::move(codec)) {
  repetitionCount_ = codec_->getRepetitionCount();
  frameInfos_ = codec_->getFrameInfo();
  frameBitmaps_.resize(frameInfos_.size());
  nextFrameIndex_ = 0;
}

sk_sp<SkImage> MultiFrameCodec::GetNextFrameImage(
    fml::WeakPtr<GrContext> resourceContext) {
  SkBitmap& bitmap = frameBitmaps_[nextFrameIndex_];
  if (!bitmap.getPixels()) {  // We haven't decoded this frame yet
    const SkImageInfo info = codec_->getInfo().makeColorType(kN32_SkColorType);
    bitmap.allocPixels(info);

    SkCodec::Options options;
    options.fFrameIndex = nextFrameIndex_;
    const int requiredFrame = frameInfos_[nextFrameIndex_].fRequiredFrame;
    if (requiredFrame != SkCodec::kNone) {
      if (requiredFrame < 0 ||
          static_cast<size_t>(requiredFrame) >= frameBitmaps_.size()) {
        FXL_LOG(ERROR) << "Frame " << nextFrameIndex_ << " depends on frame "
                       << requiredFrame << " which out of range (0,"
                       << frameBitmaps_.size() << ").";
        return NULL;
      }
      SkBitmap& requiredBitmap = frameBitmaps_[requiredFrame];
      // For simplicity, do not try to cache old frames
      if (requiredBitmap.getPixels() &&
          copy_to(&bitmap, requiredBitmap.colorType(), requiredBitmap)) {
        options.fPriorFrame = requiredFrame;
      }
    }

    if (SkCodec::kSuccess != codec_->getPixels(info, bitmap.getPixels(),
                                               bitmap.rowBytes(), &options)) {
      FXL_LOG(ERROR) << "Could not getPixels for frame " << nextFrameIndex_;
      return NULL;
    }
  }

  if (resourceContext) {
    SkPixmap pixmap(bitmap.info(), bitmap.pixelRef()->pixels(),
                    bitmap.pixelRef()->rowBytes());
    // This indicates that we do not want a "linear blending" decode.
    sk_sp<SkColorSpace> dstColorSpace = nullptr;
    return SkImage::MakeCrossContextFromPixmap(resourceContext.get(), pixmap,
                                               false, dstColorSpace.get());
  } else {
    // Defer decoding until time of draw later on the GPU thread. Can happen
    // when GL operations are currently forbidden such as in the background
    // on iOS.
    return SkImage::MakeFromBitmap(bitmap);
  }
}

void MultiFrameCodec::GetNextFrameAndInvokeCallback(
    std::unique_ptr<DartPersistentValue> callback,
    fxl::RefPtr<fxl::TaskRunner> ui_task_runner,
    fml::WeakPtr<GrContext> resourceContext,
    fxl::RefPtr<flow::SkiaUnrefQueue> unref_queue,
    size_t trace_id) {
  fxl::RefPtr<FrameInfo> frameInfo = NULL;
  sk_sp<SkImage> skImage = GetNextFrameImage(resourceContext);
  if (skImage) {
    fxl::RefPtr<CanvasImage> image = CanvasImage::Create();
    image->set_image({skImage, std::move(unref_queue)});
    frameInfo = fxl::MakeRefCounted<FrameInfo>(
        std::move(image), frameInfos_[nextFrameIndex_].fDuration);
  }
  nextFrameIndex_ = (nextFrameIndex_ + 1) % frameInfos_.size();

  ui_task_runner->PostTask(fxl::MakeCopyable(
      [callback = std::move(callback), frameInfo, trace_id]() mutable {
        InvokeNextFrameCallback(frameInfo, std::move(callback), trace_id);
      }));

  TRACE_FLOW_END("flutter", kCodecNextFrameTraceTag, trace_id);
}

Dart_Handle MultiFrameCodec::getNextFrame(Dart_Handle callback_handle) {
  static size_t trace_counter = 1;
  const size_t trace_id = trace_counter++;
  TRACE_FLOW_BEGIN("flutter", kCodecNextFrameTraceTag, trace_id);

  if (!Dart_IsClosure(callback_handle)) {
    TRACE_FLOW_END("flutter", kCodecNextFrameTraceTag, trace_id);
    return ToDart("Callback must be a function");
  }

  auto dart_state = UIDartState::Current();

  const auto& task_runners = dart_state->GetTaskRunners();

  task_runners.GetIOTaskRunner()->PostTask(fxl::MakeCopyable(
      [callback = std::make_unique<DartPersistentValue>(
           tonic::DartState::Current(), callback_handle),
       this, trace_id, ui_task_runner = task_runners.GetUITaskRunner(),
       queue = UIDartState::Current()->GetSkiaUnrefQueue(),
       context = dart_state->GetResourceContext()]() mutable {
        GetNextFrameAndInvokeCallback(std::move(callback),
                                      std::move(ui_task_runner), context,
                                      std::move(queue), trace_id);
      }));

  return Dart_Null();
}

Dart_Handle SingleFrameCodec::getNextFrame(Dart_Handle callback_handle) {
  if (!Dart_IsClosure(callback_handle)) {
    return ToDart("Callback must be a function");
  }

  auto callback = std::make_unique<DartPersistentValue>(
      tonic::DartState::Current(), callback_handle);
  tonic::DartState* dart_state = callback->dart_state().get();
  if (!dart_state) {
    return ToDart("Invalid dart state");
  }

  tonic::DartState::Scope scope(dart_state);
  DartInvoke(callback->value(), {ToDart(frame_)});
  return Dart_Null();
}

void Codec::RegisterNatives(tonic::DartLibraryNatives* natives) {
  natives->Register({
      {"instantiateImageCodec", InstantiateImageCodec, 3, true},
  });
  natives->Register({FOR_EACH_BINDING(DART_REGISTER_NATIVE)});
}

}  // namespace blink
