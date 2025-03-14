#!/bin/bash
# build-openwrt.sh - 用于在Docker容器中执行OpenWrt编译

set -e

# 初始化环境
echo "当前工作目录: $(pwd)"
mkdir -p $BUILD_STATE_DIR $CCACHE_DIR
chmod -R 777 /workdir || true

# 准备自定义脚本
echo '#!/bin/bash' > $GITHUB_WORKSPACE/diy-part1.sh
echo '# Feeds 已通过 FEEDS_CONF_URL 配置' >> $GITHUB_WORKSPACE/diy-part1.sh
chmod +x $GITHUB_WORKSPACE/diy-part1.sh
echo '#!/bin/bash' > $GITHUB_WORKSPACE/diy-part2.sh
echo 'sed -i "s/OpenWrt /OpenWrt_AutoBuild /" package/lean/default-settings/files/zzz-default-settings' >> $GITHUB_WORKSPACE/diy-part2.sh
chmod +x $GITHUB_WORKSPACE/diy-part2.sh

# 检查配置文件是否存在
if [ ! -f "$GITHUB_WORKSPACE/$CONFIG_FILE" ]; then
  echo "警告：配置文件 $CONFIG_FILE 不存在，创建默认配置文件"
  echo "# 创建默认的最小化配置文件" > $GITHUB_WORKSPACE/$CONFIG_FILE
  echo "CONFIG_TARGET_x86=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
  echo "CONFIG_TARGET_x86_64=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
  echo "CONFIG_TARGET_x86_64_DEVICE_generic=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
  echo "CONFIG_PACKAGE_luci=y" >> $GITHUB_WORKSPACE/$CONFIG_FILE
fi

# 克隆或更新OpenWrt源码
clone_or_update_source() {
  # 检查OpenWrt文件夹是否存在
  if [ -d "/workdir/openwrt" ]; then
    echo "OpenWrt源码目录已存在，检查更新..."
    cd /workdir/openwrt
    
    # 保存当前HEAD提交哈希
    CURRENT_COMMIT=$(git rev-parse HEAD)
    echo "当前提交: $CURRENT_COMMIT"
    
    # 重置并更新源码
    git fetch --all
    git reset --hard origin/$REPO_BRANCH
    git clean -fd
    
    # 获取更新后的HEAD提交哈希
    NEW_COMMIT=$(git rev-parse HEAD)
    echo "更新后提交: $NEW_COMMIT"
    
    # 检查是否有源码更新
    if [ "$CURRENT_COMMIT" != "$NEW_COMMIT" ] || [ "$FORCE_UPDATE" = "true" ]; then
      echo "源码已更新或强制更新被触发，需要重新编译"
      echo "source_changed=true" >> $GITHUB_ENV
    else
      echo "源码未变更"
      echo "source_changed=false" >> $GITHUB_ENV
    fi
  else
    echo "克隆新的OpenWrt源码..."
    git clone --depth 1 $REPO_URL -b $REPO_BRANCH /workdir/openwrt
    cd /workdir/openwrt
    echo "首次克隆，需要完整编译"
    echo "source_changed=true" >> $GITHUB_ENV
  fi
  
  # 确保所有脚本可执行
  find . -type f -name "*.sh" -exec chmod +x {} \;
  
  # 下载feeds配置
  curl -L -o feeds.conf.default "$FEEDS_CONF_URL" || echo "警告：无法下载 feeds.conf.default，使用仓库默认配置"
  cat feeds.conf.default
  
  # 创建必要的目录结构
  mkdir -p bin/targets bin/packages build_dir staging_dir
}

# 检查Feeds变化
check_feeds() {
  cd /workdir/openwrt
  mkdir -p $BUILD_STATE_DIR
  
  # 更新feeds并获取最新状态
  ./scripts/feeds update -a
  
  # 计算feeds哈希值
  find feeds -type f -name "Makefile" -exec sha256sum {} \; | sort | sha256sum > $BUILD_STATE_DIR/feeds.sha256
  CURRENT_FEEDS_HASH=$(cat $BUILD_STATE_DIR/feeds.sha256 | awk '{print $1}')
  PREVIOUS_FEEDS_HASH=$(cat $BUILD_STATE_DIR/previous_feeds.sha256 2>/dev/null | awk '{print $1}' || echo "")
  
  echo "当前 feeds 哈希: $CURRENT_FEEDS_HASH"
  echo "之前 feeds 哈希: $PREVIOUS_FEEDS_HASH"
  
  if [ "$CURRENT_FEEDS_HASH" != "$PREVIOUS_FEEDS_HASH" ] || [ "$source_changed" = "true" ]; then
    echo "feeds_changed=true" >> $GITHUB_ENV
    echo "Feeds 已变更或源码已更新，需要编译所有包"
    # 强制编译所有包的文件标记
    touch $BUILD_STATE_DIR/rebuild_all_packages
  else
    echo "feeds_changed=false" >> $GITHUB_ENV
    echo "Feeds 未变更，可以使用缓存包"
    # 移除强制编译所有包的文件标记
    rm -f $BUILD_STATE_DIR/rebuild_all_packages
  fi
  
  # 安装feeds
  ./scripts/feeds install -a
  
  # 保存当前哈希值供下次比较
  cp $BUILD_STATE_DIR/feeds.sha256 $BUILD_STATE_DIR/previous_feeds.sha256
}

# 配置编译环境
configure_build() {
  cd /workdir/openwrt
  $GITHUB_WORKSPACE/$DIY_P1_SH
  [ -e $GITHUB_WORKSPACE/files ] && cp -r $GITHUB_WORKSPACE/files ./files
  cp $GITHUB_WORKSPACE/$CONFIG_FILE ./.config
  cp .config .config.input
  $GITHUB_WORKSPACE/$DIY_P2_SH
  echo "CONFIG_AUTOREMOVE=n" >> .config
  echo "CONFIG_AUTOREBUILD=n" >> .config
  make defconfig
  
  # 检查配置是否丢失软件包
  grep "^CONFIG_PACKAGE_.*=y" .config.input > packages_input.txt || true
  grep "^CONFIG_PACKAGE_.*=y" .config > packages_defconfig.txt || true
  comm -23 packages_input.txt packages_defconfig.txt > missing_packages.txt
  if [ -s missing_packages.txt ]; then
    echo "警告：以下包在 defconfig 后缺失，将尝试恢复："
    cat missing_packages.txt
    cat missing_packages.txt >> .config
    while read -r line; do
      pkg=$(echo "$line" | sed 's/CONFIG_PACKAGE_\(.*\)=y/\1/')
      echo "安装包: $pkg"
      ./scripts/feeds install "$pkg" || echo "警告：无法安装 $pkg，可能不在 feeds 中"
    done < missing_packages.txt
    make defconfig
  else
    echo "所有配置项均保留，无缺失"
  fi
  
  # 检查配置差异
  diff .config.input .config > config_diff.txt || echo "配置有差异"
  
  # 如果配置有变化，需要重新编译
  if [ -s config_diff.txt ]; then
    echo "配置有变化，将只编译变化的包"
    # 找出新增和移除的包
    grep "^+CONFIG_PACKAGE_.*=y" config_diff.txt | sed 's/^+CONFIG_PACKAGE_\(.*\)=y/\1/' > added_packages.txt
    grep "^-CONFIG_PACKAGE_.*=y" config_diff.txt | sed 's/^-CONFIG_PACKAGE_\(.*\)=y/\1/' > removed_packages.txt
    
    if [ -s added_packages.txt ]; then
      echo "新增的包:"
      cat added_packages.txt
    fi
    
    if [ -s removed_packages.txt ]; then
      echo "移除的包:"
      cat removed_packages.txt
    fi
    
    echo "config_changed=true" >> $GITHUB_ENV
  else
    echo "配置无变化"
    echo "config_changed=false" >> $GITHUB_ENV
  fi
}

# 下载软件包
download_packages() {
  cd /workdir/openwrt
  make download -j8 || make download -j1 V=s
  # 配置CCACHE
  mkdir -p $CCACHE_DIR
  ccache -o cache_dir=$CCACHE_DIR
  ccache -o max_size=8G
  ccache -z
}

# 智能编译固件
compile_firmware() {
  cd /workdir/openwrt
  export CCACHE_DIR=$CCACHE_DIR
  export PATH="/usr/lib/ccache:$PATH"

  cleanup_temp_files() {
    echo "清理临时文件以释放空间..."
    find /tmp -type f -delete || true
    find /workdir/openwrt/tmp -type f -delete || true
    df -h
  }

  save_cache_info() {
    echo "保存缓存状态信息..."
    mkdir -p $BUILD_STATE_DIR
    cp .config $BUILD_STATE_DIR/config.txt
    echo "$(date)" > $BUILD_STATE_DIR/last_build_time.txt
    echo "保存构建状态完成"
  }

  # 开始时间记录
  START_TIME=$(date +%s)
  echo "开始编译时间: $(date)"
  
  # 定期清理临时文件以释放空间
  (while true; do sleep 300; cleanup_temp_files; done) &
  CLEANUP_PID=$!
  
  # 决定编译策略
  if [ "$CLEAN_BUILD" = "true" ]; then
    # 用户请求完全重新编译
    echo "用户请求完全重新编译"
    make clean
    make -j$(nproc) V=s || make -j1 V=s
    
  elif [ "$feeds_changed" = "true" ] || [ -f "$BUILD_STATE_DIR/rebuild_all_packages" ]; then
    # Feeds变更或源码变更，需要重新编译所有包
    echo "Feeds或源码已变更，重新编译所有包"
    make package/clean
    make -j$(nproc) V=s || make -j1 V=s
    
  elif [ "$config_changed" = "true" ]; then
    # 配置有变化，只编译变化的包
    echo "配置有变化，进行智能增量编译"
    
    # 编译新增的包
    if [ -s added_packages.txt ]; then
      echo "编译新增的包..."
      while read -r pkg; do
        echo "编译包: $pkg"
        make package/$pkg/{clean,compile} -j$(nproc) V=s || make package/$pkg/{clean,compile} -j1 V=s
        # 每编译一个包后清理临时文件
        cleanup_temp_files
      done < added_packages.txt
    fi
    
    # 移除已删除的包
    if [ -s removed_packages.txt ]; then
      echo "清理移除的包..."
      while read -r pkg; do
        echo "清理包: $pkg"
        make package/$pkg/clean V=s || true
      done < removed_packages.txt
    fi
    
    # 构建固件
    echo "生成最终固件..."
    make -j$(nproc) V=s || make -j1 V=s
    
  else
    # 无变化，仅重新生成固件
    echo "配置和feeds都未变化，执行最小增量编译..."
    make -j$(nproc) V=s || make -j1 V=s
  fi
  
  # 停止清理进程
  kill $CLEANUP_PID 2>/dev/null || true
  
  # 最后清理一次临时文件
  cleanup_temp_files
  
  # 结束时间记录
  END_TIME=$(date +%s)
  echo "结束编译时间: $(date)"
  echo "总编译用时: $((END_TIME - START_TIME)) 秒"
  
  # 保存缓存信息
  save_cache_info

  if [ $? -eq 0 ]; then
    echo "编译成功"
    return 0
  else
    echo "编译失败"
    return 1
  fi
}

# 设置环境变量
set_env_vars() {
  device_name="_$(grep '^CONFIG_TARGET.*DEVICE.*=y' /workdir/openwrt/.config | sed -r 's/.*DEVICE_(.*)=y/\1/' | tr '\n' '_')"
  file_date="_$(date +"%Y%m%d%H%M")"
  
  echo "DEVICE_NAME=$device_name" >> $GITHUB_ENV
  echo "FILE_DATE=$file_date" >> $GITHUB_ENV
  echo "FIRMWARE=/workdir/openwrt/bin/targets/*/*/firmware" >> $GITHUB_ENV
  
  echo "status=success" >> $GITHUB_OUTPUT
}

# 主函数
main() {
  # 设置变量
  CLEAN_BUILD="${CLEAN_BUILD:-false}"
  FORCE_UPDATE="${FORCE_UPDATE:-false}"
  
  # 执行构建步骤
  clone_or_update_source
  check_feeds
  configure_build
  download_packages
  compile_firmware
  set_env_vars
  
  # 完成
  echo "编译工作流完成"
}

# 运行主函数
main
