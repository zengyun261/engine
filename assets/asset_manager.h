// Copyright 2017 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_ASSETS_ASSET_MANAGER_H_
#define FLUTTER_ASSETS_ASSET_MANAGER_H_

#include <deque>
#include <memory>
#include <string>

#include "flutter/assets/asset_resolver.h"
#include "flutter/fml/macros.h"
#include "flutter/fml/memory/ref_counted.h"

namespace blink {

class AssetManager final : public AssetResolver,
                           public fml::RefCountedThreadSafe<AssetManager> {
 public:
  void PushFront(std::unique_ptr<AssetResolver> resolver);

  void PushBack(std::unique_ptr<AssetResolver> resolver);

  // |blink::AssetResolver|
  bool IsValid() const override;

  // |blink::AssetResolver|
  std::unique_ptr<fml::Mapping> GetAsMapping(
      const std::string& asset_name) const override;

 private:
  std::deque<std::unique_ptr<AssetResolver>> resolvers_;

  AssetManager();

  ~AssetManager();

  FML_DISALLOW_COPY_AND_ASSIGN(AssetManager);
  FML_FRIEND_MAKE_REF_COUNTED(AssetManager);
  FML_FRIEND_REF_COUNTED_THREAD_SAFE(AssetManager);
};

}  // namespace blink

#endif  // FLUTTER_ASSETS_ASSET_MANAGER_H_
