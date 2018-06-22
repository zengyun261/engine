// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_ASSETS_APK_ASSET_PROVIDER_H_
#define FLUTTER_ASSETS_APK_ASSET_PROVIDER_H_

#include <android/asset_manager_jni.h>
#include <jni.h>

#include "flutter/assets/asset_resolver.h"
#include "flutter/fml/platform/android/scoped_java_ref.h"
#include "lib/fxl/memory/ref_counted.h"

namespace blink {

class APKAssetProvider final : public AssetResolver {
 public:
  explicit APKAssetProvider(JNIEnv* env,
                            jobject assetManager,
                            std::string directory);
  virtual ~APKAssetProvider();

 private:
  fml::jni::ScopedJavaGlobalRef<jobject> java_asset_manager_;
  AAssetManager* assetManager_;
  const std::string directory_;

  // |blink::AssetResolver|
  bool IsValid() const override;

  // |blink::AssetResolver|
  std::unique_ptr<fml::Mapping> GetAsMapping(
      const std::string& asset_name) const override;

  FXL_DISALLOW_COPY_AND_ASSIGN(APKAssetProvider);
};

}  // namespace blink

#endif  // FLUTTER_ASSETS_APK_ASSET_PROVIDER_H
